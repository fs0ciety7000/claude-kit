# Retour arrière vers le harness v1

Ce document décrit comment revenir à la v1 (état de `main` au commit `e794022`, conservé sur la branche `legacy/v1`)
sur un poste de travail et dans une session claude.ai/code, puis comment repartir vers la v2. Il fait partie du lot 0
du plan de la v2 (`docs/plans/2026-11-12-harness-v2.md`).

Les commandes ont été essayées sur un clone jetable (checkout de `legacy/v1`, hook de mise à jour, retour sur `main`) et
la restauration de l'archive dans un conteneur jetable (`scripts/test/backup-v1-test.sh`). Le `install.sh` complet et
l'ouverture d'une vraie session `claude` restent à faire sur un poste : la section « Vérifier » dit quoi regarder.

## Ce qui vit où (v1)

| Élément | Emplacement | Sauvegardé par `backup-v1.sh` ? |
|---|---|---|
| Dépôt du kit (git) | un clone, par ex. `~/claude-kit` (lien `~/.local/bin/kit` vers `scripts/kit.sh`) | non : c'est `legacy/v1` ; l'état local (diff, commits non poussés, fichiers non suivis) est dans le manifeste |
| `CLAUDE.md`, `skills-registry.md`, agents, commandes, skills du kit | `~/.claude/*`, liens symboliques vers le clone | liens et cibles notés ; le contenu est dans `legacy/v1` |
| Réglages | `~/.claude/settings.json` (v1 : fusion par union de `global/settings.json` ; v2 : réglages gérés, registre `~/.config/claude-kit/settings.managed.json`) | oui (le fichier ; pas le registre) |
| Hooks | `~/.config/claude-kit/hooks/*` (liens vers `scripts/hooks/`), profil (`profile`) | oui (liens et profil) |
| Copies de contexte | `~/.kit/context/<dépôt>` (sans `.git` dans l'archive) | oui (fichiers) ; origine et commit dans le manifeste |
| Clé age | `~/.config/sops/age/keys.txt` | **jamais** : à garder dans le gestionnaire de mots de passe |
| Secrets globaux chiffrés | `~/.config/claude-kit/secrets/global.enc.json` | **jamais** (voir ci-dessous) |
| Identifiants Claude Code | `~/.claude/.credentials.json` (Linux), trousseau (macOS) | **jamais** |
| `~/.claude.json` | MCP, projets, état de l'interface | **jamais** (jetons MCP possibles) ; noms des serveurs MCP dans le manifeste |

Un écart avec le plan : la clé age n'est pas sous `~/.config/claude-kit/age` mais sous `~/.config/sops/age/keys.txt`
(`scripts/secrets.sh`, variable `SOPS_AGE_KEY_FILE`). Le script exclut les deux emplacements.

Le fichier de secrets globaux chiffré n'est dans aucun dépôt : sans lui, les valeurs de `kit secrets add … -g` sont
perdues si le poste meurt. Il est chiffré, mais il reste hors de l'archive (une archive qui contient le chiffré et
dont la clé voyage avec elle ne protège plus rien). Copie-le à part, à côté de la clé age.

## 0. Avant tout : sauvegarder et poser les tags

### Sauvegarde de chaque poste

```bash
# dans le dépôt du kit (branche de la PR du lot 0, ou une copie du script) :
bash scripts/backup-v1.sh --dry-run          # montre ce qui est archivé et écarté, n'écrit rien
bash scripts/backup-v1.sh                    # ~/claude-kit-backups/v1-<hôte>-<date>.tar.gz + .sha256
bash scripts/backup-v1.sh --out /chemin/vers/dossier-chiffre --with-transcripts   # variante avec les conversations
```

Le script ne contacte aucun serveur. Il liste le contenu de l'archive, la supprime si un chemin ressemble à un secret
(`credentials`, `*.key`, `*.pem`, `id_*`, `.env*`, `token`, clé age, dossier `secrets`/`sops`/`age`), et omet (en le
signalant par son nom) tout fichier dont le contenu ressemble à un secret. Ensuite, à la main :

1. Vérifier la somme : `cd ~/claude-kit-backups && sha256sum -c v1-*.tar.gz.sha256` (macOS : `shasum -a 256 -c …`).
2. Copier l'archive et sa somme hors du poste (pièce jointe du gestionnaire de mots de passe, disque chiffré). Pas dans
   Git, pas dans un dossier synchronisé en clair.
3. Copier à part la clé age et le fichier de secrets globaux chiffré.
4. Faire la même chose sur chaque poste (macOS, Linux).

`--with-transcripts` ajoute `projects/`, l'historique, les instantanés du shell, `todos/`, etc. Les conversations
peuvent contenir des secrets collés : à n'utiliser que vers un support chiffré. Sans l'option, la mémoire automatique
par projet (`~/.claude/projects/*/memory`) n'est pas sauvegardée non plus.

### Tags `v1-final`

Les sessions cloud ne peuvent pas pousser de tags : à faire une fois, en local, sur les trois dépôts (le kit, le dépôt
d'infra, le coffre de notes). Chaque dépôt a déjà une branche `legacy/v1`.

```bash
cd <repo>                                   # à répéter pour chacun des trois dépôts
git fetch origin legacy/v1
git tag -a v1-final origin/legacy/v1 -m "Harness v1 final : point de restauration"
git push origin v1-final
git ls-remote --tags origin v1-final        # vérification
```

Sur un clone « single-branch » (`--depth 1`), `git fetch origin legacy/v1` ne crée pas `origin/legacy/v1` : lance
d'abord `git remote set-branches --add origin legacy/v1` (voir le piège en 1.2).

## 1. Poste de travail : revenir à la v1

### 1.1 Arrêter la mise à jour automatique d'abord

Le hook `scripts/hooks/kit-autoupdate.sh` (événement `SessionStart`) décide ainsi :

- `KIT_AUTOUPDATE=0` dans son environnement : il sort sans rien faire. C'est le seul interrupteur prévu.
- Sinon, en local, au plus une vérification réussie par 6 h (tampon `~/.config/claude-kit/autoupdate.stamp`) ; en cloud
  (profil `cloud` ou `CLAUDE_CODE_REMOTE=true`), à chaque démarrage.
- Il ne touche à rien si le dépôt du kit n'est **pas sur la branche `main`** ou a des modifications locales : il
  affiche une ligne (« mise à jour auto ignorée ») et sort. Sur `main`, il fait `git fetch origin main`, puis
  `git merge --ff-only origin/main`, puis lance `kit sync` en arrière-plan.

Il n'existe donc **pas d'option d'épinglage** (ni référence à suivre, ni fichier d'arrêt) : l'épinglage de fait est
d'être sur une autre branche que `main`, et la couche de sécurité est `KIT_AUTOUPDATE=0`. Procédure minimale, sans
modifier le code :

```bash
# Dans le profil du shell qui lance claude (~/.zshrc, ~/.bashrc ; fish : set -Ux KIT_AUTOUPDATE 0)
export KIT_AUTOUPDATE=0
```

Ouvre un nouveau terminal : une application lancée depuis le Finder ou un lanceur graphique ne lit pas ce profil. Avant
de continuer, vérifie : `echo "$KIT_AUTOUPDATE"` affiche `0`. N'utilise pas `kit update` tant que le kit est sur
`main` : c'est un `git pull --ff-only` qui ramènerait la v2.

### 1.2 Mettre le kit sur `legacy/v1`

```bash
KIT=~/claude-kit                              # adapte : le dépôt vers lequel pointe ~/.local/bin/kit
git -C "$KIT" status --porcelain              # doit être vide ; sinon commite, ou git stash
git -C "$KIT" remote set-branches --add origin legacy/v1   # utile sur un clone « single-branch » (voir piège)
git -C "$KIT" fetch origin legacy/v1
git -C "$KIT" checkout -B legacy/v1 origin/legacy/v1
git -C "$KIT" log --oneline -1                # attendu : e794022
```

Piège constaté : un clone fait avec `--depth 1` (cas du script de démarrage cloud) ne suit que `main`. Dans ce cas,
`git fetch origin legacy/v1` seul ne crée pas `origin/legacy/v1` et un `git checkout legacy/v1` échoue (« 'origin/legacy/v1'
is not a commit » ou « cannot set up tracking information »). La ligne `remote set-branches --add` règle le problème et
est sans effet sur un clone complet.

### 1.3 Réinstaller les liens et les réglages

```bash
cat ~/.config/claude-kit/profile              # local, vps ou cloud : garde le même profil
"$KIT/install.sh"                             # poste local ; sur un VPS : "$KIT/install.sh" --vps
```

`install.sh` relance `ln -sfn` pour `~/.local/bin/kit` et pour les hooks, puis `kit sync` : liens vers `~/.claude`,
réglages, registre, copies de contexte. Les liens vers des fichiers qui n'existent plus en v1 (agents, skills,
commandes de la v2) sont supprimés (`link_dir` retire les liens cassés qui pointent vers le kit). Un fichier ordinaire
qui porte le même nom qu'un élément du kit n'est jamais écrasé : il est signalé « non géré par le kit, ignoré ».

**Les réglages ne reviennent pas tout seuls.** Le `kit sync` de la v1 fusionne par union (`permissions.allow|ask|deny`,
hooks) et ne lit pas le registre de la v2 : tout ce que la v2 a écrit dans `~/.claude/settings.json` y reste. En v2,
`kit sync` applique les réglages gérés (fusion à trois points, voir ci-dessous) ; le registre
`~/.config/claude-kit/settings.managed.json` garde en mémoire ce que le kit a posé la dernière fois. Pour retrouver
exactement la v1 : restaure le `settings.json` de l'archive, **supprime le registre**, puis lance le `kit sync` de la
v1 (section suivante). Le `settings.json` de l'archive reste la référence ; les sauvegardes
`settings.json.pre-kit.<date>` (la plus ancienne et les deux plus récentes, écrites par la v2 avant chaque changement) ne servent qu'à
revenir d'un état v2 à un état v2 plus ancien.

### 1.4 Restaurer depuis l'archive

L'archive contient des chemins relatifs à `$HOME` : `.claude/…`, `.kit/context/…`, `.config/claude-kit/…`, éventuels
fichiers vers lesquels pointaient des liens de `~/.claude` (par ex. `dotfiles/skills/…`), et un dossier
informatif `.claude-kit-backup-v1/` (manifeste, état git du kit, `kit doctor`, patchs).

**Poste neuf ou vidé** (rien à préserver) : après les étapes 1.2 et 1.3, la commande suffit.

```bash
tar -tzf ~/claude-kit-backups/v1-<hôte>-<date>.tar.gz | head       # regarde d'abord
tar -xzf ~/claude-kit-backups/v1-<hôte>-<date>.tar.gz -C ~
```

**Poste en service** : extrais dans un dossier de passage, compare, puis copie ce que tu veux (une extraction directe
dans `~` écrase les fichiers existants et les liens de même nom).

```bash
mkdir -p ~/restore-v1 && tar -xzf ~/claude-kit-backups/v1-<hôte>-<date>.tar.gz -C ~/restore-v1
cat ~/restore-v1/.claude-kit-backup-v1/MANIFEST.txt                  # ce qui est dedans, ce qui a été écarté
cp ~/.claude/settings.json ~/.claude/settings.json.v2-avant-retour   # garde la version v2 pour y revenir
cp ~/restore-v1/.claude/settings.json ~/.claude/settings.json        # remplace la fusion par les réglages v1
rm -f ~/.config/claude-kit/settings.managed.json                     # oublie le registre de la v2 (la v1 ne le lit pas)
diff -r ~/restore-v1/.claude ~/.claude | head -50                    # le reste : à reprendre au cas par cas
"$KIT/scripts/kit.sh" sync                                           # kit sur legacy/v1 : fusion par union, comme avant
```

Le `settings.json` restauré est celui de la v1 : le `kit sync` de la v1 n'y ajoute que ce que `global/settings.json` de
la v1 contient déjà, donc rien ne change. Si tu avais une surcharge `~/.config/claude-kit/settings.local.json` (propre
à la v2, voir le README), la v1 l'ignore : elle ne fait aucun mal, laisse-la en place pour le retour vers la v2.

À restaurer en général : `settings.json` (+ `settings.local.json` s'il existait), `keybindings.json`, la statusline,
`plugins/installed_plugins.json` et `known_marketplaces.json`, les agents, commandes et skills qui sont des **fichiers
ordinaires** (pas des liens vers le kit). Les modifications du kit qui n'étaient pas poussées sont dans
`.claude-kit-backup-v1/` : `kit-local-changes.patch` (`git -C "$KIT" apply …`), `kit-unpushed-commits.patch`
(`git -C "$KIT" am …`) et `kit-untracked/` (fichiers à recopier dans le kit).

À ne pas écraser : `~/.claude/.credentials.json` et `~/.claude.json` (absents de l'archive : tu restes connecté), la clé
age et `~/.config/claude-kit/secrets/` (idem), `~/.claude/projects/` si tu as conservé des sessions plus récentes que
l'archive (présent seulement avec `--with-transcripts`). Les copies de contexte (`~/.kit/context/*`) sont refaites par
`kit sync` : ne restaure leurs fichiers que s'ils avaient des modifications locales (le manifeste les signale dans
`kit-context-git.txt`). Après vérification, `rm -rf ~/.claude-kit-backup-v1 ~/restore-v1` nettoie les dossiers
informatifs.

Les serveurs MCP vivent dans `~/.claude.json`, que le script n'archive pas : recrée-les avec `kit mcp setup` (Coolify)
et `kit dash setup <url>` (kit-control). Leurs noms sont dans `.claude-kit-backup-v1/claude-json-note.txt`. La clé age
et les secrets globaux, remis depuis le gestionnaire de mots de passe, se contrôlent par `kit secrets doctor`.

### 1.5 Vérifier

```bash
git -C "$KIT" rev-parse --abbrev-ref HEAD                 # legacy/v1
kit doctor                                                # tous les ✓ ; la ligne du hook de mise à jour doit être là
ls -l ~/.claude/CLAUDE.md                                 # lien vers $KIT/global/CLAUDE.md
KIT_CONFIG=$(mktemp -d) ~/.config/claude-kit/hooks/kit-autoupdate.sh </dev/null
```

La dernière commande, avec un dossier de config vide (le vrai tampon n'est pas touché), doit afficher
« kit : mise à jour auto ignorée (branche « legacy/v1 », pas main) ». Même commande avec `KIT_AUTOUPDATE=0` : aucune
sortie. Ensuite, ouvre une session `claude` et demande de citer les titres du `CLAUDE.md` global : la v1 contient
« Router avant de coder » et « Dashboard (kit-control) », que la v2 doit supprimer. `/hooks` et `/permissions` montrent
les réglages restaurés.

### 1.6 Revenir à la v2 plus tard

```bash
# retire « export KIT_AUTOUPDATE=0 » du profil du shell, nouveau terminal
git -C "$KIT" status --porcelain                          # propre
git -C "$KIT" checkout main && git -C "$KIT" pull --ff-only
"$KIT/install.sh"                                         # même profil qu'avant
"$KIT/scripts/kit.sh" sync --dry-run                      # écart par clé sur les réglages, rien d'écrit
"$KIT/scripts/kit.sh" sync
```

Le registre ayant été supprimé au retour vers la v1, le premier `kit sync` de la v2 refait la migration : il
considère comme venant du kit tout ce que la v1 écrivait (instantané `global/settings.v1.json`), le remplace par les
réglages de la v2 et garde les ajouts de l'utilisateur. Il n'y a donc plus besoin de recopier
`settings.json.v2-avant-retour` ; la copie reste possible si tu veux retrouver tes réglages exacts d'avant le retour.

## 2. Session claude.ai/code : revenir à la v1

Un conteneur cloud est neuf à chaque session : il n'y a rien à restaurer, seulement à changer ce que le script de
démarrage de l'environnement clone (menu de l'environnement, `Edit`, `Setup script`). Il clone aujourd'hui la branche
par défaut ; en v2 ce sera la v2.

1. Dans les variables de l'environnement cloud, ajoute `KIT_AUTOUPDATE=0` (en cloud, le hook tourne à chaque
   démarrage, sans tampon).
2. Remplace le script de démarrage par :

```bash
if [ -d ~/claude-kit/.git ]; then
  git -C ~/claude-kit remote set-branches --add origin legacy/v1
  git -C ~/claude-kit fetch --depth 1 origin legacy/v1 && git -C ~/claude-kit checkout -B legacy/v1 FETCH_HEAD
else
  git clone --depth 1 --branch legacy/v1 https://github.com/<owner>/claude-kit ~/claude-kit
fi
~/claude-kit/install.sh --cloud
```

3. Ouvre une nouvelle session et contrôle : `git -C ~/claude-kit rev-parse --abbrev-ref HEAD` (attendu `legacy/v1`),
   `echo "$KIT_AUTOUPDATE"` (`0`), `kit doctor` (profil cloud : pas de sops ni age).

Limites : les agents et skills copiés dans le `.claude/` d'un projet (`kit project add`) viennent du dépôt de ce projet,
pas du kit ; ce retour ne les change pas (leur historique Git le permet). Pas d'archive en cloud : `~/.claude` y est
reconstruit par `install.sh --cloud` ; les jetons sont des variables de l'environnement. Pour repartir vers la v2 :
remets l'ancien script de démarrage et supprime `KIT_AUTOUPDATE`.

## 3. Lacunes constatées (à traiter au lot 2)

- **Pas d'épinglage du kit.** Le hook ne connaît que `KIT_AUTOUPDATE=0` (variable d'environnement, donc à poser dans
  chaque shell, chaque environnement cloud, et invisible pour une application lancée hors terminal) et le garde-fou
  « branche ≠ `main` ». Il manque un interrupteur persistant côté kit (fichier dans `~/.config/claude-kit/`) et une
  référence épinglée (`KIT_PIN=<branche|tag>` ou fichier), lus aussi par `kit update`.
- `kit doctor` ne signale pas que le kit est volontairement hors de `main` ni la valeur de `KIT_AUTOUPDATE`, et
  `kit --version` n'existe pas en v1 : la version se lit dans le commit du dépôt.
- ~~Les réglages fusionnent par union~~ : traité par le lot 2b (`apply_managed_settings`). Le retour vers la v1
  reste à faire à la main (restaurer `settings.json`, supprimer le registre, section 1.4), parce que le `kit sync` de
  la v1 ne connaît pas le registre.
- Un clone `--depth 1` (script cloud) ne connaît que `main` : toute documentation de retour doit passer par
  `git remote set-branches --add`.
