# Plugins à ajouter dans Claude Code

Les commandes `/plugin ...` sont des commandes **slash de Claude Code** : elles se tapent dans Claude Code, pas dans le terminal, donc `install.sh` ne peut pas les lancer.

Un plugin peut embarquer des **hooks** (commandes exécutées sur ta machine) : avant `/plugin install`, relis son dossier `hooks/` et son `plugin.json`. Sur le VPS, installe le strict nécessaire.

## Vérifiés (pages GitHub lues)

| Plugin | Utilité | Commandes |
|---|---|---|
| **Superpowers** (obra) | workflow : brainstorming, plan, TDD, revue | `/plugin marketplace add obra/superpowers` puis `/plugin install superpowers@superpowers-marketplace` |
| **Cloudflare** (cloudflare/skills, Apache-2.0) | wrangler, Workers, Durable Objects, Next sur Cloudflare, MCP Cloudflare | `/plugin marketplace add cloudflare/skills` puis `/plugin install cloudflare@cloudflare` |
| **logo-design** (kaankiziltug, MIT) | logos SVG, tests de lisibilité, export d'icônes et favicons | `/plugin marketplace add kaankiziltug/logo-design-skill` puis `/plugin install logo-design@logo-design-skill` |
| **web-animation-skills** (iart-ai, MIT, jeune projet) | GSAP, 60 fps, micro-interactions, Lottie, SVG | `/plugin marketplace add iart-ai/web-animation-skills` puis `/plugin install web-animation-skills` |
| **ponytail** (DietrichGebert, MIT) | pousse l'agent à écrire le minimum de code ; `/ponytail-review`, `/ponytail-audit` (a des hooks : à relire) | `/plugin marketplace add DietrichGebert/ponytail` puis `/plugin install ponytail@ponytail` |
| **Agents VoltAgent** | 100+ sous-agents génériques par catégorie | `/plugin marketplace add VoltAgent/awesome-claude-code-subagents` puis `/plugin install voltagent-qa-sec` (ou `voltagent-core-dev`, `voltagent-lang`...) |

## À utiliser comme gabarit, pas en global

- **Claude-Code-Game-Studios** (Donchitos, MIT) : 49 agents et 74 commandes pour un projet de jeu (Godot 4, Unity, Unreal). Trop lourd pour du global : clone-le comme base d'un projet de jeu (`git clone ... mon-jeu`, puis `/start`), ou pioche 3 ou 4 agents avec `kit add-agent gh:Donchitos/Claude-Code-Game-Studios/<chemin>.md`.

## Non vérifié ou faible

- **Three.js** : le « Three.js-Claude-Skill-Package » (24 skills) a 23 étoiles et ses commandes d'installation pointent vers une autre organisation que celle du dépôt affiché : relis-le avant tout usage. En attendant, le profil `threejs` installe trois skills vérifiés du pack gamedev (`threejs-scene-setup`, `threejs-materials-lighting`, `threejs-gltf-loading`) ; complète-les avec `kit new-skill`.
- **Rust** : aucun skill relu en dehors de `rust-backend` (profil `rust`).
- **PocketBase** : rien trouvé ; le skill maison `pocketbase` du kit comble le trou.

## MCP

- **Coolify** : `kit mcp setup` (le jeton est lu depuis tes secrets chiffrés, jamais écrit dans la config). Le projet est petit et sa dernière mise à jour vue date de février 2026 : relis-le et épingle une version.
- **Cloudflare** : fourni par le plugin Cloudflare ci-dessus.
