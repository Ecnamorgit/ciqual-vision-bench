# Harnais de mesure — estimation de poids par photo

## L'objectif, et ce qu'il n'est pas

Ce n'est **pas** une v0 de l'app. C'est un instrument de mesure jetable, dont
le seul but est de répondre à trois questions en une trentaine de repas :

1. Mistral sait-il identifier correctement un plat français ?
2. Quelle est son erreur d'estimation de poids, en grammes ?
3. Laquelle des trois références d'échelle réduit le plus cette erreur ?

Quand tu auras les réponses, tu jettes ce code et tu construis la vraie app
en sachant ce qui marche. Si tu commences à ajouter des graphes, un thème ou
un historique joli, tu es en train de construire la mauvaise chose.

**Critère d'arrêt** : 30 repas enregistrés. Pas 30 écrans terminés.

---

## Le protocole, et pourquoi cet ordre

L'ordre des étapes n'est pas cosmétique, il conditionne la validité de la mesure.

```
1. PHOTO          — tu photographies l'assiette
2. CONDITION      — tu déclares la référence d'échelle utilisée
3. ESTIMATION     — l'app appelle Mistral et AFFICHE le résultat
4. PESÉE          — tu saisis le poids réel lu sur la balance
5. ENREGISTREMENT — l'app calcule et stocke l'erreur
```

Deux règles absolues :

**Le modèle ne voit jamais le poids réel.** Évident, mais facile à casser en
voulant « aider » le prompt.

**Tu pèses APRÈS avoir vu l'estimation, jamais avant de la demander.** Si tu
connais déjà le poids quand tu déclenches l'appel, tu vas inconsciemment
cadrer la photo différemment. C'est un biais réel et il suffit à invalider
trente mesures.

Corollaire pratique : tu sers ton assiette, tu photographies, tu lances
l'estimation, **ensuite** tu poses l'assiette sur la balance. Ça s'intègre à
ce que tu fais déjà puisque tu pèses dans l'assiette.

---

## Les trois conditions à comparer

Chaque repas est enregistré sous une condition, que tu fais tourner :

| Code | Condition | Ce qu'on envoie au modèle |
|---|---|---|
| `none` | Photo seule | Rien de plus — la référence de base |
| `card` | Carte bancaire posée à plat à côté de l'assiette | On indique qu'une carte ISO ID-1 (85,60 × 53,98 mm) est visible |
| `plate` | Assiette de diamètre connu | On donne le diamètre en mm |

Fais-en **dix de chaque**, en alternant, pas dix d'affilée. Sinon tu confonds
l'effet de la condition avec l'effet de la semaine (tu manges différemment le
lundi et le samedi, et tu photographies mieux au bout de dix essais).

Mesure tes assiettes au mètre ruban une fois pour toutes et note les
diamètres. C'est un investissement de cinq minutes.

---

## Modèle de données

Une seule table. Résiste à l'envie de normaliser, c'est jetable.

```sql
CREATE TABLE measurement (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at    INTEGER NOT NULL,     -- epoch ms
  photo_path    TEXT    NOT NULL,     -- chemin local
  condition     TEXT    NOT NULL,     -- 'none' | 'card' | 'plate'
  plate_mm      INTEGER,              -- rempli si condition = 'plate'

  -- ce que le modèle a répondu
  model_name    TEXT    NOT NULL,     -- 'mistral-small-4' etc.
  raw_response  TEXT    NOT NULL,     -- JSON brut, pour rejouer plus tard
  est_food      TEXT,                 -- libellé identifié
  est_ciqual    TEXT,                 -- code Ciqual proposé
  est_grams     REAL,                 -- poids estimé
  est_carbs     REAL,                 -- glucides déduits via Ciqual
  est_confidence TEXT,                -- 'high' | 'medium' | 'low'
  latency_ms    INTEGER,

  -- la vérité
  true_grams    REAL,                 -- balance
  true_ciqual   TEXT,                 -- code que TU aurais choisi
  true_carbs    REAL,                 -- calculé depuis Ciqual

  -- dérivé, calculé à l'insertion
  food_correct  INTEGER,              -- 0/1 : identification juste ?
  grams_error   REAL,                 -- est_grams - true_grams
  carbs_error   REAL                  -- est_carbs - true_carbs
);
```

`raw_response` est le champ le plus important du lot. Il te permettra de
rejouer l'analyse sans refaire les repas, par exemple quand tu voudras
comparer Mistral et Claude sur les mêmes photos.

---

## Ce qu'on mesure vraiment

L'erreur en grammes est un indicateur intermédiaire. **La métrique qui compte
est l'erreur en glucides**, parce que c'est elle qui se traduit en unités
d'insuline.

```
erreur_glucides = |est_carbs - true_carbs|
erreur_insuline = erreur_glucides / I:C        (I:C = 10 chez toi)
```

Repères pour lire tes résultats :

- **MAE glucides < 10 g** → meilleur que l'estimation humaine moyenne
  (GoCARB : 12,28 g contre 27,89 g pour les patients). Ça vaut le coup.
- **10 à 20 g** → utile comme garde-fou, pas comme source de bolus
- **> 20 g** → l'approche photo seule ne suffit pas, il faut repenser

Regarde aussi la **distribution**, pas seulement la moyenne. Un modèle qui se
trompe de 5 g quatre fois sur cinq et de 60 g la cinquième est plus dangereux
qu'un modèle qui se trompe de 15 g à chaque fois : c'est l'erreur maximale qui
te met en hypo, pas la moyenne.

Note enfin le **biais** (moyenne signée, pas absolue). Un modèle qui
sous-estime systématiquement est corrigeable par un facteur ; un modèle qui
part dans les deux sens ne l'est pas.

---

## Structure Flutter à construire

```
lib/
  main.dart          — 3 écrans, navigation basique
  vision.dart        — client Mistral + prompt   [FOURNI]
  store.dart         — sqflite + export CSV
  ciqual.dart        — chargement de l'asset, lookup par code
assets/
  ciqual-base.json   — tes 153 aliments
```

Trois écrans, pas plus :

**Capture** — bouton photo (`image_picker`), sélecteur de condition, champ
diamètre si `plate`, bouton « Estimer ».

**Résultat** — affiche l'estimation du modèle, puis un champ « poids réel » et
un sélecteur d'aliment Ciqual pour la vérité terrain. Bouton « Enregistrer ».

**Stats** — nombre de mesures, MAE glucides globale et par condition, taux
d'identification correcte, bouton « Exporter CSV ».

Dépendances : `image_picker`, `http`, `sqflite`, `path_provider`, `share_plus`.
Rien d'autre. Pas de state management, `setState` suffit largement.

---

## Sécurité de la clé API

Ne mets **pas** ta clé Mistral en dur dans le code. Passe-la par
`--dart-define` :

```bash
flutter run --dart-define=MISTRAL_API_KEY=xxx
```

```dart
const apiKey = String.fromEnvironment('MISTRAL_API_KEY');
```

C'est un harnais local, mais l'habitude se prend maintenant — et une clé dans
un dépôt Git y reste même après suppression du commit.

---

## Notes RGPD, à garder en tête dès maintenant

Les photos de tes repas, associées à ta glycémie, sont des données de santé au
sens de l'article 9. Pour un usage strictement personnel, tu es hors champ du
RGPD (exemption domestique). Mais si l'app devient un jour distribuable :

- les photos partent chez Mistral, hébergé en UE — c'est le bon choix
- il faudra un consentement explicite, une durée de conservation, une purge
- pense dès maintenant à ne stocker les photos qu'en local

Ça ne change rien au harnais, mais ça évitera de tout redécouvrir plus tard.
