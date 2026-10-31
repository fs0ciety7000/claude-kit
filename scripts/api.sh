#!/usr/bin/env bash
# kit api : appels HTTP GET authentifiés vers Coolify / Cloudflare.
# Le jeton est injecté par `kit secrets run` puis passé à curl par stdin (curl -K -) :
# il n'apparaît jamais dans les arguments d'un processus (donc pas dans `ps`).
#
# Usage : kit api <coolify|cloudflare> <chemin> --jq <filtre> [--no-global]
#   kit api coolify /applications --jq 'map({uuid,name,status,fqdn})'
#   kit api cloudflare /accounts/{account_id}/tokens/verify --jq '.result.status'
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=lib.sh
source "$(dirname "$SELF")/lib.sh"

usage() { sed -n '2,9p' "$SELF" | sed 's/^# \{0,1\}//'; }

# --- mode interne : exécuté DANS `kit secrets run`, les variables sont déjà présentes ---
if [[ ${1:-} == --inner ]]; then
  shift
  svc=$1 path=$2 filter=$3
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
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  # printf est un builtin : le jeton ne passe dans aucun argv.
  code=$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\nurl = "%s%s"\n' \
    "$token" "$base" "$path" |
    curl -sS --max-time 30 -X GET -K - -o "$tmp" -w '%{http_code}') || {
    echo "échec réseau" >&2
    exit 1
  }
  echo "HTTP $code" >&2
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    echo "réponse non JSON (${code})" >&2
    exit 1
  fi
  jq -r 'if type=="array" then "éléments : \(length)" else empty end' "$tmp" >&2
  jq -c "$filter" "$tmp"
  [[ $code =~ ^2 ]] || exit 1
  exit 0
fi

# --- mode public ---
svc=${1:-}
path=${2:-}
[[ $svc == coolify || $svc == cloudflare ]] || { usage >&2; exit 1; }
[[ $path == /* ]] || die "le chemin doit commencer par / (ex. /applications)"
[[ $path != *[[:space:]\"\\]* ]] || die "chemin invalide"
shift 2
filter=""
while (($#)); do
  case $1 in
    --jq) filter=${2:-}; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done
# La réponse brute peut contenir des secrets (variables d'environnement des applications) : filtre obligatoire.
[[ -n $filter ]] || die "--jq <filtre> obligatoire : ne garde que les champs utiles (jamais la réponse brute)"
[[ $filter != *env* && $filter != *token* && $filter != *secret* ]] || die "filtre refusé : il vise des champs sensibles"
need jq
need curl
exec "$KIT_HOME/scripts/secrets.sh" run -g -- "$SELF" --inner "$svc" "$path" "$filter"
