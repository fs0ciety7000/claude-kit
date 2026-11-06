---
description: Démarre un projet pas à pas : cadrage, stack, design, gabarit, déploiement Coolify + sous-domaine Cloudflare, workflow. Validation à chaque phase.
argument-hint: "<description courte du projet> [--rapide]"
---

Démarre un nouveau projet à partir de cette description : $ARGUMENTS

Mode : **guidé** par défaut (une phase à la fois, validation de l'utilisateur entre les phases). Si l'argument contient `--rapide`, enchaîne les phases en prenant les choix par défaut et résume les hypothèses à la fin.

Règles de conduite :
- Avant chaque phase, annonce-la en une ligne. À la fin, demande « valide / modifie ? » en une seule question. **Si les outils `mcp__kit-control__*` sont disponibles** (dashboard), la validation passe par `checkpoint` (phase + résumé en Markdown) et les questions par `ask` : l'utilisateur répond depuis le dashboard. Attends la réponse (`wait_for_answer` tant que `PENDING`), n'avance jamais sur une validation en attente.
- Pose les questions d'une phase en une seule fois, 4 maximum. Ne demande pas ce qui se déduit de la description ou de `~/.claude/skills-registry.md`.
- N'installe, ne crée et ne déploie rien sans accord. Jamais de lecture de `.env*`. Une valeur secrète n'est jamais demandée dans le chat : `kit secrets add NOM` est lancé par l'utilisateur.
- Si le dossier courant contient déjà du code, lis-le d'abord et n'écrase rien.
- **Session cloud** (claude.ai/code, `CLAUDE_CODE_REMOTE=true`) : le dépôt existe déjà (la session tourne dessus), pas de sops ni de `kit secrets`, et le conteneur est jetable : tout ce qui doit rester est commité et poussé.

## Phase 1 — Cadrage
Objectif, public, fonctionnalités indispensables (3 à 5), ce qui est hors périmètre, contraintes (délai, budget, hébergement). Écris-les dans `docs/brief.md`. Pour une idée floue, charge le skill `brainstorming` (Superpowers) à la place des questions.

## Phase 2 — Type et stack
1. Lance `kit detect --json` (indices tirés des fichiers et des dépendances), puis classe le projet avec la table de routage de `~/.claude/skills-registry.md` en t'appuyant sur ce résultat et sur la description (plusieurs types possibles ; dossier vide : la description seule décide). Sans correspondance : `find-skills`.
2. Propose **deux options de stack** (une recommandée, une alternative), chacune avec : composants (front, back, base, auth, stockage), avantages, coût de maintenance, risque principal. Par défaut, privilégie la stack que l'utilisateur utilise déjà (Go, Rust, Next.js, React, PocketBase, Godot, Three.js, Shopify) plutôt qu'une nouveauté.
3. Écris le choix validé dans `.claude/memory/stack.md` (types, stack, profils, agents).
4. Après choix, liste les profils de skills et agents recommandés, puis après accord : `kit project add <type>...`. La commande copie les agents et skills maison du type dans `.claude/` du projet (commitable, donc retrouvés à chaque session, y compris en cloud) et installe ses profils de skills au niveau projet. Si `.claude/agents/` est déjà rempli (projet créé par `kit project new <dossier> <type>...`), ne la relance que pour un type en plus.

## Phase 3 — Gabarit et instructions
1. Dossier vide ou sans `CLAUDE.md` : `kit project init .` (ne remplace rien d'existant).
2. Remplis les sections « Projet courant » de `CLAUDE.md` et `AGENTS.md` (nom, type, stack, commandes réelles, structure réelle) et la section « Spécifique à ce projet » (uniquement ce qui ne se déduit pas du code). Ne modifie pas le reste.
3. Squelette minimal adapté à la stack (dossiers, config de base, Dockerfile si déploiement Coolify). Pas de code applicatif au-delà.

## Phase 4 — Design (seulement si le projet a une interface, un jeu ou une marque)
1. Écris `DESIGN.md` : couleurs et rôles, typographie, espacements, rayons, ombres, composants, clair/sombre, principes d'accessibilité. Pars du gabarit `DESIGN.md` du dossier.
2. Web : charge `web-design-system` (plugin website-design) s'il est installé ; délègue la direction visuelle à l'agent `ui-designer`. Android : `android-ui-reviewer` pour la revue. Marque : agent `brand-identity` et skill `logo-design`. Jeu : agent `game-designer`.
3. Propose 2 directions visuelles courtes avant d'écrire `DESIGN.md`, et attends le choix.

## Phase 5 — Déploiement (Coolify + sous-domaine Cloudflare)
Si le projet ne se déploie pas (bibliothèque, outil local, prototype), saute cette phase. Sinon, remplis `DEPLOY.md` en suivant le skill `deploy-coolify-cloudflare`.

Questions (en une fois) :
1. Où : Coolify (processus, base, PocketBase, conteneur) ou Cloudflare Workers (sans état) ?
2. Sous-domaine voulu et zone DNS. Pour proposer les zones : `kit api cloudflare /zones --jq '.result | map({name,id})'`. Pour vérifier qu'un nom est libre : `kit api cloudflare "/zones/<id>/dns_records?name=<fqdn>" --jq '.result | map({type,name,content,proxied})'`. Si ces lectures échouent (jeton sans accès aux zones), dis-le et demande la zone à l'utilisateur.
3. Branche déployée, branche de préproduction éventuelle, port d'écoute, route de santé (`/health`).
4. Données persistantes (volume) et variables : noms seulement, build ou exécution.

Remplis ensuite `DEPLOY.md` : source Git, mode de build, port, santé, variables (noms), volume, domaine (FQDN), enregistrement DNS exact à créer (type, nom, cible, proxifié ou non), mode SSL/TLS Full (strict), sauvegarde, retour arrière.

Exécution (après validation de `DEPLOY.md`) : fais-le toi-même, sans demander de confirmation à chaque appel, dans cet ordre :
1. **Dépôt Git** : en session cloud, il existe déjà, passe à l'étape 2. Sinon, s'il n'existe pas, `kit repo create <nom>` dans le dossier du projet (privé par défaut ; configure aussi la clé de déploiement). Fais un premier commit propre puis `git push -u origin main`.
2. **Source Git de Coolify** : lis ce qui existe (`kit api coolify /github-apps --jq 'map({uuid,name})'` et `kit api coolify /security/keys --jq 'map({uuid,name})'`) et réutilise la GitHub App ou la clé déjà utilisée par les autres applications. Si rien ne convient, dis-le et indique à l'utilisateur ce qu'il doit connecter dans Coolify ; ne crée pas de clé privée toi-même.
3. Vérifier la zone Cloudflare et que le nom est libre, puis créer l'enregistrement DNS.
4. Créer l'application Coolify (mode Dockerfile), poser le domaine, le port et la santé, ajouter les variables (`__SECRET:NOM__` pour les valeurs secrètes).
5. Déclencher le déploiement, vérifier `running:healthy` et l'URL.
Annonce chaque étape en une ligne. Annonce chaque étape en une ligne et rapporte les résultats réels (`HTTP <code>`).

Limites :
- Si un secret manque (par exemple `GITHUB_TOKEN`), dis son NOM à l'utilisateur (`kit secrets add NOM -g`) ; ne demande jamais la valeur.
- Si un appel échoue (HTTP non 2xx, droits insuffisants du jeton), arrête-toi, rapporte le message exact et propose la correction ; ne boucle pas.
- `DELETE` est bloqué par les réglages. Ne propose jamais le mode SSL « Flexible ».

## Phase 6 — Secrets
Liste dans `.env.example` les noms de variables (valeurs factices). Puis :
- en local : lance `kit secrets check` ; pour chaque nom manquant, indique à l'utilisateur de lancer lui-même `kit secrets add NOM`. Sépare dev et prod (`-e prod`) ;
- en session cloud : indique-lui les noms à ajouter dans les variables de l'environnement cloud (jetons de dev, portée minimale). `kit api` les y lit directement.

## Phase 7 — Workflow et suite
1. Remplis `.claude/memory/state.md` (fait, prochaines étapes) et `decisions.md` (choix de stack, d'hébergement). Le dashboard les affiche.
2. Fais un premier commit propre (petits commits, un sujet par commit) et pousse-le (indispensable en session cloud).
3. Avec kit-control : crée le plan comme tâches (`task_create`, une par étape, dans l'ordre) et valide-le par un `checkpoint`.
4. Propose le plan de travail : si Superpowers est installé, `writing-plans` à partir de `docs/brief.md`, puis exécution et revue par fonctionnalité.
5. Termine par un résumé de 6 lignes maximum : type, stack, fichiers créés (`CLAUDE.md`, `AGENTS.md`, `DESIGN.md`, `DEPLOY.md`, `docs/brief.md`), profils et agents à utiliser, secrets à ajouter, prochaine étape.
