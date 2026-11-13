---
name: project-size
description: Choisir la taille S, M ou L d'un projet (grille de critères), en déduire rigueur et équipe, et l'écrire dans project.yaml. À utiliser au cadrage ou si project.yaml manque.
---

# Taille du projet

Tu décides, tu annonces la taille avec **une ligne de justification** ; l'utilisateur corrige d'un mot.

## Grille

| Critère | S | M | L |
|---|---|---|---|
| Fonctionnalités | 5 au plus, sans logique métier | écrans et logique métier | plusieurs sous-systèmes |
| Données | aucune ou statiques | données propres persistées | données de tiers, personnelles, paiements |
| Exposition | local, tailnet, public sans compte | Access, ou public avec formulaire | comptes pour des inconnus |
| Utilisateurs | le propriétaire | quelques personnes connues | public |
| Durée de vie | jours, semaines | mois | années, service maintenu |

Règle : la taille est le niveau atteint par **au moins deux critères**. **Un seul déclencheur suffit pour L** :
paiements, données personnelles de tiers, authentification d'inconnus, infra de prod, secrets d'autrui.

Exemples habituels : site vitrine Astro, outil privé, prototype → S. Application Next.js ou Go avec PocketBase pour
quelques proches, boutique Shopify sur mesure → M. Service public avec comptes, API Rust ou Go qui garde des données
de tiers, infra partagée → L. Cas limite entre deux tailles : prends la plus petite, sauf déclencheur L.

## Ce que chaque taille active

| | S | M | L |
|---|---|---|---|
| Relecteurs | aucun | sur demande | après chaque lot |
| Tests | build, seuils du brief | changements de comportement, fumée | + chemins critiques |
| CI | build | lint, tests, build, prévisualisation | + audit des dépendances |
| Durcissement | défauts du framework | en-têtes de base | CSP stricte, digests, SHA |
| Plan, équipe | fil principal ; 3 lots au plus ; 2-3 agents | `architect` ; 3-5 agents | `architect` ; 4-7 agents |
| Docs | README, `DEPLOY.md` | + `decisions.md` | + sauvegarde et restauration |

Les règles M et L sont dans `docs/rules/size-M.md` et `size-L.md` (gabarits : `templates/rules/`), importées par le
`CLAUDE.md` du projet. S n'importe rien.

## Écrire la taille

`project.yaml` à la racine, une paire `clé: valeur` par ligne :

```yaml
name: ma-boutique
size: M
size_reason: boutique pour quelques proches, données propres, accès restreint
stack: nextjs pocketbase
effort.devops: high
```

`effort.<agent>` est facultatif : niveau d'effort d'un agent pour ce projet.

Commandes (depuis la racine du projet) :

- `kit project size M --reason "boutique pour quelques proches, accès restreint"` écrit `project.yaml`, copie ou
  retire `docs/rules/size-*.md` et ajuste les imports de `CLAUDE.md`. Relançable ; changer de taille en cours de route
  est permis.
- `kit project effort devops high` règle l'effort d'un agent dans sa copie du projet (`.claude/agents/`).

Si la taille change (un déclencheur L apparaît), relance `kit project size` et signale-le dans `docs/memory/decisions.md`.
