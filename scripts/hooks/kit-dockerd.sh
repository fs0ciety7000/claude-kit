#!/usr/bin/env bash
# Hook SessionStart (startup|resume) : en session cloud, démarre le démon Docker s'il est installé mais arrêté.
# Pourquoi : dans un conteneur claude.ai/code, dockerd n'est pas lancé par défaut. Le démarrer comme tâche de fond de
# Claude le soumet à la limite de durée de ces tâches (30 min par défaut, 2 h au plus) et le perd à chaque redémarrage
# du conteneur. Ce hook le lance détaché (setsid/nohup), hors des tâches de Claude, et le relance à chaque reprise.
# Ne casse jamais le démarrage : sort toujours avec 0, ne pose aucune question. Une ligne au plus sur la sortie
# standard (ajoutée au contexte de Claude), rien si Docker tourne déjà ou n'est pas installé.
#
# Réglages :
#   KIT_DOCKERD=0     désactive le hook.
#   KIT_DOCKERD=1     force le hook hors session cloud (par défaut : seulement si CLAUDE_CODE_REMOTE=true).
#   KIT_DOCKERD_WAIT  secondes d'attente de la socket (défaut 15 ; le hook a 25 s dans settings.json).
# Journal du démon : $KIT_CONFIG/dockerd.log. L'entrée JSON du hook (stdin) est ignorée.
set -uo pipefail

[[ ${KIT_DOCKERD:-} == 0 ]] && exit 0
[[ ${CLAUDE_CODE_REMOTE:-} == true || ${KIT_DOCKERD:-} == 1 ]] || exit 0

command -v dockerd >/dev/null 2>&1 || exit 0
command -v docker >/dev/null 2>&1 || exit 0

KIT_CONFIG=${KIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit}
LOG=$KIT_CONFIG/dockerd.log
WAIT=${KIT_DOCKERD_WAIT:-15}

docker_up() { timeout 3 docker info >/dev/null 2>&1; }

docker_up && exit 0

# Root requis pour dockerd (cas des conteneurs claude.ai/code). Sans root, on ne tente rien.
[[ $(id -u) == 0 ]] || { echo "kit-dockerd : Docker est arrêté et la session n'est pas root, rien lancé."; exit 0; }

# Un démon déjà en cours de démarrage : on attend la socket au lieu d'en lancer un second.
if ! pgrep -x dockerd >/dev/null 2>&1; then
  mkdir -p "$KIT_CONFIG" 2>/dev/null
  # Socket ou pid laissés par un démon mort avec le conteneur précédent.
  [[ -S /var/run/docker.sock ]] && rm -f /var/run/docker.sock 2>/dev/null
  rm -f /var/run/docker.pid 2>/dev/null
  setsid nohup dockerd >>"$LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true
fi

for ((i = 0; i < WAIT; i++)); do
  docker_up && { echo "kit-dockerd : démon Docker démarré (journal : $LOG)."; exit 0; }
  sleep 1
done
echo "kit-dockerd : Docker lancé mais pas encore prêt après ${WAIT} s (journal : $LOG)."
exit 0
