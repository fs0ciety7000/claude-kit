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

# Jokers : ? [ ] { } sont refusés partout. « * » n'est admis que de façon structurée (voir check_bash_spec, check_file_spec,
# check_kit_api_path) : les tests de mots-clés par sous-chaîne sont contournables par un joker au milieu d'un mot.
GLOB_FORBIDDEN_RE='[][?{}]'

# Premier mot d'une règle Bash refusé : shells et interpréteurs, élévation, réseau brut, lanceurs de code arbitraire.
# (Un premier mot contenant « / » ou « = » est refusé aussi : binaire désigné par chemin, ou variable d'environnement.)
BASH_FIRST_REFUSED_RE='^(bash|sh|zsh|dash|ksh|fish|csh|tcsh|python[0-9.]*|perl|ruby|php[0-9.]*|node|nodejs|deno|bun|lua[0-9.]*|osascript|su|doas|sudo|env|exec|xargs|curl|wget|nc|ncat|telnet|ftp|make|gmake|just|eval|source|\.|command|builtin|time|timeout|nice|nohup|watch|setsid|stdbuf|busybox|bunx|uvx|pipx)$'
# Premier + deuxième mot refusés : exécuteurs de paquets, installations, cibles destructrices de git et gh.
BASH_PAIR_REFUSED_RE='^(pnpm (dlx|exec|x)|yarn (dlx|exec)|npm (exec|x)|pip[0-9.]* install|cargo (run|install)|go (run|install)|gh (workflow|pr merge)|git (config|rebase|restore|filter-.*|stash drop|stash clear))$'
# npx : seulement ces outils fixes (le mot suivant doit être fixe) ; playwright seulement avec « test ».
NPX_ALLOWED_RE='^(prettier|eslint|tsc|vitest|playwright)$'
# Options globales de git qui déplacent le dépôt ou changent la configuration.
GIT_OPTS_REFUSED_RE='^(-C|-c|--git-dir(=.*)?|--work-tree(=.*)?|--exec-path(=.*)?)$'

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
# Outils MCP : verbes d'écriture dangereuse, interdits n'importe où dans le nom de l'outil. Les préfixes get_/list_/read_ n'y
# échappent pas (« get_latest_release » est refusé : il est déjà dans les réglages globaux). Les create_*/update_*/add_*
# ordinaires restent permis.
MCP_DANGER_RE='delete|remove|destroy|drop|truncate|merge|deploy|publish|release|trigger|push|force|execute|exec|run|shell|sql|migration|apply|write|create_or_update|update_file'

# Services de « kit api » ; GET libre, POST/PUT/PATCH sur chemin concret seulement.
KIT_API_SERVICES_RE='^(coolify|cloudflare|github)$'
# Chemins « kit api » qui déclenchent une action ou détruisent (start/stop/restart/deploy… sont des GET chez Coolify) : refusés.
KIT_API_PATH_DANGER_RE='merge|deploy|start|stop|restart|delete'
# Segments fixes minimaux avant un « /* » final : 3 pour POST/PUT/PATCH, 1 pour GET.
KIT_API_WRITE_MIN_SEGMENTS=3

# Edit/Write : fichiers ou dossiers exécutés par la CI ou par un build, refusés (comparés en minuscules).
# Tout segment commençant par « . » est refusé aussi (.claude, .git, .github, .husky, .vscode, .mcp.json, fichiers d'environnement).
WRITE_PROTECTED_NAMES_RE='^(package(-lock)?\.json|npm-shrinkwrap\.json|makefile|gnumakefile|justfile|dockerfile.*|docker-compose.*|compose\.ya?ml|.*\.lock|bun\.lockb|pnpm-lock\.yaml|go\.sum|cargo\.toml|build\.rs|setup\.py|pyproject\.toml|rakefile|gemfile|scripts|hooks|bin|ci)$'

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
  name=${rule#mcp__*__}
  low=$(tr 'A-Z' 'a-z' <<<"$name")
  if [[ $low =~ $MCP_DANGER_RE ]]; then
    bad "outil MCP dont le nom évoque une suppression, fusion, publication, push, exécution ou écriture brute (« $name »)"
    return 1
  fi
  check_overlap mcp "$rule" "$rule"
}


# Chemins Read/Glob/Grep/Edit/Write : relatifs au projet, premier segment fixe et sans point initial, « * » ou « ** » seulement
# comme segment entier. Edit/Write : aucun segment commençant par « . », aucun fichier de build/CI (WRITE_PROTECTED_NAMES_RE).
check_file_spec() { # tool spec
  local tool=$1 spec=$2 segs=() seg lseg i
  [[ -n $spec ]] || { bad "spécification vide"; return 1; }
  [[ $spec != /* && $spec != '~'* ]] || { bad "chemin absolu ou ~ : seuls les chemins relatifs au projet sont acceptés"; return 1; }
  [[ $spec != */ && $spec != *//* ]] || { bad "segment de chemin vide"; return 1; }
  IFS=/ read -ra segs <<<"$spec"
  for i in "${!segs[@]}"; do
    seg=${segs[$i]}
    lseg=$(tr 'A-Z' 'a-z' <<<"$seg")
    if [[ -z $seg || $seg == . || $seg == .. ]]; then bad "segment « $seg » interdit (le chemin doit rester dans le projet)"; return 1; fi
    if [[ $seg == *'*'* ]]; then
      if ((i == 0)); then bad "le premier segment doit être un dossier ou fichier fixe (pas de joker : $spec)"; return 1; fi
      if [[ $seg != '*' && $seg != '**' ]]; then bad "« * » et « ** » ne sont admis que comme segment entier (pas dans « $seg »)"; return 1; fi
    fi
    if ((i == 0)) && [[ $seg == .* ]]; then bad "le premier segment ne peut pas commencer par « . » ($seg)"; return 1; fi
    if [[ $tool == Edit || $tool == Write ]]; then
      if [[ $seg == .* ]]; then bad "écriture dans un chemin caché ($seg : .claude, .git, .github, .husky…) : réservée à l'utilisateur"; return 1; fi
      if [[ $lseg =~ $WRITE_PROTECTED_NAMES_RE ]]; then
        bad "écriture dans un fichier ou dossier de build/CI/scripts ($seg) : réservée à l'utilisateur"
        return 1
      fi
    fi
  done
}

# check_kit_api_path <méthode> <mot-chemin> : chemin concret ; un « * » unique et final, juste après « / ».
check_kit_api_path() {
  local method=$1 path=$2 base segs=() s n lp
  path=${path#[\"\']}; path=${path%[\"\']}
  [[ $path == /* ]] || { bad "kit api : le chemin doit commencer par /"; return 1; }
  [[ $path != *..* ]] || { bad "kit api : « .. » interdit dans le chemin"; return 1; }
  lp=$(tr 'A-Z' 'a-z' <<<"$path")
  if [[ $lp =~ $KIT_API_PATH_DANGER_RE ]]; then
    bad "kit api : le chemin évoque une action (merge, deploy, start, stop, restart, delete)"
    return 1
  fi
  base=$path
  n=1
  if [[ $path == *'*'* ]]; then
    [[ $path == */\* && ${path%\*} != *'*'* ]] || { bad "kit api : un seul « * », en toute fin du chemin, juste après « / »"; return 1; }
    base=${path%/\*}
    case $method in POST | PUT | PATCH) n=$KIT_API_WRITE_MIN_SEGMENTS ;; esac
  fi
  IFS=/ read -ra segs <<<"${base#/}"
  if ((${#segs[@]} < n)); then
    bad "kit api $method : au moins $n segments fixes avant « /* »"
    return 1
  fi
  for s in "${segs[@]}"; do
    [[ $s =~ ^[A-Za-z0-9_.:-]+$ ]] || { bad "kit api : segment de chemin non concret (« $s »)"; return 1; }
  done
}

check_bash_spec() { # spec  (casse d'origine)
  local spec=$1 core before low entry label re c=() wf=() first second i word pair p
  [[ -n $spec ]] || { bad "Bash() vide"; return 1; }

  # A. « * » : un seul, en toute fin, derrière un espace ou un « / » ; jamais en tête.
  core=$spec
  if [[ $spec == *'*'* ]]; then
    before=${spec%\*}
    [[ $spec == *'*' && $before != *'*'* ]] || { bad "un seul joker « * » est admis, en toute fin de règle"; return 1; }
    [[ -n $before ]] || { bad "commande trop large (joker en tête)"; return 1; }
    [[ $before == *' ' || $before == */ ]] || { bad "le « * » final doit suivre un espace ou un « / » (ex. Bash(npm run test *)) : collé à un mot, il le prolongerait en n'importe quoi"; return 1; }
    core=$before
  fi
  read -ra c <<<"$core"
  read -ra wf <<<"$spec"
  if [[ $spec == *'*'* ]] && ((${#c[@]} < 2)); then
    bad "joker après un seul mot fixe : il faut au moins deux mots fixes avant le joker (ex. Bash(npm run test *))"
    return 1
  fi
  ((${#c[@]} >= 1)) || { bad "commande vide"; return 1; }
  low=$(tr 'A-Z' 'a-z' <<<"$core")

  # Chaînage, redirection, substitution.
  # shellcheck disable=SC2053
  if [[ $spec == $BASH_METACHAR_GLOB || $spec == *'$('* || $spec == *'${'* ]]; then
    bad "chaînage, redirection ou substitution (; & | < > \` \$( ) : une règle ne doit désigner qu'une commande"
    return 1
  fi

  # B. Premier mot.
  first=${c[0]}
  second=${c[1]:-}
  [[ $first != */* ]] || { bad "binaire désigné par un chemin ($first)"; return 1; }
  [[ $first != *=* ]] || { bad "variable d'environnement avant la commande ($first)"; return 1; }
  if [[ $first =~ $BASH_FIRST_REFUSED_RE ]]; then
    bad "« $first » (shell, interpréteur, élévation, réseau brut ou lanceur de code) : à valider par l'utilisateur"
    return 1
  fi
  pair="$first $second"
  if [[ $pair =~ $BASH_PAIR_REFUSED_RE ]]; then bad "« $pair » : exécute du code arbitraire ou modifie l'historique/la configuration"; return 1; fi
  if [[ $first == npx ]]; then
    [[ $second =~ $NPX_ALLOWED_RE ]] || { bad "npx : seuls prettier, eslint, tsc, vitest et playwright test sont acceptés, avec un nom d'outil fixe"; return 1; }
    [[ $second != playwright || ${c[2]:-} == test ]] || { bad "npx playwright : seulement « npx playwright test »"; return 1; }
  fi
  if [[ $first == npm || $first == pnpm || $first == yarn ]]; then
    for word in "${c[@]}"; do
      [[ $word != -g && $word != --global && $word != --location=global ]] || { bad "installation globale ($first … $word)"; return 1; }
    done
  fi

  # C. Arguments : jamais de chemin absolu, de ~ ni de « .. » (sauf le chemin d'un « kit api », validé à part).
  for i in "${!c[@]}"; do
    ((i >= 1)) || continue
    word=${c[$i]}
    if [[ $first == kit && ${c[1]} == api && $i -eq 4 ]]; then continue; fi
    if [[ $word =~ (^|=)[\"\']?[/~] ]]; then bad "argument sur un chemin absolu ou ~ (« $word ») : seuls les chemins relatifs au projet sont acceptés"; return 1; fi
    if [[ $word =~ (^|/)\.\.($|/) ]]; then bad "argument avec « .. » (« $word ») : le chemin sort du projet"; return 1; fi
  done
  if [[ $first == git ]]; then
    for word in "${c[@]:1}"; do
      if [[ $word =~ $GIT_OPTS_REFUSED_RE ]]; then bad "option git globale ($word) : déplace le dépôt ou change la configuration"; return 1; fi
      if [[ $word == push ]]; then bad "git push : les push restent gouvernés par les réglages globaux"; return 1; fi
    done
    if [[ $second == checkout ]]; then
      for word in "${c[@]:2}"; do
        [[ $word != -- && $word != . ]] || { bad "git checkout -- / . : écrase le travail en cours"; return 1; }
      done
    fi
  fi

  # Secrets (« .env.example » retiré avant le test de « .env »).
  local s2=${low//.env.example/}
  for p in "${SECRET_WORDS[@]}"; do
    if [[ $s2 == *"$p"* ]]; then bad "mentionne un secret ou un fichier sensible (« $p »)"; return 1; fi
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

  # F. kit api.
  if [[ $first == kit && $second == api ]]; then
    local svc=${wf[2]:-} method=${wf[3]:-} path=${wf[4]:-}
    [[ $svc =~ $KIT_API_SERVICES_RE ]] || { bad "kit api : service attendu coolify, cloudflare ou github"; return 1; }
    case $method in
      GET) ;;
      POST | PUT | PATCH)
        [[ -n $path && $path != '*' ]] || { bad "kit api $method : chemin précis exigé"; return 1; }
        ;;
      *) bad "kit api : seuls GET, et POST/PUT/PATCH sur un chemin précis, sont acceptés (méthode explicite requise)"; return 1 ;;
    esac
    if [[ -n $path && $path != '*' ]]; then check_kit_api_path "$method" "$path" || return 1; fi
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

  # A. Jokers ? [ ] { } refusés pour tous les outils ; « * » est encadré outil par outil.
  if [[ $spec =~ $GLOB_FORBIDDEN_RE ]]; then bad "jokers ? [ ] { } interdits : seul un « * » structuré est admis"; return 1; fi

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

# Verrou par projet : deux « kit perms allow » simultanés ne doivent pas s'écraser. flock si présent, sinon mkdir.
# Le verrou vit dans $TMPDIR (rien à ignorer dans le dépôt) ; libéré à la sortie du processus.
TMP_FILE=""
LOCK_DIR=""
cleanup() {
  [[ -z $TMP_FILE ]] || rm -f "$TMP_FILE"
  [[ -z $LOCK_DIR ]] || rmdir "$LOCK_DIR" 2>/dev/null || true
}
acquire_lock() { # dossier-projet
  local lock n=0
  lock="${TMPDIR:-/tmp}/kit-perms-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  trap cleanup EXIT
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock.flock"
    flock -w 10 9 || die "verrou occupé ($lock.flock) : un autre kit perms écrit dans ce projet"
  else
    until mkdir "$lock.d" 2>/dev/null; do
      n=$((n + 1))
      ((n <= 100)) || die "verrou occupé ($lock.d) : supprime-le s'il est périmé"
      sleep 0.1
    done
    LOCK_DIR="$lock.d"
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

  local settings="$dir/.claude/settings.json" log="$dir/docs/memory/permissions.md" global p
  global=$(readlink -f "$CLAUDE_HOME/settings.json" 2>/dev/null || echo "$CLAUDE_HOME/settings.json")
  # G. Tout est vérifié AVANT la première écriture : aucun lien symbolique sur le trajet, tout reste dans le projet.
  for p in "$dir/.claude" "$settings" "$dir/docs" "$dir/docs/memory" "$log"; do
    [[ ! -L $p ]] || die "$p est un lien : refusé (aucune écriture hors du projet)"
  done
  [[ $(readlink -f "$settings" 2>/dev/null || echo "$settings") != "$global" ]] || die "refus de modifier $global"
  mkdir -p "$dir/.claude" "$dir/docs/memory"
  for p in "$dir/.claude" "$dir/docs/memory"; do
    [[ $(cd "$p" && pwd -P) == "$p" ]] || die "$p sort du projet : refusé"
  done
  acquire_lock "$dir"

  if [[ -f $settings ]]; then
    jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || die "$settings n'est pas un objet JSON valide"
    if jq -e --arg r "$rule" '(.permissions.allow // []) | index($r) != null' "$settings" >/dev/null; then
      ok "règle déjà présente (rien à faire) : $rule"
      return 0
    fi
  else
    echo '{}' >"$settings"
  fi
  TMP_FILE=$(mktemp "$dir/.claude/.settings.json.XXXXXX")
  jq --arg r "$rule" '
    .permissions = ((.permissions // {}) | .allow = (((.allow // []) + [$r]) | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)))
  ' "$settings" >"$TMP_FILE" || die "écriture des réglages échouée"
  chmod 644 "$TMP_FILE"
  mv "$TMP_FILE" "$settings"
  TMP_FILE=""

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
