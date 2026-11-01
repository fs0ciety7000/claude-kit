---
description: Démarre un projet pas à pas : cadrage, stack, design, gabarit, déploiement Coolify + sous-domaine Cloudflare, workflow. Validation à chaque phase.
argument-hint: "<description courte du projet> [--rapide]"
---

Démarre un nouveau projet à partir de cette description : $ARGUMENTS

Mode : **guidé** par défaut (une phase à la fois, validation de l'utilisateur entre les phases). Si l'argument contient `--rapide`, enchaîne les phases en prenant les choix par défaut et résume les hypothèses à la fin.

Règles de conduite :
- Avant chaque phase, annonce-la en une ligne. À la fin, demande « valide / modifie ? » en une seule question.
- Pose les questions d'une phase en une seule fois, 4 maximum. Ne demande pas ce qui se déduit de la description ou de `~/.claude/skills-registry.md`.
- N'installe, ne crée et ne déploie rien sans accord. Jamais de lecture de `.env*`. Une valeur secrète n'est jamais demandée dans le chat : `kit secrets add NOM` est lancé par l'utilisateur.
- Si le dossier courant contient déjà du code, lis-le d'abord et n'écrase rien.

## Phase 1 — Cadrage
Objectif, public, fonctionnalités indispensables (3 à 5), ce qui est hors périmètre, contraintes (délai, budget, hébergement). Écris-les dans `docs/brief.md`. Pour une idée floue, charge le skill `brainstorming` (Superpowers) à la place des questions.

## Phase 2 — Type et stack
1. Classe le projet avec la table de routage de `~/.claude/skills-registry.md` (plusieurs types possibles). Sans correspondance : `find-skills`.
2. Propose **deux options de stack** (une recommandée, une alternative), chacune avec : composants (front, back, base, auth, stockage), avantages, coût de maintenance, risque principal. Par défaut, privilégie la stack que l'utilisateur utilise déjà (Go, Rust, Next.js, React, PocketBase, Godot, Three.js, Shopify) plutôt qu'une nouveauté.
3. Après choix, liste les profils de skills et agents recommandés et installe les profils après accord : `kit skills install <profil>...`.

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
2. Sous-domaine voulu et zone DNS. Pour proposer les zones : `kit api cloudflare /zones --jq 'map({name,id})'`. Pour vérifier qu'un nom est libre : `kit api cloudflare "/zones/<id>/dns_records?name=<fqdn>" --jq 'map({type,name,content,proxied})'`. Si ces lectures échouent (jeton sans accès aux zones), dis-le et demande la zone à l'utilisateur.
3. Branche déployée, branche de préproduction éventuelle, port d'écoute, route de santé (`/health`).
4. Données persistantes (volume) et variables : noms seulement, build ou exécution.

Remplis ensuite `DEPLOY.md` : source Git, mode de build, port, santé, variables (noms), volume, domaine (FQDN), enregistrement DNS exact à créer (type, nom, cible, proxifié ou non), mode SSL/TLS Full (strict), sauvegarde, retour arrière.

Exécution (après validation de `DEPLOY.md`) : fais-le toi-même avec `kit api`, sans demander de confirmation à chaque appel, dans cet ordre : vérifier la zone et que le nom est libre, créer l'enregistrement DNS (Cloudflare), créer l'application Coolify, poser le domaine, le port et la santé, ajouter les variables (`__SECRET:NOM__` pour les valeurs secrètes), déclencher le déploiement, vérifier `running:healthy` et l'URL. Annonce chaque étape en une ligne et rapporte les résultats réels (`HTTP <code>`).

Limites :
- Si un secret manque, dis son NOM à l'utilisateur (`kit secrets add NOM`) ; ne demande jamais la valeur.
- Si un appel échoue (HTTP non 2xx, droits insuffisants du jeton), arrête-toi, rapporte le message exact et propose la correction ; ne boucle pas.
- `DELETE` est bloqué par les réglages. Ne propose jamais le mode SSL « Flexible ».

## Phase 6 — Secrets
Liste dans `.env.example` les noms de variables (valeurs factices). Lance `kit secrets check` : pour chaque nom manquant, indique à l'utilisateur de lancer lui-même `kit secrets add NOM`. Sépare dev et prod (`-e prod`).

## Phase 7 — Workflow et suite
1. Fais un premier commit propre (petits commits, un sujet par commit).
2. Propose le plan de travail : si Superpowers est installé, `writing-plans` à partir de `docs/brief.md`, puis exécution et revue par fonctionnalité.
3. Termine par un résumé de 6 lignes maximum : type, stack, fichiers créés (`CLAUDE.md`, `AGENTS.md`, `DESIGN.md`, `DEPLOY.md`, `docs/brief.md`), profils et agents à utiliser, secrets à ajouter, prochaine étape.
