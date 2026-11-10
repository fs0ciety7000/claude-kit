#!/usr/bin/env bash
# Helpers partagés par install.sh, kit.sh et secrets.sh. À sourcer, pas à exécuter.

KIT_HOME="${KIT_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
KIT_CONFIG="${KIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit}"

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "→ $*"; }
ok()   { echo "✓ $*"; }
warn() { echo "! $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' introuvable. ${2:-}"; }

# macOS fournit bash 3.2 (pas de mapfile, tableaux vides fragiles avec set -u).
if ((BASH_VERSINFO[0] < 4)); then
  die "bash ${BASH_VERSION} trop ancien (4+ requis). macOS : brew install bash, puis relance (ouvre un nouveau terminal)."
fi

# Système : arch | debian | macos | other
os_kind() {
  case $(uname -s) in
    Darwin) echo macos ;;
    Linux)
      if command -v pacman >/dev/null 2>&1; then echo arch
      elif command -v apt-get >/dev/null 2>&1; then echo debian
      else echo other; fi ;;
    *) echo other ;;
  esac
}

# Commande d'installation suggérée pour des paquets (noms Arch ; traduits si besoin).
pkg_hint() { # paquet...
  local p out=()
  case $(os_kind) in
    macos)
      for p in "$@"; do case $p in nodejs) out+=(node) ;; npm) ;; github-cli) out+=(gh) ;; *) out+=("$p") ;; esac; done
      echo "brew install ${out[*]}" ;;
    debian)
      for p in "$@"; do case $p in github-cli) out+=(gh) ;; sops) ;; *) out+=("$p") ;; esac; done
      local s="sudo apt-get install -y ${out[*]}"
      [[ " $* " == *" sops "* ]] && s+="   (sops : https://github.com/getsops/sops/releases)"
      echo "$s" ;;
    arch) echo "sudo pacman -S --needed $*" ;;
    *) echo "installe : $*" ;;
  esac
}

# stat portable (GNU / BSD)
file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# timeout portable : GNU timeout, gtimeout (coreutils Homebrew), sinon sans limite.
run_timeout() { # secondes commande...
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else "$@"; fi
}

# Lie chaque élément de $1 (dans le kit) vers $2 (dans ~/.claude).
# Ne remplace jamais un élément existant qui n'est pas déjà un lien.
link_dir() { # src_dir dst_dir
  local src=$1 dst=$2 item name target
  mkdir -p "$dst"
  shopt -s nullglob
  for item in "$src"/*; do
    name=$(basename "$item")
    target="$dst/$name"
    if [[ -L "$target" ]]; then
      ln -sfn "$item" "$target"
    elif [[ -e "$target" ]]; then
      warn "$target existe déjà (non géré par le kit), ignoré"
    else
      ln -s "$item" "$target"
    fi
  done
  shopt -u nullglob
  # Supprime les liens cassés qui pointaient vers le kit (agent/skill retiré).
  # (sans find -xtype, absent sous macOS)
  shopt -s nullglob
  for item in "$dst"/*; do
    [[ -L $item && ! -e $item && $(readlink "$item") == "$KIT_HOME"/* ]] && rm -f "$item"
  done
  shopt -u nullglob
}

# Lie un fichier unique ; sauvegarde l'existant s'il n'est pas déjà un lien vers le kit.
link_file() { # src dst
  local src=$1 dst=$2
  if [[ -L "$dst" ]]; then
    ln -sfn "$src" "$dst"
  elif [[ -e "$dst" ]]; then
    mv "$dst" "$dst.pre-kit"
    warn "$dst sauvegardé en $dst.pre-kit"
    ln -s "$src" "$dst"
  else
    ln -s "$src" "$dst"
  fi
}

link_global() {
  mkdir -p "$CLAUDE_HOME" "$KIT_CONFIG/hooks"
  link_dir  "$KIT_HOME/global/agents"   "$CLAUDE_HOME/agents"
  link_dir  "$KIT_HOME/global/commands" "$CLAUDE_HOME/commands"
  link_dir  "$KIT_HOME/global/skills"   "$CLAUDE_HOME/skills"
  link_file "$KIT_HOME/global/CLAUDE.md"          "$CLAUDE_HOME/CLAUDE.md"
  link_file "$KIT_HOME/global/skills-registry.md" "$CLAUDE_HOME/skills-registry.md"
  ln -sfn "$KIT_HOME/scripts/hooks/guard-secrets.sh" "$KIT_CONFIG/hooks/guard-secrets.sh"
  ln -sfn "$KIT_HOME/scripts/hooks/kit-emit.sh" "$KIT_CONFIG/hooks/kit-emit.sh"
  ln -sfn "$KIT_HOME/scripts/hooks/kit-autoupdate.sh" "$KIT_CONFIG/hooks/kit-autoupdate.sh"
}

# merge_settings <fichier-existant> <réglages-kit> <current|kit>
# Fusionne en union les listes allow/ask/deny et les hooks de chaque événement.
# "current" : les valeurs scalaires existantes gagnent ; "kit" : celles du kit gagnent.
merge_settings() {
  local cur=$1 kit=$2 winner=${3:-current} out base created=0
  need jq "Installe jq."
  if [[ -f $cur ]]; then
    jq -e . "$cur" >/dev/null 2>&1 || die "$cur n'est pas du JSON valide"
    base=$cur
  else
    # Fichier absent : on part de {} pour obtenir la même forme normalisée qu'à la fusion suivante.
    created=1
    base=$(mktemp)
    echo '{}' >"$base"
  fi
  if ! out=$(jq -s --arg w "$winner" '
    .[0] as $cur | .[1] as $kit
    | (if $w == "kit" then ($cur * $kit) else ($kit * $cur) end)
    | .permissions.allow = ((($cur.permissions.allow // []) + ($kit.permissions.allow // [])) | unique)
    | .permissions.ask   = ((($cur.permissions.ask   // []) + ($kit.permissions.ask   // [])) | unique)
    | .permissions.deny  = ((($cur.permissions.deny  // []) + ($kit.permissions.deny  // [])) | unique)
    # The kit decides the permission mode (auto); the autoMode lists are unions, kit entries first, order kept.
    | (if $kit.permissions.defaultMode then .permissions.defaultMode = $kit.permissions.defaultMode else . end)
    | reduce ("environment", "allow", "soft_deny", "hard_deny") as $k (.;
        if ($cur.autoMode[$k] // $kit.autoMode[$k]) == null then .
        else .autoMode[$k] = ((($kit.autoMode[$k] // []) + ($cur.autoMode[$k] // []))
                              | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end))
        end)
    | reduce ((($cur.hooks // {}) + ($kit.hooks // {})) | keys[]) as $e (.;
        .hooks[$e] = ((($cur.hooks[$e] // []) + ($kit.hooks[$e] // [])) | unique))
  ' "$base" "$kit"); then
    if ((created)); then rm -f "$base"; fi
    die "fusion des réglages échouée"
  fi
  if ((created)); then
    rm -f "$base"
    mkdir -p "$(dirname "$cur")"
    write_atomic "$cur" "$out"
    ok "réglages créés : $cur"
  elif [[ "$out" != "$(cat "$cur")" ]]; then
    cp "$cur" "$cur.pre-kit.$(date +%Y%m%d%H%M%S)"
    write_atomic "$cur" "$out"
    ok "réglages mis à jour : $cur"
  fi
}

# write_atomic <fichier> <contenu> : écrit dans un fichier temporaire du même dossier puis mv (jamais de fichier tronqué
# si le processus est interrompu). Suit un lien symbolique (réglages versionnés ailleurs) et garde les droits existants.
write_atomic() {
  local target=$1 content=$2 real tmp mode=644
  real=$(readlink -f "$target" 2>/dev/null || echo "$target")
  [[ -f $real ]] && mode=$(file_mode "$real")
  tmp=$(mktemp "$(dirname "$real")/.$(basename "$real").XXXXXX") || die "écriture impossible : $(dirname "$real")"
  printf '%s\n' "$content" >"$tmp" && chmod "$mode" "$tmp" && mv "$tmp" "$real" || { rm -f "$tmp"; die "écriture de $real échouée"; }
}

apply_settings() {
  mkdir -p "$CLAUDE_HOME"
  merge_settings "$CLAUDE_HOME/settings.json" "$KIT_HOME/global/settings.json" current
  if [[ "$(cat "$KIT_CONFIG/profile" 2>/dev/null || echo local)" == vps ]]; then
    merge_settings "$CLAUDE_HOME/settings.json" "$KIT_HOME/global/settings.vps.json" kit
  fi
}
