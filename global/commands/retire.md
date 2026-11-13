---
description: "Retire un service mis en ligne par kit ship : arrêt, pont, PR d'infra, expose: none (kit retire)."
argument-hint: "[dossier du projet, défaut : ici]"
---

Retire le projet de ce dossier (ou `$ARGUMENTS`) avec `kit retire`. Charge le skill `infra-context`. Le service
passe hors ligne : rien ne s'écrit avant l'accord du propriétaire.

1. **Plan** : `kit retire plan`. Montre en quelques lignes : prévisualisations coupées, application arrêtée, `DEPLOY_ALLOW`,
   `deploy:` retiré, entrées d'infra retirées ou signalées comme différentes.
2. **Validation** : demande l'accord explicite dans le chat (mise hors ligne d'un service de production) et
   attends-le. Sans accord, arrête-toi.
3. **Exécution** : `kit retire run`. Lis les lignes `HTTP <code>`. Un refus (application d'un autre dépôt,
   `DEPLOY_ALLOW` illisible ou vérification en échec, verrou) : rapporte le message exact, ne contourne pas.
4. **Infra** : donne le lien de la PR `retire/<nom>`. Les entrées « à régler à la main » restent dans le dépôt
   d'infra : liste-les pour le propriétaire, ne les modifie pas toi-même.
5. **Projet** : `project.yaml` (`expose: none`, `previews: false`, `coolify_uuid` gardé), `.fs0/bridge.yaml`, `DEPLOY.md` et
   `docs/memory/state.md` partent dans une PR du projet.
6. **Rapport** (5 lignes) : statut de l'application, PR d'infra, entrées à régler à la main, puis les étapes du
   propriétaire : fusionner la PR et lancer `tofu apply` ; supprimer l'application dans l'interface Coolify ;
   archiver le dépôt GitHub s'il le veut. Retour arrière : `TRIGGER …/start`, puis `/ship`.

Jamais de `DELETE`, de `tofu`, de valeur de secret affichée, ni d'identifiant d'infra recopié dans un dépôt public.
