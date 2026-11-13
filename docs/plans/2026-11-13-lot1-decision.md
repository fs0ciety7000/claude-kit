# Lot 1 du plan v2 : note de décision (13 nov. 2026)

Plan : `docs/plans/2026-11-12-harness-v2.md`. Ce lot devait prouver que la chaîne « GitHub principal, CI
auto-hébergée, déploiement » tient, et mesurer la v1. Résultat : **validé**, avec un ajout (sauvegarde).

## Ce qui est prouvé

| Point du lot 1 | Résultat |
|---|---|
| Pont GitHub → CI (dépôt privé du pont, Go, bibliothèque standard) | En production. Un push GitHub arrive au pont (webhook signé d'une GitHub App installée sur tous les dépôts), est poussé vers Forgejo, la CI tourne sur le runner auto-hébergé, le statut ✔/✘ revient sur le commit et la PR en ~25 s. |
| Statut lisible par une session cloud | Oui : les checks des PR se lisent par l'API GitHub depuis claude.ai/code. |
| Déploiement déclenché par la CI | Oui : `main` vert + tête GitHub = commit testé + application autorisée côté pont → déploiement Coolify (~1 min du push au service redéployé). L'auto-déploiement de Coolify est coupé sur ces applications. |
| Renovate (application Mend) | Oui : sa PR de configuration reçoit le statut de la CI auto-hébergée. Réglages Mend : désactiver *Silent mode*, activer *Create onboarding PRs* et *Automated PRs*. |
| Mesure de référence v1 | Faite (`docs/measure.md`) : 47 min, 23,6 M tokens (sortie 277 k, cache écrit 823 k), 5 validations, 6 agents lancés. |
| **Ajout : sauvegarde** | Le pont copie chaque dépôt GitHub (forks exclus) dans une organisation Forgejo dédiée, à chaque push et chaque jour, sans jamais perdre d'historique (réécritures conservées sous `refs/backup/…`, branches supprimées gardées, envoi par étapes des gros dépôts, commit unique trop gros mémorisé). |

## Décisions prises en route

- **Pont dédié plutôt que miroir natif de Forgejo** : un seul service fait le push vers Forgejo, le statut dans la PR,
  le déploiement et la sauvegarde ; les jetons de déploiement et de statut restent dans le pont, jamais sur le serveur
  de CI (qui exécute du code arbitraire).
- **PR de forks** : exécutées seulement pour un commit approuvé par `/ci approve <sha>` d'un écrivain, dans une
  organisation Forgejo séparée et sans secret.
- **Accès** : le pont joint Forgejo et l'API Coolify avec un jeton de service Cloudflare Access dédié ; seuls les deux
  chemins de webhook (signés) sont publics.

## Pièges à retenir (génériques)

- Coolify **injecte des variables réservées** (`COOLIFY_URL` = URL de l'application elle-même, `COOLIFY_FQDN`,
  `COOLIFY_BRANCH`…) qui écrasent une variable du même nom : ne jamais les utiliser pour sa propre configuration.
- Une **clé PEM** ou un jeton contenant `|` passés en variable Coolify arrivent altérés : base64 et « littéral ».
- Coolify masque dans ses journaux les **valeurs exactes de toutes les variables**, même non secrètes.
- Un jeton de service Access neuf n'est autorisé **nulle part** tant qu'une policy ne l'inclut pas.
- Un programme lancé en PID 1 dans un conteneur ne récupère pas les processus orphelins : `init: true`.
- Ne jamais tronquer la **sortie** d'une commande dont on lit les données (seulement les messages d'erreur).

## Ce qui change pour la suite

- Lot 2 (socle allégé) : démarré ; plan détaillé à valider avant toute modification du kit.
- Lot 3 (CI) : les gabarits de workflows par stack et la migration de la CI des dépôts du kit viennent compléter un
  pont déjà en place ; `.forgejo/workflows/` + `.fs0/bridge.yaml` deviennent la convention des projets.
- Mesure : pour la v2, chronométrer aussi le premier déploiement.
