---
description: Passe le relais à la prochaine session : écrit docs/memory/handoff.md et state.md, met à jour le plan et la mémoire, commite et pousse.
argument-hint: "[note libre à transmettre]"
---

Prépare la prochaine session de ce projet. Note de l'utilisateur à transmettre, s'il y en a une : $ARGUMENTS

1. **État réel** : `git status`, branche courante, commits non poussés, PR ouvertes de la branche (si un outil GitHub
   est disponible), tâches du dashboard (`task_list` si kit-control est là).
2. **`docs/memory/handoff.md`** (créé depuis le gabarit du kit s'il manque) : réécris chaque ligne, concrètement :
   - fait cette session (résultats, pas le récit) ;
   - en cours : tâche, branche, PR ;
   - **prochaine action exacte** (l'étape suivante, précise ; elle sera revérifiée et validée avant d'être lancée) ;
   - bloquant et questions ouvertes pour l'utilisateur ;
   - à savoir : pièges rencontrés, hypothèses prises ; un sujet sensible est nommé, jamais détaillé.
3. **`docs/memory/state.md`** : fait, en cours, bloquant, 3 prochaines étapes. **`decisions.md`** : ajoute toute
   décision durable prise cette session (date, décision, raison).
4. **`docs/plan.md` et tâches** : coche ce qui est fini, ajoute ce qui a été découvert ou demandé ; le dashboard
   suit à l'identique (`task_create` pour le nouveau, `task_update` `done`/`blocked` + note). Aucune tâche ne reste
   `doing` sans travail en cours.
5. **Engram, vérification obligatoire** (skill `engram`) :
   - la fiche `content/projects/<dépôt>.md` existe et reflète la session (État, Stack, Dernière activité,
     `updated`) ; sinon, crée-la ou mets-la à jour ;
   - chaque leçon, décision, pratique ou ressource réutilisable ailleurs a sa note ;
   - PR Engram ouverte, `npm run check` vert ; son lien va dans `handoff.md`. Engram inaccessible : écris dans
     `handoff.md` ce qui reste à y verser.
6. **Visibilité du dépôt** : vérifie-la (outil GitHub, ou `gh repo view --json visibility` si disponible) ; inconnue
   = publique. Dépôt public : relis le diff avant de pousser, sans aucune donnée identifiante (IP, hôte interne,
   UUID, utilisateur, e-mail).
7. **Commit** (`docs: handoff <date>`) et **push** de la branche courante. Jamais sur `main` directement si le dépôt
   travaille par PR.
8. Réponds en 5 lignes au plus : où on en est, prochaine action, ce qui attend l'utilisateur.

Ne mets dans ces fichiers ni secret ni valeur de variable ; aucune donnée identifiante si le dépôt est public.
