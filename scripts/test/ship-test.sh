#!/usr/bin/env bash
# Tests of kit ship (scripts/ship.sh) with a fake `kit api`, a fake gh, a fake curl and a fake infra repository, all in
# a temporary directory: no network, no real Coolify, Cloudflare or GitHub call. Summary line read by run.sh.
set -uo pipefail
umask 022
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)
T=$(mktemp -d)
trap '[[ -n ${KEEP:-} ]] || rm -rf "$T"' EXIT
export HOME="$T/home" KIT_HOME=$ROOT KIT_CONFIG="$T/home/.config/claude-kit"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME CLAUDE_CODE_REMOTE
mkdir -p "$HOME" "$KIT_CONFIG"
SHIP="$ROOT/scripts/ship.sh"

pass=0 fail=0
ok_() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ko_() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "${2:0:600}"; }
t() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok_ "$d"; else ko_ "$d" "$OUT"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# --- fakes ---
FAKE="$T/fake" BIN="$T/bin"
export FAKE_LOG="$T/api.log" FAKE_DIR=$FAKE
mkdir -p "$FAKE" "$BIN"
cat >"$BIN/api" <<'EOF'
#!/usr/bin/env bash
# Fake kit api: logs "METHOD path" and the request body, answers from $FAKE_DIR, applies the --jq filter like api.sh.
svc=$1; shift
m=GET
case $1 in GET|POST|PUT|PATCH|DELETE|TRIGGER) m=$1; shift ;; esac
p=$1; shift
filter="" body=""
while (($#)); do case $1 in --jq) filter=$2; shift 2 ;; --json) body=$2; shift 2 ;; *) shift ;; esac; done
[[ $body == @* ]] && body=$(cat "${body#@}")
echo "$svc $m $p" >>"$FAKE_LOG"
[[ -n $body ]] && echo "BODY $(jq -c . <<<"$body")" >>"$FAKE_LOG"
k=$(printf '%s %s' "$m" "$p" | tr -c 'A-Za-z0-9' '_')
echo "HTTP 200 ($m $p)" >&2
f="$FAKE_DIR/$k.json"
[[ -f $f ]] || f=/dev/null
if [[ -f $FAKE_DIR/$k.fail ]]; then echo "HTTP 422" >&2; exit 1; fi
if [[ $f == /dev/null ]]; then echo '{}' | jq -c "$filter"; else jq -c "$filter" "$f"; fi
EOF
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_LOG"
case "$*" in
  *"-X POST"*) echo "https://github.com/example-owner/example-infra/pull/7" | tee "$FAKE_DIR/gh_pr" ;;
  *) [[ -f $FAKE_DIR/gh_pr ]] && cat "$FAKE_DIR/gh_pr"; true ;;
esac
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"$FAKE_LOG"
cat "$FAKE_DIR/http_code" 2>/dev/null || echo 200
EOF
chmod +x "$BIN"/*
export KIT_SHIP_API="$BIN/api" KIT_SHIP_GH="$BIN/gh" KIT_SHIP_CURL="$BIN/curl"
fk() { printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9' '_'; } # fixture key
fixture() { printf '%s\n' "$3" >"$FAKE/$(fk "$1" "$2").json"; }

# --- fake infra repository (bare origin + owner's clone) ---
INFRA_BARE="$T/infra.git" INFRA="$T/infra"
git init -q --bare -b main "$INFRA_BARE"
git init -q -b main "$INFRA"
mkdir -p "$INFRA/infra/cloudflare/dns" "$INFRA/gatus"
printf '%s\n' 'zone_id: "z"' 'records:' '  "@ A":' '    name: "example.org"' '    type: "A"' '' '# trailing comment' >"$INFRA/infra/cloudflare/dns/example.org.yaml"
printf '%s\n' 'policies:' '  "me": {"name": "Me"}' 'applications:' '  "old.example.org":' '    name: "old"' '    policies: ["me"]' >"$INFRA/infra/cloudflare/access.yaml"
printf '%s\n' 'alerting: {}' 'endpoints:' '  - name: "old"' '    url: "https://old.example.org"' '' 'other: 1' >"$INFRA/gatus/config.yaml"
printf '%s\n' '# volumes' >"$INFRA/backups.txt"
git -C "$INFRA" add -A && git -C "$INFRA" commit -qm init && git -C "$INFRA" remote add origin "$INFRA_BARE" && git -C "$INFRA" push -q origin main
infra_sum() { { git -C "$INFRA" status --porcelain; git -C "$INFRA" worktree list; git -C "$INFRA_BARE" for-each-ref; } | cksum; }

write_conf() {
  cat >"$KIT_CONFIG/ship.conf" <<EOF
INFRA_REPO=example-owner/example-infra
INFRA_REPO_DIR=$INFRA
ZONES=example.org
TUNNEL_TARGET=00000000-0000-0000-0000-000000000000.cfargotunnel.com
ACCESS_POLICIES=me
GATUS_GROUP=Sites
GATUS_ALERT=ntfy
BACKUP_FILE=backups.txt
BACKUP_LINE=- {project}
COOLIFY_PROJECT_UUID=projuuid0000000000000001
COOLIFY_GITHUB_APP_UUID=ghappuuid000000000000001
SERVER_main=serveruuid00000000000001
DEFAULT_SERVER=main
BRIDGE_APP_UUID=bridgeuuid00000000000001
EOF
}
mkproj() { # dir name expose domain [volumes]
  local d=$1
  mkdir -p "$d"
  git init -q -b main "$d"
  git -C "$d" remote add origin "git@github.com:acme/$2.git"
  sed 's/^name: .*/name: '"$2"'/' "$ROOT/templates/project/project.yaml" >"$d/project.yaml"
  sed -i.bak -e "s/^expose: .*/expose: $3/" -e "s/^domain: .*/domain: $4/" -e "s|^health_path: .*|health_path: /health|" \
    -e "s/^volumes: .*/volumes: ${5:-no}/" "$d/project.yaml" && rm -f "$d/project.yaml.bak"
  printf 'FROM scratch\nEXPOSE 8080/tcp\n' >"$d/Dockerfile"
  printf '%s\n' '# example' 'API_URL=https://api.example.org' 'export SESSION_KEY=dummy' 'COOLIFY_URL=x' 'PRESENT_ONE=1' >"$d/.env.example"
}
proj_sum() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cksum) | cksum; }
run() { OUT=$(bash "$SHIP" "$@" 2>&1); RC=$?; }
has() { grep -qF -- "$1" <<<"$OUT"; }
logn() { grep -cF -- "$1" "$FAKE_LOG" 2>/dev/null || true; }

P="$T/site"
mkproj "$P" site access site.example.org yes

# ---------------------------------------------------------------------------
section "ship.conf absent"
run plan --dir "$P"
t "plan refusé sans ship.conf" test "$RC" -ne 0
t "message : ship.conf et son modèle" has "docs/ship.conf.example"
run app --dir "$P"
t "app refusé sans ship.conf" test "$RC" -ne 0
t "aucun appel d'API sans ship.conf" test ! -s "$FAKE_LOG"

write_conf
section "kit project get"
OUT=$(bash "$SHIP" project-get --dir "$P"); t "get : expose" has "expose: access"
OUT=$(bash "$SHIP" project-get coolify_uuid --dir "$P"); t "get : coolify_uuid vide par défaut" test -z "$OUT"
OUT=$(bash "$ROOT/scripts/kit.sh" project get health_path --dir "$P"); t "kit project get health_path" test "$OUT" = /health

# ---------------------------------------------------------------------------
section "plan (access, volumes) : rien d'écrit"
s0=$(infra_sum) p0=$(proj_sum "$P")
run plan --dir "$P"
t "plan : code 0" test "$RC" -eq 0
t "plan : DNS ajouté" has "+ DNS : CNAME site.example.org"
t "plan : application Access" has "+ Access : application site.example.org (policies : me)"
t "plan : pas de sonde Gatus derrière Access" has "- Gatus : non"
t "plan : sauvegarde" has "+ Sauvegarde"
t "plan : création Coolify" has "+ création de l'application"
t "plan : première mise en prod signalée" has "Première mise en prod"
t "plan : DEPLOY_ALLOW" has "acme/site=<uuid> dans DEPLOY_ALLOW"
t "plan : aucun appel d'API" test ! -s "$FAKE_LOG"
t "plan : dépôt d'infra intact" test "$(infra_sum)" = "$s0"
t "plan : projet intact" test "$(proj_sum "$P")" = "$p0"

section "infra --dry-run"
run infra --dir "$P" --dry-run
t "dry-run : diff affiché" has '+    name: "site.example.org"'
t "dry-run : dépôt d'infra intact" test "$(infra_sum)" = "$s0"
t "dry-run : aucun gh" test ! -s "$FAKE_LOG"

section "infra (access) : PR, puis idempotence"
run infra --dir "$P"
t "infra : code 0" test "$RC" -eq 0
t "infra : annonce avant le push" has "→ écriture : push de ship/site"
t "infra : PR ouverte par gh api" test "$(logn 'gh api -X POST repos/example-owner/example-infra/pulls')" -eq 1
show() { git -C "$INFRA_BARE" show "ship/site:$1"; }
t "infra : CNAME vers le tunnel" grep -qF 'content: "00000000-0000-0000-0000-000000000000.cfargotunnel.com"' <(show infra/cloudflare/dns/example.org.yaml)
t "infra : entrée DNS dans le bloc records (avant le commentaire de fin)" test "$(show infra/cloudflare/dns/example.org.yaml | tail -1)" = "# trailing comment"
t "infra : application Access" grep -qF '  "site.example.org":' <(show infra/cloudflare/access.yaml)
t "infra : policies de ship.conf" grep -qF 'policies: ["me"]' <(show infra/cloudflare/access.yaml)
t "infra : pas de sonde Gatus en access" test "$(show gatus/config.yaml | grep -c site.example.org)" -eq 0
t "infra : sauvegarde (volumes: yes)" grep -qx -- '- site' <(show backups.txt)
t "infra : clone du propriétaire intact (branche, arbre)" test "$(git -C "$INFRA" status --porcelain | wc -l)" -eq 0 -a "$(git -C "$INFRA" branch --show-current)" = main
t "infra : worktree temporaire retiré" test "$(git -C "$INFRA" worktree list | wc -l)" -eq 1
sha1=$(git -C "$INFRA_BARE" rev-parse ship/site)
echo "https://github.com/example-owner/example-infra/pull/7" >"$FAKE/gh_pr"
: >"$FAKE_LOG"
run infra --dir "$P"
t "infra relancé : aucun nouveau commit" test "$(git -C "$INFRA_BARE" rev-parse ship/site)" = "$sha1"
t "infra relancé : entrées déjà présentes" has "= DNS : site.example.org déjà déclaré"
t "infra relancé : PR existante reprise" has "PR déjà ouverte"
t "infra relancé : aucune PR créée" test "$(logn 'gh api -X POST')" -eq 0
t "infra relancé : une seule entrée DNS" test "$(show infra/cloudflare/dns/example.org.yaml | grep -c 'name: "site.example.org"')" -eq 1
rm -f "$FAKE/gh_pr"

section "infra (public) : DNS et Gatus, pas d'Access"
rm -f "$FAKE/gh_pr"
PU="$T/pub"
mkproj "$PU" pub public pub.example.org no
: >"$FAKE_LOG"
run infra --dir "$PU"
run infra --dir "$PU"
showp() { git -C "$INFRA_BARE" show "ship/pub:$1"; }
t "public : sonde Gatus unique" test "$(showp gatus/config.yaml | grep -c 'url: "https://pub.example.org/health"')" -eq 1
t "public : sonde dans le bloc endpoints" test "$(showp gatus/config.yaml | tail -1)" = "other: 1"
t "public : alerte de ship.conf" grep -qF 'alerts: [{type: ntfy}]' <(showp gatus/config.yaml)
t "public : pas d'application Access" test "$(showp infra/cloudflare/access.yaml | grep -c pub.example.org)" -eq 0
t "public : un seul CNAME" test "$(showp infra/cloudflare/dns/example.org.yaml | grep -c '"pub CNAME"')" -eq 1
t "public : pas de sauvegarde (volumes: no)" test "$(showp backups.txt | grep -c pub)" -eq 0
t "public : une seule PR" test "$(logn 'gh api -X POST')" -eq 1

section "infra (tailnet, none) : rien dans le dépôt d'infra"
TN="$T/tn"
mkproj "$TN" tn tailnet tn.in.example.org no
s1=$(infra_sum); : >"$FAKE_LOG"
run infra --dir "$TN"
t "tailnet : rien à changer" has "Infra : rien à changer"
t "tailnet : ni push ni PR" test "$(infra_sum)" = "$s1" -a ! -s "$FAKE_LOG"
NO="$T/no"
mkproj "$NO" worker none '""' no
run plan --dir "$NO"
t "none : plan sans domaine" has "domaine : aucun"

section "infra : entrées refusées"
BD="$T/bad"
mkproj "$BD" bad public 'evil.example.org"x' no
run plan --dir "$BD"
t "domaine invalide refusé" test "$RC" -ne 0
printf 'TUNNEL_TARGET=$(id)\n' >>"$KIT_CONFIG/ship.conf"
run plan --dir "$P"
t "ship.conf : \$ refusé (jamais exécuté)" has "refusés"
write_conf

# ---------------------------------------------------------------------------
section "app --dry-run"
fixture GET /applications '[]'
: >"$FAKE_LOG"
p0=$(proj_sum "$P")
run app --dir "$P" --dry-run
t "app dry-run : code 0" test "$RC" -eq 0
t "app dry-run : corps affiché, auto-déploiement coupé" has '"is_auto_deploy_enabled": false'
t "app dry-run : aucune écriture d'API" test "$(grep -cE ' (POST|PATCH|PUT|TRIGGER|DELETE) ' "$FAKE_LOG")" -eq 0
t "app dry-run : projet intact" test "$(proj_sum "$P")" = "$p0"

section "app : création, variables, pont"
NEW=newappuuid00000000000001
fixture POST /applications/private-github-app "{\"uuid\":\"$NEW\"}"
fixture GET "/applications/$NEW" '{"settings":{"is_auto_deploy_enabled":false}}'
fixture GET "/applications/$NEW/envs" '[{"key":"PRESENT_ONE","value":"v1"},{"key":"OTHER","value":"v2"}]'
fixture GET /applications/bridgeuuid00000000000001/envs '[{"key":"DEPLOY_ALLOW","value":"acme/other=oldappuuid000000000001","is_preview":false},{"key":"DEPLOY_ALLOW","value":"preview-only","is_preview":true}]'
: >"$FAKE_LOG"
run app --dir "$P"
t "app : code 0" test "$RC" -eq 0
body=$(grep -A1 'POST /applications/private-github-app' "$FAKE_LOG" | sed -n 's/^BODY //p')
jb() { jq -e "$1" <<<"$body" >/dev/null; }
t "app : auto-déploiement coupé, pas de déploiement immédiat" jb '.is_auto_deploy_enabled == false and .instant_deploy == false'
t "app : domaine de project.yaml" jb '.domains == "https://site.example.org"'
t "app : source GitHub App et dépôt" jb '.github_app_uuid == "ghappuuid000000000000001" and .git_repository == "acme/site" and .git_branch == "main"'
t "app : Dockerfile, port EXPOSE, santé" jb '.build_pack == "dockerfile" and .ports_exposes == "8080" and .health_check_path == "/health" and .health_check_enabled'
t "app : serveur et projet de ship.conf" jb '.server_uuid == "serveruuid00000000000001" and .project_uuid == "projuuid0000000000000001"'
t "app : annonce avant la création" has "→ écriture : création de l'application Coolify site"
t "app : coolify_uuid écrit dans project.yaml" grep -qx "coolify_uuid: $NEW" "$P/project.yaml"
t "app : .fs0/bridge.yaml deploy:" grep -qx "deploy: $NEW" "$P/.fs0/bridge.yaml"
t "app : .fs0/bridge.yaml branches:" grep -qx "branches: \[main\]" "$P/.fs0/bridge.yaml"
t "app : variables manquantes nommées" has "API_URL SESSION_KEY"
t "app : variable présente non signalée" bash -c '! grep -q "absentes.*PRESENT_ONE" <<<"$1"' _ "$OUT"
t "app : étape kit secrets proposée" has "kit secrets add API_URL"
t "app : nom réservé COOLIFY_URL signalé" has "COOLIFY_URL est réservée"
t "app : aucune valeur de variable affichée" bash -c '! grep -qE "v1|v2|https://api.example.org|dummy" <<<"$1"' _ "$OUT"
allow=$(grep -A1 'PATCH /applications/bridgeuuid00000000000001/envs' "$FAKE_LOG" | sed -n 's/^BODY //p' | jq -r .value)
t "DEPLOY_ALLOW : entrée ajoutée, existantes gardées" test "$allow" = "acme/other=oldappuuid000000000001,acme/site=$NEW"
t "DEPLOY_ALLOW : valeur jamais affichée" bash -c '! grep -q "acme/other" <<<"$1"' _ "$OUT"
t "DEPLOY_ALLOW : variable de prévisualisation ignorée" bash -c '! grep -q preview-only <<<"$1"' _ "$allow"
t "pont redéployé" test "$(logn 'TRIGGER /deploy?uuid=bridgeuuid00000000000001')" -eq 1
t "app : aucun déploiement de l'application par l'API" test "$(logn "TRIGGER /deploy?uuid=$NEW")" -eq 0
t "app : aucun DELETE" test "$(logn ' DELETE ')" -eq 0

section "app relancé : idempotent"
fixture GET /applications/bridgeuuid00000000000001/envs "[{\"key\":\"DEPLOY_ALLOW\",\"value\":\"acme/other=oldappuuid000000000001, acme/site=$NEW\",\"is_preview\":false}]"
: >"$FAKE_LOG"
run app --dir "$P"
t "relance : pas de nouvelle création" test "$(logn 'POST /applications/private-github-app')" -eq 0
t "relance : réglages remis par PATCH" test "$(logn "PATCH /applications/$NEW")" -eq 1
t "relance : DEPLOY_ALLOW inchangé (pas de doublon)" test "$(logn 'envs' | head -1)" -ge 1 -a "$(logn 'PATCH /applications/bridgeuuid00000000000001/envs')" -eq 0
t "relance : pont non redéployé" test "$(logn 'TRIGGER')" -eq 0
t "relance : une seule ligne deploy:" test "$(grep -c '^deploy:' "$P/.fs0/bridge.yaml")" -eq 1

section "app : DEPLOY_ALLOW absent ou en conflit"
fixture GET /applications/bridgeuuid00000000000001/envs '[]'
: >"$FAKE_LOG"
run app --dir "$P"
t "variable absente : créée par POST" test "$(logn 'POST /applications/bridgeuuid00000000000001/envs')" -eq 1
fixture GET /applications/bridgeuuid00000000000001/envs '[{"key":"DEPLOY_ALLOW","value":"acme/site=someotheruuid0000000001","is_preview":false}]'
: >"$FAKE_LOG"
run app --dir "$P"
t "conflit : refus" test "$RC" -ne 0
t "conflit : rien écrit dans DEPLOY_ALLOW" test "$(logn 'bridgeuuid00000000000001/envs' )" -eq 1 -a "$(logn 'PATCH /applications/bridgeuuid')" -eq 0
t "conflit : uuid existant non affiché" bash -c '! grep -q someotheruuid <<<"$1"' _ "$OUT"

# ---------------------------------------------------------------------------
section "status"
fixture GET "/deployments/applications/$NEW?take=10" '{"count":2,"deployments":[{"status":"failed","created_at":"2026-11-13T10:00:00Z","commit":"aaaaaaaa"},{"status":"finished","created_at":"2026-11-13T12:00:00Z","is_webhook":false,"commit":"bbbbbbbbbbbb"},{"status":"failed","created_at":"2026-11-12T12:00:00Z"}]}'
run status --dir "$P"
t "status : dernier déploiement par created_at" has "finished (2026-11-13T12:00:00Z"
t "status : HTTPS vérifié" has "HTTPS https://site.example.org/health : 200"
t "status : code 0 si terminé et HTTPS ok" test "$RC" -eq 0
echo 502 >"$FAKE/http_code"
run status --dir "$P"
t "status : code non nul si HTTPS en échec" test "$RC" -ne 0
rm -f "$FAKE/http_code"
run status --dir "$TN"
t "status : refusé sans coolify_uuid" test "$RC" -ne 0

echo
echo "ship: $pass passed, $fail failed"
((fail == 0))
