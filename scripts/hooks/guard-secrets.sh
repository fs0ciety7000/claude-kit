#!/usr/bin/env bash
# Hook PreToolUse de Claude Code : bloque la lecture de secrets et les fuites évidentes.
# Entrée : JSON sur stdin. Sortie : exit 2 + message sur stderr = action bloquée.
# C'est un garde-fou, pas une garantie : un shell peut toujours contourner des motifs.
# La vraie protection reste : pas de secret en clair sur disque, jetons à portée minimale.
set -uo pipefail

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0  # sans jq on ne bloque rien (kit doctor le signale)

block() {
  {
    echo "Bloqué par claude-kit : $1"
    echo "Pour qu'une commande reçoive des secrets sans que tu les voies : kit secrets run -- <commande>"
  } >&2
  exit 2
}

# Vrai si le chemin désigne un fichier de secrets ou d'identifiants.
is_secret_path() {
  local p=$1 base
  base=$(basename -- "$p")
  case $base in
    .env.example|.env.sample|.env.template|.env.tpl|.env.dist) return 1 ;;
    .env*|*.pem|*.key|id_rsa|id_ed25519|id_ecdsa|keys.txt|.netrc|.npmrc|.pypirc) return 0 ;;
  esac
  case "/$p" in
    */.ssh/*|*/.aws/*|*/.gnupg/*|*/.config/gh/*|*/.config/sops/*|*/.docker/config.json|*/.kube/config) return 0 ;;
  esac
  return 1
}

tool=$(jq -r '.tool_name // empty' <<<"$input")

case $tool in
  Read|Edit|Write|MultiEdit|NotebookEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    if [[ -n $path ]] && is_secret_path "$path"; then
      block "accès à un fichier de secrets ($path)"
    fi
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[[ -n $cmd ]] || exit 0

# 1) Un mot de la commande désigne un fichier de secrets.
while IFS= read -r tok; do
  [[ -n $tok ]] || continue
  tok=${tok#\~/}
  if is_secret_path "$tok"; then
    block "la commande touche un fichier de secrets ($tok)"
  fi
done < <(printf '%s\n' "$cmd" | tr -s '[:space:];|&<>()"`=' '\n' | tr -d "'")

# 2) Lecture de l'environnement.
if grep -Eq '(^|[;&|(])[[:space:]]*printenv([[:space:]]|$)' <<<"$cmd" \
  || grep -Eq '(^|[;&|(])[[:space:]]*(env|set|declare[[:space:]]+-x|export[[:space:]]+-p)[[:space:]]*($|[;&|)])' <<<"$cmd" \
  || grep -Eq '/proc/[^[:space:]]*/environ' <<<"$cmd"; then
  block "lecture de l'environnement du processus"
fi

# 3) Déchiffrement manuel ou accès à la clé privée.
if grep -Eq '(^|[^[:alnum:]_-])sops[[:space:]]+(-d|--decrypt|decrypt|exec-env|exec-file)' <<<"$cmd" \
  || grep -Eq '(^|[^[:alnum:]_-])age(-keygen)?[[:space:]]+(-d|--decrypt|-y)' <<<"$cmd"; then
  block "déchiffrement manuel de secrets"
fi

# 4) Affichage d'une variable au nom évocateur d'un secret.
if grep -Eiq '(echo|printf|cat|print)[^|;&]*\$\{?[A-Za-z_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY)' <<<"$cmd"; then
  block "affichage d'une variable secrète"
fi

# 5) Commit : refuse si le diff contient un motif de clé connu.
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+commit' <<<"$cmd"; then
  diff=$( { git diff --cached -U0; git diff -U0; } 2>/dev/null | grep -E '^\+[^+]' || true)
  if grep -Eq 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AGE-SECRET-KEY-1[A-Z0-9]{50,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|sk-[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}' <<<"$diff"; then
    block "le diff contient ce qui ressemble à une clé ou un jeton"
  fi
fi

exit 0
