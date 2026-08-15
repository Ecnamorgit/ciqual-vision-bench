// vision.dart — appel Mistral et contrat de sortie.
//
// C'est le seul fichier où la conception compte vraiment. Le reste du harnais
// n'est que de la plomberie ; ici, chaque phrase du prompt influence l'erreur
// que tu vas mesurer.
//
// Usage :
//   final vision = MistralVision(apiKey: const String.fromEnvironment('MISTRAL_API_KEY'));
//   final result = await vision.estimate(
//     imageBytes: bytes,
//     condition: ScaleCondition.plate,
//     plateDiameterMm: 260,
//     candidates: ciqual.allFoods,   // les 153 aliments
//   );

import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

enum ScaleCondition { none, card, plate }

/// Un aliment de la base Ciqual locale (ciqual-base.json).
class CiqualFood {
  final String code;
  final String name;
  final double carbsPer100g;
  CiqualFood(this.code, this.name, this.carbsPer100g);
}

class VisionResult {
  final String? foodName;
  final String? ciqualCode;
  final double? grams;
  final String? confidence; // 'high' | 'medium' | 'low'
  final String? reasoning;
  final String rawResponse;
  final int latencyMs;
  final String? error;

  VisionResult({
    this.foodName,
    this.ciqualCode,
    this.grams,
    this.confidence,
    this.reasoning,
    required this.rawResponse,
    required this.latencyMs,
    this.error,
  });

  bool get isUsable => error == null && grams != null && ciqualCode != null;
}

class MistralVision {
  final String apiKey;
  final String model;
  final Uri _endpoint = Uri.parse('https://api.mistral.ai/v1/chat/completions');

  MistralVision({required this.apiKey, this.model = 'mistral-small-latest'});

  // ---------------------------------------------------------------------------
  // Le prompt système.
  //
  // Choix de conception, chacun pour une raison :
  //
  // 1. On demande le POIDS, pas les glucides. Le modèle est mauvais en
  //    composition nutritionnelle et bon en géométrie ; Ciqual fait le reste.
  //    Lui demander les glucides directement, c'est cumuler deux erreurs.
  //
  // 2. On impose un choix dans une liste fermée de codes Ciqual. Sans ça, il
  //    invente des libellés qu'on ne peut pas rattacher à la table.
  //
  // 3. On demande un raisonnement AVANT le chiffre. Estimer un volume est une
  //    tâche à étapes (surface visible, hauteur, densité) ; forcer le chemin
  //    améliore nettement le résultat par rapport à un nombre sorti sec.
  //
  // 4. On demande une fourchette basse/haute en plus de la valeur centrale.
  //    Elle ne sert pas au calcul mais à repérer les cas où le modèle est
  //    perdu — un intervalle très large est un signal d'alerte exploitable.
  //
  // 5. On interdit explicitement de deviner quand la photo est inexploitable.
  //    Un refus honnête vaut mieux qu'un chiffre inventé : dans l'app finale,
  //    c'est ce qui déclenchera la saisie manuelle.
  // ---------------------------------------------------------------------------
  String _systemPrompt(List<CiqualFood> candidates) {
    final list = candidates
        .map((f) => '${f.code}|${f.name}')
        .join('\n');

    return '''
Tu es un assistant d'estimation de portions alimentaires. Un utilisateur
diabétique de type 1 photographie son assiette pour estimer le poids de ce
qu'il va manger.

TA TÂCHE : identifier l'aliment principal et estimer sa MASSE EN GRAMMES.
N'estime jamais les glucides toi-même — une table de composition s'en charge.

CONTRAINTES
- Choisis obligatoirement un code dans la liste fournie. Aucun autre code.
- Les aliments de la liste sont dans leur état CUIT, tel que servi.
- Estime le poids de la portion visible dans l'assiette, pas d'une portion type.
- Si la photo est floue, trop sombre, prise de trop loin, ou si l'aliment
  n'existe pas dans la liste : renvoie "unable" à true et n'invente rien.

MÉTHODE (suis ces étapes dans "reasoning")
1. Décris ce que tu vois et l'élément de référence dont tu disposes.
2. Estime la surface occupée par l'aliment.
3. Estime sa hauteur ou son épaisseur moyenne.
4. Déduis un volume, puis une masse en tenant compte de la densité typique
   de cet aliment.

RÉPONDS UNIQUEMENT EN JSON, sans texte autour, sans balises Markdown :
{
  "unable": false,
  "reasoning": "<ton raisonnement en 2-4 phrases, étapes 1 à 4>",
  "food_name": "<libellé exact repris de la liste>",
  "ciqual_code": "<code de la liste>",
  "grams": <nombre>,
  "grams_low": <borne basse plausible>,
  "grams_high": <borne haute plausible>,
  "confidence": "high" | "medium" | "low"
}

LISTE DES ALIMENTS AUTORISÉS (code|libellé)
$list
''';
  }

  String _scaleInstruction(ScaleCondition condition, int? plateDiameterMm) {
    switch (condition) {
      case ScaleCondition.none:
        return 'Aucune référence de taille dans la photo. Appuie-toi sur les '
            'objets courants visibles (couverts, verre, assiette) en gardant à '
            "l'esprit que leurs dimensions sont incertaines.";
      case ScaleCondition.card:
        return 'Une carte bancaire est posée à plat près de l\'assiette. Ses '
            'dimensions sont normalisées : 85,60 mm × 53,98 mm. Utilise-la '
            "comme référence d'échelle principale.";
      case ScaleCondition.plate:
        return 'Le diamètre intérieur de l\'assiette est de $plateDiameterMm mm. '
            "Utilise-le comme référence d'échelle principale.";
    }
  }

  Future<VisionResult> estimate({
    required Uint8List imageBytes,
    required ScaleCondition condition,
    int? plateDiameterMm,
    required List<CiqualFood> candidates,
  }) async {
    assert(condition != ScaleCondition.plate || plateDiameterMm != null,
        'plateDiameterMm est requis pour la condition plate');

    final stopwatch = Stopwatch()..start();
    final b64 = base64Encode(imageBytes);

    final body = jsonEncode({
      'model': model,
      'temperature': 0.1, // on veut de la reproductibilité, pas de créativité
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': _systemPrompt(candidates)},
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': _scaleInstruction(condition, plateDiameterMm),
            },
            {
              'type': 'image_url',
              'image_url': 'data:image/jpeg;base64,$b64',
            },
          ],
        },
      ],
    });

    try {
      final res = await http
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60));

      stopwatch.stop();

      if (res.statusCode != 200) {
        return VisionResult(
          rawResponse: res.body,
          latencyMs: stopwatch.elapsedMilliseconds,
          error: 'HTTP ${res.statusCode}',
        );
      }

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final content =
          decoded['choices'][0]['message']['content'] as String;

      // Ceinture et bretelles : malgré response_format, un modèle peut
      // encore encadrer sa réponse de ```json ... ```
      final cleaned = content
          .replaceAll(RegExp(r'^```(?:json)?\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .trim();

      final parsed = jsonDecode(cleaned) as Map<String, dynamic>;

      if (parsed['unable'] == true) {
        return VisionResult(
          rawResponse: content,
          latencyMs: stopwatch.elapsedMilliseconds,
          reasoning: parsed['reasoning'] as String?,
          error: 'unable',
        );
      }

      return VisionResult(
        foodName: parsed['food_name'] as String?,
        ciqualCode: parsed['ciqual_code']?.toString(),
        grams: (parsed['grams'] as num?)?.toDouble(),
        confidence: parsed['confidence'] as String?,
        reasoning: parsed['reasoning'] as String?,
        rawResponse: content,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      return VisionResult(
        rawResponse: '',
        latencyMs: stopwatch.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }
}

/// Convertit un poids estimé en glucides via la table Ciqual.
/// Volontairement séparé de l'appel : c'est de l'arithmétique, pas de l'IA,
/// et ça doit rester vérifiable à la main.
double carbsFor(CiqualFood food, double grams) =>
    food.carbsPer100g * grams / 100.0;
