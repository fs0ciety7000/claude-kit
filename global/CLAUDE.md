# CLAUDE.md global

## Langue et style

Français ; code, noms et commentaires techniques en anglais. Résultat d'abord. Instruction
ambiguë et coûteuse à refaire : une question ; sinon avance et signale l'hypothèse.

## Taille du projet

Lis `project.yaml`. Absent : skill `project-size`. Annonce la taille (S, M, L) avec une ligne de justification ;
l'utilisateur corrige d'un mot.

## Exécution

- Plan en lots (`docs/plan.md`), un agent par lot, brief complet. Le fil principal fait les petites choses.
- Après un lot : vérifie toi-même diff, tests et build. Pas de relecture par tâche ; relecteurs seulement en L ou
  sur demande.
- Valide **dans le chat**, seulement pour : le plan, la première mise en prod d'un projet, une suppression, une
  migration de données en prod, un écart au plan, un échec répété deux fois.
- Skill ou agent réellement manquant : `kit equip search`, installation `--project`. Sinon silence.

## Secrets : règles strictes

- Ne lis, n'affiche et ne copie jamais un `.env*`, une clé privée ou un jeton. Le hook bloque les cas évidents ; ne le
  contourne jamais pour un vrai fichier de secrets. Faux positif (nom de champ jq, mot dans une doc,
  aucun secret lu) : contournement autorisé, signalé.
- Commande avec secrets : `kit secrets run [-g] -- <commande>`. Variable manquante : dis son NOM (`kit secrets add
  NOM`), jamais la valeur demandée dans le chat. Ne commite jamais de secret.
- Session cloud : pas de `kit secrets` ; `kit api` lit les jetons de l'environnement.
- `kit api` Coolify et Cloudflare (POST, PUT, PATCH, TRIGGER) autorisé : annonce, exécute, vérifie. DELETE interdit ;
  rotation de secret ou action hors `kit api` : validation explicite.

## Mémoire

Fin d'un lot ou de la session : réécris `docs/memory/state.md` (fait, bloquant, prochaines étapes) ;
décision durable dans `decisions.md`. `/handoff` sur demande ou en fin de session.

## Qualité

- Lis avant d'écrire ; plus petit changement ; petits commits ; jamais `git push --force`.
- Avant de conclure : tests, lint et build, résultats réels.
- Dépendances : dernière version stable vérifiée au registre, jamais de mémoire.
- Pas de `docker build` pour vérifier : le build du projet suffit.

## Permissions

Routine bloquée qui reviendra : `kit perms allow "<règle>" --reason "<pourquoi>"`. Fin de session : skill
`fewer-permission-prompts`, ses allows via `kit perms allow`. Jamais d'édition à la main des réglages.
