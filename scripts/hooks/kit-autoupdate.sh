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
#   autoupdate.pin      fichier $KIT_CONFIG/autoupdate.pin écrit par `kit autoupdate pin <réf>` : le SHA complet (40
#                       caractères hexadécimaux) sur la première ligne, le nom donné sur la seconde (affichage seulement).
#                       Le hook ne lit que ce SHA, il ne cherche aucun tag ni aucune branche. Il va chercher origin/main
#                       (seulement main) et, si le kit n'est pas déjà sur cette révision, le met en HEAD détaché dessus,
#                       à ces conditions : la révision est un ancêtre de origin/main (jamais de code non fusionné), son
#                       propre hook porte un KIT_PIN_FLOOR au moins égal à celui-ci (jamais de retour à une version qui
#                       ne sait pas épingler : le retour à la v1 est la procédure de docs/rollback-v1.md), arbre propre,
#                       aucune opération git en cours (bisect, rebase, merge, cherry-pick, revert), et HEAD sur main ou
#                       détaché sur la dernière révision épinglée ($KIT_CONFIG/autoupdate.pinned). Sinon une ligne, rien
#                       ne bouge. Retirer le fichier : `git checkout main` dans le kit.
#   --resolve <réf>     (appelé par `kit autoupdate pin`) va chercher origin/main et les tags, résout un tag, une branche
#                       de origin ou une révision (7 à 40 caractères hexadécimaux : un objet, jamais un nom de référence)
#                       en SHA complet, vérifie les conditions ci-dessus et l'imprime ; code 1 et message sinon.
#   Profil local/vps    une vérification réussie au plus toutes les 6 h (tampon $KIT_CONFIG/autoupdate.stamp, écrit
#                       seulement après un fetch réussi : un échec réseau est retenté à la session suivante).
#   Profil cloud, ou CLAUDE_CODE_REMOTE=true : à chaque démarrage ou reprise.
# Ignoré (avec une ligne) si le dépôt du kit a des modifications locales ou n'est pas sur main ; en local cette ligne
# n'est affichée qu'une fois par 6 h (tampon autoupdate.skip.stamp), en cloud à chaque démarrage.
# L'entrée JSON du hook (stdin) est ignorée.
set -uo pipefail

# Socle d'épinglage : un kit dont ce hook porte un numéro plus petit ne peut pas être épinglé. À augmenter quand un
# correctif de sécurité de l'épinglage ou des réglages gérés rend les versions précédentes dangereuses.
KIT_PIN_FLOOR=2

RESOLVE=0
if [[ ${1:-} == --resolve ]]; then RESOLVE=1; fi
if ((!RESOLVE)); then [[ ${KIT_AUTOUPDATE:-1} == 0 ]] && exit 0; fi

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || exit 0
KIT_HOME=$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd) || exit 0
KIT_CONFIG=${KIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit}
if ((!RESOLVE)); then [[ -e $KIT_CONFIG/autoupdate.off ]] && exit 0; fi
STAMP=$KIT_CONFIG/autoupdate.stamp
SKIP_STAMP=$KIT_CONFIG/autoupdate.skip.stamp
LOG=$KIT_CONFIG/autoupdate.log
INTERVAL=21600 # 6 h

command -v git >/dev/null 2>&1 || exit "$RESOLVE"
[[ -d $KIT_HOME/.git || -f $KIT_HOME/.git ]] || exit "$RESOLVE"

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

# Conditions d'un épinglage sur <sha> (message sur stderr, code 1 si refusé).
pin_check() {
  local sha=$1 tn
  g 3 cat-file -e "$sha^{commit}" || { echo "révision absente du dépôt local" >&2; return 1; }
  g 3 merge-base --is-ancestor "$sha" origin/main \
    || { echo "révision absente de l'historique de origin/main (branche non fusionnée ou historique réécrit)" >&2; return 1; }
  tn=$(g 3 show "$sha:scripts/hooks/kit-autoupdate.sh" | sed -n 's/^KIT_PIN_FLOOR=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [[ ! $tn =~ ^[0-9]{1,6}$ ]] || ((tn < KIT_PIN_FLOOR)); then
    echo "version antérieure au socle d'épinglage (KIT_PIN_FLOOR $KIT_PIN_FLOOR) : retour à la v1 = procédure de docs/rollback-v1.md" >&2
    return 1
  fi
}

if ((RESOLVE)); then
  ref=${2:-}
  [[ $ref =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$ ]] || { echo "référence invalide : $ref" >&2; exit 1; }
  g 20 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet --tags origin main \
    || { echo "fetch de origin impossible (réseau, ou tag déplacé sur origin) : rien n'est épinglé" >&2; exit 1; }
  sha=""
  if [[ $ref =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    # Hexadécimal : un objet, jamais un nom de tag ou de branche qui lui ressemblerait.
    ref=$(printf '%s' "$ref" | tr 'A-F' 'a-f')
    n=0
    for c in $(g 5 rev-parse --disambiguate="$ref"); do
      [[ $(g 3 cat-file -t "$c") == commit ]] || continue
      sha=$c; n=$((n + 1))
    done
    ((n == 1)) || { echo "révision « $ref » : $([[ $n == 0 ]] && echo introuvable || echo ambiguë)" >&2; exit 1; }
  else
    sha=$(g 3 rev-parse --verify -q "refs/tags/$ref^{commit}") \
      || sha=$(g 3 rev-parse --verify -q "refs/remotes/origin/$ref^{commit}") \
      || { echo "« $ref » introuvable (ni tag, ni branche de origin)" >&2; exit 1; }
  fi
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "révision illisible" >&2; exit 1; }
  why=$(pin_check "$sha" 2>&1) || { echo "« $ref » refusé : $why" >&2; exit 1; }
  echo "$sha"
  exit 0
fi

# Version épinglée : SHA complet sur la première ligne ; autre chose = fichier invalide (une ligne, rien ne bouge).
pin=""
PIN_FILE=$KIT_CONFIG/autoupdate.pin
PINNED_FILE=$KIT_CONFIG/autoupdate.pinned
if [[ -f $PIN_FILE ]]; then
  pin=$(head -n 1 "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')
  [[ $pin =~ ^[0-9a-f]{40}$ ]] || pin="?"
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
gd=$(g 3 rev-parse --git-dir) || gd=.git
case $gd in /*) ;; *) gd=$KIT_HOME/$gd ;; esac
for f in BISECT_LOG rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if [[ -e $gd/$f ]]; then skip "kit : mise à jour auto ignorée (opération git en cours : $f) dans $KIT_HOME."; fi
done
if [[ $pin == "?" ]]; then
  skip "kit : mise à jour auto ignorée (autoupdate.pin : SHA de 40 caractères attendu ; kit autoupdate pin <réf> le réécrit) dans $KIT_CONFIG."
elif [[ -n $pin ]]; then
  # Épinglé : sur main, ou détaché sur la dernière révision épinglée, jamais ailleurs.
  if [[ -n $branch && $branch != main ]]; then
    skip "kit : version épinglée ignorée (branche « $branch », pas main) dans $KIT_HOME."
  fi
  if [[ -z $branch ]]; then
    head_now=$(g 3 rev-parse HEAD) || exit 0
    recorded=$(head -n 1 "$PINNED_FILE" 2>/dev/null | tr -d '[:space:]')
    if [[ $head_now != "$pin" && $head_now != "$recorded" ]]; then
      skip "kit : version épinglée ignorée (HEAD détaché sur une autre révision que la dernière épinglée) dans $KIT_HOME."
    fi
  fi
elif [[ $branch != main ]]; then
  skip "kit : mise à jour auto ignorée (branche « ${branch:-détachée} », pas main) dans $KIT_HOME."
fi
# A registry modified only in its generated profiles table (older kit sync versions rewrote it in the clone) is restored.
if [[ -n $(g 3 status --porcelain --untracked-files=no -- global/skills-registry.md) ]]; then
  strip_gen='/<!-- kit:profiles:start -->/ { skip = 1; next } /<!-- kit:profiles:end -->/ { skip = 0; next } !skip { print }'
  head_txt=$(g 3 show HEAD:global/skills-registry.md | awk "$strip_gen")
  cur_txt=$(awk "$strip_gen" "$KIT_HOME/global/skills-registry.md" 2>/dev/null)
  if [[ -n $head_txt && $head_txt == "$cur_txt" ]]; then g 3 checkout -q HEAD -- global/skills-registry.md; fi
fi
if [[ -n $(g 3 status --porcelain --untracked-files=no) ]]; then
  skip "kit : mise à jour auto ignorée (modifications locales dans $KIT_HOME)."
fi

# Sans timeout/gtimeout, les options http.lowSpeed* bornent quand même un fetch http(s) bloqué.
# Seulement main : la révision épinglée est un SHA, aucun tag n'est lu (un tag déplacé sur origin n'a aucun effet).
if ! g 8 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8 fetch --quiet origin main; then
  [[ -z $pin ]] || echo "kit : version épinglée non vérifiée (fetch de origin impossible, réseau ?) dans $KIT_HOME."
  exit 0
fi
((cloud)) || write_stamp "$STAMP"

old=$(g 3 rev-parse HEAD) || exit 0
if [[ -n $pin ]]; then
  if [[ $old == "$pin" ]]; then
    [[ -n $branch ]] || { mkdir -p "$KIT_CONFIG" 2>/dev/null; printf '%s\n' "$pin" >"$PINNED_FILE" 2>/dev/null; }
    exit 0
  fi
  if ! why=$(pin_check "$pin" 2>&1); then
    echo "kit : version épinglée refusée ($why) dans $KIT_HOME."
    exit 0
  fi
  if ! g 5 checkout --quiet --detach "$pin"; then
    echo "kit : passage à la version épinglée impossible dans $KIT_HOME."
    exit 0
  fi
  mkdir -p "$KIT_CONFIG" 2>/dev/null; printf '%s\n' "$pin" >"$PINNED_FILE" 2>/dev/null
elif ! g 5 merge --ff-only --quiet origin/main; then
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
  what="kit sur la version épinglée ${pin:0:7} : ${old:0:7} -> ${new:0:7}"
else
  what="kit mis à jour : ${old:0:7}..${new:0:7} ($n commits)"
fi
echo "$what — kit sync tourne en arrière-plan (journal : $LOG) : les réglages s'appliquent dans quelques secondes, CLAUDE.md et les commandes au prochain démarrage de session."
exit 0
