#!/usr/bin/env bash
# Hook SessionStart (startup|resume) : met le kit à jour (git fast-forward sur main) puis relance `kit sync`.
# Ne casse jamais le démarrage : sort toujours avec 0, ne pose aucune question (pas de prompt git ni ssh),
# chaque opération git est bornée à 10 s. La sortie standard est ajoutée au contexte de Claude : 1 ou 2 lignes au plus,
# rien quand le kit est déjà à jour.
#
# Réglages :
#   KIT_AUTOUPDATE=0    désactive le hook.
#   Profil local/vps    au plus une vérification toutes les 6 h (tampon dans $KIT_CONFIG/autoupdate.stamp).
#   Profil cloud, ou CLAUDE_CODE_REMOTE=true : à chaque démarrage ou reprise.
# Ignoré (avec une ligne) si le dépôt du kit a des modifications locales ou n'est pas sur main.
# L'entrée JSON du hook (stdin) est ignorée.
set -uo pipefail

[[ ${KIT_AUTOUPDATE:-1} == 0 ]] && exit 0

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || exit 0
KIT_HOME=$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd) || exit 0
KIT_CONFIG=${KIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit}
STAMP=$KIT_CONFIG/autoupdate.stamp
INTERVAL=21600 # 6 h

command -v git >/dev/null 2>&1 || exit 0
[[ -d $KIT_HOME/.git || -f $KIT_HOME/.git ]] || exit 0

# Jamais interactif : ni mot de passe git, ni question ssh. On respecte un GIT_SSH_COMMAND ou core.sshCommand existant.
export GIT_TERMINAL_PROMPT=0
if [[ -z ${GIT_SSH_COMMAND:-} ]] && [[ -z $(git -C "$KIT_HOME" config --get core.sshCommand 2>/dev/null) ]]; then
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=8"
fi

tmo() { # secondes commande...
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else "$@"; fi
}
g() { tmo 10 git -C "$KIT_HOME" "$@" </dev/null 2>/dev/null; }

profile=$(cat "$KIT_CONFIG/profile" 2>/dev/null || echo local)
now=$(date +%s)
if [[ $profile != cloud && ${CLAUDE_CODE_REMOTE:-} != true ]]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [[ $last =~ ^[0-9]+$ ]] || last=0
  ((now - last < INTERVAL)) && exit 0
  mkdir -p "$KIT_CONFIG" 2>/dev/null && echo "$now" >"$STAMP" 2>/dev/null
fi

branch=$(g symbolic-ref --short -q HEAD) || branch=""
if [[ $branch != main ]]; then
  echo "kit : mise à jour auto ignorée (branche « ${branch:-détachée} », pas main) dans $KIT_HOME."
  exit 0
fi
if [[ -n $(g status --porcelain --untracked-files=no) ]]; then
  echo "kit : mise à jour auto ignorée (modifications locales dans $KIT_HOME)."
  exit 0
fi

g fetch --quiet origin main || exit 0
old=$(g rev-parse HEAD) || exit 0
if ! g merge --ff-only --quiet origin/main; then
  echo "kit : mise à jour auto impossible (historique local divergent de origin/main) dans $KIT_HOME."
  exit 0
fi
new=$(g rev-parse HEAD) || exit 0
[[ $old != "$new" ]] || exit 0

n=$(g rev-list --count "$old..$new") || n="?"
if tmo 15 "$KIT_HOME/scripts/kit.sh" sync </dev/null >/dev/null 2>&1; then
  sync_note=""
else
  sync_note=" (kit sync a échoué : lance-le à la main)"
fi
echo "kit mis à jour : ${old:0:7}..${new:0:7} ($n commits) — les réglages s'appliquent tout de suite, CLAUDE.md et les commandes au prochain démarrage de session.$sync_note"
exit 0
