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

| Agent | Quand le déléguer | Accès | Modèle |
|---|---|---|---|
| `ui-designer` | concevoir/refondre des écrans, tokens, hiérarchie | lecture + écriture | opus |
| `design-critic` | relire une UI (hiérarchie, contraste, cohérence, états) | lecture seule | sonnet |
| `android-ui-reviewer` | relire du Compose / Material 3 | lecture seule | sonnet |
| `frontend-dev` | implémenter React/Next/Tailwind | lecture + écriture + shell | sonnet |
| `backend-dev` | Go, Rust, PocketBase, API, base de données | lecture + écriture + shell | sonnet |
| `qa-tester` | écrire/lancer des tests, reproduire des bugs, vérifier | lecture + écriture + shell | sonnet |
| `brand-identity` | positionnement, logo, palette, typographies, charte | lecture + écriture + shell | opus |
| `game-designer` | GDD, boucles, systèmes, équilibrage, niveaux | lecture + écriture | opus |
| `creative-coder` | Three.js, shaders, animation, effets Godot | lecture + écriture + shell | sonnet |
| `creative-content` | scripts vidéo, posts, concepts, idées de campagnes | lecture + écriture + web | sonnet |
| `copywriter` | textes de pages, microcopie UX, FR/EN | lecture + écriture | sonnet |
| `devops` | Coolify, Cloudflare, Docker, CI, diagnostics de déploiement | lecture + écriture + shell | sonnet |
| `security-reviewer` | secrets, auth, dépendances, injection, permissions | lecture + shell | opus |
| `researcher` | recherche web sourcée, comparaisons | lecture + web | haiku |

Le modèle de chaque agent est fixé dans son en-tête (`model:`) : opus pour la conception et la sécurité, sonnet pour le code, les tests et les textes, haiku pour la recherche. Il s'applique quel que soit le modèle de la session.

## Profils installables (généré par `kit registry`, ne pas éditer à la main)

<!-- kit:profiles:start -->
<!-- kit:profiles:end -->

## Règles

1. **Toujours actifs** : `writing-for-agents` dès qu'on écrit un fichier destiné à un agent ; Superpowers pour le workflow.
2. **Combiner** quand le projet mélange plusieurs types (ex. Shopify + backend Go : profils `shopify` + `go`).
3. **Ne pas tout charger** : un skill par besoin réel.
4. **Skill ou agent manquant** (domaine métier, stack absente) : `kit equip search <mots-clés>`, sélection relue, validation (`equip` de kit-control), installation au niveau du projet. Stack nouvelle : `kit registry propose <fichier.json>` ouvre la PR qui ajoute sa ligne ici.
5. **Noms de skills** : vérifiés en novembre 2026 avec `npx skills add <source> -l`, sauf `compose-pro` (dépôt non clonable lors du test). Les dépôts évoluent : si une installation échoue, relance `-l`, corrige la ligne du profil et `kit registry`.
