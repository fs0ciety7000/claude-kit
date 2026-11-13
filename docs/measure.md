# Mesurer le harness (v1 contre v2)

But : comparer la v1 et la v2 sur **le même projet**, avec les mêmes chiffres : tokens, durée, validations demandées,
agents lancés, temps jusqu'au premier déploiement. Plan : `docs/plans/2026-11-12-harness-v2.md` (lots 1, 2 et 6).

## Protocole

1. Sur un poste (toujours le même), dans un dossier vide `~/dev/mesure-<v1|v2>-<date>` :
   `claude` (mode auto, modèle et effort par défaut du kit), puis coller **exactement** l'énoncé ci-dessous.
2. Répondre aux questions sans rien ajouter au-delà de l'énoncé ; choisir les options recommandées.
3. Arrêter quand le site répond en HTTPS (ou, si le déploiement n'est pas encore automatisé, quand le build passe).
   Noter l'heure du premier déploiement réussi.
4. Dans le même dossier : `scripts/measure-session.sh --json > mesure.json` (depuis le dossier du kit :
   `<kit>/scripts/measure-session.sh --json`), puis reporter les chiffres dans le tableau.

## Énoncé de référence (à coller tel quel)

> Crée un petit site vitrine en Astro pour un atelier de céramique fictif, « Terre & Feu » : une page d'accueil
> (présentation, trois photos de pièces en placeholder, horaires), une page « Ateliers » (trois formules avec prix) et
> une page « Contact » (adresse, carte statique, formulaire qui ouvre le client mail). Site statique, en français,
> responsive, sans base de données. Déploiement public sur un sous-domaine de test.

## Résultats

| Version | Date | Tokens (total) | Durée | Validations | Agents | Premier déploiement |
|---|---|---|---|---|---|---|
| v1 | | | | | | |
| v2 (lot 2) | | | | | | |
| v2 (lot 6) | | | | | | |

`total` additionne entrée, cache écrit, cache lu et sortie ; le cache lu domine et coûte peu : comparer aussi
`output` et `cache_write`, plus représentatifs de l'effort.
