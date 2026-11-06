# claude-kit

Environnement Claude Code réutilisable : 14 sous-agents, skills routés par profil, secrets chiffrés (sops + age), garde-fous, et une commande `kit` pour tout étendre en une ligne. Pensé pour Garuda Linux (Arch) et un VPS Debian/Ubuntu.

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

Le dépôt [`claude-kit-dashboard`](https://github.com/fs0ciety7000/claude-kit-dashboard) affiche en direct les sessions Claude Code (terminal, claude.ai/code, worker VPS) : fil d'événements, arbre des sous-agents et workflows, fichiers modifiés, commits, mémoire du projet (`.claude/memory/*.md`) et statut Coolify. Il est protégé par Cloudflare Access.

Le hook `kit-emit` (installé par `kit sync`, inactif tant que rien n'est configuré) envoie chaque événement en arrière-plan, sans jamais ralentir Claude, après masquage des valeurs qui ressemblent à des secrets.

```bash
kit dash setup https://kit.fs0ciety.org     # active l'envoi
kit secrets add KIT_DASH_TOKEN -g           # jeton affiché dans Réglages du dashboard
kit dash status
```

Session claude.ai/code : ajoute la variable `KIT_DASH_URL=https://kit.fs0ciety.org` à l'environnement cloud et enregistre le jeton comme *network secret* de l'hôte `kit.fs0ciety.org` (en-tête `Authorization: Bearer`) : le proxy l'injecte, il n'existe dans aucune variable.

`kit dash setup` déclare aussi le serveur MCP **kit-control** (`/mcp`) : Claude y demande les validations de phase (`checkpoint`) et pose ses questions (`ask`), auxquelles tu réponds depuis le dashboard, et tient le tableau de tâches. En local, le jeton est fourni par `headersHelper` (`kit secrets run`), jamais écrit en clair ; en cloud, `install.sh --cloud` le déclare si `KIT_DASH_URL` est défini, et le proxy injecte le jeton.

`kit detect [--json]` devine les types de projet à partir des fichiers (`global/detect-rules.tsv`) et en déduit profils, skills et agents ; `/new-project` s'en sert et note le choix dans `.claude/memory/stack.md`.

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
- `kit add-agent` refuse un fichier sans en-tête valide et te signale un agent sans ligne `tools:` (il hériterait de tous les outils, Bash compris).
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
