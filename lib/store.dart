// store.dart — persistance sqflite et export CSV.
//
// Plomberie assumée : une table, pas de migration, pas d'édition. La seule
// subtilité est que les champs dérivés (food_correct, grams_error,
// carbs_error, weight_only_error) sont calculés ICI, à l'insertion —
// l'appelant fournit l'estimation et la vérité terrain, jamais l'erreur.
//
// Usage :
//   final store = MeasurementStore();
//   await store.open();
//   await store.insert(Measurement(
//     createdAt: DateTime.now(),
//     photoPath: path,
//     condition: ScaleCondition.plate,
//     plateMm: 260,
//     modelName: 'mistral-small-latest',
//     rawResponse: result.rawResponse,
//     estFood: result.foodName,
//     estCiqual: result.ciqualCode,
//     estGrams: result.grams,
//     estCarbs: estCarbs,
//     estConfidence: result.confidence,
//     latencyMs: result.latencyMs,
//     trueGrams: 240,
//     trueCiqual: '25101',
//     trueCarbs: trueCarbs,
//   ), trueCarbsPer100g: trueFood.carbsPer100g);
//   final stats = await store.stats();
//   final csvPath = await store.exportCsv();

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'vision.dart' show ScaleCondition;

/// Une mesure : un repas, une estimation, une pesée.
///
/// `id` et les champs dérivés sont null tant que la mesure n'est pas passée
/// par [MeasurementStore.insert].
class Measurement {
  final int? id;
  final DateTime createdAt;
  final String photoPath;
  final ScaleCondition condition;
  final int? plateMm; // rempli si condition = plate

  // ce que le modèle a répondu
  final String modelName;
  final String rawResponse; // JSON brut, pour rejouer plus tard
  final String? estFood;
  final String? estCiqual;
  final double? estGrams;
  final double? estCarbs;
  final String? estConfidence; // 'high' | 'medium' | 'low'
  final int? latencyMs;

  // la vérité
  final double? trueGrams; // balance
  final String? trueCiqual; // code que TU aurais choisi
  final double? trueCarbs;

  // dérivé, calculé à l'insertion
  final bool? foodCorrect;
  final double? gramsError; // est_grams - true_grams
  final double? carbsError; // est_carbs - true_carbs (erreur totale)

  /// Glucides qu'on aurait obtenus avec la BONNE identification et le poids
  /// ESTIMÉ, moins la vérité : l'erreur de POIDS pure. L'écart avec
  /// [carbsError] est ce que coûte (ou masque) l'identification.
  final double? weightOnlyError;

  Measurement({
    this.id,
    required this.createdAt,
    required this.photoPath,
    required this.condition,
    this.plateMm,
    required this.modelName,
    required this.rawResponse,
    this.estFood,
    this.estCiqual,
    this.estGrams,
    this.estCarbs,
    this.estConfidence,
    this.latencyMs,
    this.trueGrams,
    this.trueCiqual,
    this.trueCarbs,
    this.foodCorrect,
    this.gramsError,
    this.carbsError,
    this.weightOnlyError,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'created_at': createdAt.millisecondsSinceEpoch,
        'photo_path': photoPath,
        'condition': condition.name,
        'plate_mm': plateMm,
        'model_name': modelName,
        'raw_response': rawResponse,
        'est_food': estFood,
        'est_ciqual': estCiqual,
        'est_grams': estGrams,
        'est_carbs': estCarbs,
        'est_confidence': estConfidence,
        'latency_ms': latencyMs,
        'true_grams': trueGrams,
        'true_ciqual': trueCiqual,
        'true_carbs': trueCarbs,
        'food_correct': foodCorrect == null ? null : (foodCorrect! ? 1 : 0),
        'grams_error': gramsError,
        'carbs_error': carbsError,
        'weight_only_error': weightOnlyError,
      };

  static Measurement fromMap(Map<String, Object?> m) => Measurement(
        id: m['id'] as int?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        photoPath: m['photo_path'] as String,
        condition: ScaleCondition.values.byName(m['condition'] as String),
        plateMm: m['plate_mm'] as int?,
        modelName: m['model_name'] as String,
        rawResponse: m['raw_response'] as String,
        estFood: m['est_food'] as String?,
        estCiqual: m['est_ciqual'] as String?,
        estGrams: (m['est_grams'] as num?)?.toDouble(),
        estCarbs: (m['est_carbs'] as num?)?.toDouble(),
        estConfidence: m['est_confidence'] as String?,
        latencyMs: m['latency_ms'] as int?,
        trueGrams: (m['true_grams'] as num?)?.toDouble(),
        trueCiqual: m['true_ciqual'] as String?,
        trueCarbs: (m['true_carbs'] as num?)?.toDouble(),
        foodCorrect: switch (m['food_correct'] as int?) {
          null => null,
          0 => false,
          _ => true,
        },
        gramsError: (m['grams_error'] as num?)?.toDouble(),
        carbsError: (m['carbs_error'] as num?)?.toDouble(),
        weightOnlyError: (m['weight_only_error'] as num?)?.toDouble(),
      );
}

/// Agrégats pour l'écran Stats. Tout est calculé en Dart sur la liste
/// complète : à 30 mesures, une requête SQL par agrégat serait du zèle.
class BenchStats {
  final int count;
  final Map<ScaleCondition, int> countByCondition;

  /// MAE glucides : moyenne de |carbs_error|. Null si aucune mesure exploitable.
  final double? carbsMae;
  final Map<ScaleCondition, double> carbsMaeByCondition;

  /// Biais : moyenne SIGNÉE de carbs_error. Négatif = le modèle sous-estime.
  final double? carbsBias;

  /// MAE de |weight_only_error| : erreur de POIDS pure, identification
  /// supposée parfaite.
  ///
  /// Lecture :
  ///   weightMae ≈ carbsMae  -> l'identification est fiable, tout se joue sur
  ///                            le poids : travaille les références d'échelle.
  ///   weightMae << carbsMae -> l'identification est le goulot : enrichis la
  ///                            liste d'aliments ou le prompt.
  ///   weightMae > carbsMae  -> les erreurs se compensent par hasard. Ne te
  ///                            réjouis pas : c'est fragile.
  final double? weightMae;

  /// carbsMae - weightMae : ce que coûte (ou masque) l'identification.
  final double? identImpact;

  /// Photos que le modèle a refusé d'estimer (est_grams absent).
  final int unableCount;

  /// Repas où une MAUVAISE identification a accidentellement amélioré le
  /// résultat (|carbs_error| < |weight_only_error|). Au-delà de 2-3 sur 30,
  /// le MAE global est bon par chance, pas par justesse : à regarder AVANT
  /// de tirer la moindre conclusion.
  final int luckyCompensations;

  /// Part des mesures où le modèle a choisi le bon code Ciqual.
  final double? foodCorrectRate;

  BenchStats({
    required this.count,
    required this.countByCondition,
    required this.carbsMae,
    required this.carbsMaeByCondition,
    required this.carbsBias,
    required this.weightMae,
    required this.identImpact,
    required this.unableCount,
    required this.luckyCompensations,
    required this.foodCorrectRate,
  });
}

class MeasurementStore {
  Database? _db;

  static const _createTable = '''
CREATE TABLE IF NOT EXISTS measurement (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at    INTEGER NOT NULL,
  photo_path    TEXT    NOT NULL,
  condition     TEXT    NOT NULL,
  plate_mm      INTEGER,
  model_name    TEXT    NOT NULL,
  raw_response  TEXT    NOT NULL,
  est_food      TEXT,
  est_ciqual    TEXT,
  est_grams     REAL,
  est_carbs     REAL,
  est_confidence TEXT,
  latency_ms    INTEGER,
  true_grams    REAL,
  true_ciqual   TEXT,
  true_carbs    REAL,
  food_correct  INTEGER,
  grams_error   REAL,
  carbs_error   REAL,
  weight_only_error REAL
)''';

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(
      '${dir.path}/bench.db',
      version: 1,
      onCreate: (db, _) => db.execute(_createTable),
    );
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('MeasurementStore.open() doit être appelé avant usage');
    }
    return db;
  }

  /// Insère une mesure en calculant les champs dérivés. Renvoie la mesure
  /// complète (id + dérivés) telle qu'enregistrée.
  Future<Measurement> insert(
    Measurement m, {
    /// Glucides pour 100 g de l'aliment RÉEL (m.trueCiqual), lus dans Ciqual.
    /// Nécessaire pour isoler l'erreur de poids de l'erreur d'identification.
    double? trueCarbsPer100g,
  }) async {
    final foodCorrect = (m.estCiqual != null && m.trueCiqual != null)
        ? m.estCiqual == m.trueCiqual
        : null;
    final gramsError = (m.estGrams != null && m.trueGrams != null)
        ? m.estGrams! - m.trueGrams!
        : null;
    final carbsError = (m.estCarbs != null && m.trueCarbs != null)
        ? m.estCarbs! - m.trueCarbs!
        : null;
    // Glucides qu'on aurait obtenus avec la BONNE identification et le
    // poids ESTIMÉ. L'écart restant est imputable au seul poids.
    final weightOnlyError = (trueCarbsPer100g != null &&
            m.estGrams != null &&
            m.trueCarbs != null)
        ? (trueCarbsPer100g * m.estGrams! / 100.0) - m.trueCarbs!
        : null;

    final complete = Measurement(
      createdAt: m.createdAt,
      photoPath: m.photoPath,
      condition: m.condition,
      plateMm: m.plateMm,
      modelName: m.modelName,
      rawResponse: m.rawResponse,
      estFood: m.estFood,
      estCiqual: m.estCiqual,
      estGrams: m.estGrams,
      estCarbs: m.estCarbs,
      estConfidence: m.estConfidence,
      latencyMs: m.latencyMs,
      trueGrams: m.trueGrams,
      trueCiqual: m.trueCiqual,
      trueCarbs: m.trueCarbs,
      foodCorrect: foodCorrect,
      gramsError: gramsError,
      carbsError: carbsError,
      weightOnlyError: weightOnlyError,
    );

    final id = await _database.insert('measurement', complete.toMap());
    return Measurement.fromMap({...complete.toMap(), 'id': id});
  }

  Future<List<Measurement>> all() async {
    final rows =
        await _database.query('measurement', orderBy: 'created_at ASC');
    return rows.map(Measurement.fromMap).toList();
  }

  Future<BenchStats> stats() async {
    final measurements = await all();

    final countByCondition = <ScaleCondition, int>{};
    final errorsByCondition = <ScaleCondition, List<double>>{};
    final allErrors = <double>[];
    final weightErrors = <double>[];
    var identified = 0, identifiable = 0, unableCount = 0;
    var luckyCompensations = 0;

    for (final m in measurements) {
      countByCondition.update(m.condition, (n) => n + 1, ifAbsent: () => 1);
      if (m.carbsError != null) {
        allErrors.add(m.carbsError!);
        errorsByCondition.putIfAbsent(m.condition, () => []).add(m.carbsError!);
      }
      if (m.weightOnlyError != null) weightErrors.add(m.weightOnlyError!);
      // Tolérance : quand l'identification est bonne, les deux erreurs sont
      // mathématiquement égales mais pas forcément bit à bit (carbsPer100g
      // est dérivé de carbs*100/per) — sans epsilon on compterait des
      // compensations fantômes à 1e-15 près.
      if (m.carbsError != null &&
          m.weightOnlyError != null &&
          m.carbsError!.abs() < m.weightOnlyError!.abs() - 1e-9) {
        luckyCompensations++;
      }
      if (m.estGrams == null) unableCount++;
      if (m.foodCorrect != null) {
        identifiable++;
        if (m.foodCorrect!) identified++;
      }
    }

    double mean(Iterable<double> xs) =>
        xs.reduce((a, b) => a + b) / xs.length;

    final carbsMae =
        allErrors.isEmpty ? null : mean(allErrors.map((e) => e.abs()));
    final weightMae =
        weightErrors.isEmpty ? null : mean(weightErrors.map((e) => e.abs()));

    return BenchStats(
      count: measurements.length,
      countByCondition: countByCondition,
      carbsMae: carbsMae,
      carbsMaeByCondition: errorsByCondition.map(
          (c, errs) => MapEntry(c, mean(errs.map((e) => e.abs())))),
      carbsBias: allErrors.isEmpty ? null : mean(allErrors),
      weightMae: weightMae,
      identImpact: (carbsMae != null && weightMae != null)
          ? carbsMae - weightMae
          : null,
      unableCount: unableCount,
      luckyCompensations: luckyCompensations,
      foodCorrectRate: identifiable == 0 ? null : identified / identifiable,
    );
  }

  /// Écrit toutes les mesures en CSV et renvoie le chemin du fichier.
  /// Exclusions volontaires : `raw_response` (retours à la ligne et guillemets
  /// qui cassent les lecteurs CSV naïfs — il reste dans la base) et
  /// `photo_path` (les résultats se publient sans les photos, et un chemin
  /// local n'apprend rien). Le partage du fichier (share_plus) est du ressort
  /// de l'UI.
  Future<String> exportCsv() async {
    const columns = [
      'id', 'created_at', 'condition', 'plate_mm',
      'model_name', 'est_food', 'est_ciqual', 'est_grams', 'est_carbs',
      'est_confidence', 'latency_ms', 'true_grams', 'true_ciqual',
      'true_carbs', 'food_correct', 'grams_error', 'carbs_error',
      'weight_only_error',
    ];

    String cell(Object? v) {
      if (v == null) return '';
      final s = v.toString();
      return s.contains(RegExp(r'[",\n]'))
          ? '"${s.replaceAll('"', '""')}"'
          : s;
    }

    final buffer = StringBuffer()
      ..write('\uFEFF') // BOM : Excel FR lit alors correctement l'UTF-8
      ..writeln(columns.join(','));
    for (final m in await all()) {
      final map = m.toMap();
      buffer.writeln(columns.map((c) => cell(map[c])).join(','));
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/ciqual-vision-bench.csv');
    await file.writeAsString(buffer.toString());
    return file.path;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
