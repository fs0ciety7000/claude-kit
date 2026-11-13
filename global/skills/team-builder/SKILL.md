---
name: team-builder
description: Composer l'équipe d'agents d'un projet selon sa taille (S, M, L) à partir du brief et du plan. À utiliser dans /new-project, /adopt, ou quand le travail change de nature.
---

# Équipe d'un projet

Équipe déjà en place (rubrique « Équipe » de `CLAUDE.md`) : ne la recompose pas, ajoute le rôle qui manque.

## Choisir selon la taille (`project.yaml`)

| Taille | Équipe |
|---|---|
| S | fil principal + 1 ou 2 agents |
| M | `architect` + 3 à 5 agents |
| L | `architect` + 4 à 7 agents, avec relecteurs |

Un agent par rôle utile à ce brief, jamais tous.

## Effectif

- Conception : `architect`.
- Code : `frontend-dev`, `backend-dev`, `rust-dev`, `go-cli`, `pocketbase`, `creative-coder`.
- Infra : `devops`.
- Design et textes : `ui-designer`, `brand-identity` (L), `copywriter`, `creative-content`, `researcher`.
- Relecteurs (L, ou sur demande) : `code-reviewer`, `qa-tester`, `security-reviewer`, `design-critic`.
- Optionnels : `sysop`, `data-engineer`, `game-designer`, `android-ui-reviewer`.

Rôle sans agent : `kit equip search`, sinon `kit new-agent`.

## Installer

1. `kit project add <type>` copie les agents du type dans `.claude/agents/` ; les autres :
   `kit add-agent <nom> --project` (les optionnels aussi).
2. Effort : celui de l'en-tête ; autre niveau : `kit project effort <agent> <niveau>`.
3. Restreins `tools` au strict nécessaire.
4. Déclare l'équipe (rubrique « Équipe » de `CLAUDE.md`, tableau de `docs/plan.md`) ; commite `.claude/agents/`.

## Travailler

Un agent par lot, brief complet (objectif, fichiers, contraintes, critère de fin). Lots indépendants en parallèle.
Vérifie toi-même diff, tests et build.
