#!/usr/bin/env bash
# Tests of kit atlas (scripts/atlas.sh) with a fake gh and a fake hub repository (bare origin + owner's clone), all in a
# temporary directory: no network, no real GitHub call. Summary line read by run.sh.
set -uo pipefail
umask 022
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)
T=$(mktemp -d)
trap '[[ -n ${KEEP:-} ]] || rm -rf "$T"' EXIT
export HOME="$T/home" KIT_HOME=$ROOT KIT_CONFIG="$T/home/.config/claude-kit" KIT_ATLAS_TODAY=2026-01-02
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME CLAUDE_CODE_REMOTE
mkdir -p "$HOME" "$KIT_CONFIG"
ATLAS="$ROOT/scripts/atlas.sh"

pass=0 fail=0
ok_() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ko_() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "${2:0:600}"; }
t() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok_ "$d"; else ko_ "$d" "$OUT"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# --- fake gh: logs every call, one open PR once created ---
FAKE="$T/fake" BIN="$T/bin"
export FAKE_LOG="$T/gh.log" FAKE_DIR=$FAKE
mkdir -p "$FAKE" "$BIN"
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_LOG"
case "$*" in
  *"-X POST"*) echo "https://github.com/example-owner/example-hub/pull/3" | tee "$FAKE_DIR/gh_pr" ;;
  *state=closed*) cat "$FAKE_DIR/gh_merged" 2>/dev/null || echo 0 ;;
  *"--jq length"*) if [[ -f $FAKE_DIR/gh_pr ]]; then echo 1; else echo 0; fi ;;
  *) [[ -f $FAKE_DIR/gh_pr ]] && cat "$FAKE_DIR/gh_pr"; true ;;
esac
EOF
chmod +x "$BIN/gh"
export KIT_SHIP_GH="$BIN/gh"

# --- fake hub repository ---
BARE="$T/hub.git" HUB="$T/hub"
git init -q --bare -b main "$BARE"
git init -q -b main "$HUB"
mkdir -p "$HUB/src/content/docs/projets"
printf '%s\n' '---' 'title: Accueil' '---' >"$HUB/src/content/docs/index.md"
git -C "$HUB" add -A && git -C "$HUB" commit -q -m init
git -C "$HUB" remote add origin "$BARE"
git -C "$HUB" push -q origin main
git -C "$HUB" fetch -q origin
printf '%s\n' '# hub' 'ATLAS_REPO=example-owner/example-hub' "ATLAS_DIR=$HUB" 'ATLAS_BASE=main' >"$KIT_CONFIG/atlas.conf"

# --- fixture project ---
P="$T/proj"
mkdir -p "$P/docs/memory"
printf '%s\n' 'name: demo-app' 'size: M' 'stack: go + astro' 'expose: access' 'domain: demo.example.org' 'coolify_uuid: ""' >"$P/project.yaml"
cat >"$P/docs/plan.md" <<'EOF'
# Plan

## Lot 1 — Socle

- [x] squelette — fini quand : build vert
- [x] CI

## Lot 2 — API

- [ ] routes
- [x] schéma

```
- [ ] exemple dans un bloc de code, ignoré
```

## Équipe

| Agent | Rôle |
EOF
cat >"$P/docs/memory/state.md" <<'EOF'
# État

- **Fait** : socle livré
- **En cours** : API
- **Bloquant** : —
- **Prochaines étapes** :
  1. écrire les tests
  2. brancher la CI
  3. mettre en ligne
  4. quatrième, coupée
EOF

OUT="" RC=0
arun() { OUT=$(PATH="$BIN:$PATH" bash "$ATLAS" "$@" 2>&1); RC=$?; }
has() { grep -qF -- "$1" <<<"$OUT"; }
pages() { git -C "$BARE" ls-tree -r --name-only "refs/heads/projet/demo-app" 2>/dev/null | grep -c '^src/content/docs/projets/' || true; }
commits() { git -C "$BARE" rev-list --count "refs/heads/projet/demo-app" 2>/dev/null || echo 0; }
remote_page() { git -C "$BARE" show "refs/heads/projet/demo-app:src/content/docs/projets/demo-app.md"; }
REL=src/content/docs/projets/demo-app.md

section "page générée"
arun page --dir "$P"
t "page : code 0" test "$RC" -eq 0
t "page : frontmatter title" has 'title: "demo-app"'
t "page : type projet" has 'type: projet'
t "page : updated" has 'updated: 2026-01-02'
t "page : tags de la pile" has 'tags: [projet, go, astro]'
t "page : status actif (schéma atlas)" has 'status: actif'
t "page : URL d'un service derrière Access" has '- **URL** : https://demo.example.org'
t "page : progression totale" has '3/4 tâches (75 %).'
t "page : progression par lot" has '- Lot 2 — API : 1/2'
t "page : section sans case ignorée" bash -c '! grep -q "Équipe" <<<"$1"' _ "$OUT"
t "page : état, fait" has '- **Fait** : socle livré'
t "page : 3 prochaines étapes au plus" bash -c 'grep -q "  3. mettre en ligne" <<<"$1" && ! grep -q "quatrième" <<<"$1"' _ "$OUT"

section "dry-run"
: >"$FAKE_LOG"
before=$(git -C "$HUB" status --porcelain; git -C "$HUB" rev-parse HEAD; git -C "$HUB" worktree list | wc -l)
arun sync --dir "$P" --dry-run
t "dry-run : code 0" test "$RC" -eq 0
t "dry-run : diff montré" has "+++ b/$REL"
t "dry-run : Rien n'a été écrit" has "Rien n'a été écrit (--dry-run)."
t "dry-run : aucun appel gh" test ! -s "$FAKE_LOG"
t "dry-run : aucune branche poussée" test "$(commits)" -eq 0
t "dry-run : clone du propriétaire intact" test "$(git -C "$HUB" status --porcelain; git -C "$HUB" rev-parse HEAD; git -C "$HUB" worktree list | wc -l)" == "$before"

section "sync"
arun sync --dir "$P"
t "sync : code 0" test "$RC" -eq 0
t "sync : une page sur projet/demo-app" test "$(pages)" -eq 1
t "sync : PR ouverte" has "PR ouverte : https://github.com/example-owner/example-hub/pull/3"
t "sync : PR vers la base" grep -q -- '-X POST repos/example-owner/example-hub/pulls .*head=projet/demo-app .*base=main' "$FAKE_LOG"
t "sync : page poussée = page générée" bash -c 'diff <(bash "$1" page --dir "$2" 2>/dev/null) <(git -C "$3" show "refs/heads/projet/demo-app:$4")' _ "$ATLAS" "$P" "$BARE" "$REL"
t "sync : clone du propriétaire intact (branche, arbre)" bash -c '[[ $(git -C "$1" branch --show-current) == main && -z $(git -C "$1" status --porcelain) && $(git -C "$1" worktree list | wc -l) -eq 1 ]]' _ "$HUB"

section "idempotence"
n1=$(commits)
KIT_ATLAS_TODAY=2026-02-03 arun sync --dir "$P"
t "relance, seule la date change : code 0" test "$RC" -eq 0
t "relance : aucun commit" test "$(commits)" -eq "$n1"
t "relance : PR existante" has "PR mise à jour"
t "relance : une seule PR créée" test "$(grep -c -- '-X POST' "$FAKE_LOG")" -eq 1
KIT_ATLAS_TODAY=2026-02-03 arun sync --dir "$P" --dry-run
t "dry-run après sync : page à jour" has "page à jour : rien à écrire"
sed -i 's/- \[ \] routes/- [x] routes/' "$P/docs/plan.md"
arun sync --dir "$P"
t "plan changé : un commit de plus" test "$(commits)" -eq $((n1 + 1))
t "plan changé : nouvelle progression" bash -c 'git -C "$1" show "refs/heads/projet/demo-app:$2" | grep -q "4/4 tâches (100 %)"' _ "$BARE" "$REL"

section "données identifiantes refusées"
n2=$(commits)
for leak in 'serveur 192.168.10.4' 'hôte fe80::1ab:2cd' 'écrire à someone@example.org' 'jeton ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' 'clé Zx9Qm2Lp8Rt4Vw6Yb1Nc3Kd5Fg7Hj0Aq2Ws'; do
  cp "$P/docs/memory/state.md" "$T/state.bak"
  sed -i "s/- \*\*En cours\*\* : API/- **En cours** : $leak/" "$P/docs/memory/state.md"
  : >"$FAKE_LOG"
  arun sync --dir "$P"
  t "refus ($leak) : code non nul" test "$RC" -ne 0
  t "refus ($leak) : message" has "page refusée"
  t "refus ($leak) : valeur jamais affichée" bash -c '! grep -qF -- "${2#* }" <<<"$1"' _ "$OUT" "$leak"
  t "refus ($leak) : rien poussé, aucun appel gh" bash -c '[[ $1 -eq $2 && ! -s $3 ]]' _ "$(commits)" "$n2" "$FAKE_LOG"
  cp "$T/state.bak" "$P/docs/memory/state.md"
done
arun page --dir "$P"
t "page sans fuite : acceptée" test "$RC" -eq 0
cp "$P/docs/memory/state.md" "$T/state.bak"
sed -i 's/- \*\*Fait\*\* : socle livré/- **Fait** : v1.2.3 du 2026-01-02 à 12:30:45, commit 3f9c2ab, lot-2-site-starlight-atlas-pagefind/' "$P/docs/memory/state.md"
arun page --dir "$P"
t "version, date, heure, SHA court, nom à tirets : acceptés" test "$RC" -eq 0
cp "$T/state.bak" "$P/docs/memory/state.md"

section "configuration"
mv "$KIT_CONFIG/atlas.conf" "$T/atlas.conf"
arun sync --dir "$P"
t "atlas.conf absent : code 0" test "$RC" -eq 0
t "atlas.conf absent : avertissement" has "atlas.conf absent"
printf '%s\n' 'ATLAS_REPO=$(touch /tmp/x)' "ATLAS_DIR=$HUB" >"$KIT_CONFIG/atlas.conf"
arun sync --dir "$P" --dry-run
t "atlas.conf : \$ refusé (jamais exécuté)" bash -c '[[ $1 -ne 0 ]] && grep -q "atlas.conf ligne 1" <<<"$2"' _ "$RC" "$OUT"
ln -sf "$T/atlas.conf" "$KIT_CONFIG/atlas.conf.lnk"
rm -f "$KIT_CONFIG/atlas.conf" && ln -s "$T/atlas.conf" "$KIT_CONFIG/atlas.conf"
arun sync --dir "$P" --dry-run
t "atlas.conf lien symbolique : refusé" bash -c '[[ $1 -ne 0 ]] && grep -q "lien symbolique" <<<"$2"' _ "$RC" "$OUT"
rm -f "$KIT_CONFIG/atlas.conf" "$KIT_CONFIG/atlas.conf.lnk" && cp "$T/atlas.conf" "$KIT_CONFIG/atlas.conf"

section "branche fusionnée (squash)"
rm -f "$FAKE/gh_pr"
echo 1 >"$FAKE/gh_merged"
sed -i 's/socle livré/socle et API livrés/' "$P/docs/memory/state.md"
n3=$(commits)
arun sync --dir "$P"
t "branche fusionnée sans PR ouverte : arrêt" bash -c '[[ $1 -ne 0 ]] && grep -q "déjà fusionnée" <<<"$2"' _ "$RC" "$OUT"
t "branche fusionnée : rien poussé" test "$(commits)" -eq "$n3"

echo
echo "atlas: $pass passed, $fail failed"
((fail == 0))
