# Plan : un vrai harness autour du kit

> Statut : **plan, à valider**. Rien n'est modifié. Rédigé le 10/11/2026.

## 1. Le besoin

Une session principale **orchestre** un projet de bout en bout, depuis n'importe où (terminal sur Mac, Garuda ou le VPS,
claude.ai/code) :

1. elle écrit ou adapte tous les fichiers d'instructions (`CLAUDE.md`, `AGENTS.md`, brief, mémoire, design, déploiement) ;
2. elle établit un plan précis, en tâches suivies (dashboard kit-control) ;
3. elle compose une **équipe d'agents** adaptée au projet (opsec, sysop, stack, frontend, data, backend, QA, revue…), en
   reprenant ceux du kit, ceux des collections relues, ou en écrivant des agents propres au projet ;
4. elle choisit les skills nécessaires selon la stack et le domaine ;
5. elle connaît l'infra (`KNOWLEDGE.md`) pour déployer sur Coolify et Cloudflare ;
6. elle passe le relais proprement d'une session à l'autre (handoff, mémoire, workflow).

## 2. Ce qui existe déjà (on part de bonnes bases)

| Besoin | Déjà dans le kit | Manque |
|---|---|---|
| Démarrer un projet | `/new-project` : cadrage, stack, équipement, gabarit, design, déploiement, secrets | orchestration d'une équipe, plan en tâches dès le départ |
| Instructions | gabarit `CLAUDE.md`, `AGENTS.md`, `docs/brief.md`, `docs/memory/` | un fichier de relais (`handoff.md`), une rubrique « équipe » |
| Agents | 14 agents maison, `kit add-agent`, collections wshobson et VoltAgent pour `kit equip search` | agents écrits **pour** le projet (règles, commandes, chemins réels) ; rôles opsec, sysop, data, architecte, relecteur |
| Skills | registre par type, profils, `kit equip search` (skills.sh) | workflow (Superpowers) absent en session cloud ; skill design (hallmark) non référencé |
| Suivi | dashboard kit-control (`task_*`, `checkpoint`, `ask`) | — |
| Infra | skill `deploy-coolify-cloudflare`, `kit api` | **accès à `KNOWLEDGE.md`** depuis un autre projet ; consignes opsec communes |
| Partout | `install.sh` (Mac, Garuda, VPS), `install.sh --cloud` (script de démarrage de l'environnement cloud) | vérifier que l'environnement cloud a bien ce script ; plugins non chargés en cloud |

Contrainte clé (doc Claude Code) : une session cloud **ne charge pas** les plugins ni `~/.claude/` sauf si le script de
démarrage les installe ; elle lit en revanche tout ce qui est **commité dans le dépôt** (`CLAUDE.md`, `.claude/agents`,
`.claude/skills`, `.claude/commands`, `.claude/settings.json`). D'où la règle actuelle du kit, à garder : **ce dont un
projet a besoin est copié et commité dans son `.claude/`**.

## 3. La cible

```
claude-kit (public)                          fs0ciety-ops (privé)            projet X (privé)
├── global/CLAUDE.md, settings, hook         ├── KNOWLEDGE.md  ◄── lu à la   ├── CLAUDE.md, AGENTS.md
├── global/commands/                          ├── docs (Starlight)    demande ├── docs/brief.md, plan.md
│   ├── new-project.md   (orchestrateur v2)   └── services/, infra/           ├── docs/memory/ (state, decisions,
│   ├── adopt.md         (projet existant)                                    │   stack, handoff)
│   ├── handoff.md / resume.md                                                ├── .claude/agents/  (équipe)
├── global/skills/                                                            ├── .claude/skills/  (choisis)
│   ├── infra-context    (KNOWLEDGE)                                          └── .claude/settings.json (hook de
│   ├── team-builder     (compose l'équipe)                                       démarrage : état + relais)
│   ├── opsec            (règles communes)
│   └── workflow         (Superpowers, copié)
├── global/agents/ (+ architect, sysop, opsec, data, reviewer)
└── templates/project/ (+ handoff.md, plan.md, settings.json)
```

### 3.1 Orchestrateur : `/new-project` v2

Mêmes phases qu'aujourd'hui (validation à chaque phase, par `checkpoint` si le dashboard est là), avec trois ajouts :

- **Phase « Plan »** (après la stack) : `docs/plan.md` découpé en lots et tâches, chacune avec critère de fin et agent
  responsable ; tâches créées dans le dashboard (`task_create`).
- **Phase « Équipe »** (skill `team-builder`) : à partir du brief, de la stack et du plan, choisit les rôles nécessaires
  (jamais tous : 4 à 7), puis pour chacun, dans l'ordre : agent maison du kit → agent d'une collection relue
  (`kit equip search`) → agent écrit pour le projet à partir d'un modèle de rôle. Chaque agent reçoit les commandes,
  chemins et règles **réels** du projet. Résultat commité dans `.claude/agents/` et listé dans la rubrique « Équipe »
  de `CLAUDE.md` (qui fait quoi, quand le déléguer, modèle).
- **Exécution orchestrée** : la session principale ne code pas tout elle-même ; elle délègue chaque tâche à l'agent
  responsable (en parallèle quand les tâches sont indépendantes), fait relire par `reviewer` et `security-reviewer`,
  puis met à jour le plan, le dashboard et la mémoire.

### 3.2 Projet existant : `/adopt`

Pour Tandem, CSM, Atrium… : lit ce qui existe (`CLAUDE.md` riche, workflow maison), **n'écrase rien**, ajoute seulement
ce qui manque (handoff, équipe, `infra-context`, hook de démarrage) et propose un diff à valider.

### 3.3 Relais entre sessions : `handoff` et `resume`

- `docs/memory/handoff.md` : réécrit en fin de session (fait, en cours, bloquant, prochaine action exacte, questions
  ouvertes, branches et PR en cours). Court : relu à chaque démarrage.
- Hook de démarrage du projet (`.claude/settings.json`, commité, donc actif aussi en cloud) : affiche `state.md` et
  `handoff.md` en tête de session.
- `/handoff` écrit le relais et pousse ; `/resume` le relit, relit `task_list` et propose la suite.
- Pas de claude-mem (voir § 4) : la mémoire reste dans le dépôt, lisible et versionnée.

### 3.4 Connaissance de l'infra : skill `infra-context`

`KNOWLEDGE.md` reste **dans fs0ciety-ops** (privé, une seule source à jour ; jamais copié dans le kit public ni dans les
projets, où il vieillirait). Le skill dit comment l'obtenir :

- **en local** : `kit sync` garde une copie en lecture de fs0ciety-ops dans `~/.kit/context/` (`git pull`) ;
- **en session cloud** : la session attache fs0ciety-ops **en lecture** (outil `add_repo`) et lit `KNOWLEDGE.md` ;
  `docs.in` (tailnet) n'est pas joignable depuis le cloud, le dépôt l'est ;
- quand le charger : déploiement, DNS, Access, nouveau service, diagnostic ; pas pour du code applicatif.

### 3.5 Opsec : skill `opsec`

Règles déjà éparses (CLAUDE.md global, KNOWLEDGE, projets) réunies : secrets (`kit secrets`, variables cloud), données
identifiantes jamais dans un dépôt public, dépôts privés par défaut, Access ou tailnet par défaut pour une admin,
ports sur `127.0.0.1`, contenu tiers relu avant installation, `DELETE` réservé à l'utilisateur. Chargé par l'agent
`opsec` et à chaque déploiement.

### 3.6 Workflow : Superpowers copié

Les plugins ne se chargent pas en cloud : les skills de Superpowers (MIT) utiles (brainstorming, writing-plans,
executing-plans, subagent-driven-development, requesting-code-review, finishing-a-development-branch, systematic-debugging)
sont installés comme skills (profil `workflow`, global et cloud). Télémétrie coupée (`SUPERPOWERS_DISABLE_TELEMETRY=1`
dans les réglages du kit).

### 3.7 Partout

- **Machines** : `install.sh` / `kit update` (inchangé).
- **Cloud** : un environnement « kit » avec le script de démarrage du README (clone + `install.sh --cloud`), réseau
  GitHub et npm ; variables `KIT_DASH_TOKEN` et jetons de dev. À vérifier sur l'environnement actuel.
- **Téléphone** : `project-template` (Use this template) puis `/new-project` dans claude.ai/code (inchangé).

## 4. Collections (relues le 10/11/2026, aucune installée)

| Dépôt | Licence, activité | Décision proposée |
|---|---|---|
| wshobson/agents | MIT, très actif | **garder** comme source de `kit equip search` (déjà) |
| VoltAgent/awesome-claude-code-subagents | MIT, actif | **garder** (déjà) ; ne pas utiliser `install-agents.sh` (télécharge du code) |
| obra/superpowers | MIT, très actif, télémétrie désactivable | **adopter** les skills de workflow (§ 3.6) |
| Donchitos/Claude-Code-Game-Studios | MIT, actif ; 18 hooks | **source d'agents pour les jeux** (pioche relue, pas de hooks) ; gabarit pour un vrai projet de jeu |
| Nutlope/hallmark | MIT, actif ; hook d'édition, puppeteer | **profil `design`** : le skill seulement, sans son hook ni son linter navigateur |
| thedotmack/claude-mem | Apache-2.0 ; télémétrie PostHog activée par défaut, worker local, modèle « observateur » qui envoie l'activité à un fournisseur | **écarter** : `docs/memory/` + handoff font le travail sans processus ni fuite possible |

## 5. Lots (une PR par lot, chacune testée)

| Lot | Contenu | Test |
|---|---|---|
| A. Fondations | registre et `PLUGINS.md` à jour (§ 4), `agent-sources.txt` (+ Game Studios), gabarit (`handoff.md`, `plan.md`, `settings.json` avec hook de démarrage), skills `opsec` et `infra-context`, `kit sync` qui tient la copie de fs0ciety-ops | `kit project new` dans un dossier jetable ; hook affiché au démarrage |
| B. Workflow | profil `workflow` (Superpowers, télémétrie coupée), global et cloud | une session cloud de test voit les skills |
| C. Équipe | agents `architect`, `sysop`, `opsec`, `data`, `reviewer` ; modèles de rôle ; skill `team-builder` | équipe générée pour un projet fictif, relue |
| D. Orchestrateur | `/new-project` v2 (plan, équipe, exécution déléguée), `/handoff`, `/resume` | projet fictif de bout en bout jusqu'au déploiement, en cloud |
| E. Projets existants | `/adopt` ; application à un projet (CSM ou Tandem) en PR | relais et `infra-context` utilisés dans une vraie session |

Chaque lot passe par `security-reviewer` (hooks, commandes, contenu tiers) et par `writing-for-agents` (fichiers pour
agents).

## 6. Décisions

Prises le 10/11 :
- claude-mem **écarté** : `docs/memory/` + `handoff.md` versionnés dans chaque dépôt.
- `KNOWLEDGE.md` : copie locale en lecture seule de fs0ciety-ops par `kit sync` ; en cloud, dépôt attaché en lecture.
- Obsidian : **plus tard**.

En attente : l'ordre et le contenu des lots (l'utilisateur veut modifier le plan).

Questions initiales :

1. Ordre des lots A → E, une PR par lot ?
2. claude-mem écarté, `docs/memory/` + handoff à la place ?
3. Obsidian : pas maintenant (le « second cerveau » = fs0ciety-ops + `docs/memory/` des projets, versionnés) ; à
   rouvrir si tu veux écrire des notes à la main ?
4. Copie locale de fs0ciety-ops par `kit sync` : d'accord (lecture seule, jamais modifiée par le kit) ?
