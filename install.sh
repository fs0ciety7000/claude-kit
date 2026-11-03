#!/usr/bin/env bash
# Installe le kit sur cette machine (Garuda/Arch, ou VPS Debian/Ubuntu).
# Usage : ./install.sh [--vps|--cloud] [--deps] [--no-secrets]
#   --vps         profil serveur : permissions plus strictes (modifications validées une à une)
#   --cloud       session claude.ai/code : accepte root, sans sops/age (implique --no-secrets),
#                 installe aussi le profil global « meta » (find-skills) au mieux
#   --deps        installe les dépendances avec sudo (pacman ou apt) ; sans ce flag, vérifie seulement
#   --no-secrets  ne crée pas la clé age
# Relançable sans risque : rien d'existant n'est écrasé sans sauvegarde.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
export KIT_HOME=$HERE
# shellcheck source=scripts/lib.sh
source "$HERE/scripts/lib.sh"

VPS=0 CLOUD=0 DEPS=0 SECRETS=1
for a in "$@"; do
  case $a in
    --vps) VPS=1 ;;
    --cloud) CLOUD=1; SECRETS=0 ;;
    --deps) DEPS=1 ;;
    --no-secrets) SECRETS=0 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "option inconnue : $a" ;;
  esac
done

((VPS && CLOUD)) && die "--vps et --cloud sont incompatibles"
# En cloud, le conteneur tourne en root et il est jetable : c'est attendu.
((CLOUD || EUID != 0)) || die "Ne lance pas ce script en root : le kit s'installe dans ton \$HOME d'utilisateur (et Claude ne doit pas tourner en root)."

# 1) Dépendances
missing=()
deps=(git node npm jq age sops)
((CLOUD)) && deps=(git node npm jq)
for t in "${deps[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if ((${#missing[@]})); then
  if ((DEPS)); then
    if command -v pacman >/dev/null 2>&1; then
      info "pacman : installation des dépendances (sudo)"
      sudo pacman -S --needed --noconfirm git nodejs npm jq sops age github-cli ripgrep
    elif command -v apt-get >/dev/null 2>&1; then
      info "apt : installation des dépendances (sudo)"
      sudo apt-get install -y git nodejs npm jq age ripgrep curl
      warn "sops n'est pas dans apt : télécharge le binaire sur https://github.com/getsops/sops/releases et vérifie son checksum."
    else
      die "Gestionnaire de paquets non reconnu : installe à la main : ${missing[*]}"
    fi
  else
    warn "Manquant : ${missing[*]}"
    echo "  Arch/Garuda : sudo pacman -S --needed git nodejs npm jq sops age github-cli ripgrep   (ou relance avec --deps)"
  fi
fi
((CLOUD)) || command -v claude >/dev/null 2>&1 || warn "Claude Code n'est pas installé : voir README.md (section Installer Claude Code)."

# 2) Liens et réglages
mkdir -p "$KIT_CONFIG" "$HOME/.local/bin"
ln -sfn "$HERE/scripts/kit.sh" "$HOME/.local/bin/kit"
# En cloud, ~/.local/bin n'est pas forcément dans le PATH : on expose aussi kit dans /usr/local/bin.
if ((CLOUD)) && [[ -w /usr/local/bin ]]; then ln -sfn "$HERE/scripts/kit.sh" /usr/local/bin/kit; fi
if ((VPS)); then echo vps >"$KIT_CONFIG/profile"
elif ((CLOUD)); then echo cloud >"$KIT_CONFIG/profile"
else echo local >"$KIT_CONFIG/profile"; fi
link_global
apply_settings
ok "agents, commandes, skills et réglages liés dans $CLAUDE_HOME (profil : $(cat "$KIT_CONFIG/profile"))"

# 3) Secrets
if ((SECRETS)) && command -v sops >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  "$HERE/scripts/secrets.sh" init
fi

((CLOUD)) || case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "Ajoute ~/.local/bin à ton PATH (ex. dans ~/.bashrc ou ~/.config/fish/config.fish)." ;; esac

if ((CLOUD)); then
  # find-skills sert à chercher un skill manquant ; un échec réseau ne doit pas bloquer la session.
  "$HERE/scripts/kit.sh" skills install -g meta >/dev/null 2>&1 \
    && ok "profil global « meta » installé" \
    || warn "profil « meta » non installé (réseau ?) : kit skills install -g meta"
  cat <<'MSG'

Kit installé pour cette session cloud (agents, skills, commandes, CLAUDE.md, hook anti-fuite).
  Dans un projet : /new-project <description>, ou kit project add <type>...  (liste : kit project types)
  Pas de sops/age ici : les secrets passent par les variables de l'environnement cloud.
MSG
  exit 0
fi

cat <<EOF

Installation terminée. Prochaines étapes :
  1. kit doctor                                  vérifie tout
  2. kit secrets add CLOUDFLARE_API_TOKEN -g     (idem CLOUDFLARE_ACCOUNT_ID, COOLIFY_ACCESS_TOKEN, COOLIFY_BASE_URL)
  3. kit mcp setup                               déclare le MCP Coolify avec jeton injecté
  4. kit skills install -g meta                  puis, par projet : kit skills install web cloud ...
  5. Dans Claude Code : les commandes /plugin de PLUGINS.md (marketplaces)
  6. kit list                                    voir ce qui est disponible
EOF
if ((VPS)); then
  cat <<'EOF'

VPS : génère ici ta propre clé (déjà fait) et autorise-la depuis ta machine principale :
  sur le VPS      : kit secrets pubkey
  sur ta machine  : kit secrets add-recipient <clé publique du VPS>   puis git push du dépôt de secrets
Ne copie JAMAIS ~/.config/sops/age/keys.txt d'une machine à l'autre. Connecte Claude Code sur le VPS lui-même.
EOF
fi
