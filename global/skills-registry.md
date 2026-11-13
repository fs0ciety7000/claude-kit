# Registre : skills, profils et agents

Source de vérité du routage, lue par `/new-project`, `/adopt` et `kit project add`. Lis la ligne du projet ; ne charge que ce qu'elle indique.

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
| `astro-static` | `astro.config.*`, dépendance `astro`, fichiers `.astro` | `astro` | `astro`, `frontend-design` | frontend-dev, ui-designer, design-critic, qa-tester, devops |
| `autre` | rien ne correspond | | `find-skills`, puis proposer | researcher |

## Profils installables (généré par `kit registry`, ne pas éditer à la main)

<!-- kit:profiles:start -->
<!-- kit:profiles:end -->

## Harness

| Élément | Rôle |
|---|---|
| `/new-project` | démarrer : cadrage, taille, stack, plan et équipe, mise en prod |
| `/adopt` | équiper un projet existant sans rien écraser |
| `/resume`, `/handoff` | reprendre une session ; passer le relais |
| skill `project-size` | choisir la taille S, M ou L d'un projet |
| skill `team-builder` | composer l'équipe d'agents d'un projet |
| skills `infra-context`, `opsec`, `engram` | hébergement ; sécurité commune ; savoir commun (sur demande) |

## Règles

1. **Combiner** quand le projet mélange plusieurs types (Shopify + backend Go : profils `shopify` + `go`).
2. **Un skill par besoin réel** : ne pas tout charger.
3. **Manque réel** (domaine métier, stack absente) : `kit equip search <mots-clés>`, sélection relue, installation
   `--project`. Stack nouvelle : `kit registry propose <fichier.json>` ouvre la PR qui ajoute sa ligne ici.
4. **Noms de skills** : vérifiés en novembre 2026 avec `npx skills add <source> -l`. Une installation échoue : relancer
   `-l`, corriger la ligne du profil, puis `kit registry`.
