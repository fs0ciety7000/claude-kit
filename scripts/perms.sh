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
# Validation par LISTE BLANCHE : une règle n'est acceptée que si elle appartient à une famille connue et sûre.
# Les listes noires sont contournables (jokers, guillemets, options inattendues) ; ici, tout ce qui n'est pas listé
# est refusé. Pour étendre : ajouter une ligne aux tableaux ci-dessous par PR sur claude-kit (relue par l'utilisateur).
# ---------------------------------------------------------------------------------------------------------

# --- Bash -------------------------------------------------------------------------------------------------

# Caractères admis dans une spécification Bash (donc ni \ ' " $ ` ; & | < > ( ) { } [ ] ? ~, ni tabulation, ni retour ligne).
# « * » n'est admis que comme dernier caractère, derrière un espace ou un « / » (contrôlé à part).
BASH_SPEC_CHARS_RE='^[A-Za-z0-9 _./:=%,*-]+$'

# Débuts de commande admis (mots entiers : le préfixe est la règle entière, ou suivi d'un espace). Lecture, build, test,
# lint, format de la pile, git non destructif, kit api en lecture seule, utilitaires de lecture. Rien qui écrive hors
# du projet, installe globalement, lance un interpréteur, un exécuteur de paquets ou un déploiement.
BASH_ALLOW_PREFIXES=(
  # Node : tests et outils de la pile (les scripts « npm run <script> » sont traités à part, voir BASH_RUN_PREFIXES)
  "npm test" "pnpm test" "yarn test" "bun test"
  "npm audit" "npm ls" "npm outdated" "pnpm audit" "pnpm ls" "yarn audit"
  "npx prettier" "npx eslint" "npx tsc" "npx vitest" "npx playwright test"
  "npx astro check" "npx astro build" "npx astro sync" "npx next lint" "npx next build" "npx svelte-check" "npx biome check" "npx biome lint"
  "node --test"
  "tsc" "eslint" "prettier"
  # Go
  "go test" "go build" "go vet" "gofmt -l" "go fmt" "go mod tidy" "go mod download" "go list" "govulncheck" "golangci-lint run"
  # Rust
  "cargo test" "cargo build" "cargo check" "cargo clippy" "cargo fmt" "cargo doc" "cargo audit" "cargo tree" "cargo nextest run" "cargo deny check"
  # Python
  "pytest" "python -m pytest" "uv run pytest" "uv run ruff" "uv run mypy" "ruff check" "ruff format" "mypy" "pyright" "pip list" "pip check" "pip-audit"
  # OpenTofu (never apply, destroy or import) and Docker Compose (no `config`: it prints interpolated secrets)
  "tofu fmt" "tofu validate" "tofu plan" "tofu init" "tofu providers" "tofu version"
  "docker compose ps" "docker compose logs" "docker compose ls" "docker compose images"
  # git en lecture (les options dangereuses et « push » sont refusées plus bas)
  "git status" "git log" "git diff" "git show" "git fetch" "git rev-parse" "git ls-files" "git blame"
  # kit : API en lecture seule (chemin exigé) et commandes de diagnostic
  "kit api coolify GET" "kit api cloudflare GET" "kit api github GET"
  "kit detect" "kit doctor" "kit equip search" "kit sync --dry-run" "kit --version"
  # Utilitaires de lecture (find : -exec/-delete/-ok… refusés plus bas)
  "ls" "cat" "head" "tail" "wc" "grep" "rg" "find" "jq" "tree" "du" "df" "which" "file" "stat"
)
# Commandes admises telles quelles, sans argument ni joker.
BASH_ALLOW_EXACT=("git branch --list" "git branch --show-current" "git remote -v" "git stash list")
# Lanceurs de scripts du projet : « <lanceur> <script> », le script étant un nom simple hors BASH_SCRIPT_DENY_RE.
BASH_RUN_PREFIXES=("npm run" "pnpm run" "yarn run" "bun run")
BASH_SCRIPT_RE='^[a-z0-9][a-z0-9:_-]*$'
# Scripts qui déploient, publient, installent ou migrent (sous-chaîne du nom).
BASH_SCRIPT_DENY_RE='deploy|publish|release|install|prepare|pack|version|push|migrate|prod|upload|ship|rollout'

# Options refusées dans n'importe quel mot après le début de commande (exécution, suppression, écriture hors projet,
# déplacement du dépôt git, push…). Comparées mot entier, casse respectée.
BASH_DANGEROUS_OPTS_RE='^(--exec(=.*)?|-exec|-execdir|-ok|-okdir|-delete|--delete(=.*)?|-fprint0?|-fprintf|-fls|--output(=.*)?|--pre(=.*)?|--pre-glob(=.*)?|--config-env(=.*)?|--git-dir(=.*)?|--work-tree(=.*)?|--exec-path(=.*)?|--upload-pack(=.*)?|--receive-pack(=.*)?|--ext-diff|--textconv|--force(=.*)?|--hard|--no-verify|--in-place|push|-D)$'
# Pour git seulement : -c / -C changent la configuration ou le dossier ; un « : » désigne un refspec (écrase des branches).
GIT_DANGEROUS_OPTS_RE='^(-c|-C)$'

# kit api (lecture) : chemin concret commençant par « / », sans mot d'action (Coolify : start/stop/restart sont des GET).
KIT_API_PATH_DANGER_RE='merge|deploy|start|stop|restart|trigger|delete'

# --- Fichiers ---------------------------------------------------------------------------------------------

# Read/Glob/Grep : chemin relatif ancré (au moins un « / »), premier segment fixe, segments fixes ou « * » / « ** » entiers.
FILE_FIRST_SEGMENT_RE='^[A-Za-z0-9_][A-Za-z0-9_-]*$'
FILE_SEGMENT_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]*$'

# --- MCP --------------------------------------------------------------------------------------------------

# Outils MCP de lecture seulement : nom en lecture ET aucun verbe d'écriture n'importe où dans le nom.
MCP_READ_RE='^((get|list|search|read|fetch|query|describe|view)_[a-z0-9_]+|[a-z0-9_]+_(read|get|list|search))$'
MCP_DANGER_RE='delete|remove|destroy|drop|truncate|merge|deploy|publish|release|trigger|push|force|execute|exec|run|shell|sql|migration|apply|write|reset|pause|restore|rebase|revoke|rotate|archive|disable|cancel|kill|stop|restart|create|update|add|set|upload|send'

# --- WebFetch ---------------------------------------------------------------------------------------------

WEBFETCH_HOST_RE='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'

# --- Secrets (toute spécification, tous outils) ----------------------------------------------------------
# « .env.example » est retiré avant le test de « .env ». « secret » couvre aussi « __SECRET:NOM__ ».
SECRET_WORDS=(
  ".env" ".pem" ".key" ".p12" ".pfx" "id_rsa" "id_ed25519" ".ssh" ".gnupg" ".aws" ".kube" ".netrc" ".npmrc"
  ".pgpass" "secret" "keys.txt" "token" "password" "credential"
)

# ---------------------------------------------------------------------------------------------------------

REASON=""
bad() { REASON=$1; }

usage() {
  cat <<'EOF'
usage : kit perms allow "<règle>" --reason "<pourquoi>" [--dir <projet>]
        kit perms list [--dir <projet>]
        kit perms check "<règle>"
Ajoute une règle permissions.allow de la LISTE BLANCHE (lecture, build, test, lint, git en lecture, kit api GET,
outils MCP de lecture) au .claude/settings.json du projet et la journalise dans docs/memory/permissions.md.
Tout le reste (Edit/Write, écritures, déploiement, push, jokers) est refusé : accord de l'utilisateur ou PR.
EOF
}

# fixed_prefix <spec> : partie fixe avant le premier joker.
fixed_prefix() {
  local p=$1
  if [[ $p == *'*'* ]]; then p=${p%%\**}; fi
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

# check_overlap <tool> <spec> <rule> : refuse ce qui recouvre une règle deny/ask du kit (filet en plus de la liste blanche).
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

# secret_words_in <texte> : refuse si le texte (minuscules) mentionne un secret.
secret_words_in() {
  local s w
  s=$(tr 'A-Z' 'a-z' <<<"$1")
  s=${s//.env.example/}
  for w in "${SECRET_WORDS[@]}"; do
    if [[ $s == *"$w"* ]]; then bad "mentionne un secret ou un fichier sensible (« $w »)"; return 1; fi
  done
}

check_mcp() { # rule
  local rule=$1 name
  [[ $rule != *'*'* && $rule != *'('* ]] || { bad "joker ou spécification interdits sur un outil MCP : écris exactement mcp__<serveur>__<outil>"; return 1; }
  [[ $rule =~ ^mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+$ ]] || { bad "format attendu : mcp__<serveur>__<outil> (un seul outil nommé)"; return 1; }
  name=${rule#mcp__*__}
  [[ $name =~ $MCP_READ_RE ]] || { bad "« $name » n'est pas un outil MCP de lecture (get_/list_/search_/read_…) : un outil MCP qui écrit demande l'accord de l'utilisateur ou une PR"; return 1; }
  if [[ $name =~ $MCP_DANGER_RE ]]; then
    bad "le nom « $name » évoque une écriture, une suppression, un déploiement ou une exécution : accord de l'utilisateur ou PR"
    return 1
  fi
  check_overlap mcp "$rule" "$rule"
}

# Read/Glob/Grep : chemin relatif ancré (« src/** », « docs/* », « lib/parser.ts »).
check_file_spec() { # spec
  local spec=$1 segs=() seg i
  [[ -n $spec ]] || { bad "spécification vide"; return 1; }
  [[ $spec == */* ]] || { bad "chemin non ancré : écris un dossier fixe suivi d'un « / » (ex. src/**)"; return 1; }
  [[ $spec != */ && $spec != *//* ]] || { bad "segment de chemin vide"; return 1; }
  IFS=/ read -ra segs <<<"$spec"
  for i in "${!segs[@]}"; do
    seg=${segs[$i]}
    if ((i == 0)); then
      [[ $seg =~ $FILE_FIRST_SEGMENT_RE ]] || { bad "premier segment « $seg » : un nom de dossier fixe (lettres, chiffres, _ -), sans point initial ni joker"; return 1; }
    elif [[ $seg != '*' && $seg != '**' ]] && ! [[ $seg =~ $FILE_SEGMENT_RE ]]; then
      bad "segment « $seg » : un nom fixe (lettres, chiffres, _ . -, sans point initial) ou « * » / « ** » entier"
      return 1
    fi
  done
}

# check_kit_api_path <chemin> : lecture seulement, chemin concret.
check_kit_api_path() {
  local path=$1 lp
  [[ $path == /* ]] || { bad "kit api : le chemin doit commencer par /"; return 1; }
  [[ $path != *..* ]] || { bad "kit api : « .. » interdit dans le chemin"; return 1; }
  [[ ${path#/} =~ [A-Za-z0-9] ]] || { bad "kit api : chemin trop large (/)"; return 1; }
  lp=$(tr 'A-Z' 'a-z' <<<"$path")
  if [[ $lp =~ $KIT_API_PATH_DANGER_RE ]]; then
    bad "kit api : le chemin évoque une action (merge, deploy, start, stop, restart, trigger, delete)"
    return 1
  fi
}

check_bash_spec() { # spec
  local spec=$1 before core c=() p word first i matched=0 exact=0 run=0 script
  [[ -n $spec ]] || { bad "Bash() vide"; return 1; }
  [[ $spec =~ $BASH_SPEC_CHARS_RE ]] || { bad "caractère interdit dans une règle Bash (seuls lettres, chiffres, espace et _ . / : = % , - sont admis ; pas de guillemet, \\, \$, ~, jokers ? [ ] { }, chaînage ou redirection)"; return 1; }
  [[ $spec != ' '* && $spec != *'  '* ]] || { bad "espaces en tête ou doublés"; return 1; }

  # « * » : un seul, dernier caractère, derrière un espace ou un « / ».
  core=$spec
  if [[ $spec == *'*'* ]]; then
    before=${spec%\*}
    [[ $spec == *'*' && $before != *'*'* ]] || { bad "un seul joker « * » est admis, en toute fin de règle"; return 1; }
    [[ -n $before && ( $before == *' ' || $before == */ ) ]] || { bad "le « * » final doit suivre un espace ou un « / » (ex. Bash(npm run test *))"; return 1; }
    core=${before% }
  fi
  [[ -n $core && $core != *' ' ]] || { bad "commande vide"; return 1; }
  read -ra c <<<"$core"
  first=${c[0]}

  # Début de commande : liste blanche.
  for p in "${BASH_ALLOW_EXACT[@]}"; do
    if [[ $core == "$p" ]]; then exact=1; matched=1; fi
  done
  if ((exact)) && [[ $spec == *'*'* ]]; then bad "« $core » est admis sans argument ni joker"; return 1; fi
  if ((!matched)); then
    for p in "${BASH_RUN_PREFIXES[@]}"; do
      if [[ $core == "$p" || $core == "$p "* ]]; then run=1; matched=1; fi
    done
  fi
  if ((run)); then
    script=${c[2]:-}
    [[ $script =~ $BASH_SCRIPT_RE ]] || { bad "« ${c[0]} run » exige un nom de script simple (minuscules, chiffres, : _ -), pas d'option"; return 1; }
    if [[ $script =~ $BASH_SCRIPT_DENY_RE ]]; then bad "script « $script » : déploiement, publication, installation ou migration"; return 1; fi
  fi
  if ((!matched)); then
    for p in "${BASH_ALLOW_PREFIXES[@]}"; do
      if [[ $core == "$p" || $core == "$p "* ]]; then matched=1; break; fi
    done
  fi
  ((matched)) || { bad "commande hors de la liste blanche (BASH_ALLOW_PREFIXES dans scripts/perms.sh) : lecture, build, test, lint, git en lecture, kit api GET"; return 1; }

  # Mots suivants : jamais de chemin absolu ni de « .. », jamais d'option dangereuse.
  for i in "${!c[@]}"; do
    ((i >= 1)) || continue
    word=${c[$i]}
    if [[ $first == kit && ${c[1]} == api && $i -eq 4 ]]; then continue; fi
    if [[ $word == /* || $word == *=/* ]]; then bad "argument sur un chemin absolu (« $word ») : seuls les chemins relatifs au projet sont acceptés"; return 1; fi
    if [[ $word =~ (^|/)\.\.($|/) ]]; then bad "argument avec « .. » (« $word ») : le chemin sort du projet"; return 1; fi
    if [[ $word =~ $BASH_DANGEROUS_OPTS_RE ]]; then bad "option ou mot refusé (« $word »)"; return 1; fi
    if [[ $first == git ]]; then
      if [[ $word =~ $GIT_DANGEROUS_OPTS_RE ]]; then bad "option git globale (« $word ») : change la configuration ou le dossier"; return 1; fi
      if [[ $word == *:* ]]; then bad "git avec « : » (refspec) : peut écraser des branches"; return 1; fi
    fi
    if [[ $first == tree && $word == -o ]]; then bad "tree -o écrit un fichier"; return 1; fi
  done

  # kit api GET : chemin exigé et contrôlé.
  if [[ $first == kit && ${c[1]} == api ]]; then
    [[ -n ${c[4]:-} ]] || { bad "kit api GET : chemin précis exigé (ex. Bash(kit api coolify GET /applications/*))"; return 1; }
    check_kit_api_path "${c[4]}" || return 1
  fi
  secret_words_in "$core" || return 1
  check_overlap Bash "$spec" "Bash($spec)"
}

# validate_rule <règle> : 0 si acceptable ; sinon 1 et $REASON expliqué.
validate_rule() {
  local rule=$1 tool spec host
  REASON=""
  [[ -n $rule ]] || { bad "règle vide"; return 1; }
  ((${#rule} <= 300)) || { bad "règle trop longue"; return 1; }
  if [[ $rule =~ [[:cntrl:]] || $rule == *'`'* ]]; then bad "caractère de contrôle ou accent grave interdits"; return 1; fi
  if [[ $rule == mcp__* ]]; then check_mcp "$rule"; return; fi
  [[ $rule =~ ^([A-Za-z0-9_-]+)(\((.*)\))?$ ]] || { bad "syntaxe attendue : Outil ou Outil(spécification)"; return 1; }
  tool=${BASH_REMATCH[1]}
  spec=${BASH_REMATCH[3]}
  if [[ $tool == Edit || $tool == Write ]]; then
    bad "Edit/Write : les éditions dans le projet sont déjà gérées par le mode de la session ; toute règle Edit/Write demande l'accord de l'utilisateur ou une PR"
    return 1
  fi
  if [[ -z ${BASH_REMATCH[2]} ]]; then
    bad "« $tool » sans spécification : trop large, ou déjà autorisé globalement"
    return 1
  fi
  case $tool in
    Bash) check_bash_spec "$spec" ;;
    Read | Glob | Grep)
      check_file_spec "$spec" || return 1
      secret_words_in "$spec" || return 1
      check_overlap "$tool" "$spec" "$rule"
      ;;
    WebFetch)
      [[ $spec == domain:* ]] || { bad "WebFetch exige domain:<hôte> précis (ex. WebFetch(domain:docs.example.com))"; return 1; }
      host=${spec#domain:}
      [[ $host =~ $WEBFETCH_HOST_RE ]] || { bad "WebFetch : hôte invalide ou joker (« $host »)"; return 1; }
      check_overlap WebFetch "$spec" "$rule"
      ;;
    *) bad "outil non pris en charge ($tool) : Bash, Read, Glob, Grep, WebFetch ou mcp__serveur__outil (lecture)"; return 1 ;;
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
