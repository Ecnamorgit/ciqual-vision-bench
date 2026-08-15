// ciqual.dart — chargement de l'asset Ciqual, lookup par code, recherche.
//
// Usage :
//   final ciqual = await CiqualBase.load();          // une fois au démarrage
//   final food = ciqual.byCode('25101');             // lookup O(1)
//   final hits = ciqual.search('pates');             // trouve « Pâtes »
//   vision.estimate(..., candidates: ciqual.allFoods);

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'vision.dart' show CiqualFood;

class CiqualBase {
  final List<CiqualFood> allFoods;
  final Map<String, CiqualFood> _byCode;

  // Libellés pré-normalisés une fois au chargement : la recherche à chaque
  // frappe ne re-normalise que la requête.
  final Map<String, String> _normalizedNames;

  CiqualBase._(this.allFoods, this._byCode, this._normalizedNames);

  static Future<CiqualBase> load({String asset = 'assets/ciqual-base.json'}) async {
    final raw = jsonDecode(await rootBundle.loadString(asset))
        as Map<String, dynamic>;
    final foods = <CiqualFood>[];
    for (final f in raw['foods'] as List) {
      final m = f as Map<String, dynamic>;
      // `per` vaut 100 partout aujourd'hui, mais on le LIT au lieu de le
      // supposer : un aliment ajouté avec une autre portion ne deviendra pas
      // un bug silencieux.
      final per = (m['per'] as num).toDouble();
      final carbsPer100g = (m['carbs'] as num).toDouble() * 100.0 / per;
      foods.add(CiqualFood(m['code'] as String, m['name'] as String, carbsPer100g));
    }
    return CiqualBase._(
      foods,
      {for (final f in foods) f.code: f},
      {for (final f in foods) f.code: normalize(f.name)},
    );
  }

  /// Lookup par code Ciqual. Null si le code n'existe pas dans la base —
  /// possible si le modèle hallucine un code malgré la liste fermée.
  CiqualFood? byCode(String code) => _byCode[code];

  /// Recherche insensible à la casse, aux accents et à la ponctuation :
  /// « pates » trouve « Pâtes », « boeuf » trouve « Bœuf ». Tous les mots de
  /// la requête doivent apparaître dans le libellé.
  List<CiqualFood> search(String query) {
    final words = normalize(query).split(' ').where((w) => w.isNotEmpty);
    if (words.isEmpty) return allFoods;
    return allFoods
        .where((f) =>
            words.every((w) => _normalizedNames[f.code]!.contains(w)))
        .toList();
  }

  /// Même normalisation que le filtre Node (tools/ciqual-to-nightscout.mjs) :
  /// minuscules, accents supprimés, ponctuation en espaces. Dart n'a pas de
  /// String.normalize('NFD') en standard ; pour le français, une table de
  /// remplacement suffit et évite une dépendance.
  static String normalize(String s) {
    const accents = {
      'à': 'a', 'â': 'a', 'ä': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'î': 'i', 'ï': 'i',
      'ô': 'o', 'ö': 'o',
      'ù': 'u', 'û': 'u', 'ü': 'u',
      'ç': 'c', 'œ': 'oe', 'æ': 'ae',
    };
    final sb = StringBuffer();
    for (final rune in s.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      if (accents.containsKey(ch)) {
        sb.write(accents[ch]);
      } else if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
        sb.write(ch);
      } else {
        sb.write(' ');
      }
    }
    return sb.toString().replaceAll(RegExp(r' +'), ' ').trim();
  }
}
