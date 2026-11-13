#!/usr/bin/env bash
# kit new: one-shot project launcher (folder, template, stack, project.yaml, first commit, private GitHub repo).
# Sourced by kit.sh (needs lib.sh and the project_* helpers of kit.sh); not executable on its own.

# 0 = cloud session (claude.ai/code): no kit secrets, no SSH to GitHub, GitHub access limited to attached repos.
new_is_cloud() {
  [[ ${CLAUDE_CODE_REMOTE:-} == true || "$(cat "$KIT_CONFIG/profile" 2>/dev/null)" == cloud ]]
}

# Kind of a --stack item: type (registry), perms (templates/permissions/<p>.json), ci (templates/ci/<p>.yml), or empty.
new_stack_kind() { # item rows
  local s=$1 rows=$2
  [[ $s =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 0
  if awk -F';' -v t="$s" '$1 == t { f = 1 } END { exit !f }' <<<"$rows"; then echo type
  elif [[ -f $KIT_HOME/templates/permissions/$s.json ]]; then echo perms
  elif [[ " $CI_STACKS " == *" $s "* ]]; then echo ci
  fi
}

# gh is usable: installed and logged in (output discarded: no token ever printed).
new_gh_ok() { command -v gh >/dev/null 2>&1 && run_timeout 20 gh auth status >/dev/null 2>&1; }

# GITHUB_TOKEN present in the global kit secrets (name only).
new_kit_token_ok() {
  "$KIT_HOME/scripts/secrets.sh" list -g 2>/dev/null | grep -qxF GITHUB_TOKEN
}

new_usage() {
  die 'usage : kit new <nom> --stack <pile>[,<pile>] [--size S|M|L --reason "…"] [--public] [--dir parent] [--dry-run] [--no-skills]'
}

# Commands the owner runs on their own machine when the session cannot create the repository.
new_owner_hint() { # name visibility dir
  local pub=""
  [[ $2 == private ]] || pub=" --public"
  echo "  Sur ton poste (gh connecté ou GITHUB_TOKEN dans kit secrets) :"
  echo "    gh repo create $1 --$2        # ou : kit repo create $1$pub"
  echo "  puis attache le dépôt à la session cloud et, ici :"
  echo "    git -C $3 remote add origin https://github.com/<compte>/$1.git && git -C $3 push -u origin main"
}

cmd_new() {
  local name="" stacks_arg="" size="" reason="" vis=private parent=. dry=0 skills=1
  while (($#)); do
    case $1 in
      --stack) stacks_arg=${2:-}; shift ;;
      --size) size=${2:-}; shift ;;
      --reason) reason=${2:-}; shift ;;
      --public) vis=public ;;
      --dir) parent=${2:-}; shift ;;
      --dry-run) dry=1 ;;
      --no-skills) skills=0 ;;
      -h|--help) new_usage ;;
      -*) die "option inconnue : $1" ;;
      *) [[ -z $name ]] || die "un seul nom de projet"; name=$1 ;;
    esac
    shift
  done
  [[ -n $name && -n $stacks_arg && -n $parent ]] || new_usage
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "nom invalide : $name (lettres, chiffres, . _ -)"
  size=$(printf '%s' "$size" | tr '[:lower:]' '[:upper:]')
  if [[ -n $size ]]; then
    [[ $size =~ ^[SML]$ ]] || die "taille invalide : $size (S, M ou L)"
    [[ -n $reason ]] || die 'justification requise avec --size : --reason "<une ligne>"'
  fi

  # Stack items: registry types and permission piles go to kit project add, CI-only piles to kit project ci.
  local rows s kind add=() ci=() stacks=() c
  rows=$(registry_rows)
  IFS=',' read -r -a stacks <<<"${stacks_arg// /}"
  ((${#stacks[@]})) || new_usage
  for s in "${stacks[@]}"; do
    kind=$(new_stack_kind "$s" "$rows")
    case $kind in
      type) add+=("$s"); for c in $(ci_stack_for_type "$s"); do ci+=("$c"); done ;;
      perms) add+=("$s"); [[ " $CI_STACKS " != *" $s "* ]] || ci+=("$s") ;;
      ci) ci+=("$s") ;;
      *) die "pile inconnue : $s (types : kit project types ; piles de CI : $CI_STACKS)" ;;
    esac
  done

  local dir="${parent%/}/$name" resume=0
  if [[ -e $dir && ! -d $dir ]]; then die "$dir existe et n'est pas un dossier"; fi
  if [[ -d $dir && -n "$(ls -A "$dir")" ]]; then
    # Rerun on a folder made by kit new (same name, git repo): finish the remaining steps only.
    if [[ -d $dir/.git && $(yaml_get "$dir/project.yaml" name) == "$name" && -n $(yaml_get "$dir/project.yaml" stack) ]]; then
      resume=1
    else
      die "$dir existe déjà et n'est pas vide : kit new ne crée qu'un projet neuf (projet existant : /adopt ou kit project init)"
    fi
  fi

  local cloud=0
  if new_is_cloud; then cloud=1; fi
  if ((dry)); then
    echo "Simulation (rien n'est écrit) : $dir"
    if ((resume)); then echo "  reprise : dossier déjà créé par kit new, étapes restantes seulement"; fi
    echo "  gabarit : kit project init $dir"
    if ((${#add[@]})); then echo "  pile : kit project add ${add[*]} --dir $dir --no-ci$( ((skills)) || echo ' --no-skills')"; fi
    if ((${#ci[@]})); then echo "  CI : kit project ci ${ci[*]} --dir $dir (si absente)"; fi
    echo "  project.yaml : name=$name stack=${stacks[*]}${size:+ size=$size}"
    echo "  git init -b main + premier commit"
    if ((cloud)); then
      echo "  dépôt GitHub $vis : session cloud, gh si connecté, sinon commande à lancer sur ton poste"
    else
      echo "  dépôt GitHub $vis : kit repo create $name (GITHUB_TOKEN) ou gh repo create, puis git push -u origin main"
    fi
    return 0
  fi

  need git
  need jq
  if ((!resume)); then
    mkdir -p "$dir"
    cp -rn "$KIT_HOME/templates/project/." "$dir/" 2>/dev/null
    ok "gabarit copié dans $dir"
    [[ -d $dir/.git ]] || git -C "$dir" init -q -b main
    local addopts=(--dir "$dir" --no-ci)
    ((skills)) || addopts+=(--no-skills)
    if ((${#add[@]})); then project_add "${add[@]}" "${addopts[@]}"; fi
    if ((${#ci[@]})); then project_ci --if-absent --dir "$dir" "${ci[@]}"; fi
    [[ -f $dir/project.yaml ]] || : >"$dir/project.yaml"
    yaml_set "$dir/project.yaml" name "$name"
    yaml_set "$dir/project.yaml" stack "$(IFS=,; echo "${stacks[*]}")"
    if [[ -n $size ]]; then project_size "$size" --reason "$reason" --dir "$dir"; fi
  fi
  if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "Initial commit (kit new)" \
      || die 'premier commit impossible : identité git ? git config --global user.name "…" && git config --global user.email "…"'
    ok "premier commit : $(git -C "$dir" log -1 --format=%h)"
  fi

  # Private GitHub repository and first push. Existing origin: creation skipped (rerun).
  local pushed=0
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    if ((!cloud)) && new_kit_token_ok; then
      local ropts=(--dir "$dir")
      [[ $vis == private ]] || ropts+=(--public)
      (cmd_repo create "$name" "${ropts[@]}" >/dev/null) || warn "kit repo create a échoué (message ci-dessus)"
    elif new_gh_ok; then
      run_timeout 60 gh repo create "$name" "--$vis" --source "$dir" --remote origin >/dev/null \
        && ok "dépôt GitHub $vis créé (gh) : $name" \
        || warn "gh repo create a échoué (nom déjà pris, droits du jeton, accès limité de la session ?)"
    fi
  fi
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    if git -C "$dir" push -q -u origin main 2>/dev/null; then
      pushed=1
      ok "main poussée vers origin"
    else
      warn "push refusé : vérifie l'accès (gh auth setup-git, clé de déploiement) puis : git -C $dir push -u origin main"
    fi
  elif ((cloud)); then
    echo "! session cloud : le dépôt GitHub ne peut pas être créé d'ici (accès GitHub limité aux dépôts attachés)."
    new_owner_hint "$name" "$vis" "$dir"
  else
    echo "! dépôt GitHub non créé : ni GITHUB_TOKEN (kit secrets add GITHUB_TOKEN -g) ni gh connecté (gh auth login)."
    echo "  Ensuite : kit new $name --stack $stacks_arg --dir $parent   (reprend où il s'est arrêté)"
  fi

  [[ -n $size ]] || size=$(yaml_get "$dir/project.yaml" size)
  [[ $size =~ ^[SML]$ ]] || size=""
  ok "projet $name prêt dans $dir$( ((pushed)) && echo ', poussé sur GitHub')"
  echo "Étapes suivantes :"
  echo "  cd $dir && claude          (claude remote-control pour suivre la session depuis l'app)"
  echo "  /new-project \"<description>\" : brief, ${size:+taille $size déjà fixée, }équipe (skill team-builder), plan (docs/plan.md), validation"
  [[ -n $size ]] || echo "  taille : skill project-size, puis kit project size S|M|L --reason \"…\" --dir $dir"
  echo "  première mise en prod : /ship (validation dans le chat)"
}

# kit doctor: GitHub prerequisites of kit new and kit repo create (names and states only, never a token).
new_doctor() { # cloud(0|1)
  local cloud=$1 login
  if ! command -v gh >/dev/null 2>&1; then
    echo "! gh absent : kit new crée alors le dépôt par kit repo create seulement ($(pkg_hint github-cli))"
  elif new_gh_ok; then
    ok "gh authentifié"
    login=$(run_timeout 20 gh api user --jq .login 2>/dev/null || true)
    if [[ $login =~ ^[A-Za-z0-9-]+$ ]]; then
      if run_timeout 20 gh api "repos/$login/project-template" --jq .is_template 2>/dev/null | grep -qx true; then
        ok "dépôt modèle project-template présent"
      else
        echo "! dépôt modèle project-template absent ou non marqué modèle : kit project template (depuis ton poste)"
      fi
    fi
  else
    echo "! gh non authentifié : gh auth login (kit new l'utilise si GITHUB_TOKEN manque)"
  fi
  ((cloud)) && return 0
  if new_kit_token_ok; then
    ok "GITHUB_TOKEN dans les secrets globaux (kit repo create)"
  else
    echo "! GITHUB_TOKEN absent des secrets globaux : kit secrets add GITHUB_TOKEN -g (kit repo create, kit project template)"
  fi
}
