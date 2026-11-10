# Plan : harness autonome (10 nov. 2026)

Demande : Engram obligatoire, plan et tâches suivis, permissions auto-octroyées encadrées, pipeline plus autonome,
mise à jour automatique du kit, bug `checkpoint`. Un commit par sujet ; une PR claude-kit, une PR claude-kit-dashboard.

## Diagnostic du bug `checkpoint` (sujet 6)

Mesuré dans une session cloud, par appel direct de `/mcp` :

- `initialize`, `task_*` et `wait_for_answer` sur un id inconnu répondent en moins de 0,3 s ;
- `ask` ou `checkpoint`, qui attendent la réponse humaine environ 80 s côté serveur, reçoivent au bout de **30,1 s**
  un `502 Bad Gateway`, `text/plain`, corps `upstream request failed`, **sans** `Server: cloudflare` ni `Cf-Ray`.

La coupure vient donc du proxy sortant de la session cloud (délai de réponse de 30 s), pas de Cloudflare (100 s) ni du
serveur. La demande est quand même créée côté dashboard, mais son `request_id` est perdu : la session ne peut pas
attendre la réponse et l'utilisateur voit une validation orpheline.

**Correctif (dashboard)** : `checkpoint`, `ask` et `equip` attendent au plus `KIT_WAIT_SECONDS` (20 s par défaut) puis
répondent `PENDING request_id=<n>` ; `wait_for_answer` attend lui aussi au plus 20 s par appel. Les descriptions
d'outils passent de « ~80 s » à « ~20 s ». Les sessions locales n'y perdent rien (elles rappellent `wait_for_answer`).

## Sujets et fichiers

| # | Sujet | Fichiers |
|---|---|---|
| 1 | Engram obligatoire : fiche `content/projects/<dépôt>.md` créée par `/new-project` et `/adopt`, mise à jour à chaque avancée notable, vérifiée par `/handoff`, lue par `/resume` ; en cloud, `add_repo` (push) puis clone sans demander | `global/CLAUDE.md`, `global/skills/engram/SKILL.md`, `global/commands/{new-project,adopt,handoff,resume}.md`, `global/settings.json` (allow `add_repo`, `register_repo_root`) |
| 2 | Plan et tâches : `docs/plan.md` (ou la feuille de route existante) = source ; une tâche dashboard par élément ; `doing`/`done` au fil du travail ; `/resume` et `/handoff` réconcilient plan et `task_list` | idem + `templates/project/docs/plan.md` |
| 3 | Permissions auto-octroyées : `kit perms allow "<règle>" --reason "…"` écrit dans `.claude/settings.json` **du projet** et journalise dans `docs/memory/permissions.md` ; refus codés en dur (voir étendue ci-dessous) ; `kit perms list` | `scripts/kit.sh` (ou `scripts/perms.sh`), `global/CLAUDE.md`, `global/settings.json` (allow `kit perms *`, phrase `autoMode`) |
| 4 | Pipeline autonome (ci-dessous) | `global/commands/*.md`, `global/skills/team-builder/SKILL.md` |
| 5 | Mise à jour auto : hook global `SessionStart` (`startup` et `resume`) → `kit-autoupdate.sh` : `git pull --ff-only` (timeout 10 s, sans invite) puis `kit sync` si la révision a changé ; toujours `exit 0` ; en local au plus une fois toutes les 6 h | `scripts/hooks/kit-autoupdate.sh`, `scripts/lib.sh` (lien), `global/settings.json` |
| 6 | Réponse en moins de 30 s | dépôt `claude-kit-dashboard` (serveur MCP) |

### Étendue proposée pour le sujet 3

Autorisé sans demander (projet seulement, journalisé) : une règle **précise** pour une action de routine non
destructive (lecture, build, test, lint, format, outils de la stack du projet, `git` non destructif, `kit api … GET`,
outils MCP en lecture).

Refusé par le script :

- toute règle large : `Bash(*)`, `Bash`, un préfixe d'un seul mot générique suivi de `*` (`Bash(npm *)`, `Bash(git *)`,
  `Bash(curl *)`…), `Read(**)`, `Edit`/`Write` hors du projet, `mcp__*` sans nom d'outil ;
- toute règle qui recouvre une entrée `deny` ou `ask` du kit (secrets, `rm`, `sudo`, `push --force`, `reset --hard`,
  `docker run`, `wrangler deploy`, `kit secrets`…) ;
- secrets : `.env*`, clés, `sops`, `age`, `printenv`, `env` ;
- suppression et prod : `DELETE`, `TRIGGER`, `deploy`, `publish`, `push` vers `main` ;
- jamais de retrait d'un `deny` ni d'écriture dans `~/.claude/settings.json` (global = PR sur claude-kit, inchangé).

### Pipeline (sujet 4)

- **Validations groupées** : `/new-project` guidé passe de 7 validations à 4 (cadrage + stack ; plan + équipe ;
  identité ; `DEPLOY.md` avant toute création). Les phases sans choix (gabarit, secrets) s'enchaînent.
- **Exécution enchaînée** une fois le plan validé : lot → agent → PR → `code-reviewer` (+ `security-reviewer`) →
  `qa-tester` → vérification → tâche `done` → lot suivant, sans demander entre les lots. Arrêt et validation
  seulement pour : fusion, déploiement en prod, suppression, écart au plan, échec répété.
- **`/resume`** : si la prochaine action du relais est une tâche du plan validé et reste cohérente avec l'état réel,
  elle démarre sans attendre ; validation seulement pour une action irréversible ou hors plan.
- **`/handoff`** automatique en fin de travail notable (consigne globale), avec contrôle Engram et tâches.
- **`team-builder`** : ne recompose pas une équipe déjà en place si le travail ne change pas de nature.
- `checkpoint` `PENDING` : l'attente se fait par `wait_for_answer` ; pendant ce temps, seulement de la lecture.

## Script d'environnement « kit »

Inchangé : `git clone … || git -C ~/claude-kit pull --ff-only` puis `install.sh --cloud`. Le hook couvre les reprises
de session sans reconstruction de conteneur.

## Vérification

`bash -n` et `shellcheck` sur les scripts, `jq` sur les JSON, tests de `kit perms` (règles acceptées et refusées),
exécution du hook (dépôt à jour, réseau coupé, dépôt modifié), `kit doctor`. Côté dashboard : ses tests et un appel
`checkpoint` mesuré sous 30 s depuis cette session.
