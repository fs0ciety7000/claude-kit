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

Règle : la taille est le niveau atteint par **au moins deux critères**. L, réservé aux projets vraiment
sensibles, exige **deux critères forts** (paiements, données personnelles de tiers, comptes d'inconnus) ; un seul ne
suffit pas.

Exemples : site vitrine Astro, outil privé, prototype → S. Application Next.js ou Go avec PocketBase pour
quelques proches, boutique Shopify sur mesure → M. Service public avec comptes et paiements, API multi-utilisateurs
qui garde des données personnelles de tiers → L. Cas limite : la plus petite.

## Ce que chaque taille active

| | S | M | L |
|---|---|---|---|
| Relecteurs | aucun | sur demande | une revue de sécurité avant la première prod |
| Tests | build, seuils du brief | changements de comportement, fumée | + chemins critiques |
| CI | build, audit | lint, tests, build, audit, prévisualisation | + audit bloquant |
| Durcissement | défauts du framework | défauts du gabarit | CSP stricte, digests, SHA |
| Mode | `fast` (`/fast`) | `normal` | `normal` |
| Plan, équipe | fil principal ; au plus designer et dev front | `architect` ; 3-5 agents | `architect` ; 4-7 agents |
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
  retire `docs/rules/size-*.md` et ajuste les imports de `CLAUDE.md`. `mode` absent : fast en S, normal sinon.
  Relançable.
- `kit project effort devops high` règle l'effort d'un agent dans sa copie du projet (`.claude/agents/`).

Si la taille change (deux critères forts apparaissent), relance `kit project size` et signale-le dans `docs/memory/decisions.md`.
