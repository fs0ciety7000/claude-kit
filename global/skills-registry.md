# Registre : skills, profils et agents

Source de vérité du routage. Lis la ligne qui correspond au projet ; ne charge que ce qu'elle indique.

## Table de routage (type de projet → profils et skills)

| Type de projet | Détection | Profils à installer | Skills à charger en priorité | Agents utiles |
|---|---|---|---|---|
| `web-frontend` | React, Next, Vue, Svelte, CSS, `package.json` + composants | `web`, `design` | `vercel-react-best-practices`, `web-design-guidelines`, `design-taste-frontend` | frontend-dev, ui-designer, design-critic, qa-tester |
| `nextjs-cloudflare` | `wrangler.*`, `open-next`, Next sur Workers | `web`, `cloud` | `nextjs-on-cloudflare`, `workers-best-practices`, `wrangler` | frontend-dev, devops, qa-tester |
| `design-ui` | maquette, design system, refonte d'interface | `design` | `design-taste-frontend`, emilkowalski, `web-design-guidelines` | ui-designer, design-critic, copywriter |
| `android` | `build.gradle*`, Kotlin, Compose | `android`, `design` | `compose-pro` | android-ui-reviewer, ui-designer, qa-tester |
| `shopify` | `*.liquid`, `shopify.app.toml`, Admin API | `shopify`, `design` | `shopify` | frontend-dev, copywriter, qa-tester |
| `gamedev-godot` | `project.godot`, `.gd`, `.tscn` | `game` | `godot-gdscript`, `godot-nodes-scenes`, `game-feel`, `level-design` (pack gamedev) | game-designer, creative-coder, qa-tester |
| `threejs-3d` | `three`, `@react-three/fiber`, shaders | `threejs`, `web` | `threejs-scene-setup`, `threejs-materials-lighting`, `threejs-gltf-loading` (peu nombreux : écris les tiens avec `kit new-skill`) | creative-coder, frontend-dev |
| `motion` | GSAP, Framer Motion, Lottie, SVG animé | `design` | `animate`, `gsap-web`, `micro-interaction`, `accessible-animation` | creative-coder, ui-designer |
| `backend-go` | `go.mod`, `*.go` | `go` | `golang-how-to` (orchestrateur : charge les autres `golang-*` selon la tâche) | backend-dev, qa-tester, security-reviewer |
| `backend-rust` | `Cargo.toml`, `*.rs` | `rust` | `rust-backend` | backend-dev, qa-tester, security-reviewer |
| `pocketbase` | `pb_data/`, `pb_hooks/`, `pb_migrations/` | (skill maison) | `pocketbase` | backend-dev, security-reviewer |
| `deploy` | Coolify, Cloudflare, Docker, DNS | `cloud` | `deploy-coolify-cloudflare`, `secrets-handling`, `wrangler` | devops, security-reviewer |
| `brand` | logo, identité visuelle, charte | `brand` | `logo-design` | brand-identity, copywriter, ui-designer |
| `content` | scripts, posts, vidéos, newsletters | `media` | (selon le besoin) | creative-content, copywriter, researcher |
| `meta-agents` | écrire CLAUDE.md, SKILL.md, prompts | `meta` | `writing-for-agents` | (toi) |
| `autre` | rien ne correspond | | `find-skills`, puis proposer | researcher |

## Agents (sous-agents maison)

| Agent | Quand le déléguer | Accès | Modèle | Effort |
|---|---|---|---|---|
| `ui-designer` | concevoir/refondre des écrans, tokens, hiérarchie (après `brand-identity` pour une interface ou une marque nouvelle) | lecture + écriture | opus | high |
| `design-critic` | relire une UI (hiérarchie, contraste, cohérence, états) | lecture seule | sonnet | high |
| `android-ui-reviewer` | relire du Compose / Material 3 | lecture seule | sonnet | medium |
| `frontend-dev` | implémenter React/Next/Tailwind | lecture + écriture + shell | sonnet | medium |
| `backend-dev` | Go, Rust, PocketBase, API, base de données | lecture + écriture + shell | sonnet | medium |
| `qa-tester` | écrire/lancer des tests, reproduire des bugs, vérifier | lecture + écriture + shell | sonnet | medium |
| `brand-identity` | positionnement, logo, palette, typographies, charte | lecture + écriture + shell | opus | high |
| `game-designer` | GDD, boucles, systèmes, équilibrage, niveaux | lecture + écriture | opus | high |
| `creative-coder` | Three.js, shaders, animation, effets Godot | lecture + écriture + shell | sonnet | medium |
| `creative-content` | scripts vidéo, posts, concepts, idées de campagnes | lecture + écriture + web | sonnet | medium |
| `copywriter` | textes de pages, microcopie UX, FR/EN | lecture + écriture | sonnet | medium |
| `devops` | Coolify, Cloudflare, Docker, CI, diagnostics de déploiement | lecture + écriture + shell | sonnet | high |
| `security-reviewer` | secrets, auth, dépendances, injection, permissions | lecture + shell | opus | xhigh |
| `architect` | concevoir avant de coder : découpage, choix argumentés, plan d'un lot | lecture + web | opus | high |
| `sysop` | exploiter l'infra : santé, journaux, DNS/Access, bascules (charge `infra-context`, `opsec`) | lecture + shell | sonnet | high |
| `data-engineer` | schémas, migrations, requêtes, import/export, intégrité des données | lecture + écriture + shell | sonnet | high |
| `code-reviewer` | relire chaque PR : correction, tests, simplicité, cohérence | lecture + shell | sonnet | high |
| `researcher` | recherche web sourcée, comparaisons | lecture + web | sonnet | medium |

Le modèle et l'effort de chaque agent sont fixés dans son en-tête (`model:`, `effort:`) : opus pour la conception (design, marque, jeu) et la sécurité, sonnet pour le code, les tests, les textes et la recherche ; effort `high` pour le design, l'infra et la conception, `xhigh` pour la sécurité, `medium` ailleurs. Ils s'appliquent quel que soit le modèle de la session (`CLAUDE_CODE_EFFORT_LEVEL`, s'il est défini, prime sur `effort`). Agent d'une collection sans `model:` : il prend le modèle de la session ; en l'installant, ajoute `model:` et `effort:` selon ce barème.

## Profils installables (généré par `kit registry`, ne pas éditer à la main)

<!-- kit:profiles:start -->
<!-- kit:profiles:end -->

## Harness (toujours disponibles)

| Élément | Rôle |
|---|---|
| `/new-project` | démarrer : cadrage, stack, équipement, **plan et équipe**, gabarit, design, déploiement, exécution orchestrée, relais |
| `/adopt` | équiper un projet existant (mémoire, relais, plan, équipe, hook de démarrage) sans rien écraser |
| `/resume` | reprendre : relais, état, plan, tâches, dépôt, puis proposer la suite |
| `/handoff` | passer le relais : `docs/memory/handoff.md`, état, plan, commit et push |
| skill `team-builder` | composer l'équipe d'agents d'un projet |
| skill `infra-context` | lire `KNOWLEDGE.md` (copie locale ou dépôt attaché en cloud) avant de toucher à l'hébergement |
| skill `opsec` | règles de sécurité opérationnelle communes |
| workflow (Superpowers) | 11 skills copiés dans le kit à un commit relu (`vendor/superpowers/`) : brainstorming, plans, exécution par sous-agents, revue, débogage, TDD, vérification, fin de branche |

## Règles

1. **Toujours actifs** : `writing-for-agents` dès qu'on écrit un fichier destiné à un agent ; `dependency-hygiene` dès qu'on ajoute, met à jour ou épingle une dépendance ; Superpowers pour le workflow.
2. **Combiner** quand le projet mélange plusieurs types (ex. Shopify + backend Go : profils `shopify` + `go`).
3. **Ne pas tout charger** : un skill par besoin réel.
4. **Skill ou agent manquant** (domaine métier, stack absente) : `kit equip search <mots-clés>` (skills.sh + index local de 12 collections, `global/agent-sources.txt`), sélection relue, validation (`equip` de kit-control), installation au niveau du projet. Stack nouvelle : `kit registry propose <fichier.json>` ouvre la PR qui ajoute sa ligne ici.
5. **Noms de skills** : vérifiés en novembre 2026 avec `npx skills add <source> -l`, sauf `compose-pro` (dépôt non clonable lors du test). Les dépôts évoluent : si une installation échoue, relance `-l`, corrige la ligne du profil et `kit registry`.
