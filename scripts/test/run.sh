#!/usr/bin/env bash
# Tests du kit : syntaxe, JSON, kit perms, hook kit-autoupdate. Aucune dépendance au-delà de bash, jq, git.
# Usage : scripts/test/run.sh        (code de sortie non nul au moindre échec)
# HOME et les dossiers de config sont redirigés vers un dossier temporaire : rien ne touche ~/.claude ni ~/.config.
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REAL_HOME=$HOME
export HOME="$TMP/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME XDG_STATE_HOME CLAUDE_HOME CLAUDE_CODE_REMOTE KIT_AUTOUPDATE
export KIT_HOME=$ROOT
export KIT_CONFIG="$HOME/.config/claude-kit"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_NOSYSTEM=1
PERMS="$ROOT/scripts/perms.sh"

pass=0
fail=0
ok_()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ko_()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; }
check() { # description commande... : réussit si la commande retourne 0
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok_ "$d"; else ko_ "$d"; fi
}
section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
section "Syntaxe bash"
while IFS= read -r f; do
  if err=$(bash -n "$f" 2>&1); then ok_ "bash -n ${f#"$ROOT"/}"; else ko_ "bash -n ${f#"$ROOT"/}" "$err"; fi
done < <(find "$ROOT" \( -name .git -o -name node_modules \) -prune -o -name '*.sh' -type f -print | sort)

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r f; do
    if out=$(shellcheck -x -S warning "$f" 2>&1); then ok_ "shellcheck ${f#"$ROOT"/}"; else ko_ "shellcheck ${f#"$ROOT"/}" "$(head -5 <<<"$out")"; fi
  done < <(find "$ROOT/scripts" -name '*.sh' -type f | sort)
else
  echo "  (shellcheck absent : ignoré)"
fi

section "JSON"
while IFS= read -r f; do
  if jq -e . "$f" >/dev/null 2>&1; then ok_ "jq ${f#"$ROOT"/}"; else ko_ "jq ${f#"$ROOT"/}"; fi
done < <(find "$ROOT/global" "$ROOT/templates" -name '*.json' -type f 2>/dev/null | sort)

# ---------------------------------------------------------------------------
section "kit perms : règles acceptées"
PROJ="$TMP/proj"
mkdir -p "$PROJ"

accepted=(
  'Bash(npm run test*)'
  'Bash(go test ./...)'
  'Bash(kit api coolify GET /applications*)'
  'Bash(kit api coolify PATCH /applications/abc*)'
  'Bash(kit api cloudflare POST /zones/abc/dns_records)'
  'Read(src/**)'
  'Edit(src/**)'
  'WebFetch(domain:docs.example.com)'
  'mcp__github__pull_request_read'
  'mcp__github__create_pull_request'
  'Bash(npx prettier --check*)'
  'Bash(cargo clippy --all-targets*)'
  'Read(.env.example)'
)
for r in "${accepted[@]}"; do
  if out=$("$PERMS" check "$r" 2>&1); then ok_ "accepté : $r"; else ko_ "accepté : $r" "$out"; fi
done

section "kit perms : règles refusées"
refused=(
  'Bash(*)'
  'Bash'
  'Bash(:*)'
  'Bash(npm *)'
  'Bash(git:*)'
  'Bash(curl *)'
  'Bash(*foo)'
  'Bash(rm -rf build)'
  'Bash(sudo apt install x)'
  'Bash(cat secrets/dev.enc.json)'
  'Bash(cat .env)'
  'Bash(cat ~/.ssh/config)'
  'Bash(printenv HOME)'
  'Bash(env)'
  'Bash(sops -d x.enc.json)'
  'Bash(git reset --hard HEAD)'
  'Bash(docker run alpine)'
  'Bash(ssh host ls)'
  'Bash(npm test && rm x)'
  'Bash(bash scripts/x.sh*)'
  'Bash(kit secrets run -- ls)'
  'Bash(kit api coolify DELETE /x)'
  'Bash(kit api coolify TRIGGER /deploy*)'
  'Bash(kit api coolify POST /applications*)'
  'Bash(kit api coolify POST /applications/*)'
  'Bash(kit api coolify /applications)'
  'Bash(kit api tailscale GET /x)'
  'Bash(git push origin main)'
  'Bash(gh pr merge 1)'
  'Bash(wrangler deploy)'
  'Bash(npm publish)'
  'Bash(npm run deploy)'
  'Bash(git push --force)'
  'Read'
  'Edit'
  'Write'
  'WebFetch'
  'Read(.env)'
  'Read(**)'
  'Read(/**)'
  'Read(~/**)'
  'Read(../x)'
  'Read(secrets/**)'
  'Edit(/etc/hosts)'
  'Edit(~/.bashrc)'
  'Edit(../x)'
  'Edit(.claude/settings.json)'
  'Write(**)'
  'WebFetch(domain:*.example.com)'
  'WebFetch(https://example.com)'
  'mcp__github__*'
  'mcp__github'
  'mcp__github__delete_branch'
  'mcp__github__merge_pull_request'
  'Task(foo)'
  'Bash(python -c print(1))'
)
for r in "${refused[@]}"; do
  out=$("$PERMS" check "$r" 2>&1); rc=$?
  if ((rc == 1)) && [[ $out == *"Règle refusée"* ]]; then ok_ "refusé : $r"; else ko_ "refusé : $r" "code $rc, sortie : $out"; fi
done

section "kit perms : allow, idempotence, préservation"
mkdir -p "$PROJ/.claude"
cat >"$PROJ/.claude/settings.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]},"permissions":{"deny":["Read(x)"],"allow":["Bash(ls*)"]},"model":"sonnet"}
EOF
rule='Bash(npm run test*)'
"$PERMS" allow "$rule" --reason "tests du projet" --dir "$PROJ" >/dev/null 2>&1
rc1=$?
"$PERMS" allow "$rule" --reason "tests du projet" --dir "$PROJ" >/dev/null 2>&1
rc2=$?
S="$PROJ/.claude/settings.json"
LOG="$PROJ/docs/memory/permissions.md"
((rc1 == 0 && rc2 == 0)) && ok_ "allow deux fois : codes 0" || ko_ "allow deux fois : codes 0" "rc1=$rc1 rc2=$rc2"
[[ $(jq --arg r "$rule" '[.permissions.allow[] | select(. == $r)] | length' "$S") == 1 ]] && ok_ "une seule entrée dans allow" || ko_ "une seule entrée dans allow"
[[ $(grep -cF "\`$rule\`" "$LOG" 2>/dev/null) == 1 ]] && ok_ "une seule ligne de journal" || ko_ "une seule ligne de journal"
grep -qE "^- [0-9]{4}-[0-9]{2}-[0-9]{2} \`Bash\(npm run test\*\)\` — tests du projet$" "$LOG" && ok_ "format de la ligne de journal" || ko_ "format de la ligne de journal" "$(cat "$LOG" 2>/dev/null)"
jq -e '.hooks.SessionStart[0].hooks[0].command == "echo hi"' "$S" >/dev/null && ok_ "clé hooks préservée" || ko_ "clé hooks préservée"
jq -e '.model == "sonnet" and .permissions.deny == ["Read(x)"] and (.permissions.allow | index("Bash(ls*)") != null)' "$S" >/dev/null && ok_ "autres clés et règles préservées" || ko_ "autres clés et règles préservées"
"$PERMS" allow 'Read(src/**)' --reason "lecture des sources" --dir "$PROJ" >/dev/null 2>&1
[[ $(jq '.permissions.allow | length' "$S") == 3 ]] && ok_ "deuxième règle ajoutée" || ko_ "deuxième règle ajoutée"
head -3 "$LOG" | grep -q '^# Permissions' && ok_ "en-tête du journal créé" || ko_ "en-tête du journal créé"

# Fichier absent : créé avec les bonnes clés.
P2="$TMP/proj2"; mkdir -p "$P2"
"$PERMS" allow 'mcp__github__pull_request_read' --reason "lecture des PR" --dir "$P2" >/dev/null 2>&1
jq -e '.permissions.allow == ["mcp__github__pull_request_read"]' "$P2/.claude/settings.json" >/dev/null 2>&1 && ok_ "settings.json créé si absent" || ko_ "settings.json créé si absent"

# Refus : rien n'est écrit.
"$PERMS" allow 'Bash(rm -rf build)' --reason "x" --dir "$P2" >/dev/null 2>&1; rc=$?
((rc != 0)) && ! grep -q 'rm -rf' "$P2/.claude/settings.json" "$P2/docs/memory/permissions.md" && ok_ "règle refusée : rien d'écrit" || ko_ "règle refusée : rien d'écrit"
"$PERMS" allow 'Bash(npm run lint*)' --dir "$P2" >/dev/null 2>&1 && ko_ "--reason obligatoire" || ok_ "--reason obligatoire"
"$PERMS" allow 'Bash(npm run lint*)' --reason "x" --dir "$HOME" >/dev/null 2>&1 && ko_ "dossier \$HOME refusé" || ok_ "dossier \$HOME refusé"
"$PERMS" allow 'Bash(npm run lint*)' --reason "x" --dir / >/dev/null 2>&1 && ko_ "dossier / refusé" || ok_ "dossier / refusé"
[[ ! -e $HOME/.claude/settings.json && ! -e $HOME/.claude ]] && ok_ "settings.json global jamais touché" || ko_ "settings.json global jamais touché"
out=$(cd "$P2" && "$PERMS" list 2>&1) && [[ $out == *"mcp__github__pull_request_read"* ]] && ok_ "list affiche les règles" || ko_ "list affiche les règles" "$out"
out=$("$ROOT/scripts/kit.sh" perms check 'Bash(*)' 2>&1); rc=$?
((rc == 1)) && ok_ "kit perms dispatché par kit.sh" || ko_ "kit perms dispatché par kit.sh" "code $rc : $out"

# ---------------------------------------------------------------------------
section "link_global, merge_settings, usage"
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/lib.sh"
  link_global >/dev/null 2>&1
  merge_settings "$TMP/merged.json" "$ROOT/global/settings.json" current >/dev/null 2>&1
)
[[ -L $KIT_CONFIG/hooks/kit-autoupdate.sh && $(readlink "$KIT_CONFIG/hooks/kit-autoupdate.sh") == "$ROOT/scripts/hooks/kit-autoupdate.sh" ]] \
  && ok_ "link_global lie kit-autoupdate.sh" || ko_ "link_global lie kit-autoupdate.sh"
jq -e '.hooks.SessionStart | length == 2 and any(.matcher == "startup|resume" and .hooks[0].timeout == 20)' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "SessionStart : kit-emit conservé + autoupdate (startup|resume, timeout 20)" || ko_ "SessionStart : kit-emit conservé + autoupdate"
jq -e '.permissions.allow | index("Bash(kit perms allow *)") != null and index("mcp__claude-code-remote__add_repo") != null' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "allow : kit perms et add_repo présents" || ko_ "allow : kit perms et add_repo présents"
"$ROOT/scripts/kit.sh" help 2>&1 | grep -q 'kit perms allow' && ok_ "usage : section PERMISSIONS" || ko_ "usage : section PERMISSIONS"
"$ROOT/scripts/kit.sh" help 2>&1 | grep -q 'KIT_AUTOUPDATE=0' && ok_ "usage : KIT_AUTOUPDATE=0" || ko_ "usage : KIT_AUTOUPDATE=0"
rm -rf "$HOME/.claude" "$KIT_CONFIG"

# ---------------------------------------------------------------------------
section "hook kit-autoupdate"
AU="$TMP/au"
ORIGIN="$AU/origin.git"
SEED="$AU/seed"
KITCLONE="$AU/kit"
MARK="$AU/sync.marker"
mkdir -p "$AU"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$SEED"
mkdir -p "$SEED/scripts/hooks"
cp "$ROOT/scripts/hooks/kit-autoupdate.sh" "$SEED/scripts/hooks/kit-autoupdate.sh"
cat >"$SEED/scripts/kit.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: records that `kit sync` was called.
echo "$*" >>"$AU_MARK"
EOF
chmod +x "$SEED/scripts/hooks/kit-autoupdate.sh" "$SEED/scripts/kit.sh"
echo v1 >"$SEED/VERSION"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m v1
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin main
git clone -q "$ORIGIN" "$KITCLONE"
mkdir -p "$KIT_CONFIG/hooks"
HOOK="$KIT_CONFIG/hooks/kit-autoupdate.sh"
ln -s "$KITCLONE/scripts/hooks/kit-autoupdate.sh" "$HOOK"
export AU_MARK=$MARK

push_commit() { # contenu : nouveau commit sur origin
  echo "$1" >"$SEED/VERSION"
  git -C "$SEED" commit -q -am "$1"
  git -C "$SEED" push -q origin main
}
run_hook() { # [VAR=val...] : sortie dans $OUT, code dans $RC
  OUT=$(env "$@" "$HOOK" <<<'{"hook_event_name":"SessionStart"}' 2>&1)
  RC=$?
}
head_of() { git -C "$KITCLONE" rev-parse HEAD; }

# 1. À jour : aucune sortie, code 0.
run_hook A=1
[[ $RC == 0 && -z $OUT ]] && ok_ "à jour : aucune sortie, code 0" || ko_ "à jour : aucune sortie, code 0" "code $RC, sortie : $OUT"
[[ -f $KIT_CONFIG/autoupdate.stamp ]] && ok_ "tampon de limitation écrit" || ko_ "tampon de limitation écrit"

# 2. Limitation 6 h : nouveau commit, tampon récent -> rien.
push_commit v2
before=$(head_of)
run_hook A=1
[[ $RC == 0 && -z $OUT && $(head_of) == "$before" ]] && ok_ "limité à une fois par 6 h (profil local)" || ko_ "limité à une fois par 6 h" "code $RC, sortie : $OUT"

# 3. Tampon expiré -> mise à jour + message + sync.
echo $(($(date +%s) - 30000)) >"$KIT_CONFIG/autoupdate.stamp"
run_hook A=1
[[ $RC == 0 && $OUT == "kit mis à jour : "*" (1 commits) — les réglages s'appliquent tout de suite, CLAUDE.md et les commandes au prochain démarrage de session." ]] \
  && ok_ "nouveau commit : mise à jour et message" || ko_ "nouveau commit : mise à jour et message" "code $RC, sortie : $OUT"
[[ $(head_of) == "$(git -C "$ORIGIN" rev-parse main)" ]] && ok_ "HEAD aligné sur origin/main" || ko_ "HEAD aligné sur origin/main"
[[ $(cat "$MARK" 2>/dev/null) == "sync" ]] && ok_ "kit sync lancé une fois" || ko_ "kit sync lancé une fois" "$(cat "$MARK" 2>/dev/null)"
[[ $(wc -l <<<"$OUT") == 1 ]] && ok_ "une seule ligne de sortie" || ko_ "une seule ligne de sortie"

# 4. Arbre sale : ignoré, code 0.
push_commit v3
echo dirty >>"$KITCLONE/VERSION"
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"ignorée"*"modifications locales"* && $(head_of) == "$before" ]] \
  && ok_ "arbre modifié : ignoré avec une ligne, code 0" || ko_ "arbre modifié : ignoré" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q -- VERSION

# 5. Hors main : ignoré.
git -C "$KITCLONE" checkout -q -b feature
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"ignorée"*"pas main"* && $(head_of) == "$before" ]] \
  && ok_ "branche autre que main : ignoré, code 0" || ko_ "branche autre que main : ignoré" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q main

# 6. KIT_AUTOUPDATE=0 : rien, même avec un commit en attente.
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true KIT_AUTOUPDATE=0
[[ $RC == 0 && -z $OUT && $(head_of) == "$before" ]] && ok_ "KIT_AUTOUPDATE=0 : désactivé" || ko_ "KIT_AUTOUPDATE=0 : désactivé" "code $RC, sortie : $OUT"

# 7. Profil cloud : pas de limitation, deux démarrages de suite.
echo cloud >"$KIT_CONFIG/profile"
run_hook A=1
[[ $RC == 0 && $OUT == "kit mis à jour : "* ]] && ok_ "profil cloud : mise à jour sans limitation" || ko_ "profil cloud : mise à jour sans limitation" "code $RC, sortie : $OUT"
push_commit v4
run_hook A=1
[[ $RC == 0 && $OUT == "kit mis à jour : "* && $(head_of) == "$(git -C "$ORIGIN" rev-parse main)" ]] \
  && ok_ "profil cloud : à chaque démarrage" || ko_ "profil cloud : à chaque démarrage" "code $RC, sortie : $OUT"
rm -f "$KIT_CONFIG/profile"

# 8. Origine injoignable : code 0, dans le délai.
git -C "$KITCLONE" remote set-url origin "http://10.255.255.1/none.git"
SECONDS=0
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $SECONDS -le 14 && -z $OUT ]] && ok_ "origine injoignable : code 0, silencieux, en ${SECONDS}s" || ko_ "origine injoignable" "code $RC, ${SECONDS}s, sortie : $OUT"
git -C "$KITCLONE" remote set-url origin "$ORIGIN"

# 9. Sans dépôt git : code 0.
NOGIT="$AU/nogit"; mkdir -p "$NOGIT/scripts/hooks"
cp "$ROOT/scripts/hooks/kit-autoupdate.sh" "$NOGIT/scripts/hooks/"
OUT=$(CLAUDE_CODE_REMOTE=true "$NOGIT/scripts/hooks/kit-autoupdate.sh" </dev/null 2>&1); RC=$?
[[ $RC == 0 && -z $OUT ]] && ok_ "hors dépôt git : code 0, silencieux" || ko_ "hors dépôt git" "code $RC, sortie : $OUT"

# ---------------------------------------------------------------------------
echo
echo "$pass passed, $fail failed"
HOME=$REAL_HOME
((fail == 0))
