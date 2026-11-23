# Règles de taille L

S'ajoute à `size-M.md`. Copié par `kit project size L`. Retiré si le projet repasse en S ou M. Réservé aux projets
vraiment sensibles : paiements, données personnelles de tiers, comptes multi-utilisateurs avec données sensibles.

- **Équipe** : `architect` et 4 à 7 agents.
- **`security-reviewer`** : une revue avant la **première** mise en prod, puis sur demande ; pas à chaque PR.
- **Autres relecteurs** (`code-reviewer`, `qa-tester`, `design-critic`) : sur demande seulement.
- **Tests** : en plus, les chemins critiques (authentification, paiement, écriture de données, restauration).
- **CI** : l'audit des dépendances y est bloquant ; l'agent ne le relance pas à la main.
- **Durcissement** : CSP stricte (scripts hachés ou avec nonce, domaines externes listés et dits dans la PR) ;
  images épinglées par digest, actions par SHA (posés par le gabarit, tenus par Renovate) ; conteneurs non-root,
  `no-new-privileges`, limites mémoire.
- **Docs** : en plus, sauvegarde et restauration décrites dans `DEPLOY.md`, restauration essayée une fois.
