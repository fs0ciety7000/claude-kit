#!/usr/bin/env bash
# kit ship : put a project online from its project.yaml (expose, domain, server, coolify_uuid, health_path, volumes).
#
#   kit ship plan   [--dir D]             what the infra PR and the Coolify / bridge changes would be; writes nothing
#   kit ship infra  [--dir D] [--dry-run] branch ship/<name> + PR in the infra repo: DNS (public, access), Access
#                                         application (access), Gatus probe (public), backup entry (volumes: yes)
#   kit ship app    [--dir D] [--dry-run] Coolify application (GitHub App source, auto-deploy off, domain, health
#                                         path), env var NAMES checked against .env.example, .fs0/bridge.yaml deploy:,
#                                         owner/repo=uuid added to the bridge's DEPLOY_ALLOW
#   kit ship status [--dir D] [--wait S]  last deployment and HTTPS answer of the domain (--wait: poll up to S seconds)
#   kit project get [key] [--dir D]       read the project.yaml fields used here (defaults applied)
#
# Machine-local settings (identifiers of the infra, never in a repository): ~/.config/claude-kit/ship.conf, see
# docs/ship.conf.example. Every write is announced on one line before it runs. tofu is never run: the owner applies.
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=lib.sh
source "$(dirname "$SELF")/lib.sh"

usage() { sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'; }

# Test seams: the commands used for the Coolify API, GitHub and HTTPS checks.
API=${KIT_SHIP_API:-$KIT_HOME/scripts/api.sh}
GH=${KIT_SHIP_GH:-gh}
CURL=${KIT_SHIP_CURL:-curl}
CONF="$KIT_CONFIG/ship.conf"
RESERVED_RE='^COOLIFY_(URL|FQDN|BRANCH|RESOURCE_UUID|CONTAINER_NAME)$'

DIR=$PWD DRY=0 WAIT=0
TMPS=()
cleanup() { local t; for t in "${TMPS[@]+"${TMPS[@]}"}"; do rm -rf "$t"; done; }
trap cleanup EXIT
tmpd() { local d; d=$(mktemp -d); TMPS+=("$d"); echo "$d"; }
announce() { echo "→ écriture : $*"; } # target, effect, rollback (global rule: one line before every write)

# ---------- flat key: value files (project.yaml, .fs0/bridge.yaml) ----------
kv_get() { # file key -> value ("" when absent)
  [[ -f $1 ]] || return 0
  awk -v k="$2" 'index($0, k ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' "$1"
}
kv_set() { # file key value : replaces the key's line, else appends it
  local f=$1 tmp
  [[ ! -L $f ]] || die "$f est un lien symbolique : refusé"
  [[ -f $f ]] || : >"$f"
  tmp=$(mktemp)
  KEY=$2 VAL=$3 awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; done = 0 }
    index($0, k ":") == 1 { if (!done) print k ": " v; done = 1; next }
    { print }
    END { if (!done) print k ": " v }
  ' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}

# project.yaml field with its default; "", "-" and "TODO" mean unset.
pget() { # key
  local v
  v=$(kv_get "$DIR/project.yaml" "$1")
  case $v in -|TODO|'""') v="" ;; esac
  if [[ -z $v ]]; then
    case $1 in
      expose) v=none ;;
      health_path) v=/ ;;
      volumes) v=no ;;
      branch) v=main ;;
    esac
  fi
  printf '%s\n' "$v"
}
SHIP_KEYS="name expose domain server coolify_uuid health_path volumes"

project_get() {
  local key=""
  while (($#)); do
    case $1 in
      --dir) DIR=${2:?"dossier manquant"}; shift ;;
      -*) die "option inconnue : $1" ;;
      *) key=$1 ;;
    esac
    shift
  done
  [[ -f $DIR/project.yaml ]] || die "project.yaml absent dans $DIR"
  if [[ -n $key ]]; then pget "$key"; return; fi
  local k
  for k in $SHIP_KEYS; do printf '%s: %s\n' "$k" "$(pget "$k")"; done
}

# ---------- project ----------
P_NAME="" P_EXPOSE="" P_DOMAIN="" P_SERVER="" P_UUID="" P_HEALTH="" P_VOLUMES="" P_REPO="" P_BRANCH=""
load_project() {
  [[ -f $DIR/project.yaml ]] || die "project.yaml absent dans $DIR (kit project init)"
  [[ ! -L $DIR/project.yaml ]] || die "project.yaml est un lien symbolique : refusé"
  P_NAME=$(pget name) P_EXPOSE=$(pget expose) P_DOMAIN=$(pget domain) P_SERVER=$(pget server)
  P_UUID=$(pget coolify_uuid) P_HEALTH=$(pget health_path) P_VOLUMES=$(pget volumes) P_BRANCH=$(pget branch)
  [[ $P_NAME =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "project.yaml : name invalide ou absent (minuscules, chiffres, tirets)"
  [[ $P_EXPOSE =~ ^(none|tailnet|access|public)$ ]] || die "project.yaml : expose doit valoir none, tailnet, access ou public"
  [[ $P_VOLUMES =~ ^(yes|no)$ ]] || die "project.yaml : volumes doit valoir yes ou no"
  [[ $P_HEALTH =~ ^/[A-Za-z0-9._~/-]*$ ]] || die "project.yaml : health_path invalide (ex. /health)"
  [[ $P_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "project.yaml : branch invalide"
  [[ -z $P_UUID || $P_UUID =~ ^[a-z0-9]{8,40}$ ]] || die "project.yaml : coolify_uuid invalide"
  [[ -z $P_SERVER || $P_SERVER =~ ^[A-Za-z0-9_]{1,40}$ ]] || die "project.yaml : server invalide (lettres, chiffres, _)"
  if [[ $P_EXPOSE != none ]]; then
    [[ -n $P_DOMAIN ]] || die "project.yaml : domain requis avec expose: $P_EXPOSE"
  fi
  if [[ -n $P_DOMAIN ]]; then
    [[ ${#P_DOMAIN} -le 253 && $P_DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
      || die "project.yaml : domain invalide (nom DNS en minuscules, sans https://)"
  fi
  P_REPO=$(pget repo)
  if [[ -z $P_REPO ]]; then
    local url
    url=$(git -C "$DIR" remote get-url origin 2>/dev/null || true)
    url=${url%.git}
    if [[ $url =~ github\.com[:/]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then P_REPO=${BASH_REMATCH[1]}; fi
  fi
}
need_repo() { [[ $P_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "dépôt GitHub introuvable (remote origin, ou repo: owner/nom dans project.yaml)"; }

# ---------- machine-local configuration (KEY=value lines, never sourced) ----------
load_conf() {
  [[ -f $CONF ]] || die "configuration absente : $CONF (modèle : docs/ship.conf.example du kit ; identifiants propres à ce poste, jamais dans un dépôt)"
  [[ ! -L $CONF ]] || die "$CONF est un lien symbolique : refusé"
  local line k v n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^([A-Za-z][A-Za-z0-9_]*)=(.*)$ ]] || die "ship.conf ligne $n : KEY=valeur attendu"
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    v=${v%"${v##*[![:space:]]}"}
    if [[ $v == \"*\" || $v == \'*\' ]]; then v=${v:1:${#v}-2}; fi
    [[ $v != *[\"\\\`\$]* ]] || die "ship.conf ligne $n : caractères \" \\ \` \$ refusés"
    printf -v "SC_$k" '%s' "$v"
  done <"$CONF"
}
conf() { local v="SC_$1"; printf '%s' "${!v:-${2:-}}"; }
conf_req() { # key regex
  local v
  v=$(conf "$1")
  [[ -n $v ]] || die "ship.conf : $1 manquant (voir docs/ship.conf.example)"
  [[ $v =~ $2 ]] || die "ship.conf : $1 au format inattendu"
  printf '%s' "$v"
}
UUID_RE='^[a-z0-9]{8,40}$'
RELPATH_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

# ---------- infra repository edits (YAML as text, idempotent) ----------
# Inserts the lines of a snippet file at the end of the block of a top-level key (after its last content line).
block_append() { # file topkey snippet
  local tmp
  tmp=$(mktemp)
  awk -v key="$2:" -v snip="$3" '
    { line[NR] = $0 }
    END {
      start = 0
      for (i = 1; i <= NR; i++) if (line[i] == key || index(line[i], key " ") == 1) { start = i; break }
      if (!start) exit 3
      last = start
      for (i = start + 1; i <= NR; i++) {
        if (line[i] ~ /^[^ \t#-]/) break
        if (line[i] !~ /^[ \t]*$/ && line[i] !~ /^#/) last = i
      }
      for (i = 1; i <= NR; i++) {
        print line[i]
        if (i == last) while ((getline s < snip) > 0) print s
      }
    }' "$1" >"$tmp" || { rm -f "$tmp"; die "${1##*/} : clé de premier niveau « $2: » introuvable"; }
  cat "$tmp" >"$1"
  rm -f "$tmp"
}

zone_of() { # domain -> longest configured zone that contains it
  local z best="" zones
  zones=$(conf ZONES)
  if [[ -z $zones && -d $INFRA_SRC/$DNS_DIR ]]; then
    zones=$(cd "$INFRA_SRC/$DNS_DIR" && ls -- *.yaml 2>/dev/null | sed 's/\.yaml$//' | tr '\n' ' ')
  fi
  for z in $zones; do
    if [[ $1 == "$z" || $1 == *".$z" ]] && ((${#z} > ${#best})); then best=$z; fi
  done
  printf '%s' "$best"
}

# Each step prints "+ ..." (added), "= ..." (already there) or "- ..." (not applicable). CHANGES counts additions.
CHANGES=0 SUMMARY=()
step_dns() { # root
  local root=$1 zone f sub key snip
  zone=$(zone_of "$P_DOMAIN")
  [[ -n $zone ]] || die "aucune zone de ship.conf (ZONES) ne contient $P_DOMAIN"
  f="$root/$DNS_DIR/$zone.yaml"
  [[ -f $f ]] || die "fichier de zone absent : $DNS_DIR/$zone.yaml"
  if grep -qF "name: \"$P_DOMAIN\"" "$f"; then echo "  = DNS : $P_DOMAIN déjà déclaré ($DNS_DIR/$zone.yaml)"; return; fi
  if [[ $P_DOMAIN == "$zone" ]]; then sub="@"; else sub=${P_DOMAIN%".$zone"}; fi
  key="$sub CNAME"
  if grep -qF "\"$key\":" "$f"; then die "$DNS_DIR/$zone.yaml : la clé « $key » existe avec un autre nom : à régler à la main"; fi
  snip=$(mktemp)
  printf '  "%s":\n    name: "%s"\n    type: "CNAME"\n    content: "%s"\n    proxied: true\n    ttl: 1\n    comment: "%s (kit ship, %s)"\n' \
    "$key" "$P_DOMAIN" "$TUNNEL" "$P_NAME" "$P_EXPOSE" >"$snip"
  block_append "$f" records "$snip"
  rm -f "$snip"
  echo "  + DNS : CNAME $P_DOMAIN vers le tunnel, proxifié ($DNS_DIR/$zone.yaml)"
  CHANGES=$((CHANGES + 1)) SUMMARY+=("DNS")
}
step_access() {
  local f="$1/$ACCESS_FILE" snip pol="" p
  [[ -f $f ]] || die "fichier Access absent : $ACCESS_FILE"
  if grep -qF "  \"$P_DOMAIN\":" "$f"; then echo "  = Access : application $P_DOMAIN déjà déclarée"; return; fi
  for p in ${POLICIES//,/ }; do pol+="${pol:+, }\"$p\""; done
  snip=$(mktemp)
  printf '  "%s":\n    name: "%s"\n    session_duration: "24h"\n    app_launcher_visible: false\n    auto_redirect_to_identity: false\n    http_only_cookie_attribute: true\n    enable_binding_cookie: false\n    options_preflight_bypass: false\n    policies: [%s]\n' \
    "$P_DOMAIN" "$P_NAME" "$pol" >"$snip"
  block_append "$f" applications "$snip"
  rm -f "$snip"
  echo "  + Access : application $P_DOMAIN (policies : ${POLICIES//,/ })"
  CHANGES=$((CHANGES + 1)) SUMMARY+=("Access")
}
step_gatus() {
  local f="$1/$GATUS_FILE" snip alert url="https://$P_DOMAIN${P_HEALTH%/}"
  [[ $P_HEALTH == / ]] && url="https://$P_DOMAIN"
  [[ -f $f ]] || die "fichier Gatus absent : $GATUS_FILE"
  if grep -qF "url: \"https://$P_DOMAIN" "$f"; then echo "  = Gatus : sonde de $P_DOMAIN déjà déclarée"; return; fi
  alert=$(conf GATUS_ALERT)
  snip=$(mktemp)
  {
    printf '  - name: "%s"\n    group: "%s"\n    url: "%s"\n    interval: 2m\n' "$P_NAME" "$(conf GATUS_GROUP Sites)" "$url"
    printf '    conditions: ["[CONNECTED] == true", "[STATUS] < 400", "[RESPONSE_TIME] < 5000"]\n'
    [[ -z $alert ]] || printf '    alerts: [{type: %s}]\n' "$alert"
  } >"$snip"
  block_append "$f" endpoints "$snip"
  rm -f "$snip"
  echo "  + Gatus : sonde $url"
  CHANGES=$((CHANGES + 1)) SUMMARY+=("Gatus")
}
step_backup() {
  local file line
  file=$(conf BACKUP_FILE)
  if [[ -z $file ]]; then echo "  - Sauvegarde : BACKUP_FILE vide dans ship.conf (volumes couverts par la sauvegarde de l'hôte)"; return; fi
  line=$(conf BACKUP_LINE '- {project}')
  line=${line//\{project\}/$P_NAME}
  line=${line//\{server\}/$P_SERVER}
  line=${line//\{domain\}/$P_DOMAIN}
  [[ -f $1/$file ]] || die "fichier de sauvegarde absent : $file"
  if grep -qxF -- "$line" "$1/$file"; then echo "  = Sauvegarde : entrée déjà présente ($file)"; return; fi
  printf '%s\n' "$line" >>"$1/$file"
  echo "  + Sauvegarde : entrée ajoutée ($file)"
  CHANGES=$((CHANGES + 1)) SUMMARY+=("sauvegarde")
}
infra_steps() { # root
  case $P_EXPOSE in
    public) step_dns "$1"; echo "  - Access : non (expose public)"; step_gatus "$1" ;;
    access) step_dns "$1"; step_access "$1"; echo "  - Gatus : non (Access répond à la place de l'origine)" ;;
    tailnet) echo "  - DNS, Access, Gatus : non (expose tailnet : nom du tailnet, aucun enregistrement public)" ;;
    none) echo "  - DNS, Access, Gatus : non (expose none)" ;;
  esac
  if [[ $P_VOLUMES == yes ]]; then step_backup "$1"; else echo "  - Sauvegarde : non (volumes: no)"; fi
}
infra_files() { # relative paths an expose mode may touch
  local f b
  if [[ $P_EXPOSE == public || $P_EXPOSE == access ]]; then
    for f in $(conf ZONES); do echo "$DNS_DIR/$f.yaml"; done
    if [[ -z $(conf ZONES) ]]; then git -C "$INFRA_DIR" ls-tree --name-only "$1" "$DNS_DIR/" 2>/dev/null || true; fi
  fi
  [[ $P_EXPOSE == access ]] && echo "$ACCESS_FILE"
  [[ $P_EXPOSE == public ]] && echo "$GATUS_FILE"
  b=$(conf BACKUP_FILE)
  if [[ $P_VOLUMES == yes && -n $b ]]; then echo "$b"; fi
  return 0
}

INFRA_DIR="" INFRA_REPO="" INFRA_BASE="" DNS_DIR="" ACCESS_FILE="" GATUS_FILE="" TUNNEL="" POLICIES="" INFRA_SRC=""
load_infra_conf() {
  INFRA_DIR=$(conf_req INFRA_REPO_DIR '^/')
  INFRA_REPO=$(conf_req INFRA_REPO '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
  INFRA_BASE=$(conf INFRA_BASE main)
  DNS_DIR=$(conf DNS_DIR infra/cloudflare/dns)
  ACCESS_FILE=$(conf ACCESS_FILE infra/cloudflare/access.yaml)
  GATUS_FILE=$(conf GATUS_FILE gatus/config.yaml)
  POLICIES=$(conf ACCESS_POLICIES)
  local p
  for p in DNS_DIR ACCESS_FILE GATUS_FILE; do [[ ${!p} =~ $RELPATH_RE && ${!p} != *..* ]] || die "ship.conf : $p doit être un chemin relatif au dépôt d'infra"; done
  [[ -z $(conf BACKUP_FILE) || ( $(conf BACKUP_FILE) =~ $RELPATH_RE && $(conf BACKUP_FILE) != *..* ) ]] || die "ship.conf : BACKUP_FILE doit être un chemin relatif"
  [[ $INFRA_BASE =~ ^[A-Za-z0-9._/-]+$ ]] || die "ship.conf : INFRA_BASE invalide"
  if [[ $P_EXPOSE == public || $P_EXPOSE == access ]]; then
    TUNNEL=$(conf_req TUNNEL_TARGET '^[a-z0-9.-]+$')
  fi
  if [[ $P_EXPOSE == access ]]; then
    POLICIES=$(conf_req ACCESS_POLICIES '^[a-z0-9_]+([ ,]+[a-z0-9_]+)*$')
  fi
  [[ -d $INFRA_DIR/.git || -f $INFRA_DIR/.git ]] || die "INFRA_REPO_DIR n'est pas un clone git : $INFRA_DIR"
}
infra_needed() { [[ $P_EXPOSE == public || $P_EXPOSE == access || $P_VOLUMES == yes ]]; }

# Copies the files an edit may touch, from a git ref, into a scratch tree (plan and --dry-run never touch the clone).
scratch_tree() { # ref -> dir
  local ref=$1 d f
  d=$(tmpd)
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    mkdir -p "$d/$(dirname "$f")"
    git -C "$INFRA_DIR" show "$ref:$f" >"$d/$f" 2>/dev/null || rm -f "$d/$f"
  done < <(infra_files "$ref")
  echo "$d"
}
infra_ref() { # branch ship/<name> on origin if it exists, else the base branch
  if git -C "$INFRA_DIR" rev-parse -q --verify "refs/remotes/origin/ship/$P_NAME" >/dev/null; then echo "origin/ship/$P_NAME"
  else echo "origin/$INFRA_BASE"; fi
}

ship_infra() { # mode: plan | dry | real
  local mode=$1 ref root wt branch="ship/$P_NAME" pr title body
  if ! infra_needed; then echo "Infra : rien à changer"; infra_steps /nonexistent; return 0; fi
  load_infra_conf
  echo "Infra : branche $branch sur $INFRA_REPO"
  if [[ $mode == real ]]; then
    need gh "Installe GitHub CLI (gh)."
    git -C "$INFRA_DIR" fetch -q origin || die "git fetch du dépôt d'infra en échec"
  fi
  ref=$(infra_ref)
  [[ $mode == real ]] || echo "  (d'après $ref du clone local, sans git fetch)"
  git -C "$INFRA_DIR" rev-parse -q --verify "$ref^{commit}" >/dev/null || die "référence $ref absente dans $INFRA_DIR (git fetch)"
  if [[ $mode != real ]]; then
    root=$(scratch_tree "$ref")
    INFRA_SRC=$root
    local before
    before=$(tmpd)
    cp -R "$root/." "$before/"
    infra_steps "$root"
    if [[ $mode == dry ]] && ((CHANGES)); then (cd "$before" && diff -ru . "$root" | sed 's/^/    /') || true; fi
    if ((CHANGES)); then echo "  PR à ouvrir : « ship: $P_NAME » ($branch -> $INFRA_BASE), puis tofu plan et apply par le propriétaire"
    else echo "  aucune modification de fichier"; fi
    return 0
  fi
  # Real run: a detached disposable worktree, so the owner's clone (branches, working tree) is left alone.
  wt="$(tmpd)/wt"
  git -C "$INFRA_DIR" worktree add -q --detach "$wt" "$ref" >/dev/null 2>&1 || die "git worktree add en échec dans $INFRA_DIR"
  # shellcheck disable=SC2064
  trap "git -C '$INFRA_DIR' worktree remove --force '$wt' >/dev/null 2>&1 || true; cleanup" EXIT
  INFRA_SRC=$wt
  infra_steps "$wt"
  if ((CHANGES)); then
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "ship($P_NAME): $(IFS=,; echo "${SUMMARY[*]}" | sed 's/,/, /g')" \
      -m "Opened by kit ship for $P_REPO (expose: $P_EXPOSE). Apply with tofu after review." \
      || die "commit en échec dans le dépôt d'infra"
    announce "push de $branch sur $INFRA_REPO (effet : branche de PR ; retour arrière : fermer la PR, supprimer la branche)"
    git -C "$wt" push -q origin "HEAD:refs/heads/$branch" || die "push en échec"
  fi
  if [[ $ref == "origin/$INFRA_BASE" ]] && ((CHANGES == 0)); then
    echo "  aucune modification : pas de PR"
    return 0
  fi
  pr=$("$GH" api "repos/$INFRA_REPO/pulls?head=${INFRA_REPO%%/*}:$branch&state=open" --jq '.[0].html_url // empty') || die "lecture des PR en échec (gh)"
  if [[ -n $pr ]]; then
    ok "PR déjà ouverte : $pr"
  else
    title="ship: $P_NAME ($P_EXPOSE)"
    body=$(printf 'Opened by `kit ship infra` for `%s` (expose: `%s`).\n\nChanges: %s.\n\nThe owner reviews, merges, then runs `tofu plan` and `tofu apply`.' \
      "$P_NAME" "$P_EXPOSE" "$(IFS=,; echo "${SUMMARY[*]:-see commits}")")
    announce "PR « $title » sur $INFRA_REPO (effet : revue ; retour arrière : fermer la PR)"
    pr=$("$GH" api -X POST "repos/$INFRA_REPO/pulls" -f title="$title" -f head="$branch" -f base="$INFRA_BASE" -f body="$body" --jq .html_url) \
      || die "création de la PR en échec (gh)"
    ok "PR ouverte : $pr"
  fi
  echo "  Propriétaire : fusionner, puis tofu plan et tofu apply ; /ship attend sa confirmation."
}

# ---------- Coolify application ----------
build_pack() { # -> "pack port"
  local port pack
  port=$(pget port)
  if [[ -f $DIR/compose.yaml || -f $DIR/docker-compose.yml || -f $DIR/docker-compose.yaml ]] && [[ ! -f $DIR/Dockerfile ]]; then
    die "projet Docker Compose : pas encore géré par kit ship (créer l'application à la main, voir le skill deploy-coolify-cloudflare)"
  fi
  if [[ -f $DIR/Dockerfile ]]; then
    pack=dockerfile
    [[ -n $port ]] || port=$(awk 'toupper($1) == "EXPOSE" { sub(/\/.*/, "", $2); print $2; exit }' "$DIR/Dockerfile")
    [[ -n $port ]] || port=80
  elif [[ $(pget stack) == static ]]; then
    pack=static port=${port:-80}
  else
    pack=nixpacks port=${port:-3000}
    warn "pas de Dockerfile : build Nixpacks (un Dockerfile explicite est plus prévisible)"
  fi
  [[ $port =~ ^[0-9]{2,5}$ ]] || die "port invalide ($port) : port: <n> dans project.yaml"
  echo "$pack $port"
}

expected_env_names() { # names declared in the project's example env file (values never read into the output)
  local f="$DIR/.env.example"
  [[ -f $f ]] || return 0
  sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$f" | sort -u
}

api() { "$API" coolify "$@"; }
SERVER_UUID="" CPROJ="" CENV="" GHAPP=""
load_app_conf() {
  local s=${P_SERVER:-$(conf DEFAULT_SERVER)}
  [[ -n $s ]] || die "serveur inconnu : server: <nom> dans project.yaml ou DEFAULT_SERVER dans ship.conf"
  [[ $s =~ ^[A-Za-z0-9_]{1,40}$ ]] || die "ship.conf : DEFAULT_SERVER invalide"
  P_SERVER=$s
  SERVER_UUID=$(conf_req "SERVER_$s" "$UUID_RE")
  CPROJ=$(conf_req COOLIFY_PROJECT_UUID "$UUID_RE")
  GHAPP=$(conf_req COOLIFY_GITHUB_APP_UUID "$UUID_RE")
  CENV=$(conf COOLIFY_ENVIRONMENT production)
  [[ $CENV =~ ^[A-Za-z0-9_-]+$ ]] || die "ship.conf : COOLIFY_ENVIRONMENT invalide"
}

app_payload() { # pack port -> JSON of the creation request
  local domains=""
  [[ -n $P_DOMAIN ]] && domains="https://$P_DOMAIN"
  jq -n --arg p "$CPROJ" --arg s "$SERVER_UUID" --arg e "$CENV" --arg g "$GHAPP" --arg r "$P_REPO" \
    --arg b "$P_BRANCH" --arg bp "$1" --arg port "$2" --arg n "$P_NAME" --arg d "$domains" --arg h "$P_HEALTH" '
    {project_uuid: $p, server_uuid: $s, environment_name: $e, github_app_uuid: $g, git_repository: $r,
     git_branch: $b, build_pack: $bp, ports_exposes: $port, name: $n,
     description: "kit ship", instant_deploy: false, is_auto_deploy_enabled: false,
     health_check_enabled: true, health_check_path: $h}
    + (if $d == "" then {} else {domains: $d} end)
    + (if $bp == "static" then {is_static: true} else {} end)'
}
settings_payload() { # JSON of the PATCH that keeps an existing application in line
  local domains=""
  [[ -n $P_DOMAIN ]] && domains="https://$P_DOMAIN"
  jq -n --arg d "$domains" --arg h "$P_HEALTH" '{is_auto_deploy_enabled: false, health_check_enabled: true, health_check_path: $h}
    + (if $d == "" then {} else {domains: $d} end)'
}
jsonfile() { # stdin -> private temporary file (request bodies are passed by file, never in argv)
  local f
  f="$(tmpd)/body.json"
  (umask 077 && cat >"$f")
  echo "$f"
}

ship_app() { # mode: plan | dry | real
  local mode=$1 bp port uuid=$P_UUID found body created=0 bpp dom=${P_DOMAIN:+https://$P_DOMAIN}
  need_repo
  load_app_conf
  bpp=$(build_pack)
  bp=${bpp% *} port=${bpp#* }
  echo "Coolify : application $P_NAME depuis $P_REPO@$P_BRANCH (GitHub App), build $bp, port $port"
  echo "  domaine : ${dom:-aucun (expose none)} ; santé : $P_HEALTH ; auto-déploiement Coolify coupé (le pont déploie)"
  if [[ -z $uuid && $mode != plan ]]; then
    found=$(api /applications --jq "map(select(.name == \"$P_NAME\")) | map(.uuid) | join(\" \")" | jq -r .) \
      || die "lecture des applications Coolify en échec"
    if [[ $found == *" "* ]]; then die "plusieurs applications Coolify nommées $P_NAME : coolify_uuid à fixer dans project.yaml"; fi
    if [[ -n $found ]]; then
      [[ $found =~ $UUID_RE ]] || die "uuid Coolify inattendu"
      uuid=$found
      info "application existante reprise (même nom)"
    fi
  fi
  if [[ -z $uuid ]]; then
    case $mode in
      plan) echo "  + création de l'application (POST /applications/private-github-app)" ;;
      dry) echo "  + création (POST /applications/private-github-app), corps :"; app_payload "$bp" "$port" | jq . | sed 's/^/    /' ;;
      real)
        body=$(app_payload "$bp" "$port" | jsonfile)
        announce "création de l'application Coolify $P_NAME (auto-déploiement coupé ; retour arrière : supprimer l'application dans l'interface)"
        uuid=$(api POST /applications/private-github-app --json "@$body" --jq '.uuid // empty' | jq -r .) || die "création refusée par Coolify (voir le message ci-dessus)"
        [[ $uuid =~ $UUID_RE ]] || die "réponse Coolify sans uuid"
        created=1
        ok "application créée : $uuid"
        ;;
    esac
  else
    case $mode in
      plan) echo "  = application existante ($uuid) : domaine, santé et auto-déploiement remis en ligne avec project.yaml" ;;
      dry) echo "  ~ PATCH /applications/$uuid, corps :"; settings_payload | jq . | sed 's/^/    /' ;;
      real)
        body=$(settings_payload | jsonfile)
        announce "réglages de l'application $uuid (domaine, santé, auto-déploiement coupé ; retour arrière : PATCH des anciennes valeurs)"
        api PATCH "/applications/$uuid" --json "@$body" --jq '{uuid: (.uuid // null)}' >/dev/null || die "mise à jour refusée par Coolify"
        ;;
    esac
  fi
  if [[ $mode == real && -n $uuid && $uuid != "$P_UUID" ]]; then
    announce "coolify_uuid dans project.yaml (retour arrière : git checkout project.yaml)"
    kv_set "$DIR/project.yaml" coolify_uuid "$uuid"
  fi
  if ((created)); then
    local auto
    auto=$(api "/applications/$uuid" --jq '.settings.is_auto_deploy_enabled // false' 2>/dev/null || echo unknown)
    [[ $auto == false ]] || warn "auto-déploiement encore actif sur l'application : coupe-le dans l'interface (Advanced > Auto Deploy)"
  fi
  check_env_names "$mode" "${uuid:-<uuid>}"
  bridge_file "$mode" "${uuid:-<uuid>}"
  bridge_allow "$mode" "${uuid:-<uuid>}"
  if [[ $mode == real ]]; then
    echo "Suite : commite .fs0/bridge.yaml et project.yaml sur $P_BRANCH (PR) : après la CI verte, le pont déploie."
    echo "  Rien à pousser : kit api coolify TRIGGER \"/deploy?uuid=$uuid\" --jq '.' (première mise en ligne seulement)."
  fi
}

check_env_names() { # mode uuid
  local mode=$1 uuid=$2 expected present missing="" n name
  expected=$(expected_env_names)
  if [[ -z $expected ]]; then echo "  variables : aucune déclarée dans .env.example"; return 0; fi
  n=$(wc -l <<<"$expected" | tr -d ' ')
  while IFS= read -r name; do
    [[ $name =~ $RESERVED_RE ]] && warn "$name est réservée par Coolify (injectée, elle écrase la tienne) : renomme-la (ex. ${name/COOLIFY_/APP_})"
  done <<<"$expected"
  present=""
  if [[ $mode == plan ]]; then
    echo "  variables : $n noms attendus (.env.example), comparés à Coolify par kit ship app : $(grep -vE "$RESERVED_RE" <<<"$expected" | tr '\n' ' ')"
    return 0
  fi
  if [[ $uuid != "<uuid>" ]]; then
    present=$(api "/applications/$uuid/envs" --jq 'map(.key) | unique | .[]' | jq -r .) \
      || die "lecture des noms de variables en échec"
  fi
  while IFS= read -r name; do
    [[ $name =~ $RESERVED_RE ]] && continue
    grep -qxF -- "$name" <<<"$present" || missing+="$name "
  done <<<"$expected"
  if [[ -z $missing ]]; then ok "variables : les $n noms de .env.example sont présents dans Coolify"; return 0; fi
  if [[ $uuid == "<uuid>" ]]; then echo "  variables à créer dans Coolify après l'application (noms seulement) : $missing"
  else echo "  variables absentes de Coolify (noms seulement) : $missing"; fi
  for name in $missing; do
    echo "    $name : kit secrets add $name, puis kit api coolify POST /applications/$uuid/envs --json '{\"key\":\"$name\",\"value\":\"__SECRET:${name}__\",\"is_preview\":false,\"is_literal\":true}' --jq '{uuid}'"
  done
}

bridge_file() { # mode uuid : deploy: and branches: in .fs0/bridge.yaml, other keys kept
  local mode=$1 uuid=$2 f="$DIR/.fs0/bridge.yaml" cur
  [[ ! -L $DIR/.fs0 && ! -L $f ]] || die ".fs0/bridge.yaml est un lien symbolique : refusé"
  cur=$(kv_get "$f" deploy)
  if [[ $cur == "$uuid" && -n $(kv_get "$f" branches) ]]; then echo "  = .fs0/bridge.yaml : deploy: $uuid"; return 0; fi
  if [[ -n $cur && $cur != "$uuid" && $uuid != "<uuid>" ]]; then warn ".fs0/bridge.yaml visait $cur : remplacé par $uuid"; fi
  if [[ $mode != real ]]; then echo "  + .fs0/bridge.yaml : deploy: $uuid, branches: [$P_BRANCH]"; return 0; fi
  announce ".fs0/bridge.yaml (deploy: $uuid ; retour arrière : git checkout .fs0/bridge.yaml)"
  mkdir -p "$DIR/.fs0"
  if [[ ! -f $f ]]; then
    printf '%s\n' '# fs0-bridge: per-repository settings (keys and rules in the bridge README).' 'enabled: true' >"$f"
  fi
  kv_set "$f" deploy "$uuid"
  [[ -n $(kv_get "$f" branches) ]] || kv_set "$f" branches "[$P_BRANCH]"
  ok ".fs0/bridge.yaml : deploy: $uuid"
}

# DEPLOY_ALLOW of the bridge application: owner/repo=uuid added, existing entries kept, value never printed.
bridge_allow() { # mode uuid
  local mode=$1 uuid=$2 bridge cur new entry e found=0 body method
  bridge=$(conf BRIDGE_APP_UUID)
  if [[ -z $bridge ]]; then warn "BRIDGE_APP_UUID absent de ship.conf : DEPLOY_ALLOW non modifié"; return 0; fi
  [[ $bridge =~ $UUID_RE ]] || die "ship.conf : BRIDGE_APP_UUID au format inattendu"
  entry="$P_REPO=$uuid"
  if [[ $mode == plan || $uuid == "<uuid>" ]]; then echo "  + pont : $P_REPO=$uuid dans DEPLOY_ALLOW (entrées existantes gardées), puis redéploiement du pont"; return 0; fi
  # The filter returns the value as a JSON string (null when the variable is absent); it stays in this process.
  cur=$(api "/applications/$bridge/envs" --jq '[.[] | select(.key == "DEPLOY_ALLOW" and (.is_preview | not)) | .value][0]') \
    || die "lecture de DEPLOY_ALLOW du pont en échec"
  if [[ $cur == null || -z $cur ]]; then method=POST cur=""; else method=PATCH cur=$(jq -r '. // ""' <<<"$cur"); fi
  new=""
  local parts=()
  IFS=, read -r -a parts <<<"$cur"
  for e in "${parts[@]+"${parts[@]}"}"; do
    e=${e//[[:space:]]/}
    [[ -n $e ]] || continue
    if [[ ${e%%=*} == "$P_REPO" ]]; then
      [[ ${e#*=} == "$uuid" ]] || die "DEPLOY_ALLOW autorise déjà $P_REPO vers une autre application : à régler à la main (rien n'a été modifié)"
      found=1
    fi
    new+="${new:+,}$e"
  done
  if ((found)); then echo "  = pont : $P_REPO déjà autorisé dans DEPLOY_ALLOW"; return 0; fi
  new+="${new:+,}$entry"
  if [[ $mode == dry ]]; then echo "  + pont : $entry ajouté à DEPLOY_ALLOW ($method /applications/$bridge/envs), puis redéploiement du pont"; return 0; fi
  body=$(V=$new jq -n '{key: "DEPLOY_ALLOW", value: env.V, is_preview: false, is_literal: true}' | jsonfile)
  announce "DEPLOY_ALLOW du pont : ajout de $entry (retour arrière : retirer l'entrée, redéployer le pont)"
  api "$method" "/applications/$bridge/envs" --json "@$body" --jq '{uuid: (.uuid // null)}' >/dev/null || die "écriture de DEPLOY_ALLOW refusée"
  announce "redéploiement du pont pour charger DEPLOY_ALLOW (retour arrière : redéployer après correction)"
  api TRIGGER "/deploy?uuid=$bridge" --jq '{deployments: ((.deployments // []) | length)}' >/dev/null || die "redéploiement du pont en échec"
  ok "pont : $entry autorisé, redéploiement lancé"
}

# ---------- status ----------
https_code() { "$CURL" -sS -o /dev/null --max-time 15 -w '%{http_code}' "$1" 2>/dev/null || echo 000; }
ship_status() {
  [[ -n $P_UUID ]] || die "coolify_uuid absent de project.yaml : kit ship app d'abord"
  local dep st code url="" end=$((SECONDS + WAIT)) rc
  [[ -n $P_DOMAIN ]] && url="https://$P_DOMAIN${P_HEALTH}"
  while :; do
    dep=$(api "/deployments/applications/$P_UUID?take=10" \
      --jq '(if type == "object" then .deployments else . end) | sort_by(.created_at) | last // {} | {status: (.status // "aucun"), created_at, is_webhook, commit: ((.commit // "") | .[0:7])}' 2>/dev/null) \
      || die "lecture des déploiements en échec"
    st=$(jq -r .status <<<"$dep")
    code=""
    [[ -z $url ]] || code=$(https_code "$url")
    rc=1
    if [[ $st == finished && ( -z $url || $code =~ ^[23] ) ]]; then rc=0; fi
    if ((rc == 0)) || [[ $st == failed || $st == cancelled* ]] || ((SECONDS >= end)); then break; fi
    sleep 15
  done
  echo "Déploiement : $(jq -r '"\(.status) (\(.created_at // "-"), \(if .is_webhook then "webhook" else "API ou pont" end), \(.commit))"' <<<"$dep")"
  if [[ -n $url ]]; then
    case $code in
      2*) ok "HTTPS $url : $code" ;;
      3*) ok "HTTPS $url : $code (redirection ; derrière Access, c'est la page de connexion)" ;;
      *) echo "✗ HTTPS $url : $code" ;;
    esac
  fi
  return "$rc"
}

# ---------- entry point ----------
main() {
  local sub=${1:-help}
  shift || true
  case $sub in
    help|-h|--help) usage; return 0 ;;
    project-get) project_get "$@"; return ;;
    plan|infra|app|status) ;;
    *) usage >&2; exit 1 ;;
  esac
  while (($#)); do
    case $1 in
      --dir) DIR=${2:?"dossier manquant"}; shift ;;
      --dry-run) DRY=1 ;;
      --wait) WAIT=${2:?"durée manquante (secondes)"}; shift; [[ $WAIT =~ ^[0-9]+$ ]] || die "--wait : secondes" ;;
      *) die "option inconnue : $1" ;;
    esac
    shift
  done
  [[ -d $DIR ]] || die "dossier introuvable : $DIR"
  DIR=$(cd "$DIR" && pwd)
  need jq
  load_project
  local mode=real
  ((DRY)) && mode=dry
  case $sub in
    status) ship_status ;;
    plan)
      load_conf
      echo "kit ship plan : $P_NAME (expose $P_EXPOSE${P_DOMAIN:+, $P_DOMAIN}, serveur ${P_SERVER:-$(conf DEFAULT_SERVER)})"
      if [[ -z $P_UUID ]]; then echo "Première mise en prod : validation du propriétaire avant toute écriture."; fi
      ship_infra plan
      ship_app plan
      echo "Rien n'a été écrit."
      ;;
    infra) load_conf; ship_infra "$mode"; ((DRY)) && echo "Rien n'a été écrit (--dry-run)." ;;
    app) load_conf; ship_app "$mode"; ((DRY)) && echo "Rien n'a été écrit (--dry-run)." ;;
  esac
  return 0
}
main "$@"
