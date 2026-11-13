---
name: team-builder
description: Composer l'équipe de sous-agents d'un projet (2 à 3 rôles pour un petit projet, 4 à 7 pour un gros) à partir du brief, de la stack et du plan, en réutilisant les agents du kit et des collections relues, ou en écrivant des agents propres au projet ; les installer dans .claude/agents/ avec le contexte réel du projet. À utiliser dans /new-project, /adopt, ou quand le travail change de nature.
---

# Composer l'équipe d'un projet

**Équipe déjà en place** (`.claude/agents/` rempli, rubrique « Équipe ») : ne la recompose pas. Pour une demande
nouvelle, ajoute seulement le rôle qui manque (étapes 2 à 4 pour ce rôle) ; recompose tout seulement si le travail
change de nature (ex. une app web qui devient un jeu ou une app mobile).

## 1. Rôles nécessaires
À partir de `docs/brief.md`, `docs/memory/stack.md` et `docs/plan.md`, choisis **2 à 3 rôles** pour un petit projet (site vitrine, outil privé, prototype), **4 à 7** pour un gros, jamais tous. Les relecteurs (`code-reviewer`, `qa-tester`, `security-reviewer`, `design-critic`) n'entrent dans l'équipe que pour un projet de taille L (`project.yaml`) ou si l'utilisateur le demande. Base :

| Rôle | Quand |
|---|---|
| `architect` | conception, découpage, choix techniques, plan détaillé d'un lot |
| développement (`frontend-dev`, `backend-dev`, un spécialiste de la stack) | toujours un au moins |
| `data` | modèle de données, migrations, requêtes, import/export |
| `devops` / `sysop` | build, CI, Docker, Coolify, Cloudflare, supervision |
| `qa-tester` | tests, reproduction de bugs, vérification avant « fini » |
| `code-reviewer` | relecture de chaque PR (correction, simplicité, cohérence) |
| `security-reviewer` | toute PR qui touche à l'auth, aux secrets, à l'exposition, aux dépendances, au déploiement |
| design (`ui-designer`, `design-critic`, `copywriter`) | s'il y a une interface ou des textes visibles |
| domaine (jeu, marque, contenu, science…) | selon le brief |

## 2. Source de chaque agent, dans cet ordre
1. **Agent du kit** (`kit list`, colonne « Agents utiles » du registre) ;
2. **Agent d'une collection relue** : `kit equip search <rôle> <stack>`, lis le fichier, vérifie ses outils (`tools:`)
   et sa licence ; écarte tout ce qui demande des secrets, lance des scripts distants ou contredit le kit ;
3. **Agent écrit pour le projet** : `kit new-agent <nom> "<description>" --tools … --model … --effort …` puis
   déplace-le dans `.claude/agents/` du projet, et complète-le.

## 3. Adapter chaque agent au projet
Copie l'agent dans `.claude/agents/<nom>.md` (jamais en global pour un besoin de projet), puis :
- vérifie `model` et `effort` selon le barème du registre (conception et sécurité : opus, `high`/`xhigh` ; code,
  tests, textes : sonnet, `medium` ; infra et critique de design : `high`) ;
- restreins `tools` au nécessaire (un relecteur n'écrit pas) ;
- ajoute à la fin une section **« Ce projet »** de 10 lignes au plus : commandes réelles (install, dev, test, lint,
  build), chemins clés, conventions du `CLAUDE.md` à respecter, ce qu'il ne doit jamais toucher, à qui il rend compte ;
- skills à précharger s'il y a lieu (`skills:` dans l'en-tête, ex. `dependency-hygiene`, `opsec`, `infra-context`).

## 4. Déclarer l'équipe
- Rubrique **« Équipe »** dans `CLAUDE.md` et tableau « Équipe » de `docs/plan.md` : agent, rôle ici, modèle/effort,
  source (kit, collection, écrit pour le projet).
- Note l'équipement dans `docs/memory/stack.md` (section « Équipement »).
- Commite `.claude/agents/` : les sessions suivantes, locales ou cloud, retrouvent l'équipe.
- Un agent écrit pour le projet et réutilisable ailleurs : propose-le au kit (PR sur claude-kit, `global/agents/`).

## 5. Travailler avec l'équipe (session principale = orchestratrice)
- Chaque tâche du plan a un agent responsable ; la session principale délègue, ne code pas tout elle-même.
- Tâches indépendantes : agents lancés en parallèle ; tâches liées : à la suite, avec le résultat de la précédente
  dans le brief de la suivante.
- Brief d'un agent : objectif, fichiers concernés, contraintes, critère de fin, ce qui a déjà été écarté.
- Après chaque lot : tes vérifications (diff, tests, build) ; les relecteurs seulement en taille L ou sur demande.
- Ne fais jamais confiance à un rapport sans vérifier le résultat (diff, tests, build).
