---
description: Initialise un projet : détecte le type, installe les profils de skills, prépare CLAUDE.md, AGENTS.md et les secrets
argument-hint: "<description courte du projet>"
---

Démarre un nouveau projet à partir de cette description : $ARGUMENTS

Procède dans l'ordre :

1. **Classer le projet.** Lis `~/.claude/skills-registry.md`, choisis le ou les types dans la table de routage. Si rien ne correspond, utilise `find-skills`.
2. **Questions manquantes** (3 maximum, en une seule fois) : stack exacte, commandes build/test, contraintes de déploiement. Ne demande pas ce qui se déduit de la description.
3. **Gabarit.** Si `CLAUDE.md` et `AGENTS.md` n'existent pas dans le dossier courant : `kit project init .`
4. **Skills.** Propose les profils du registre pour ce type et installe-les après accord : `kit skills install <profil>...` (niveau projet). Signale les lignes en échec sans t'acharner.
5. **Remplir** la section « Projet courant » de `CLAUDE.md` et `AGENTS.md` : nom, type, stack, commandes réelles, structure réelle. Ne modifie pas le reste.
6. **Secrets.** Liste les variables nécessaires dans `.env.example` (noms et valeurs factices). Puis `kit secrets check` : pour chaque nom manquant, dis à l'utilisateur de lancer `kit secrets add NOM` lui-même. Ne demande jamais une valeur dans le chat.
7. **Squelette minimal** adapté à la stack (dossiers, config de base, `.gitignore`). Pas de code applicatif au-delà.
8. **Résumer en 5 lignes** : type retenu, profils et agents recommandés, fichiers créés, secrets à ajouter, prochaine étape.

Contraintes : n'installe rien sans accord ; ne lis jamais de fichier `.env*` ; les agents sont dans `~/.claude/agents`, utilise-les.
