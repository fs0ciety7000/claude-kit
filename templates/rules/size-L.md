# Règles de taille L

S'ajoute à `size-M.md`. Copié par `kit project size L`. Retiré si le projet repasse en S ou M.

- **Équipe** : `architect` et 4 à 7 agents.
- **Relecteurs** : après chaque lot, `code-reviewer` ; `qa-tester` sur les chemins critiques ; `design-critic` s'il y
  a une interface.
- **`security-reviewer`** : sur toute PR qui touche à l'authentification, aux secrets, à l'exposition réseau, aux
  dépendances, au déploiement ou à une donnée de tiers.
- **Tests** : en plus, les chemins critiques (authentification, paiement, écriture de données, restauration).
- **CI** : en plus, audit des dépendances (`npm audit`, `govulncheck`, `pip-audit`, `osv-scanner`…) ; échec bloquant.
  Audit lancé aussi avant de conclure un lot.
- **Durcissement** : CSP stricte (scripts hachés ou avec nonce, domaines externes listés et dits dans la PR) ;
  images épinglées par digest, actions par SHA ; conteneurs non-root, `no-new-privileges`, limites mémoire.
- **Docs** : en plus, sauvegarde et restauration décrites dans `DEPLOY.md`, restauration essayée une fois.
