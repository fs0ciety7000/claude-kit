#!/usr/bin/env bash
# Hook SessionStart (startup|resume) : met le kit à jour (git fast-forward sur main) puis lance `kit sync` en arrière-plan.
# Ne casse jamais le démarrage : sort toujours avec 0, ne pose aucune question (pas de prompt git ni ssh).
# Budget de temps (le hook a 30 s dans settings.json) : état local 3 s par appel, fetch 8 s, merge 5 s. `kit sync` est
# détaché (setsid/nohup, sortie dans $KIT_CONFIG/autoupdate.log) : il n'est jamais tué à mi-écriture par la fin du hook.
# La sortie standard est ajoutée au contexte de Claude : 1 ou 2 lignes au plus, rien quand le kit est déjà à jour.
#
# Réglages :
#   KIT_AUTOUPDATE=0    désactive le hook (variable d'environnement).
#   autoupdate.off      fichier $KIT_CONFIG/autoupdate.off (n'importe quel contenu) : désactive le hook sur ce poste.
#   autoupdate.pin      fichier $KIT_CONFIG/autoupdate.pin, une référence (tag, branche de origin ou SHA) sur sa première
#                       ligne : le kit reste sur cette version. Le hook va chercher origin (tags compris) et, si le kit
#                       n'est pas déjà sur cette révision, le met en HEAD détaché dessus (même garde-fous : arbre propre,
#                       pas sur une autre branche que main). Retirer le fichier : `git checkout main` dans le kit.
#   Profil local/vps    une vérification réussie au plus toutes les 6 h (tampon $KIT_CONFIG/autoupdate.stamp, écrit
#                       seulement après un fetch réussi : un échec réseau est retenté à la session suivante).
#   Profil cloud, ou CLAUDE_CODE_REMOTE=true : à chaque démarrage ou reprise.
# Ignoré (avec une ligne) si le dépôt du kit a des modifications locales ou n'est pas sur main ; en local cette ligne
# n'est affichée qu'une fois par 6 h (tampon autoupdate.skip.stamp), en cloud à chaque démarrage.
# L'entrée JSON du hook (stdin) est ignorée.
set -uo pipefail

[[ ${KIT_AUTOUPDATE:-1} == 0 ]] && exit 0

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || exit 0
KIT_HOME=$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd) || exit 0
KIT_CONFIG=${KIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit}
[[ -e $KIT_CONFIG/autoupdate.off ]] && exit 0
STAMP=$KIT_CONFIG/autoupdate.stamp
SKIP_STAMP=$KIT_CONFIG/autoupdate.skip.stamp
LOG=$KIT_CONFIG/autoupdate.log
INTERVAL=21600 # 6 h

command -v git >/dev/null 2>&1 || exit 0
[[ -d $KIT_HOME/.git || -f $KIT_HOME/.git ]] || exit 0

# Jamais interactif : ni mot de passe git, ni question ssh. On respecte un GIT_SSH_COMMAND ou core.sshCommand existant.
export GIT_TERMINAL_PROMPT=0
if [[ -z ${GIT_SSH_COMMAND:-} ]] && [[ -z $(git -C "$KIT_HOME" config --get core.sshCommand 2>/dev/null) ]]; then
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=6"
fi

tmo() { # secondes commande...
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else "$@"; fi
}
g() { tmo "$1" git -C "$KIT_HOME" "${@:2}" </dev/null 2>/dev/null; } # g <secondes> <args git>

stamp_age_ok() { # fichier : vrai si le tampon a moins de 6 h
  local last
  last=$(cat "$1" 2>/dev/null || echo 0)
  [[ $last =~ ^[0-9]+$ ]] || last=0
  (($(date +%s) - last < INTERVAL))
}
write_stamp() { mkdir -p "$KIT_CONFIG" 2>/dev/null && date +%s >"$1" 2>/dev/null; }

# Version épinglée : première ligne du fichier, sans espaces ; une valeur qui n'a pas la forme d'une référence est ignorée.
pin=""
if [[ -f $KIT_CONFIG/autoupdate.pin ]]; then
  pin=$(head -n 1 "$KIT_CONFIG/autoupdate.pin" 2>/dev/null | tr -d '[:space:]')
  [[ $pin =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$ ]] || pin="?"
fi

cloud=0
profile=$(cat "$KIT_CONFIG/profile" 2>/dev/null || echo local)
if [[ $profile == cloud || ${CLAUDE_CODE_REMOTE:-} == true ]]; then cloud=1; fi
if ((!cloud)) && stamp_age_ok "$STAMP"; then exit 0; fi

skip() { # message : une ligne, une fois par 6 h hors cloud
  if ((!cloud)); then
    if stamp_age_ok "$SKIP_STAMP"; then exit 0; fi
    write_stamp "$SKIP_STAMP"
  fi
  echo "$1"
  exit 0
}

branch=$(g 3 symbolic-ref --short -q HEAD) || branch=""
if [[ $pin == "?" ]]; then
  skip "kit : mise à jour auto ignorée (autoupdate.pin : référence invalide) dans $KIT_CONFIG."
elif [[ -n $pin ]]; then
  # Épinglé : sur main ou en HEAD détaché (un précédent épinglage) seulement, jamais sur la branche de travail de quelqu'un.
  if [[ -n $branch && $branch != main ]]; then
    skip "kit : version épinglée ignorée (branche « $branch », pas main) dans $KIT_HOME."
  fi
elif [[ $branch != main ]]; then
  skip "kit : mise à jour auto ignorée (branche « ${branch:-détachée} », pas main) dans $KIT_HOME."
fi
if [[ -n $(g 3 status --porcelain --untracked-files=no) ]]; then
  skip "kit : mise à jour auto ignorée (modifications locales dans $KIT_HOME)."
fi

# Sans timeout/gtimeout, les options http.lowSpeed* bornent quand même un fetch http(s) bloqué.
if [[ -n $pin ]]; then
  g 8 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8 fetch --quiet --tags origin || exit 0
else
  g 8 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8 fetch --quiet origin main || exit 0
fi
((cloud)) || write_stamp "$STAMP"

old=$(g 3 rev-parse HEAD) || exit 0
if [[ -n $pin ]]; then
  target=$(g 3 rev-parse --verify -q "refs/tags/$pin^{commit}") \
    || target=$(g 3 rev-parse --verify -q "refs/remotes/origin/$pin^{commit}") \
    || target=$(g 3 rev-parse --verify -q "$pin^{commit}") \
    || { echo "kit : version épinglée introuvable (« $pin » : ni tag, ni branche de origin, ni révision) dans $KIT_HOME."; exit 0; }
  [[ $old != "$target" ]] || exit 0
  if ! g 5 checkout --quiet --detach "$target"; then
    echo "kit : passage à la version épinglée « $pin » impossible dans $KIT_HOME."
    exit 0
  fi
elif ! g 5 merge --ff-only --quiet origin/main; then
  gd=$(g 3 rev-parse --git-dir) || gd=.git
  case $gd in /*) ;; *) gd=$KIT_HOME/$gd ;; esac
  if [[ -e $gd/index.lock ]]; then
    echo "kit : mise à jour auto impossible (verrou git présent : $gd/index.lock) dans $KIT_HOME."
  else
    echo "kit : mise à jour auto impossible (historique local divergent de origin/main) dans $KIT_HOME."
  fi
  exit 0
fi
new=$(g 3 rev-parse HEAD) || exit 0
[[ $old != "$new" ]] || exit 0

n=$(g 3 rev-list --count "$old..$new") || n="?"

# kit sync détaché : ni attendu, ni lié à la sortie du hook (sinon Claude attendrait la fermeture du tube).
mkdir -p "$KIT_CONFIG" 2>/dev/null
{ echo "--- $(date '+%F %T') kit sync après ${old:0:7}..${new:0:7}"; } >>"$LOG" 2>/dev/null
if command -v setsid >/dev/null 2>&1; then
  setsid nohup "$KIT_HOME/scripts/kit.sh" sync </dev/null >>"$LOG" 2>&1 &
else
  nohup "$KIT_HOME/scripts/kit.sh" sync </dev/null >>"$LOG" 2>&1 &
fi
disown 2>/dev/null || true

if [[ -n $pin ]]; then
  what="kit sur la version épinglée « $pin » : ${old:0:7} -> ${new:0:7}"
else
  what="kit mis à jour : ${old:0:7}..${new:0:7} ($n commits)"
fi
echo "$what — kit sync tourne en arrière-plan (journal : $LOG) : les réglages s'appliquent dans quelques secondes, CLAUDE.md et les commandes au prochain démarrage de session."
exit 0
