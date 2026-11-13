#!/usr/bin/env bash
# Tests of kit retire (scripts/retire.sh) with the fakes of ship-test.sh (kit api, gh, curl, infra repository) in a
# temporary directory: no network, no real Coolify, Cloudflare or GitHub call. Entries are written by the real kit ship
# first, so "identical to what kit ship writes" is checked against kit ship itself. Summary line read by run.sh.
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
SHIP="$ROOT/scripts/ship.sh" RETIRE="$ROOT/scripts/retire.sh"

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
if [[ ($m == POST || $m == PATCH) && $p == */envs && -n $body ]]; then
  g="$FAKE_DIR/$(printf 'GET %s' "$p" | tr -c 'A-Za-z0-9' '_').json"
  [[ -f $g ]] || echo '[]' >"$g"
  if [[ -f $FAKE_DIR/envs_lossy ]]; then body=$(jq -c '.value = (.value | split(",") | last)' <<<"$body"); fi
  jq -c --argjson b "$body" '[.[] | select(.key != $b.key or .is_preview == true)] + [$b + {is_preview: false}]' "$g" >"$g.tmp" && mv "$g.tmp" "$g"
fi
# With $FAKE_DIR/patch_applies, a PATCH of an application's preview settings is kept by the fake Coolify.
if [[ $m == PATCH && $p == /applications/* && $p != */envs && -f $FAKE_DIR/patch_applies ]]; then
  g="$FAKE_DIR/$(printf 'GET %s' "$p" | tr -c 'A-Za-z0-9' '_').json"
  [[ -f $g ]] && jq -c --argjson b "$body" '.settings = ((.settings // {}) + ($b | with_entries(select(.key | startswith("is_pr")))))' "$g" >"$g.tmp" && mv "$g.tmp" "$g"
fi
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
TAILNET_SUFFIX=in.example.org
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
rrun() { OUT=$(bash "$RETIRE" "$@" 2>&1); RC=$?; }
writes() { grep -cE ' (POST|PATCH|PUT|TRIGGER|DELETE) |^gh api -X' "$FAKE_LOG" 2>/dev/null || true; }
merge_ship() { # name : the owner merges the kit ship PR
  git -C "$INFRA" fetch -q origin && git -C "$INFRA" merge -q --ff-only "origin/ship/$1" && git -C "$INFRA" push -q origin main
}
B=bridgeuuid00000000000001
allow_fixture() { fixture GET "/applications/$B/envs" "[{\"key\":\"DEPLOY_ALLOW\",\"value\":\"$1\",\"is_preview\":false},{\"key\":\"DEPLOY_ALLOW\",\"value\":\"preview-only\",\"is_preview\":true}]"; }
allow_written() { grep -A1 "PATCH /applications/$B/envs" "$FAKE_LOG" | sed -n 's/^BODY //p' | jq -r .value; }

write_conf
# Online first, by the real kit ship: an Access site with a volume, and a public site with a Gatus probe.
S=siteuuid0000000000000001 U=pubuuid00000000000000001
P="$T/site" PU="$T/pub"
mkproj "$P" site access site.example.org yes
mkproj "$PU" pub public pub.example.org no
for x in "$P:$S" "$PU:$U"; do
  d=${x%%:*} u=${x#*:}
  sed -i.bak "s/^coolify_uuid: .*/coolify_uuid: $u/" "$d/project.yaml" && rm -f "$d/project.yaml.bak"
  mkdir -p "$d/.fs0"
  printf '%s\n' '# fs0-bridge' 'enabled: true' "deploy: $u" 'branches: [main]' >"$d/.fs0/bridge.yaml"
  printf '%s\n' '# DEPLOY.md' >"$d/DEPLOY.md"
  git -C "$d" add -A && git -C "$d" commit -qm init
done
run infra --dir "$P"; merge_ship site; rm -f "$FAKE/gh_pr"
run infra --dir "$PU"; merge_ship pub; rm -f "$FAKE/gh_pr"
t "préparation : entrées écrites par kit ship et fusionnées" grep -qF '"site.example.org":' "$INFRA/infra/cloudflare/access.yaml"
fixture GET "/applications/$S" '{"git_repository":"https://github.com/Acme/site.git","status":"running:healthy"}'
fixture GET "/applications/$U" '{"git_repository":"acme/pub","status":"running:healthy"}'
allow_fixture "acme/other=oldappuuid000000000001, Acme/Site=$S,acme/third=thirduuid00000000000001"
: >"$FAKE_LOG"

# ---------------------------------------------------------------------------
section "aide et entrées"
rrun help
t "help : plan et run" has "kit retire run"
rrun stop --dir "$P"
t "sous-commande inconnue refusée" test "$RC" -ne 0

section "plan : rien d'écrit"
s0=$(infra_sum) p0=$(proj_sum "$P")
rrun plan --dir "$P"
t "plan : code 0" test "$RC" -eq 0
t "plan : arrêt annoncé" has "arrêt de l'application (TRIGGER /applications/$S/stop"
t "plan : retrait de DEPLOY_ALLOW annoncé" has "acme/site retiré de DEPLOY_ALLOW"
t "plan : deploy: annoncé" has "deploy: retiré"
t "plan : DNS, Access, sauvegarde retirés" bash -c 'grep -q "DNS : entrée de kit ship retirée" <<<"$1" && grep -q "Access : entrée de kit ship retirée" <<<"$1" && grep -q "Sauvegarde : entrée de kit ship retirée" <<<"$1"' _ "$OUT"
t "plan : expose none annoncé" has "expose: none"
t "plan : lectures seulement" test "$(grep -cvE '^coolify GET ' "$FAKE_LOG")" -eq 0
t "plan : dépôt d'infra intact" test "$(infra_sum)" = "$s0"
t "plan : projet intact" test "$(proj_sum "$P")" = "$p0"
t "plan : DEPLOY_ALLOW jamais affiché" bash -c '! grep -qE "acme/other|acme/third|preview-only" <<<"$1"' _ "$OUT"

section "propriété : application d'un autre dépôt"
fixture GET "/applications/$S" '{"git_repository":"someone/else","status":"running:healthy"}'
: >"$FAKE_LOG"
rrun run --dir "$P"
t "autre dépôt : refus" test "$RC" -ne 0
t "autre dépôt : message" has "n'est pas construite depuis"
t "autre dépôt : aucune écriture (API, gh)" test "$(writes)" -eq 0
t "autre dépôt : dépôt d'infra et projet intacts" test "$(infra_sum)" = "$s0" -a "$(proj_sum "$P")" = "$p0"
fixture GET "/applications/$S" '{"git_repository":"https://github.com/Acme/site.git","status":"running:healthy"}'

section "run --dry-run"
: >"$FAKE_LOG"
rrun run --dir "$P" --dry-run
t "dry-run : code 0" test "$RC" -eq 0
t "dry-run : diff affiché" has '-    name: "site.example.org"'
t "dry-run : aucune écriture" test "$(writes)" -eq 0
t "dry-run : dépôt d'infra et projet intacts" test "$(infra_sum)" = "$s0" -a "$(proj_sum "$P")" = "$p0"
t "dry-run : verrou non pris" test ! -e "$KIT_CONFIG/ship-deploy-allow.lock"

section "vérification de DEPLOY_ALLOW en échec : arrêt"
touch "$FAKE/envs_lossy"
: >"$FAKE_LOG"
rrun run --dir "$P"
rm -f "$FAKE/envs_lossy"
t "écriture qui perd une entrée : refus" has "vérification de DEPLOY_ALLOW en échec"
t "écriture qui perd une entrée : code non nul" test "$RC" -ne 0
t "écriture qui perd une entrée : pont non redéployé" test "$(logn "TRIGGER /deploy")" -eq 0
t "écriture qui perd une entrée : ni PR ni deploy: retiré" test "$(logn 'gh api -X POST')" -eq 0 -a "$(grep -c '^deploy:' "$P/.fs0/bridge.yaml")" -eq 1
t "verrou retiré après l'échec" test ! -e "$KIT_CONFIG/ship-deploy-allow.lock"
allow_fixture "acme/other=oldappuuid000000000001, Acme/Site=$S,acme/third=thirduuid00000000000001"

section "verrou"
mkdir "$KIT_CONFIG/ship-deploy-allow.lock"
: >"$FAKE_LOG"
rrun run --dir "$P"
t "verrou présent : refus" has "modifie DEPLOY_ALLOW"
t "verrou présent : aucune écriture" test "$(writes)" -eq 0
t "verrou d'un autre run laissé en place" test -d "$KIT_CONFIG/ship-deploy-allow.lock"
rmdir "$KIT_CONFIG/ship-deploy-allow.lock"

section "run (access, volumes)"
: >"$FAKE_LOG"
rrun run --dir "$P"
t "run : code 0" test "$RC" -eq 0
t "run : application arrêtée par TRIGGER …/stop (GET Coolify)" test "$(logn "coolify TRIGGER /applications/$S/stop")" -eq 1 -a "$(logn "POST /applications/$S/stop")" -eq 0
t "run : annonce avant l'arrêt" has "→ écriture : arrêt de l'application Coolify $S"
t "DEPLOY_ALLOW : entrée retirée, autres gardées" test "$(allow_written)" = "acme/other=oldappuuid000000000001,acme/third=thirduuid00000000000001"
t "DEPLOY_ALLOW : valeur jamais affichée" bash -c '! grep -qE "acme/other|acme/third|preview-only" <<<"$1"' _ "$OUT"
t "pont redéployé une fois" test "$(logn "TRIGGER /deploy?uuid=$B")" -eq 1
t "aucun déploiement de l'application, aucun DELETE" test "$(logn "uuid=$S")" -eq 0 -a "$(logn ' DELETE ')" -eq 0
t ".fs0/bridge.yaml : deploy: retiré, reste gardé" test "$(cat "$P/.fs0/bridge.yaml")" = "$(printf '# fs0-bridge\nenabled: true\nbranches: [main]')"
t "project.yaml : expose: none" grep -qx 'expose: none' "$P/project.yaml"
t "project.yaml : coolify_uuid gardé" grep -qx "coolify_uuid: $S" "$P/project.yaml"
t "DEPLOY.md : note de retrait" grep -qF '<!-- kit retire -->' "$P/DEPLOY.md"
t "state.md : note de retrait" grep -qF "tofu apply" "$P/docs/memory/state.md"
showr() { git -C "$INFRA_BARE" show "retire/site:$1"; }
t "infra : PR ouverte une fois" test "$(logn 'gh api -X POST repos/example-owner/example-infra/pulls')" -eq 1
t "infra : CNAME retiré" test "$(showr infra/cloudflare/dns/example.org.yaml | grep -c site.example.org)" -eq 0
t "infra : autres enregistrements gardés" test "$(showr infra/cloudflare/dns/example.org.yaml | grep -c 'pub.example.org\|"@ A"')" -eq 2
t "infra : application Access retirée, l'autre gardée" test "$(showr infra/cloudflare/access.yaml | grep -c site.example.org)" -eq 0 -a "$(showr infra/cloudflare/access.yaml | grep -c old.example.org)" -eq 1
t "infra : ligne de sauvegarde retirée" test "$(showr backups.txt)" = "# volumes"
t "infra : commentaire de fin gardé" test "$(showr infra/cloudflare/dns/example.org.yaml | tail -1)" = "# trailing comment"
t "infra : clone du propriétaire intact" test "$(git -C "$INFRA" status --porcelain | wc -l)" -eq 0 -a "$(git -C "$INFRA" worktree list | wc -l)" -eq 1
t "étapes du propriétaire : tofu apply" has "tofu apply"
t "étapes du propriétaire : suppression dans l'interface" has "supprimer l'application Coolify dans l'interface"
t "étapes du propriétaire : archivage" has "archiver le dépôt GitHub"

section "run relancé : idempotent"
fixture GET "/applications/$S" '{"git_repository":"acme/site","status":"exited:unhealthy"}'
sha=$(git -C "$INFRA_BARE" rev-parse retire/site)
p1=$(proj_sum "$P")
: >"$FAKE_LOG"
rrun run --dir "$P"
t "relance : code 0" test "$RC" -eq 0
t "relance : application déjà arrêtée" has "application déjà arrêtée"
t "relance : aucune écriture d'API" test "$(grep -cE ' (POST|PATCH|PUT|TRIGGER|DELETE) ' "$FAKE_LOG")" -eq 0
t "relance : aucun nouveau commit, aucune PR" test "$(git -C "$INFRA_BARE" rev-parse retire/site)" = "$sha" -a "$(logn 'gh api -X POST')" -eq 0
t "relance : PR existante reprise" has "PR déjà ouverte"
t "relance : projet inchangé" test "$(proj_sum "$P")" = "$p1"
rm -f "$FAKE/gh_pr"

section "entrées modifiées à la main : gardées et signalées"
sed -i.bak '/url: "https:\/\/pub.example.org\/health"/{n;s/interval: 2m/interval: 5m/;}' "$INFRA/gatus/config.yaml" && rm -f "$INFRA/gatus/config.yaml.bak"
git -C "$INFRA" commit -qam "hand edit" && git -C "$INFRA" push -q origin main
allow_fixture "acme/pub=$U"
: >"$FAKE_LOG"
rrun run --dir "$PU"
showp() { git -C "$INFRA_BARE" show "retire/pub:$1"; }
t "public : code 0" test "$RC" -eq 0
t "public : CNAME identique retiré" test "$(showp infra/cloudflare/dns/example.org.yaml | grep -c pub.example.org)" -eq 0
t "public : sonde modifiée gardée" test "$(showp gatus/config.yaml | grep -c 'pub.example.org')" -eq 1
t "public : sonde modifiée signalée" has "À régler à la main"
t "public : autres sondes gardées" test "$(showp gatus/config.yaml | grep -c old.example.org)" -eq 1
t "public : DEPLOY_ALLOW vidé de sa seule entrée" test "$(allow_written)" = ""

section "prévisualisations : coupées et relues avant l'arrêt"
V=pvuuid000000000000000001
PV="$T/pv"
mkproj "$PV" pv access pv.example.org no
sed -i.bak -e "s/^coolify_uuid: .*/coolify_uuid: $V/" -e "s/^previews: .*/previews: true/" "$PV/project.yaml" && rm -f "$PV/project.yaml.bak"
fixture GET "/applications/$V" '{"git_repository":"acme/pv","status":"running:healthy","settings":{"is_preview_deployments_enabled":true,"is_pr_deployments_public_enabled":false}}'
allow_fixture "acme/pv=$V"
: >"$FAKE_LOG"
rrun run --dir "$PV" --dry-run
t "dry-run : coupure annoncée" has "- prévisualisations des PR coupées"
t "dry-run : aucune écriture" test "$(writes)" -eq 0
rrun run --dir "$PV"
t "relecture encore active : erreur" bash -c '[[ $1 -ne 0 ]] && grep -q "pas gardé le réglage" <<<"$2"' _ "$RC" "$OUT"
t "relecture encore active : application non arrêtée" test "$(logn "TRIGGER /applications/$V/stop")" -eq 0
touch "$FAKE/patch_applies"
: >"$FAKE_LOG"
rrun run --dir "$PV"
rm -f "$FAKE/patch_applies"
t "run : code 0" test "$RC" -eq 0
t "run : PATCH previews off" bash -c 'grep -A1 "PATCH /applications/$2\$" "$1" | sed -n "s/^BODY //p" | jq -e ".is_preview_deployments_enabled == false and .is_pr_deployments_public_enabled == false" >/dev/null' _ "$FAKE_LOG" "$V"
t "run : coupure avant l'arrêt" test "$(grep -n "PATCH /applications/$V\$" "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n "TRIGGER /applications/$V/stop" "$FAKE_LOG" | cut -d: -f1)"
t "run : previews: false dans project.yaml" grep -qx 'previews: false' "$PV/project.yaml"
: >"$FAKE_LOG"
rrun run --dir "$PV"
t "relance : déjà coupées, pas de PATCH" bash -c 'grep -q "déjà coupées" <<<"$1" && ! grep -q "PATCH /applications/$2\$" "$3"' _ "$OUT" "$V" "$FAKE_LOG"

section "sans coolify_uuid ni domaine"
NO="$T/no"
mkproj "$NO" worker none '""' no
: >"$FAKE_LOG"
allow_fixture "acme/other=oldappuuid000000000001"
rrun run --dir "$NO"
t "none : code 0" test "$RC" -eq 0
t "none : aucune application à arrêter" has "aucune application à arrêter"
t "none : aucune écriture d'API" test "$(grep -cE ' (POST|PATCH|PUT|TRIGGER|DELETE) ' "$FAKE_LOG")" -eq 0

echo
echo "retire: $pass passed, $fail failed"
((fail == 0))
