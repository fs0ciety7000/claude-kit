# Règles de taille M

Copié par `kit project size M`. Retiré si le projet repasse en S.

- **Plan** : l'agent `architect` conçoit le plan en lots ; équipe de 3 à 5 agents.
- **Tests** : chaque changement de comportement ajoute ou met à jour un test ; un test de fumée couvre le parcours
  principal. `test` et `lint` avant de conclure.
- **CI** : lint, tests, build, audit des dépendances, prévisualisation. L'agent écrit, la CI vérifie : rouge, l'agent
  corrige ; vert, on fusionne.
- **Durcissement** : les défauts du framework et du gabarit (en-têtes, CSP) suffisent ; pas de chantier CSP, pas
  d'audit ni de vérification de digest à la main.
- **Dépendances** : version vérifiée au registre à chaque ajout ; lockfile commité ; Renovate tient versions et
  digests à jour (`renovate.json`).
- **Relecteurs** (`code-reviewer`, `qa-tester`, `security-reviewer`, `design-critic`) : sur demande seulement.
- **Docs** : README, `DEPLOY.md`, et les décisions durables dans `docs/memory/decisions.md`.
