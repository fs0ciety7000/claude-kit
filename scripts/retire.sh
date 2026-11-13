#!/usr/bin/env bash
# kit retire : take a project put online by kit ship offline, without deleting anything.
#
#   kit retire plan [--dir D]             what would be stopped, removed or edited; writes nothing
#   kit retire run  [--dir D] [--dry-run] switch PR previews off (read back), stop the Coolify application (owned check),
#                                         remove owner/repo from the bridge's DEPLOY_ALLOW, remove deploy: from
#                                         .fs0/bridge.yaml, open a PR in the infra repo removing the entries kit ship
#                                         wrote (DNS, Access, Gatus, backup line), set expose: none (coolify_uuid kept),
#                                         note the retirement in DEPLOY.md and docs/memory/state.md
#
# Entries of the infra repo that differ from what kit ship writes are kept and listed for the owner. Deleting the Coolify
# application, tofu apply and archiving the GitHub repository stay with the owner. Settings: ~/.config/claude-kit/ship.conf.
set -euo pipefail
RSELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck disable=SC2034 # read by ship.sh: helpers only, no entry point
KIT_SHIP_SOURCED=1
# shellcheck source-path=SCRIPTDIR source=ship.sh
source "$(dirname "$RSELF")/ship.sh"

usage() { sed -n '2,13p' "$RSELF" | sed 's/^# \{0,1\}//'; }

REMOVED=() MANUAL=() PR_URL=""

# ---------- Coolify application ----------
APP_STATUS=""
retire_app_check() { # read-only: ownership and current status
  if [[ -z $P_UUID ]]; then echo "Coolify : coolify_uuid vide dans project.yaml : aucune application à arrêter"; return 0; fi
  app_owned "$P_UUID"
  APP_STATUS=$(api "/applications/$P_UUID" --jq '.status // ""' | jq -r .) || die "lecture de l'application $P_UUID en échec"
  echo "Coolify : application $P_UUID (construite depuis $P_REPO), statut ${APP_STATUS:-inconnu}"
}
# PR previews switched off before the stop (a preview keeps running otherwise), then read back: any gap stops the run.
retire_previews() { # mode
  local cur body
  [[ -n $P_UUID ]] || return 0
  cur=$(api "/applications/$P_UUID" --jq '{on: (.settings.is_preview_deployments_enabled // false), pub: (.settings.is_pr_deployments_public_enabled // false)}' | jq -c .) \
    || die "lecture des prévisualisations de $P_UUID en échec"
  if [[ $(jq -r '.on or .pub' <<<"$cur") == false ]]; then echo "  = prévisualisations des PR déjà coupées"; return 0; fi
  if [[ $1 != real ]]; then echo "  - prévisualisations des PR coupées (PATCH /applications/$P_UUID, relu)"; return 0; fi
  body=$(preview_json | jsonfile)
  announce "prévisualisations des PR de $P_UUID coupées (retour arrière : previews: true, puis kit ship app)"
  api PATCH "/applications/$P_UUID" --json "@$body" --jq '{uuid: (.uuid // null)}' >/dev/null || die "coupure des prévisualisations refusée par Coolify"
  PREVIEWS_ON=0
  preview_readback "$P_UUID"
  ok "prévisualisations des PR coupées"
  REMOVED+=("prévisualisations coupées")
}
retire_app_stop() { # mode
  [[ -n $P_UUID ]] || return 0
  if [[ $APP_STATUS == exited* || $APP_STATUS == stopped* ]]; then echo "  = application déjà arrêtée"; return 0; fi
  if [[ $1 != real ]]; then echo "  - arrêt de l'application (TRIGGER /applications/$P_UUID/stop, GET côté Coolify)"; return 0; fi
  announce "arrêt de l'application Coolify $P_UUID (effet : service hors ligne ; retour arrière : kit api coolify TRIGGER \"/applications/$P_UUID/start\" --jq '.')"
  api TRIGGER "/applications/$P_UUID/stop" --jq '{message: (.message // null)}' >/dev/null || die "arrêt refusé par Coolify (voir le message ci-dessus)"
  local st
  st=$(api "/applications/$P_UUID" --jq '.status // ""' 2>/dev/null | jq -r . 2>/dev/null || echo inconnu)
  ok "arrêt demandé (statut lu ensuite : ${st:-inconnu} ; l'arrêt peut prendre quelques secondes)"
  REMOVED+=("application arrêtée")
}

# ---------- bridge DEPLOY_ALLOW ----------
BR_KEEP="" BR_DROP=0
retire_bridge_check() { # mode : reads DEPLOY_ALLOW (lock taken first in a real run); the value is never printed
  local mode=$1 repo e
  BA_BRIDGE=$(conf BRIDGE_APP_UUID)
  [[ -n $BA_BRIDGE ]] || return 0
  [[ $BA_BRIDGE =~ $UUID_RE ]] || die "ship.conf : BRIDGE_APP_UUID au format inattendu"
  if [[ $mode == real ]]; then
    LOCK_DIR="$KIT_CONFIG/ship-deploy-allow.lock"
    mkdir "$LOCK_DIR" 2>/dev/null || { LOCK_DIR=""; die "un autre kit ship ou kit retire modifie DEPLOY_ALLOW (verrou $KIT_CONFIG/ship-deploy-allow.lock ; s'il est périmé, retire ce dossier)"; }
  fi
  bridge_read
  if ((BA_N > 1)); then die "DEPLOY_ALLOW défini plusieurs fois sur le pont : à régler à la main (rien n'a été modifié)"; fi
  if ((BA_N == 1)) && [[ $BA_VAL == __kit_null__ ]]; then
    die "DEPLOY_ALLOW existe sur le pont mais sa valeur n'est pas lisible (masquée) : rien n'a été modifié ; retire l'entrée de $P_REPO à la main"
  fi
  ((BA_N == 1)) || return 0
  repo=$(lc "$P_REPO") BR_KEEP="" BR_DROP=0
  while IFS= read -r e; do
    [[ -n $e ]] || continue
    if [[ ${e%%=*} == "$repo" ]]; then
      BR_DROP=$((BR_DROP + 1))
      [[ -z $P_UUID || ${e#*=} == "$P_UUID" ]] || warn "DEPLOY_ALLOW : l'entrée de $P_REPO visait une autre application que coolify_uuid ; retirée aussi"
    else
      BR_KEEP+="$e"$'\n'
    fi
  done <<<"$(allow_entries "$BA_VAL")"
}
retire_bridge() { # mode
  local mode=$1 repo body e now
  if [[ -z $(conf BRIDGE_APP_UUID) ]]; then warn "BRIDGE_APP_UUID absent de ship.conf : DEPLOY_ALLOW non modifié"; return 0; fi
  repo=$(lc "$P_REPO")
  if ((BR_DROP == 0)); then echo "  = pont : $repo absent de DEPLOY_ALLOW"; return 0; fi
  if [[ $mode != real ]]; then echo "  - pont : $repo retiré de DEPLOY_ALLOW (autres entrées gardées), puis redéploiement du pont"; return 0; fi
  body=$(V=$(printf '%s' "$BR_KEEP" | grep -v '^$' | paste -sd, - || true) jq -n '{key: "DEPLOY_ALLOW", value: env.V, is_preview: false, is_literal: true}' | jsonfile)
  announce "DEPLOY_ALLOW du pont : retrait de $repo (retour arrière : kit ship app, qui remet l'entrée)"
  api PATCH "/applications/$BA_BRIDGE/envs" --json "@$body" --jq '{uuid: (.uuid // null)}' >/dev/null || die "écriture de DEPLOY_ALLOW refusée"
  # Read back: every other entry still there, none for this repository (compared here, never printed).
  bridge_read
  now=$'\n'$(allow_entries "$BA_VAL")$'\n'
  while IFS= read -r e; do
    [[ -z $e || $now == *$'\n'"$e"$'\n'* ]] || die "vérification de DEPLOY_ALLOW en échec : une autre entrée manque après l'écriture ; à contrôler dans l'interface du pont (valeur non affichée), pont non redéployé"
  done <<<"$BR_KEEP"
  while IFS= read -r e; do
    [[ -z $e || ${e%%=*} != "$repo" ]] || die "vérification de DEPLOY_ALLOW en échec : $repo y figure encore ; pont non redéployé"
  done <<<"$now"
  announce "redéploiement du pont pour charger DEPLOY_ALLOW (retour arrière : redéployer après correction)"
  api TRIGGER "/deploy?uuid=$BA_BRIDGE" --jq '{deployments: ((.deployments // []) | length)}' >/dev/null || die "redéploiement du pont en échec"
  ok "pont : $repo retiré de DEPLOY_ALLOW, redéploiement lancé"
  REMOVED+=("DEPLOY_ALLOW")
}

# ---------- project files ----------
retire_bridge_file() { # mode : drops the deploy: line, other keys kept
  local f="$DIR/.fs0/bridge.yaml" tmp
  [[ ! -L $DIR/.fs0 && ! -L $f ]] || die ".fs0/bridge.yaml est un lien symbolique : refusé"
  if ! has_key "$f" deploy; then echo "  = .fs0/bridge.yaml : pas de deploy:"; return 0; fi
  if [[ $1 != real ]]; then echo "  - .fs0/bridge.yaml : deploy: retiré (autres clés gardées)"; return 0; fi
  announce ".fs0/bridge.yaml : retrait de deploy: (retour arrière : git checkout .fs0/bridge.yaml)"
  tmp=$(mktemp)
  grep -v '^deploy:' "$f" >"$tmp" || true
  cat "$tmp" >"$f"
  rm -f "$tmp"
  ok ".fs0/bridge.yaml : deploy: retiré"
}
NOTE_START="<!-- kit retire -->" NOTE_END="<!-- /kit retire -->"
note_block() { # mode file text : appends a marked block once; a second run leaves it as it is
  local mode=$1 f=$2 rel=${2#"$DIR"/}
  [[ ! -L $f ]] || die "$rel est un lien symbolique : refusé"
  if [[ -f $f ]] && grep -qxF -- "$NOTE_START" "$f"; then echo "  = $rel : retrait déjà noté"; return 0; fi
  if [[ $mode != real ]]; then echo "  + $rel : note de retrait"; return 0; fi
  announce "$rel : note de retrait (retour arrière : git checkout $rel)"
  mkdir -p "$(dirname "$f")"
  { [[ ! -s $f ]] || echo; printf '%s\n%s\n%s\n' "$NOTE_START" "$3" "$NOTE_END"; } >>"$f"
}
retire_project_files() { # mode
  local mode=$1 day pr
  day=$(date +%Y-%m-%d)
  pr=${PR_URL:-aucune}
  if [[ $(pget expose) == none ]]; then echo "  = project.yaml : expose: none"
  elif [[ $mode != real ]]; then echo "  ~ project.yaml : expose: none (coolify_uuid et domain gardés pour référence)"
  else
    announce "project.yaml : expose: none (retour arrière : git checkout project.yaml)"
    kv_set "$DIR/project.yaml" expose none
  fi
  if [[ $(pget previews) == false ]]; then echo "  = project.yaml : previews: false"
  elif [[ $mode != real ]]; then echo "  ~ project.yaml : previews: false"
  else
    announce "project.yaml : previews: false (retour arrière : git checkout project.yaml)"
    kv_set "$DIR/project.yaml" previews false
  fi
  note_block "$mode" "$DIR/DEPLOY.md" "## Retrait

Retiré le $day par \`kit retire\` : application Coolify arrêtée (\`coolify_uuid\` gardé pour référence), entrée du
pont retirée de \`DEPLOY_ALLOW\`, \`deploy:\` retiré de \`.fs0/bridge.yaml\`, \`expose: none\`. PR d'infra : $pr.
Remise en ligne : remettre \`expose\` (et \`domain\`), puis \`/ship\`."
  note_block "$mode" "$DIR/docs/memory/state.md" "## Retrait ($day)

- **Fait** : service retiré par \`kit retire\` (application arrêtée, pont et \`deploy:\` coupés, \`expose: none\`).
- **Reste au propriétaire** : fusionner la PR d'infra ($pr) puis \`tofu apply\` ; supprimer l'application dans
  l'interface Coolify ; archiver le dépôt GitHub si voulu."
}

# ---------- infra repository ----------
# Start and end line of each uncommented entry (map key or list item at two spaces) of a top-level block.
entry_ranges() { # file block
  awk -v blk="$2" '
    function flush() { if (s) print s, last; s = 0 }
    /^[^ \t#]/ { flush(); inb = ($0 == blk ":" || index($0, blk ": ") == 1); next }
    !inb || /^[ \t]*$/ || /^[ \t]*#/ { next }
    /^  [^ ]/ { flush(); s = NR; last = NR; next }
    s { last = NR }
    END { flush() }' "$1"
}
# What kit ship writes, produced by kit ship's own step functions on an empty block (exact text, no guess).
ship_snippet() { # step file-relative-path block [expose]
  local root
  root=$(tmpd)
  mkdir -p "$root/$(dirname "$2")"
  printf '%s:\n' "$3" >"$root/$2"
  (APEX=1 INFRA_SRC=$root; P_EXPOSE=${4:-$P_EXPOSE} "$1" "$root" >/dev/null 2>&1) || return 0
  tail -n +2 "$root/$2"
}
match_dns() { [[ $1 == "  \"$DNS_KEY\":"* || $1 == *$'\n'"    name: \"$P_DOMAIN\""* ]]; }
match_access() { [[ $1 == "  \"$P_DOMAIN\":" || $1 == "  \"$P_DOMAIN\":"$'\n'* ]]; }
match_gatus() { [[ $1 == *$'\n'"    url: \"https://$P_DOMAIN"[\"/:?]* ]]; }
retire_entries() { # root relpath block match_fn label expected...
  local root=$1 rel=$2 blk=$3 fn=$4 label=$5 f="$1/$2" s e text exp hit del="" tmp kept=0
  shift 5
  [[ -f $f ]] || { echo "  - $label : $rel absent"; return 0; }
  while read -r s e; do
    [[ -n $s ]] || continue
    text=$(sed -n "${s},${e}p" "$f")
    "$fn" "$text" || continue
    hit=0
    for exp in "$@"; do if [[ -n $exp && $text == "$exp" ]]; then hit=1; fi; done
    if ((hit)); then del+="$s $e"$'\n'
    else
      echo "  ! $label : entrée de $rel (lignes $s-$e) différente de ce qu'écrit kit ship : gardée, à retirer à la main"
      MANUAL+=("$label ($rel, lignes $s-$e)") kept=1
    fi
  done < <(entry_ranges "$f" "$blk")
  if [[ -z $del ]]; then ((kept)) || echo "  = $label : rien à retirer ($rel)"; return 0; fi
  tmp=$(mktemp)
  DEL=$del awk 'BEGIN { n = split(ENVIRON["DEL"], r, "\n"); for (i = 1; i <= n; i++) if (r[i] != "") { split(r[i], p, " "); for (j = p[1]; j <= p[2]; j++) drop[j] = 1 } }
    !(FNR in drop)' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
  echo "  - $label : entrée de kit ship retirée ($rel)"
  CHANGES=$((CHANGES + 1)) SUMMARY+=("$label")
}
DNS_KEY=""
retire_steps() { # root
  local root=$1 zone="" file line
  if [[ -n $P_DOMAIN && $P_EXPOSE != tailnet ]]; then
    zone=$(zone_of "$P_DOMAIN")
    if [[ -z $zone ]]; then echo "  - DNS : aucune zone de ship.conf ne contient $P_DOMAIN"
    else
      if [[ $P_DOMAIN == "$zone" ]]; then DNS_KEY="@ CNAME"; else DNS_KEY="${P_DOMAIN%".$zone"} CNAME"; fi
      retire_entries "$root" "$DNS_DIR/$zone.yaml" records match_dns DNS \
        "$(ship_snippet step_dns "$DNS_DIR/$zone.yaml" records public)" "$(ship_snippet step_dns "$DNS_DIR/$zone.yaml" records access)"
    fi
    local acc=""
    [[ -z $POLICIES ]] || acc=$(ship_snippet step_access "$ACCESS_FILE" applications)
    retire_entries "$root" "$ACCESS_FILE" applications match_access Access "$acc"
    retire_entries "$root" "$GATUS_FILE" endpoints match_gatus Gatus "$(ship_snippet step_gatus "$GATUS_FILE" endpoints)"
  else
    if [[ -z $P_DOMAIN ]]; then echo "  - DNS, Access, Gatus : non (aucun domaine)"
    else echo "  - DNS, Access, Gatus : non (expose tailnet, aucun enregistrement public)"; fi
  fi
  file=$(conf BACKUP_FILE)
  if [[ -z $file ]]; then echo "  - Sauvegarde : BACKUP_FILE vide dans ship.conf"; return 0; fi
  [[ -f $root/$file ]] || { echo "  - Sauvegarde : $file absent"; return 0; }
  line=$(ship_snippet step_backup "$file" x | tail -1)
  if [[ -z $line ]] || ! grep -qxF -- "$line" "$root/$file"; then echo "  = Sauvegarde : rien à retirer ($file)"; return 0; fi
  local tmp
  tmp=$(mktemp)
  grep -vxF -- "$line" "$root/$file" >"$tmp" || true
  cat "$tmp" >"$root/$file"
  rm -f "$tmp"
  echo "  - Sauvegarde : entrée de kit ship retirée ($file)"
  CHANGES=$((CHANGES + 1)) SUMMARY+=("sauvegarde")
}
retire_files() { # ref -> relative paths that may change
  local z
  if [[ -n $(conf ZONES) ]]; then for z in $(zones_list); do echo "$DNS_DIR/$z.yaml"; done
  else git -C "$INFRA_DIR" ls-tree --name-only "$1" "$DNS_DIR/" 2>/dev/null || true; fi
  echo "$ACCESS_FILE"
  echo "$GATUS_FILE"
  [[ -z $(conf BACKUP_FILE) ]] || printf '%s\n' "$(conf BACKUP_FILE)"
  return 0
}
retire_infra() { # mode
  local mode=$1 ref root wt branch="retire/$P_NAME" pr title body d f
  if [[ -z $P_DOMAIN && -z $(conf BACKUP_FILE) ]]; then echo "Infra : rien à retirer (aucun domaine, pas de BACKUP_FILE)"; return 0; fi
  load_infra_conf
  TUNNEL=$(conf TUNNEL_TARGET) POLICIES=$(conf ACCESS_POLICIES)
  [[ -z $TUNNEL || $TUNNEL =~ ^[a-z0-9.-]+$ ]] || die "ship.conf : TUNNEL_TARGET au format inattendu"
  [[ -z $POLICIES || $POLICIES =~ ^[a-z0-9_]+([ ,]+[a-z0-9_]+)*$ ]] || die "ship.conf : ACCESS_POLICIES au format inattendu"
  echo "Infra : branche $branch sur $INFRA_REPO"
  if [[ $mode == real ]]; then
    need "$GH" "Installe GitHub CLI (gh)."
    git -C "$INFRA_DIR" fetch -q origin || die "git fetch du dépôt d'infra en échec"
  fi
  if git -C "$INFRA_DIR" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then ref="origin/$branch"; else ref="origin/$INFRA_BASE"; fi
  git -C "$INFRA_DIR" rev-parse -q --verify "$ref^{commit}" >/dev/null || die "référence $ref absente dans $INFRA_DIR (git fetch)"
  if [[ $mode != real ]]; then
    echo "  (d'après $ref du clone local, sans git fetch)"
    root=$(tmpd)
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      mkdir -p "$root/$(dirname "$f")"
      git -C "$INFRA_DIR" show "$ref:$f" >"$root/$f" 2>/dev/null || rm -f "$root/$f"
    done < <(retire_files "$ref")
    INFRA_SRC=$root
    d=$(tmpd)
    cp -R "$root/." "$d/"
    retire_steps "$root"
    if [[ $mode == dry ]] && ((CHANGES)); then (cd "$d" && diff -ru . "$root" | sed 's/^/    /') || true; fi
    if ((CHANGES)); then echo "  PR à ouvrir : « retire: $P_NAME » ($branch -> $INFRA_BASE), puis tofu apply par le propriétaire"; fi
    return 0
  fi
  wt="$(tmpd)/wt"
  git -C "$INFRA_DIR" worktree add -q --detach "$wt" "$ref" >/dev/null 2>&1 || die "git worktree add en échec dans $INFRA_DIR"
  WT_DIR=$wt INFRA_SRC=$wt
  retire_steps "$wt"
  if ((CHANGES)); then
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "retire($P_NAME): $(IFS=,; echo "${SUMMARY[*]}" | sed 's/,/, /g')" \
      -m "Opened by kit retire for $P_REPO: removes the entries kit ship wrote. Apply with tofu after review." \
      || die "commit en échec dans le dépôt d'infra"
    announce "push de $branch sur $INFRA_REPO (effet : branche de PR ; retour arrière : fermer la PR, supprimer la branche)"
    git -C "$wt" push -q origin "HEAD:refs/heads/$branch" || die "push en échec"
  elif git -C "$wt" diff --quiet "origin/$INFRA_BASE" HEAD --; then
    echo "  aucune modification : pas de PR"
    return 0
  fi
  pr=$("$GH" api "repos/$INFRA_REPO/pulls?head=${INFRA_REPO%%/*}:$branch&state=open" --jq '.[0].html_url // empty') || die "lecture des PR en échec (gh)"
  if [[ -n $pr ]]; then
    ok "PR déjà ouverte : $pr"
  else
    title="retire: $P_NAME"
    body=$(printf 'Opened by `kit retire` for `%s`: removes the entries `kit ship` wrote (%s).\n\nThe owner reviews, merges, then runs `tofu plan` and `tofu apply`.' \
      "$P_NAME" "$(IFS=,; echo "${SUMMARY[*]:-see commits}")")
    announce "PR « $title » sur $INFRA_REPO (effet : revue ; retour arrière : fermer la PR)"
    pr=$("$GH" api -X POST "repos/$INFRA_REPO/pulls" -f title="$title" -f head="$branch" -f base="$INFRA_BASE" -f body="$body" --jq .html_url) \
      || die "création de la PR en échec (gh)"
    ok "PR ouverte : $pr"
  fi
  PR_URL=$pr
}

# ---------- entry point ----------
retire_main() {
  local sub=${1:-help} mode
  shift || true
  case $sub in
    help|-h|--help) usage; return 0 ;;
    plan|run) ;;
    *) usage >&2; exit 1 ;;
  esac
  while (($#)); do
    case $1 in
      --dir) DIR=${2:?"dossier manquant"}; shift ;;
      --dry-run) DRY=1 ;;
      *) die "option inconnue : $1" ;;
    esac
    shift
  done
  [[ -d $DIR ]] || die "dossier introuvable : $DIR"
  DIR=$(cd "$DIR" && pwd)
  need jq
  load_project
  load_conf
  need_repo
  mode=real
  ((DRY)) && mode=dry
  [[ $sub == plan ]] && mode=plan
  echo "kit retire $sub : $P_NAME (expose $P_EXPOSE${P_DOMAIN:+, $P_DOMAIN}, dépôt $P_REPO)"
  # Read-only checks first: nothing is written unless the application belongs to this repository.
  retire_app_check
  retire_bridge_check "$mode"
  retire_previews "$mode"
  retire_app_stop "$mode"
  retire_bridge "$mode"
  echo "Projet :"
  retire_bridge_file "$mode"
  retire_infra "$mode"
  echo "Projet (mémoire) :"
  retire_project_files "$mode"
  if ((${#MANUAL[@]})); then
    echo "À régler à la main (entrées différentes de ce qu'écrit kit ship, gardées) :"
    printf '  - %s\n' "${MANUAL[@]}"
  fi
  case $mode in
    plan) echo "Rien n'a été écrit." ;;
    dry) echo "Rien n'a été écrit (--dry-run)." ;;
    real)
      echo "Reste au propriétaire :"
      echo "  1. relire et fusionner la PR d'infra (${PR_URL:-aucune}), puis tofu plan et tofu apply"
      echo "  2. supprimer l'application Coolify dans l'interface (le kit ne fait jamais de DELETE)"
      echo "  3. archiver le dépôt GitHub $P_REPO si voulu"
      echo "  Commiter project.yaml, .fs0/bridge.yaml, DEPLOY.md et docs/memory/state.md (PR du projet)."
      ;;
  esac
}
retire_main "$@"
