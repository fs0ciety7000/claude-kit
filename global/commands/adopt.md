---
description: Équipe un projet existant avec le harness du kit (mémoire, relais, plan, équipe d'agents, contexte d'infra) sans rien écraser ; propose un diff à valider.
argument-hint: "[ce sur quoi tu vas travailler ensuite]"
---

Équipe ce projet existant avec le harness du kit. Prochain travail prévu, s'il est donné : $ARGUMENTS

Règle d'or : **ce projet a peut-être déjà ses conventions** (CLAUDE.md riche, workflow maison, docs, CI). Tu
n'écrases rien, tu ne réécris pas ce qui existe : tu ajoutes seulement ce qui manque, et tu le relies à l'existant.

1. **Lis** : `CLAUDE.md` et ce qu'il importe, `AGENTS.md`, `README`, `docs/` (mémoire, plan, roadmap), `.claude/`
   (agents, skills, réglages), la CI, les manifestes (`package.json`, `go.mod`…), `kit detect --json`.
2. **Inventaire** (court, dans le chat) : ce qui existe déjà et tient lieu de mémoire, de plan, d'équipe ou de
   relais ; ce qui manque.
3. **Propose** une liste d'ajouts, chacun avec son fichier et son contenu en une ligne, parmi :
   - `docs/memory/` (`state.md`, `decisions.md`, `stack.md`, `handoff.md`) : seulement ceux qui manquent, en
     reprenant ce qui existe ailleurs (une roadmap existante reste la référence : le plan y renvoie) ;
   - `docs/plan.md` : le plan s'il n'y a ni plan ni roadmap, sinon un lien vers la roadmap et les tâches en cours,
     au format de `writing-plans` (lots, cases à cocher) ;
   - le hook de démarrage (`.claude/settings.json` du gabarit du kit) qui affiche `state.md` (1 500 caractères au plus), fusionné avec un
     `.claude/settings.json` existant (jamais remplacé) ;
   - une **équipe** (skill `team-builder`) adaptée au travail prévu, et une rubrique « Équipe » dans `CLAUDE.md` ;
   - les profils de skills du type de projet (`kit project add <type>`), après accord ;
   - `renovate.json` s'il manque (skill `dependency-hygiene`) ;
   - la page projet du hub de docs (`kit atlas sync`, par PR), **seulement si l'utilisateur le demande**.
4. **Validation** : une question récapitulative dans le chat. Rien n'est écrit avant.
5. **Applique** sur une branche `claude/adopt-<date>`, un commit par sujet, puis PR (titre et corps dans la langue du
   dépôt), et réponds par le lien et la liste de ce qui a été ajouté. Dépôt public (visibilité vérifiée ; inconnue =
   publique) : aucune donnée identifiante dans ce qui est ajouté, diff relu avant le push.
