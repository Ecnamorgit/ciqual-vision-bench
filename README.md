# Estimation de portions par photo — harnais de mesure

Un instrument pour répondre à une question simple, en français, avec des
chiffres plutôt que des impressions :

> **Un modèle de vision peut-il estimer le poids d'une assiette assez
> précisément pour être utile à un diabétique de type 1 qui compte ses
> glucides ?**

Ce dépôt ne contient pas une application. Il contient le protocole, le code
et les résultats bruts d'une campagne de mesure sur des repas réels, avec
vérité terrain à la balance de cuisine.

---

## ⚠️ Avertissement

**Ceci n'est pas un dispositif médical.** Rien ici ne doit servir à décider
d'une dose d'insuline.

L'estimation de glucides par photo comporte une erreur qui, convertie en
unités, peut provoquer une hypoglycémie sévère. Ce projet existe justement
pour **mesurer** cette erreur, pas pour prétendre qu'elle est négligeable.

Le seul usage défendable de ce type d'outil est d'assister une estimation
humaine, jamais de la remplacer. Toute décision thérapeutique reste celle de
la personne concernée et de son équipe soignante.

Aucune garantie, d'aucune sorte. Voir `LICENSE`.

---

## Pourquoi ce projet existe

Les applications de comptage de glucides par photo se multiplient, mais
aucune ne publie son erreur mesurée sur des plats français avec une vérité
terrain vérifiable. La seule référence publique solide reste **GoCARB**, un
projet européen dont l'évaluation clinique a donné une erreur absolue moyenne
de 12,28 g contre 27,89 g pour les patients estimant à l'œil.

Cette barre est donc l'objectif : **faire mieux qu'un humain entraîné**.

Si les mesures montrent qu'on y arrive, l'approche mérite une vraie
application. Sinon, ce dépôt aura au moins documenté un échec utile — et
c'est déjà plus que ce que publient la plupart des projets du domaine.

---

## Ce qu'on mesure

Trois conditions comparées sur les mêmes repas :

| Condition | Référence d'échelle fournie au modèle |
|---|---|
| `none` | Aucune — référence de base |
| `card` | Carte bancaire (ISO/IEC 7810 ID-1 : 85,60 × 53,98 mm) |
| `plate` | Diamètre de l'assiette, déclaré en millimètres |

Métrique principale : **l'erreur en grammes de glucides**, pas en grammes de
nourriture — c'est elle qui se convertit en unités d'insuline.

Voir [`SPEC.md`](SPEC.md) pour le protocole détaillé et les biais à éviter.

---

## Conception

Le point de départ est que **le modèle ne doit pas estimer les glucides**.
Les modèles de vision sont médiocres en composition nutritionnelle et
corrects en géométrie. On leur demande donc uniquement d'identifier l'aliment
et d'estimer sa masse ; la conversion en glucides passe par une table de
composition officielle. Deux étapes séparées, deux erreurs isolables.

Le choix des aliments est contraint à une liste fermée de codes Ciqual, ce
qui rend l'identification vérifiable et empêche le modèle d'inventer des
libellés inexploitables.

---

## Résultats

*(à publier — campagne en cours)*

Les mesures brutes seront versées ici en CSV anonymisé : condition, aliment,
poids estimé, poids réel, erreur. Sans les photos.

---

## Données

La table de composition nutritionnelle utilisée est **Ciqual**, publiée par
l'**Anses** (Agence nationale de sécurité sanitaire de l'alimentation, de
l'environnement et du travail).

- Source : https://ciqual.anses.fr
- Version : Ciqual 2025
- Licence : **Licence Ouverte / Open Licence (Etalab)**, via data.gouv.fr

Le fichier `assets/ciqual-base.json` est un sous-ensemble dérivé de cette
table : 153 aliments courants, en forme cuite, valeurs pour 100 g. Les
teneurs sont arrondies à l'entier — contrainte imposée par AndroidAPS, qui
attend des entiers sur les champs `carbs`, `protein`, `fat` et `energy`.

**Attention à la forme cuite.** Le boulgour cru titre 65,8 g de glucides pour
100 g contre 24,1 g une fois cuit. Un facteur 2,7. Ce sous-ensemble ne
contient que des formes cuites, cohérent avec une pesée dans l'assiette. Si
tu pèses au paquet avant cuisson, il ne te convient pas.

---

## Outils annexes

`tools/ciqual-to-nightscout.mjs` importe un sous-ensemble de Ciqual dans la
base `food` d'une instance Nightscout, où AndroidAPS la lit via son onglet
Aliments. Utilisable indépendamment du reste du projet.

Deux contraintes découvertes dans le code source d'AAPS et absentes de sa
documentation, notées ici pour épargner la recherche à d'autres :

- `carbs`, `protein`, `fat` et `energy` doivent être des **entiers**. Une
  décimale déclenche `NumberFormatException` côté AAPS et invalide tout le
  lot. Seul `portion` accepte un décimal. (`core/nssdk/…/RemoteFood.kt`)
- AAPS ne recharge la collection `food` qu'**un cycle de synchronisation sur
  cinq**, avec un compteur persisté entre les redémarrages. Après un import,
  il faut déclencher une synchronisation complète pour voir les aliments.
  (`plugins/sync/…/LoadFoodsWorker.kt`)

---

## Contribuer

Les mesures d'autres personnes sont les bienvenues, en particulier sur des
cuisines que je ne mange pas. Le protocole tient en une page ; l'important
est de respecter l'ordre des étapes, notamment de **peser après avoir vu
l'estimation**, jamais avant.

Aucune photo ne doit être partagée dans une contribution.
