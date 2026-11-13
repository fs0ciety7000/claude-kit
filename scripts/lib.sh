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
  # Le dossier de config (registre des réglages, surcharge locale, secrets chiffrés) n'est lisible que par son propriétaire.
  if [[ ! -d $KIT_CONFIG ]]; then mkdir -p "$KIT_CONFIG" && chmod 700 "$KIT_CONFIG"; fi
  mkdir -p "$CLAUDE_HOME" "$KIT_CONFIG/hooks"
  link_dir  "$KIT_HOME/global/agents"   "$CLAUDE_HOME/agents"
  link_dir  "$KIT_HOME/global/commands" "$CLAUDE_HOME/commands"
  link_dir  "$KIT_HOME/global/skills"   "$CLAUDE_HOME/skills"
  link_file "$KIT_HOME/global/CLAUDE.md"          "$CLAUDE_HOME/CLAUDE.md"
  link_file "$KIT_HOME/global/skills-registry.md" "$CLAUDE_HOME/skills-registry.md"
  ln -sfn "$KIT_HOME/scripts/hooks/guard-secrets.sh" "$KIT_CONFIG/hooks/guard-secrets.sh"
  ln -sfn "$KIT_HOME/scripts/hooks/kit-autoupdate.sh" "$KIT_CONFIG/hooks/kit-autoupdate.sh"
  ln -sfn "$KIT_HOME/scripts/hooks/kit-dockerd.sh" "$KIT_CONFIG/hooks/kit-dockerd.sh"
  retire_dashboard
}

# The kit-control dashboard was abandoned (sessions are followed with `claude remote-control`). Removes what earlier
# versions of `kit sync` left on this machine: the kit-emit hook link, its URL file and the user-scope MCP server
# declaration. The settings entries (hooks, permissions) are retired by the managed-settings merge. Never fatal.
dashboard_hook_left() { # settings.json : vrai si un hook du tableau de bord y figure encore
  [[ -f $1 ]] && jq -e '[.. | .command? // empty | select(type == "string" and test("kit-emit"))] | length > 0' "$1" >/dev/null 2>&1
}
retire_dashboard() {
  local cj="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  rm -f "$KIT_CONFIG/hooks/kit-emit.sh" "$KIT_CONFIG/dash.url"
  [[ -f $cj ]] || return 0
  jq -e '(.mcpServers // {}) | has("kit-control")' "$cj" >/dev/null 2>&1 || return 0
  if command -v claude >/dev/null 2>&1 && claude mcp remove --scope user kit-control >/dev/null 2>&1; then
    ok "serveur MCP kit-control retiré (tableau de bord abandonné)"
  else
    warn "serveur MCP kit-control encore déclaré : claude mcp remove --scope user kit-control"
  fi
  return 0
}

# write_atomic <fichier> <contenu> [droits] : écrit dans un fichier temporaire du même dossier puis mv (jamais de fichier tronqué
# si le processus est interrompu). Suit un lien symbolique (réglages versionnés ailleurs) et garde les droits existants.
write_atomic() {
  local target=$1 content=$2 real tmp mode=644
  real=$(readlink -f "$target" 2>/dev/null || echo "$target")
  if [[ -f $real ]]; then mode=$(file_mode "$real"); fi
  if [[ -n ${3:-} ]]; then mode=$3; fi
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
#   L = registre $KIT_CONFIG/settings.managed.json = le K appliqué la dernière fois (+ le profil). Absent ou illisible
#       (première exécution après la mise à niveau) : L = K + global/settings.v1.json, instantané des entrées allow,
#       hooks et autoMode (en empreintes SHA-256) que le kit v1 a écrites.
#   U = ajouts de l'utilisateur = C (fichier actuel) moins L, pour allow et autoMode.environment|allow.
#   deny, ask, autoMode.soft_deny|hard_deny ne sont JAMAIS retirés automatiquement : seules les règles listées dans
#   global/settings.retired.json le sont. Hooks : seules les entrées exactement <dossier des hooks du kit>/<script du
#   kit> (même matcher que dans K ou L) appartiennent au kit ; les autres restent.
#   Nouveau fichier : chaque liste = K puis U, sans doublon, ordre gardé ; defaultMode vient de K, mais un passage à un
#   mode plus permissif (default -> auto…) est refusé sans --yes. Écriture atomique seulement si le contenu change,
#   sous verrou ($KIT_CONFIG/settings.lock), sauvegarde settings.json.pre-kit.<date> (la plus ancienne et les 2
#   dernières gardées), puis L := K.
# Options : --dry-run affiche l'écart par clé et n'écrit rien (ni fichier, ni sauvegarde, ni registre, ni verrou) ;
#           --yes accepte un defaultMode plus permissif.
# Variables : KIT_LOCK_WAIT (secondes d'attente du verrou, 10 par défaut).
_AMS_TMPD=""
_AMS_LOCK=""
_ams_cleanup() {
  if [[ -n $_AMS_TMPD ]]; then rm -rf "$_AMS_TMPD"; fi
  if [[ -n $_AMS_LOCK ]]; then rm -rf "$_AMS_LOCK"; fi
  _AMS_TMPD="" _AMS_LOCK=""
  return 0
}

# Verrou par mkdir (flock est absent de macOS). Un verrou dont le processus n'existe plus, ou sans pid depuis plus de
# 5 minutes, est repris. Retourne 1 si le verrou reste tenu après KIT_LOCK_WAIT secondes.
_ams_lock() {
  local lock="$KIT_CONFIG/settings.lock" waited=0 max=${KIT_LOCK_WAIT:-10} pid
  while ! mkdir "$lock" 2>/dev/null; do
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -n $pid ]]; then
      if ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
    elif [[ -n $(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null) ]]; then
      rm -rf "$lock"; continue
    fi
    ((waited < max)) || return 1
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ >"$lock/pid"
  _AMS_LOCK=$lock
}

# Forme attendue d'un fichier de réglages (objet ; permissions, hooks et autoMode bien typés) : sans elle, la fusion échouerait.
_ams_valid() { # fichier
  jq -e '
    type == "object"
    and ((.permissions // {}) | type == "object" and all((.allow, .ask, .deny); . == null or type == "array"))
    and ((.hooks // {}) | type == "object" and all(.[]; type == "array"))
    and ((.autoMode // {}) | type == "object" and all(.[]; type == "array"))' "$1" >/dev/null 2>&1
}

# Rang de permissivité d'un defaultMode (plus grand = plus permissif).
_ams_rank() {
  case $1 in plan) echo 0 ;; default) echo 1 ;; acceptEdits) echo 2 ;; auto) echo 3 ;; bypassPermissions) echo 4 ;; *) echo 9 ;; esac
}

# Contrôle de la surcharge locale : refuse bypassPermissions et les règles allow trop larges, affiche ce qu'elle apporte.
_ams_check_overlay() { # fichier
  local f=$1 bad line
  bad=$(jq -r '
    [(.permissions.allow // [])[] | select(type == "string"
        and test("^(\\*|Bash|Bash\\(\\*{1,2}\\)|Bash\\(:\\*\\)|(Edit|Write|MultiEdit|NotebookEdit)(\\(\\*{0,2}\\))?)$"))
      | "permissions.allow : " + .]
    + (if .permissions.defaultMode == "bypassPermissions" then ["permissions.defaultMode : bypassPermissions"] else [] end)
    | .[]' "$f") || die "lecture de $f échouée"
  if [[ -n $bad ]]; then
    warn "surcharge refusée ($f) : une surcharge locale ne peut pas contenir"
    while IFS= read -r line; do warn "  $line"; done <<<"$bad"
    die "retire ces entrées de $f (règles larges et bypassPermissions : à décider dans global/settings.json, par PR)"
  fi
  info "surcharge locale ($f) :"
  jq -r 'def short: tojson | if length > 120 then .[0:117] + "..." else . end;
    ((.permissions // {}) | to_entries[] | select(.value | type == "array")
      | "  permissions." + .key + " : +" + (.value | length | tostring)
        + (if .key == "allow" or .key == "ask" or .key == "deny" then " (" + (.value | map(short) | join(", ")) + ")" else "" end)),
    (if .permissions.defaultMode then "  permissions.defaultMode : " + (.permissions.defaultMode | tostring) else empty end),
    ((.hooks // {}) | to_entries[] | "  hooks." + .key + " : +" + (.value | length | tostring) + " groupe(s)"),
    ((.autoMode // {}) | to_entries[] | "  autoMode." + .key + " : +" + (.value | length | tostring) + " entrée(s)")' "$f"
}

# Phrases autoMode.environment propres au poste (domaines et hôtes internes : le dépôt est public, elles n'y figurent pas).
#   Source : fichier texte hors dépôt, une phrase par ligne ($KIT_CONFIG/environment.local.txt par défaut ; lignes vides et
#   lignes commençant par # ignorées). Cible : autoMode.environment de $KIT_CONFIG/settings.local.json (600), seule clé
#   que cette fonction touche ; le reste du fichier est conservé. Fichier vide ou --clear : la clé est retirée.
#   Session cloud : la variable KIT_LOCAL_ENVIRONMENT (même format) est d'abord écrite dans le fichier par défaut.
#   overlay_sync <fichier|""> <dry 0|1> [--verbose]. Écrit seulement si le contenu change. Ne montre jamais les phrases.
overlay_sync() {
  local src=${1:-} dry=${2:-0} verbose=${3:-} overlay="$KIT_CONFIG/settings.local.json" arr bad base new n
  if [[ -z $src ]]; then
    src="$KIT_CONFIG/environment.local.txt"
    if [[ -n ${KIT_LOCAL_ENVIRONMENT:-} ]] && ((!dry)); then
      if [[ ! -d $KIT_CONFIG ]]; then mkdir -p "$KIT_CONFIG" && chmod 700 "$KIT_CONFIG"; fi
      write_atomic "$src" "$KIT_LOCAL_ENVIRONMENT" 600
    fi
  fi
  [[ -f $src ]] || return 0
  arr=$(jq -R -s 'split("\n") | map(gsub("\r"; "") | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0 and (startswith("#") | not)))' "$src") \
    || die "lecture de $src échouée"
  bad=$(jq -r 'map(select(length > 800 or test("[\u0001-\u001f]"))) | length' <<<"$arr")
  [[ $bad == 0 ]] || die "$src : $bad ligne(s) de plus de 800 caractères ou avec un caractère de contrôle"
  base='{}'
  if [[ -f $overlay ]]; then
    _ams_valid "$overlay" || die "$overlay n'est pas un objet JSON de réglages valide"
    base=$(cat "$overlay")
  fi
  new=$(jq --argjson e "$arr" 'if ($e | length) > 0 then .autoMode.environment = $e
    else del(.autoMode.environment) | (if .autoMode == {} then del(.autoMode) else . end) end' <<<"$base") || die "fusion de $src échouée"
  n=$(jq 'length' <<<"$arr")
  if [[ "$(jq -S -c . <<<"$base")" == "$(jq -S -c . <<<"$new")" ]]; then
    [[ -z $verbose ]] || ok "autoMode.environment local : déjà à jour ($n phrase(s))"
    return 0
  fi
  if ((dry)); then
    info "autoMode.environment local : $n phrase(s) de $src seraient appliquées à $overlay"
    return 0
  fi
  if [[ ! -d $KIT_CONFIG ]]; then mkdir -p "$KIT_CONFIG" && chmod 700 "$KIT_CONFIG"; fi
  write_atomic "$overlay" "$(jq . <<<"$new")" 600
  ok "autoMode.environment local : $n phrase(s) de $src écrites dans $overlay (600)"
}

apply_managed_settings() {
  local dry=0 yes=0 cur="$CLAUDE_HOME/settings.json" reg="$KIT_CONFIG/settings.managed.json"
  local jqf="$KIT_HOME/scripts/managed-settings.jq" snap="$KIT_HOME/global/settings.v1.json"
  local retired="$KIT_HOME/global/settings.retired.json" overlay="$KIT_CONFIG/settings.local.json"
  local tmpd f created=0 migrating=0 nb_add nb_rm profile="" reg_profile="" a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      --yes) yes=1 ;;
      *) die "option inconnue : $a" ;;
    esac
  done
  need jq "Installe jq."
  [[ -f $jqf ]] || die "$jqf introuvable"
  overlay_sync "" "$dry"

  # Profil : fichier profile ; à défaut, celui du registre (un profil vps ne retombe pas silencieusement sur local).
  profile=$(cat "$KIT_CONFIG/profile" 2>/dev/null || true)
  if [[ -f $reg ]]; then reg_profile=$(jq -r '.profile // empty' "$reg" 2>/dev/null || true); fi
  if [[ -z $profile ]]; then
    if [[ -n $reg_profile && $reg_profile != local ]]; then
      warn "profil introuvable ($KIT_CONFIG/profile) : profil « $reg_profile » du registre conservé"
      profile=$reg_profile
    else
      profile=local
    fi
  fi

  local frags=("$KIT_HOME/global/settings.json")
  if [[ $profile == vps ]]; then frags+=("$KIT_HOME/global/settings.vps.json"); fi
  if [[ -f $overlay ]]; then
    chmod 600 "$overlay" 2>/dev/null || true
    _ams_valid "$overlay" || die "$overlay n'est pas un objet JSON de réglages valide"
    _ams_check_overlay "$overlay"
    frags+=("$overlay")
  fi
  for f in "${frags[@]}"; do
    _ams_valid "$f" || die "$f n'est pas un objet JSON de réglages valide"
  done
  if [[ -f $cur ]]; then
    _ams_valid "$cur" || die "$cur n'est pas du JSON valide (objet de réglages attendu : permissions, hooks et autoMode en listes)"
  else
    created=1
  fi

  if ((!dry)); then
    if [[ ! -d $KIT_CONFIG ]]; then mkdir -p "$KIT_CONFIG" && chmod 700 "$KIT_CONFIG"; fi
    _ams_lock || { warn "réglages non appliqués : $KIT_CONFIG/settings.lock est tenu par un autre kit sync (réessaie)"; return 0; }
  fi
  tmpd=$(mktemp -d) || { _ams_cleanup; die "mktemp échoué"; }
  _AMS_TMPD=$tmpd
  trap '_ams_cleanup' EXIT
  trap '_ams_cleanup; exit 130' INT
  trap '_ams_cleanup; exit 143' TERM

  # K : réglages du kit pour ce poste.
  jq -s --arg mode build -f "$jqf" "${frags[@]}" >"$tmpd/k.json" || die "calcul des réglages du kit échoué"
  # C : fichier actuel (lu une fois ; son cksum est revérifié juste avant l'écriture).
  local sum0=""
  if ((created)); then echo '{}' >"$tmpd/c.json"; else cp "$cur" "$tmpd/c.json"; sum0=$(cksum <"$cur"); fi
  # L : registre, ou K + instantané v1 à la première exécution.
  if [[ -f $reg ]] && _ams_valid "$reg" && jq --arg mode project -f "$jqf" "$reg" >"$tmpd/l.json" 2>/dev/null; then
    :
  else
    migrating=1
    if [[ -f $reg ]]; then warn "$reg illisible : traité comme absent (première migration)"; fi
    if [[ -f $snap ]]; then
      # Le profil vps ajoute ses entrées à l'instantané (profiles.<profil>) ; local = global seul.
      jq --arg p "$profile" '.profiles[$p] // {}' "$snap" >"$tmpd/snapprof.json" || die "lecture de $snap échouée"
      jq -s --arg mode build -f "$jqf" "$tmpd/k.json" "$snap" "$tmpd/snapprof.json" >"$tmpd/l.json" || die "lecture de $snap échouée"
      # autoMode.* est stocké en empreintes SHA-256 dans l'instantané : les entrées de C qui y figurent viennent du kit.
      automode_v1_owned "$snap" "$tmpd/c.json" >"$tmpd/lx.json" \
        && jq -s --arg mode build -f "$jqf" "$tmpd/l.json" "$tmpd/lx.json" >"$tmpd/l2.json" \
        && mv "$tmpd/l2.json" "$tmpd/l.json" \
        || die "lecture des empreintes autoMode de $snap échouée"
    else
      warn "$snap introuvable : les anciennes entrées du kit ne seront pas retirées"
      cp "$tmpd/k.json" "$tmpd/l.json"
    fi
  fi
  # Règles que le kit a explicitement retirées (deny, ask, autoMode.soft_deny|hard_deny).
  if [[ -f $retired ]] && jq -e 'type == "object"' "$retired" >/dev/null 2>&1; then cp "$retired" "$tmpd/r.json"; else echo '{}' >"$tmpd/r.json"; fi
  # Préfixes ancrés du dossier des hooks du kit et noms de ses scripts.
  local prefixes names h
  # shellcheck disable=SC2016,SC2088
  prefixes=$(printf '%s\n' "$KIT_CONFIG/hooks/" "$HOME/.config/claude-kit/hooks/" '$HOME/.config/claude-kit/hooks/' \
    '${HOME}/.config/claude-kit/hooks/' '~/.config/claude-kit/hooks/' | jq -R . | jq -s -c .) || die "préfixes de hooks"
  names=$(for h in "$KIT_HOME"/scripts/hooks/*.sh; do [[ -e $h ]] && basename "$h"; done | jq -R . | jq -s -c .) || die "noms de hooks"
  jq -n --arg mode merge --argjson prefixes "$prefixes" --argjson names "$names" --argjson yes "$( ((yes)) && echo true || echo false )" \
    --slurpfile c "$tmpd/c.json" --slurpfile k "$tmpd/k.json" --slurpfile l "$tmpd/l.json" --slurpfile r "$tmpd/r.json" \
    -f "$jqf" >"$tmpd/res.json" || die "fusion des réglages échouée"
  jq '.new' "$tmpd/res.json" >"$tmpd/new.json"
  local dm_c dm_k
  dm_c=$(jq -r '.permissions.defaultMode // empty' "$tmpd/c.json")
  dm_k=$(jq -r '.permissions.defaultMode // empty' "$tmpd/k.json")
  if [[ -n $dm_c && -n $dm_k && $dm_c != "$dm_k" ]] && (($(_ams_rank "$dm_k") > $(_ams_rank "$dm_c"))) && ((!yes)); then
    warn "defaultMode : le kit voudrait passer de « $dm_c » à « $dm_k » (plus permissif) : refusé. Relance « kit sync --yes » pour l'accepter."
  fi

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
    _ams_cleanup
    trap - EXIT INT TERM
    return 0
  fi

  if ((changed)); then
    # Le fichier a-t-il changé depuis la lecture ? (un autre processus, ou l'utilisateur dans son éditeur)
    if { ((created)) && [[ -e $cur ]]; } || { ((!created)) && [[ "$(cksum <"$cur" 2>/dev/null)" != "$sum0" ]]; }; then
      warn "$cur a changé pendant la fusion : rien n'est écrit, réessaie (prochain kit sync)"
      _ams_cleanup
      trap - EXIT INT TERM
      return 0
    fi
    if ((created)); then
      mkdir -p "$(dirname "$cur")"
      write_atomic "$cur" "$(cat "$tmpd/new.json")"
      ok "réglages créés : $cur"
    else
      _ams_backup "$cur"
      write_atomic "$cur" "$(cat "$tmpd/new.json")"
      ok "réglages mis à jour : $cur (+$nb_add -$nb_rm entrées)"
      # Phrases d'environnement retirées du kit (domaines internes sortis du dépôt public) et rien en local pour les remplacer.
      if (($(jq '[.changes[] | select(.name == "autoMode.environment") | .removed | length] | add // 0' "$tmpd/res.json") > 0)) \
        && ! jq -e '(.autoMode.environment // []) | length > 0' "$overlay" >/dev/null 2>&1; then
        warn "autoMode.environment : des phrases du kit ont été retirées. Si elles décrivaient tes domaines internes, déclare-les sur ce poste : kit overlay env (voir README) ; l'ancien contenu est dans $cur.pre-kit.<date>"
      fi
      # Ce que le kit a retiré et qui peut compter : hooks, deny, ask (nommés, jamais silencieux).
      jq -r 'def short: tojson | if length > 160 then .[0:157] + "..." else . end;
        .changes[] | select(.name | test("^hooks[.]|^permissions[.](deny|ask)$|^autoMode[.](soft_deny|hard_deny)$"))
        | .name as $n | .removed[] | "→ retiré de " + $n + " : " + short' "$tmpd/res.json"
    fi
  fi
  # Registre : L := K (+ profil), seulement si son contenu change ; droits 600.
  jq --arg p "$profile" '. + {profile: $p}' "$tmpd/k.json" >"$tmpd/reg.json"
  if [[ ! -f $reg ]] || [[ "$(jq -S -c . "$tmpd/reg.json")" != "$(jq -S -c . "$reg" 2>/dev/null)" ]]; then
    write_atomic "$reg" "$(cat "$tmpd/reg.json")" 600
  else
    chmod 600 "$reg" 2>/dev/null || true
  fi
  _ams_cleanup
  trap - EXIT INT TERM
}

# Sauvegarde settings.json.pre-kit.<14 chiffres> : pas d'écrasement dans la même seconde, rien si identique à la
# dernière ; on garde la plus ancienne et les deux plus récentes (les suffixes qui ne sont pas des dates sont ignorés).
_ams_backup() { # fichier
  local cur=$1 ts b bks=() n i last=""
  for b in "$cur".pre-kit.*; do
    [[ -e $b && ${b##*.} =~ ^[0-9]{14}$ ]] && bks+=("$b")
  done
  n=${#bks[@]}
  if ((n > 0)); then last=${bks[n - 1]}; fi
  if [[ -z $last ]] || ! cmp -s "$cur" "$last"; then
    ts=$(date +%Y%m%d%H%M%S)
    while [[ -e $cur.pre-kit.$ts ]]; do ts=$((10#$ts + 1)); done
    cp "$cur" "$cur.pre-kit.$ts" && chmod 600 "$cur.pre-kit.$ts" 2>/dev/null
    bks+=("$cur.pre-kit.$ts")
    n=${#bks[@]}
  fi
  for ((i = 1; i < n - 2; i++)); do rm -f "${bks[i]}"; done
  return 0
}
