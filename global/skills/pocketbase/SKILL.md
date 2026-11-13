---
name: pocketbase
description: "Développer avec PocketBase : collections, règles d'API, hooks, migrations, déploiement. À utiliser si un projet contient pb_data, pb_hooks ou pb_migrations."
---

# PocketBase

PocketBase change d'API entre versions (la 0.23 a renommé des notions et des hooks). **Avant d'écrire du code, lis la version** : `./pocketbase --version`, et appuie-toi sur la documentation de cette version (pocketbase.io/docs). En cas de doute, dis ce que tu n'as pas pu vérifier.

## Structure d'un projet
- `pb_data/` : base SQLite, fichiers uploadés, sauvegardes. **Jamais dans git**, toujours sur un volume persistant en production.
- `pb_migrations/` : migrations JS générées quand tu modifies le schéma depuis le dashboard. **À versionner** et à relire.
- `pb_hooks/` : fichiers `*.pb.js` chargés au démarrage (logique serveur légère, routes, validations).
- Lancer : `./pocketbase serve` (dashboard sur `/_/`). Étendu en Go : `pocketbase.New()` puis `app.Start()`.

## Règles d'API (le point de sécurité n°1)
Chaque collection a des règles : liste, lecture, création, modification, suppression.
- règle **verrouillée** (vide/nulle côté dashboard : réservé aux superutilisateurs) ≠ règle **chaîne vide** (ouvert à tous) : ne confonds pas les deux ; vérifie leur sens dans la doc de la version.
- Exemples d'expressions : `@request.auth.id != ""` (connecté), `owner = @request.auth.id` (propriétaire).
- Pour chaque collection, écris la règle la plus stricte qui permet l'usage et teste avec un utilisateur non connecté et un autre utilisateur.
- Les champs sensibles (email, rôle) ne doivent pas être modifiables par l'utilisateur lui-même sans règle explicite sur `@request.body`.

## SDK JavaScript
- `const pb = new PocketBase(url)` ; données : `pb.collection('posts').getList(page, perPage, { filter, sort })`, `getOne`, `create`, `update`, `delete` ; auth : `pb.collection('users').authWithPassword(email, mdp)` ; état : `pb.authStore`.
- Filtres avec valeurs utilisateur : utilise la liaison de paramètres du SDK (`pb.filter("title ~ {:q}", { q })` dans les versions récentes) au lieu de concaténer du texte.
- Temps réel : `pb.collection('x').subscribe('*', cb)` ; pense à `unsubscribe` au démontage.

## Migrations et schéma
- Modifie le schéma via le dashboard en local, **commite la migration générée**, applique-la en production par le démarrage de l'application. Ne modifie jamais le schéma de production à la main.
- Une migration doit pouvoir être annulée ; teste-la sur une copie de `pb_data`.

## Production
- Un seul processus par `pb_data` (SQLite, un seul écrivain). Pas de réplicas qui partagent le même volume.
- Volume persistant pour `pb_data` (Coolify : stockage persistant), sauvegardes planifiées et **test de restauration**.
- Derrière un proxy HTTPS ; domaines autorisés et SMTP configurés dans les réglages.
- Création du superutilisateur : privilégie le lien de première installation du dashboard. Évite de passer un mot de passe en argument de commande (visible dans l'historique et la liste des processus).

## Pièges
- Oublier une règle d'API = collection publique.
- Committer `pb_data/` ou un `.env`.
- Mettre à jour le binaire sans lire les notes de version et sans sauvegarde.
- Lancer deux instances sur le même dossier de données.
