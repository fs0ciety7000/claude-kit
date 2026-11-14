---
name: atlas
description: Chercher dans atlas, le hub de docs (projets, services, piles, leçons), avant de choisir un service, une pile ou de démarrer un projet. Écriture par PR.
---

# Atlas

Hub de docs privé (site Starlight). Pages Markdown dans `src/content/docs/{projets,services,infra,piles,lecons}/`,
en-tête `title`, `description`, `type`, `updated` (AAAA-MM-JJ), `tags`, `status`.

## Quand le lire

Avant de choisir un service ou une pile, de démarrer ou d'adopter un projet, ou devant un piège qui semble connu : un
service réutilisable ou une leçon déjà écrite évite de refaire.

## Chercher

1. Clone à jour : `ATLAS_DIR` de `~/.config/claude-kit/atlas.conf`, puis `git -C "$ATLAS_DIR" pull --ff-only`. En
   session cloud : le dépôt attaché à la session ; absent, dis-le et continue.
2. Par l'en-tête : `grep -rlE '^tags:.*\bcoolify\b' src/content/docs/`, `grep -rl '^type: service' src/content/docs/`,
   puis `title` et `description` des fichiers trouvés.
3. Plein texte : `grep -ril '<mot>' src/content/docs/`. Lis les pages retenues en entier.
4. Cite ce qui a servi : « atlas : <titre> ».

## Écrire, seulement à la demande

- Page projet : `kit atlas sync` (générée, jamais éditée à la main ; `--dry-run` montre le diff).
- Autre page : branche `claude/atlas-<sujet>` dans un worktree, en-tête complet, `updated` du jour, une idée par
  leçon, puis PR vers `main` ; le propriétaire fusionne.
- Rôles seulement (« le VPS principal ») : ni IP, ni hôte interne, ni utilisateur, ni e-mail, ni identifiant, ni
  secret. Dans un dépôt public, cite le titre d'une page sans la recopier.
