---
description: "Mode rapide : de l'idée à l'app en ligne, sans validation du plan."
argument-hint: "<idée en une phrase>"
---

Livre vite cette idée, en mode rapide : $ARGUMENTS

Aucune attente : tu décides et avances ; une ligne par jalon.

## 1. Hypothèses (3 lignes, sans attendre)
- **Pile** : la plus simple (site vitrine : Astro).
- **MVP** : 3 fonctionnalités au plus.
- **Reporté** : le reste, nommé. Trop gros : coupe. Ex. navigateur sur ungoogled-chromium et
  WebKit : v0 coquille Rust (Tauri ou wry) sur la WebView du système, v1 CEF.

## 2. Squelette
`kit new <nom> --fast --stack <pile>` (taille S, `mode: fast` ; en cloud, sur place dans le dépôt vide cloné).
Projet existant : `kit project mode fast`.

## 3. Construction
- Le fil principal code ; `docs/plan.md` court, sans validation. Un agent au plus pour un gros morceau séparable ;
  interface : `ui-designer` puis `frontend-dev`.
- **Interface** (web, Tauri, tout front) : vrai passage design, rapide.
  1. `ui-designer` (fil principal si trivial) choisit seul : références du propriétaire, sinon direction moderne
     et assumée, jamais l'allure par défaut (Starlight, Bootstrap). `DESIGN.md` court : palette et rôles, échelle
     typographique (1-2 polices auto-hébergées), espacements, 4 à 6 composants.
  2. `frontend-dev` : mobile d'abord, contraste AA, focus, sémantique, peu de JS, vrais textes.
  3. Captures Playwright (bureau, mobile, clair et sombre) envoyées au premier jalon, sans attendre ; le
     propriétaire réoriente d'un mot.
- Jamais : `team-builder`, `brainstorming`, `brand-identity` (sauf demande), CSP au-delà des défauts, relecteurs,
  audit manuel, `kit atlas sync`.
- Site statique (Astro, Vite) : ni Dockerfile ni nginx, Coolify le construit et le sert.
- Une PR par fonctionnalité ; **fusionne-la toi-même** dès que la CI est verte.

## 4. Validations
Seulement : suppression, migration de données en prod, deux échecs consécutifs.

## 5. Mise en ligne
`/ship` à la demande du propriétaire, sans validation dans le chat ; DNS ou Access : son `tofu apply` reste la porte.

## 6. Fin
`docs/memory/state.md`, push ; rapport : URL, fait, reporté, suite.

Projet qui grandit : `kit project mode normal`.
