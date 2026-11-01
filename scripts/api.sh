#!/usr/bin/env bash
# kit api : appels HTTP authentifiés vers Coolify / Cloudflare.
# Le jeton est injecté par `kit secrets run` puis passé à curl par stdin (curl -K -) :
# il n'apparaît jamais dans les arguments d'un processus (donc pas dans `ps`).
#
# Usage : kit api <coolify|cloudflare> [METHODE] <chemin> --jq <filtre> [--json <JSON|@fichier>]
#   METHODE : GET (défaut, lecture) | POST | PUT | PATCH | DELETE | TRIGGER
#   TRIGGER = GET qui déclenche une action (Coolify : /deploy, /start, /stop, /restart)
#   --json  : corps de la requête. "__SECRET:NOM__" est remplacé par la valeur du secret NOM
#             chiffré (la valeur ne passe ni par la ligne de commande ni par le chat).
# Exemples :
#   kit api coolify /applications --jq 'map({uuid,name,status})'
#   kit api cloudflare POST /zones/ID/dns_records --json '{"type":"CNAME",...}' --jq '.result.id'
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=lib.sh
source "$(dirname "$SELF")/lib.sh"

usage() { sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'; }

# Chemins GET qui exécutent une action côté serveur : réservés à TRIGGER.
ACTION_RE='/(deploy|start|stop|restart|validate|cancel)(/|\?|$)'

# --- mode interne : exécuté DANS `kit secrets run`, les variables sont déjà présentes ---
if [[ ${1:-} == --inner ]]; then
  shift
  svc=$1 method=$2 path=$3 filter=$4 body=$5
  case $svc in
    coolify)
      : "${COOLIFY_BASE_URL:?COOLIFY_BASE_URL manquant (kit secrets add COOLIFY_BASE_URL -g)}"
      : "${COOLIFY_ACCESS_TOKEN:?COOLIFY_ACCESS_TOKEN manquant (kit secrets add COOLIFY_ACCESS_TOKEN -g)}"
      base="${COOLIFY_BASE_URL%/}/api/v1"
      token=$COOLIFY_ACCESS_TOKEN
      ;;
    cloudflare)
      : "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN manquant (kit secrets add CLOUDFLARE_API_TOKEN -g)}"
      base="https://api.cloudflare.com/client/v4"
      token=$CLOUDFLARE_API_TOKEN
      path=${path//\{account_id\}/${CLOUDFLARE_ACCOUNT_ID:-}}
      ;;
  esac
  # Une valeur avec guillemet, antislash ou saut de ligne casserait la config curl.
  if [[ $token == *[\"\\]* || $token == *$'\n'* ]]; then
    echo "jeton au format inattendu" >&2
    exit 1
  fi
  [[ $method == TRIGGER ]] && http=GET || http=$method

  tmpdir=${XDG_RUNTIME_DIR:-/dev/shm}
  [[ -d $tmpdir && -w $tmpdir ]] || tmpdir=${TMPDIR:-/tmp}
  out=$(mktemp -p "$tmpdir")
  bodyfile=""
  trap 'rm -f "$out" "$bodyfile"' EXIT

  data_line=""
  if [[ -n $body ]]; then
    bodyfile=$(mktemp -p "$tmpdir")
    # Remplace __SECRET:NOM__ par la valeur du secret chargé ; erreur (nom seulement) s'il manque.
    jq -c 'walk(if type=="string" then
             gsub("__SECRET:(?<n>[A-Za-z0-9_]+)__"; ($ENV[.n] // error("secret absent : " + .n)))
           else . end)' <<<"$body" >"$bodyfile" || { echo "corps JSON invalide ou secret absent" >&2; exit 1; }
    data_line="data = \"@${bodyfile}\""$'\n''header = "Content-Type: application/json"'$'\n'
  fi

  # printf est un builtin : le jeton ne passe dans aucun argv.
  code=$(printf 'request = "%s"\nheader = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n%surl = "%s%s"\n' \
    "$http" "$token" "$data_line" "$base" "$path" |
    curl -sS --max-time 60 -K - -o "$out" -w '%{http_code}') || {
    echo "échec réseau" >&2
    exit 1
  }
  echo "HTTP $code ($method $path)" >&2
  if ! jq -e . "$out" >/dev/null 2>&1; then
    echo "réponse non JSON (${code})" >&2
    [[ $code =~ ^2 ]] || exit 1
    exit 0
  fi
  jq -r 'if type=="array" then "éléments : \(length)"
         elif type=="object" and ((.result|type)=="array") then "éléments : \(.result|length)"
         else empty end' "$out" >&2
  # Messages d'erreur de l'API (Cloudflare : .errors[].message ; Coolify : .message), jamais le corps entier.
  jq -r 'if type=="object" then
           ([(.errors // [])[]? | .message? // empty] + [.message? // empty])
           | map(select(type=="string" and length>0)) | unique
           | select(length>0) | "message : " + join("; ")
         else empty end' "$out" >&2 || true
  jq -c "$filter" "$out"
  [[ $code =~ ^2 ]] || exit 1
  exit 0
fi

# --- mode public ---
svc=${1:-}
[[ $svc == coolify || $svc == cloudflare ]] || { usage >&2; exit 1; }
shift
method=GET
case ${1:-} in
  GET | POST | PUT | PATCH | DELETE | TRIGGER) method=$1; shift ;;
esac
path=${1:-}
[[ $path == /* ]] || die "le chemin doit commencer par / (ex. /applications)"
[[ $path != *[[:space:]\"\\]* ]] || die "chemin invalide"
shift
filter=""
body=""
while (($#)); do
  case $1 in
    --jq) filter=${2:-}; shift 2 ;;
    --json) body=${2:-}; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done

# La réponse brute peut contenir des secrets (variables d'environnement des applications) : filtre obligatoire.
[[ -n $filter ]] || die "--jq <filtre> obligatoire : ne garde que les champs utiles (jamais la réponse brute)"
[[ $filter != *env* && $filter != *token* && $filter != *secret* ]] || die "filtre refusé : il vise des champs sensibles"

if [[ $method == GET && $path =~ $ACTION_RE ]]; then
  die "ce chemin déclenche une action : utilise « kit api $svc TRIGGER $path »"
fi
if [[ $method == GET && -n $body ]]; then die "GET n'accepte pas --json"; fi
if [[ $method == DELETE && -n $body ]]; then die "DELETE n'accepte pas --json"; fi

if [[ $body == @* ]]; then
  f=${body#@}
  [[ -f $f && ! -L $f ]] || die "fichier JSON introuvable : $f"
  (($(stat -c %s "$f") <= 1048576)) || die "fichier JSON trop gros (> 1 Mo)"
  body=$(<"$f")
fi

need jq
need curl
if [[ -n $body ]]; then jq -e . <<<"$body" >/dev/null 2>&1 || die "--json : JSON invalide"; fi

exec "$KIT_HOME/scripts/secrets.sh" run -g -- "$SELF" --inner "$svc" "$method" "$path" "$filter" "$body"
