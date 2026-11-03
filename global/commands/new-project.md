---
description: Initialise un projet : détecte le type, installe les profils de skills, prépare CLAUDE.md, AGENTS.md et les secrets
argument-hint: "<description courte du projet>"
---

Démarre un nouveau projet à partir de cette description : $ARGUMENTS

Procède dans l'ordre :

1. **Classer le projet.** Lis `~/.claude/skills-registry.md` (ou `kit project types`), choisis le ou les types dans la table de routage. Si rien ne correspond, utilise `find-skills`.
2. **Questions manquantes** (3 maximum, en une seule fois) : stack exacte, commandes build/test, contraintes de déploiement. Ne demande pas ce qui se déduit de la description.
3. **Gabarit.** Si `CLAUDE.md` et `AGENTS.md` n'existent pas dans le dossier courant : `kit project init .`
4. **Agents et skills.** Annonce ce que le type apporte (profils, agents, skills maison) puis, après accord : `kit project add <type>...`. La commande copie les agents et skills maison dans `.claude/` du projet et installe les profils de skills au niveau projet. Si `.claude/agents/` est déjà rempli (projet créé par `kit project new <nom> <type>...`), ne relance `kit project add` que pour un type en plus. Signale les lignes en échec sans t'acharner. Besoin non couvert : `find-skills`, 3 candidats maximum, `kit add-skill <source> --project` après accord.
5. **Remplir** la section « Projet courant » de `CLAUDE.md` et `AGENTS.md` : nom, type, stack, commandes réelles, structure réelle. Ne modifie pas le reste.
6. **Secrets.** Liste les variables nécessaires dans `.env.example` (noms et valeurs factices). Puis :
   - en local : `kit secrets check` ; pour chaque nom manquant, dis à l'utilisateur de lancer `kit secrets add NOM` lui-même ;
   - en session cloud (`CLAUDE_CODE_REMOTE=true`, pas de sops) : dis-lui d'ajouter les noms manquants dans les variables de l'environnement cloud, avec des jetons de dev à portée minimale.
   Ne demande jamais une valeur dans le chat.
7. **Squelette minimal** adapté à la stack (dossiers, config de base, `.gitignore`). Pas de code applicatif au-delà.
8. **Commiter** `.claude/`, `CLAUDE.md`, `AGENTS.md`, `.env.example` et le squelette (indispensable en cloud : le conteneur est jetable).
9. **Résumer en 5 lignes** : type retenu, agents et skills posés, fichiers créés, secrets à ajouter, prochaine étape.

Contraintes : n'installe rien sans accord ; ne lis jamais de fichier `.env*` ; utilise les agents posés dans `.claude/agents` (et ceux de `~/.claude/agents`).
