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
  ln -sfn "$KIT_HOME/scripts/hooks/kit-dockerd.sh" "$KIT_CONFIG/hooks/kit-dockerd.sh"
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

# Empreinte SHA-256 (hexadécimal) de l'entrée standard.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else openssl dgst -sha256 -r | cut -d' ' -f1; fi
}

# automode_v1_owned <instantané v1> <réglages actuels> : écrit {"autoMode": {<liste>: [entrées]}} avec les entrées
# autoMode.* des réglages actuels dont l'empreinte SHA-256 (de la chaîne exacte) figure dans autoModeSha256 de
# l'instantané. L'instantané ne contient pas ces phrases en clair (elles décrivent l'infra interne, le dépôt est
# public). Les entrées sur plusieurs lignes ne sont pas comparées : aucune entrée du kit n'en a.
automode_v1_owned() {
  local snap=$1 cur=$2 rows k line rc
  rows=$(mktemp) || return 1
  while IFS= read -r k; do
    while IFS= read -r line; do
      printf '%s\t%s\t%s\n' "$k" "$(printf '%s' "$line" | sha256_hex)" "$line" >>"$rows"
    done < <(jq -r --arg k "$k" '(.autoMode[$k] // []) | if type == "array" then .[] else empty end
      | select(type == "string" and (contains("\n") | not))' "$cur")
  done < <(jq -r '(.autoMode // {}) | keys_unsorted[]' "$cur")
  rc=0
  jq -R -s --slurpfile s "$snap" '
    ($s[0].autoModeSha256 // {}) as $m
    | split("\n") | map(select(length > 0) | split("\t"))
    | map(select(. as $r | any(($m[$r[0]] // [])[]; . == $r[1])))
    | reduce .[] as $r ({}; .autoMode[$r[0]] += [$r[2:] | join("\t")])' "$rows" || rc=$?
  rm -f "$rows"
  return $rc
}

# Réglages gérés : fusion à trois points de ~/.claude/settings.json (programme jq : scripts/managed-settings.jq).
# Clés gérées : permissions.allow|ask|deny|defaultMode, hooks, autoMode.*. Le reste du fichier n'est jamais touché.
#   K = réglages du kit pour ce poste : global/settings.json, + settings.vps.json (profil vps),
#       + $KIT_CONFIG/settings.local.json (surcharge propre au poste, jamais dans Git, absente par défaut).
#   L = registre $KIT_CONFIG/settings.managed.json = le K appliqué la dernière fois. Absent (première exécution après
#       la mise à niveau) : L = K + global/settings.v1.json, instantané de toutes les entrées que le kit v1 a écrites
#       (autoMode.* y figure en empreintes SHA-256, pas en clair).
#   U = ajouts de l'utilisateur = C (fichier actuel) moins L, par liste. Un groupe de hooks dont une commande pointe
#       dans $KIT_CONFIG/hooks appartient toujours au kit (retire les doublons).
#   Nouveau fichier : chaque liste = K puis U, sans doublon, ordre gardé ; defaultMode vient de K. Écriture atomique
#   seulement si le contenu change, sauvegarde settings.json.pre-kit.<date> (les 3 dernières gardées), puis L := K.
# Option --dry-run : affiche l'écart par clé, n'écrit rien (ni fichier, ni sauvegarde, ni registre).
apply_managed_settings() {
  local dry=0 cur="$CLAUDE_HOME/settings.json" reg="$KIT_CONFIG/settings.managed.json"
  local jqf="$KIT_HOME/scripts/managed-settings.jq" snap="$KIT_HOME/global/settings.v1.json"
  local overlay="$KIT_CONFIG/settings.local.json" tmpd f created=0 migrating=0 nb_add nb_rm
  [[ ${1:-} == --dry-run ]] && dry=1
  need jq "Installe jq."
  [[ -f $jqf ]] || die "$jqf introuvable"
  local frags=("$KIT_HOME/global/settings.json")
  if [[ "$(cat "$KIT_CONFIG/profile" 2>/dev/null || echo local)" == vps ]]; then frags+=("$KIT_HOME/global/settings.vps.json"); fi
  [[ -f $overlay ]] && frags+=("$overlay")
  for f in "${frags[@]}"; do
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f n'est pas un objet JSON valide"
  done
  if [[ -f $cur ]]; then
    jq -e 'type == "object"' "$cur" >/dev/null 2>&1 || die "$cur n'est pas du JSON valide (objet attendu)"
  else
    created=1
  fi

  tmpd=$(mktemp -d) || die "mktemp échoué"
  # K : réglages du kit pour ce poste.
  jq -s --arg mode build -f "$jqf" "${frags[@]}" >"$tmpd/k.json" || { rm -rf "$tmpd"; die "calcul des réglages du kit échoué"; }
  # C : fichier actuel.
  if ((created)); then echo '{}' >"$tmpd/c.json"; else cp "$cur" "$tmpd/c.json"; fi
  # L : registre, ou K + instantané v1 à la première exécution.
  if [[ -f $reg ]] && jq -e 'type == "object"' "$reg" >/dev/null 2>&1; then
    jq --arg mode project -f "$jqf" "$reg" >"$tmpd/l.json" || { rm -rf "$tmpd"; die "lecture de $reg échouée"; }
  else
    migrating=1
    [[ -f $reg ]] && warn "$reg illisible : traité comme absent"
    if [[ -f $snap ]]; then
      jq -s --arg mode build -f "$jqf" "$tmpd/k.json" "$snap" >"$tmpd/l.json" || { rm -rf "$tmpd"; die "lecture de $snap échouée"; }
      # autoMode.* est stocké en empreintes SHA-256 dans l'instantané : les entrées de C qui y figurent viennent du kit.
      automode_v1_owned "$snap" "$tmpd/c.json" >"$tmpd/lx.json" \
        && jq -s --arg mode build -f "$jqf" "$tmpd/l.json" "$tmpd/lx.json" >"$tmpd/l2.json" \
        && mv "$tmpd/l2.json" "$tmpd/l.json" \
        || { rm -rf "$tmpd"; die "lecture des empreintes autoMode de $snap échouée"; }
    else
      warn "$snap introuvable : les anciennes entrées du kit ne seront pas retirées"
      cp "$tmpd/k.json" "$tmpd/l.json"
    fi
  fi
  jq -n --arg mode merge --arg kitdir "$KIT_CONFIG/hooks" \
    --slurpfile c "$tmpd/c.json" --slurpfile k "$tmpd/k.json" --slurpfile l "$tmpd/l.json" \
    -f "$jqf" >"$tmpd/res.json" || { rm -rf "$tmpd"; die "fusion des réglages échouée"; }
  jq '.new' "$tmpd/res.json" >"$tmpd/new.json"

  local changed=0
  if ((created)) || [[ "$(jq -S -c . "$tmpd/c.json")" != "$(jq -S -c . "$tmpd/new.json")" ]]; then changed=1; fi
  nb_add=$(jq '[.changes[].added | length] | add // 0' "$tmpd/res.json")
  nb_rm=$(jq '[.changes[].removed | length] | add // 0' "$tmpd/res.json")

  if ((dry)); then
    info "réglages gérés ($cur) : simulation, rien n'est écrit"
    if ((migrating)); then info "registre absent : première migration (entrées du kit = K + instantané v1)"; fi
    if ((changed)); then
      jq -r 'def short: tojson | if length > 160 then .[0:157] + "..." else . end;
        .changes[]
        | "  " + .name + " : +" + (.added | length | tostring) + " -" + (.removed | length | tostring)
          + (if .duplicates > 0 then " (doublons exacts retirés : " + (.duplicates | tostring) + ")" else "" end),
          (.added[] | "    + " + short), (.removed[] | "    - " + short)' "$tmpd/res.json"
      if ((nb_add + nb_rm == 0)); then echo "  (ordre ou doublons exacts seulement)"; fi
    else
      echo "  aucun changement"
    fi
    rm -rf "$tmpd"
    return 0
  fi

  if ((changed)); then
    if ((created)); then
      mkdir -p "$(dirname "$cur")"
      write_atomic "$cur" "$(cat "$tmpd/new.json")"
      ok "réglages créés : $cur"
    else
      cp "$cur" "$cur.pre-kit.$(date +%Y%m%d%H%M%S)"
      write_atomic "$cur" "$(cat "$tmpd/new.json")"
      ok "réglages mis à jour : $cur (+$nb_add -$nb_rm entrées)"
      # Garde les 3 dernières sauvegardes (l'horodatage trie dans l'ordre chronologique).
      local bks=() b i
      for b in "$cur".pre-kit.*; do [[ -e $b ]] && bks+=("$b"); done
      for ((i = 0; i < ${#bks[@]} - 3; i++)); do rm -f "${bks[i]}"; done
    fi
  fi
  # Registre : L := K, seulement si son contenu change.
  if [[ ! -f $reg ]] || [[ "$(jq -S -c . "$tmpd/k.json")" != "$(jq -S -c --arg mode project -f "$jqf" "$reg" 2>/dev/null)" ]]; then
    mkdir -p "$KIT_CONFIG"
    write_atomic "$reg" "$(cat "$tmpd/k.json")"
  fi
  rm -rf "$tmpd"
}
