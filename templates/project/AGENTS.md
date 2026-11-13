# AGENTS.md

Règles communes à tous les agents de code (Claude Code, Codex, Cursor...). Format neutre : rien ici n'est propre à Claude.

## Contexte

- **Nom** : `TODO`
- **Type** : `TODO`
- **Résumé en une phrase** : `TODO`

## Commandes

```bash
install: TODO
dev:     TODO
test:    TODO
lint:    TODO
build:   TODO
```

## Structure du dépôt

```
.
├── AGENTS.md
├── CLAUDE.md
├── project.yaml        # taille (S, M, L) et réglages
├── DESIGN.md           # direction visuelle
├── DEPLOY.md           # Coolify / Cloudflare, domaine, variables (noms)
├── docs/brief.md       # objectif et périmètre
├── .env.example        # noms des variables, valeurs factices
├── secrets/            # secrets chiffrés (sops + age), commitables
└── src/                # TODO
```

## Règles de travail

1. Lis avant d'écrire : ouvre les fichiers concernés avant de les modifier.
2. Plus petit changement qui résout le problème. Pas de refactor non demandé.
3. Suis le style existant (nommage, formatage, structure).
4. Lance le build (et les tests, s'il y en a) avant de conclure ; rapporte les résultats réels.
5. Ne touche jamais à : `.env*`, `dist/`, `build/`, fichiers de lock modifiés à la main.
6. Tâche de plus de ~5 fichiers ou changement d'architecture : propose d'abord un plan.
7. Dépendances : dernière version stable vérifiée auprès du registre, jamais de mémoire.

Tests, CI, durcissement et relecteurs dépendent de la taille du projet : `docs/rules/size-*.md` (M et L).

## Sécurité

- Aucun secret dans le code, les logs ou les commits. Les secrets passent par `kit secrets`.
- Valide toutes les entrées externes ; requêtes SQL paramétrées uniquement.
- Confirmation avant toute action destructive (suppression, reset, migration de données en prod).
