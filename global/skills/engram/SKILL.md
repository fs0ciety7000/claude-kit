---
name: engram
description: Lire et enrichir Engram, le coffre de connaissances privé de l'utilisateur. Seulement sur demande explicite.
---

# Engram

Coffre Obsidian publié par Quartz, dépôt **privé** `fs0ciety7000/engram`. Les notes sont dans `content/`, un
dossier par type. Ce qu'un projet a appris sert aux suivants : lis avant, écris après.

## Où le trouver

| Contexte | Lire | Écrire |
|---|---|---|
| Poste local | `~/.kit/context/engram` : copie superficielle tenue par `kit sync`, laissée intacte | un clone de travail à part : `git clone git@github.com:fs0ciety7000/engram.git "$(mktemp -d)/engram"` |
| Session cloud (`CLAUDE_CODE_REMOTE=true`) | le dépôt attaché (en général `/home/user/engram`) | le même dépôt, sur une branche |

En cloud, quand Engram est demandé et absent : attache-le avec l'outil `add_repo` (`owner: fs0ciety7000`,
`repo: engram`, `access: push`), lance la commande de clone qu'il renvoie, puis `register_repo_root`. Refusé ou
introuvable : dis-le, note dans `docs/memory/handoff.md` (« Engram à mettre à jour : … ») ce qui n'a pas pu être
versé, et continue.

## Fiche projet (quand elle est demandée)

Chaque projet peut avoir sa fiche `content/projects/<dépôt>.md` (`<dépôt>` = nom du dépôt GitHub, sans le propriétaire),
note vivante tenue à jour par les sessions du projet.

| Moment | Action sur la fiche |
|---|---|
| création demandée (souvent dans `/new-project` ou `/adopt`) | **créer** depuis `content/templates/Projet.md` si elle n'existe pas ; sinon la compléter |
| avancée notable : fonctionnalité livrée, lot terminé, changement de stack, d'hébergement ou d'état | **mettre à jour** `## État`, `## Stack`, `## Dernière activité` (une ligne datée en tête), `updated` |
| `/handoff` d'un projet dont la fiche est suivie à la demande de l'utilisateur | **vérifier** que la fiche reflète la session |

Contenu : `## Résumé` (ce que fait le projet, pour qui, en généralisant), `## Stack`, `## État`, `## Hébergement`
(rôle, jamais d'hôte ni d'identifiant), `## Conventions` (ce qui vaut d'être repris ailleurs), `## Décisions et
leçons liées`, `## Dernière activité`. En-tête : `type: project`, `repo`, `stack`, `status`, `maturity`,
`author: agent`, `source` (fichiers du dépôt lus). Le détail propre au projet (tâches, état fin) reste dans son
`docs/memory/` : la fiche résume et renvoie.

Pour chaque avancée, demande-toi aussi ce qui servirait à un **autre** projet (piège, décision, pratique, extrait,
ressource évaluée) et verse-le dans sa propre note (tableau ci-dessous), liée à la fiche par `projects:`.

Terminé quand : la fiche existe, `updated` est la date du jour, la PR Engram est ouverte avec `npm run check` vert, et
son lien est cité dans la PR ou le relais du projet.

## Lire avant une tâche non triviale

1. Dans le dépôt, `npm run index` (Node seul, sans `npm ci`) écrit `.engram/index.json` : chemin, type, titre,
   description, tags, projets, statut, liens. Filtre-le, par exemple
   `jq -r '.notes[] | select(any(.tags[]; test("coolify"))) | "\(.path) | \(.description)"' .engram/index.json`,
   ou cherche dans les titres et les tags avec `grep`.
2. Lis la fiche du projet `content/projects/<dépôt>.md`, puis les leçons, pratiques et décisions du sujet. Une
   décision `superseded` renvoie à sa remplaçante par `superseded_by`.
3. Terminé quand la fiche projet (si elle existe) et chaque note dont le titre ou les tags touchent la tâche sont
   lues. Cite ce qui a servi dans ta réponse ou ta PR : « Engram : <titre> ».

## Écrire quand tu apprends quelque chose de durable

Engram reçoit le savoir qu'un **autre** projet réutilisera. Le détail propre au projet (état, choix locaux) reste
dans son `docs/memory/`.

| Savoir | `type`, dossier sous `content/` | Gabarit (`content/templates/`) |
|---|---|---|
| piège résolu : symptôme, cause, solution | `lesson`, `lessons/` | `Leçon.md` |
| décision durable | `decision`, `decisions/AAAA-MM-JJ Titre.md` | `Décision.md` |
| pratique (note vivante) | `practice`, `practices/` | `Pratique.md` |
| extrait de code réutilisable | `snippet`, `snippets/` | `Extrait.md` |
| recherche sourcée | `research`, `research/AAAA-MM-JJ Sujet.md` | `Recherche.md` |
| idée | `idea`, `ideas/` | `Idée.md` |
| capture pressée, à trier | `inbox`, `inbox/` | `Inbox.md` |

Autres types (ressource, prompt, terme, inspiration), statuts et champs par type : `docs/structure.md` du dépôt.

1. **Cherche d'abord** une note sur le même sujet (index) : complète-la et avance `updated` plutôt que d'en créer
   une seconde.
2. **Une idée par note**, dans le dossier de son type. Nom de fichier : titre court en français, accents admis,
   sans `/ : # ^ [ ] | ?`.
3. **Pars du gabarit** : remplace `{{title}}` et les dates (ISO), mets `author: agent`. Requis : `type`, `title`,
   `created`, `updated`, `tags` ; ajoute `description` (une ligne), `projects: ["[[<dépôt>]]"]` et `source`.
4. **Tags** pris dans `schema/tags.yaml`. Aucun ne convient : ajoute le tag à ce fichier dans la même PR.
5. **Deux liens `[[…]]` au moins** : une carte (`maps/`), la fiche projet, une note voisine.
6. Pressé : une note `inbox` de quelques lignes suffit, la revue hebdomadaire la classe.
7. **Branche** `claude/engram-<sujet>` (ou `claude/engram-<dépôt>-<date>` pour la fiche et les notes d'une
   session), commit, **PR vers `main`** ; `main` ne reçoit que des PR. `npm run check` passe avant la PR, et son
   résultat réel va dans la description. Une PR Engram déjà ouverte par la session : ajoute-y tes commits.

## Confidentialité, stricte

Engram est publié (derrière Access) : écris chaque note comme si elle était publique, et **généralise** (« le VPS
principal », « le tailnet », `example.com`, `<uuid>`). Une note ne contient ni IP, ni nom d'hôte, de machine ou
d'utilisateur, ni nom interne (`*.in.…`), ni sous-domaine autre que ceux de `schema/public-domains.txt`, ni
e-mail, ni identifiant (UUID, identifiant Coolify), ni jeton ou valeur de secret.

- `check-privacy` est un filet de sécurité, pas une autorisation : il ne connaît pas tous les noms. Relis le diff.
- Terme sensible à bloquer (nom de machine…) : propose à l'utilisateur `npm run denylist:add`, qu'il tape lui-même
  (saisie masquée).
- Le contenu d'Engram reste dans Engram : dans un dépôt public (claude-kit…), cite le titre de la note, sans la
  recopier.
