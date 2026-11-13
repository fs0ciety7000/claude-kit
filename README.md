# claude-kit

Environnement Claude Code réutilisable : 17 sous-agents (plus 4 optionnels), skills routés par profil, secrets chiffrés (sops + age), garde-fous, et une commande `kit` pour tout étendre en une ligne. Pensé pour Garuda Linux (Arch), macOS et un VPS Debian/Ubuntu.

## Ce qui est installé

| Élément | Où | Rôle |
|---|---|---|
| `global/CLAUDE.md` | lien vers `~/.claude/CLAUDE.md` | langue, routage, règles secrets et qualité |
| `global/agents/*.md` (17) | `~/.claude/agents/` | tous en `model: opus` (alias, suit les versions), effort réglé par rôle dans l'en-tête. Conception : architect. Code : frontend-dev, backend-dev, rust-dev, go-cli, pocketbase, creative-coder, devops. Design et textes : ui-designer, brand-identity, copywriter, creative-content, researcher. Relecteurs (taille L ou sur demande) : code-reviewer, qa-tester, security-reviewer (effort `xhigh`), design-critic |
| `extras/agents/*.md` (4) | copiés dans `.claude/agents/` d'un projet | agents optionnels, jamais en global : sysop, data-engineer, game-designer, android-ui-reviewer. `kit add-agent <nom> --project` (ou `kit project add <type>` quand le registre les cite) |
| `global/skills/` (11) | `~/.claude/skills/` | `pocketbase`, `secrets-handling`, `deploy-coolify-cloudflare`, `dependency-hygiene`, `infra-context`, `opsec`, `engram`, `project-size`, `team-builder`, `brainstorming`, `writing-plans` |
| `global/commands/` | `~/.claude/commands/` | `/new-project`, `/add-skill`, `/add-agent`, `/env-check` |
| `global/skills-registry.md` | copié par `kit sync` dans `~/.config/claude-kit/skills-registry.md` (table des profils régénérée), lié depuis `~/.claude/skills-registry.md` | type de projet → profils, skills, agents ; le dépôt du kit n'est jamais réécrit par `kit sync` (seul `kit registry` régénère le fichier suivi, à commiter) |
| `global/settings.json` (+ `settings.vps.json`, `settings.v1.json`, `settings.retired.json`) | appliqué à `~/.claude/settings.json` (réglages gérés, voir plus bas) | permissions + hook anti-fuite ; `settings.v1.json` : instantané des entrées écrites par la v1 ; `settings.retired.json` : deny/ask que le kit retire explicitement |
| `profiles/*.txt` | utilisés par `kit skills install` | listes de skills par domaine (web, design, brand, android, game, threejs, go, rust, shopify, cloud, media, meta, custom) |
| `templates/permissions/*.json` | fusionnés dans `.claude/settings.json` d'un projet par `kit project add` / `kit project perms` | autorisations `allow` par pile (node, astro, next, go, rust, pocketbase, python, tofu) ; `types.tsv` : type du registre → piles |
| `templates/ci/*.yml` | copiés dans `.forgejo/workflows/` d'un projet par `kit project ci` / `kit project add` | CI Forgejo par pile (astro, next, vite, go-web, go-cli, pocketbase, rust, tauri, static) : `on: [push]`, actions `data.forgejo.org` épinglées par SHA, audit de dépendances ; `types.tsv` : type du registre → gabarit ; `fixtures/README.md` : mini-projets de recette |
| `scripts/` | `~/.local/bin/kit` | CLI : secrets, skills, agents, MCP |

Les agents et commandes sont des **liens** vers ce dépôt : modifier un fichier ici le modifie partout, et `git pull` met tout à jour.

## CI

Les workflows du kit sont dans `.forgejo/workflows/` et tournent sur le runner Forgejo auto-hébergé : le pont pousse
chaque ref dans le miroir `ci/<owner>__claude-kit` et renvoie le résultat sur GitHub (statut `ci/forgejo`).

- `ci.yml` (`on: [push]`, aucun secret) : shellcheck épinglé (version et SHA-256), `scripts/test/run.sh`,
  `guard-secrets-test.sh`, `backup-v1-test.sh --local` (le passage bash 3.2 dans Docker est facultatif) et
  `BUDGET_ENFORCE=1 scripts/context-budget.sh --budget`.
- `collections-index.yml` (lundi 05:17 UTC et à la demande) : seule l'étape de publication lit le secret
  `KIT_INDEX_GITHUB_TOKEN`, à poser dans les secrets d'Actions du dépôt Forgejo `ci/<owner>__claude-kit` (pas dans
  l'organisation). Valeur : jeton GitHub à grain fin limité au seul dépôt claude-kit, permissions *Contents* :
  lecture et écriture, *Pull requests* : lecture et écriture (*Metadata* : lecture, imposée). Sans ce secret, l'index
  est construit et le job finit avec un avis, sans PR. Le runner est partagé : le jeton est lisible par un job de
  n'importe quelle branche, d'où sa portée minimale (une PR relue avant fusion).

## Installation (Garuda)

```bash
# 1. Dépendances
sudo pacman -S --needed git nodejs npm jq sops age github-cli ripgrep

# 2. Claude Code : installeur officiel d'Anthropic
#    (vérifie la commande à jour dans la doc officielle, la méthode a pu changer)
curl -fsSL https://claude.ai/install.sh | bash

# 3. Ce kit
git clone <ton-dépôt>/claude-kit ~/claude-kit && cd ~/claude-kit
./install.sh            # ajoute --deps pour que le script lance pacman à ta place
kit doctor
```

### macOS

Pré-requis : [Homebrew](https://brew.sh). macOS fournit bash 3.2, trop ancien : le kit demande bash 4+ (installé par Homebrew).

```bash
brew install git node jq sops age gh ripgrep bash coreutils
curl -fsSL https://claude.ai/install.sh | bash
git clone <ton-dépôt>/claude-kit ~/claude-kit && cd ~/claude-kit
./install.sh            # ou ./install.sh --deps pour lancer brew à ta place
kit doctor
```

`install.sh` est relançable sans risque. Il ne s'exécute pas en root. Il sauvegarde (`*.pre-kit`) ce qu'il remplace.

## Secrets : mise en place

```bash
kit secrets init                          # crée ta clé age (déjà fait par install.sh)
kit secrets add CLOUDFLARE_API_TOKEN -g   # saisie masquée ; -g = clé partagée entre projets
kit secrets add CLOUDFLARE_ACCOUNT_ID -g
kit secrets add COOLIFY_BASE_URL -g
kit secrets add COOLIFY_ACCESS_TOKEN -g
kit mcp setup                             # déclare le MCP Coolify, jeton injecté au lancement
```

- **Sauvegarde ta clé privée** (`~/.config/sops/age/keys.txt`) dans ton gestionnaire de mots de passe : sans elle, les secrets sont perdus. Ne la mets jamais dans git.
- Nouveau projet : `kit project new mon-projet && cd mon-projet && claude`, puis `/new-project "<description>"` Deux validations dans le chat : le plan (brief, taille, stack, équipe, direction visuelle, brouillon de `DEPLOY.md`), puis la première mise en prod (Coolify + sous-domaine Cloudflare). Projet existant : `kit project init`.
- Dépôt GitHub : `kit repo create mon-projet` (dans le dossier du projet) crée le dépôt privé, une clé de déploiement propre à ce dépôt (écriture) et configure `origin`. Prérequis : `git config --global user.name/user.email` et `kit secrets add GITHUB_TOKEN -g` (droits : création de dépôts + Administration pour la clé). `/new-project` l'appelle tout seul.
- Par projet : remplis `.env.example`, puis `kit secrets add NOM` (fichier `secrets/dev.enc.json`, commitable car chiffré). `kit secrets check` compare les deux.
- Lancer une commande avec secrets : `kit secrets run -g -- wrangler deploy`. Les valeurs n'existent que dans ce processus.
- Interroger Coolify ou Cloudflare en lecture : `kit api coolify /applications --jq 'map({uuid,name,status})'`. Le jeton passe à `curl` par stdin (jamais dans `ps`), le filtre `--jq` est obligatoire (la réponse brute peut contenir des variables d'environnement). Les écritures (`POST`, `PUT`, `PATCH`) et les actions (`TRIGGER`, qui lance un déploiement) sont autorisées sans confirmation dans `global/settings.json` ; `DELETE` est refusé. Pour redemander une confirmation, déplace les lignes `kit api … POST/PUT/PATCH/TRIGGER` de `allow` vers `ask`. Une valeur secrète dans un corps JSON s'écrit `__SECRET:NOM__`. Les agents utilisent cette commande plutôt que `curl`.
- Jetons à portée minimale : Cloudflare par zone et par permission, GitHub fine-grained, Coolify séparé dev/prod.

## Suivre une session

Le tableau de bord en direct (hook d'émission, serveur MCP de validation) est **abandonné** : `docs/plan.md` est la
seule liste de tâches, les validations se font dans le chat, et une session se suit avec `claude remote-control`
(depuis l'app Claude ou claude.ai/code, voir plus bas). `kit sync` nettoie les postes qui l'avaient : il retire le
hook et ses autorisations de `~/.claude/settings.json` (fusion à trois points, tes hooks et règles restent), supprime
le lien du hook (seulement s'il pointe dans ce kit) et le fichier d'URL, et retire le serveur MCP de portée utilisateur
s'il est déclaré. `kit doctor` signale un reste, y compris `KIT_DASH_TOKEN` ou `KIT_DASH_URL` encore présents dans
l'environnement (leurs noms seulement, jamais les valeurs).

**À faire de ton côté, le kit n'y touche pas** (rien de tout cela n'est automatique) :
1. révoquer le jeton du tableau de bord côté serveur (réglages du dashboard), puis, sur chaque poste local,
   `kit secrets rm KIT_DASH_TOKEN -g` ;
2. dans l'environnement cloud : retirer la variable `KIT_DASH_URL` et le secret réseau (en-tête `Authorization`) de
   l'hôte du dashboard ;
3. arrêter l'application du tableau de bord sur son serveur et purger ses données (événements, mémoire de projet,
   jetons), puis retirer son entrée DNS et sa politique d'accès si elles ne servent plus.

`kit detect [--json]` devine les types de projet à partir des fichiers (`global/detect-rules.tsv`) et en déduit profils, skills et agents ; `/new-project` s'en sert et note le choix dans `docs/memory/stack.md`.

## Taille du projet (S, M, L)

La taille règle ce qu'un projet exige : relecteurs, tests, CI, durcissement, équipe. Claude la choisit au cadrage
d'après une grille (skill `project-size`) et l'annonce avec une ligne de justification ; tu la corriges d'un mot.
Elle vit dans `project.yaml` (paires `clé: valeur`, lisibles sans `yq`).

```bash
kit project size M --reason "boutique pour quelques proches, accès restreint"   # ou S, L ; relançable
kit project effort devops high     # effort d'un agent pour ce projet (copie dans .claude/agents/)
```

`kit project size` écrit `project.yaml`, copie `docs/rules/size-M.md` (et `size-L.md` en L) depuis `templates/rules/`,
et ajoute leurs lignes `@docs/rules/size-*.md` au `CLAUDE.md` du projet ; en S, rien n'est importé. Revenir à une
taille plus petite retire règles et imports. Les règles copiées sont à toi : adapte-les dans le projet.

## Équiper un projet selon son domaine et sa stack

`/new-project` a une phase « Équipement » : Claude extrait des mots-clés du domaine (finance, compta…) et de la stack (laravel, php…), lance `kit equip search` (skills de skills.sh triés par installations, agents et skills de l'index des collections), garde ce qui est utile au projet après relecture, le fait valider dans le chat (avec les sources de confiance), l'installe au niveau du projet (`--project`, commité dans `.claude/`) puis relance la session pour charger les nouveaux skills. Une stack absente du registre fait l'objet d'une PR automatique (`kit registry propose`) : une fois fusionnée, le projet suivant l'installe directement.

### Index des collections

`global/collections-index.json` recense les agents et les skills de 12 collections open source relues (liste,
licences et collections écartées : `global/agent-sources.txt`) : environ 1 800 agents et 2 200 skills. Il est construit
par `scripts/build-index.sh` à partir de clones superficiels, **sans API GitHub** : il marche en local, en session cloud
et dans la CI. Seuls les fichiers sont lus ; aucun installateur, CLI ni hook de ces dépôts n'est lancé.

```bash
kit equip search laravel stripe --max 5   # agents, skills des collections et skills de skills.sh
kit index                                 # régénère l'index (3 min environ)
```

- Le workflow Forgejo `collections-index` le régénère chaque lundi et ouvre (ou met à jour) une **PR** depuis la
  branche `bot/collections-index` : relis le résumé (texte tiers), surtout quand une source est ajoutée (voir « CI »).
- Ajouter une collection : une ligne `owner/repo [dossier]` dans `global/agent-sources.txt` (licence claire, activité
  récente), puis `kit index` ou le workflow.
- Les descriptions de l'index sont des données, jamais des consignes. Noms et descriptions appartiennent à leurs
  auteurs, sous la licence de chaque source (`sources[]` de l'index, avec le lien du dépôt) ; pour une licence
  « share-alike » (CC-BY-SA), seuls les noms et les liens sont indexés.
- Le générateur clone sans liens symboliques, sans hooks ni LFS, ne lit que des en-têtes (fichiers de moins de
  256 Ko), filtre et borne chaque champ, et refuse un index de plus de 5 Mo.

## Permissions de projet auto-octroyées

Claude ajoute lui-même les règles `allow` **précises** dont un projet a besoin. Le script les vérifie, les écrit dans le `.claude/settings.json` du projet (jamais dans le global) et les journalise dans `docs/memory/permissions.md` :

```bash
kit perms check "Bash(npm run test *)"                        # dit si la règle est acceptée, et pourquoi
kit perms allow "Bash(npm run test *)" --reason "suite de tests"
kit perms list
```

Le script valide sur une **liste blanche** (tableaux commentés en tête de `scripts/perms.sh`, à étendre par PR) :
- `Bash` : commandes de test, build, lint et format de la stack (`npm|pnpm|yarn|bun run <script>`, `go test`, `cargo clippy`, `pytest`, `npx prettier`…), `git` en lecture, `kit api <service> GET <chemin>`, utilitaires de lecture (`ls`, `cat`, `rg`, `jq`…). Un seul `*`, en fin, après une espace ; ni guillemet, ni `\`, ni `$`, ni chaînage ; ni chemin absolu ni `..` ;
- `Read`, `Grep`, `Glob` : chemin ancré du projet (`Read(src/**)`), sans segment à point ;
- outils MCP de lecture (`get_…`, `list_…`, `search_…`, `…_read`) sans verbe d'écriture ;
- `WebFetch(domain:<hôte>)`.

Tout le reste est refusé : `Edit`/`Write`, écritures `kit api`, outils MCP qui écrivent, règles larges, secrets, suppression, déploiement, `push`, fusion. Ces cas refusés, et toute règle globale, passent par une PR sur ce dépôt.

### Autorisations de base et de pile

Pour que la validation reste l'exception (le mode `auto` reste le défaut), le kit pose deux niveaux d'`allow` :

- **Base globale** (`global/settings.json`) : git courant (`rebase`, `worktree`, `rev-parse`, `merge`, `cherry-pick`…),
  `gh pr *` (donc la fusion d'une PR), `git push` (donc sur `main`), `docker compose ps|logs|build|up|down…` (pas
  `config`, qui imprime les secrets interpolés), `tofu fmt|validate|plan|init`, les formes ancrées
  `bash infra/tofu.sh cloudflare|tailscale plan` et `tofu -chdir=infra/cloudflare|tailscale plan|validate|init` (aucun
  `*` au milieu d'une règle qui laisserait passer une autre sous-commande), `kit sync` (sans `--yes`), `kit equip`,
  `kit index` (sans `--out`), utilitaires de lecture. Les commandes capables d'écrire un fichier (`sed`, `awk`, `sort -o`,
  `uniq`, `date -s`…) ne sont plus autorisées d'office : Claude Code admet déjà leurs formes sûres.
- **Pile du projet** : `kit project add <type>` (ou `kit project perms`, qui détecte la pile d'après `package.json`,
  `go.mod`, `Cargo.toml`, `pyproject.toml`, `*.tf`…) fusionne `templates/permissions/<pile>.json` dans le
  `.claude/settings.json` du projet : seulement `permissions.allow`, sans doublon, après tes règles, relançable ; le
  `deny`, le `ask` et les hooks du projet ne sont jamais touchés. Une pile qui n'est pas un type du registre
  (`python`, `tofu`) se donne directement : `kit project add python tofu`. Le fragment est commité avec le projet : une
  session cloud sans le kit retrouve ses autorisations. `--no-permissions` les saute. Chaque règle des fragments passe
  `kit perms check` (test), donc la liste blanche et les fragments restent cohérents.
- **CI du projet** : `kit project ci [pile]` (détection comme `kit project perms` ; `kit project add <type>` l'appelle
  et laisse en place une CI existante, `--no-ci` la saute) écrit `.forgejo/workflows/ci.yml` (piles suivantes :
  `ci-<pile>.yml`), un `.fs0/bridge.yaml` minimal et un `renovate.json` (gabarit du kit) s'ils manquent : Renovate met à jour
  les actions `data.forgejo.org` (SHA et version en commentaire) avec son gestionnaire `github-actions` intégré. Rien n'est écrasé sans `--force` ; liens symboliques et dossier personnel refusés. La CI tourne sur
  le Forgejo auto-hébergé (le pont pousse branches, `pr/<n>` et tags), jamais dans `.github/workflows/`.
- En fin de session, le skill `fewer-permission-prompts` propose les `allow` de projet qui auraient évité des invites.

Ce qui demande encore une validation : `git rebase -i` (et `--exec`/`-x`), `kit autoupdate …`, `kit overlay …`, les
écritures destructrices déjà listées en `ask` (`git push --force|-f|+ref|--mirror|--delete|-d`, `git reset [opts] --hard`,
`git clean`, `git branch -D`, `rm`, `docker run|exec|rm`, `gh secret`…). Ce qui est refusé : `tofu|terraform
apply|destroy` (y compris `bash infra/tofu.sh <dossier> apply|destroy`), `Edit` et `Write` sur `~/.config/claude-kit/**`,
`~/.claude/settings.json` et, règles propres au poste ajoutées par `kit sync`, sur `$KIT_HOME/scripts/**` et
`$KIT_HOME/global/settings*.json` du kit installé ; `Read` des magasins de jetons (`~/.claude.json`, `~/.docker/**`,
`~/.netrc`, `~/.npmrc`, `~/.cloudflared/**`, `~/.wrangler/**`, `~/.config/rclone/**`, `~/.config/gh/**`, `~/.aws/**`…) ;
`sudo`, `sops -d`, `printenv`. Une règle qu'un kit plus récent retire (`settings.retired.json`) disparaît de ton fichier
au prochain `kit sync`, nommée dans sa sortie, **seulement si le kit l'avait livrée** (elle figure dans le registre) : une
règle identique que tu as ajoutée toi-même reste. Ainsi l'ask sur `git push*` du profil `vps` est retiré.

## Réglages gérés

`kit sync` (aussi lancé par `install.sh` et par `kit update`) applique les réglages du kit à `~/.claude/settings.json`
par une **fusion à trois points** : une règle `allow` retirée du kit disparaît, tes ajouts restent, les doublons sont
fusionnés.

- **Clés gérées** : `permissions.allow|ask|deny|defaultMode`, `hooks`, `autoMode.*`. Le reste du fichier (`model`,
  `statusLine`, `enabledPlugins`, `env`, `permissions.additionalDirectories`…) n'est jamais lu ni modifié.
- **K, réglages du kit pour ce poste** : `global/settings.json`, plus `global/settings.vps.json` (profil `vps`), plus
  la surcharge locale ci-dessous.
- **Registre** `~/.config/claude-kit/settings.managed.json` (droits 600) : le K appliqué la dernière fois, avec le
  profil. Pour `allow` et `autoMode.environment|allow`, tes ajouts sont ce qui est dans `settings.json` sans être dans
  le registre ; la nouvelle liste est K puis tes ajouts, sans doublon, ordre gardé. Un registre illisible ou de forme
  inattendue est traité comme absent (avertissement). Si le fichier `profile` manque, le profil du registre est gardé
  (un poste `vps` ne retombe pas sur `local`).
- **`deny`, `ask`, `autoMode.soft_deny|hard_deny` ne sont jamais retirés automatiquement** : ce sont des
  restrictions, et une règle identique à celle du kit peut être la tienne. Le kit ne les retire que s'il les liste dans
  `global/settings.retired.json` (`permissions.ask|deny`, `autoMode.*`) **et** qu'il les avait livrées (présentes dans le
  registre ; à la première migration, sans registre, toute règle listée part) ; chaque retrait est nommé dans la sortie
  de `kit sync` (donc dans `autoupdate.log` quand le hook lance le sync).
- **Arbre de travail du kit protégé** : si le dépôt du kit installé a des modifications non commitées dans `scripts/` ou
  `global/settings*.json`, `kit sync` (et donc le hook de mise à jour) n'applique pas les réglages et le dit : un agent
  qui y aurait écrit un hook, une règle ou le programme de fusion ne les ferait pas appliquer. `kit sync --dry-run`
  montre quand même l'écart ; `kit sync --yes` les accepte après relecture. Travaille sur le kit dans un autre clone.
- **Hooks** : une entrée de ton fichier appartient au kit seulement si sa commande est exactement
  `~/.config/claude-kit/hooks/<script du kit>` (préfixe `$HOME/`, `${HOME}/`, `~/` ou le chemin développé), si ce script
  est un hook du kit **et** si le même couple (matcher, commande) est dans K ou le registre. Seules ces entrées sont
  retirées (doublons compris) : un hook à toi dans le même groupe, un script du kit réutilisé avec un autre matcher, un
  script à toi dans ce dossier, un chemin hors préfixe (`/opt/…/claude-kit/hooks/…`) ou un événement entier que le kit
  ne connaît pas restent. Les groupes retirés sont nommés dans la sortie.
- **Instantané v1, à chaque sync** : le registre est toujours **uni** à l'instantané. Ce qu'un `kit sync` de la v1 réécrit
  après coup (retour arrière, autre poste : hooks du tableau de bord, autorisations du tableau de bord, règles allow retirées,
  anciennes phrases) est donc retiré au sync v2 suivant ; `deny`, `ask`, `soft_deny` et `hard_deny` restent régis par
  `settings.retired.json`. Sans registre (première exécution après la mise à niveau), tout ce que le kit v1 écrivait pour `allow`, les
  hooks et `autoMode` (`global/settings.v1.json`, union de toutes les versions de `global/settings.json` sur `main` ;
  le profil `vps` ajoute les siennes via `profiles.vps`) compte comme venant du kit : ces entrées `allow` et ces hooks
  disparaissent si le kit ne les a plus. Limite : une entrée `allow` que tu avais ajoutée à la main et qui est
  identique à une entrée v1 est prise pour une entrée du kit. Les phrases d'`autoMode.*` y sont stockées en empreintes
  SHA-256 (`autoModeSha256`, empreinte de la chaîne exacte), pas en clair : le dépôt est public et ces phrases décrivaient
  l'infra interne. Les empreintes des phrases sorties du dépôt (domaines internes) y restent : un poste qui les a encore
  les perd au sync, sauf si elles sont déclarées en local.
- **`defaultMode`** vient de K, mais un passage à un mode plus permissif (`default` → `auto`…) est refusé : le mode
  actuel reste et `kit sync` le dit. `kit sync --yes` l'accepte (le hook de mise à jour automatique ne le fait jamais).
- **Surcharge propre au poste** : `~/.config/claude-kit/settings.local.json` (jamais dans Git, ignoré par `.gitignore`,
  absente par défaut ; à ne pas confondre avec le `~/.claude/settings.local.json` de Claude Code). Même forme que
  `global/settings.json`, limitée aux clés gérées : ses entrées s'ajoutent à K sur ce poste seulement ; supprimer le
  fichier retire ses entrées `allow` au sync suivant. Le fichier est remis en 600 à chaque sync. Il ne peut pas contenir
  `defaultMode: bypassPermissions` ni de règle `allow` large (`Bash(*)`, `Bash`, `*`, `Edit`, `Write` sans chemin…) :
  le sync s'arrête avec un message, rien n'est écrit. Ce qu'elle apporte est affiché à chaque sync (règles pour les
  permissions, nombre d'entrées pour `hooks` et `autoMode`).
- **Domaines internes (`autoMode.environment`)** : le dépôt est public, les phrases qui nomment tes domaines et hôtes
  internes n'y sont plus ; `global/settings.json` ne garde qu'un texte générique. Chaque poste les déclare dans un fichier
  texte **hors dépôt**, `~/.config/claude-kit/environment.local.txt` (une phrase par ligne, en anglais, `#` pour un
  commentaire ; modèle : `docs/environment.local.example.txt`, avec des domaines factices). `kit sync` (et
  `install.sh`) en tire l'entrée `autoMode.environment` de `settings.local.json` (600, ses autres clés sont conservées,
  rien n'est écrit si rien ne change) ; `kit overlay env [fichier]` le fait à la demande. Les phrases ne sont jamais
  affichées : ni par le sync, ni par `kit sync --dry-run` (comptes seulement, calculés depuis la surcharge telle qu'elle
  serait écrite). Session cloud : la variable `KIT_LOCAL_ENVIRONMENT` (même format, lignes séparées par des retours à la
  ligne) alimente ce fichier à chaque sync.
  - **Refus** (avertissement sur stderr, donc dans `autoupdate.log` ; **le sync continue** et les phrases précédentes
    restent appliquées) : source ou `settings.local.json` qui est un lien symbolique, source qui n'est pas à toi ou
    modifiable par d'autres, octet NUL, plus de 50 phrases, phrase de plus de 800 caractères, caractère de contrôle (C0,
    DEL, C1), séparateurs U+2028/2029, contrôles bidirectionnels (U+202A à U+202E, U+2066 à U+2069), U+FFFD, et tout ce qui
    ressemble à un secret (clé age ou privée, `ghp_`, `github_pat_`, `sk-`, `xoxb-`/`xoxp-`, suite de 40 caractères base64
    ou hexadécimaux). Ces phrases **ne sont pas secrètes** : elles sont copiées dans `~/.claude/settings.json`, dont les
    droits sont ceux que Claude Code lui donne, et lues par le classifieur du mode auto.
  - `kit overlay env --clear` retire les phrases **et met le fichier source de côté**
    (`environment.local.txt.cleared-<date>`) : sinon le sync suivant les remettrait. Si `KIT_LOCAL_ENVIRONMENT` est défini,
    il les réécrira : retire la variable.
  - **À faire une fois par poste** : sans ce fichier, le classifieur du mode auto ne connaît plus tes domaines de
    confiance, et le premier `kit sync` après la mise à jour le signale (l'ancien contenu est dans
    `settings.json.pre-kit.<date>`). **Historique** : les anciennes phrases restent dans l'historique Git du dépôt public
    (il n'a pas été réécrit) ; seul le contenu actuel est propre.
- **Écriture** : sous verrou (`~/.config/claude-kit/settings.lock`, `KIT_LOCK_WAIT` secondes d'attente, 10 par défaut ;
  un verrou orphelin est repris). Atomique, droits et lien symbolique conservés, et seulement si le contenu change ; si
  `settings.json` a changé entre la lecture et l'écriture, rien n'est écrit (réessaie). L'ancien contenu est copié en
  `settings.json.pre-kit.<date>` ; on garde la plus ancienne et les deux plus récentes.
- **Simulation** : `kit sync --dry-run` affiche, par clé, les entrées qui seraient ajoutées (`+`) et retirées (`-`) et
  n'écrit rien (ni réglages, ni sauvegarde, ni registre, ni verrou, ni liens). Les tests et les HOME temporaires
  utilisent aussi `KIT_SYNC_CONTEXT=0` (pas de clonage des dépôts de contexte) et `KIT_SYNC_REGISTRY=0` (pas de
  régénération de la copie du registre). `kit sync` laisse le dépôt du kit propre (`git status --porcelain` vide,
  testé) ; `kit update` et le hook de mise à jour restaurent un `global/skills-registry.md` modifié seulement dans sa
  table générée (ce que laissaient les versions précédentes) avant le `git pull`. Sur un poste où le fichier diffère
  autrement, `git -C <kit> checkout -- global/skills-registry.md` une fois, puis `kit update`.
- **Retour à la v1** : voir `docs/rollback-v1.md` (restaurer le `settings.json` de l'archive, supprimer le registre,
  lancer le `kit sync` de la v1).

## Mise à jour automatique

Un hook `SessionStart` (démarrage et reprise de session) lance `kit-autoupdate`. Il fait un `git pull --ff-only` du kit, avec un délai de 10 s et sans invite, puis `kit sync` si la révision a changé. Il n'échoue jamais.

En session cloud (`CLAUDE_CODE_REMOTE=true`), un second hook `SessionStart`, `kit-dockerd`, démarre le démon Docker s'il est installé mais arrêté : il le lance détaché (hors des tâches de fond de Claude, donc sans leur limite de durée) et le relance après un redémarrage du conteneur. `KIT_DOCKERD=0` le désactive, `KIT_DOCKERD=1` le force hors cloud ; journal dans `~/.config/claude-kit/dockerd.log`.
- En session cloud, il tourne à chaque démarrage ; en local ou sur le VPS, au plus une fois toutes les 6 h.
- Il ne fait rien si le dépôt du kit a des modifications locales ou n'est pas sur `main`.
- **Couper** : `KIT_AUTOUPDATE=0` (variable d'environnement) ou le fichier `~/.config/claude-kit/autoupdate.off` (n'importe quel
  contenu) sur ce poste ; `kit autoupdate off` / `kit autoupdate on` le crée ou le retire.
- **Épingler une version** : `kit autoupdate pin <tag|branche|révision>`. La référence est **résolue une fois** (le hook,
  appelé avec `--resolve`, va chercher `origin/main` et les tags) et `~/.config/claude-kit/autoupdate.pin` reçoit le **SHA
  complet** (première ligne ; le nom donné sur la seconde, pour l'affichage). Une chaîne de 7 à 40 caractères
  hexadécimaux est toujours un objet, jamais un tag ou une branche du même nom. Le hook ne lit que ce SHA (aucun tag ni
  aucune branche : un tag déplacé sur `origin` n'a aucun effet), ne va chercher que `main`, et met le kit en HEAD
  détaché dessus, puis lance `kit sync`. Conditions, refusées au `pin` **et** revérifiées par le hook avant le
  `checkout` : la révision est un **ancêtre de `origin/main`** (jamais de code non fusionné, branche ou fork), et son propre
  hook porte un `KIT_PIN_FLOOR` au moins égal au courant (**socle** : aucun retour à une version qui ne sait pas épingler ;
  le retour à la v1 est la procédure de `docs/rollback-v1.md`, pas l'épinglage). Le hook ne bouge pas non plus avec un arbre
  modifié, pendant un bisect, un rebase, un merge, un cherry-pick ou un revert, ni si le kit est sur une autre branche
  que `main` ou détaché ailleurs que sur le dernier SHA qu'il a épinglé (`autoupdate.pinned`). Un fichier sans SHA de 40
  caractères est signalé une fois et ignoré. `kit update` ne fait pas de `git pull` tant que le fichier existe ;
  `kit autoupdate unpin` le retire (puis `git -C <kit> checkout main` pour suivre `main` de nouveau),
  `kit autoupdate status` montre l'état.
- `kit --version` affiche le tag (ou la révision, `git describe`) et la date du commit ; `kit doctor` l'ajoute à ses
  contrôles, avec l'état de la mise à jour automatique.
- Les réglages s'appliquent tout de suite ; `CLAUDE.md` et les commandes, au démarrage de session suivant.

## Skills et profils

```bash
kit skills install -g meta        # find-skills, writing-for-agents (une fois par machine)
kit skills install web cloud      # dans un projet : installe les profils choisis
kit list                          # ce qui est disponible et installé
```

Puis dans Claude Code, les marketplaces de `PLUGINS.md` (commandes `/plugin`).

Les noms de skills de chaque profil ont été vérifiés auprès des dépôts avec `npx skills add <source> -l` (novembre 2026), sauf `compose-pro` (profil `android`), dont le dépôt n'a pas pu être cloné dans mon environnement de test. Les dépôts évoluent : une ligne qui échoue n'arrête pas les suivantes et est listée à la fin ; contrôle alors la source avec `-l`.

## Ajouter des skills et des agents au fil du temps

```bash
kit add-skill vercel-labs/agent-skills --skill vercel-react-best-practices --profile web
kit add-skill <dépôt> --project              # seulement pour le projet courant
kit add-agent gh:owner/repo/chemin/agent.md  # ou une URL, ou un fichier local
kit new-agent seo-auditor "Audite le SEO technique d'un site" --tools "Read, Glob, Grep, WebFetch"   # model: opus, effort: medium par défaut
kit add-agent sysop --project                   # un agent optionnel du kit (extras/agents/), pour ce projet
kit new-skill mon-skill "Quand et pourquoi l'utiliser"
```

- Tout est enregistré dans le dépôt (`profiles/custom.txt`, `global/agents/`) : **commite**, et ta prochaine machine le retrouve.
- Dans Claude Code : `/add-skill <besoin ou dépôt>` et `/add-agent <URL ou besoin>` font la recherche, la relecture et le rangement pour toi.
- `kit add-agent` refuse un fichier sans en-tête valide et te signale un agent sans ligne `tools:` (il hériterait de tous les outils, Bash compris). Un nom affiché (« Application Security Engineer ») est remplacé par le nom du fichier.
- Le contenu tiers (skill, agent, plugin) est du prompt non fiable : relis-le avant de l'activer.

## claude.ai/code (sessions cloud)

Chaque session cloud démarre dans un conteneur neuf : le kit s'y réinstalle à chaque fois grâce au **script de démarrage** de l'environnement (menu de l'environnement dans la barre de titre de la session → Edit → Setup script) :

```bash
git clone --depth 1 https://github.com/fs0ciety7000/claude-kit ~/claude-kit 2>/dev/null || git -C ~/claude-kit pull --ff-only
~/claude-kit/install.sh --cloud
```

- `--cloud` accepte root (le conteneur tourne en root), saute sops et age, met `kit` dans le PATH et installe le profil global `meta` (`find-skills`). Agents, skills, commandes, `CLAUDE.md` et hook anti-fuite sont alors disponibles dans toutes les sessions de cet environnement, quel que soit le dépôt ouvert.
- Le script clone la branche par défaut du dépôt : une modification du kit n'arrive dans les sessions qu'une fois fusionnée.
- L'accès réseau de l'environnement doit autoriser GitHub et npm (clone du kit, `npx skills add`).
- Secrets : pas de `kit secrets` en cloud. Mets les jetons nécessaires dans les variables de l'environnement cloud, en version dev et à portée minimale ; jamais ceux de prod.

### Démarrer un projet

**Avant tout**, sur github.com/apps/claude → Configure, donne à l'app l'accès à **All repositories** : chaque nouveau dépôt sera visible par claude.ai/code sans réglage supplémentaire.

**1. Créer le dépôt** (une session cloud ne peut pas créer de dépôt elle-même), au choix :

- **Depuis n'importe où, téléphone compris** : sur GitHub, ouvre ton dépôt modèle `project-template`, clique sur **Use this template**, puis donne un nom. Le modèle se publie une fois depuis ta machine, et se met à jour de la même façon après une modification de `templates/project/` :

  ```bash
  kit project template          # crée ou met à jour <toi>/project-template et le marque comme modèle
  ```

- **Depuis ta machine ou le VPS**, en une commande : dossier, gabarit, agents, skills, autorisations et CI de la pile,
  `project.yaml`, premier commit, dépôt GitHub privé et push de `main` :

  ```bash
  kit new ma-boutique --stack nextjs-cloudflare,pocketbase --size S --reason "boutique simple, un seul déploiement"
  kit new ma-boutique --stack astro-static --dry-run      # montre ce qui serait fait, n'écrit rien
  ```

  Le dépôt passe par `kit repo create` (`GITHUB_TOKEN`, clé de déploiement), sinon par `gh` connecté ; relancer
  `kit new` reprend où il s'est arrêté. En session cloud, si le dépôt ne peut pas être créé, `kit new` le dit et donne
  la commande à lancer sur ton poste. `kit doctor` vérifie ces prérequis. Environnement cloud conseillé :
  `docs/cloud-env.md`.

Le modèle et `kit repo create` passent par `GITHUB_TOKEN` (`kit secrets add GITHUB_TOKEN -g`, droits : création de dépôts + Administration).

**2. Ouvrir une session** sur claude.ai/code sur ce dépôt, puis :

```
/new-project <description du projet>
```

Claude classe le projet avec `skills-registry.md`, puis lance `kit project add <type>...` après ton accord : les agents et skills maison du type sont **copiés** dans `.claude/` du projet, et ses profils de skills sont installés au niveau projet. Le tout est commité, donc le projet retrouve ses outils aux sessions suivantes. À la main :

```bash
kit project types                         # types, profils et agents de chacun
kit project add web-frontend deploy       # plusieurs types se combinent
```

## Mettre en ligne

`/ship` (ou `kit ship` à la main) met un projet en ligne d'après son `project.yaml` : `expose`
(`none`, `tailnet`, `access` derrière Cloudflare Access, `public`), `domain`, `server`, `health_path`, `volumes`
(`yes`/`no`) ; `coolify_uuid` est écrit au premier passage. `kit project get [clé]` lit ces champs.

```bash
kit ship plan               # ce qui serait créé ou modifié ; rien n'est écrit, aucun appel d'API
kit ship infra [--dry-run]  # branche ship/<nom> + PR dans le dépôt d'infra : CNAME vers le tunnel (access, public),
                            # application Access (access), sonde Gatus (public), sauvegarde (volumes: yes)
kit ship app [--dry-run]    # application Coolify (source GitHub App, auto-déploiement coupé, domaine, santé),
                            # noms de variables comparés à .env.example, .fs0/bridge.yaml deploy:, DEPLOY_ALLOW du pont
kit ship status [--wait s]  # dernier déploiement (trié par created_at) et réponse HTTPS du domaine
kit ship previews setup [--dry-run]  # PR d'infra : CNAME et Access joker *.<PREVIEW_SUFFIX>, puis (après apply) ingress
```

- **Réglages du poste** : `~/.config/claude-kit/ship.conf` (modèle `docs/ship.conf.example`, valeurs factices) :
  dépôt d'infra et son clone, cible du tunnel, zones, policies Access, fichier Gatus, sauvegarde, UUID Coolify
  (projet, serveurs, GitHub App, application du pont). Ces identifiants ne vont jamais dans un dépôt ; sans ce
  fichier, `kit ship` refuse.
- **Le propriétaire applique** : `kit ship infra` ne lance jamais tofu ; il fusionne la PR puis lance `tofu apply`.
  Le clone d'infra n'est pas touché (worktree temporaire) ; relancer n'ajoute pas de doublon. Un nom déjà déclaré
  autrement (autre enregistrement, autres policies) arrête tout ; `tailnet` exige `TAILNET_SUFFIX`, `public` et
  `access` le refusent, un apex de zone demande `--apex`.
- **Application existante** : reprise seulement si elle est construite depuis le dépôt du projet.
- **Prévisualisations des PR** : `previews: true` (piles web, tailles M et L, `expose` access ou public ; refusé
  sinon). Coolify construit sur le serveur de prod les PR de toute branche du dépôt (Renovate, agents) avant revue,
  et copie chaque variable dans sa version de prévisualisation avec la même valeur. Avec des variables déclarées,
  `previews: true` est donc refusé, sauf `preview_env: dedicated` : chaque copie reçoit alors `__SECRET:<NOM>_PREVIEW__`,
  vérifiée par relecture (un booléen, jamais une valeur). `kit ship app` active les prévisualisations
  (`{{pr_id}}-<nom>.<PREVIEW_SUFFIX>`) seulement si le dépôt d'infra (branche de base) porte l'application Access
  joker et la règle d'ingress dédiée (`access.required`), si l'application Access en ligne correspond, et si les
  variables sont remplacées. Sinon, ou avec `previews: false`, il les coupe ; un écart à la relecture, ou des PR
  publiques actives, l'arrête. Certificat d'edge requis pour `*.<PREVIEW_SUFFIX>` (Universal SSL ne couvre qu'un
  niveau sous la zone).
- **Secrets** : seuls les noms des variables sont comparés ; les manquantes sont listées avec `kit secrets add NOM`
  et le `POST …/envs` en `__SECRET:NOM__`. `DEPLOY_ALLOW` est relue et réécrite par fichier, sans jamais être
  affichée ; une entrée du même dépôt vers une autre application bloque tout.
- **Déploiement** : le pont déploie après la CI verte sur `main` ; aucun déploiement de l'application par l'API après
  une fusion. Chaque écriture est annoncée sur une ligne ; `DELETE` n'est jamais utilisé.

**Retirer** : `/retire` (ou `kit retire plan|run [--dry-run]`) met hors ligne un projet publié par `kit ship`, sans
rien supprimer : arrêt de l'application Coolify (après contrôle qu'elle est construite depuis le dépôt du projet),
retrait de l'entrée du dépôt dans `DEPLOY_ALLOW` du pont (relue et vérifiée, valeur jamais affichée), retrait de
`deploy:` dans `.fs0/bridge.yaml`, PR d'infra `retire/<nom>` qui enlève les entrées DNS, Access, Gatus et sauvegarde
seulement si elles sont identiques à ce qu'écrit `kit ship` (les autres sont signalées et gardées), puis
`expose: none` (`coolify_uuid` gardé) et une note dans `DEPLOY.md` et `docs/memory/state.md`. Restent au
propriétaire : `tofu apply`, la suppression de l'application dans l'interface Coolify et l'archivage du dépôt.

## VPS

```bash
# sur le VPS, avec un utilisateur NON root
git clone <ton-dépôt>/claude-kit ~/claude-kit && cd ~/claude-kit
./install.sh --vps --deps
kit secrets pubkey                 # copie cette clé publique
# sur ta machine principale
kit secrets add-recipient <clé publique du VPS>   # dans chaque projet qui a un dossier secrets/, + global
git add -A && git commit && git push
```

- Le profil `--vps` passe en permissions strictes : modifications validées une à une, `git commit`, installations de paquets, `mv` et `cp` demandent confirmation (le `git push` n'en demande plus : décision du propriétaire), `wrangler deploy` est refusé (déploie via Coolify).
- Le VPS a **sa propre clé age** et ses propres jetons. Ne copie jamais `keys.txt` d'une machine à l'autre, et ne copie pas ta session Claude : connecte-toi avec `claude` sur le VPS lui-même.
- Garde la session vivante avec `tmux`. `claude remote-control` (forfait Pro/Max/Team/Enterprise requis) permet de la retrouver depuis l'app Claude ou claude.ai/code sans ouvrir de port ; voir la doc officielle pour les limites.

## Harness : démarrer, reprendre, passer le relais

| Commande | Quand |
|---|---|
| `/new-project <brief>` | nouveau projet : cadrage, stack, équipement, **plan** (agent `architect`) et **équipe** (skill `team-builder`), gabarit, design, déploiement, puis exécution orchestrée lot par lot |
| `/adopt` | projet existant (Tandem, CSM…) : ajoute mémoire, relais, plan, équipe et hook de démarrage, sans rien écraser, en PR |
| `/resume` | début de session : relit relais, état et plan, vérifie le dépôt, propose la suite |
| `/handoff` | fin de session : écrit `docs/memory/handoff.md`, met à jour état et plan, commite et pousse |

- **Équipe** : selon la taille (S : fil principal et 1 ou 2 agents ; M : `architect` et 3 à 5 ; L : `architect` et 4 à 7,
  avec relecteurs), copiée dans `.claude/agents/` (`model` et `effort` de l'en-tête, réglables par `kit project effort`), listée dans la rubrique « Équipe » de `CLAUDE.md`. La session principale orchestre.
- **Hook de démarrage** du gabarit (`.claude/settings.json`) : affiche `docs/memory/state.md` seul en tête de session,
  1 500 caractères au plus (coupé à une fin de ligne, avec un renvoi au fichier ; `handoff.md` est lu à la demande par
  `/resume`). Budget appliqué par `scripts/test/run.sh` (`project_sessionstart.chars`), contre 8 129 caractères en v1.
- **Plan** : `docs/plan.md` est la seule liste de tâches (lots, `Agent / Parallel with / Done when`, cases à cocher, format
  écrit par le skill `writing-plans`) ; il n'y a plus d'outil de tâches ni de validation en dehors du chat.
- **Contexte d'infra** (skill `infra-context`) : `KNOWLEDGE.md` de fs0ciety-ops, lu dans `~/.kit/context/fs0ciety-ops`
  (copie en lecture seule tenue par `kit sync`, liste dans `global/context-repos.txt`) ou, en cloud, dans le dépôt
  attaché à la session.
- **Engram** (skill `engram`) : le coffre de connaissances privé, lu avant une tâche non triviale et enrichi par PR
  (leçons, décisions, pratiques). `kit sync` (donc `kit update`) en tient une copie en lecture seule dans
  `~/.kit/context/engram`, comme pour fs0ciety-ops : clone superficiel s'il manque (HTTPS puis SSH, avec les
  identifiants git de la machine, aucun jeton dans l'URL), sinon `git pull --ff-only` ; un échec n'est qu'un
  avertissement. Rien n'est cloné en profil cloud : la session attache le dépôt `fs0ciety7000/engram`.
- **Workflow** : deux skills de Superpowers, `brainstorming` (idées floues) et `writing-plans` (écrit `docs/plan.md`),
  copiés dans `global/skills/` à un commit relu puis corrigés (`vendor/superpowers/`, corrections dans `PATCHES.md`),
  donc épinglés : pas de mise à jour automatique depuis le dépôt amont. Les neuf autres skills (exécution par
  sous-agents, TDD, débogage, revues…) sont retirés du kit en v2 ; ils restent dans la branche `legacy/v1`.

## Mode auto (presque sans interruption)

Le kit met Claude Code en mode **`auto`** : un classifieur juge chaque action au lieu de te la demander. Le bloc
`autoMode` de `global/settings.json` lui décrit ton infra de confiance, en phrases :

- `environment` : tes dépôts (`fs0ciety7000/*`, claude-kit public), Coolify, Cloudflare, Tailscale, la gestion des
  secrets, les registres de paquets ; tes domaines internes n'y sont pas (dépôt public) : ils viennent de la surcharge
  locale de chaque poste (voir « Réglages gérés ») ;
- `allow` : installer les dépendances et lancer les scripts d'un projet, les outils de build (Quartz…), cloner un dépôt
  public pour le lire, `kit api` en création, modification et déploiement, push (branches `claude/*` ou `main`),
  ouverture et fusion de PR, `docker compose up|down` ;
- `soft_deny` : pas de `tofu apply` ni de `tofu destroy` (c'est toi qui les lances ; ils sont aussi refusés par une règle
  `deny`), pas de modification de ses propres permissions ;
- `hard_deny` : jamais la valeur d'un secret, nulle part.

`kit sync` l'applique à `~/.claude/settings.json` (machines et sessions cloud) : le mode vient du kit, et tes propres
entrées sont conservées (voir « Réglages gérés »). Le classifieur **ignore** `autoMode` dans le `.claude/settings.json`
d'un projet (un dépôt ne peut pas s'autoriser lui-même).

**Quand Claude est bloqué à répétition** sur une action de routine, il ne change pas ses réglages : il ouvre une PR
sur claude-kit avec la règle proposée et la raison. Tu la fusionnes, puis `kit update`. Commandes utiles :
`claude auto-mode config` (règles effectives), `claude auto-mode critique` (avis sur tes règles), `/permissions` →
onglet « Recently blocked » pour relancer une action refusée.

## Garde-fous et leurs limites

- **Permissions** (`settings.json`) : lecture des fichiers de secrets refusée, `sudo`, `printenv`, `sops -d`, `tofu apply|destroy` refusés, écriture de `~/.config/claude-kit/**` et de `~/.claude/settings.json` refusée à `Edit`/`Write`, actions destructrices en confirmation.
- **Hook `guard-secrets.sh`** (un seul processus par appel d'outil : Bash, Read, Edit, Write, MultiEdit, NotebookEdit, Grep ;
  budget `hooks_per_tool_call.*` = 1) : il juge les **fichiers** qu'une commande touche, pas les mots qu'elle cite.
  Il bloque la lecture, l'affichage, la copie ou l'écriture par redirection de fichiers d'environnement (`.env`,
  `.env.local`… mais pas `.env.example`, `.env.sample`), de clés privées (`id_*` sans `.pub`, `*.pem`, `*.key`, `~/.ssh`
  hors `config`, `known_hosts` et `*.pub`), de magasins de jetons (`~/.config/gh`, `~/.docker/config.json`, `.netrc`,
  `.npmrc`, `~/.aws`, `~/.claude.json`…), le déchiffrement manuel (`sops -d`, `age -d`, `kit secrets edit`, `gh auth
  token`), les vidages de l'environnement (`printenv`, `env`, `set`, `export -p`, `jq env`, `os.environ` entier, tout ce
  qui imprime l'environnement dans `kit secrets run`), l'`echo` d'une variable nommée `*TOKEN*`, `*SECRET*`… (sauf dans
  un tube), et un commit dont le diff contient une clé reconnaissable. Il bloque aussi les écritures d'un agent (Edit,
  Write, `cp`, `mv`, `tee`, `rm`, `touch`, `sed -i`, redirection, `dd of=`, `curl -o`) dans `~/.config/claude-kit/**`
  (`settings.local.json`, `environment.local.txt`, `autoupdate.pin`, registre) et `~/.claude/settings.json` : seuls
  `kit sync`, `kit overlay` et `kit autoupdate` les écrivent. Il ne bloque **pas** une commande qui ne fait que
  *nommer* ces fichiers : chemin `jq` comme `.environment`, motif de `grep`/`rg`/`sed`, message de commit, corps de PR,
  règle JSON `Read(**/.env)`, texte de doc, `git diff` de `.env.example`, `cp .env.example .env` (la destination d'une
  copie n'est pas lue), `ls`/`test -f`/`rm`/`chmod` sur ces fichiers. Il découpe la commande (guillemets, heredocs,
  `$( )`, accents graves, redirections, `sudo`/`env`/`timeout`/`xargs`, `bash -c`, `eval`) et résout `~`, `$HOME`,
  `$KIT_CONFIG` et le dossier courant ; `scripts/test/guard-secrets-test.sh` couvre les deux sens (583 cas, dont le corpus de contournements de la revue de sécurité dans `scripts/test/guard-corpus/`).
- **Ce n'est pas étanche.** Les motifs de commandes se contournent (un script, un autre langage) et le hook ne détecte que les formats de clés connus. La vraie protection : secrets chiffrés, jetons à portée minimale, séparation dev/prod, et rotation immédiate en cas de doute.
- **Limites connues du hook** (épinglées par des tests : `scripts/test/guard-corpus/known-limits.txt`) : un nom construit
  à l'exécution (`f=.env; cat $f`, `$'…'`, `$"…"`, `cat $(echo …)`, concaténation dans `python -c`), un lien symbolique
  ou dur créé dans une commande précédente puis lu, `xargs` qui reçoit les chemins par l'entrée standard, un programme
  `python`/`node` qui écrit un fichier, `eval` très imbriqué au-delà de huit niveaux (refusé, pas analysé), une recherche
  récursive depuis le projet lui-même (`grep -r TOKEN .` lit un fichier d'environnement non ignoré : seul le départ de
  `$HOME`, `/` ou d'un dossier au-dessus d'un magasin d'identifiants est refusé), l'outil `Glob` (noms seulement, hors
  du hook), `docker compose up|build` sans fichier compose trouvé (on laisse passer), un service distant qui renvoie ce
  qu'on lui envoie. Le hook échoue fermé (awk absent, analyse en échec, commande de plus de 256 Ko) ; son entrée dans
  `settings.json` a un délai de 10 s (au-delà, Claude Code laisse passer).
- **Risques acceptés** : `git worktree add` ou `git clone` dans `~/.claude` (hors `settings.json`), `git remote add` puis
  `git push` vers une URL quelconque (le push est autorisé par décision du propriétaire), les outils des fragments de
  pile (`pytest`, `npm run test`, `go test`…) exécutent le code du projet, `docker compose up|build` est autorisé (le
  hook refuse seulement les fichiers compose qui donnent l'hôte au conteneur : `privileged: true`, `pid|network_mode|ipc:
  host`, montage de `/`, de `$HOME` ou du socket Docker, contexte de build `/` ou `~`), et un agent peut toujours écrire le
  `.claude/settings.json` de son projet (seul `settings.local.json` est protégé).
- Les noms des variables restent lisibles dans les fichiers chiffrés (seules les valeurs le sont).
- Un secret injecté dans une commande est visible par cette commande et ses enfants : ne lance sous `kit secrets run` que des programmes de confiance.

## Arborescence

```
claude-kit/
├── install.sh                  installateur (--vps, --cloud, --deps, --no-secrets)
├── PLUGINS.md                  commandes /plugin à taper dans Claude Code
├── scripts/
│   ├── kit.sh                  CLI kit
│   ├── secrets.sh              sops + age
│   ├── lib.sh                  fonctions communes
│   ├── managed-settings.jq     fusion à trois points des réglages (appelée par lib.sh)
│   ├── backup-v1.sh            sauvegarde d'un poste avant la v2 (docs/rollback-v1.md)
│   └── hooks/guard-secrets.sh  hook PreToolUse
├── global/                     lié dans ~/.claude
│   ├── CLAUDE.md, settings.json, settings.vps.json, settings.v1.json, settings.retired.json, skills-registry.md
│   ├── agents/  commands/  skills/
├── profiles/                   listes de skills par domaine
├── templates/project/          gabarit copié par « kit project new/init » (dont `project.yaml`)
├── templates/permissions/      autorisations `allow` par pile, posées par « kit project add/perms »
└── templates/rules/            règles de taille M et L, copiées par « kit project size »
```
