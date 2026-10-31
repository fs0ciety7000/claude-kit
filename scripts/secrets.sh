#!/usr/bin/env bash
# Gestion des secrets avec sops + age.
# Principes : les valeurs ne sont jamais affichées, jamais passées en argument de commande,
# et ne sont injectées que dans le processus lancé par `run`.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

AGE_KEY="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="$AGE_KEY"
RECIPIENTS_FILE="$KIT_CONFIG/recipients"
GLOBAL_FILE="$KIT_CONFIG/secrets/global.enc.json"
SCOPE_GLOBAL=0
ENVNAME=dev
ARGS=()
T=""

cleanup() { [[ -n $T ]] && rm -rf "$T"; return 0; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
kit secrets <commande> [options]

  init                       crée la clé age (si absente) et enregistre ta clé publique
  pubkey                     affiche ta clé publique (à donner pour autoriser une machine)
  add-recipient <age1...>    autorise une autre clé (ex. ton VPS) sur tous les fichiers du dossier courant et global
  add NOM [-g] [-e ENV]      ajoute/modifie un secret (saisie masquée ; ou valeur via stdin)
  rm NOM [-g] [-e ENV]       supprime un secret
  list [-g] [-e ENV]         liste les NOMS des secrets (jamais les valeurs)
  check [FICHIER]            compare .env.example aux secrets disponibles (noms seulement)
  edit [-g] [-e ENV]         ouvre le fichier déchiffré dans $EDITOR (usage humain uniquement)
  run [-g] [-e ENV] -- CMD   lance CMD avec les secrets en variables d'environnement
  doctor                     vérifie l'installation

Portées : par défaut ./secrets/<ENV>.enc.json (ENV=dev par défaut) ;
          -g utilise le fichier global (~/.config/claude-kit/secrets/global.enc.json).
          Avec run, -g AJOUTE le global au fichier projet (le projet gagne en cas de doublon).
EOF
}

parse_flags() {
  SCOPE_GLOBAL=0
  ARGS=()
  while (($#)); do
    case $1 in
      -g|--global) SCOPE_GLOBAL=1 ;;
      -e|--env) ENVNAME=${2:?"valeur manquante pour $1"}; shift ;;
      --) ARGS+=("$@"); break ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

project_file() { echo "$PWD/secrets/$ENVNAME.enc.json"; }
target_file()  { if ((SCOPE_GLOBAL)); then echo "$GLOBAL_FILE"; else project_file; fi; }

tmpdir() {
  local base=${XDG_RUNTIME_DIR:-/dev/shm}
  [[ -d $base && -w $base ]] || base=/tmp
  (umask 077; mktemp -d "$base/kit-secrets.XXXXXX")
}

recipients_csv() {
  [[ -s $RECIPIENTS_FILE ]] || die "Aucun destinataire enregistré. Lance : kit secrets init"
  grep -E '^age1[a-z0-9]+$' "$RECIPIENTS_FILE" | paste -sd,
}

require_tools() {
  need sops "Arch : sudo pacman -S sops   |   autre : https://github.com/getsops/sops/releases"
  need age "Arch : sudo pacman -S age"
  need jq "Arch : sudo pacman -S jq"
}

names_of() { # fichier -> noms de variables, un par ligne
  [[ -f $1 ]] || return 0
  sops -d --output-type json "$1" | jq -r 'keys[]'
}

cmd_init() {
  require_tools
  need age-keygen "Arch : sudo pacman -S age"
  if [[ ! -f $AGE_KEY ]]; then
    mkdir -p "$(dirname "$AGE_KEY")"
    (umask 077; age-keygen -o "$AGE_KEY" 2>/dev/null)
    ok "clé age créée : $AGE_KEY (privée : ne la copie jamais dans un dépôt ni dans un chat)"
  else
    ok "clé age existante : $AGE_KEY"
  fi
  local pub
  pub=$(age-keygen -y "$AGE_KEY")
  mkdir -p "$KIT_CONFIG/secrets"
  touch "$RECIPIENTS_FILE"
  grep -qxF "$pub" "$RECIPIENTS_FILE" || echo "$pub" >>"$RECIPIENTS_FILE"
  echo "Clé publique : $pub"
  echo "Sauvegarde la clé privée ailleurs (gestionnaire de mots de passe) : sans elle, les secrets sont perdus."
}

cmd_pubkey() { need age-keygen; age-keygen -y "$AGE_KEY"; }

write_encrypted() { # fichier-json-clair fichier-destination
  local plain=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  sops -e --age "$(recipients_csv)" --input-type json --output-type json "$plain" >"$T/out.json"
  mv "$T/out.json" "$dest"
  chmod 600 "$dest"
}

load_current() { # fichier -> $T/cur.json (clair, en tmpfs)
  local file=$1
  if [[ -f $file ]]; then
    sops -d --output-type json "$file" >"$T/cur.json" || die "Déchiffrement impossible : $file (kit secrets doctor)"
  else
    echo '{}' >"$T/cur.json"
  fi
}

valid_name() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Nom de variable invalide : $1"; }

cmd_add() {
  parse_flags "$@"
  local key=${ARGS[0]:-}
  [[ -n $key ]] || die "usage : kit secrets add NOM [-g] [-e ENV]"
  valid_name "$key"
  require_tools
  local file; file=$(target_file)
  T=$(tmpdir)
  if [[ -t 0 ]]; then
    local v
    read -rsp "Valeur de $key (saisie masquée) : " v
    echo >&2
    printf '%s' "$v" >"$T/v"
    unset v
  else
    printf '%s' "$(cat)" >"$T/v"
  fi
  [[ -s $T/v ]] || die "Valeur vide, rien n'a été enregistré."
  load_current "$file"
  jq --arg k "$key" --rawfile v "$T/v" '.[$k] = $v' "$T/cur.json" >"$T/new.json"
  write_encrypted "$T/new.json" "$file"
  ok "$key enregistré dans ${file/#$HOME/~}"
}

cmd_rm() {
  parse_flags "$@"
  local key=${ARGS[0]:-}
  [[ -n $key ]] || die "usage : kit secrets rm NOM [-g] [-e ENV]"
  valid_name "$key"
  require_tools
  local file; file=$(target_file)
  [[ -f $file ]] || die "Fichier introuvable : $file"
  T=$(tmpdir)
  load_current "$file"
  jq --arg k "$key" 'del(.[$k])' "$T/cur.json" >"$T/new.json"
  write_encrypted "$T/new.json" "$file"
  ok "$key supprimé"
}

cmd_list() {
  parse_flags "$@"
  require_tools
  local file; file=$(target_file)
  [[ -f $file ]] || { echo "(aucun fichier : ${file/#$HOME/~})"; return 0; }
  names_of "$file"
}

cmd_check() {
  parse_flags "$@"
  require_tools
  local ex=${ARGS[0]:-.env.example} proj glob n missing=0
  [[ -f $ex ]] || die "$ex introuvable"
  proj=$(names_of "$(project_file)")
  glob=$(names_of "$GLOBAL_FILE")
  while read -r n; do
    if grep -qxF "$n" <<<"$proj"; then
      echo "✓ $n (projet)"
    elif grep -qxF "$n" <<<"$glob"; then
      echo "✓ $n (global : utiliser run -g)"
    else
      echo "✗ $n manquant : kit secrets add $n"
      missing=1
    fi
  done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$ex")
  return "$missing"
}

cmd_edit() {
  parse_flags "$@"
  require_tools
  local file; file=$(target_file)
  [[ -f $file ]] || die "Fichier introuvable : $file (crée d'abord un secret avec : kit secrets add NOM)"
  exec sops "$file"
}

load_scope() { # fichier -> exporte les variables dans le shell courant
  local f=$1 exports
  [[ -f $f ]] || return 1
  exports=$(sops -d --output-type json "$f" \
    | jq -r 'to_entries[] | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | tostring | @sh)"') \
    || die "Déchiffrement impossible : $f (bonne clé age ? kit secrets doctor)"
  eval "$exports"
}

cmd_run() {
  parse_flags "$@"
  require_tools
  local i sep=-1
  for i in "${!ARGS[@]}"; do
    if [[ ${ARGS[$i]} == -- ]]; then sep=$i; break; fi
  done
  ((sep >= 0)) || die "usage : kit secrets run [-g] [-e ENV] -- COMMANDE [args...]"
  local cmd=("${ARGS[@]:$((sep + 1))}")
  ((${#cmd[@]})) || die "Commande manquante après --"
  local loaded=0
  if ((SCOPE_GLOBAL)) && load_scope "$GLOBAL_FILE"; then loaded=1; fi
  if load_scope "$(project_file)"; then loaded=1; fi
  ((loaded)) || die "Aucun fichier de secrets (projet : $(project_file), global avec -g : $GLOBAL_FILE)"
  exec "${cmd[@]}"
}

cmd_add_recipient() {
  local pub=${1:-}
  [[ $pub =~ ^age1[a-z0-9]+$ ]] || die "usage : kit secrets add-recipient age1..."
  require_tools
  mkdir -p "$KIT_CONFIG"
  touch "$RECIPIENTS_FILE"
  grep -qxF "$pub" "$RECIPIENTS_FILE" || echo "$pub" >>"$RECIPIENTS_FILE"
  local f
  for f in "$GLOBAL_FILE" "$PWD"/secrets/*.enc.json; do
    [[ -f $f ]] || continue
    sops rotate -i --add-age "$pub" "$f"
    ok "${f/#$HOME/~} : clé ajoutée"
  done
  echo "Pense à relancer cette commande dans chaque projet qui a un dossier secrets/."
}

cmd_doctor() {
  local bad=0 t
  for t in sops age age-keygen jq; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else echo "✗ $t manquant"; bad=1; fi
  done
  if [[ -f $AGE_KEY ]]; then
    ok "clé age : $AGE_KEY"
    [[ "$(stat -c %a "$AGE_KEY")" == 600 ]] || { echo "✗ permissions de la clé : chmod 600 $AGE_KEY"; bad=1; }
  else
    echo "✗ clé age absente : kit secrets init"; bad=1
  fi
  [[ -s $RECIPIENTS_FILE ]] && ok "destinataires : $(grep -c '^age1' "$RECIPIENTS_FILE")" || { echo "✗ aucun destinataire : kit secrets init"; bad=1; }
  if [[ -f $GLOBAL_FILE ]] && command -v sops >/dev/null 2>&1; then
    sops -d "$GLOBAL_FILE" >/dev/null 2>&1 && ok "global déchiffrable" || { echo "✗ global non déchiffrable avec cette clé"; bad=1; }
  fi
  return "$bad"
}

main() {
  local sub=${1:-help}
  shift || true
  case $sub in
    init) cmd_init ;;
    pubkey) cmd_pubkey ;;
    add) cmd_add "$@" ;;
    rm) cmd_rm "$@" ;;
    list) cmd_list "$@" ;;
    check) cmd_check "$@" ;;
    edit) cmd_edit "$@" ;;
    run) cmd_run "$@" ;;
    add-recipient) cmd_add_recipient "$@" ;;
    doctor) cmd_doctor ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}
main "$@"
