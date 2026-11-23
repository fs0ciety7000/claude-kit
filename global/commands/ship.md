---
description: "Met le projet en ligne : PR d'infra, application Coolify, pont, puis vérifie le HTTPS (kit ship)."
argument-hint: "[dossier du projet, défaut : ici]"
---

Mets en ligne le projet de ce dossier (ou `$ARGUMENTS`) avec `kit ship`. Charge les skills `infra-context` et
`deploy-coolify-cloudflare`. Annonce chaque écriture en une ligne.

1. **Prérequis** : `project.yaml` a `name`, `expose` (`none|tailnet|access|public`), `domain` (sauf `none`),
   `health_path`, `volumes`. Manquant : écris-les. Tests, lint et build verts.
   `ship.conf` absent : modèle `docs/ship.conf.example` du kit, arrête-toi. `previews: true` (web, M ou L) :
   après `kit ship previews setup` (PR d'infra unique). Préviens : toute branche du dépôt est construite sur le
   serveur de prod avant revue et CI.
2. **Plan** : `kit ship plan`. Résume-le.
3. **Validation** : seulement si `coolify_uuid` est vide (première mise en prod) et hors `mode: fast` : demande
   l'accord et attends-le. Mode rapide : enchaîne.
4. **Infra** (si le plan annonce des ajouts) : `kit ship infra`. Donne au propriétaire le lien de la PR et la suite :
   relire, fusionner, `tofu plan`, `tofu apply`. **Attends sa confirmation** ; ne lance jamais tofu.
5. **Application** : `kit ship app`. Lis les lignes `HTTP <code>`. Variables manquantes : leurs **noms** et les commandes
   (`kit secrets add NOM`, puis `POST …/envs` avec `__SECRET:NOM__`), jamais de valeur ; `POST` une fois présents.
6. **Déploiement** : `.fs0/bridge.yaml` et `project.yaml` partent dans une PR du projet ; après fusion sur `main` et CI
   verte, le pont déploie. Aucun `TRIGGER /deploy` après une fusion. Seulement si rien n'est à fusionner : le
   `TRIGGER` que `kit ship app` affiche, une fois.
7. **Attente** : `kit ship status --wait 900`. Échec : lis les logs de build (`GET /deployments/…`) avant tout nouvel
   essai ; pas de relance en boucle. Derrière Access, un 3xx est attendu.
8. **Mémoire** : `project.yaml` (`coolify_uuid` écrit par `kit ship app`, `domain`), `DEPLOY.md` (cible, domaine,
   variables par nom, retour arrière), `docs/memory/state.md` (fait, URL, prochaines étapes). Commit sur la branche
   de travail, puis `kit atlas sync` (hub de docs, par PR ; pas en mode rapide).
9. **Rapport** (5 lignes) : URL et code HTTPS, PR d'infra, variables absentes, retour arrière (redéployer le commit
   précédent ; retirer DNS ou Access par PR ; l'application se supprime dans l'interface).

Jamais de `DELETE`, de valeur de secret affichée, ni d'identifiant d'infra (UUID, tunnel, IP) recopié dans un dépôt
public.
