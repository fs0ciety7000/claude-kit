#!/usr/bin/env bash
# backup-v1.sh : sauvegarde le harness v1 d'un poste (à lancer PAR L'UTILISATEUR, sur chaque poste) avant la refonte v2.
#
# Usage : backup-v1.sh [--dry-run] [--out DIR] [--with-transcripts]
#   --dry-run            n'écrit rien : montre ce qui serait archivé et ce qui serait écarté
#   --out DIR            dossier de destination (défaut : ~/claude-kit-backups, créé en mode 700)
#   --with-transcripts   ajoute projects/, history, shell-snapshots, todos, file-history... de ~/.claude
#                        (volumineux, et les conversations peuvent contenir des secrets collés : à chiffrer)
#
# Produit v1-<empreinte-courte-de-l-hôte>-<AAAAMMJJ-HHMMSS>.tar.gz (mode 600) et v1-….tar.gz.sha256.
# Chemins archivés relatifs à $HOME : restauration par `tar -xzf <archive> -C ~` (voir docs/rollback-v1.md).
#
# Contenu :
#   ~/.claude                 réglages, CLAUDE.md, commandes, agents, skills, hooks, plugins (liste et config),
#                             keybindings, statusline... ; les liens symboliques vers le kit sont archivés comme liens
#   ~/.kit                    copies de contexte (~/.kit/context/*), sans leur dossier .git
#   ~/.config/claude-kit      profil, destinataires age (clés PUBLIQUES), liens de hooks ; sans secrets/ ni journaux
#   cibles de liens           fichiers situés dans $HOME vers lesquels pointent des liens de ~/.claude (hors kit)
#   .claude-kit-backup-v1/    MANIFEST.txt, état git du kit (remote, branche, commit, status, diff local, commits non
#                             poussés, fichiers non suivis), `kit doctor`, `claude --version`, cibles des liens
#
# JAMAIS archivé : .credentials.json et tout *credentials*, ~/.claude.json (peut contenir des jetons de serveurs MCP),
# clé age (~/.config/sops/age/keys.txt et variantes), fichiers sops/secrets, ~/.config/gh, clés ssh, .env*, *.key, *.pem,
# id_*, tout nom contenant « token », et tout fichier dont le CONTENU ressemble à un secret (jeton GitHub/Anthropic/AWS/Slack,
# clé privée, valeur de variable *TOKEN/*SECRET/*PASSWORD/*API_KEY dans un JSON) : ces fichiers sont omis et signalés.
#
# Compatible bash 3.2 (macOS) : pas de mapfile, ${var,,}, tableaux associatifs, readlink -f, grep -P, sed -i.
# Aucune lecture de valeur de secret : les contrôles de contenu n'utilisent que `grep -l` (noms de fichiers).
# shellcheck disable=SC2088,SC2015,SC2086,SC2317
# SC2088: "~" is displayed to the user, never expanded; SC2015: `A && B || die` is intended; SC2086: $ROOTS is a word
# list; SC2317: cleanup is reached through trap.
set -u
umask 077

SCRIPT_VERSION=1
DRY=0
TRANSCRIPTS=0
OUT=""
DEFAULT_OUT="$HOME/claude-kit-backups"

die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }
info() { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --with-transcripts) TRANSCRIPTS=1 ;;
    --out) [ $# -ge 2 ] || die "--out demande un dossier"; OUT=$2; shift ;;
    --out=*) OUT=${1#--out=} ;;
    -h|--help) usage; exit 0 ;;
    *) die "option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "\$HOME introuvable"
for t in tar gzip find grep awk sed xargs mktemp wc tr sort uname; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' introuvable"
done

# ---------------------------------------------------------------------------------------------------------------------
# Helpers

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else return 1; fi
}
sha256_file() { hash_stdin <"$1"; }

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; } # GNU, puis BSD/macOS
size_of() { wc -c <"$1" | tr -d ' '; }

run_timeout() { # secondes commande... (sans limite si ni timeout ni gtimeout)
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else "$@"; fi
}

# Physical absolute path of an existing file or directory (no readlink -f on old macOS).
phys() {
  if [ -d "$1" ]; then (cd "$1" 2>/dev/null && pwd -P)
  elif [ -e "$1" ]; then
    local d
    d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$d" "$(basename "$1")"
  else return 1; fi
}

# Strips credentials embedded in a URL (https://user:token@host/...).
clean_url() { sed -E 's#(://)[^/@]*@#\1#'; }

count_lines() { if [ -s "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# ---------------------------------------------------------------------------------------------------------------------
# Rules (extended regexes, matched case-insensitively against paths relative to $HOME)

# Never archived, whatever the options.
RE_SECRET='(^|/)[^/]*credentials[^/]*$|(^|/)[^/]*\.(key|pem|p12|pfx|kdbx)$|(^|/)id_[^/]*$|(^|/)\.env[^/]*$|(^|/)[^/]*token[^/]*$|(^|/)keys\.txt$|(^|/)\.netrc$|(^|/)\.claude\.json[^/]*$|(^|/)\.(ssh|gnupg)/|^\.config/(gh|sops|age)/|(^|/)(secrets|sops|age)/|(^|/)[^/]*\.enc\.(json|ya?ml)$'
# Bulky or regenerable, never archived. ~/.claude/backups holds copies of ~/.claude.json (MCP tokens).
RE_BULKY='^\.claude/(cache|debug|telemetry|statsig|ide|backups|local|usage-data|plugins/(cache|marketplaces|repos|data))(/|$)|(^|/)\.DS_Store$|\.(log|stamp)$|^\.config/claude-kit/autoupdate\.'
# Conversations and shell state: only with --with-transcripts.
RE_TRANSCRIPT='^\.claude/(projects|shell-snapshots|todos|file-history|paste-cache|image-cache|session-env|sessions|transcripts|history\.jsonl|stats-cache\.json)(/|$)'
# File contents that look like a secret (checked with grep -l: only file names are ever printed).
RE_CONTENT='-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----|AGE-SECRET-KEY-1[0-9A-Z]{20,}|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|"[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|API_?KEY)[A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*"[^"]{12,}"'
MAX_KB=10240 # files above 10 MB are skipped (except transcripts with --with-transcripts)

# ---------------------------------------------------------------------------------------------------------------------
# Paths

CFG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit
HOME_P=$(cd "$HOME" && pwd -P) || die "\$HOME illisible"
[ -d "$HOME/.claude" ] || [ -L "$HOME/.claude" ] || die "~/.claude introuvable : rien à sauvegarder sur cette machine."

default_out=0
if [ -z "$OUT" ]; then OUT=$DEFAULT_OUT; default_out=1; fi
case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac
case $OUT in
  "$HOME/.claude"|"$HOME/.claude"/*|"$HOME/.kit"|"$HOME/.kit"/*|"$CFG_DIR"|"$CFG_DIR"/*)
    die "--out ne doit pas être dans ce qui est sauvegardé (~/.claude, ~/.kit, ~/.config/claude-kit)" ;;
esac

# Roots archived, relative to $HOME. The kit's config dir is archived only when it lives under $HOME.
ROOTS=".claude"
[ -e "$HOME/.kit" ] && ROOTS="$ROOTS .kit"
CFG_REL=""
case $CFG_DIR in
  "$HOME"/*) CFG_REL=${CFG_DIR#"$HOME"/}; [ -d "$CFG_DIR" ] && ROOTS="$ROOTS $CFG_REL" ;;
  *) warn "config du kit hors de \$HOME ($CFG_DIR) : non archivée" ;;
esac

# Kit directory: $KIT_HOME, else the target of ~/.local/bin/kit, else ~/claude-kit, else the clone holding this script.
find_kit_dir() {
  local d="" t here
  if [ -n "${KIT_HOME:-}" ]; then d=$KIT_HOME
  elif [ -L "$HOME/.local/bin/kit" ]; then
    t=$(readlink "$HOME/.local/bin/kit")
    case $t in /*) ;; *) t="$HOME/.local/bin/$t" ;; esac
    d=$(cd "$(dirname "$t")/.." 2>/dev/null && pwd -P)
  fi
  [ -n "$d" ] && [ -f "$d/scripts/kit.sh" ] && { echo "$d"; return 0; }
  [ -f "$HOME/claude-kit/scripts/kit.sh" ] && { (cd "$HOME/claude-kit" && pwd -P); return 0; }
  here=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)
  [ -n "$here" ] && [ -f "$here/scripts/kit.sh" ] && { echo "$here"; return 0; }
  return 1
}
KIT_DIR=$(find_kit_dir) || KIT_DIR=""
HAVE_GIT=0; command -v git >/dev/null 2>&1 && HAVE_GIT=1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kit-backup.XXXXXX") || die "dossier temporaire impossible"
PARTIAL=""
cleanup() {
  rm -rf "$WORK"
  [ -n "$PARTIAL" ] && rm -rf "$PARTIAL"
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

STAGE_ROOT="$WORK/meta"
STAGE="$STAGE_ROOT/.claude-kit-backup-v1"
mkdir -p "$STAGE"

# ---------------------------------------------------------------------------------------------------------------------
# 1) File list: find, then filters. Symlinks are archived as links (never followed).

info "Inventaire de $HOME (${ROOTS})"
RAW="$WORK/raw.txt"; : >"$RAW"
for r in $ROOTS; do
  [ -e "$HOME/$r" ] || continue
  (cd "$HOME" && find -H "$r" \( -name .git -o -name node_modules \) -type d -prune -o ! -type d -print) >>"$RAW" 2>/dev/null
done

# Targets of symlinks in ~/.claude that live in $HOME but outside the kit and the roots (e.g. skills linked from a
# dotfiles directory): without them, the links alone would restore nothing.
EXTRA_NOTE="$WORK/extra-targets.txt"; : >"$EXTRA_NOTE"
(cd "$HOME" && find -H .claude -type l -print) 2>/dev/null >"$WORK/links.txt"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  t=$(readlink "$HOME/$l" 2>/dev/null) || continue
  case $t in /*) ;; *) t="$(dirname "$HOME/$l")/$t" ;; esac
  tp=$(phys "$t") || continue
  case $tp in "$HOME_P"/*) ;; *) continue ;; esac
  [ -n "$KIT_DIR" ] && case $tp in "$KIT_DIR"|"$KIT_DIR"/*) continue ;; esac
  rel=${tp#"$HOME_P"/}
  case $rel in
    .claude|.claude/*|.kit|.kit/*|.ssh|.ssh/*|.gnupg|.gnupg/*|.config/gh|.config/gh/*|.config/sops|.config/sops/*) continue ;;
  esac
  [ -n "$CFG_REL" ] && case $rel in "$CFG_REL"|"$CFG_REL"/*) continue ;; esac
  kb=$(du -sk "$tp" 2>/dev/null | awk '{print $1}')
  if [ "${kb:-0}" -gt 20480 ]; then
    echo "ignoré (> 20 Mo) : $l -> $rel" >>"$EXTRA_NOTE"
    continue
  fi
  echo "ajouté : $l -> $rel" >>"$EXTRA_NOTE"
  (cd "$HOME" && find -H "$rel" \( -name .git -o -name node_modules \) -type d -prune -o ! -type d -print) >>"$RAW" 2>/dev/null
done <"$WORK/links.txt"

sort -u "$RAW" >"$WORK/raw.sorted"; mv "$WORK/raw.sorted" "$RAW"
# The backup destination is never part of the backup (e.g. when it is a symlink target).
OUT_REL=""
case $OUT in "$HOME_P"/*) OUT_REL=${OUT#"$HOME_P"/} ;; "$HOME"/*) OUT_REL=${OUT#"$HOME"/} ;; esac
if [ -n "$OUT_REL" ]; then
  grep -vF -e "$OUT_REL/" "$RAW" >"$WORK/raw.2"; mv "$WORK/raw.2" "$RAW"
fi

# Successive filters; each step writes what it drops, for the report.
DROP_SECRET="$WORK/drop-secret.txt"; DROP_BULKY="$WORK/drop-bulky.txt"; DROP_TRANS="$WORK/drop-transcripts.txt"
DROP_BIG="$WORK/drop-big.txt"; DROP_SUSPECT="$WORK/drop-suspect.txt"
grep -iE "$RE_SECRET" "$RAW" >"$DROP_SECRET"
grep -viE "$RE_SECRET" "$RAW" >"$WORK/f1.txt"
grep -iE "$RE_BULKY" "$WORK/f1.txt" >"$DROP_BULKY"
grep -viE "$RE_BULKY" "$WORK/f1.txt" >"$WORK/f2.txt"
if [ "$TRANSCRIPTS" -eq 1 ]; then
  : >"$DROP_TRANS"; cp "$WORK/f2.txt" "$WORK/f3.txt"
else
  grep -iE "$RE_TRANSCRIPT" "$WORK/f2.txt" >"$DROP_TRANS"
  grep -viE "$RE_TRANSCRIPT" "$WORK/f2.txt" >"$WORK/f3.txt"
fi
# Big files (regular files only).
: >"$DROP_BIG"
(cd "$HOME" && find -H $ROOTS -type f -size +${MAX_KB}k -print 2>/dev/null) | sort -u >"$WORK/bigall.txt"
if [ -s "$WORK/bigall.txt" ]; then
  if [ "$TRANSCRIPTS" -eq 1 ]; then grep -viE "$RE_TRANSCRIPT" "$WORK/bigall.txt" >"$WORK/bigcand.txt"; else cp "$WORK/bigall.txt" "$WORK/bigcand.txt"; fi
  grep -Fxf "$WORK/bigcand.txt" "$WORK/f3.txt" >"$DROP_BIG"
  grep -Fxvf "$DROP_BIG" "$WORK/f3.txt" >"$WORK/f4.txt"
else
  cp "$WORK/f3.txt" "$WORK/f4.txt"
fi
[ -s "$DROP_BIG" ] || cp "$WORK/f3.txt" "$WORK/f4.txt"

# Content scan of regular, non-transcript files: anything that looks like a secret is omitted and reported by name.
: >"$WORK/scan.txt"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -f "$HOME/$f" ] && [ ! -L "$HOME/$f" ]; then printf '%s\n' "$f"; fi
done <"$WORK/f4.txt" | grep -viE "$RE_TRANSCRIPT" >"$WORK/scan.txt"
: >"$DROP_SUSPECT"
if [ -s "$WORK/scan.txt" ]; then
  (cd "$HOME" && tr '\n' '\0' <"$WORK/scan.txt" | xargs -0 grep -lE -- "$RE_CONTENT" 2>/dev/null) >"$DROP_SUSPECT"
fi
if [ -s "$DROP_SUSPECT" ]; then grep -Fxvf "$DROP_SUSPECT" "$WORK/f4.txt" >"$WORK/kept.txt"; else cp "$WORK/f4.txt" "$WORK/kept.txt"; fi
KEPT="$WORK/kept.txt"
[ -s "$KEPT" ] || die "aucun fichier à archiver (tout a été écarté ?)"

summarize() { # label file : counts by directory (3 levels max) of what was dropped
  [ -s "$2" ] || return 0
  echo "[$1] $(count_lines "$2") fichier(s)"
  awk -F/ '{ k = $1; for (i = 2; i < NF && i <= 3; i++) k = k "/" $i; c[k]++ } END { for (k in c) print "  " c[k] "\t" k }' "$2" | sort -rn | head -12
}
EXCL_REPORT="$WORK/excluded-summary.txt"
{
  echo "Écarté par règle de secret (noms seulement) :"
  if [ -s "$DROP_SECRET" ]; then head -40 "$DROP_SECRET" | sed 's/^/  /'; [ "$(count_lines "$DROP_SECRET")" -gt 40 ] && echo "  ... ($(count_lines "$DROP_SECRET") au total)"; else echo "  (aucun)"; fi
  echo
  summarize "volumineux ou régénérable" "$DROP_BULKY"
  summarize "conversations et état du shell (--with-transcripts pour les inclure)" "$DROP_TRANS"
  summarize "fichiers de plus de $((MAX_KB / 1024)) Mo" "$DROP_BIG"
  if [ -s "$DROP_SUSPECT" ]; then
    echo "[contenu ressemblant à un secret : OMIS, à nettoyer puis à sauvegarder à la main] $(count_lines "$DROP_SUSPECT") fichier(s)"
    sed 's/^/  /' "$DROP_SUSPECT"
  fi
} >"$EXCL_REPORT"

# ---------------------------------------------------------------------------------------------------------------------
# 2) Dry run: report and stop, nothing written (the work dir is temporary and removed on exit).

if [ "$DRY" -eq 1 ]; then
  info "Mode --dry-run : rien n'est écrit"
  echo "Destination prévue : $OUT/v1-<hôte>-<horodatage>.tar.gz (+ .sha256)"
  echo "Racines            : $ROOTS"
  echo "Kit                : ${KIT_DIR:-introuvable}"
  echo "Transcripts        : $([ "$TRANSCRIPTS" -eq 1 ] && echo inclus || echo exclus)"
  echo "À archiver         : $(count_lines "$KEPT") fichier(s) et lien(s), $(tar -cf - -C "$HOME" -T "$KEPT" 2>/dev/null | wc -c | tr -d ' ') octets avant compression"
  [ -s "$EXTRA_NOTE" ] && { echo "Cibles de liens    :"; sed 's/^/  /' "$EXTRA_NOTE"; }
  echo
  cat "$EXCL_REPORT"
  echo
  [ -e "$HOME/.claude.json" ] && echo "~/.claude.json : présent, JAMAIS archivé (jetons MCP possibles)."
  ok "dry-run terminé"
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------------------
# 3) Metadata (staged in $STAGE, archived under .claude-kit-backup-v1/)

info "Collecte des métadonnées"
{
  echo "claude --version :"
  if command -v claude >/dev/null 2>&1; then run_timeout 20 claude --version 2>&1 </dev/null | head -3 | sed 's/^/  /'; else echo "  (claude absent du PATH)"; fi
  echo "uname : $(uname -srm)"
  echo "bash  : ${BASH_VERSION:-?}"
  echo "tar   : $(tar --version 2>&1 | head -1)"
} >"$STAGE/versions.txt" 2>&1

KIT_CMD=""
if command -v kit >/dev/null 2>&1; then KIT_CMD=$(command -v kit)
elif [ -n "$KIT_DIR" ] && [ -x "$KIT_DIR/scripts/kit.sh" ]; then KIT_CMD="$KIT_DIR/scripts/kit.sh"; fi
{
  if [ -n "$KIT_CMD" ]; then
    if KIT_AUTOUPDATE=0 run_timeout 20 "$KIT_CMD" --version >/dev/null 2>&1 </dev/null; then
      echo "kit --version : $(KIT_AUTOUPDATE=0 run_timeout 20 "$KIT_CMD" --version 2>&1 </dev/null | head -1)"
    else
      echo "kit --version : non géré en v1 (la référence est le commit du dépôt, voir kit-git.txt)"
    fi
    echo
    echo "kit doctor (sortie telle quelle, code de sortie en dernière ligne) :"
    KIT_AUTOUPDATE=0 run_timeout 60 "$KIT_CMD" doctor 2>&1 </dev/null
    echo "[code de sortie : $?]"
  else
    echo "kit absent du PATH et du dépôt : pas de kit doctor"
  fi
} >"$STAGE/kit-doctor.txt" 2>&1

if [ -n "$KIT_DIR" ] && [ "$HAVE_GIT" -eq 1 ] && git -C "$KIT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  g() { git -C "$KIT_DIR" "$@" 2>&1; }
  UP=""
  if g rev-parse --verify -q '@{u}' >/dev/null; then UP='@{u}'
  elif g rev-parse --verify -q origin/main >/dev/null; then UP=origin/main; fi
  {
    echo "kit_dir_basename : $(basename "$KIT_DIR")"
    echo "remotes :"; g remote -v | clean_url | sed 's/^/  /'
    echo "branch : $(git -C "$KIT_DIR" symbolic-ref --short -q HEAD 2>/dev/null || echo '(détachée)')"
    echo "commit : $(g rev-parse HEAD)"
    echo "describe : $(g describe --always --tags --dirty)"
    echo "comparé à : ${UP:-(aucun amont connu)}"
    if [ -n "$UP" ]; then
      echo "amont : $(g rev-parse "$UP")"
      echo "ahead/behind (HEAD...amont) : $(g rev-list --left-right --count "HEAD...$UP")"
    fi
    if g rev-parse --verify -q refs/remotes/origin/legacy/v1 >/dev/null; then
      echo "origin/legacy/v1 : $(g rev-parse refs/remotes/origin/legacy/v1)"
      if git -C "$KIT_DIR" merge-base --is-ancestor HEAD refs/remotes/origin/legacy/v1 2>/dev/null; then
        echo "HEAD est dans legacy/v1 : oui"
      else
        echo "HEAD est dans legacy/v1 : non (commits locaux ou plus récents que le point de restauration)"
      fi
    else
      echo "origin/legacy/v1 : non récupéré localement (git fetch origin legacy/v1)"
    fi
    echo "status --porcelain :"; g status --porcelain | sed 's/^/  /'
    echo "git config core.sshCommand défini : $([ -n "$(git -C "$KIT_DIR" config --get core.sshCommand 2>/dev/null)" ] && echo oui || echo non)"
  } >"$STAGE/kit-git.txt"
  # Local work that exists only on this machine: uncommitted changes, unpushed commits, untracked files.
  git -C "$KIT_DIR" diff --binary HEAD >"$STAGE/kit-local-changes.patch" 2>/dev/null
  [ -s "$STAGE/kit-local-changes.patch" ] || rm -f "$STAGE/kit-local-changes.patch"
  if [ -n "$UP" ]; then
    git -C "$KIT_DIR" format-patch --stdout --binary "$UP..HEAD" >"$STAGE/kit-unpushed-commits.patch" 2>/dev/null
    [ -s "$STAGE/kit-unpushed-commits.patch" ] || rm -f "$STAGE/kit-unpushed-commits.patch"
  fi
  git -C "$KIT_DIR" -c core.quotepath=false ls-files -z --others --exclude-standard 2>/dev/null | tr '\0' '\n' >"$WORK/untracked.all"
  : >"$WORK/untracked.keep"
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$f" | grep -qiE "$RE_SECRET|$RE_BULKY" && continue
    [ -f "$KIT_DIR/$f" ] && [ ! -L "$KIT_DIR/$f" ] || continue
    [ "$(size_of "$KIT_DIR/$f")" -le 1048576 ] || continue
    n=$((n + 1)); [ "$n" -le 500 ] || break
    printf '%s\n' "$f" >>"$WORK/untracked.keep"
  done <"$WORK/untracked.all"
  if [ -s "$WORK/untracked.keep" ]; then
    mkdir -p "$STAGE/kit-untracked"
    (cd "$KIT_DIR" && tar -cf - -T "$WORK/untracked.keep") | tar -xf - -C "$STAGE/kit-untracked"
  fi
else
  echo "kit introuvable ou git absent : état du dépôt non collecté" >"$STAGE/kit-git.txt"
fi

# Context clones (~/.kit/context/*): their .git is not archived, so record where they point.
if [ "$HAVE_GIT" -eq 1 ] && [ -d "$HOME/.kit/context" ]; then
  for d in "$HOME"/.kit/context/*; do
    [ -d "$d/.git" ] || continue
    {
      echo "$(basename "$d") : branche $(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || echo '(détachée)'), commit $(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
      echo "  remote : $(git -C "$d" config --get remote.origin.url 2>/dev/null | clean_url)"
      echo "  modifications locales : $(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ') fichier(s)"
    } >>"$STAGE/kit-context-git.txt"
  done
fi

# Symlinks of ~/.claude (raw targets) and what was added because of them.
{
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    printf '%s -> %s\n' "$l" "$(readlink "$HOME/$l" 2>/dev/null)"
  done <"$WORK/links.txt"
} >"$STAGE/claude-symlinks.txt"
[ -s "$EXTRA_NOTE" ] && cp "$EXTRA_NOTE" "$STAGE/symlink-targets-added.txt"

# ~/.claude.json is NOT archived: only the names and types of the user-scope MCP servers (no args, env or headers).
{
  if [ -f "$HOME/.claude.json" ]; then
    echo "~/.claude.json : présent ($(size_of "$HOME/.claude.json") octets), non archivé."
    if command -v jq >/dev/null 2>&1; then
      echo "Serveurs MCP de portée utilisateur (nom, type, commande ou hôte seulement) :"
      jq -r '(.mcpServers // {}) | to_entries[] | "  \(.key) : \(.value.type // "stdio") \(.value.command // ((.value.url // "") | split("/") | .[0:3] | join("/")))"' "$HOME/.claude.json" 2>/dev/null \
        || echo "  (illisible)"
    else
      echo "  (jq absent : liste non extraite)"
    fi
    echo "Les recréer en v1 : kit mcp setup (Coolify) ; le serveur MCP du tableau de bord n'existe plus en v2."
  else
    echo "~/.claude.json : absent"
  fi
} >"$STAGE/claude-json-note.txt"

# The staged metadata must not carry a secret either (e.g. a token inside an uncommitted diff).
SUSPECT_META="$WORK/suspect-meta.txt"
grep -rlE -- "$RE_CONTENT" "$STAGE" 2>/dev/null >"$SUSPECT_META"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rm -f "$f"
  echo "omis (contenu ressemblant à un secret) : ${f#"$STAGE"/}" >>"$STAGE/OMITTED.txt"
done <"$SUSPECT_META"

# ---------------------------------------------------------------------------------------------------------------------
# 4) Archive

STAMP=$(date +%Y%m%d-%H%M%S)
HOST_RAW=$(hostname 2>/dev/null || uname -n)
HOST_HASH=$(printf '%s' "$HOST_RAW" | hash_stdin | cut -c1-8) || HOST_HASH=""
[ -n "$HOST_HASH" ] || die "aucun outil sha256 (sha256sum, shasum ou openssl)"
NAME="v1-$HOST_HASH-$STAMP"

{
  echo "claude-kit : sauvegarde v1 (format $SCRIPT_VERSION)"
  echo "créée le : $(date '+%F %T %z')"
  echo "hôte : $(hostname -s 2>/dev/null || echo ?)   empreinte : $HOST_HASH   système : $(uname -s)"
  echo "script : backup-v1.sh   transcripts : $([ "$TRANSCRIPTS" -eq 1 ] && echo inclus || echo exclus)"
  echo "racines archivées (relatives à \$HOME) : $ROOTS"
  echo "fichiers et liens archivés : $(count_lines "$KEPT")"
  echo
  echo "Restauration : tar -xzf $NAME.tar.gz -C ~   (voir docs/rollback-v1.md ; ce dossier .claude-kit-backup-v1 est informatif)"
  echo
  echo "== Écarté =="
  cat "$EXCL_REPORT"
  if [ -s "$STAGE/OMITTED.txt" ]; then echo; cat "$STAGE/OMITTED.txt"; fi
  echo
  echo "== Contenu de ce dossier =="
  (cd "$STAGE" && find . -type f ! -name MANIFEST.txt | sed 's#^\./#  #' | sort)
} >"$STAGE/MANIFEST.txt"

if [ ! -d "$OUT" ]; then
  mkdir -p "$OUT" && chmod 700 "$OUT" || die "création de $OUT impossible"
elif [ "$default_out" -eq 1 ]; then
  chmod 700 "$OUT" 2>/dev/null
else
  m=$(mode_of "$OUT"); [ "$m" = 700 ] || warn "$OUT existe avec le mode ${m:-?} (pas 700) : l'archive est en 600, mais vérifie ce dossier."
fi
FINAL="$OUT/$NAME.tar.gz"
[ ! -e "$FINAL" ] || die "$FINAL existe déjà (réessaie dans une seconde)"
PARTIAL=$(mktemp -d "$OUT/.partial.XXXXXX") || die "dossier temporaire dans $OUT impossible"

export COPYFILE_DISABLE=1 # macOS: no AppleDouble (._*) entries
info "Création de l'archive"
tar -cf "$PARTIAL/a.tar" -C "$HOME" -T "$KEPT" || die "tar a échoué (fichier modifié pendant la lecture ? relance)"
tar -rf "$PARTIAL/a.tar" -C "$STAGE_ROOT" .claude-kit-backup-v1 || die "ajout des métadonnées échoué"
gzip -c "$PARTIAL/a.tar" >"$PARTIAL/$NAME.tar.gz" || die "compression échouée"
mv "$PARTIAL/$NAME.tar.gz" "$FINAL" || die "déplacement vers $FINAL impossible"
chmod 600 "$FINAL"

# ---------------------------------------------------------------------------------------------------------------------
# 5) Verification: list the archive and refuse it if any path matches a secret pattern.

info "Contrôle du contenu"
LISTING="$WORK/listing.txt"
tar -tzf "$FINAL" 2>/dev/null | sed 's#^\./##' >"$LISTING" || true
if [ ! -s "$LISTING" ]; then rm -f "$FINAL"; die "archive illisible : supprimée"; fi
HITS="$WORK/hits.txt"
grep -iE "$RE_SECRET" "$LISTING" >"$HITS"
if [ -s "$HITS" ]; then
  rm -f "$FINAL"
  warn "chemins de secrets détectés dans l'archive : elle a été SUPPRIMÉE"
  sed 's/^/  /' "$HITS" >&2
  die "sauvegarde refusée (corrige les règles de $0 avant de relancer)"
fi

( cd "$OUT" && printf '%s  %s\n' "$(sha256_file "$NAME.tar.gz")" "$NAME.tar.gz" >"$NAME.tar.gz.sha256" ) || die "somme de contrôle impossible"
chmod 600 "$FINAL.sha256"

total=$(count_lines "$LISTING")
ok "Archive : $FINAL ($(size_of "$FINAL") octets, $total entrées, mode $(mode_of "$FINAL"))"
ok "Somme de contrôle : $FINAL.sha256"
echo "Répartition (2 premiers niveaux) :"
awk -F/ '{ k = $1; if (NF > 2) k = k "/" $2; c[k]++ } END { for (k in c) print "  " c[k] "\t" k }' "$LISTING" | sort -rn | head -15
if [ -s "$DROP_SUSPECT" ] || [ -s "$STAGE/OMITTED.txt" ]; then
  warn "Des fichiers ont été OMIS car leur contenu ressemble à un secret (liste dans MANIFEST.txt) :"
  [ -s "$DROP_SUSPECT" ] && sed 's/^/    /' "$DROP_SUSPECT" >&2
  [ -s "$STAGE/OMITTED.txt" ] && sed 's/^/    /' "$STAGE/OMITTED.txt" >&2
  warn "Retire le secret du fichier (ou garde-le à part), puis relance si le fichier compte."
fi
if [ "$TRANSCRIPTS" -eq 1 ]; then
  warn "Transcripts inclus : ils peuvent contenir des secrets collés dans les conversations. Chiffre l'archive avant de la stocker."
fi

cat <<EOF

Étapes manuelles (rien n'est envoyé nulle part par ce script) :
  1. Vérifie la somme :   cd "$OUT" && $(command -v sha256sum >/dev/null 2>&1 && echo "sha256sum -c $NAME.tar.gz.sha256" || echo "shasum -a 256 -c $NAME.tar.gz.sha256")
  2. Copie l'archive ET sa somme HORS de cette machine : pièce jointe du gestionnaire de mots de passe, ou disque chiffré.
     Pas dans un dépôt Git, pas dans un dossier synchronisé en clair.
  3. Sauvegarde À PART, dans le gestionnaire de mots de passe (jamais dans cette archive) :
       - la clé age du poste (par défaut ~/.config/sops/age/keys.txt) : sans elle, les secrets chiffrés sont perdus ;
       - le fichier de secrets globaux chiffré (~/.config/claude-kit/secrets/global.enc.json), qui n'est dans aucun dépôt.
  4. ~/.claude.json n'est pas archivé (jetons MCP possibles) : les serveurs MCP se recréent avec kit mcp setup
     (Coolify ; celui du tableau de bord n'existe plus en v2) ; leur liste (noms seulement) est dans .claude-kit-backup-v1/claude-json-note.txt.
  5. Lance ce script sur CHAQUE poste (macOS et Linux), puis suis docs/rollback-v1.md pour le retour arrière.
EOF
exit 0
