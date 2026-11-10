---
name: dependency-hygiene
description: Choisir et tenir à jour les dépendances (paquets, images Docker, actions, runtimes) en dernière version stable et sans faille connue (CVE), vérifiées auprès des registres et des bases de vulnérabilités, jamais de mémoire. À utiliser dès qu'on ajoute, met à jour ou épingle une dépendance, crée un projet, écrit un Dockerfile ou un compose, ou répond à une alerte de sécurité.
---

# Dépendances : à jour et sans faille connue

## Principe

Ta mémoire d'entraînement a des mois de retard : une version « récente » pour toi peut être obsolète ou vulnérable.
**Toute version se vérifie auprès du registre, au moment où tu l'écris.** On prend la dernière version **stable**
(pas de bêta, RC, nightly, `latest` ou `canary`), sauf contrainte de compatibilité écrite dans `docs/memory/decisions.md`.

## 1. Trouver la dernière version stable

| Écosystème | Commande |
|---|---|
| npm, pnpm | `npm view <paquet> version` (et `npm view <paquet> time --json` pour la date) |
| Python | `pip index versions <paquet>` |
| Go | `go list -m -versions <module>` ; Go lui-même : `curl -s 'https://go.dev/dl/?mode=json' \| jq -r '.[0].version'` |
| Rust | `cargo search <crate> --limit 1` |
| Image Docker | page du registre (Docker Hub, ghcr) ; puis épingler **tag exact + digest** (`image:1.2.3@sha256:…`) |
| GitHub Action | `git ls-remote --tags https://github.com/<owner>/<action>` ; épingler le **SHA** du tag, tag en commentaire |
| Runtime (Node, Python…) | version LTS ou stable courante, depuis le site officiel |

Une version sortie il y a moins de 3 jours : attendre, sauf correctif de sécurité (une version retirée arrive).

## 2. Vérifier les failles

Avant de conclure, lance l'audit de l'écosystème et rapporte le résultat réel :

| Écosystème | Commande |
|---|---|
| npm | `npm audit --omit=dev` (pnpm : `pnpm audit --prod`) |
| Python | `pip-audit` (ou `uvx pip-audit`) |
| Go | `go run golang.org/x/vuln/cmd/govulncheck@latest ./...` |
| Rust | `cargo audit` |
| Multi-langages | `osv-scanner scan source -r .` (base OSV, gratuite) |
| Images | `trivy image <image>` si disponible |

- Faille **haute ou critique** atteignable : mettre à jour avant de livrer (même mineure) ; sinon, l'écrire dans la PR
  avec la raison (pas de correctif publié, code non atteint) et une tâche de suivi.
- Ne jamais désactiver un audit ni ajouter une exception pour obtenir du vert sans le dire.

## 3. Rester à jour

- Chaque dépôt a **Renovate** (`renovate.json` du gabarit du kit) : PR de mises à jour, épinglage des digests et des
  actions, fusion automatique des correctifs seulement si la CI est verte.
- Fichiers de verrouillage commités (`package-lock.json`, `pnpm-lock.yaml`, `go.sum`, `Cargo.lock`, `uv.lock`).
- Version majeure : lire les notes de version (changements cassants, migrations) avant de fusionner.
- Bases de données (Postgres, Redis…) : jamais de majeure automatique (dump et restauration).

## 4. Ajouter une dépendance

1. En a-t-on vraiment besoin ? (la bibliothèque standard, ou 20 lignes de code, suffisent souvent)
2. Activité (dernier commit, mainteneurs), licence compatible, nombre de dépendances transitives.
3. Dernière version stable (§ 1), audit (§ 2), verrouillage commité.
4. Le noter dans la PR : paquet, version, pourquoi.
