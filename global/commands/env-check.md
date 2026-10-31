---
description: Vérifie que les variables d'environnement du projet existent dans les secrets chiffrés (noms seulement)
argument-hint: "[environnement, défaut : dev]"
---

Vérifie l'environnement du projet courant. Environnement demandé : "$ARGUMENTS" (s'il est vide, utilise `dev`).

1. Lance `kit secrets check` (ajoute `-e <env>` si l'environnement n'est pas `dev`). Il compare `.env.example` aux secrets chiffrés et n'affiche que des noms.
2. Lance `kit secrets list` puis `kit secrets list -g` pour montrer ce qui existe, noms seulement.
3. Pour chaque variable manquante, donne à l'utilisateur la commande exacte à lancer lui-même dans son terminal : `kit secrets add NOM` (ou avec `-g` si c'est une clé partagée comme `CLOUDFLARE_API_TOKEN`).
4. Si une variable est « global seulement », rappelle qu'il faut `kit secrets run -g -- <commande>`.

Interdits : lire un fichier `.env*`, demander une valeur dans le chat, afficher une variable d'environnement. Conclus par un tableau court : variable, présente ou non, portée (projet/global).
