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
   - **prochaine action exacte** (une commande ou une étape qu'on peut lancer sans réfléchir) ;
   - bloquant et questions ouvertes pour l'utilisateur ;
   - à savoir : pièges rencontrés, hypothèses prises, fichiers ou réglages sensibles.
3. **`docs/memory/state.md`** : fait, en cours, bloquant, 3 prochaines étapes. **`decisions.md`** : ajoute toute
   décision durable prise cette session (date, décision, raison).
4. **`docs/plan.md`** : coche ce qui est fini, ajoute ce qui a été découvert.
5. **Engram** : si la session a produit une leçon, une décision réutilisable ou une recherche utile au-delà de ce
   projet, applique le skill `engram` s'il est installé.
6. **Commit** (`docs: handoff <date>`) et **push** de la branche courante. Jamais sur `main` directement si le dépôt
   travaille par PR.
7. Réponds en 5 lignes au plus : où on en est, prochaine action, ce qui attend l'utilisateur.

Ne mets dans ces fichiers ni secret, ni valeur de variable, ni donnée identifiante si le dépôt est public.
