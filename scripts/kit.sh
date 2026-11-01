#!/usr/bin/env bash
# kit : point d'entrée unique. Installé comme ~/.local/bin/kit par install.sh.
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=lib.sh
source "$(dirname "$SELF")/lib.sh"

usage() {
  cat <<'EOF'
kit : gérer skills, agents et secrets de Claude Code

AJOUTER FACILEMENT
  kit add-skill <source> [--skill nom ...] [--profile p] [--project]
        installe un skill (global par défaut), le mémorise dans profiles/<p>.txt (défaut : custom)
        ex. kit add-skill vercel-labs/agent-skills --skill vercel-react-best-practices --profile web
  kit add-agent <url|gh:owner/repo/chemin.md|fichier.md> [--project] [--force]
        télécharge un agent, vérifie son en-tête, l'installe (global par défaut)
  kit new-agent <nom> "<description>" [--tools "Read, Glob, Grep"]
  kit new-skill <nom> "<description>"

SKILLS PAR PROFIL
  kit skills install [-g] <profil>...     installe les skills d'un ou plusieurs profils
  kit skills profiles                     liste les profils
  kit registry                            régénère la table des profils dans skills-registry.md

PROJETS
  kit project new <dossier>               crée un dossier neuf + gabarit + git init, puis lance claude et /new-project
  kit project init [dossier]              copie le gabarit dans un dossier existant (n'écrase rien)
        gabarit : CLAUDE.md, AGENTS.md, DESIGN.md, DEPLOY.md, .env.example, .gitignore, secrets/

SECRETS (sops + age)
  kit secrets <commande>                  voir : kit secrets help

API COOLIFY / CLOUDFLARE (jeton jamais visible dans `ps`)
  kit api <coolify|cloudflare> [GET|POST|PUT|PATCH|DELETE|TRIGGER] <chemin> --jq <filtre> [--json <JSON|@fichier>]
        filtre jq obligatoire ; affiche le code HTTP et le nombre d'éléments
        TRIGGER = action déclenchée par un GET (Coolify : /deploy, /start, /stop, /restart)
        "__SECRET:NOM__" dans le corps JSON = valeur du secret chiffré NOM, jamais visible
        ex. kit api coolify /applications --jq 'map({uuid,name,status})'
        DELETE est bloqué par les réglages (permissions.deny)

INFOS & MAINTENANCE
  kit list                                agents, skills et profils disponibles
  kit mcp setup                           déclare le serveur MCP Coolify (jeton injecté, jamais écrit en clair)
  kit sync                                (re)crée les liens vers ~/.claude et fusionne les réglages
  kit update                              git pull du kit + sync + mise à jour des skills globaux
  kit doctor                              vérifie l'installation
EOF
}

# ---------- profils de skills ----------

profile_names() {
  local f
  for f in "$KIT_HOME"/profiles/*.txt; do
    [[ -f $f ]] && basename "$f" .txt
  done
  return 0
}

install_line() { # "<source> [--skill a b]"  global(0|1)
  local line=$1 global=$2 parts flags=(--agent claude-code -y)
  read -ra parts <<<"$line"
  if ((global)); then flags+=(-g); fi
  info "npx skills add ${parts[*]} ${flags[*]}"
  npx --yes skills add "${parts[@]}" "${flags[@]}" </dev/null
}

cmd_skills() {
  local sub=${1:-}
  shift || true
  case $sub in
    profiles) profile_names ;;
    install)
      need npx "Installe Node.js (Arch : sudo pacman -S nodejs npm)."
      local global=0 profiles=() p
      while (($#)); do
        case $1 in
          -g|--global) global=1 ;;
          *) profiles+=("$1") ;;
        esac
        shift
      done
      ((${#profiles[@]})) || die "usage : kit skills install [-g] <profil>...   (profils : $(profile_names | paste -sd' '))"
      local ok=0 fail=0 failed=() line
      for p in "${profiles[@]}"; do
        [[ -f $KIT_HOME/profiles/$p.txt ]] || die "Profil inconnu : $p (profils : $(profile_names | paste -sd' '))"
        while IFS= read -r line; do
          line=${line%%#*}
          line=$(echo "$line" | xargs 2>/dev/null || true)
          [[ -n $line ]] || continue
          if install_line "$line" "$global"; then ok=$((ok + 1)); else fail=$((fail + 1)); failed+=("$line"); fi
        done <"$KIT_HOME/profiles/$p.txt"
      done
      echo
      echo "Skills : $ok lignes installées, $fail en échec."
      if ((fail > 0)); then
        printf '  ✗ %s\n' "${failed[@]}"
        echo "Les noms de skills dépendent de ce que publient les dépôts : vérifie avec « npx skills add <source> -l »."
      fi
      echo "Relis les SKILL.md installés : ce sont des instructions tierces. Redémarre Claude Code pour les charger."
      ((fail == 0))
      ;;
    *) die "usage : kit skills install|profiles" ;;
  esac
}

regen_registry() {
  local reg="$KIT_HOME/global/skills-registry.md" tmp blk p content
  [[ -f $reg ]] || return 0
  grep -q 'kit:profiles:start' "$reg" || { warn "marqueurs absents dans $reg : table non régénérée"; return 0; }
  tmp=$(mktemp)
  blk=$(mktemp)
  {
    echo '<!-- kit:profiles:start -->'
    echo '| Profil | Contenu (source → skills) |'
    echo '|---|---|'
    for p in $(profile_names); do
      content=$(grep -vE '^[[:space:]]*(#|$)' "$KIT_HOME/profiles/$p.txt" \
        | sed -E 's# --skill # → #; s#https://github.com/##' | paste -sd';' | sed 's/;/ ; /g')
      echo "| \`$p\` | ${content:-(vide)} |"
    done
    echo '<!-- kit:profiles:end -->'
  } >"$blk"
  awk -v blk="$blk" '
    /<!-- kit:profiles:start -->/ { while ((getline l < blk) > 0) print l; skip = 1; next }
    /<!-- kit:profiles:end -->/   { skip = 0; next }
    !skip { print }
  ' "$reg" >"$tmp"
  cat "$tmp" >"$reg"
  rm -f "$tmp" "$blk"
  ok "registre mis à jour"
}

cmd_add_skill() {
  local source="" names=() profile=custom global=1 collecting=0
  while (($#)); do
    case $1 in
      --skill|-s) collecting=1 ;;
      --profile|-p) profile=${2:?"nom de profil manquant"}; shift; collecting=0 ;;
      --project) global=0; collecting=0 ;;
      -g|--global) global=1; collecting=0 ;;
      -*) die "option inconnue : $1" ;;
      *)
        if ((collecting)); then names+=("$1")
        elif [[ -z $source ]]; then source=$1
        else die "argument en trop : $1 (les noms de skills se mettent après --skill)"
        fi
        ;;
    esac
    shift
  done
  [[ -n $source ]] || die "usage : kit add-skill <source> [--skill nom ...] [--profile p] [--project]"
  [[ $profile =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Nom de profil invalide : $profile"
  need npx "Installe Node.js."
  local line=$source
  if ((${#names[@]})); then line+=" --skill ${names[*]}"; fi
  install_line "$line" "$global" || die "Installation échouée. Vérifie la source et les noms (npx skills add $source -l)."
  local pf="$KIT_HOME/profiles/$profile.txt"
  touch "$pf"
  if grep -qxF "$line" "$pf"; then
    info "déjà présent dans le profil $profile"
  else
    echo "$line" >>"$pf"
    ok "ajouté au profil « $profile » (pour le retrouver sur tes autres machines)"
  fi
  regen_registry
  echo "Relis le SKILL.md installé (contenu tiers). Pense à commiter le kit : git -C $KIT_HOME add -A && git -C $KIT_HOME commit"
}

# ---------- agents ----------

fm_get() { # fichier clé -> valeur de l'en-tête YAML
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, k ":") == 1 { sub("^" k ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

resolve_source() {
  case $1 in
    gh:*)
      local s=${1#gh:} owner repo path rest
      owner=${s%%/*}; rest=${s#*/}; repo=${rest%%/*}; path=${rest#*/}
      [[ -n $owner && -n $repo && $path != "$rest" ]] || die "format : gh:owner/repo/chemin/agent.md"
      echo "https://raw.githubusercontent.com/$owner/$repo/HEAD/$path"
      ;;
    https://github.com/*/blob/*)
      echo "$1" | sed -E 's#https://github.com/([^/]+)/([^/]+)/blob/#https://raw.githubusercontent.com/\1/\2/#'
      ;;
    https://*) echo "$1" ;;
    http://*) die "http refusé : utilise https" ;;
    *) echo "$1" ;;
  esac
}

cmd_add_agent() {
  local src="" project=0 force=0
  while (($#)); do
    case $1 in
      --project) project=1 ;;
      --force) force=1 ;;
      -*) die "option inconnue : $1" ;;
      *) [[ -z $src ]] && src=$1 || die "argument en trop : $1" ;;
    esac
    shift
  done
  [[ -n $src ]] || die "usage : kit add-agent <url|gh:owner/repo/chemin.md|fichier.md> [--project] [--force]"
  local url name desc tools dest_dir dest
  TMP_FILE=$(mktemp)  # global exprès : nettoyé par le trap EXIT, hors de la portée de la fonction
  trap 'rm -f "${TMP_FILE:-}"' EXIT
  url=$(resolve_source "$src")
  if [[ $url == https://* ]]; then
    need curl
    curl -fsSL --max-filesize 200000 -o "$TMP_FILE" "$url" || die "Téléchargement impossible : $url"
  else
    [[ -f $url ]] || die "Fichier introuvable : $url"
    cp "$url" "$TMP_FILE"
  fi
  [[ "$(head -1 "$TMP_FILE")" == "---" ]] || die "Pas d'en-tête YAML (---) : ce n'est pas un agent Claude Code."
  name=$(fm_get "$TMP_FILE" name)
  desc=$(fm_get "$TMP_FILE" description)
  tools=$(fm_get "$TMP_FILE" tools)
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Nom d'agent invalide ou absent dans l'en-tête : « $name »"
  [[ -n $desc ]] || die "Description absente dans l'en-tête."
  if ((project)); then dest_dir="$PWD/.claude/agents"; else dest_dir="$KIT_HOME/global/agents"; fi
  dest="$dest_dir/$name.md"
  if [[ -e $dest && $force -ne 1 ]]; then die "$dest existe déjà (--force pour remplacer)"; fi
  mkdir -p "$dest_dir"
  cp "$TMP_FILE" "$dest"
  if ((project == 0)); then link_dir "$KIT_HOME/global/agents" "$CLAUDE_HOME/agents"; fi
  ok "agent « $name » installé : ${dest/#$HOME/~}"
  echo "  description : $desc"
  if [[ -z $tools ]]; then
    warn "aucune ligne « tools: » : cet agent hérite de TOUS les outils (y compris Bash). Restreins-la si possible."
  else
    echo "  outils      : $tools"
  fi
  echo "Relis le fichier avant de t'en servir : c'est un prompt tiers."
}

cmd_new_agent() {
  local name=${1:-} desc=${2:-} tools="Read, Glob, Grep"
  shift 2 2>/dev/null || true
  while (($#)); do
    case $1 in
      --tools) tools=${2:?"liste d'outils manquante"}; shift ;;
      *) die "option inconnue : $1" ;;
    esac
    shift
  done
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ && -n $desc ]] || die 'usage : kit new-agent <nom-en-minuscules> "<description>" [--tools "Read, Glob, Grep"]'
  local dest="$KIT_HOME/global/agents/$name.md"
  [[ ! -e $dest ]] || die "$dest existe déjà"
  cat >"$dest" <<EOF
---
name: $name
description: $desc
tools: $tools
---

Tu es $name.

## Rôle
(À compléter : ce que fait cet agent, en une ou deux phrases.)

## Méthode
1. (étape concrète)
2. (étape concrète)

## Sortie attendue
(Format du rapport rendu à l'agent principal : court, actionnable.)

## Limites
- Reste dans ton rôle ; signale ce qui sort de ton périmètre.
EOF
  link_dir "$KIT_HOME/global/agents" "$CLAUDE_HOME/agents"
  ok "agent créé : $dest (lien dans ~/.claude/agents). Complète-le, puis redémarre Claude Code."
}

cmd_new_skill() {
  local name=${1:-} desc=${2:-}
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ && -n $desc ]] || die 'usage : kit new-skill <nom-en-minuscules> "<description : quand l utiliser>"'
  local dir="$KIT_HOME/global/skills/$name"
  [[ ! -e $dir ]] || die "$dir existe déjà"
  mkdir -p "$dir"
  cat >"$dir/SKILL.md" <<EOF
---
name: $name
description: $desc
---

# $name

## Quand l'utiliser
(À compléter : déclencheurs précis.)

## Procédure
1. (étape concrète)
2. (étape concrète)

## Pièges
- (erreur fréquente à éviter)
EOF
  link_dir "$KIT_HOME/global/skills" "$CLAUDE_HOME/skills"
  ok "skill créé : $dir/SKILL.md. Complète-le, puis redémarre Claude Code."
}

# ---------- projet, listes, maintenance ----------

cmd_project() {
  local sub=${1:-} dir
  case $sub in
    init)
      dir=${2:-.}
      mkdir -p "$dir"
      cp -rn "$KIT_HOME/templates/project/." "$dir/" 2>/dev/null
      ok "gabarit copié dans $dir (rien d'existant n'a été écrasé)"
      echo "Étapes suivantes : lance « claude » dans ce dossier puis /new-project \"<description>\""
      ;;
    new)
      dir=${2:-}
      [[ -n $dir ]] || die "usage : kit project new <dossier>"
      [[ ! -e $dir ]] || [[ -d $dir && -z "$(ls -A "$dir")" ]] || die "$dir existe déjà et n'est pas vide : utilise « kit project init $dir »"
      mkdir -p "$dir"
      cp -rn "$KIT_HOME/templates/project/." "$dir/" 2>/dev/null
      if command -v git >/dev/null 2>&1 && [[ ! -d $dir/.git ]]; then git -C "$dir" init -q -b main; fi
      ok "projet créé dans $dir (dépôt git initialisé, aucun commit)"
      echo "Étapes suivantes :"
      echo "  cd $dir && claude"
      echo "  puis : /new-project \"<description du projet>\"   (ajoute --rapide pour enchaîner sans pause)"
      ;;
    *) die "usage : kit project new <dossier> | kit project init [dossier]" ;;
  esac
}

cmd_list() {
  local f
  echo "== Agents (kit) =="
  for f in "$KIT_HOME"/global/agents/*.md; do
    [[ -f $f ]] && printf '  %-22s %s\n' "$(fm_get "$f" name)" "$(fm_get "$f" description | cut -c1-90)"
  done
  echo "== Skills (kit) =="
  for f in "$KIT_HOME"/global/skills/*/SKILL.md; do
    [[ -f $f ]] && printf '  %-26s %s\n' "$(fm_get "$f" name)" "$(fm_get "$f" description | cut -c1-80)"
  done
  echo "== Skills installés (~/.claude/skills) =="
  ls -1 "$CLAUDE_HOME/skills" 2>/dev/null | sed 's/^/  /' || true
  echo "== Profils =="
  profile_names | sed 's/^/  /'
}

cmd_mcp() {
  [[ ${1:-} == setup ]] || die "usage : kit mcp setup"
  need claude "Installe Claude Code d'abord."
  local bin="$HOME/.local/bin/kit" names
  [[ -x $bin ]] || bin=$SELF
  names=$("$KIT_HOME/scripts/secrets.sh" list -g 2>/dev/null || true)
  local v
  for v in COOLIFY_ACCESS_TOKEN COOLIFY_BASE_URL; do
    grep -qxF "$v" <<<"$names" || warn "$v absent des secrets globaux : kit secrets add $v -g"
  done
  claude mcp remove coolify --scope user >/dev/null 2>&1 || true
  claude mcp add --scope user coolify -- "$bin" secrets run -g -- npx -y @masonator/coolify-mcp
  ok "MCP Coolify déclaré. Le jeton est lu depuis tes secrets chiffrés au lancement du serveur, jamais stocké dans la config."
  echo "Conseil : épingle une version (npx -y @masonator/coolify-mcp@X.Y.Z) après avoir relu le paquet sur npm."
}

cmd_sync() {
  link_global
  apply_settings
  regen_registry
  ok "liens et réglages à jour"
}

cmd_update() {
  git -C "$KIT_HOME" pull --ff-only
  cmd_sync
  if command -v npx >/dev/null 2>&1; then npx --yes skills update -g -y </dev/null || warn "mise à jour des skills globaux échouée"; fi
}

cmd_doctor() {
  local bad=0 t
  for t in git node npm jq sops age claude; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else echo "✗ $t manquant"; bad=1; fi
  done
  [[ -L $CLAUDE_HOME/CLAUDE.md ]] && ok "CLAUDE.md global lié" || { echo "✗ CLAUDE.md global non lié : kit sync"; bad=1; }
  if [[ -f $CLAUDE_HOME/settings.json ]] && jq -e '.hooks.PreToolUse | length > 0' "$CLAUDE_HOME/settings.json" >/dev/null 2>&1; then
    ok "hook anti-fuite actif"
  else
    echo "✗ hook anti-fuite absent de settings.json : kit sync"; bad=1
  fi
  [[ -x $KIT_CONFIG/hooks/guard-secrets.sh ]] && ok "hook installé" || { echo "✗ hook introuvable : kit sync"; bad=1; }
  case ":$PATH:" in *":$HOME/.local/bin:"*) ok "\$HOME/.local/bin dans le PATH" ;; *) echo "✗ ajoute \$HOME/.local/bin à ton PATH"; bad=1 ;; esac
  "$KIT_HOME/scripts/secrets.sh" doctor || bad=1
  return "$bad"
}

main() {
  local sub=${1:-help}
  shift || true
  case $sub in
    secrets) exec "$KIT_HOME/scripts/secrets.sh" "$@" ;;
    api) exec "$KIT_HOME/scripts/api.sh" "$@" ;;
    skills) cmd_skills "$@" ;;
    add-skill) cmd_add_skill "$@" ;;
    add-agent) cmd_add_agent "$@" ;;
    new-agent) cmd_new_agent "$@" ;;
    new-skill) cmd_new_skill "$@" ;;
    registry) regen_registry ;;
    project) cmd_project "$@" ;;
    list) cmd_list ;;
    mcp) cmd_mcp "$@" ;;
    sync) cmd_sync ;;
    update) cmd_update ;;
    doctor) cmd_doctor ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}
main "$@"
