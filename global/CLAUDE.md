# CLAUDE.md global

## Langue et style

Français ; code, noms et commentaires techniques en anglais. Résultat d'abord. Ambiguïté
coûteuse : une question ; sinon avance et signale l'hypothèse.

## Taille du projet

Lis `project.yaml` (absent : skill `project-size`). Annonce la taille (S, M, L) en une ligne ; l'utilisateur
corrige d'un mot.

## Exécution

- Plan en lots (`docs/plan.md`), un agent par lot, brief complet. Le fil principal fait les petites choses.
- Après un lot : vérifie diff, tests et build. Relecteurs : sur demande ; en L, une revue de sécurité avant la
  première mise en prod.
- Valide **dans le chat** seulement : le plan, la première mise en prod, une suppression, une migration de données
  en prod, un écart au plan, un double échec.
- Mode rapide (`mode: fast`, défaut en S) : pas de validation du plan, ni relecteurs, ni CSP au-delà des défauts ;
  au plus un designer et un dev front pour une interface ; validations seulement suppression, migration de données
  en prod, échec répété.
- Skill ou agent réellement manquant : `kit equip search`, installation `--project`.

## Secrets : règles strictes

- Ne lis, n'affiche ni ne copie jamais un `.env*`, une clé privée ou un jeton ; jamais de contournement du hook pour
  eux. Faux positif (champ jq, mot d'une doc) : contournement signalé.
- Commande avec secrets : `kit secrets run [-g] -- <commande>`. Variable manquante : son NOM (`kit secrets add NOM`),
  jamais sa valeur. Ne commite jamais de secret.
- Session cloud : pas de `kit secrets` ; `kit api` lit les jetons de l'environnement.
- `kit api` Coolify et Cloudflare (POST, PUT, PATCH, TRIGGER) autorisé : annonce, exécute, vérifie. DELETE interdit ;
  rotation de secret ou action hors `kit api` : validation explicite.

## Mémoire

Fin d'un lot ou de session : réécris `docs/memory/state.md` (fait, bloquant, suite) ; décision durable dans
`decisions.md`. `/handoff` sur demande.

## Qualité

- Lis avant d'écrire ; plus petit changement ; petits commits ; jamais `git push --force`.
- Avant de conclure : tests, lint et build, résultats réels.
- Dépendance : dernière stable vérifiée au registre.
- Pas de `docker build` pour vérifier.
- CI dans `.forgejo/workflows/`, jamais `.github/workflows/`.

## Permissions

Routine bloquée qui reviendra : `kit perms allow "<règle>" --reason "…"`. Fin de session : skill
`fewer-permission-prompts`, allows par `kit perms allow`. Réglages jamais édités à la main.
