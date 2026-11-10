---
description: Reprend un projet là où la dernière session l'a laissé : relit le relais, l'état, le plan et les tâches, vérifie le dépôt et propose la suite.
argument-hint: "[ce que tu veux faire maintenant]"
---

Reprends ce projet. Intention de l'utilisateur pour cette session, s'il en donne une : $ARGUMENTS

1. **Relis**, dans cet ordre et sans tout réafficher : `docs/memory/handoff.md`, `docs/memory/state.md`,
   `docs/memory/decisions.md` (les dernières entrées), `docs/plan.md`, la rubrique « Équipe » de `CLAUDE.md`,
   `task_list` du dashboard si kit-control est là.
2. **Vérifie le dépôt** : branche courante, retard sur `main` (`git fetch` puis comparaison), PR ouvertes et leur CI
   si un outil GitHub est disponible. Signale tout écart avec le relais (branche disparue, PR fusionnée entre-temps…).
3. **Contexte** : si la suite touche à l'infra (déploiement, DNS, Access), charge le skill `infra-context` ; si elle
   touche à un problème déjà rencontré, cherche dans Engram (skill `engram`, s'il est installé).
4. **Propose la suite** en 5 lignes au plus : la prochaine action du relais (ou celle qui découle de l'intention de
   l'utilisateur), l'agent qui s'en charge, ce qui attend une validation. Puis attends le feu vert, sauf si
   l'utilisateur a déjà dit quoi faire.

Projet sans `docs/memory/` ni `handoff.md` : propose `/adopt`.
