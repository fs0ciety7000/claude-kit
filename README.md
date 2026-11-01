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
- Par projet : remplis `.env.example`, puis `kit secrets add NOM` (fichier `secrets/dev.enc.json`, commitable car chiffré). `kit secrets check` compare les deux.
- Lancer une commande avec secrets : `kit secrets run -g -- wrangler deploy`. Les valeurs n'existent que dans ce processus.
- Interroger Coolify ou Cloudflare en lecture : `kit api coolify /applications --jq 'map({uuid,name,status})'`. Le jeton passe à `curl` par stdin (jamais dans `ps`), le filtre `--jq` est obligatoire (la réponse brute peut contenir des variables d'environnement), seul `GET` existe. Les agents utilisent cette commande plutôt que `curl`.
- Jetons à portée minimale : Cloudflare par zone et par permission, GitHub fine-grained, Coolify séparé dev/prod.

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
├── install.sh                  installateur (--vps, --deps, --no-secrets)
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
