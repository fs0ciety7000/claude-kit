#!/usr/bin/env bash
# Test de scripts/backup-v1.sh dans un conteneur jetable (bash 3.2, Alpine) avec un HOME factice rempli de faux fichiers,
# dont des leurres de secrets (identifiants, clé age, fichiers d'environnement, clés ssh...). Rien ne touche le vrai HOME.
#
# Usage : scripts/test/backup-v1-test.sh            lance le test dans Docker (image construite au premier passage)
#         scripts/test/backup-v1-test.sh --local    lance directement ici (HOME factice dans un dossier temporaire ;
#                                                   outils GNU ou BSD requis : tar, find, grep, git, jq)
# Variables : BACKUP_TEST_IMAGE (défaut claude-kit-backup-test:bash3.2), BACKUP_TEST_BUILD_ARGS (options de docker build,
#             ex. --network host derrière un proxy).
# Les leurres sont fabriqués ici, dans le conteneur : aucun faux secret n'est écrit dans le dépôt, et les jetons de test
# sont assemblés à l'exécution pour ne pas déclencher les détecteurs de secrets.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MODE=${1:-docker}

if [ "$MODE" = docker ]; then
  command -v docker >/dev/null 2>&1 || { echo "docker introuvable : relance avec --local" >&2; exit 2; }
  IMAGE=${BACKUP_TEST_IMAGE:-claude-kit-backup-test:bash3.2}
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "→ construction de l'image $IMAGE (bash 3.2 + outils GNU, bsdtar)"
    # shellcheck disable=SC2086
    docker build ${BACKUP_TEST_BUILD_ARGS:-} -t "$IMAGE" - <<'EOF' || exit 2
FROM bash:3.2@sha256:2556c2da19c32c1614d318645c73a7bf64d38be21cf69e98e3ca51f053983719
RUN apk add --no-cache tar findutils grep coreutils git jq libarchive-tools diffutils
EOF
  fi
  exec docker run --rm -v "$ROOT:/kit:ro" "$IMAGE" bash /kit/scripts/test/backup-v1-test.sh --inner
fi

# ---------------------------------------------------------------------------------------------------------------------
# Inner part (runs in the container, or locally with --local)

BACKUP=$ROOT/scripts/backup-v1.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset KIT_HOME XDG_CONFIG_HOME CLAUDE_HOME CLAUDE_CODE_REMOTE KIT_AUTOUPDATE TMPDIR
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

pass=0; fail=0
ok_() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ko_() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok_ "$d"; else ko_ "$d"; fi; }
section() { printf '\n== %s ==\n' "$1"; }
in_list() { grep -qxF -- "$2" "$1"; }          # file line
not_in_list() { ! grep -qF -- "$2" "$1"; }     # substring
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo "bash : ${BASH_VERSION}   tar : $(tar --version 2>&1 | head -1)"

# --- Fake machine ------------------------------------------------------------------------------------------------------
H=$TMP/home
export HOME=$H
mkdir -p "$H"
MARK=DECOY-SECRET-MARKER

mkdir -p "$H/.local/bin" "$H/.claude"/{commands,agents,skills/own,hooks,plugins/cache/big,plugins/marketplaces/m,plans,projects/p,shell-snapshots,todos,statsig,cache,backups}
mkdir -p "$H/.config/claude-kit"/{secrets,hooks,age} "$H/.config/sops/age" "$H/.config/gh" "$H/.ssh"
mkdir -p "$H/dotfiles/skills/linked" "$H/.kit/context/proj"

# Fake kit repository with an upstream, a legacy/v1 branch, then local work (diff, unpushed commit, untracked file).
K=$H/claude-kit
git init -q --bare -b main "$TMP/origin.git"
mkdir -p "$K/scripts" "$K/global/agents"
git -C "$K" init -q -b main
cat >"$K/scripts/kit.sh" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in doctor) echo "✓ fake doctor"; exit 0 ;; *) echo usage >&2; exit 1 ;; esac
EOF
chmod +x "$K/scripts/kit.sh"
echo "# global v1" >"$K/global/CLAUDE.md"
echo "agent a" >"$K/global/agents/a.md"
git -C "$K" add -A && git -C "$K" commit -q -m v1
git -C "$K" remote add origin "https://tester:${MARK}-URL@example.invalid/org/claude-kit.git"
git -C "$K" push -q "$TMP/origin.git" main 2>/dev/null
git -C "$K" push -q "$TMP/origin.git" main:legacy/v1 2>/dev/null
git -C "$K" fetch -q "$TMP/origin.git" 'refs/heads/*:refs/remotes/origin/*' 2>/dev/null
git -C "$K" branch -q --set-upstream-to=origin/main main 2>/dev/null
echo "unpushed" >"$K/global/unpushed.md"; git -C "$K" add -A; git -C "$K" commit -q -m unpushed
echo "local edit" >>"$K/global/CLAUDE.md"
echo "untracked agent" >"$K/global/agents/new.md"
printf '%s' "$MARK-UNTRACKED-ENV" >"$K/.env.local"   # untracked decoy inside the kit: must not be archived
ln -s "$K/scripts/kit.sh" "$H/.local/bin/kit"
KIT_COMMIT=$(git -C "$K" rev-parse HEAD)

# ~/.claude : included
echo '{"permissions":{"allow":["Bash(ls)"]}}' >"$H/.claude/settings.json"
echo '{"bindings":[]}' >"$H/.claude/keybindings.json"
printf '#!/bin/sh\necho status\n' >"$H/.claude/statusline.sh"
echo "# command" >"$H/.claude/commands/foo.md"
echo "# own skill" >"$H/.claude/skills/own/SKILL.md"
echo "# plan" >"$H/.claude/plans/p.md"
printf '#!/bin/sh\ntrue\n' >"$H/.claude/hooks/x.sh"
echo '{"plugins":{}}' >"$H/.claude/plugins/installed_plugins.json"
echo '{}' >"$H/.claude/plugins/known_marketplaces.json"
echo '{}' >"$H/.claude/plugins/config.json"
ln -s "$K/global/CLAUDE.md" "$H/.claude/CLAUDE.md"
ln -s "$K/global/agents/a.md" "$H/.claude/agents/a.md"
ln -s ../../dotfiles/skills/linked "$H/.claude/skills/linked"          # relative link to a dir outside ~/.claude
echo "# linked skill" >"$H/dotfiles/skills/linked/SKILL.md"
ln -s "$K/scripts/kit.sh" "$H/.config/claude-kit/hooks/kit-autoupdate.sh"
# ~/.claude : excluded as bulky, regenerable or transcripts
echo "transcript-content" >"$H/.claude/projects/p/s.jsonl"
echo "history-content" >"$H/.claude/history.jsonl"
echo "snap" >"$H/.claude/shell-snapshots/a.sh"
echo "{}" >"$H/.claude/todos/t.json"
echo "{}" >"$H/.claude/statsig/s.json"
echo "c" >"$H/.claude/cache/c"
echo "js" >"$H/.claude/plugins/cache/big/x.js"
echo "readme" >"$H/.claude/plugins/marketplaces/m/README.md"
# Decoy secrets (each carries the marker, except where the name alone is the test)
printf '{"claudeAiOauth":"%s-CRED"}' "$MARK" >"$H/.claude/.credentials.json"
printf '{"mcpServers":{"coolify":{"type":"stdio","command":"npx","args":["x"],"env":{"T":"%s-MCP"}}}}' "$MARK" >"$H/.claude.json"
printf '{"x":"%s-BACKUP"}' "$MARK" >"$H/.claude/backups/.claude.json.backup.1"
printf '{"env":{"MY_API_TOKEN":"%s-ENVVALUE"}}' "$MARK" >"$H/.claude/settings.local.json"      # content rule
printf 'ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" >"$H/.claude/notes-pat.md"                   # content rule
printf -- '-----BEGIN %s PRIVATE KEY-----\nxx\n' RSA >"$H/.claude/skills/own/notes-pem.txt"      # content rule
echo "$MARK-NAME" >"$H/.claude/skills/own/id_rsa"
echo "$MARK-NAME" >"$H/.claude/skills/own/server.pem"
echo "$MARK-NAME" >"$H/.claude/skills/own/deploy.key"
echo "$MARK-NAME" >"$H/.claude/skills/own/design-tokens.md"
echo "$MARK-NAME" >"$H/.claude/skills/own/.env"
echo "$MARK-NAME" >"$H/.env"
# ~/.config/claude-kit : included, then decoys
echo local >"$H/.config/claude-kit/profile"
echo "age1publicrecipientdecoy" >"$H/.config/claude-kit/recipients"
echo "$MARK-ENC" >"$H/.config/claude-kit/secrets/global.enc.json"
echo "$MARK-AGE1" >"$H/.config/claude-kit/age/key.txt"
echo "$MARK-AGE2" >"$H/.config/sops/age/keys.txt"
echo "$MARK-GH" >"$H/.config/gh/hosts.yml"
echo "$MARK-SSH" >"$H/.ssh/id_ed25519"
echo "log" >"$H/.config/claude-kit/autoupdate.log"
# ~/.kit/context : a git clone (its .git is not archived) with a decoy .env
git -C "$H/.kit/context/proj" init -q -b main
echo "# knowledge" >"$H/.kit/context/proj/KNOWLEDGE.md"
echo "$MARK-CTXENV" >"$H/.kit/context/proj/.env"
git -C "$H/.kit/context/proj" add KNOWLEDGE.md && git -C "$H/.kit/context/proj" commit -q -m c
git -C "$H/.kit/context/proj" remote add origin "https://u:${MARK}-CTXURL@example.invalid/org/proj.git"
chmod 600 "$H/.config/sops/age/keys.txt" "$H/.ssh/id_ed25519"

home_state() { (cd "$H" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }

# --- 1) Dry run ----------------------------------------------------------------------------------------------------------
section "--dry-run"
before=$(home_state)
OUT_DRY=$TMP/out-dry
dry_out=$(bash "$BACKUP" --dry-run --out "$OUT_DRY" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok_ "code de sortie 0" || ko_ "code de sortie 0" "rc=$rc"
[ ! -e "$OUT_DRY" ] && ok_ "le dossier de destination n'est pas créé" || ko_ "le dossier de destination n'est pas créé"
[ "$(home_state)" = "$before" ] && ok_ "HOME inchangé (aucun fichier ajouté ni modifié)" || ko_ "HOME inchangé"
case $dry_out in *"dry-run terminé"*) ok_ "rapport affiché" ;; *) ko_ "rapport affiché" ;; esac
[ ! -e "$TMP/out" ] && [ ! -e "$H/claude-kit-backups" ] && ok_ "aucune archive créée (ni destination par défaut)" || ko_ "aucune archive créée"

# --- 2) Real run -----------------------------------------------------------------------------------------------------------
section "sauvegarde (sans transcripts)"
OUT=$TMP/out
real_out=$(bash "$BACKUP" --out "$OUT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok_ "code de sortie 0" || ko_ "code de sortie 0" "$(echo "$real_out" | tail -5)"
ARCH=$(ls "$OUT"/v1-*.tar.gz 2>/dev/null | head -1)
[ -n "$ARCH" ] || { ko_ "archive créée"; echo "$real_out"; echo; echo "Résultat : $pass ok, $fail échec(s)"; exit 1; }
BASE=$(basename "$ARCH")
echo "$BASE" | grep -qE '^v1-[0-9a-f]{8}-[0-9]{8}-[0-9]{6}\.tar\.gz$' && ok_ "nom v1-<hash>-<horodatage>.tar.gz" || ko_ "nom de l'archive" "$BASE"
[ "$(mode_of "$ARCH")" = 600 ] && ok_ "archive en mode 600" || ko_ "archive en mode 600" "$(mode_of "$ARCH")"
[ "$(mode_of "$OUT")" = 700 ] && ok_ "dossier de destination en mode 700" || ko_ "dossier en mode 700" "$(mode_of "$OUT")"
[ "$(mode_of "$ARCH.sha256")" = 600 ] && ok_ ".sha256 en mode 600" || ko_ ".sha256 en mode 600"
[ -z "$(find "$OUT" -name '.partial*' | head -1)" ] && ok_ "aucun résidu temporaire dans la destination" || ko_ "résidu temporaire"
(cd "$OUT" && { sha256sum -c "$BASE.sha256" || shasum -a 256 -c "$BASE.sha256"; }) >/dev/null 2>&1 && ok_ "somme sha256 vérifiée" || ko_ "somme sha256 vérifiée"
cp "$ARCH" "$TMP/tampered.tar.gz"; printf 'x' >>"$TMP/tampered.tar.gz"
echo "$(cut -d' ' -f1 "$ARCH.sha256")  tampered.tar.gz" >"$TMP/tampered.sha256"
(cd "$TMP" && sha256sum -c tampered.sha256) >/dev/null 2>&1 && ko_ "une archive altérée est détectée" || ok_ "une archive altérée est détectée"

LIST=$TMP/list.txt
tar -tzf "$ARCH" | sed 's#^\./##; s#/$##' >"$LIST"

section "fichiers inclus"
for p in .claude/settings.json .claude/keybindings.json .claude/statusline.sh .claude/commands/foo.md .claude/skills/own/SKILL.md \
  .claude/plans/p.md .claude/hooks/x.sh .claude/plugins/installed_plugins.json .claude/plugins/known_marketplaces.json \
  .claude/plugins/config.json .claude/CLAUDE.md .claude/agents/a.md .claude/skills/linked dotfiles/skills/linked/SKILL.md \
  .config/claude-kit/profile .config/claude-kit/recipients .config/claude-kit/hooks/kit-autoupdate.sh \
  .kit/context/proj/KNOWLEDGE.md \
  .claude-kit-backup-v1/MANIFEST.txt .claude-kit-backup-v1/kit-git.txt .claude-kit-backup-v1/kit-doctor.txt \
  .claude-kit-backup-v1/versions.txt .claude-kit-backup-v1/claude-symlinks.txt .claude-kit-backup-v1/claude-json-note.txt \
  .claude-kit-backup-v1/kit-context-git.txt .claude-kit-backup-v1/kit-local-changes.patch \
  .claude-kit-backup-v1/kit-unpushed-commits.patch .claude-kit-backup-v1/kit-untracked/global/agents/new.md; do
  if in_list "$LIST" "$p"; then ok_ "présent : $p"; else ko_ "présent : $p"; fi
done
tv=$(tar -tvzf "$ARCH"); case $tv in *"-> "*"claude-kit/global/CLAUDE.md"*) tv_ok=1 ;; *) tv_ok=0 ;; esac
[ "$tv_ok" = 1 ] && ok_ "CLAUDE.md archivé comme lien symbolique vers le kit" || ko_ "lien CLAUDE.md conservé"

section "secrets et fichiers volumineux absents"
for p in .credentials.json .claude.json age/key.txt sops/age .env id_rsa id_ed25519 .pem .key .config/gh .ssh global.enc.json projects/ \
  history.jsonl shell-snapshots todos/ statsig cache/ backups/ autoupdate.log plugins/marketplaces token settings.local.json \
  notes-pat.md notes-pem.txt; do
  if not_in_list "$LIST" "$p"; then ok_ "absent : $p"; else ko_ "absent : $p" "$(grep -F -- "$p" "$LIST" | head -2 | tr '\n' ' ')"; fi
done
EX=$TMP/extract; mkdir -p "$EX"; tar -xzf "$ARCH" -C "$EX"
hits=$(grep -rl "$MARK" "$EX" 2>/dev/null | wc -l | tr -d ' ')
[ "$hits" = 0 ] && ok_ "aucun leurre de secret dans le contenu extrait ($MARK)" || ko_ "aucun leurre dans le contenu" "$(grep -rl "$MARK" "$EX" | head -3)"
grep -rq "example.invalid" "$EX/.claude-kit-backup-v1/kit-git.txt" && ok_ "URL du remote conservée sans identifiants" || ko_ "URL du remote conservée"
echo "$real_out" | grep -q 'OMIS' && ok_ "fichiers au contenu suspect signalés à l'écran" || ko_ "fichiers suspects signalés"
grep -q 'settings.local.json' "$EX/.claude-kit-backup-v1/MANIFEST.txt" && ok_ "fichiers omis listés dans MANIFEST.txt (noms seulement)" || ko_ "omis listés dans MANIFEST.txt"
grep -q 'coolify' "$EX/.claude-kit-backup-v1/claude-json-note.txt" && ok_ "serveurs MCP listés par nom seulement" || ko_ "serveurs MCP listés"

section "métadonnées du kit"
GITTXT=$EX/.claude-kit-backup-v1/kit-git.txt
grep -q "commit : $KIT_COMMIT" "$GITTXT" && ok_ "commit du kit enregistré" || ko_ "commit du kit enregistré"
grep -q 'branch : main' "$GITTXT" && ok_ "branche enregistrée" || ko_ "branche enregistrée"
grep -q 'ahead/behind.*1.0' "$GITTXT" && ok_ "commit non poussé détecté (ahead 1)" || ko_ "ahead/behind" "$(grep ahead "$GITTXT")"
grep -q '^   M global/CLAUDE.md' "$GITTXT" && grep -q '^  ?? global/agents/new.md' "$GITTXT" && ok_ "git status --porcelain enregistré" || ko_ "git status enregistré"
grep -q 'HEAD est dans legacy/v1 : non' "$GITTXT" && ok_ "écart avec legacy/v1 signalé" || ko_ "écart avec legacy/v1"
grep -q 'local edit' "$EX/.claude-kit-backup-v1/kit-local-changes.patch" && ok_ "diff local conservé" || ko_ "diff local conservé"
grep -q 'unpushed' "$EX/.claude-kit-backup-v1/kit-unpushed-commits.patch" && ok_ "commits non poussés conservés (patch)" || ko_ "commits non poussés conservés"
grep -q 'fake doctor' "$EX/.claude-kit-backup-v1/kit-doctor.txt" && ok_ "sortie de kit doctor conservée" || ko_ "kit doctor conservé"
grep -q 'kit --version : non géré' "$EX/.claude-kit-backup-v1/kit-doctor.txt" && ok_ "absence de kit --version consignée" || ko_ "kit --version consigné"
grep -q 'skills/linked -> ../../dotfiles/skills/linked' "$EX/.claude-kit-backup-v1/claude-symlinks.txt" && ok_ "cibles des liens de ~/.claude listées" || ko_ "cibles des liens listées"

# --- 3) Restore into a fresh HOME ------------------------------------------------------------------------------------------
verify_restore() { # archive label
  local a=$1 l=$2 H2 exp n bad f
  H2=$TMP/restore-$l; mkdir -p "$H2"
  tar -xzf "$a" -C "$H2" || { ko_ "[$l] extraction dans un HOME vierge"; return; }
  ok_ "[$l] extraction dans un HOME vierge"
  exp=$TMP/exp-$l.txt
  tar -tzf "$a" | sed 's#^\./##; s#/$##' | grep -v '^\.claude-kit-backup-v1' | LC_ALL=C sort >"$exp"
  bad=0; n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -d "$H/$f" ] && [ ! -L "$H/$f" ] && continue
    n=$((n + 1))
    if [ -L "$H/$f" ]; then
      [ -L "$H2/$f" ] && [ "$(readlink "$H/$f")" = "$(readlink "$H2/$f")" ] || { bad=$((bad + 1)); echo "       lien différent : $f"; }
    else
      cmp -s "$H/$f" "$H2/$f" || { bad=$((bad + 1)); echo "       contenu différent : $f"; }
    fi
  done <"$exp"
  [ "$bad" -eq 0 ] && ok_ "[$l] $n entrées restaurées à l'identique (contenu et liens)" || ko_ "[$l] restauration à l'identique" "$bad écart(s)"
  extra=$(cd "$H2" && find . ! -type d | sed 's#^\./##' | grep -v '^\.claude-kit-backup-v1' | LC_ALL=C sort | grep -Fxv -f "$exp")
  [ -z "$extra" ] && ok_ "[$l] rien d'autre que le contenu archivé dans le HOME restauré" || ko_ "[$l] fichiers en trop" "$extra"
}
section "restauration (tar -xzf -C HOME vierge)"
verify_restore "$ARCH" gnu

# --- 4) --with-transcripts -------------------------------------------------------------------------------------------------
section "--with-transcripts"
sleep 1
OUT2=$TMP/out2
t_out=$(bash "$BACKUP" --with-transcripts --out "$OUT2" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok_ "code de sortie 0" || ko_ "code de sortie 0" "$(echo "$t_out" | tail -3)"
ARCH2=$(ls "$OUT2"/v1-*.tar.gz 2>/dev/null | head -1)
tar -tzf "$ARCH2" | sed 's#^\./##; s#/$##' >"$TMP/list2.txt"
for p in .claude/projects/p/s.jsonl .claude/history.jsonl .claude/shell-snapshots/a.sh .claude/todos/t.json; do
  in_list "$TMP/list2.txt" "$p" && ok_ "présent avec --with-transcripts : $p" || ko_ "présent avec --with-transcripts : $p"
done
for p in .credentials.json .claude.json backups/ statsig cache/ global.enc.json age/key.txt .env id_ed25519 settings.local.json; do
  not_in_list "$TMP/list2.txt" "$p" && ok_ "toujours absent : $p" || ko_ "toujours absent : $p"
done
echo "$t_out" | grep -q 'Transcripts inclus' && ok_ "avertissement sur les secrets dans les conversations" || ko_ "avertissement transcripts"

# --- 5) Safety net: a path-rule bug must delete the archive ----------------------------------------------------------------
section "garde-fou final (règle de nom contournée volontairement)"
BROKEN=$TMP/backup-broken.sh
sed 's#^grep -viE "\$RE_SECRET" "\$RAW" >"\$WORK/f1.txt"#cp "$RAW" "$WORK/f1.txt"#' "$BACKUP" >"$BROKEN"
if cmp -s "$BACKUP" "$BROKEN"; then
  ko_ "variante défectueuse fabriquée" "motif sed non trouvé dans backup-v1.sh"
else
  OUT3=$TMP/out3
  sleep 1
  b_out=$(bash "$BROKEN" --out "$OUT3" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok_ "sortie en erreur (code $rc)" || ko_ "sortie en erreur"
  [ -z "$(ls "$OUT3"/*.tar.gz 2>/dev/null)" ] && ok_ "archive supprimée" || ko_ "archive supprimée"
  [ -z "$(ls "$OUT3"/*.sha256 2>/dev/null)" ] && ok_ "aucune somme de contrôle orpheline" || ko_ "somme orpheline"
  echo "$b_out" | grep -qi 'SUPPRIMÉE' && ok_ "message explicite" || ko_ "message explicite"
fi

# --- 6) Options and refusals -----------------------------------------------------------------------------------------------
section "options"
bash "$BACKUP" --nope >/dev/null 2>&1 && ko_ "option inconnue refusée" || ok_ "option inconnue refusée"
bash "$BACKUP" --out "$H/.claude/x" >/dev/null 2>&1 && ko_ "--out dans ~/.claude refusé" || ok_ "--out dans ~/.claude refusé"
bash "$BACKUP" --help 2>&1 | grep -q 'dry-run' && ok_ "--help" || ko_ "--help"
# Default destination: ~/claude-kit-backups, created in mode 700.
sleep 1
bash "$BACKUP" >/dev/null 2>&1
[ "$(mode_of "$H/claude-kit-backups")" = 700 ] && ls "$H"/claude-kit-backups/v1-*.tar.gz >/dev/null 2>&1 && ok_ "destination par défaut ~/claude-kit-backups (700)" || ko_ "destination par défaut"
# The default destination must not leak into a following backup.
sleep 1
bash "$BACKUP" --out "$TMP/out4" >/dev/null 2>&1
tar -tzf "$(ls "$TMP"/out4/v1-*.tar.gz | head -1)" >"$TMP/list4.txt"
not_in_list "$TMP/list4.txt" 'claude-kit-backups' && ok_ "les sauvegardes précédentes ne sont pas réarchivées" || ko_ "les sauvegardes précédentes ne sont pas réarchivées"

# --- 7) bsdtar (macOS) ------------------------------------------------------------------------------------------------------
section "bsdtar (comme sur macOS)"
if command -v bsdtar >/dev/null 2>&1; then
  mkdir -p "$TMP/bsdbin"; ln -sf "$(command -v bsdtar)" "$TMP/bsdbin/tar"
  sleep 1
  b_out=$(PATH="$TMP/bsdbin:$PATH" bash "$BACKUP" --out "$TMP/out-bsd" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok_ "sauvegarde avec bsdtar" || ko_ "sauvegarde avec bsdtar" "$(echo "$b_out" | tail -3)"
  ARCH_B=$(ls "$TMP"/out-bsd/v1-*.tar.gz 2>/dev/null | head -1)
  if [ -n "$ARCH_B" ]; then
    tar -tzf "$ARCH_B" | sed 's#^\./##; s#/$##' >"$TMP/list-bsd.txt"
    in_list "$TMP/list-bsd.txt" .claude/settings.json && in_list "$TMP/list-bsd.txt" .claude-kit-backup-v1/MANIFEST.txt \
      && ok_ "contenu inclus présent (bsdtar)" || ko_ "contenu inclus présent (bsdtar)"
    not_in_list "$TMP/list-bsd.txt" .credentials.json && not_in_list "$TMP/list-bsd.txt" age/key.txt && ok_ "secrets absents (bsdtar)" || ko_ "secrets absents (bsdtar)"
    verify_restore "$ARCH_B" bsd
  fi
else
  echo "  (bsdtar absent : étape ignorée)"
fi

# --- 8) bash 3.2 constructs ------------------------------------------------------------------------------------------------
section "constructions bash 4+ interdites (macOS = bash 3.2)"
bad=$(grep -nE 'mapfile|readarray|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^|,|\^)\}|declare +-[A-Za-z]*A|local +-[A-Za-z]*A|\[\[ +-v |\|&|&>>|coproc|readlink +-f|grep +-[A-Za-z]*P|sed +-i|\$\{[A-Za-z_]+@[QEPAa]\}|;;&|;&$|\bdeclare +-n|\blocal +-n' "$BACKUP" | grep -v '^[0-9]*:#' || true)
[ -z "$bad" ] && ok_ "aucune construction bash 4+ dans backup-v1.sh" || ko_ "constructions bash 4+" "$bad"
case $BASH_VERSION in 3.*) ok_ "exécuté sous bash $BASH_VERSION" ;; *) echo "  (exécuté sous bash $BASH_VERSION, pas 3.2 : voir l'image Docker)" ;; esac
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck --shell=bash" shellcheck --shell=bash -x -S warning "$BACKUP"
else
  echo "  (shellcheck absent ici : lancé séparément)"
fi

echo
echo "Résultat : $pass ok, $fail échec(s)"
[ "$fail" -eq 0 ]
