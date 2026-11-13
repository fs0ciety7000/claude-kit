# Mesurer le harness (v1 contre v2)

But : comparer la v1 et la v2 sur **le même projet**, avec les mêmes chiffres : tokens, durée, validations demandées,
agents lancés, temps jusqu'au premier déploiement. Plan : `docs/plans/2026-11-12-harness-v2.md` (lots 1, 2 et 6).

## Protocole

1. Sur un poste (toujours le même), dans un dossier vide `~/dev/mesure-<v1|v2>-<date>` :
   `claude` (mode auto, modèle et effort par défaut du kit), puis coller **exactement** l'énoncé ci-dessous.
2. Répondre aux questions sans rien ajouter au-delà de l'énoncé ; choisir les options recommandées.
3. Arrêter quand le site répond en HTTPS (ou, si le déploiement n'est pas encore automatisé, quand le build passe).
   Noter l'heure du premier déploiement réussi.
4. Dans le même dossier : `scripts/measure-session.sh --json > mesure.json` (depuis le dossier du kit :
   `<kit>/scripts/measure-session.sh --json`), puis reporter les chiffres dans le tableau.

## Énoncé de référence (à coller tel quel)

> Crée un petit site vitrine en Astro pour un atelier de céramique fictif, « Terre & Feu » : une page d'accueil
> (présentation, trois photos de pièces en placeholder, horaires), une page « Ateliers » (trois formules avec prix) et
> une page « Contact » (adresse, carte statique, formulaire qui ouvre le client mail). Site statique, en français,
> responsive, sans base de données. Déploiement public sur un sous-domaine de test.

## Résultats

| Version | Date | Tokens (total) | Durée | Validations | Agents | Premier déploiement | Contexte au démarrage |
|---|---|---|---|---|---|---|---|
| v1 | 2026-11-13 | 23,6 M (sortie 277 k, cache écrit 823 k) | 47 min | 5 | 6 lancés (11 sous-agents au total, 160 messages) | non mesuré | 4 586 mots, 29 894 car. |
| v2 (lot 2) | | | | | | | |
| v2 (lot 6) | | | | | | | |

`total` additionne entrée, cache écrit, cache lu et sortie ; le cache lu domine et coûte peu : comparer aussi
`output` et `cache_write`, plus représentatifs de l'effort.

### Détail v1 (2026-11-13, poste Linux, énoncé de référence)

Session `measure` : 93 messages dans la session principale + 160 dans 11 sous-agents ; 20 messages humains ;
modèles Opus 5.5 et Sonnet 5.5. Tokens : entrée 548, cache écrit 822 829, cache lu 22 549 447, sortie 277 040.
Le premier déploiement n'a pas été chronométré (à mesurer pour la v2 : heure du premier HTTPS qui répond).

## Contexte au démarrage

Ce que le harness met dans le contexte de Claude Code avant la première question, mesuré **depuis l'arbre du dépôt**
(pas depuis `~/.claude`) par `scripts/context-budget.sh` : mots (`wc -w`) et caractères (`wc -m`). Même commande pour
la v2, à comparer à la v1 ; les budgets cibles sont dans `scripts/context-budgets.tsv`.

```bash
scripts/context-budget.sh            # tableau lisible
scripts/context-budget.sh --json     # clés stables, pour comparer deux versions (jq)
scripts/context-budget.sh --budget   # compare aux budgets ; échoue seulement avec BUDGET_ENFORCE=1
```

Les hooks de démarrage tournent dans un HOME et un projet jetables (mémoire `docs/memory/*.md` remplie au-delà du
plafond du hook), environnement purgé, mises à jour désactivées, aucun accès réseau : un hook qui en aurait besoin est
mesuré à 0 et la ligne de détail le dit. Le vrai HOME n'est jamais lu.

### v1 (branche `main` au 13/11/2026, arbre à 18 agents, 19 skills, 7 commandes)

Toujours chargé :

| Élément | Mots | Caractères | Budget v2 |
|---|---|---|---|
| CLAUDE.md global (aucun `@` importé) | 1 519 | 9 834 | 400 mots |
| Descriptions des 18 agents | 584 | 3 918 | 400 mots |
| Descriptions des 19 skills (dont 11 Superpowers) | 614 | 4 031 | 450 mots avec les commandes |
| Descriptions des 7 commandes | 139 | 845 | (idem) |
| SessionStart du kit (3 hooks) | 15 | 177 | |
| Gabarit projet `CLAUDE.md` + `AGENTS.md` | 442 | 2 960 | |
| SessionStart du projet, mémoire pleine | 1 273 | 8 129 | 1 500 caractères |
| **Total au démarrage** | **4 586** | **29 894** | ≤ 40 % de la v1 |

Détails :
- SessionStart du kit : seul `kit-emit.sh` écrit dans le contexte (identifiant de session pour kit-control, avec un
  tableau de bord configuré) ; `kit-autoupdate.sh` (réseau) est mesuré à 0 : vide quand le kit est à jour, une ligne
  après une mise à jour ; `kit-dockerd.sh` n'agit qu'en session cloud, 0 en local.
- SessionStart du projet : 8 129 caractères avec `handoff.md` et `state.md` pleins (le hook lit 4 000 octets de
  chacun), 786 caractères pour un projet neuf (gabarit non rempli, hors total).
- Les descriptions les plus longues : agents `architect` et `code-reviewer` (46 mots), `sysop` (43) ; skills
  `team-builder` (71), `dependency-hygiene` (61), `engram` (56) ; commandes `resume` (27), `adopt` (25).
- Skills installés par `kit skills install -g` (hors dépôt) et plugins ne sont pas comptés.

Sur demande, parcours `/new-project` :

| Élément | Mots | Caractères | Budget v2 |
|---|---|---|---|
| Commande `/new-project` | 2 123 | 13 692 | 900 mots |
| Registre des skills (`skills-registry.md`) | 1 180 | 7 941 | |
| Skill `team-builder` | 699 | 4 375 | |
| Superpowers : `brainstorming` | 2 658 | 15 190 | |
| Superpowers : `writing-plans` | 1 639 | 10 317 | |
| Superpowers : `subagent-driven-development` | 2 895 | 19 625 | |
| Superpowers : `executing-plans` | 2 985 | 18 258 | |
| **Superpowers sur le parcours** | **10 177** | 63 390 | 4 000 mots |
| **Total du parcours** | **14 179** | 89 398 | |

Superpowers sur le parcours : `brainstorming` (phase 1, idée floue), `writing-plans` (phase 7) puis l'exécuteur que
`writing-plans` recommande (`subagent-driven-development`) ou propose en variante (`executing-plans`). `SKILL.md`
seulement : les fichiers annexes ne sont lus qu'à la demande.

Hooks lancés par appel d'outil (`PreToolUse` + `PostToolUse` de `global/settings.json`) :

| Outil | v1 | Budget v2 |
|---|---|---|
| Bash, Read, Edit, Write, MultiEdit, NotebookEdit | 3 | 1 (Bash) |
| Grep, Glob, Task, WebFetch, outils MCP | 2 | |

Les 3 hooks d'un appel `Bash` : `guard-secrets.sh` et le hook d'émission du tableau de bord avant, ce dernier après (retiré en v2, sous-lot 2c).

### v2, état après le sous-lot 2c (arbre du dépôt, 13/11/2026)

Même commande (`scripts/context-budget.sh`), mêmes méthodes qu'en v1. 2c retire le tableau de bord (hook d'émission,
outils de tâches) et réduit le démarrage de projet à `state.md`.

| Élément | v1 mots | v1 caractères | 2c mots | 2c caractères | Budget |
|---|---|---|---|---|---|
| SessionStart du kit (2 hooks, 0 mesuré) | 15 | 177 | 0 | 0 | |
| SessionStart du projet, mémoire pleine | 1 273 | 8 129 | 228 | 1 359 | 1 500 caractères (tenu, appliqué) |
| Hooks par appel `Bash` (avant + après) | 3 | | 1 | | 1 (tenu) |
| Hooks par appel `Read`, `Edit`, `Write` | 3 | | 1 | | |
| Hooks par appel `Grep`, `Glob`, `Task`, `WebFetch`, MCP | 2 | | 0 | | |
| **Total au démarrage** | **4 586** | **29 894** | **1 768** | **11 233** | ≤ 40 % de la v1 (38 % des mots, 38 % des caractères) |

Le SessionStart du projet : `state.md` seul, coupé à une fin de ligne à 1 300 caractères au plus, plus l'en-tête et un
renvoi au fichier ; 265 caractères pour un projet neuf. Les mesures des sous-lots 2e et 2f (CLAUDE.md global,
descriptions) sont dans le tableau ci-dessus : 391 mots (CLAUDE.md), 322 (agents), 402 (skills et commandes).
Le parcours `/new-project` (5 052 mots, dont Superpowers) n'est pas touché par 2c.
