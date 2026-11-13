# Règles de taille M

Copié par `kit project size M`. Retiré si le projet repasse en S.

- **Plan** : l'agent `architect` conçoit le plan en lots ; équipe de 3 à 5 agents.
- **Tests** : chaque changement de comportement ajoute ou met à jour un test ; un test de fumée couvre le parcours
  principal. `test` et `lint` avant de conclure.
- **CI** : lint, tests, build, prévisualisation.
- **Durcissement** : en-têtes de base, CSP du framework, pas de `unsafe-eval` sans besoin, `frame-ancestors` fixé,
  `object-src 'none'`.
- **Dépendances** : version vérifiée au registre à chaque ajout ; lockfile commité ; Renovate tient le reste à jour
  (`renovate.json`).
- **Relecteurs** (`code-reviewer`, `qa-tester`, `security-reviewer`, `design-critic`) : sur demande seulement.
- **Docs** : README, `DEPLOY.md`, et les décisions durables dans `docs/memory/decisions.md`.
