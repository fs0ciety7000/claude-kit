#!/usr/bin/env bash
# kit perms : règles d'autorisation que Claude s'accorde lui-même, au niveau du PROJET uniquement.
#
#   kit perms allow "<règle>" --reason "<pourquoi>" [--dir <projet>]
#   kit perms list [--dir <projet>]
#   kit perms check "<règle>"
#
# Garde-fous : la règle est validée (voir les tableaux ci-dessous), ajoutée à <projet>/.claude/settings.json
# (.permissions.allow, jamais deny/ask, jamais ~/.claude/settings.json), puis journalisée dans
# <projet>/docs/memory/permissions.md. Rien n'est jamais retiré. Une règle refusée demande l'accord explicite
# de l'utilisateur ou une PR sur fs0ciety7000/claude-kit (global/settings.json).
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=lib.sh
source "$(dirname "$SELF")/lib.sh"

# ---------------------------------------------------------------------------------------------------------
# Règles de validation, en données pour être relues facilement.
# Format des entrées : "libellé@@regex ERE". Elles sont testées sur la spécification en minuscules.
# ---------------------------------------------------------------------------------------------------------

# Frontières de mot : ni alphanumérique, ni _ . - (donc « .env », « age-keygen », « usage » ne déclenchent pas « env », « age »).
L='(^|[^[:alnum:]_.-])'
R='($|[^[:alnum:]_.-])'

# Outils acceptés (en plus de mcp__<serveur>__<outil>).
ALLOWED_TOOLS_RE='^(Bash|Read|Edit|Write|Glob|Grep|WebFetch)$'

# Outils qui ne peuvent jamais être accordés sans spécification (trop larges).
BARE_REFUSED=(Bash Read Edit Write WebFetch)

# Premier mot d'un Bash(...) qui lance du code arbitraire : refusé dès qu'un joker suit.
WILDCARD_REFUSED_FIRST_WORDS=(bash sh zsh dash ksh fish xargs nohup watch exec command builtin source time timeout nice)

# Interpréteurs : refusés avec -c / -e / -p / -r (code en ligne).
INTERPRETERS=(python python3 perl ruby php node deno bun)

# Chaînage, redirection, substitution : une règle Bash ne doit désigner qu'UNE commande (couvre aussi « | sh »).
BASH_METACHAR_GLOB='*[;&|<>`]*'

# Mots dangereux n'importe où dans une règle Bash (suppression, élévation, secrets, accès distant, conteneurs…).
DANGEROUS_BASH=(
  "rm@@${L}rm${R}"
  "sudo@@${L}sudo${R}"
  "--force@@--force"
  "push -f@@${L}push${R}.*[[:space:]]-f($|[[:space:]])"
  "reset --hard@@reset[[:space:]]+--hard"
  "clean@@${L}clean${R}"
  "branch -D@@branch[[:space:]]+-d"
  "--delete / -delete@@(^|[[:space:]])--?delete"
  "-exec@@(^|[[:space:]])-exec"
  "chmod / chown / chgrp@@${L}(chmod|chown|chgrp)${R}"
  "dd@@${L}dd${R}"
  "mkfs@@mkfs"
  "eval@@${L}eval${R}"
  "printenv@@${L}printenv${R}"
  "env@@^env${R}"
  "sops@@${L}sops${R}"
  "age@@${L}age(-keygen)?${R}"
  "kit secrets / kit perms@@kit[[:space:]]+(secrets|perms)"
  "ssh / scp / sftp@@${L}(ssh|scp|sftp)"
  "docker run|exec|push|rm@@${L}docker[[:space:]]+(run|exec|push|rm|rmi|login|system|volume)${R}"
  "kubectl / helm@@${L}(kubectl|helm)${R}"
  "terraform / tofu apply@@${L}(terraform|tofu)[[:space:]]+(apply|destroy)"
  "gh api / auth / secret@@${L}gh[[:space:]]+(api|auth|secret)${R}"
  "kill / shutdown@@${L}(kill|pkill|killall|shutdown|reboot)${R}"
  "réseau brut (utilise WebFetch(domain:…) ou kit api)@@^(curl|wget|nc|ncat|telnet|ftp)${R}"
)

# Secrets, sur toute spécification (tous outils). « .env.example » est retiré avant le test de « .env ».
SECRET_WORDS=(
  ".env" ".pem" ".key" ".p12" ".pfx" "id_rsa" "id_ed25519" ".ssh" ".gnupg" ".aws" ".kube" ".netrc" ".npmrc"
  ".pgpass" "secret" "keys.txt" "token" "password" "credential"
)

# Suppression / production : sur toute règle Bash et sur les outils MCP qui écrivent.
DELETE_PROD_BASH=(
  "DELETE@@delete"
  "TRIGGER@@trigger"
  "deploy@@deploy"
  "publish@@publish"
  "release@@release"
  "merge@@merge"
  "wrangler@@wrangler"
  "git push (les push restent gouvernés par les réglages globaux)@@git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*push"
)
# Outils MCP : mots interdits dans le nom, sauf outil de lecture (get_/list_/search_/read, ou finissant par _read/_get/_list).
DELETE_PROD_MCP_RE='delete|remove|destroy|merge|deploy|publish|release|trigger|drop|truncate|push|force'
MCP_READONLY_RE='^(get|list|search|read)_|_(read|get|list)$'

# Services de « kit api » ; GET libre, POST/PUT/PATCH sur chemin concret seulement.
KIT_API_SERVICES_RE='^(coolify|cloudflare|github)$'

# Chemins protégés en écriture (Edit/Write) : réglages de Claude, dépôt git, MCP.
WRITE_PROTECTED_RE='(^|/)\.(claude|git|mcp)($|[/*.])'

# ---------------------------------------------------------------------------------------------------------

REASON=""
bad() { REASON=$1; }

usage() {
  cat <<'EOF'
usage : kit perms allow "<règle>" --reason "<pourquoi>" [--dir <projet>]
        kit perms list [--dir <projet>]
        kit perms check "<règle>"
Ajoute une règle permissions.allow ÉTROITE au .claude/settings.json du projet et la journalise dans
docs/memory/permissions.md. Refus : règle large, secrets, suppression, déploiement, push.
EOF
}

# fixed_prefix <spec> : partie fixe avant le premier joker (« :* » hérité compris).
fixed_prefix() {
  local p=$1
  if [[ $p == *'*'* ]]; then
    p=${p%%\**}
    p=${p%:}
  fi
  printf '%s' "$p"
}

# load_restricted : deny + ask du kit (global/settings.json) dans le tableau RESTRICTED.
RESTRICTED=()
load_restricted() {
  local f="$KIT_HOME/global/settings.json"
  [[ -f $f ]] || { bad "global/settings.json du kit introuvable ($f) : impossible de vérifier deny/ask"; return 1; }
  mapfile -t RESTRICTED < <(jq -r '((.permissions.deny // []) + (.permissions.ask // []))[]' "$f") \
    || { bad "global/settings.json illisible"; return 1; }
}

# check_overlap <tool> <spec> <rule> : refuse ce qui recouvre une règle deny/ask du kit.
check_overlap() {
  local tool=$1 spec=$2 rule=$3 p ptool pspec rp pp
  load_restricted || return 1
  for p in "${RESTRICTED[@]}"; do
    if [[ $p == "$rule" ]]; then bad "identique à une règle deny/ask du kit ($p)"; return 1; fi
    [[ $p =~ ^([A-Za-z0-9_-]+)\((.*)\)$ ]] || continue
    ptool=${BASH_REMATCH[1]}
    pspec=${BASH_REMATCH[2]}
    [[ $ptool == "$tool" ]] || continue
    if [[ $tool == Bash ]]; then
      rp=$(fixed_prefix "$spec")
      pp=$(fixed_prefix "$pspec")
      # shellcheck disable=SC2053  # glob volontaire des deux côtés
      if [[ $rp == $pspec ]] || { [[ -n $pp ]] && [[ $pp == $spec ]]; }; then
        bad "recouvre une règle deny/ask du kit ($p)"
        return 1
      fi
    else
      # shellcheck disable=SC2053
      if [[ $spec == $pspec || $pspec == $spec ]]; then
        bad "recouvre une règle deny/ask du kit ($p)"
        return 1
      fi
    fi
  done
}

check_mcp() { # rule
  local rule=$1 name low
  [[ $rule != *'*'* && $rule != *'('* ]] || { bad "joker ou spécification interdits sur un outil MCP : écris exactement mcp__<serveur>__<outil>"; return 1; }
  [[ $rule =~ ^mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+$ ]] || { bad "format attendu : mcp__<serveur>__<outil> (un seul outil nommé)"; return 1; }
  name=${rule##*__}
  low=$(tr 'A-Z' 'a-z' <<<"$name")
  if ! [[ $low =~ $MCP_READONLY_RE ]] && [[ $low =~ $DELETE_PROD_MCP_RE ]]; then
    bad "outil MCP de suppression, fusion, publication ou push (« $name »)"
    return 1
  fi
  check_overlap mcp "$rule" "$rule"
}

check_file_spec() { # tool spec
  local tool=$1 spec=$2 stripped
  [[ -n $spec ]] || { bad "spécification vide"; return 1; }
  [[ $spec != *..* ]] || { bad "« .. » : le chemin sort du projet"; return 1; }
  [[ $spec != /* && $spec != '~'* ]] || { bad "chemin absolu ou ~ : seuls les chemins relatifs au projet sont acceptés"; return 1; }
  stripped=${spec//[*\/.]/}
  [[ -n $stripped ]] || { bad "motif trop large ($spec)"; return 1; }
  if [[ $tool == Edit || $tool == Write ]] && [[ $spec =~ $WRITE_PROTECTED_RE ]]; then
    bad "écriture dans .claude/, .git/ ou .mcp.json : réservée à l'utilisateur"
    return 1
  fi
}

check_bash_spec() { # spec  (casse d'origine)
  local spec=$1 low pre w first entry label re p1 p2
  low=$(tr 'A-Z' 'a-z' <<<"$spec")
  [[ -n $spec ]] || { bad "Bash() vide"; return 1; }
  [[ $spec != '*' && $spec != ':*' && $spec != \** ]] || { bad "commande trop large (joker en tête)"; return 1; }
  if [[ $spec == *'*'* ]]; then
    pre=$(fixed_prefix "$spec")
    read -ra w <<<"$pre"
    ((${#w[@]} >= 2)) || { bad "joker après un seul mot fixe : il faut au moins deux mots fixes avant le joker (ex. Bash(npm run test*))"; return 1; }
  fi
  read -ra w <<<"$spec"
  first=${w[0]:-}
  # shellcheck disable=SC2053
  if [[ $spec == $BASH_METACHAR_GLOB || $spec == *'$('* || $spec == *'${'* ]]; then
    bad "chaînage, redirection ou substitution (; & | < > \` \$( ) : une règle ne doit désigner qu'une commande"
    return 1
  fi
  # Secrets.
  local s2=${low//.env.example/}
  for p1 in "${SECRET_WORDS[@]}"; do
    if [[ $s2 == *"$p1"* ]]; then bad "mentionne un secret ou un fichier sensible (« $p1 »)"; return 1; fi
  done
  # Suppression / production.
  for entry in "${DELETE_PROD_BASH[@]}"; do
    label=${entry%%@@*}; re=${entry#*@@}
    if [[ $low =~ $re ]]; then bad "suppression, fusion ou déploiement : $label"; return 1; fi
  done
  # Mots dangereux.
  for entry in "${DANGEROUS_BASH[@]}"; do
    label=${entry%%@@*}; re=${entry#*@@}
    if [[ $low =~ $re ]]; then bad "contient une commande dangereuse : $label"; return 1; fi
  done
  # Code arbitraire.
  if [[ $spec == *'*'* ]]; then
    for p1 in "${WILDCARD_REFUSED_FIRST_WORDS[@]}"; do
      if [[ $first == "$p1" ]]; then bad "« $first » avec joker lancerait du code arbitraire"; return 1; fi
    done
  fi
  for p1 in "${INTERPRETERS[@]}"; do
    if [[ $first == "$p1" && $low =~ [[:space:]]-(c|e|p|r)([[:space:]]|$) ]]; then
      bad "code en ligne via « $first »"; return 1
    fi
  done
  # kit api.
  if [[ $first == kit && ${w[1]:-} == api ]]; then
    p1=${w[2]:-}; p2=${w[3]:-}
    [[ $p1 =~ $KIT_API_SERVICES_RE ]] || { bad "kit api : service attendu coolify, cloudflare ou github"; return 1; }
    case $p2 in
      GET) ;;
      POST | PUT | PATCH)
        local path=${w[4]:-}
        path=${path#\"}; path=${path#\'}
        [[ $path != *..* ]] || { bad "kit api : « .. » interdit dans le chemin"; return 1; }
        [[ $path =~ ^/[A-Za-z0-9_.-]+(/[^*[:space:]][^[:space:]]*)?$ ]] \
          || { bad "kit api $p2 : chemin concret exigé (pas de joker avant le deuxième segment, ex. /applications/<uuid>*)"; return 1; }
        ;;
      *) bad "kit api : seuls GET, et POST/PUT/PATCH sur un chemin précis, sont acceptés (méthode explicite requise)"; return 1 ;;
    esac
  fi
  check_overlap Bash "$spec" "Bash($spec)"
}

# validate_rule <règle> : 0 si acceptable ; sinon 1 et $REASON expliqué.
validate_rule() {
  local rule=$1 tool spec p low s2
  REASON=""
  [[ -n $rule ]] || { bad "règle vide"; return 1; }
  ((${#rule} <= 300)) || { bad "règle trop longue"; return 1; }
  if [[ $rule =~ [[:cntrl:]] || $rule == *'`'* ]]; then bad "caractère de contrôle ou accent grave interdits"; return 1; fi
  if [[ $rule == mcp__* ]]; then check_mcp "$rule"; return; fi
  if [[ $rule =~ ^([A-Za-z0-9_-]+)(\((.*)\))?$ ]]; then
    tool=${BASH_REMATCH[1]}
    spec=${BASH_REMATCH[3]}
    if [[ -z ${BASH_REMATCH[2]} ]]; then
      for p in "${BARE_REFUSED[@]}"; do
        if [[ $tool == "$p" ]]; then bad "« $tool » seul est trop large : précise une spécification étroite"; return 1; fi
      done
      [[ $tool =~ $ALLOWED_TOOLS_RE ]] || { bad "outil non pris en charge ($tool)"; return 1; }
      return 0  # Glob / Grep nus : lecture seule, déjà autorisés globalement
    fi
  else
    bad "syntaxe attendue : Outil ou Outil(spécification)"; return 1
  fi
  [[ $tool =~ $ALLOWED_TOOLS_RE ]] || { bad "outil non pris en charge ($tool) : Bash, Read, Edit, Write, Glob, Grep, WebFetch ou mcp__serveur__outil"; return 1; }

  case $tool in
    Bash) check_bash_spec "$spec" ;;
    WebFetch)
      [[ $spec =~ ^domain:([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+$ ]] || { bad "WebFetch exige domain:<hôte> précis, sans joker (ex. WebFetch(domain:docs.example.com))"; return 1; }
      [[ ! $spec =~ ^domain:[0-9.]+$ ]] || { bad "WebFetch : adresse IP refusée"; return 1; }
      check_overlap WebFetch "$spec" "$rule"
      ;;
    *)
      check_file_spec "$tool" "$spec" || return 1
      low=$(tr 'A-Z' 'a-z' <<<"$spec")
      s2=${low//.env.example/}
      for p in "${SECRET_WORDS[@]}"; do
        if [[ $s2 == *"$p"* ]]; then bad "mentionne un secret ou un fichier sensible (« $p »)"; return 1; fi
      done
      check_overlap "$tool" "$spec" "$rule"
      ;;
  esac
}

refusal_message() {
  echo "✗ Règle refusée : $1" >&2
  echo "  Cette règle demande l'accord explicite de l'utilisateur, ou une PR sur fs0ciety7000/claude-kit (global/settings.json)." >&2
}

# ---------- projet ----------

resolve_project_dir() { # [dir]
  local d=${1:-} home
  if [[ -z $d ]]; then d=$(git rev-parse --show-toplevel 2>/dev/null || pwd); fi
  [[ -d $d ]] || die "dossier introuvable : $d"
  d=$(cd "$d" && pwd -P)
  home=$(cd "$HOME" && pwd -P)
  if [[ $d == / || $d == "$home" ]]; then
    die "dossier de projet refusé ($d) : lance la commande dans un projet, ou passe --dir <projet>"
  fi
  printf '%s' "$d"
}

cmd_check() {
  local rule=${1:-}
  [[ -n $rule ]] || { usage >&2; exit 2; }
  if validate_rule "$rule"; then
    ok "règle acceptable : $rule"
  else
    refusal_message "$REASON"
    exit 1
  fi
}

cmd_allow() {
  local rule="" reason="" dir=""
  while (($#)); do
    case $1 in
      --reason) reason=${2:?"--reason : explication manquante"}; shift ;;
      --dir) dir=${2:?"--dir : dossier manquant"}; shift ;;
      -*) die "option inconnue : $1" ;;
      *) [[ -z $rule ]] && rule=$1 || die "argument en trop : $1 (mets la règle entre guillemets)" ;;
    esac
    shift
  done
  [[ -n $rule ]] || { usage >&2; exit 2; }
  reason=$(tr '\n\r\t`' '   '"'" <<<"$reason" | sed -E 's/^ +//; s/ +$//')
  [[ -n $reason ]] || die "--reason obligatoire : explique pourquoi cette règle est nécessaire"
  reason=${reason:0:300}
  need jq "Installe jq."
  if ! validate_rule "$rule"; then refusal_message "$REASON"; exit 1; fi
  dir=$(resolve_project_dir "$dir")

  local settings="$dir/.claude/settings.json" log="$dir/docs/memory/permissions.md" tmp global
  global=$(readlink -f "$CLAUDE_HOME/settings.json" 2>/dev/null || echo "$CLAUDE_HOME/settings.json")
  [[ ! -L $settings && ! -L $dir/.claude ]] || die "$settings est un lien : refusé (aucune écriture hors du projet)"
  [[ $(readlink -f "$settings" 2>/dev/null || echo "$settings") != "$global" ]] || die "refus de modifier $global"
  mkdir -p "$dir/.claude"
  if [[ -f $settings ]]; then
    jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || die "$settings n'est pas un objet JSON valide"
    if jq -e --arg r "$rule" '(.permissions.allow // []) | index($r) != null' "$settings" >/dev/null; then
      ok "règle déjà présente (rien à faire) : $rule"
      return 0
    fi
  else
    echo '{}' >"$settings"
  fi
  tmp=$(mktemp "$dir/.claude/.settings.json.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  jq --arg r "$rule" '
    .permissions = ((.permissions // {}) | .allow = (((.allow // []) + [$r]) | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)))
  ' "$settings" >"$tmp" || die "écriture des réglages échouée"
  chmod 644 "$tmp"
  mv "$tmp" "$settings"
  trap - EXIT

  [[ ! -L $log ]] || die "$log est un lien : journal non écrit (la règle est déjà ajoutée)"
  mkdir -p "$dir/docs/memory"
  if [[ ! -f $log ]]; then
    cat >"$log" <<'EOF'
# Permissions accordées par Claude

Règles `permissions.allow` ajoutées à `.claude/settings.json` via `kit perms allow` (périmètre projet, jamais large).
Une ligne par règle : date, règle, raison. Pour en retirer une, édite `.claude/settings.json` à la main.

EOF
  fi
  [[ -z $(tail -c1 "$log") ]] || echo >>"$log"
  printf -- '- %s `%s` — %s\n' "$(date +%F)" "$rule" "$reason" >>"$log"
  ok "règle ajoutée à ${settings/#$HOME/~} : $rule"
  info "journal : ${log/#$HOME/~}"
}

cmd_list() {
  local dir=""
  while (($#)); do
    case $1 in
      --dir) dir=${2:?"--dir : dossier manquant"}; shift ;;
      *) die "option inconnue : $1" ;;
    esac
    shift
  done
  need jq "Installe jq."
  dir=$(resolve_project_dir "$dir")
  local settings="$dir/.claude/settings.json" log="$dir/docs/memory/permissions.md"
  echo "== Règles allow du projet ($settings) =="
  if [[ -f $settings ]]; then
    jq -r '(.permissions.allow // [])[] | "  " + .' "$settings"
  else
    echo "  (aucune)"
  fi
  echo "== Journal ($log) =="
  if [[ -f $log ]]; then cat "$log"; else echo "  (vide)"; fi
}

main() {
  local sub=${1:-help}
  shift || true
  case $sub in
    allow) cmd_allow "$@" ;;
    list) cmd_list "$@" ;;
    check) cmd_check "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}
main "$@"
