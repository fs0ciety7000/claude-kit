# claude-kit

Environnement Claude Code réutilisable : 14 sous-agents, skills routés par profil, secrets chiffrés (sops + age), garde-fous, et une commande `kit` pour tout étendre en une ligne. Pensé pour Garuda Linux (Arch), macOS et un VPS Debian/Ubuntu.

## Ce qui est installé

| Élément | Où | Rôle |
|---|---|---|
| `global/CLAUDE.md` | lien vers `~/.claude/CLAUDE.md` | langue, routage, règles secrets et qualité |
| `global/agents/*.md` (14) | `~/.claude/agents/` | ui-designer, design-critic, android-ui-reviewer, frontend-dev, backend-dev, qa-tester, brand-identity, game-designer, creative-coder, creative-content, copywriter, devops, security-reviewer, researcher |
| `global/skills/` (3) | `~/.claude/skills/` | `pocketbase`, `secrets-handling`, `deploy-coolify-cloudflare` |
| `global/commands/` | `~/.claude/commands/` | `/new-project`, `/add-skill`, `/add-agent`, `/env-check` |
| `global/skills-registry.md` | `~/.claude/skills-registry.md` | type de projet → profils, skills, agents |
| `global/settings.json` | fusionné dans `~/.claude/settings.json` | permissions + hook anti-fuite |
| `profiles/*.txt` | utilisés par `kit skills install` | listes de skills par domaine (web, design, brand, android, game, threejs, go, rust, shopify, cloud, media, meta, custom) |
| `scripts/` | `~/.local/bin/kit` | CLI : secrets, skills, agents, MCP |

Les agents et commandes sont des **liens** vers ce dépôt : modifier un fichier ici le modifie partout, et `git pull` met tout à jour.

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
- Nouveau projet : `kit project new mon-projet && cd mon-projet && claude`, puis `/new-project "<description>"` (ajoute `--rapide` pour enchaîner sans pause). Le flux guidé passe par cadrage, stack, design (`DESIGN.md`), gabarit, déploiement Coolify + sous-domaine Cloudflare (`DEPLOY.md`), secrets, puis plan de travail. Projet existant : `kit project init`.
- Dépôt GitHub : `kit repo create mon-projet` (dans le dossier du projet) crée le dépôt privé, une clé de déploiement propre à ce dépôt (écriture) et configure `origin`. Prérequis : `git config --global user.name/user.email` et `kit secrets add GITHUB_TOKEN -g` (droits : création de dépôts + Administration pour la clé). `/new-project` l'appelle tout seul.
- Par projet : remplis `.env.example`, puis `kit secrets add NOM` (fichier `secrets/dev.enc.json`, commitable car chiffré). `kit secrets check` compare les deux.
- Lancer une commande avec secrets : `kit secrets run -g -- wrangler deploy`. Les valeurs n'existent que dans ce processus.
- Interroger Coolify ou Cloudflare en lecture : `kit api coolify /applications --jq 'map({uuid,name,status})'`. Le jeton passe à `curl` par stdin (jamais dans `ps`), le filtre `--jq` est obligatoire (la réponse brute peut contenir des variables d'environnement). Les écritures (`POST`, `PUT`, `PATCH`) et les actions (`TRIGGER`, qui lance un déploiement) sont autorisées sans confirmation dans `global/settings.json` ; `DELETE` est refusé. Pour redemander une confirmation, déplace les lignes `kit api … POST/PUT/PATCH/TRIGGER` de `allow` vers `ask`. Une valeur secrète dans un corps JSON s'écrit `__SECRET:NOM__`. Les agents utilisent cette commande plutôt que `curl`.
- Jetons à portée minimale : Cloudflare par zone et par permission, GitHub fine-grained, Coolify séparé dev/prod.

## Dashboard en direct (kit.fs0ciety.org)

Le dépôt [`claude-kit-dashboard`](https://github.com/fs0ciety7000/claude-kit-dashboard) affiche en direct les sessions Claude Code (terminal, claude.ai/code, worker VPS) : fil d'événements, arbre des sous-agents et workflows, fichiers modifiés, commits, mémoire du projet (`docs/memory/*.md`) et statut Coolify. Il est protégé par Cloudflare Access.

Le hook `kit-emit` (installé par `kit sync`, inactif tant que rien n'est configuré) envoie chaque événement en arrière-plan, sans jamais ralentir Claude, après masquage des valeurs qui ressemblent à des secrets.

```bash
kit dash setup https://kit.fs0ciety.org     # active l'envoi
kit secrets add KIT_DASH_TOKEN -g           # jeton affiché dans Réglages du dashboard
kit dash status
```

Session claude.ai/code : ajoute la variable `KIT_DASH_URL=https://kit.fs0ciety.org` à l'environnement cloud et enregistre le jeton comme *network secret* de l'hôte `kit.fs0ciety.org` (en-tête `Authorization: Bearer`) : le proxy l'injecte, il n'existe dans aucune variable.

`kit dash setup` déclare aussi le serveur MCP **kit-control** (`/mcp`) : Claude y demande les validations de phase (`checkpoint`) et pose ses questions (`ask`), auxquelles tu réponds depuis le dashboard, et tient le tableau de tâches. En local, le jeton est fourni par `headersHelper` (`kit secrets run`), jamais écrit en clair ; en cloud, `install.sh --cloud` le déclare si `KIT_DASH_URL` est défini, et le proxy injecte le jeton.

`kit detect [--json]` devine les types de projet à partir des fichiers (`global/detect-rules.tsv`) et en déduit profils, skills et agents ; `/new-project` s'en sert et note le choix dans `docs/memory/stack.md`.

## Équiper un projet selon son domaine et sa stack

`/new-project` a une phase « Équipement » : Claude extrait des mots-clés du domaine (finance, compta…) et de la stack (laravel, php…), lance `kit equip search` (skills de skills.sh triés par installations, agents et skills de l'index des collections), garde ce qui est utile au projet après relecture, le fait valider (outil `equip` de kit-control, avec sources de confiance), l'installe au niveau du projet (`--project`, commité dans `.claude/`) puis relance la session pour charger les nouveaux skills. Une stack absente du registre fait l'objet d'une PR automatique (`kit registry propose`) : une fois fusionnée, le projet suivant l'installe directement.

### Index des collections

`global/collections-index.json` recense les agents et les skills de 12 collections open source relues (liste,
licences et collections écartées : `global/agent-sources.txt`) : environ 1 800 agents et 2 200 skills. Il est construit
par `scripts/build-index.sh` à partir de clones superficiels, **sans API GitHub** : il marche en local, en session cloud
et dans la CI. Seuls les fichiers sont lus ; aucun installateur, CLI ni hook de ces dépôts n'est lancé.

```bash
kit equip search laravel stripe --max 5   # agents, skills des collections et skills de skills.sh
kit index                                 # régénère l'index (3 min environ)
```

- Le workflow « Collections index » le régénère chaque lundi et ouvre une **PR** : relis le diff (texte tiers), surtout
  quand une source est ajoutée.
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

Règles acceptées : commandes précises de lecture, build, test, lint et format (au moins deux mots fixes, `*` seulement en fin après une espace : `Bash(npm run test *)`, `Bash(go test ./...)`), chemins du projet (`Read(src/**)`), `git` non destructif, `kit api … GET`, écritures `kit api` POST, PUT ou PATCH sur un chemin précis, outils MCP nommés sans verbe dangereux. Refusés aussi : jokers en milieu de mot (`?`, `[…]`, `test*`), chemins absolus ou `..`, interpréteurs et lanceurs de code (`node`, `python`, `make`, `go run`, `npx` hors prettier/eslint/tsc/vitest/playwright), écriture dans les fichiers à point, manifestes et scripts exécutés (`.claude/`, `.github/`, `package.json`, `Makefile`…).

Règles refusées par le script :
- les règles larges (`Bash(*)`, `Bash(npm *)`, `mcp__x__*`) ;
- celles qui recouvrent un `deny` ou un `ask` du kit ;
- les secrets ;
- `rm`, `DELETE`, `TRIGGER`, le déploiement, la publication, `push` et la fusion ;
- les chemins hors du projet.

Ces cas refusés, et toute règle globale, passent par une PR sur ce dépôt.

## Mise à jour automatique

Un hook `SessionStart` (démarrage et reprise de session) lance `kit-autoupdate`. Il fait un `git pull --ff-only` du kit, avec un délai de 10 s et sans invite, puis `kit sync` si la révision a changé. Il n'échoue jamais.
- En session cloud, il tourne à chaque démarrage ; en local ou sur le VPS, au plus une fois toutes les 6 h.
- Il ne fait rien si le dépôt du kit a des modifications locales ou n'est pas sur `main`.
- `KIT_AUTOUPDATE=0` le désactive.
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
kit new-agent seo-auditor "Audite le SEO technique d'un site" --tools "Read, Glob, Grep, WebFetch"
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

- **Depuis ta machine ou le VPS** : le dossier, le gabarit et les agents et skills des types donnés, puis le dépôt GitHub (privé, avec sa clé de déploiement) :

  ```bash
  kit project new ma-boutique nextjs-cloudflare pocketbase && cd ma-boutique
  kit repo create ma-boutique
  git add -A && git commit -m "Initialise le projet" && git push -u origin main
  ```

Les deux passent par `GITHUB_TOKEN` (`kit secrets add GITHUB_TOKEN -g`, droits : création de dépôts + Administration).

**2. Ouvrir une session** sur claude.ai/code sur ce dépôt, puis :

```
/new-project <description du projet>
```

Claude classe le projet avec `skills-registry.md`, puis lance `kit project add <type>...` après ton accord : les agents et skills maison du type sont **copiés** dans `.claude/` du projet, et ses profils de skills sont installés au niveau projet. Le tout est commité, donc le projet retrouve ses outils aux sessions suivantes. À la main :

```bash
kit project types                         # types, profils et agents de chacun
kit project add web-frontend deploy       # plusieurs types se combinent
```

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

- Le profil `--vps` passe en permissions strictes : modifications validées une à une, `git push`, installations de paquets et `docker` demandent confirmation, `wrangler deploy` est refusé (déploie via Coolify).
- Le VPS a **sa propre clé age** et ses propres jetons. Ne copie jamais `keys.txt` d'une machine à l'autre, et ne copie pas ta session Claude : connecte-toi avec `claude` sur le VPS lui-même.
- Garde la session vivante avec `tmux`. `claude remote-control` (forfait Pro/Max/Team/Enterprise requis) permet de la retrouver depuis l'app Claude ou claude.ai/code sans ouvrir de port ; voir la doc officielle pour les limites.

## Harness : démarrer, reprendre, passer le relais

| Commande | Quand |
|---|---|
| `/new-project <brief>` | nouveau projet : cadrage, stack, équipement, **plan** (agent `architect`) et **équipe** (skill `team-builder`), gabarit, design, déploiement, puis exécution orchestrée lot par lot |
| `/adopt` | projet existant (Tandem, CSM…) : ajoute mémoire, relais, plan, équipe et hook de démarrage, sans rien écraser, en PR |
| `/resume` | début de session : relit relais, état, plan, tâches, vérifie le dépôt, propose la suite |
| `/handoff` | fin de session : écrit `docs/memory/handoff.md`, met à jour état et plan, commite et pousse |

- **Équipe** : 4 à 7 agents par projet, copiés et adaptés dans `.claude/agents/` (commandes et règles réelles du
  projet, `model` et `effort`), listés dans la rubrique « Équipe » de `CLAUDE.md`. La session principale orchestre.
- **Hook de démarrage** du gabarit (`.claude/settings.json`) : affiche `handoff.md` et `state.md` en tête de session.
- **Contexte d'infra** (skill `infra-context`) : `KNOWLEDGE.md` de fs0ciety-ops, lu dans `~/.kit/context/fs0ciety-ops`
  (copie en lecture seule tenue par `kit sync`, liste dans `global/context-repos.txt`) ou, en cloud, dans le dépôt
  attaché à la session.
- **Engram** (skill `engram`) : le coffre de connaissances privé, lu avant une tâche non triviale et enrichi par PR
  (leçons, décisions, pratiques). `kit sync` (donc `kit update`) en tient une copie en lecture seule dans
  `~/.kit/context/engram`, comme pour fs0ciety-ops : clone superficiel s'il manque (HTTPS puis SSH, avec les
  identifiants git de la machine, aucun jeton dans l'URL), sinon `git pull --ff-only` ; un échec n'est qu'un
  avertissement. Rien n'est cloné en profil cloud : la session attache le dépôt `fs0ciety7000/engram`.
- **Workflow** : 11 skills de Superpowers copiés dans `global/skills/` à un commit relu (`vendor/superpowers/`),
  donc épinglés : pas de mise à jour automatique depuis le dépôt amont.

## Mode auto (presque sans interruption)

Le kit met Claude Code en mode **`auto`** : un classifieur juge chaque action au lieu de te la demander. Le bloc
`autoMode` de `global/settings.json` lui décrit ton infra de confiance, en phrases :

- `environment` : tes dépôts (`fs0ciety7000/*`, claude-kit public), tes domaines, Coolify, Cloudflare, Tailscale, le
  dashboard, la gestion des secrets, les registres de paquets ;
- `allow` : installer les dépendances et lancer les scripts d'un projet, les outils de build (Quartz…), cloner un dépôt
  public pour le lire, `kit api` en création, modification et déploiement, branches `claude/*` et PR ;
- `soft_deny` : pas de `tofu apply` (c'est toi qui l'appliques), pas de modification de ses propres permissions ;
- `hard_deny` : jamais la valeur d'un secret, nulle part.

`kit sync` le fusionne dans `~/.claude/settings.json` (machines et sessions cloud) : le mode vient du kit, et les
listes s'additionnent avec tes propres entrées. Le classifieur **ignore** `autoMode` dans le `.claude/settings.json`
d'un projet (un dépôt ne peut pas s'autoriser lui-même).

**Quand Claude est bloqué à répétition** sur une action de routine, il ne change pas ses réglages : il ouvre une PR
sur claude-kit avec la règle proposée et la raison. Tu la fusionnes, puis `kit update`. Commandes utiles :
`claude auto-mode config` (règles effectives), `claude auto-mode critique` (avis sur tes règles), `/permissions` →
onglet « Recently blocked » pour relancer une action refusée.

## Garde-fous et leurs limites

- **Permissions** (`settings.json`) : lecture des fichiers de secrets refusée, `sudo`, `printenv`, `sops -d` refusés, actions destructrices en confirmation.
- **Hook `guard-secrets.sh`** : bloque la lecture de `.env*`, clés et identifiants, l'affichage de variables secrètes et les commits contenant une clé reconnaissable.
- **Ce n'est pas étanche.** Les motifs de commandes se contournent (un script, un autre langage) et le hook ne détecte que les formats de clés connus. La vraie protection : secrets chiffrés, jetons à portée minimale, séparation dev/prod, et rotation immédiate en cas de doute.
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
│   └── hooks/guard-secrets.sh  hook PreToolUse
├── global/                     lié dans ~/.claude
│   ├── CLAUDE.md, settings.json, settings.vps.json, skills-registry.md
│   ├── agents/  commands/  skills/
├── profiles/                   listes de skills par domaine
└── templates/project/          gabarit copié par « kit project new/init »
```
