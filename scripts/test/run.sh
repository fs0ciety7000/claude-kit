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
  'Bash(npm run test *)'
  'Bash(npm run test)'
  'Bash(npm run lint)'
  'Bash(npm run test:e2e *)'
  'Bash(npm test *)'
  'Bash(pnpm run build)'
  'Bash(go test ./...)'
  'Bash(go vet ./...)'
  'Bash(cargo clippy --all-targets *)'
  'Bash(cargo test)'
  'Bash(pytest -q *)'
  'Bash(python -m pytest tests *)'
  'Bash(git status *)'
  'Bash(git log --oneline *)'
  'Bash(git diff HEAD)'
  'Bash(git branch --list)'
  'Bash(git remote -v)'
  'Bash(kit api coolify GET /applications/*)'
  'Bash(kit api coolify GET /applications *)'
  'Bash(kit api cloudflare GET /zones/abc/dns_records)'
  'Bash(kit doctor)'
  'Bash(ls -la src *)'
  'Bash(rg -n todo src *)'
  'Bash(find src -name x)'
  'Bash(npx prettier --check *)'
  'Bash(npx playwright test *)'
  'Read(src/**)'
  'Read(src/*)'
  'Read(docs/guide.md)'
  'Grep(src/*)'
  'Glob(docs/**)'
  'WebFetch(domain:docs.example.com)'
  'mcp__github__pull_request_read'
  'mcp__github__list_commits'
  'mcp__github__get_file_contents'
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
  # A. Jokers : collés à un mot, au milieu, ou de classe (? [ ] { }).
  'Bash(npm run test*)'
  'Bash(kit perm* allow x)'
  'Bash(ls * -l)'
  'Bash(npm run * test)'
  'Bash(npm run te?t)'
  'Bash(npm run [t]est)'
  'Bash(npm run {test,lint})'
  'Bash(cat src/?.ts)'
  'Bash(npm run test **)'
  'Read(.e*)'
  'Read(**/x)'
  'Read(id_*)'
  'Read(src/*.ts)'
  'Read(src/[a]/x)'
  'Read(./src/**)'
  'Read(.github/**)'
  'Grep(**/*)'
  'Edit(.github/workflows/**)'
  'Edit(src/.husky/x)'
  'Edit(package.json)'
  'Edit(src/Makefile)'
  'Edit(Dockerfile)'
  'Edit(yarn.lock)'
  'Edit(scripts/**)'
  'Write(.vscode/settings.json)'
  'Write(*.md)'
  # B. Premier mot : chemin de binaire, shells, interpréteurs, lanceurs de code.
  'Bash(/usr/bin/git status *)'
  'Bash(./node_modules/.bin/eslint src)'
  'Bash(git -C sub status)'
  'Bash(bash scripts/x.sh)'
  'Bash(python3 -m pytest)'
  'Bash(node build.js)'
  'Bash(env FOO=1 npm test)'
  'Bash(xargs echo)'
  'Bash(npx cowsay hi)'
  'Bash(npx -y prettier --check *)'
  'Bash(npx playwright install)'
  'Bash(pnpm dlx create-x)'
  'Bash(yarn dlx x)'
  'Bash(bunx x)'
  'Bash(uvx x)'
  'Bash(pip install requests)'
  'Bash(npm install -g typescript)'
  'Bash(npm i -g typescript)'
  'Bash(cargo run --release)'
  'Bash(cargo install ripgrep)'
  'Bash(go run main.go)'
  'Bash(go install x@latest)'
  'Bash(make build)'
  'Bash(just build)'
  'Bash(gh workflow run x)'
  'Bash(git config user.name x)'
  'Bash(git rebase main)'
  'Bash(git restore .)'
  'Bash(git checkout -- .)'
  'Bash(git filter-branch --all)'
  'Bash(FOO=1 npm test)'
  'Bash(curl https://example.com/x)'
  # C. Arguments : chemins absolus, ~, .. ; options globales de git ; push en position quelconque.
  'Bash(cat /etc/hostname)'
  'Bash(ls ~)'
  'Bash(cat ../x)'
  'Bash(cat src/../../x)'
  'Bash(cat --file=/etc/x)'
  'Bash(git -C /tmp status)'
  'Bash(git -c core.pager=x log)'
  'Bash(git --git-dir=x log)'
  'Bash(git --work-tree=x status)'
  'Bash(git remote push x)'
  'Bash(git status /*)'
  # D. Mots dangereux restent refusés (sans joker pour les masquer).
  'Bash(kit perms allow x)'
  'Bash(kit secrets list)'
  'Bash(git push)'
  # E. MCP : verbes dangereux n'importe où, y compris derrière un préfixe de lecture.
  'mcp__github__get_and_delete_branch'
  'mcp__github__list_releases'
  'mcp__github__push_files'
  'mcp__db__execute_sql'
  'mcp__db__run_query'
  'mcp__db__apply_migration'
  'mcp__fs__write_file'
  'mcp__github__create_or_update_file'
  'mcp__github__update_file'
  'mcp__shell__exec'
  'mcp__github__force_thing'
  'mcp__github__search_*'
  # F. kit api : chemins larges, actions, joker mal placé.
  'Bash(kit api coolify PATCH /applications/abc*)'
  'Bash(kit api coolify PATCH /applications/*)'
  'Bash(kit api coolify PATCH /applications/abc/*)'
  'Bash(kit api coolify POST /applications/abc/envs/*/x)'
  'Bash(kit api coolify POST /applications/abc/restart)'
  'Bash(kit api coolify POST /applications/abc/start)'
  'Bash(kit api coolify GET /applications/abc/stop)'
  'Bash(kit api coolify GET /applications*)'
  'Bash(kit api coolify GET /applications/abc/restart)'
  'Bash(kit api coolify PUT /servers/../x)'
  'Bash(kit api coolify PATCH *)'
  'Bash(kit api coolify PATCH)'
  'Bash(kit api coolify GET *.*)'
  # Liste blanche : Edit/Write toujours refusés, quel que soit le motif.
  'Edit(src/**)'
  'Edit(settings.json)'
  'Edit(config)'
  'Edit(workflows)'
  'Edit(\.claude/settings.json)'
  'Edit(Makefile )'
  'Write(docs/notes.md)'
  # Liste blanche : commandes hors liste.
  'Bash(uv run *)'
  'Bash(bundle exec *)'
  'Bash(docker compose run *)'
  'Bash(sed -i *)'
  'Bash(tee -a *)'
  'Bash(git apply *)'
  'Bash(npm pkg set *)'
  'Bash(awk -f *)'
  'Bash(vim -c *)'
  'Bash(git submodule foreach *)'
  'Bash(git reset HEAD *)'
  'Bash(git tag -d *)'
  'Bash(git update-ref -d *)'
  'Bash(git reflog expire *)'
  'Bash(git --config-env=core.pager=sh log)'
  'Bash(r\m -rf src)'
  "Bash(gi''t push)"
  'Bash(git log --output=x *)'
  'Bash(git fetch origin main:main)'
  'Bash(git branch --list *)'
  'Bash(git remote -v add x y)'
  'Bash(find . -exec ls)'
  'Bash(find . -delete)'
  'Bash(rg --pre sh x)'
  'Bash(tree -o x)'
  'Bash(cat src/..)'
  'Bash(ls src/../..)'
  'Bash(npm run *)'
  'Bash(npm run deploy)'
  'Bash(npm run postinstall *)'
  'Bash(npm run -w x test)'
  'Bash(npm run Test)'
  'Bash(ls)x'
  'Bash(kit api github PUT /repos/x/y/contents/a)'
  'Bash(kit api github POST /repos/x/y/git/refs)'
  'Bash(kit api github POST /repos/x/y/actions/workflows/1/dispatches)'
  'Bash(kit api github POST /repos/x/y/keys)'
  'Bash(kit api github PATCH /repos/x/y/git/refs/heads/main)'
  'Bash(kit api cloudflare PUT /accounts/a/workers/scripts/s)'
  'Bash(kit api cloudflare PUT /accounts/a/workers/scripts/s/content)'
  'Bash(kit api coolify PATCH /applications/abc)'
  'Bash(kit api coolify GET /applications/__SECRET:X__)'
  'Bash(kit api coolify GET /applications/../x)'
  'Bash(kit api coolify GET /applications/abc/restart)'
  'Bash(kit api coolify GET /)'
  'Bash(kit api coolify GET)'
  'Bash(kit api coolify GET /applications/abc/../x *)'
  'Read(src)'
  'Read(.github/**)'
  'Read(src/.env)'
  'Read(src/ x/**)'
  'Read(src/"x"/**)'
  'Read(src\x/**)'
  'Read(docs/.env.example)'
  'Glob'
  'Grep'
  'WebFetch(domain:Docs.Example.com)'
  'WebFetch(domain:localhost)'
  'WebFetch(domain:10.0.0.1)'
  'WebFetch(domain:a..example.com)'
  'mcp__supabase__reset_branch'
  'mcp__supabase__pause_project'
  'mcp__supabase__rebase_branch'
  'mcp__supabase__list_projects_and_delete'
  'mcp__github__create_pull_request'
  'mcp__github__update_pull_request'
  'mcp__github__add_issue_comment'
  'mcp__github__get_job_logs_and_run'
  'mcp__supabase__restore_project'
  'mcp__github__Get_File'
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
rule='Bash(npm run test *)'
"$PERMS" allow "$rule" --reason "tests du projet" --dir "$PROJ" >/dev/null 2>&1
rc1=$?
"$PERMS" allow "$rule" --reason "tests du projet" --dir "$PROJ" >/dev/null 2>&1
rc2=$?
S="$PROJ/.claude/settings.json"
LOG="$PROJ/docs/memory/permissions.md"
((rc1 == 0 && rc2 == 0)) && ok_ "allow deux fois : codes 0" || ko_ "allow deux fois : codes 0" "rc1=$rc1 rc2=$rc2"
[[ $(jq --arg r "$rule" '[.permissions.allow[] | select(. == $r)] | length' "$S") == 1 ]] && ok_ "une seule entrée dans allow" || ko_ "une seule entrée dans allow"
[[ $(grep -cF "\`$rule\`" "$LOG" 2>/dev/null) == 1 ]] && ok_ "une seule ligne de journal" || ko_ "une seule ligne de journal"
grep -qE "^- [0-9]{4}-[0-9]{2}-[0-9]{2} \`Bash\(npm run test \*\)\` — tests du projet$" "$LOG" && ok_ "format de la ligne de journal" || ko_ "format de la ligne de journal" "$(cat "$LOG" 2>/dev/null)"
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
"$PERMS" allow 'Bash(npm run lint *)' --dir "$P2" >/dev/null 2>&1 && ko_ "--reason obligatoire" || ok_ "--reason obligatoire"
"$PERMS" allow 'Bash(npm run lint *)' --reason "x" --dir "$HOME" >/dev/null 2>&1 && ko_ "dossier \$HOME refusé" || ok_ "dossier \$HOME refusé"
"$PERMS" allow 'Bash(npm run lint *)' --reason "x" --dir / >/dev/null 2>&1 && ko_ "dossier / refusé" || ok_ "dossier / refusé"
[[ ! -e $HOME/.claude/settings.json && ! -e $HOME/.claude ]] && ok_ "settings.json global jamais touché" || ko_ "settings.json global jamais touché"
# G. Liens symboliques : refus avant toute écriture (docs/ ou docs/memory hors du projet).
P3="$TMP/proj3"; OUTSIDE="$TMP/outside"; mkdir -p "$P3" "$OUTSIDE"
ln -s "$OUTSIDE" "$P3/docs"
"$PERMS" allow 'Bash(npm run lint *)' --reason "x" --dir "$P3" >/dev/null 2>&1; rc=$?
((rc != 0)) && [[ ! -e $P3/.claude/settings.json && -z $(ls -A "$OUTSIDE") ]] && ok_ "docs/ lien symbolique : refusé avant toute écriture" || ko_ "docs/ lien symbolique : refusé avant toute écriture"
P4="$TMP/proj4"; mkdir -p "$P4/docs"
ln -s "$OUTSIDE" "$P4/docs/memory"
"$PERMS" allow 'Bash(npm run lint *)' --reason "x" --dir "$P4" >/dev/null 2>&1; rc=$?
((rc != 0)) && [[ ! -e $P4/.claude/settings.json && -z $(ls -A "$OUTSIDE") ]] && ok_ "docs/memory lien symbolique : refusé avant toute écriture" || ko_ "docs/memory lien symbolique : refusé avant toute écriture"
# Écritures concurrentes : toutes les règles survivent (verrou).
P5="$TMP/proj5"; mkdir -p "$P5"
for n in 1 2 3 4 5 6 7 8; do
  "$PERMS" allow "Bash(npm run task$n *)" --reason "concurrence $n" --dir "$P5" >/dev/null 2>&1 &
done
wait
[[ $(jq '.permissions.allow | length' "$P5/.claude/settings.json" 2>/dev/null) == 8 && $(grep -c '^- ' "$P5/docs/memory/permissions.md" 2>/dev/null) == 8 ]] \
  && ok_ "8 allow concurrents : 8 règles, 8 lignes de journal" || ko_ "8 allow concurrents" "$(jq -c '.permissions.allow' "$P5/.claude/settings.json" 2>&1)"
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
[[ -L $KIT_CONFIG/hooks/kit-dockerd.sh && $(readlink "$KIT_CONFIG/hooks/kit-dockerd.sh") == "$ROOT/scripts/hooks/kit-dockerd.sh" ]] \
  && ok_ "link_global lie kit-dockerd.sh" || ko_ "link_global lie kit-dockerd.sh"
jq -e '[.hooks.SessionStart[] | select(.matcher == "startup|resume") | .hooks[].command] | any(endswith("kit-dockerd.sh"))' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "SessionStart : kit-dockerd (startup|resume)" || ko_ "SessionStart : kit-dockerd"
out=$(KIT_DOCKERD=0 CLAUDE_CODE_REMOTE=true bash "$ROOT/scripts/hooks/kit-dockerd.sh" </dev/null); rc=$?
[[ $rc == 0 && -z $out ]] && ok_ "kit-dockerd : KIT_DOCKERD=0 ne fait rien" || ko_ "kit-dockerd : KIT_DOCKERD=0"
out=$(env -u CLAUDE_CODE_REMOTE -u KIT_DOCKERD bash "$ROOT/scripts/hooks/kit-dockerd.sh" </dev/null); rc=$?
[[ $rc == 0 && -z $out ]] && ok_ "kit-dockerd : hors cloud, ne fait rien" || ko_ "kit-dockerd : hors cloud"
jq -e '.hooks.SessionStart | length == 2 and any(.matcher == "startup|resume" and .hooks[0].timeout == 30)' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "SessionStart : kit-emit conservé + autoupdate (startup|resume, timeout 30)" || ko_ "SessionStart : kit-emit conservé + autoupdate"
jq -e '.permissions.allow | index("Bash(kit perms allow *)") != null and index("mcp__claude-code-remote__add_repo") != null' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "allow : kit perms et add_repo présents" || ko_ "allow : kit perms et add_repo présents"
"$ROOT/scripts/kit.sh" help 2>&1 | grep -q 'kit perms allow' && ok_ "usage : section PERMISSIONS" || ko_ "usage : section PERMISSIONS"
"$ROOT/scripts/kit.sh" help 2>&1 | grep -q 'KIT_AUTOUPDATE=0' && ok_ "usage : KIT_AUTOUPDATE=0" || ko_ "usage : KIT_AUTOUPDATE=0"
rm -rf "$HOME/.claude" "$KIT_CONFIG"
# I. merge_settings écrit de façon atomique et suit un lien symbolique (réglages versionnés ailleurs).
mkdir -p "$HOME/.claude"
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo bye"}]}]}}' >"$TMP/real-settings.json"
chmod 600 "$TMP/real-settings.json"
ln -s "$TMP/real-settings.json" "$HOME/.claude/settings.json"
( source "$ROOT/scripts/lib.sh"; merge_settings "$HOME/.claude/settings.json" "$ROOT/global/settings.json" current >/dev/null 2>&1 )
[[ -L $HOME/.claude/settings.json ]] && jq -e '.model == "sonnet" and (.hooks.Stop | length == 2) and (.hooks.SessionStart | length == 2)' "$TMP/real-settings.json" >/dev/null 2>&1 \
  && ok_ "merge_settings : lien conservé, cible fusionnée" || ko_ "merge_settings : lien conservé, cible fusionnée"
[[ $(stat -c %a "$TMP/real-settings.json" 2>/dev/null || stat -f %Lp "$TMP/real-settings.json") == 600 ]] && ok_ "merge_settings : droits conservés" || ko_ "merge_settings : droits conservés"
[[ -z $(find "$TMP" -maxdepth 1 -name '.real-settings.json.*') ]] && ok_ "merge_settings : aucun fichier temporaire résiduel" || ko_ "merge_settings : fichier temporaire résiduel"
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
[[ $RC == 0 && $OUT == "kit mis à jour : "*" (1 commits) — kit sync tourne en arrière-plan "*"CLAUDE.md et les commandes au prochain démarrage de session." ]] \
  && ok_ "nouveau commit : mise à jour et message" || ko_ "nouveau commit : mise à jour et message" "code $RC, sortie : $OUT"
[[ $(head_of) == "$(git -C "$ORIGIN" rev-parse main)" ]] && ok_ "HEAD aligné sur origin/main" || ko_ "HEAD aligné sur origin/main"
for _ in $(seq 1 50); do [[ -s $MARK ]] && break; sleep 0.1; done
[[ $(cat "$MARK" 2>/dev/null) == "sync" ]] && ok_ "kit sync lancé une fois (en arrière-plan)" || ko_ "kit sync lancé une fois" "$(cat "$MARK" 2>/dev/null)"
grep -q 'kit sync après' "$KIT_CONFIG/autoupdate.log" 2>/dev/null && ok_ "journal autoupdate.log écrit" || ko_ "journal autoupdate.log écrit"
[[ $(wc -l <<<"$OUT") == 1 ]] && ok_ "une seule ligne de sortie" || ko_ "une seule ligne de sortie"

# 4. Arbre sale : ignoré, code 0.
push_commit v3
echo dirty >>"$KITCLONE/VERSION"
# 4a. Profil local : la ligne « ignorée » n'apparaît qu'une fois par 6 h.
rm -f "$KIT_CONFIG/autoupdate.stamp" "$KIT_CONFIG/autoupdate.skip.stamp"
run_hook A=1
[[ $RC == 0 && $OUT == *"ignorée"* ]] && ok_ "local, arbre modifié : une ligne la première fois" || ko_ "local, arbre modifié : une ligne" "code $RC, sortie : $OUT"
run_hook A=1
[[ $RC == 0 && -z $OUT ]] && ok_ "local, arbre modifié : silencieux ensuite (6 h)" || ko_ "local, arbre modifié : silencieux ensuite" "code $RC, sortie : $OUT"
[[ ! -f $KIT_CONFIG/autoupdate.stamp ]] && ok_ "tampon de fetch non écrit sans fetch" || ko_ "tampon de fetch non écrit sans fetch"
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"ignorée"*"modifications locales"* && $(head_of) == "$before" ]] \
  && ok_ "arbre modifié : ignoré avec une ligne, code 0" || ko_ "arbre modifié : ignoré" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q -- VERSION

# 4b. Verrou git : message distinct de « divergent ».
touch "$KITCLONE/.git/index.lock"
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"verrou git présent"* && $(head_of) == "$before" ]] \
  && ok_ "index.lock : message « verrou git présent », code 0" || ko_ "index.lock : message verrou" "code $RC, sortie : $OUT"
rm -f "$KITCLONE/.git/index.lock"

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
# 8b. Profil local : un fetch en échec n'écrit pas le tampon (retenté à la session suivante).
rm -f "$KIT_CONFIG/autoupdate.stamp"
run_hook A=1
[[ $RC == 0 && -z $OUT && ! -f $KIT_CONFIG/autoupdate.stamp ]] && ok_ "fetch en échec : pas de tampon, code 0" || ko_ "fetch en échec : pas de tampon" "code $RC, sortie : $OUT"
push_commit v5
git -C "$KITCLONE" remote set-url origin "$ORIGIN"
run_hook A=1
[[ $RC == 0 && $OUT == "kit mis à jour : "* && -f $KIT_CONFIG/autoupdate.stamp ]] && ok_ "session suivante : retenté, mise à jour, tampon écrit" || ko_ "session suivante : retenté" "code $RC, sortie : $OUT"

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
