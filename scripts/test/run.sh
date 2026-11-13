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
# État du dépôt du kit (fichiers suivis et non suivis, diff) : comparé en fin de run, les tests n'y écrivent rien.
repo_state() {
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo none; return; }
  { git -C "$ROOT" status --porcelain -uall; git -C "$ROOT" diff; git -C "$ROOT" diff --cached; } | cksum
}
REPO_STATE0=$(repo_state)

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
section "link_global, apply_managed_settings, usage"
(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/lib.sh"
  link_global >/dev/null 2>&1
  apply_managed_settings >/dev/null 2>&1
  cp "$CLAUDE_HOME/settings.json" "$TMP/merged.json"
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
# I. apply_managed_settings écrit de façon atomique et suit un lien symbolique (réglages versionnés ailleurs).
mkdir -p "$HOME/.claude"
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo bye"}]}]}}' >"$TMP/real-settings.json"
chmod 600 "$TMP/real-settings.json"
ln -s "$TMP/real-settings.json" "$HOME/.claude/settings.json"
( source "$ROOT/scripts/lib.sh"; apply_managed_settings >/dev/null 2>&1 )
[[ -L $HOME/.claude/settings.json ]] && jq -e '.model == "sonnet" and (.hooks.Stop | length == 2) and (.hooks.SessionStart | length == 2)' "$TMP/real-settings.json" >/dev/null 2>&1 \
  && ok_ "apply_managed_settings : lien conservé, cible fusionnée" || ko_ "apply_managed_settings : lien conservé, cible fusionnée"
[[ $(stat -c %a "$TMP/real-settings.json" 2>/dev/null || stat -f %Lp "$TMP/real-settings.json") == 600 ]] && ok_ "apply_managed_settings : droits conservés" || ko_ "apply_managed_settings : droits conservés"
[[ -z $(find "$TMP" -maxdepth 1 -name '.real-settings.json.*') ]] && ok_ "apply_managed_settings : aucun fichier temporaire résiduel" || ko_ "apply_managed_settings : fichier temporaire résiduel"
rm -rf "$HOME/.claude" "$KIT_CONFIG"

# ---------------------------------------------------------------------------
section "réglages gérés (kit sync, fusion à trois points)"
# Copie du kit : les tests y retirent ou ajoutent des règles sans jamais toucher au dépôt. KIT_SYNC_CONTEXT=0 saute le
# clonage des dépôts de contexte, KIT_SYNC_REGISTRY=0 ne régénère pas global/skills-registry.md.
KITC="$TMP/kitcopy"
mkdir -p "$KITC/global"
cp "$ROOT"/global/settings*.json "$KITC/global/"
cp -R "$ROOT/scripts" "$KITC/scripts"
reset_home() { rm -rf "$HOME/.claude" "$HOME/.kit" "$KIT_CONFIG"; mkdir -p "$HOME/.claude"; }
msync() { env KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 KIT_SYNC_REGISTRY=0 "$KITC/scripts/kit.sh" sync "$@"; }
cur_settings() { echo "$HOME/.claude/settings.json"; }
n_backups() { find "$HOME/.claude" -maxdepth 1 -name 'settings.json.pre-kit.*' | wc -l | tr -d ' '; }
jqc() { jq -e "$@" >/dev/null 2>&1; } # jqc <filtre> <fichier>
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sha256_hex_t() { ( source "$ROOT/scripts/lib.sh"; sha256_hex ); }
KIT_ALLOW_JSON="$KITC/global/settings.json"
RULE='Bash(git stash*)'   # règle du kit, retirée dans certains tests

# 1. Poste neuf : fichier et registre créés.
reset_home
msync >/dev/null 2>&1
jqc '.permissions.defaultMode == "auto" and (.permissions.allow | index("Bash(git status*)") != null)' "$(cur_settings)" \
  && ok_ "poste neuf : réglages créés depuis le kit" || ko_ "poste neuf : réglages créés depuis le kit"
[[ -f $KIT_CONFIG/settings.managed.json ]] && jqc 'has("permissions") and has("hooks")' "$KIT_CONFIG/settings.managed.json" \
  && ok_ "poste neuf : registre settings.managed.json écrit" || ko_ "poste neuf : registre écrit"
[[ $(n_backups) == 0 ]] && ok_ "poste neuf : aucune sauvegarde inutile" || ko_ "poste neuf : sauvegarde inutile"

# 2. Une règle retirée du kit disparaît ; les autres restent.
before=$(jq '.permissions.allow | length' "$(cur_settings)")
jq --arg r "$RULE" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
jqc --arg r "$RULE" '.permissions.allow | index($r) != null' "$(cur_settings)" && ok_ "retrait : la règle est d'abord présente" || ko_ "retrait : règle présente avant"
msync >/dev/null 2>&1
jqc --arg r "$RULE" '.permissions.allow | index($r) == null' "$(cur_settings)" && ok_ "retrait : la règle retirée du kit disparaît" || ko_ "retrait : la règle retirée du kit disparaît"
[[ $(jq '.permissions.allow | length' "$(cur_settings)") == $((before - 1)) ]] && ok_ "retrait : les autres règles restent" || ko_ "retrait : les autres règles restent"
[[ $(n_backups) == 1 ]] && ok_ "retrait : une sauvegarde pre-kit créée" || ko_ "retrait : sauvegarde pre-kit" "$(n_backups)"

# 3. Les ajouts de l'utilisateur survivent (règle, groupe de hooks, entrée autoMode), même après un autre retrait.
jq '.permissions.allow += ["Bash(make lint)"] | .permissions.deny += ["Bash(make deploy)"]
    | .hooks.Stop += [{"hooks": [{"type": "command", "command": "echo mon-hook"}]}]
    | .autoMode.environment += ["Mon serveur de test."]' "$(cur_settings)" >"$TMP/u.json" && cp "$TMP/u.json" "$(cur_settings)"
jq '.permissions.allow |= map(select(. != "Bash(git add*)"))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
msync >/dev/null 2>&1
jqc '.permissions.allow | index("Bash(make lint)") != null' "$(cur_settings)" && ok_ "ajout utilisateur : règle allow conservée" || ko_ "ajout utilisateur : allow"
jqc '.permissions.deny | index("Bash(make deploy)") != null' "$(cur_settings)" && ok_ "ajout utilisateur : règle deny conservée" || ko_ "ajout utilisateur : deny"
jqc '[.hooks.Stop[].hooks[].command] | index("echo mon-hook") != null' "$(cur_settings)" && ok_ "ajout utilisateur : groupe de hooks conservé" || ko_ "ajout utilisateur : hooks"
jqc '.autoMode.environment | index("Mon serveur de test.") != null' "$(cur_settings)" && ok_ "ajout utilisateur : entrée autoMode conservée" || ko_ "ajout utilisateur : autoMode"
jqc '.permissions.allow | index("Bash(git add*)") == null' "$(cur_settings)" && ok_ "ajout utilisateur : le retrait du kit s'applique en même temps" || ko_ "ajout utilisateur : retrait simultané"
# Les entrées du kit passent avant celles de l'utilisateur.
jqc '(.permissions.allow | index("Bash(make lint)")) > (.permissions.allow | index("Bash(git status*)"))' "$(cur_settings)" \
  && ok_ "ordre : kit d'abord, utilisateur ensuite" || ko_ "ordre : kit d'abord"

# 4. Idempotence : deux syncs donnent le même fichier, sans nouvelle sauvegarde ; le registre ne bouge pas.
cp "$(cur_settings)" "$TMP/i1.json"; cp "$KIT_CONFIG/settings.managed.json" "$TMP/r1.json"; b1=$(n_backups)
msync >/dev/null 2>&1
cmp -s "$(cur_settings)" "$TMP/i1.json" && ok_ "idempotence : fichier identique après un second sync" || ko_ "idempotence : fichier identique"
[[ $(n_backups) == "$b1" ]] && ok_ "idempotence : pas de nouvelle sauvegarde" || ko_ "idempotence : nouvelle sauvegarde"
cmp -s "$KIT_CONFIG/settings.managed.json" "$TMP/r1.json" && ok_ "idempotence : registre identique" || ko_ "idempotence : registre"

# 5. Le groupe SessionStart dupliqué (kit-emit, autre timeout) est fusionné ; les groupes de hooks du kit retirés aussi.
reset_home
msync >/dev/null 2>&1
n_ss=$(jq '.hooks.SessionStart | length' "$(cur_settings)")
jq '.hooks.SessionStart += [{"hooks": [{"type": "command", "command": "$HOME/.config/claude-kit/hooks/kit-emit.sh", "timeout": 10}]}]
    | .hooks.SessionStart += [.hooks.SessionStart[1]]' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
msync >/dev/null 2>&1
[[ $(jq '.hooks.SessionStart | length' "$(cur_settings)") == "$n_ss" ]] && ok_ "doublon : SessionStart ramené à $n_ss groupes" || ko_ "doublon : SessionStart" "$(jq -c '.hooks.SessionStart | length' "$(cur_settings)")"
jqc '[.hooks.SessionStart[].hooks[].timeout] | index(10) == null' "$(cur_settings)" && ok_ "doublon : le groupe en trop (timeout 10) a disparu" || ko_ "doublon : groupe en trop"
# Un groupe utilisateur (hors dossier du kit) n'est jamais pris pour un doublon.
jq '.hooks.SessionStart += [{"hooks": [{"type": "command", "command": "echo mien"}]}]' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
msync >/dev/null 2>&1
[[ $(jq '.hooks.SessionStart | length' "$(cur_settings)") == $((n_ss + 1)) ]] && ok_ "hooks : le groupe de l'utilisateur reste" || ko_ "hooks : groupe utilisateur"

# 6. --dry-run : écart par clé sur la sortie standard, rien d'écrit.
reset_home
msync >/dev/null 2>&1
jq '.permissions.allow += ["Bash(make lint)"]' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
jq --arg r "Bash(git commit*)" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
tree_sum() { (cd "$HOME" && { find . | sort; find . -type f -exec cksum {} +; } 2>/dev/null | sort | cksum); }
t1=$(tree_sum)
dout=$(msync --dry-run 2>&1); rc=$?
[[ $rc == 0 && $(tree_sum) == "$t1" ]] && ok_ "dry-run : rien d'écrit (fichiers, sauvegardes, registre)" || ko_ "dry-run : rien d'écrit"
grep -q 'permissions.allow : +0 -1' <<<"$dout" && grep -qF -- '- "Bash(git commit*)"' <<<"$dout" \
  && ok_ "dry-run : écart par clé (entrée retirée listée)" || ko_ "dry-run : écart par clé" "$dout"
! grep -q 'make lint' <<<"$dout" && ok_ "dry-run : l'ajout utilisateur n'est pas touché" || ko_ "dry-run : ajout utilisateur"
reset_home
msync --dry-run >/dev/null 2>&1
[[ ! -e $HOME/.claude/settings.json && ! -e $KIT_CONFIG ]] && ok_ "dry-run : poste neuf, rien créé" || ko_ "dry-run : poste neuf"
msync --bogus >/dev/null 2>&1 && ko_ "sync : option inconnue refusée" || ok_ "sync : option inconnue refusée"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 7. Lien symbolique et droits de settings.json conservés ; aucun fichier temporaire résiduel.
reset_home
echo '{"model":"sonnet"}' >"$TMP/real-settings.json"
chmod 600 "$TMP/real-settings.json"
ln -s "$TMP/real-settings.json" "$HOME/.claude/settings.json"
msync >/dev/null 2>&1
[[ -L $HOME/.claude/settings.json ]] && jqc '.model == "sonnet" and (.permissions.allow | length > 10)' "$TMP/real-settings.json" \
  && ok_ "lien symbolique : conservé, cible mise à jour" || ko_ "lien symbolique conservé"
[[ $(stat -c %a "$TMP/real-settings.json" 2>/dev/null || stat -f %Lp "$TMP/real-settings.json") == 600 ]] && ok_ "droits : 600 conservés" || ko_ "droits conservés"
[[ -z $(find "$TMP" -maxdepth 1 -name '.real-settings.json.*') ]] && ok_ "aucun fichier temporaire résiduel" || ko_ "fichier temporaire résiduel"
rm -f "$TMP/real-settings.json"

# 8. Migration sans registre (poste v1) : instantané v1 = entrées du kit. Ajouts utilisateur gardés, règles retirées perdues.
reset_home
jq --arg r "$RULE" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
# Fichier de la v1 : union triée de tout ce que le kit v1 écrivait, plus des ajouts de l'utilisateur.
jq '.permissions.allow = ((.permissions.allow + ["Bash(make lint)"]) | sort)
    | .hooks.SessionStart += [{"hooks": [{"type": "command", "command": "$HOME/.config/claude-kit/hooks/kit-emit.sh", "timeout": 10}]}]
    | .hooks.Stop += [{"hooks": [{"type": "command", "command": "echo mon-hook"}]}]' \
  "$ROOT/global/settings.v1.json" >"$(cur_settings)"
[[ ! -e $KIT_CONFIG/settings.managed.json ]] && ok_ "migration : pas de registre au départ" || ko_ "migration : registre présent"
dout=$(msync --dry-run 2>&1)
grep -q 'registre absent' <<<"$dout" && ok_ "migration : dry-run signale l'absence de registre" || ko_ "migration : dry-run" "$dout"
msync >/dev/null 2>&1
jqc '.permissions.allow | index("Bash(make lint)") != null' "$(cur_settings)" && ok_ "migration : ajout utilisateur conservé" || ko_ "migration : ajout utilisateur"
jqc '[.hooks.Stop[].hooks[].command] | index("echo mon-hook") != null' "$(cur_settings)" && ok_ "migration : hook utilisateur conservé" || ko_ "migration : hook utilisateur"
jqc --arg r "$RULE" '.permissions.allow | index($r) == null' "$(cur_settings)" && ok_ "migration : règle v1 retirée du kit supprimée" || ko_ "migration : règle v1 retirée"
jqc '.hooks.SessionStart | length == 2' "$(cur_settings)" && ok_ "migration : SessionStart dédoublonné" || ko_ "migration : SessionStart"
[[ -f $KIT_CONFIG/settings.managed.json ]] && ok_ "migration : registre créé" || ko_ "migration : registre créé"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 8b. Migration sans registre, autoMode : l'instantané v1 ne contient que des empreintes SHA-256 (le dépôt est public).
jqc 'has("autoMode") | not' "$ROOT/global/settings.v1.json" && jqc '.autoModeSha256 | [.[][]] | length > 0 and all(test("^[0-9a-f]{64}$"))' "$ROOT/global/settings.v1.json" \
  && ok_ "instantané v1 : autoMode en empreintes SHA-256 seulement, rien en clair" || ko_ "instantané v1 : autoMode"
dig=$(printf '%s' '$defaults' | sha256_hex_t)
jqc --arg d "$dig" '[.autoModeSha256[][]] | index($d) != null' "$ROOT/global/settings.v1.json" \
  && ok_ "instantané v1 : l'empreinte d'une entrée connue y figure" || ko_ "instantané v1 : empreinte connue"
reset_home
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
# Le kit d'aujourd'hui ne livre plus l'entrée « Trusted internal domains… » (cas du lot 2c).
jq '.autoMode.environment |= map(select(startswith("Trusted internal domains") | not))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
# Fichier v1 : toutes les entrées autoMode du kit v1 (ici celles de global/settings.json), plus une entrée de l'utilisateur.
jq '.autoMode as $am | {permissions: {allow: ["Bash(ls*)"]}, autoMode: ($am | .environment += ["Mon serveur de test."])}' "$ROOT/global/settings.json" >"$(cur_settings)"
jqc '.autoMode.environment | map(select(startswith("Trusted internal domains"))) | length == 1' "$(cur_settings)" \
  && ok_ "migration autoMode : l'entrée à retirer est d'abord présente" || ko_ "migration autoMode : entrée présente avant"
msync >/dev/null 2>&1
jqc '.autoMode.environment | map(select(startswith("Trusted internal domains"))) | length == 0' "$(cur_settings)" \
  && ok_ "migration autoMode : une entrée v1 (empreinte connue) retirée du kit est supprimée" || ko_ "migration autoMode : entrée v1 supprimée"
jqc '.autoMode.environment | index("Mon serveur de test.") != null' "$(cur_settings)" \
  && ok_ "migration autoMode : l'entrée de l'utilisateur reste" || ko_ "migration autoMode : entrée utilisateur"
jqc '(.autoMode.environment | index("$defaults") != null) and (.autoMode.hard_deny | length == 2)' "$(cur_settings)" \
  && ok_ "migration autoMode : les entrées toujours livrées restent" || ko_ "migration autoMode : entrées livrées"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 9. Clés non gérées intactes (y compris une clé inconnue) ; sauvegarde conservant l'ancien contenu.
reset_home
cat >"$(cur_settings)" <<'EOF'
{"model": "opus", "statusLine": {"type": "command", "command": "echo s"}, "enabledPlugins": {"p@m": true},
 "env": {"UNE_VARIABLE": "valeur"}, "autre": [1, 2], "permissions": {"allow": ["Bash(make lint)"], "additionalDirectories": ["/tmp/x"]}}
EOF
msync >/dev/null 2>&1
jqc '.model == "opus" and .statusLine.command == "echo s" and .enabledPlugins["p@m"] == true and .env.UNE_VARIABLE == "valeur" and .autre == [1, 2] and .permissions.additionalDirectories == ["/tmp/x"]' "$(cur_settings)" \
  && ok_ "clés non gérées : model, statusLine, enabledPlugins, env, permissions.additionalDirectories intactes" || ko_ "clés non gérées"
jqc '.permissions.allow | index("Bash(make lint)") != null' "$(cur_settings)" && ok_ "clés non gérées : la règle utilisateur reste aussi" || ko_ "clés non gérées : règle"
bk=$(find "$HOME/.claude" -maxdepth 1 -name 'settings.json.pre-kit.*' | head -1)
[[ -n $bk ]] && jqc '.model == "opus" and (.permissions.allow == ["Bash(make lint)"])' "$bk" && ok_ "sauvegarde : contient l'ancien contenu" || ko_ "sauvegarde : ancien contenu"

# 10. Surcharge propre au poste : settings.local.json (jamais dans Git), ajoutée puis retirée.
reset_home
msync >/dev/null 2>&1
mkdir -p "$KIT_CONFIG"
echo '{"permissions":{"allow":["Bash(mon-outil *)"]},"autoMode":{"environment":["Domaine interne de ce poste."]}}' >"$KIT_CONFIG/settings.local.json"
msync >/dev/null 2>&1
jqc '(.permissions.allow | index("Bash(mon-outil *)") != null) and (.autoMode.environment | index("Domaine interne de ce poste.") != null)' "$(cur_settings)" \
  && ok_ "surcharge : entrées de settings.local.json appliquées" || ko_ "surcharge : appliquée"
rm -f "$KIT_CONFIG/settings.local.json"
msync >/dev/null 2>&1
jqc '(.permissions.allow | index("Bash(mon-outil *)") == null) and (.autoMode.environment | index("Domaine interne de ce poste.") == null)' "$(cur_settings)" \
  && ok_ "surcharge : retirer le fichier retire ses entrées" || ko_ "surcharge : retirée"
[[ -z $(git -C "$ROOT" ls-files -- '*settings.local.json' 2>/dev/null) ]] && ok_ "surcharge : aucun settings.local.json versionné dans le kit" || ko_ "surcharge : fichier versionné"
echo '{"permissions": ' >"$KIT_CONFIG/settings.local.json"
before_sum=$(cksum <"$(cur_settings)")
msync >/dev/null 2>&1 && ko_ "surcharge : JSON invalide refusé" || ok_ "surcharge : JSON invalide refusé"
[[ $(cksum <"$(cur_settings)") == "$before_sum" ]] && ok_ "surcharge invalide : settings.json intact" || ko_ "surcharge invalide : settings.json touché"

# 11. Profil vps : defaultMode et fragments du profil ; JSON invalide : refus sans écriture.
reset_home
mkdir -p "$KIT_CONFIG"; echo vps >"$KIT_CONFIG/profile"
msync >/dev/null 2>&1
jqc '.permissions.defaultMode == "default" and (.permissions.ask | index("Bash(cp *)") != null)' "$(cur_settings)" \
  && ok_ "profil vps : defaultMode et fragment appliqués" || ko_ "profil vps"
echo local >"$KIT_CONFIG/profile"
msync >/dev/null 2>&1
jqc '.permissions.defaultMode == "default"' "$(cur_settings)" && ok_ "profil local après vps : defaultMode plus permissif refusé sans --yes" || ko_ "profil local après vps : refus"
msync --yes >/dev/null 2>&1
jqc '.permissions.defaultMode == "auto" and (.permissions.deny | index("Bash(kit secrets run -- wrangler deploy*)") != null)' "$(cur_settings)" \
  && ok_ "profil local après vps : --yes passe en auto, les deny restent (jamais retirés)" || ko_ "profil local après vps : --yes"
echo '{"permissions": ' >"$(cur_settings)"
nb0=$(n_backups)
dout=$(msync 2>&1); rc=$?
[[ $rc != 0 && $(cat "$(cur_settings)") == '{"permissions": ' && $(n_backups) == "$nb0" ]] && ok_ "settings.json invalide : refus, rien écrit" || ko_ "settings.json invalide" "code $rc : $dout"

# 12. Au plus 3 sauvegardes pre-kit : la plus ancienne et les deux plus récentes.
reset_home
msync >/dev/null 2>&1
for n in 1 2 3 4 5; do echo '{}' >"$HOME/.claude/settings.json.pre-kit.2020010100000$n"; done
jq --arg r "Bash(git add*)" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
msync >/dev/null 2>&1
[[ $(n_backups) == 3 ]] && ok_ "sauvegardes : 3 conservées au plus" || ko_ "sauvegardes : 3 au plus" "$(n_backups)"
[[ -e $HOME/.claude/settings.json.pre-kit.20200101000001 && ! -e $HOME/.claude/settings.json.pre-kit.20200101000002 \
  && ! -e $HOME/.claude/settings.json.pre-kit.20200101000004 && -e $HOME/.claude/settings.json.pre-kit.20200101000005 ]] \
  && ok_ "sauvegardes : la plus ancienne et la plus récente gardées, les intermédiaires supprimées" || ko_ "sauvegardes : rotation"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 13. KIT_SYNC_CONTEXT=0 : aucun clonage des dépôts de contexte ; rien n'est écrit dans le dépôt du kit.
reset_home
printf 'exemple/depot-prive\n' >"$KITC/global/context-repos.txt"
msync >/dev/null 2>&1
[[ ! -e $HOME/.kit ]] && ok_ "KIT_SYNC_CONTEXT=0 : ~/.kit/context non créé" || ko_ "KIT_SYNC_CONTEXT=0"
rm -f "$KITC/global/context-repos.txt"
reset_home

# 14. deny et ask ne sont jamais retirés automatiquement : une règle identique à une règle du kit survit à son retrait.
reset_home
msync >/dev/null 2>&1
jq '.permissions.deny |= map(select(. != "Bash(sudo *)")) | .permissions.ask |= map(select(. != "Bash(rm *)"))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
msync >/dev/null 2>&1
jqc '.permissions.deny | index("Bash(sudo *)") != null' "$(cur_settings)" && ok_ "deny : une règle retirée du kit n'est pas retirée du fichier" || ko_ "deny retiré automatiquement"
jqc '.permissions.ask | index("Bash(rm *)") != null' "$(cur_settings)" && ok_ "ask : une règle retirée du kit n'est pas retirée du fichier" || ko_ "ask retiré automatiquement"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
# Seule une règle listée dans global/settings.retired.json est retirée, et la sortie la nomme.
jq '.permissions.deny += ["Bash(retire-x)", "Bash(garde-y)"]' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
echo '{"permissions":{"deny":["Bash(retire-x)"],"ask":[]}}' >"$KITC/global/settings.retired.json"
dout=$(msync 2>&1)
jqc '(.permissions.deny | index("Bash(retire-x)")) == null and (.permissions.deny | index("Bash(garde-y)")) != null' "$(cur_settings)" \
  && ok_ "retired : seule la règle listée est retirée" || ko_ "retired : règle listée"
grep -q 'retiré de permissions.deny : "Bash(retire-x)"' <<<"$dout" && ok_ "retired : la règle retirée est nommée dans la sortie" || ko_ "retired : sortie" "$dout"
rm -f "$KITC/global/settings.retired.json"
[[ $(jq -r '.permissions | keys | join(",")' "$ROOT/global/settings.retired.json") == "ask,deny" ]] && ok_ "settings.retired.json : forme permissions.ask|deny" || ko_ "settings.retired.json : forme"

# 15. Migration locale : les entrées vps-only de l'utilisateur ne sont pas retirées (ask git push, ask mv, deny wrangler).
reset_home
jq '.permissions.ask = ["Bash(git push*)", "Bash(mv *)"] | .permissions.deny = ["Bash(kit secrets run -- wrangler deploy*)"]' \
  "$ROOT/global/settings.v1.json" >"$(cur_settings)"
msync >/dev/null 2>&1
jqc '(.permissions.ask | index("Bash(git push*)") != null) and (.permissions.ask | index("Bash(mv *)") != null)
     and (.permissions.deny | index("Bash(kit secrets run -- wrangler deploy*)") != null)' "$(cur_settings)" \
  && ok_ "migration locale : ask et deny de l'utilisateur conservés" || ko_ "migration locale : ask/deny"
jqc '.permissions.defaultMode == "auto"' "$(cur_settings)" && ok_ "migration locale : defaultMode du kit posé (aucun mode antérieur)" || ko_ "migration locale : defaultMode"

# 16. Hooks : seules les entrées exactement du kit (préfixe ancré, script du kit, même matcher) lui appartiennent.
reset_home
msync >/dev/null 2>&1
gm=$(jq -r '[.hooks.PreToolUse[] | select(any(.hooks[]?; (.command // "") | endswith("guard-secrets.sh")))][0].matcher' "$(cur_settings)")
gc=$(jq -r '[.hooks.PreToolUse[] | .hooks[] | select(.command | endswith("guard-secrets.sh")) | .command][0]' "$(cur_settings)")
jq --arg gm "$gm" --arg gc "$gc" '
    (.hooks.PreToolUse[] | select(.matcher == $gm and any(.hooks[]; .command == $gc)) | .hooks) += [{"type": "command", "command": "echo mien-dans-le-groupe"}]
    | .hooks.PreToolUse += [{"matcher": "WebFetch|mcp__.*", "hooks": [{"type": "command", "command": $gc}]},
                            {"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/acme/claude-kit/hooks/corp-dlp.sh"}]}]
    | .hooks.Stop += [{"hooks": [{"type": "command", "command": "$HOME/.config/claude-kit/hooks/perso.sh"}]}]
    | .hooks.PermissionRequest = [{"hooks": [{"type": "command", "command": "echo pr"}]}]
    | .hooks.SessionStart += [(.hooks.SessionStart[0] | .hooks[0].timeout = 10)]' \
  "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
dout=$(msync 2>&1)
jqc --arg gm "$gm" '[.hooks.PreToolUse[] | select(.matcher == $gm) | .hooks[].command] | index("echo mien-dans-le-groupe") != null' "$(cur_settings)" \
  && ok_ "hooks : le hook de l'utilisateur ajouté dans le groupe du kit reste" || ko_ "hooks : hook dans le groupe du kit"
jqc --arg gc "$gc" '[.hooks.PreToolUse[] | .hooks[].command | select(. == $gc)] | length == 2' "$(cur_settings)" \
  && ok_ "hooks : guard-secrets du kit une fois, plus celui du groupe utilisateur (autre matcher)" || ko_ "hooks : script du kit réutilisé"
jqc 'any(.hooks.PreToolUse[]; .matcher == "WebFetch|mcp__.*")' "$(cur_settings)" && ok_ "hooks : groupe utilisateur réutilisant guard-secrets (autre matcher) conservé" || ko_ "hooks : autre matcher"
jqc '[.hooks.Stop[].hooks[].command] | index("$HOME/.config/claude-kit/hooks/perso.sh") != null' "$(cur_settings)" && ok_ "hooks : hook personnel dans le dossier des hooks conservé" || ko_ "hooks : hook personnel"
jqc '[.hooks.PreToolUse[].hooks[].command] | index("/opt/acme/claude-kit/hooks/corp-dlp.sh") != null' "$(cur_settings)" && ok_ "hooks : chemin tiers /opt/acme/claude-kit/hooks conservé" || ko_ "hooks : chemin tiers"
jqc '.hooks.PermissionRequest | length == 1' "$(cur_settings)" && ok_ "hooks : événement PermissionRequest de l'utilisateur conservé" || ko_ "hooks : événement entier"
jqc '[.hooks.SessionStart[].hooks[].timeout] | index(10) == null' "$(cur_settings)" && ok_ "hooks : le doublon du kit (timeout 10) est retiré" || ko_ "hooks : doublon"
grep -q 'retiré de hooks.SessionStart' <<<"$dout" && ok_ "hooks : le groupe retiré est nommé dans la sortie" || ko_ "hooks : sortie" "$dout"
msync >/dev/null 2>&1
jqc '([.hooks.PreToolUse[] | .hooks[].command | select(endswith("guard-secrets.sh"))] | length == 2) and ([.hooks.PreToolUse[].hooks[].command] | index("echo mien-dans-le-groupe") != null)' "$(cur_settings)" \
  && ok_ "hooks : second sync stable (rien de perdu, rien de dupliqué)" || ko_ "hooks : second sync"

# 17. Invariant : toute règle deny/ask de K est dans le résultat, quels que soient C, L et les règles retirées.
pool=('Bash(r1)' 'Bash(r2)' 'Bash(r3)' 'Bash(r4)' 'Bash(r5)' 'Bash(r6)' 'Bash(r7)' 'Bash(r8)')
rs() { local o="[" first=1 p; for p in "${pool[@]}"; do if ((RANDOM % 2)); then ((first)) || o+=","; o+="\"$p\""; first=0; fi; done; RS="$o]"; }
inv_bad=0
for _ in $(seq 1 40); do
  rs; kd=$RS; rs; ka=$RS
  rs; c1=$RS; rs; c2=$RS; rs; c3=$RS; rs; l1=$RS; rs; l2=$RS; rs; l3=$RS; rs; r1=$RS; rs; r2=$RS; rs; k3=$RS
  cobj="{\"permissions\":{\"deny\":$c1,\"ask\":$c2,\"allow\":$c3}}"
  lobj="{\"permissions\":{\"deny\":$l1,\"ask\":$l2,\"allow\":$l3}}"
  robj="{\"permissions\":{\"deny\":$r1,\"ask\":$r2}}"
  kobj="{\"permissions\":{\"deny\":$kd,\"ask\":$ka,\"allow\":$k3}}"
  jq -n --arg mode merge --argjson prefixes '[]' --argjson names '[]' --argjson yes false \
    --slurpfile c <(echo "$cobj") --slurpfile k <(echo "$kobj") --slurpfile l <(echo "$lobj") --slurpfile r <(echo "$robj") \
    -f "$ROOT/scripts/managed-settings.jq" \
    | jq -e --argjson kd "$kd" --argjson ka "$ka" '(.new.permissions.deny // []) as $d | (.new.permissions.ask // []) as $a
        | all($kd[]; . as $x | $d | index($x) != null) and all($ka[]; . as $x | $a | index($x) != null)' >/dev/null 2>&1 || inv_bad=$((inv_bad + 1))
done
((inv_bad == 0)) && ok_ "invariant : toute règle deny/ask de K est dans le résultat (40 tirages aléatoires)" || ko_ "invariant deny/ask" "$inv_bad tirages en défaut"

# 18. Surcharge locale : droits 600, refus de bypassPermissions et des règles larges, contenu affiché à chaque sync.
reset_home
msync >/dev/null 2>&1
[[ $(fmode "$KIT_CONFIG") == 700 ]] && ok_ "droits : dossier de config créé en 700" || ko_ "droits : dossier de config" "$(fmode "$KIT_CONFIG")"
[[ $(fmode "$KIT_CONFIG/settings.managed.json") == 600 ]] && ok_ "droits : registre en 600" || ko_ "droits : registre" "$(fmode "$KIT_CONFIG/settings.managed.json")"
echo '{"permissions":{"allow":["Bash(mon-outil *)"]},"autoMode":{"environment":["Entree locale."]}}' >"$KIT_CONFIG/settings.local.json"
chmod 644 "$KIT_CONFIG/settings.local.json"
dout=$(msync 2>&1)
[[ $(fmode "$KIT_CONFIG/settings.local.json") == 600 ]] && ok_ "droits : surcharge remise en 600" || ko_ "droits : surcharge"
grep -q 'surcharge locale' <<<"$dout" && grep -qF 'Bash(mon-outil *)' <<<"$dout" && grep -q 'autoMode.environment : +1' <<<"$dout" \
  && ok_ "surcharge : ce qu'elle apporte est affiché à chaque sync" || ko_ "surcharge : affichage" "$dout"
! grep -q 'Entree locale' <<<"$dout" && ok_ "surcharge : le texte des entrées autoMode n'est pas affiché" || ko_ "surcharge : texte autoMode affiché"
sum_before=$(cksum <"$(cur_settings)")
for bad in '"defaultMode":"bypassPermissions"' '"allow":["Bash(*)"]' '"allow":["Bash"]' '"allow":["*"]' '"allow":["Edit"]' '"allow":["Write"]' '"allow":["Write(*)"]'; do
  body="{\"permissions\":{$bad}}"
  echo "$body" >"$KIT_CONFIG/settings.local.json"
  dout=$(msync 2>&1); rc=$?
  if [[ $rc != 0 && $(cksum <"$(cur_settings)") == "$sum_before" ]] && grep -q 'surcharge refusée' <<<"$dout"; then ok_ "surcharge refusée : $bad"; else ko_ "surcharge refusée : $bad" "code $rc : $dout"; fi
done
echo '{"permissions":{"allow":["Edit(src/**)","Write(docs/*)"]}}' >"$KIT_CONFIG/settings.local.json"
msync >/dev/null 2>&1 && ok_ "surcharge : règles Edit/Write avec chemin acceptées" || ko_ "surcharge : règles avec chemin"
rm -f "$KIT_CONFIG/settings.local.json"

# 19. defaultMode : un passage à un mode plus permissif est refusé sans --yes.
reset_home
msync >/dev/null 2>&1
jq '.permissions.defaultMode = "default"' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
dout=$(msync 2>&1)
jqc '.permissions.defaultMode == "default"' "$(cur_settings)" && grep -q 'plus permissif' <<<"$dout" \
  && ok_ "defaultMode : default -> auto refusé sans --yes (avertissement)" || ko_ "defaultMode : refus" "$dout"
msync --yes >/dev/null 2>&1
jqc '.permissions.defaultMode == "auto"' "$(cur_settings)" && ok_ "defaultMode : accepté avec --yes" || ko_ "defaultMode : --yes"
jq '.permissions.defaultMode = "plan"' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
dout=$(msync --dry-run 2>&1)
grep -q 'plus permissif' <<<"$dout" && ok_ "defaultMode : le dry-run signale aussi le refus" || ko_ "defaultMode : dry-run" "$dout"
jq 'del(.permissions.defaultMode)' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
msync >/dev/null 2>&1
jqc '.permissions.defaultMode == "auto"' "$(cur_settings)" && ok_ "defaultMode : posé quand le fichier n'en a pas" || ko_ "defaultMode : absent"

# 20. Profil absent : le profil du registre (vps) est conservé, pas de retour silencieux à local.
reset_home
mkdir -p "$KIT_CONFIG"; echo vps >"$KIT_CONFIG/profile"
msync >/dev/null 2>&1
rm -f "$KIT_CONFIG/profile"
dout=$(msync 2>&1)
grep -q 'profil introuvable' <<<"$dout" && jqc '.permissions.defaultMode == "default"' "$(cur_settings)" \
  && [[ $(jq -r '.profile' "$KIT_CONFIG/settings.managed.json") == vps ]] \
  && ok_ "profil absent : le profil vps du registre est conservé (avertissement)" || ko_ "profil absent" "$dout"

# 21. Registre corrompu ou modifié à la main : traité comme absent (avertissement), rien de perdu.
reset_home
msync >/dev/null 2>&1
jq '.permissions.allow += ["Bash(make lint)"]' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
for body in '{"permissions": ' '{"hooks": [1]}' '{"permissions": "x"}' '[]' '{"autoMode": {"environment": "texte"}}'; do
  printf '%s\n' "$body" >"$KIT_CONFIG/settings.managed.json"
  dout=$(msync 2>&1); rc=$?
  if [[ $rc == 0 ]] && grep -q 'illisible' <<<"$dout" && jqc '.permissions.allow | index("Bash(make lint)") != null' "$(cur_settings)" \
    && jq -e 'type == "object" and has("profile")' "$KIT_CONFIG/settings.managed.json" >/dev/null 2>&1; then ok_ "registre corrompu ($body) : migration refaite, ajout conservé"
  else ko_ "registre corrompu ($body)" "code $rc : $dout"; fi
done

# 22. Échec en cours de route : ni dossier temporaire ni verrou résiduels.
reset_home
mkdir -p "$TMP/tmpd"
cp "$KITC/global/settings.v1.json" "$TMP/snap.bak"
echo '{' >"$KITC/global/settings.v1.json"
env TMPDIR="$TMP/tmpd" KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 KIT_SYNC_REGISTRY=0 "$KITC/scripts/kit.sh" sync >/dev/null 2>&1 && rc=0 || rc=$?
[[ $rc != 0 && -z $(ls -A "$TMP/tmpd") && ! -e $KIT_CONFIG/settings.lock ]] && ok_ "échec : dossier temporaire et verrou nettoyés" || ko_ "échec : nettoyage" "code $rc : $(ls -A "$TMP/tmpd")"
cp "$TMP/snap.bak" "$KITC/global/settings.v1.json"

# 23. Verrou : tenu par un processus vivant, le second sync attend puis renonce ; un verrou orphelin est repris.
reset_home
msync >/dev/null 2>&1
jq --arg r "Bash(git add*)" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
sleep 60 & holder=$!
mkdir "$KIT_CONFIG/settings.lock" && echo "$holder" >"$KIT_CONFIG/settings.lock/pid"
cp "$(cur_settings)" "$TMP/lock-before.json"
dout=$(env KIT_LOCK_WAIT=1 KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 KIT_SYNC_REGISTRY=0 "$KITC/scripts/kit.sh" sync 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q 'settings.lock' <<<"$dout" && cmp -s "$(cur_settings)" "$TMP/lock-before.json" \
  && ok_ "verrou tenu : le second sync attend, renonce avec un message, ne touche à rien" || ko_ "verrou tenu" "code $rc : $dout"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
dout=$(msync 2>&1)
jqc '.permissions.allow | index("Bash(git add*)") == null' "$(cur_settings)" && [[ ! -e $KIT_CONFIG/settings.lock ]] \
  && ok_ "verrou orphelin (processus mort) : repris, réglages appliqués, verrou libéré" || ko_ "verrou orphelin" "$dout"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
# Le fichier a changé entre la lecture et l'écriture : rien n'est écrit.
reset_home
msync >/dev/null 2>&1
jq --arg r "Bash(git add*)" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
SHIM="$TMP/shim"; mkdir -p "$SHIM"; : >"$TMP/shim.cnt"
cat >"$SHIM/cksum" <<EOF
#!/bin/sh
n=\$(cat "$TMP/shim.cnt" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$TMP/shim.cnt"
if [ "\$n" -ge 1 ]; then echo "1 1"; else exec "$(command -v cksum)"; fi
EOF
chmod +x "$SHIM/cksum"
cp "$(cur_settings)" "$TMP/race-before.json"
dout=$(env PATH="$SHIM:$PATH" KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 KIT_SYNC_REGISTRY=0 "$KITC/scripts/kit.sh" sync 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q 'a changé pendant la fusion' <<<"$dout" && cmp -s "$(cur_settings)" "$TMP/race-before.json" \
  && ok_ "fichier modifié pendant la fusion : rien d'écrit, message" || ko_ "fichier modifié pendant la fusion" "code $rc : $dout"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 24. Sauvegardes : suffixes non datés ignorés, plus ancienne conservée, pas d'écrasement dans la même seconde.
reset_home
msync >/dev/null 2>&1
echo '{}' >"$HOME/.claude/settings.json.pre-kit.notadate"
echo '{}' >"$HOME/.claude/settings.json.pre-kit.2020"
for r in 'Bash(git add*)' 'Bash(git commit*)' 'Bash(git switch*)'; do
  jq --arg r "$r" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
  msync >/dev/null 2>&1
done
valid_backups=$(find "$HOME/.claude" -maxdepth 1 -name 'settings.json.pre-kit.[0-9]*' | grep -cE '\.pre-kit\.[0-9]{14}$' || true)
[[ $valid_backups == 3 ]] && ok_ "sauvegardes : trois changements dans la même seconde, trois sauvegardes distinctes" || ko_ "sauvegardes : même seconde" "$valid_backups"
[[ -e $HOME/.claude/settings.json.pre-kit.notadate && -e $HOME/.claude/settings.json.pre-kit.2020 ]] \
  && ok_ "sauvegardes : suffixes non datés ni comptés ni supprimés" || ko_ "sauvegardes : suffixe non daté"
oldest=$(find "$HOME/.claude" -maxdepth 1 -name 'settings.json.pre-kit.[0-9]*' | grep -E '\.pre-kit\.[0-9]{14}$' | sort | head -1)
jq --arg r "Bash(git stash*)" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
msync >/dev/null 2>&1
valid_backups=$(find "$HOME/.claude" -maxdepth 1 -name 'settings.json.pre-kit.[0-9]*' | grep -cE '\.pre-kit\.[0-9]{14}$' || true)
[[ $valid_backups == 3 && -e $oldest ]] && ok_ "sauvegardes : toujours 3, la plus ancienne conservée" || ko_ "sauvegardes : plus ancienne" "$valid_backups, $oldest"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 25. Entrées autoMode avec tabulation et antislash : l'empreinte est celle de la chaîne exacte.
reset_home
odd=$'Entree\tavec tab et \\antislash "guillemets"'
dig=$(printf '%s' "$odd" | sha256_hex_t)
jq --arg d "$dig" '.autoModeSha256.environment += [$d]' "$KITC/global/settings.v1.json" >"$TMP/s.json" && cp "$TMP/s.json" "$KITC/global/settings.v1.json"
jq -n --arg odd "$odd" '{autoMode: {environment: [$odd, "Entree utilisateur"]}}' >"$(cur_settings)"
msync >/dev/null 2>&1
jqc '.autoMode.environment | index("Entree utilisateur") != null' "$(cur_settings)" && jq -e --arg odd "$odd" '.autoMode.environment | index($odd) == null' "$(cur_settings)" >/dev/null 2>&1 \
  && ok_ "autoMode : entrée à tabulation et antislash (empreinte connue) retirée, entrée utilisateur conservée" || ko_ "autoMode : tab et antislash" "$(jq -c '.autoMode' "$(cur_settings)")"
cp "$ROOT/global/settings.v1.json" "$KITC/global/settings.v1.json"

# 26. Options : toute option inconnue est refusée, même après --dry-run.
msync --dry-run --bogus >/dev/null 2>&1 && ko_ "sync --dry-run --bogus refusé" || ok_ "sync --dry-run --bogus refusé"
reset_home

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
section "tailles S/M/L : kit project size, kit project effort"
KIT="$ROOT/scripts/kit.sh"
SZ="$TMP/size-proj"
bash "$KIT" project init "$SZ" >/dev/null 2>&1
[[ -f $SZ/project.yaml ]] && ok_ "gabarit : project.yaml copié" || ko_ "gabarit : project.yaml absent"
imports() { grep -c '^@docs/rules/size-' "$SZ/CLAUDE.md" || true; }
rule_files() { find "$SZ/docs" -name 'size-*.md' 2>/dev/null | wc -l | tr -d ' '; }

bash "$KIT" project size S --reason "site vitrine, données statiques" --dir "$SZ" >/dev/null 2>&1
[[ $(grep '^size:' "$SZ/project.yaml") == "size: S" && $(grep '^size_reason:' "$SZ/project.yaml") == "size_reason: site vitrine, données statiques" ]] \
  && ok_ "size S : project.yaml (size, size_reason)" || ko_ "size S : project.yaml" "$(cat "$SZ/project.yaml")"
[[ $(grep -c '^name: ' "$SZ/project.yaml") == 1 && $(grep '^name:' "$SZ/project.yaml") != "name: TODO" ]] \
  && ok_ "size : name déduit du dossier" || ko_ "size : name"
[[ $(imports) == 0 && $(rule_files) == 0 ]] && ok_ "size S : aucune règle ni import" || ko_ "size S : règles ou imports présents" "$(imports) imports, $(rule_files) fichiers"

bash "$KIT" project size M --reason "données propres" --dir "$SZ" >/dev/null 2>&1
[[ $(imports) == 1 && -f $SZ/docs/rules/size-M.md && ! -e $SZ/docs/rules/size-L.md ]] \
  && ok_ "size M : size-M.md copié et importé, pas size-L" || ko_ "size M" "$(imports) imports"
grep -qxF '@docs/rules/size-M.md' "$SZ/CLAUDE.md" && [[ $(sed -n '/^@AGENTS.md$/{n;p;}' "$SZ/CLAUDE.md") == "@docs/rules/size-M.md" ]] \
  && ok_ "size M : l'import suit @AGENTS.md" || ko_ "size M : place de l'import"

bash "$KIT" project size L --reason "comptes pour des inconnus" --dir "$SZ" >/dev/null 2>&1
bash "$KIT" project size L --reason "comptes pour des inconnus" --dir "$SZ" >/dev/null 2>&1
[[ $(imports) == 2 && $(rule_files) == 2 && $(grep -c '^size:' "$SZ/project.yaml") == 1 ]] \
  && ok_ "size L deux fois : M et L importés une seule fois, une seule ligne size" || ko_ "size L idempotent" "$(imports) imports, $(rule_files) fichiers"

bash "$KIT" project size S --reason "finalement un prototype" --dir "$SZ" >/dev/null 2>&1
[[ $(imports) == 0 && $(rule_files) == 0 && ! -d $SZ/docs/rules ]] \
  && ok_ "S -> L -> S : plus d'import, de règle ni de dossier docs/rules" || ko_ "S -> L -> S" "$(imports) imports, $(rule_files) fichiers"
[[ $(grep -c '^- \*\*Taille\*\* : `S`' "$SZ/CLAUDE.md") == 1 ]] \
  && ok_ "size : ligne « Taille » de CLAUDE.md mise à jour" || ko_ "size : ligne Taille"
bash "$KIT" project size M --dir "$SZ" >/dev/null 2>&1 \
  && [[ $(grep '^size_reason:' "$SZ/project.yaml") == "size_reason: finalement un prototype" ]] \
  && ok_ "size sans --reason : garde la justification existante" || ko_ "size sans --reason"

SZ2="$TMP/size-proj2"; mkdir -p "$SZ2"
bash "$KIT" project size L --dir "$SZ2" >/dev/null 2>&1 && ko_ "size sans justification : doit échouer" || ok_ "size sans justification (projet neuf) : refusé"
bash "$KIT" project size XL --reason x --dir "$SZ" >/dev/null 2>&1 && ko_ "size XL : doit échouer" || ok_ "taille invalide refusée"
bash "$KIT" project size L --reason "x" --dir "$SZ2" >/dev/null 2>&1
[[ -f $SZ2/project.yaml && -f $SZ2/docs/rules/size-L.md ]] && ok_ "size L sans CLAUDE.md : project.yaml et règles posés (avertissement)" || ko_ "size L sans CLAUDE.md"

# Fichier projet plat, lisible sans yq : clé: valeur, une par ligne.
bad=$(grep -vE '^(#.*|[a-z_.]+: .*|)$' "$ROOT/templates/project/project.yaml" || true)
[[ -z $bad ]] && ok_ "templates/project/project.yaml : paires « clé: valeur » seulement" || ko_ "project.yaml plat" "$bad"
for k in name size size_reason stack; do
  grep -q "^$k: " "$ROOT/templates/project/project.yaml" && ok_ "project.yaml : clé $k" || ko_ "project.yaml : clé $k manquante"
done

# effort : copie l'agent global s'il manque, réécrit effort: sans toucher au reste.
EF="$TMP/effort-proj"; mkdir -p "$EF"
cp "$SZ/project.yaml" "$EF/project.yaml"
bash "$KIT" project effort devops xhigh --dir "$EF" >/dev/null 2>&1
AG="$EF/.claude/agents/devops.md"
[[ -f $AG && $(grep -c '^effort:' "$AG") == 1 && $(grep '^effort:' "$AG") == "effort: xhigh" ]] \
  && ok_ "effort : agent copié, effort: xhigh" || ko_ "effort : copie ou valeur" "$(grep -n 'effort' "$AG" 2>/dev/null)"
bash "$KIT" project effort devops low --dir "$EF" >/dev/null 2>&1
[[ $(grep -c '^effort:' "$AG") == 1 && $(grep '^effort:' "$AG") == "effort: low" && $(grep -c '^---$' "$AG") == 2 ]] \
  && ok_ "effort : réécriture sans doublon, en-tête intact" || ko_ "effort : réécriture" "$(head -8 "$AG")"
diff <(sed '/^effort:/d' "$ROOT/global/agents/devops.md") <(sed '/^effort:/d' "$AG") >/dev/null \
  && ok_ "effort : le reste de l'agent est inchangé" || ko_ "effort : corps de l'agent modifié"
[[ $(grep '^effort.devops:' "$EF/project.yaml") == "effort.devops: low" ]] \
  && ok_ "effort : noté dans project.yaml (effort.devops)" || ko_ "effort : project.yaml"
bash "$KIT" project effort devops ultra --dir "$EF" >/dev/null 2>&1 && ko_ "effort invalide : doit échouer" || ok_ "niveau d'effort invalide refusé"
bash "$KIT" project effort nope high --dir "$EF" >/dev/null 2>&1 && ko_ "agent inconnu : doit échouer" || ok_ "agent inconnu refusé"

section "instructions : tailles de texte"
gw=$(wc -w <"$ROOT/global/CLAUDE.md" | tr -d ' ')
[[ $gw -lt 400 ]] && ok_ "global/CLAUDE.md : $gw mots (< 400)" || ko_ "global/CLAUDE.md : $gw mots (>= 400)"
npw=$(wc -w <"$ROOT/global/commands/new-project.md" | tr -d ' ')
[[ $npw -le 900 ]] && ok_ "/new-project : $npw mots (<= 900)" || ko_ "/new-project : $npw mots (> 900)"
ps="$ROOT/global/skills/project-size/SKILL.md"
psw=$(wc -w <"$ps" | tr -d ' ')
psd=$(sed -n 's/^description: //p' "$ps" | wc -w | tr -d ' ')
[[ $psw -le 500 && $psd -le 30 ]] && ok_ "skill project-size : $psw mots, description $psd mots" || ko_ "skill project-size : $psw mots, description $psd mots"
rw=$(wc -w <"$ROOT/global/skills-registry.md" | tr -d ' ')
[[ $rw -le 600 ]] && ok_ "skills-registry.md : $rw mots (<= 600)" || ko_ "skills-registry.md : $rw mots (> 600)"
grep -qE 'kit-control|checkpoint|wait_for_answer|restart_session' "$ROOT/global/CLAUDE.md" "$ROOT/global/commands/new-project.md" \
  && ko_ "CLAUDE.md et /new-project : plus de dashboard" || ok_ "CLAUDE.md et /new-project : aucune mention du dashboard"
nt=$(bash "$KIT" project types 2>/dev/null | wc -l | tr -d ' ')
[[ $nt -ge 16 ]] && ok_ "registre : kit project types lit $((nt - 1)) types (registry_rows)" || ko_ "registre : kit project types ($nt lignes)"

# ---------------------------------------------------------------------------
section "agents et Superpowers (2f)"
# Every global agent: model alias opus, effort valid and set per role, description <= 25 words.
declare -a EFFORT_OF=(
  "architect=high" "backend-dev=medium" "brand-identity=high" "code-reviewer=high" "copywriter=medium"
  "creative-coder=medium" "creative-content=medium" "design-critic=medium" "devops=medium" "frontend-dev=medium"
  "qa-tester=medium" "researcher=medium" "security-reviewer=xhigh" "ui-designer=high"
  "rust-dev=medium" "go-cli=medium" "pocketbase=medium")
want_effort() { local e; for e in "${EFFORT_OF[@]}"; do [[ ${e%%=*} == "$1" ]] && { echo "${e#*=}"; return; }; done; }
wcw() { awk '{n += NF} END {print n + 0}'; } # words, independent of the locale (wc -w splits on byte 0xA0 in the C locale)
fm() { awk -v k="$2" 'NR == 1 && $0 != "---" {exit} NR > 1 && $0 == "---" {exit} NR > 1 && index($0, k ":") == 1 {sub("^" k ":[[:space:]]*", ""); print; exit}' "$1"; }
bad_model="" bad_effort="" bad_desc="" bad_name="" n_agents=0
for f in "$ROOT"/global/agents/*.md; do
  n=$(basename "$f" .md); n_agents=$((n_agents + 1))
  [[ $(fm "$f" name) == "$n" ]] || bad_name="$bad_name $n"
  [[ $(fm "$f" model) == opus ]] || bad_model="$bad_model $n"
  e=$(fm "$f" effort); w=$(want_effort "$n")
  [[ $e =~ ^(low|medium|high|xhigh|max)$ && -n $w && $e == "$w" ]] || bad_effort="$bad_effort $n($e)"
  [[ $(fm "$f" description | wcw) -le 25 ]] || bad_desc="$bad_desc $n"
done
[[ -z $bad_name ]] && ok_ "agents : name = nom du fichier ($n_agents agents)" || ko_ "agents : name" "$bad_name"
[[ -z $bad_model ]] && ok_ "agents : model: opus partout" || ko_ "agents : model" "$bad_model"
[[ -z $bad_effort ]] && ok_ "agents : effort valide et conforme au rôle" || ko_ "agents : effort" "$bad_effort"
[[ -z $bad_desc ]] && ok_ "agents : description <= 25 mots" || ko_ "agents : description trop longue" "$bad_desc"
[[ $n_agents == "${#EFFORT_OF[@]}" ]] && ok_ "agents : $n_agents fichiers = le barème d'effort" || ko_ "agents : $n_agents fichiers pour ${#EFFORT_OF[@]} rôles du barème"
miss=""
for a in "${EFFORT_OF[@]}"; do [[ -f $ROOT/global/agents/${a%%=*}.md ]] || miss="$miss ${a%%=*}"; done
[[ -z $miss ]] && ok_ "agents : rust-dev, go-cli, pocketbase présents (et tout le barème)" || ko_ "agents : manquants" "$miss"
badskill=""
for f in "$ROOT"/global/agents/*.md "$ROOT"/extras/agents/*.md; do
  for s in $(awk 'NR == 1 {next} $0 == "---" {exit} /^skills:/ {c = 1; next} c && /^[[:space:]]+-/ {sub(/^[[:space:]]+-[[:space:]]*/, ""); print; next} c {c = 0}' "$f"); do
    [[ -f $ROOT/global/skills/$s/SKILL.md ]] || badskill="$badskill $(basename "$f"):$s"
  done
done
[[ -z $badskill ]] && ok_ "agents : chaque skill préchargé (skills:) existe" || ko_ "agents : skill préchargé introuvable" "$badskill"
grep -qx '  - pocketbase' "$ROOT/global/agents/pocketbase.md" && ok_ "pocketbase : précharge le skill pocketbase" || ko_ "pocketbase : skills:"
if grep -qi 'engram' "$ROOT/global/agents/brand-identity.md" "$ROOT/global/agents/ui-designer.md"; then ko_ "brand-identity, ui-designer : plus de lecture d'Engram"; else ok_ "brand-identity, ui-designer : aucune lecture d'Engram"; fi
if grep -q 'chaque PR\|recommande `security-reviewer`' "$ROOT/global/agents/code-reviewer.md"; then ko_ "code-reviewer : contradictions retirées"; else ok_ "code-reviewer : ni « chaque PR » ni recommandation de security-reviewer"; fi
for r in code-reviewer qa-tester design-critic security-reviewer brand-identity; do
  fm "$ROOT/global/agents/$r.md" description | grep -q 'Taille L' && ok_ "$r : réservé à la taille L ou à la demande" || ko_ "$r : description sans « Taille L »"
done

# Optional agents: extras/agents/, never linked globally, installable per project.
for a in sysop data-engineer game-designer android-ui-reviewer; do
  [[ -f $ROOT/extras/agents/$a.md && ! -e $ROOT/global/agents/$a.md ]] && ok_ "extras : $a hors de global/agents" || ko_ "extras : $a mal placé"
done
XP="$TMP/extras-proj"; mkdir -p "$XP"
(cd "$XP" && bash "$KIT" add-agent sysop --project >/dev/null 2>&1)
[[ -f $XP/.claude/agents/sysop.md && ! -e $KIT_HOME/global/agents/sysop.md ]] \
  && ok_ "kit add-agent sysop --project : installé dans le projet seulement" || ko_ "kit add-agent <extra> --project"
(cd "$XP" && bash "$KIT" add-agent no-such-agent --project >/dev/null 2>&1) && ko_ "extra inconnu : doit échouer" || ok_ "kit add-agent : nom inconnu refusé"
bash "$KIT" project add android --no-skills --dir "$XP" >/dev/null 2>&1
[[ -f $XP/.claude/agents/android-ui-reviewer.md ]] && ok_ "kit project add android : copie l'agent optionnel android-ui-reviewer" || ko_ "kit project add android : agent optionnel"
klist=$(bash "$KIT" list 2>/dev/null)
grep -q 'Agents optionnels' <<<"$klist" && ok_ "kit list : rubrique des agents optionnels" || ko_ "kit list : agents optionnels"
grep -q 'effort=medium' "$ROOT/scripts/kit.sh" && grep -q 'tools="Read, Glob, Grep" model=opus' "$ROOT/scripts/kit.sh" \
  && ok_ "kit new-agent : model: opus par défaut" || ko_ "kit new-agent : modèle par défaut"
reviewers_in_registry=$(awk -F'|' '/^\| `/ {print $6}' "$ROOT/global/skills-registry.md" | grep -cE 'code-reviewer|qa-tester|security-reviewer|design-critic' || true)
[[ $reviewers_in_registry == 0 ]] && ok_ "registre : aucun relecteur dans la colonne des agents" || ko_ "registre : relecteurs dans la colonne des agents" "$reviewers_in_registry lignes"

# team-builder is short; every skill and command description stays short.
tbw=$(wcw <"$ROOT/global/skills/team-builder/SKILL.md")
[[ $tbw -le 250 ]] && ok_ "team-builder : $tbw mots (<= 250)" || ko_ "team-builder : $tbw mots (> 250)"
longdesc=""
for f in "$ROOT"/global/skills/*/SKILL.md "$ROOT"/global/commands/*.md; do
  [[ $(fm "$f" description | wcw) -le 30 ]] || longdesc="$longdesc $(basename "$(dirname "$f")")/$(basename "$f")"
done
[[ -z $longdesc ]] && ok_ "skills et commandes : description <= 30 mots" || ko_ "description > 30 mots" "$longdesc"

# Superpowers: only brainstorming and writing-plans remain, patched and documented.
gone=""
for s in executing-plans subagent-driven-development dispatching-parallel-agents requesting-code-review receiving-code-review \
  systematic-debugging test-driven-development verification-before-completion finishing-a-development-branch; do
  [[ -e $ROOT/global/skills/$s ]] && gone="$gone $s"
done
[[ -z $gone ]] && ok_ "Superpowers : les 9 skills retirés sont absents de global/skills" || ko_ "Superpowers : skills encore présents" "$gone"
refs=$(grep -rnE 'superpowers:|subagent-driven|executing-plans|test-driven|systematic-debugging|verification-before|finishing-a-dev|requesting-code-review|receiving-code-review|dispatching-parallel' \
  "$ROOT/global" "$ROOT/templates" "$ROOT/README.md" "$ROOT/PLUGINS.md" "$ROOT/docs" \
  --exclude=collections-index.json --exclude-dir=plans --exclude=measure.md 2>/dev/null | cut -c1-160 || true)
[[ -z $refs ]] && ok_ "aucune référence aux skills retirés (global, templates, README, PLUGINS, docs hors plans et mesure)" || ko_ "références aux skills retirés" "$refs"
WP="$ROOT/global/skills/writing-plans/SKILL.md"
if grep -q 'REQUIRED SUB-SKILL\|using-git-worktrees' "$WP"; then ko_ "writing-plans : ni REQUIRED SUB-SKILL ni using-git-worktrees"; else ok_ "writing-plans : ni REQUIRED SUB-SKILL ni using-git-worktrees"; fi
grep -q 'docs/plan.md' "$WP" && grep -q -- '- \[ \]' "$WP" && grep -qi 'one agent runs one lot' "$WP" \
  && ok_ "writing-plans : écrit docs/plan.md, lots, cases à cocher, un agent par lot" || ko_ "writing-plans : format docs/plan.md"
BS="$ROOT/global/skills/brainstorming/SKILL.md"
if fm "$BS" description | grep -q 'MUST'; then ko_ "brainstorming : description sans « MUST »"; else ok_ "brainstorming : description limitée aux idées floues (pas de « MUST »)"; fi
grep -q 'docs/brief.md' "$BS" && ! grep -q 'docs/superpowers' "$BS" && ok_ "brainstorming : le design va dans docs/brief.md" || ko_ "brainstorming : emplacement du design"
[[ -f $ROOT/vendor/superpowers/PATCHES.md ]] && grep -q 'brainstorming' "$ROOT/vendor/superpowers/PATCHES.md" && grep -q 'writing-plans' "$ROOT/vendor/superpowers/PATCHES.md" \
  && ok_ "vendor/superpowers/PATCHES.md consigne les deux correctifs" || ko_ "PATCHES.md"
if grep -q 'plugin install superpowers' "$ROOT/PLUGINS.md"; then ko_ "PLUGINS.md : plus de commande d'installation de Superpowers"; else ok_ "PLUGINS.md : plugin Superpowers retiré"; fi

# kit sync on a copy of the tree, temp HOME, cloud mode (no network, no write in the repository): no broken link,
# and the links of agents and skills removed from a previous version are pruned.
SY="$TMP/sync"; mkdir -p "$SY/kit" "$SY/home/.claude/agents" "$SY/home/.claude/skills"
(cd "$ROOT" && tar --exclude=.git -cf - .) | tar -xf - -C "$SY/kit"
ln -s "$SY/kit/global/agents/sysop.md" "$SY/home/.claude/agents/sysop.md"
ln -s "$SY/kit/global/skills/executing-plans" "$SY/home/.claude/skills/executing-plans"
(
  export HOME="$SY/home" KIT_HOME="$SY/kit" KIT_CONFIG="$SY/home/.config/claude-kit" CLAUDE_CODE_REMOTE=true
  bash "$SY/kit/scripts/kit.sh" sync >/dev/null 2>&1
)
broken=$(find -L "$SY/home/.claude" -type l 2>/dev/null | wc -l | tr -d ' ')
[[ $broken == 0 ]] && ok_ "kit sync : aucun lien cassé dans ~/.claude (agents, skills, commandes)" || ko_ "kit sync : $broken lien(s) cassé(s)" "$(find -L "$SY/home/.claude" -type l | sed "s#$SY##")"
[[ $(find "$SY/home/.claude/agents" -name '*.md' | wc -l | tr -d ' ') == "$n_agents" ]] \
  && ok_ "kit sync : $n_agents agents liés, les extras ne le sont pas" || ko_ "kit sync : nombre d'agents liés"

# ---------------------------------------------------------------------------
section "budgets de contexte (context-budget.sh)"
CB="$ROOT/scripts/context-budget.sh"
CBT="$TMP/ctx"
mkdir -p "$CBT/global/agents" "$CBT/global/skills/alpha" "$CBT/global/commands" "$CBT/templates/project/.claude" "$CBT/scripts"
# Fixture tree with known sizes: CLAUDE.md 7 words + one imported file of 3 words ("@" in a code span is ignored).
printf 'un deux trois quatre @extra.md cinq `@ignore.md`\n' >"$CBT/global/CLAUDE.md"
printf 'six sept huit\n' >"$CBT/global/extra.md"
printf -- '---\nname: a1\ndescription: un deux trois\n---\ncorps long qui ne compte pas\n' >"$CBT/global/agents/a1.md"
printf -- '---\nname: a2\ndescription: "deux mots"\n---\ncorps\n' >"$CBT/global/agents/a2.md"
printf -- '---\nname: alpha\ndescription: >\n  quatre mots sur\n  deux lignes\n---\ncorps\n' >"$CBT/global/skills/alpha/SKILL.md"
printf -- '---\ndescription: une commande\n---\ncorps\n' >"$CBT/global/commands/c1.md"
printf 'un deux\n' >"$CBT/templates/project/CLAUDE.md"
cat >"$CBT/global/settings.json" <<'JSON'
{"hooks": {
  "PreToolUse": [
    {"matcher": "Bash|Read", "hooks": [{"type": "command", "command": "true"}]},
    {"matcher": "*", "hooks": [{"type": "command", "command": "true"}, {"type": "command", "command": "true"}]}],
  "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "true"}]}],
  "SessionStart": [
    {"hooks": [{"type": "command", "command": "printf 'bonjour le monde'"}]},
    {"matcher": "clear", "hooks": [{"type": "command", "command": "printf 'jamais lu'"}]}]}}
JSON
cat >"$CBT/templates/project/.claude/settings.json" <<'JSON'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "printf 'abcde fghij'"}]}]}}
JSON
printf 'global_claude_md.words\t10\tx\nhooks_per_tool_call.Bash\t3\tx\n' >"$CBT/budgets-ok.tsv"
printf 'global_claude_md.words\t9\tx\nhooks_per_tool_call.Bash\t2\tx\n' >"$CBT/budgets-over.tsv"

CBJ=$(bash "$CB" --root "$CBT" --json 2>/dev/null)
cbv() { jq -r "$1" <<<"$CBJ"; }
[[ $(cbv '.global_claude_md.words') == 10 && $(cbv '.global_claude_md.files') == 2 ]] \
  && ok_ "fixture : CLAUDE.md global + import = 10 mots, 2 fichiers" \
  || ko_ "fixture : CLAUDE.md global" "$(cbv '.global_claude_md')"
[[ $(cbv '.agent_descriptions.count') == 2 && $(cbv '.agent_descriptions.words') == 5 ]] \
  && ok_ "fixture : descriptions d'agents (simple et entre guillemets) = 5 mots" || ko_ "fixture : descriptions d'agents" "$(cbv '.agent_descriptions')"
[[ $(cbv '.skill_descriptions.words') == 5 && $(cbv '.command_descriptions.words') == 2 && $(cbv '.skill_command_descriptions.words') == 7 ]] \
  && ok_ "fixture : description de skill repliée (5) + commande (2) = 7 mots" || ko_ "fixture : descriptions skills et commandes" "$(cbv '.skill_command_descriptions')"
[[ $(cbv '.sessionstart_kit.chars') == 16 && $(cbv '.sessionstart_kit.hooks') == 1 ]] \
  && ok_ "fixture : SessionStart du kit (matcher « clear » ignoré) = 16 caractères" || ko_ "fixture : SessionStart du kit" "$(cbv '.sessionstart_kit')"
[[ $(cbv '.project_sessionstart.chars') == 11 ]] \
  && ok_ "fixture : SessionStart du projet = 11 caractères" || ko_ "fixture : SessionStart du projet" "$(cbv '.project_sessionstart')"
[[ $(cbv '.hooks_per_tool_call.Bash') == 3 && $(cbv '.hooks_per_tool_call.Read') == 3 && $(cbv '.hooks_per_tool_call.Edit') == 3 \
  && $(cbv '.hooks_per_tool_call.Write') == 2 && $(cbv '.hooks_per_tool_call.Glob') == 2 ]] \
  && ok_ "fixture : hooks par appel (matchers regex, *, PostToolUse)" || ko_ "fixture : hooks par appel" "$(cbv '.hooks_per_tool_call')"
[[ $(cbv '.project_template.words') == 2 && $(cbv '.new_project_command.words') == 0 && $(cbv '.superpowers_path.skills') == 0 ]] \
  && ok_ "fixture : éléments absents mesurés à 0" || ko_ "fixture : éléments absents"

BUDGET_ENFORCE=0 bash "$CB" --root "$CBT" --budgets "$CBT/budgets-over.tsv" --budget >/dev/null 2>&1; rc_warn=$?
BUDGET_ENFORCE=1 bash "$CB" --root "$CBT" --budgets "$CBT/budgets-over.tsv" --budget >/dev/null 2>&1; rc_enf=$?
BUDGET_ENFORCE=1 bash "$CB" --root "$CBT" --budgets "$CBT/budgets-ok.tsv" --budget >/dev/null 2>&1; rc_ok=$?
[[ $rc_warn == 0 && $rc_enf == 1 && $rc_ok == 0 ]] \
  && ok_ "--budget : dépassement = avertissement ; échec seulement avec BUDGET_ENFORCE=1" \
  || ko_ "--budget : codes de sortie" "avertissement $rc_warn, enforce+dépassement $rc_enf, enforce+ok $rc_ok"
[[ $(bash "$CB" --root "$CBT" --budgets "$CBT/budgets-over.tsv" --budget --json 2>/dev/null | jq -r '.budget.over') == 2 ]] \
  && ok_ "--budget --json : nombre de dépassements" || ko_ "--budget --json"

# The real tree: stable JSON shape, hooks run in a sandbox (the real HOME stays untouched), then the budgets (warnings).
REALJ=$(bash "$CB" --json 2>/dev/null)
missing=$(jq -r '
  . as $d | [ "global_claude_md.words", "global_claude_md.chars", "agent_descriptions.words", "skill_descriptions.words",
    "command_descriptions.words", "skill_command_descriptions.words", "sessionstart_kit.chars", "project_sessionstart.chars",
    "project_template.words", "new_project_command.words", "skills_registry.words", "team_builder.words",
    "superpowers_path.words", "hooks_per_tool_call.Bash", "hooks_per_tool_call.Read", "hooks_per_tool_call.Edit",
    "hooks_per_tool_call.Write", "startup_total.words", "startup_total.chars" ]
  | map(select(. as $p | ($d | getpath($p | split(".")) | type) != "number")) | join(" ")' <<<"$REALJ" 2>/dev/null)
[[ -n $REALJ && -z $missing && $(jq -r '.version' <<<"$REALJ") == 1 ]] \
  && ok_ "arbre réel : JSON de forme stable (clés numériques présentes)" || ko_ "arbre réel : JSON" "manquant : $missing"
EH="$TMP/emptyhome"; mkdir -p "$EH"
HOME=$EH bash "$CB" --json >/dev/null 2>&1
[[ -z $(ls -A "$EH") ]] && ok_ "arbre réel : un HOME vide le reste (les hooks tournent dans un bac à sable)" || ko_ "arbre réel : effets de bord des hooks"
# Budgets owned by delivered sub-lots are enforced (2e: global CLAUDE.md, /new-project, registry; 2f: agent and
# skill/command descriptions, Superpowers on the /new-project path); the others (hooks 2c/2d, startup memory 2c) stay
# warnings until their sub-lot lands.
ENFORCED='global_claude_md.words new_project_command.words skills_registry.words agent_descriptions.words skill_command_descriptions.words superpowers_path.words'
grep -E "^($(printf '%s' "$ENFORCED" | tr ' ' '|'))	" "$ROOT/scripts/context-budgets.tsv" >"$TMP/budgets-enforced.tsv"
if bash_out=$(BUDGET_ENFORCE=1 bash "$CB" --budgets "$TMP/budgets-enforced.tsv" --budget 2>&1); then
  ok_ "budgets appliqués (CLAUDE.md global, /new-project, registre, agents, skills et commandes, Superpowers) : respectés"
else
  ko_ "budgets appliqués dépassés" "$(grep 'DÉPASSÉ' <<<"$bash_out" | tr -s ' ' | paste -sd';' -)"
fi
echo "  -- autres budgets (avertissements seulement) --"
bash "$CB" --budget 2>&1 | sed 's/^/  /'
check "arbre réel : --budget sort 0 hors BUDGET_ENFORCE" bash "$CB" --budget

# ---------------------------------------------------------------------------
section "dépôt du kit"
[[ $(repo_state) == "$REPO_STATE0" ]] && ok_ "aucune écriture dans le dépôt du kit pendant les tests" || ko_ "le dépôt du kit a été modifié pendant les tests" "$(git -C "$ROOT" status --porcelain | head -5)"

# ---------------------------------------------------------------------------
echo
echo "$pass passed, $fail failed"
HOME=$REAL_HOME
((fail == 0))
