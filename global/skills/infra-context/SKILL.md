---
name: infra-context
description: Charger la connaissance de l'infrastructure de l'utilisateur (KNOWLEDGE.md du dépôt privé fs0ciety-ops) avant de déployer, toucher au DNS, à Cloudflare Access, à Coolify, à Tailscale, ou diagnostiquer un service. À utiliser dès qu'une tâche sort du code applicatif pour aller vers l'hébergement.
---

# Contexte d'infrastructure

## Où est la connaissance

- **`KNOWLEDGE.md`** du dépôt **privé** `fs0ciety7000/fs0ciety-ops` : identifiants Coolify (projets, serveurs, GitHub
  App), pièges connus, procédures, conventions. Une seule source, jamais copiée ailleurs (elle vieillirait, et le kit
  est public).
- Doc détaillée du même dépôt : `docs/src/content/docs/` (infra, runbooks, référence, suivi) ; catalogue des services :
  `reference/10-catalogue.md` ; Cloudflare et Tailscale en code : `infra/`.

## Comment l'obtenir

1. **En local** : `~/.kit/context/fs0ciety-ops/` (copie en lecture seule tenue à jour par `kit sync` / `kit update`).
   Lis `KNOWLEDGE.md` là. Ne modifie jamais cette copie : un changement passe par une PR sur le dépôt.
2. **En session cloud** (`CLAUDE_CODE_REMOTE=true`) : lis-le dans `fs0ciety-ops` s'il est attaché à la session (c'est
   le cas dans l'environnement « kit »). Sinon, **demande à l'utilisateur** de l'attacher ; ne l'attache pas toi-même.
   Le tailnet (`*.in.fs0ciety.org`) n'est pas joignable depuis le cloud ; le dépôt l'est.
3. Ni l'un ni l'autre : dis-le, et demande à l'utilisateur plutôt que de deviner un identifiant.

## Quand

- Avant : déploiement, nouvelle application ou service, domaine, DNS, Access, tunnel, port, volume, variable Coolify,
  sauvegarde, diagnostic d'un service.
- Pas pour du code applicatif pur.

## Règles

- Session ouverte sur un dépôt **public** (claude-kit) : ne charge pas ce contenu, sauf demande expresse de
  l'utilisateur, et n'en recopie rien dans ce dépôt.

- Données identifiantes (IP, hôtes internes, UUID, utilisateurs, e-mails) : jamais recopiées dans un autre dépôt, une
  PR publique, ou le kit. Les domaines publics des sites sont admis.
- Ce que tu apprends sur l'infra (piège, procédure, identifiant nouveau) va dans `KNOWLEDGE.md` par PR sur
  fs0ciety-ops ; une leçon générale (sans donnée identifiante) va aussi dans Engram (skill `engram`).
- Changements Cloudflare ou Tailscale : par `fs0ciety-ops/infra/` (OpenTofu) ; `tofu apply` est lancé par l'utilisateur.
