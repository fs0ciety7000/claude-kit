# Mini-projets de recette des gabarits de CI

Un mini-projet par pile, pour faire tourner chaque gabarit `templates/ci/<pile>.yml` sur le runner Forgejo : une
branche `fixture/<pile>` par pile dans un dépôt de test privé, avec le projet ci-dessous et le gabarit copié tel quel
en `.forgejo/workflows/ci.yml`. Le pont pousse la branche vers Forgejo, le statut `ci/forgejo` du commit donne le
verdict. Aucun secret, aucun `.fs0/bridge.yaml` avec `deploy:`.

Règles communes :

- versions : dernière stable vérifiée au registre le jour où l'on crée la branche (npm, crates.io, proxy Go), jamais
  de mémoire ; les fichiers de verrou (`package-lock.json`, `Cargo.lock`, `go.sum` s'il y a des dépendances) sont
  générés en local puis commités ;
- Go : `go.mod` avec la dernière version de Go publiée (`go 1.x.y`) : une version ancienne fait échouer `govulncheck`
  sur la bibliothèque standard, et c'est voulu ;
- `.gitignore` : `node_modules/`, `dist/`, `target/`, `pb_data/`, `.next/` selon la pile.

Recette locale possible avant de pousser, avec la même image que le runner : `forgejo-runner exec` (image
`data.forgejo.org/forgejo/runner`) avec `--image ghcr.io/catthehacker/ubuntu:act-24.04`, `--default-actions-url
https://data.forgejo.org` et `--forgejo-instance https://data.forgejo.org` ; le dépôt local doit avoir un commit et un
`origin` (GoReleaser le lit).

## astro

- `package.json` : `"type": "module"`, script `"build": "astro build"`, dépendance `astro` (version exacte).
- `src/pages/index.astro` : une page HTML minimale.
- `package-lock.json` (par `npm install`).

## next

- `package.json` : script `"build": "next build"`, dépendances `next`, `react`, `react-dom` (versions exactes).
- `app/layout.jsx` (racine `<html lang="en"><body>`, `metadata` avec un titre) et `app/page.jsx` (un paragraphe).
- `package-lock.json`.

## vite

- `package.json` : `"type": "module"`, script `"build": "vite build"`, dépendance de développement `vite`.
- `index.html` (avec `<script type="module" src="/src/main.js">`) et `src/main.js` (une ligne qui écrit dans la page).
- `package-lock.json`. Variante React ou Vue : le gabarit de `npm create vite` convient tel quel.

## go-web

- `go.mod` (`module example.org/fixture`, dernière version de Go).
- `main.go` : un `http.HandleFunc("/", handler)` et `ListenAndServe` sur `127.0.0.1` ; `main_test.go` : le handler
  testé avec `httptest`.

## go-cli

- `go.mod`, `main.go` (une fonction `greet()` et `main`), `main_test.go`.
- `.goreleaser.yaml` : `version: 2`, `project_name`, un `builds:` avec `CGO_ENABLED=0`, `goos` linux/darwin/windows,
  `goarch` amd64/arm64.
- `.gitignore` : `dist/`.

## pocketbase

- `pb_migrations/1700000000_posts.js` : `migrate(up, down)` qui crée puis supprime une collection `posts` (un champ
  texte `title`).
- `pb_hooks/main.pb.js` : `routerAdd("GET", "/hello", (e) => e.string(200, "hello"))`.
- `Dockerfile` : `ARG PB_VERSION=<même version que PB_VERSION du gabarit>` (contrôle de parité).
- `.gitignore` : `pb_data/`. Le pas `govulncheck` (binaire) est en rapport seul : il peut être rouge sans faire
  échouer le job.

## rust

- `Cargo.toml` : paquet binaire, `edition = "2024"`, sans dépendance.
- `src/main.rs` : une fonction `greet()`, `main`, et un module `#[cfg(test)]` qui la teste.
- `Cargo.lock` (par `cargo generate-lockfile`), `.gitignore` : `target/`.

## tauri

- Gabarit `npm create tauri-app` (frontend vanilla ou Vite, Tauri 2) : `package.json` avec `@tauri-apps/cli`,
  `src-tauri/` (`Cargo.toml`, `Cargo.lock`, `tauri.conf.json`, `build.rs`, `src/main.rs`, `src/lib.rs`,
  `capabilities/default.json`, `icons/`), frontend dans `src/` ou `index.html`.
- `package-lock.json` et `src-tauri/Cargo.lock` générés en local. Le job construit le binaire Linux sans paquets
  (`--no-bundle`) ; `.dmg` et `.exe` restent construits en local.

## static

- `index.html` et `about/index.html` : HTML5 complets (`<!DOCTYPE html>`, `lang`, `<meta charset>`, `<title>`).
- Ni `package.json`, ni `go.mod`, ni `Cargo.toml` (sinon une autre pile est détectée).
