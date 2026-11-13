#!/usr/bin/env bash
# Tests du kit : syntaxe, JSON, kit perms, hook kit-autoupdate. Aucune dépendance au-delà de bash, jq, git.
# Usage : scripts/test/run.sh        (code de sortie non nul au moindre échec)
# HOME et les dossiers de config sont redirigés vers un dossier temporaire : rien ne touche ~/.claude ni ~/.config.
set -uo pipefail
# Usual user umask: some CI runners start jobs with umask 000, and the kit rightly refuses world-writable local files.
umask 022

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
# Hook guard-secrets : vrais accès bloqués, simples mentions autorisées (cas dans scripts/test/guard-secrets-test.sh).
gs_out=$(bash "$ROOT/scripts/test/guard-secrets-test.sh" 2>&1)
gs_rc=$?
grep -E '^(==|  FAIL|       )' <<<"$gs_out"
gs_p=$(sed -n 's/^guard-secrets: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1/p' <<<"$gs_out")
gs_f=$(sed -n 's/^guard-secrets: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\2/p' <<<"$gs_out")
pass=$((pass + ${gs_p:-0}))
fail=$((fail + ${gs_f:-0}))
if [[ $gs_rc != 0 && ${gs_f:-0} == 0 ]]; then ko_ "guard-secrets-test.sh a échoué sans résumé" "$(tail -3 <<<"$gs_out")"; fi
((${gs_p:-0} >= 25)) && ok_ "guard-secrets : au moins 25 cas de test (${gs_p:-0})" || ko_ "guard-secrets : moins de 25 cas (${gs_p:-0})"

# ---------------------------------------------------------------------------
# kit ship: fake kit api, gh, curl and infra repository (cases in scripts/test/ship-test.sh).
sh_out=$(bash "$ROOT/scripts/test/ship-test.sh" 2>&1)
sh_rc=$?
grep -E '^(==|  FAIL|       )' <<<"$sh_out"
sh_p=$(sed -n 's/^ship: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1/p' <<<"$sh_out")
sh_f=$(sed -n 's/^ship: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\2/p' <<<"$sh_out")
pass=$((pass + ${sh_p:-0}))
fail=$((fail + ${sh_f:-0}))
if [[ $sh_rc != 0 && ${sh_f:-0} == 0 ]]; then ko_ "ship-test.sh a échoué sans résumé" "$(tail -3 <<<"$sh_out")"; fi

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
  apply_managed_settings --yes >/dev/null 2>&1
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
jq -e '.hooks.SessionStart | length == 1 and any(.matcher == "startup|resume" and .hooks[0].timeout == 30)' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "SessionStart : autoupdate seul (startup|resume, timeout 30)" || ko_ "SessionStart : autoupdate seul"
jq -e '[.. | .command? // empty | select(type == "string")] | map(select(test("kit-emit"))) | length == 0' "$TMP/merged.json" >/dev/null 2>&1 \
  && ok_ "settings.json du kit : plus aucun hook kit-emit" || ko_ "settings.json du kit : kit-emit présent"
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
( source "$ROOT/scripts/lib.sh"; apply_managed_settings --yes >/dev/null 2>&1 )
[[ -L $HOME/.claude/settings.json ]] && jq -e '.model == "sonnet" and (.hooks.Stop | length == 1) and (.hooks.SessionStart | length == 1)' "$TMP/real-settings.json" >/dev/null 2>&1 \
  && ok_ "apply_managed_settings : lien conservé, cible fusionnée" || ko_ "apply_managed_settings : lien conservé, cible fusionnée"
[[ $(stat -c %a "$TMP/real-settings.json" 2>/dev/null || stat -f %Lp "$TMP/real-settings.json") == 600 ]] && ok_ "apply_managed_settings : droits conservés" || ko_ "apply_managed_settings : droits conservés"
[[ -z $(find "$TMP" -maxdepth 1 -name '.real-settings.json.*') ]] && ok_ "apply_managed_settings : aucun fichier temporaire résiduel" || ko_ "apply_managed_settings : fichier temporaire résiduel"
rm -rf "$HOME/.claude" "$KIT_CONFIG"

# ---------------------------------------------------------------------------
section "réglages gérés (kit sync, fusion à trois points)"
# Copie du kit : les tests y retirent ou ajoutent des règles sans jamais toucher au dépôt. KIT_SYNC_CONTEXT=0 saute le
# clonage des dépôts de contexte (la copie n'a pas de skills-registry.md : aucune régénération du registre des profils).
KITC="$TMP/kitcopy"
mkdir -p "$KITC/global"
cp "$ROOT"/global/settings*.json "$KITC/global/"
cp -R "$ROOT/scripts" "$KITC/scripts"
reset_home() { rm -rf "$HOME/.claude" "$HOME/.kit" "$KIT_CONFIG"; mkdir -p "$HOME/.claude"; }
msync() { env KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 "$KITC/scripts/kit.sh" sync "$@"; }
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

# 5. Le groupe SessionStart dupliqué (kit-autoupdate, autre timeout) est fusionné ; les groupes de hooks du kit retirés aussi.
reset_home
msync >/dev/null 2>&1
n_ss=$(jq '.hooks.SessionStart | length' "$(cur_settings)")
jq '.hooks.SessionStart += [{"matcher": "startup|resume", "hooks": [{"type": "command", "command": "$HOME/.config/claude-kit/hooks/kit-autoupdate.sh", "timeout": 10}]}]
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
jqc '.hooks.SessionStart | length == 1' "$(cur_settings)" && ok_ "migration : SessionStart dédoublonné" || ko_ "migration : SessionStart"
[[ -f $KIT_CONFIG/settings.managed.json ]] && ok_ "migration : registre créé" || ko_ "migration : registre créé"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"

# 8a. Tableau de bord abandonné (2c) : un poste v1 (sans registre) et un poste v2 (registre de la 2b) perdent le hook
# d'émission et ses autorisations au sync ; les hooks et règles de l'utilisateur restent, même dans un groupe du kit.
EMIT='$HOME/.config/claude-kit/hooks/kit-emit.sh'
CTL_RULES='["mcp__kit-control__ask","mcp__kit-control__task_create","Bash(kit dash *)"]'
no_emit() { jqc '[.. | .command? // empty | select(type == "string") | select(test("kit-emit"))] | length == 0' "$1"; }
# v1 : fichier de la v1 + hooks de l'utilisateur (un groupe à lui, un hook à lui dans un groupe de kit-emit).
reset_home
jq --arg e "$EMIT" '.hooks.Stop += [{"hooks": [{"type": "command", "command": "echo mon-hook"}]}]
    | (.hooks.SessionEnd[] | select(any(.hooks[]; .command == $e)) | .hooks) += [{"type": "command", "command": "echo mon-hook-de-groupe"}]
    | .permissions.allow += ["Bash(make lint)"]' "$ROOT/global/settings.v1.json" >"$(cur_settings)"
jqc --arg e "$EMIT" '[.hooks[][].hooks[].command | select(. == $e)] | length >= 5' "$(cur_settings)" \
  && ok_ "poste v1 : le fichier contient bien les hooks kit-emit au départ" || ko_ "poste v1 : kit-emit au départ"
msync >/dev/null 2>&1
no_emit "$(cur_settings)" && ok_ "poste v1 : plus aucun hook kit-emit après sync" || ko_ "poste v1 : kit-emit encore présent" "$(jq -c '[.hooks | to_entries[] | select(any(.value[].hooks[]; (.command // "") | test("kit-emit"))) | .key]' "$(cur_settings)")"
jqc '[.hooks.Stop[].hooks[].command] | index("echo mon-hook") != null' "$(cur_settings)" && ok_ "poste v1 : hook utilisateur conservé" || ko_ "poste v1 : hook utilisateur"
jqc '[.hooks.SessionEnd[].hooks[].command] == ["echo mon-hook-de-groupe"]' "$(cur_settings)" \
  && ok_ "poste v1 : le hook de l'utilisateur placé dans un groupe kit-emit reste, seul" || ko_ "poste v1 : hook dans un groupe kit-emit" "$(jq -c '.hooks.SessionEnd' "$(cur_settings)")"
jqc --argjson r "$CTL_RULES" '(.permissions.allow | index("Bash(make lint)") != null) and ([.permissions.allow[] | select(. as $x | $r | index($x))] | length == 0)' "$(cur_settings)" \
  && ok_ "poste v1 : autorisations du tableau de bord retirées, règle utilisateur conservée" || ko_ "poste v1 : autorisations kit-control"
jqc '[.hooks.PreToolUse[].hooks[].command | select(endswith("guard-secrets.sh"))] | length == 1' "$(cur_settings)" \
  && ok_ "poste v1 : guard-secrets reste le seul hook PreToolUse du kit" || ko_ "poste v1 : guard-secrets"
# v2 (poste synchronisé avec la 2b) : le registre est l'ancien K, qui contient kit-emit.
reset_home
OLDK="$TMP/oldk.json"
jq --arg e "$EMIT" --argjson r "$CTL_RULES" '
    .hooks.SessionStart = [{"hooks": [{"type": "command", "command": $e, "timeout": 5}]}] + .hooks.SessionStart
    | .hooks.PostToolUse = [{"matcher": "*", "hooks": [{"type": "command", "command": $e, "timeout": 5}]}]
    | .hooks.PreToolUse += [{"matcher": "*", "hooks": [{"type": "command", "command": $e, "timeout": 5}]}]
    | .permissions.allow += $r' "$ROOT/global/settings.json" >"$OLDK"
mkdir -p "$KIT_CONFIG"
jq '. + {profile: "local"}' "$OLDK" >"$KIT_CONFIG/settings.managed.json"
jq '.hooks.Stop += [{"hooks": [{"type": "command", "command": "echo mon-hook"}]}] | .permissions.allow += ["Bash(make lint)"]' "$OLDK" >"$(cur_settings)"
dout=$(msync 2>&1)
no_emit "$(cur_settings)" && ok_ "poste v2 : plus aucun hook kit-emit après sync" || ko_ "poste v2 : kit-emit encore présent"
jqc '[.hooks.Stop[].hooks[].command] | index("echo mon-hook") != null' "$(cur_settings)" && ok_ "poste v2 : hook utilisateur conservé" || ko_ "poste v2 : hook utilisateur"
jqc --argjson r "$CTL_RULES" '(.permissions.allow | index("Bash(make lint)") != null) and ([.permissions.allow[] | select(. as $x | $r | index($x))] | length == 0)' "$(cur_settings)" \
  && ok_ "poste v2 : autorisations du tableau de bord retirées, règle utilisateur conservée" || ko_ "poste v2 : autorisations kit-control"
grep -q 'retiré de hooks.PostToolUse' <<<"$dout" && ok_ "poste v2 : le retrait des hooks est nommé dans la sortie" || ko_ "poste v2 : sortie" "$dout"
jqc '(.hooks | has("PostToolUse") | not) and (.hooks.SessionStart | length == 1)' "$(cur_settings)" \
  && ok_ "poste v2 : événements vidés supprimés, SessionStart réduit à autoupdate" || ko_ "poste v2 : événements vidés"
# Le lien du hook supprimé et le fichier d'URL sont nettoyés ; le serveur MCP est retiré s'il est déclaré.
reset_home
mkdir -p "$KIT_CONFIG/hooks" "$TMP/fakebin"
ln -s "$KITC/scripts/hooks/kit-emit.sh" "$KIT_CONFIG/hooks/kit-emit.sh"
echo "https://exemple.invalid" >"$KIT_CONFIG/dash.url"
echo '{"mcpServers":{"kit-control":{"type":"http","url":"https://exemple.invalid/mcp"},"autre":{"type":"stdio","command":"x"}}}' >"$HOME/.claude.json"
printf '#!/bin/sh\necho "$*" >>"%s/claude-calls"\n' "$TMP" >"$TMP/fakebin/claude"
chmod +x "$TMP/fakebin/claude"
rm -f "$TMP/claude-calls"
PATH="$TMP/fakebin:$PATH" msync >/dev/null 2>&1
[[ ! -e $KIT_CONFIG/hooks/kit-emit.sh && ! -L $KIT_CONFIG/hooks/kit-emit.sh && ! -e $KIT_CONFIG/dash.url ]] \
  && ok_ "sync : lien kit-emit et dash.url supprimés" || ko_ "sync : lien kit-emit ou dash.url restent"
[[ $(cat "$TMP/claude-calls" 2>/dev/null) == "mcp remove --scope user kit-control" ]] \
  && ok_ "sync : serveur MCP kit-control retiré (et lui seul)" || ko_ "sync : retrait du serveur MCP" "$(cat "$TMP/claude-calls" 2>/dev/null)"
echo '{"mcpServers":{"autre":{"type":"stdio","command":"x"}}}' >"$HOME/.claude.json"
rm -f "$TMP/claude-calls"
PATH="$TMP/fakebin:$PATH" msync >/dev/null 2>&1
[[ ! -e $TMP/claude-calls ]] && ok_ "sync : aucun appel à claude quand kit-control n'est pas déclaré" || ko_ "sync : appel inutile à claude"
rm -f "$HOME/.claude.json"
reset_home

# 8b. Migration sans registre, autoMode : l'instantané v1 ne contient que des empreintes SHA-256 (le dépôt est public).
jqc 'has("autoMode") | not' "$ROOT/global/settings.v1.json" && jqc '.autoModeSha256 | [.[][]] | length > 0 and all(test("^[0-9a-f]{64}$"))' "$ROOT/global/settings.v1.json" \
  && ok_ "instantané v1 : autoMode en empreintes SHA-256 seulement, rien en clair" || ko_ "instantané v1 : autoMode"
dig=$(printf '%s' '$defaults' | sha256_hex_t)
jqc --arg d "$dig" '[.autoModeSha256[][]] | index($d) != null' "$ROOT/global/settings.v1.json" \
  && ok_ "instantané v1 : l'empreinte d'une entrée connue y figure" || ko_ "instantané v1 : empreinte connue"
reset_home
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
# Une phrase v1 de test (empreinte ajoutée à la copie de l'instantané) que le kit d'aujourd'hui ne livre plus (cas du lot 2c :
# les phrases qui nommaient des domaines internes sont sorties du dépôt public).
V1SENT="Phrase v1 de test."
jq --arg h "$(printf '%s' "$V1SENT" | sha256_hex_t)" '.autoModeSha256.environment += [$h]' "$KITC/global/settings.v1.json" >"$TMP/g.json" && cp "$TMP/g.json" "$KITC/global/settings.v1.json"
# Fichier v1 : toutes les entrées autoMode du kit (ici celles de global/settings.json), la phrase v1 et une entrée de l'utilisateur.
jq --arg s "$V1SENT" '.autoMode as $am | {permissions: {allow: ["Bash(ls*)"]}, autoMode: ($am | .environment += [$s, "Mon serveur de test."])}' "$ROOT/global/settings.json" >"$(cur_settings)"
jqc --arg s "$V1SENT" '.autoMode.environment | index($s) != null' "$(cur_settings)" \
  && ok_ "migration autoMode : l'entrée à retirer est d'abord présente" || ko_ "migration autoMode : entrée présente avant"
dout=$(msync 2>&1)
jqc --arg s "$V1SENT" '.autoMode.environment | index($s) == null' "$(cur_settings)" \
  && ok_ "migration autoMode : une entrée v1 (empreinte connue) retirée du kit est supprimée" || ko_ "migration autoMode : entrée v1 supprimée"
grep -q 'autoMode.environment : des phrases du kit ont été retirées' <<<"$dout" && grep -q 'kit overlay env' <<<"$dout" \
  && ok_ "migration autoMode : sans surcharge locale, le sync dit quoi faire (kit overlay env)" || ko_ "migration autoMode : avertissement" "$dout"
jqc '.autoMode.environment | index("Mon serveur de test.") != null' "$(cur_settings)" \
  && ok_ "migration autoMode : l'entrée de l'utilisateur reste" || ko_ "migration autoMode : entrée utilisateur"
jqc '(.autoMode.environment | index("$defaults") != null) and (.autoMode.hard_deny | length == 2)' "$(cur_settings)" \
  && ok_ "migration autoMode : les entrées toujours livrées restent" || ko_ "migration autoMode : entrées livrées"
# Même migration avec des phrases locales déclarées : plus d'avertissement.
reset_home
mkdir -p "$KIT_CONFIG"
printf 'Phrase locale de test.\n' >"$KIT_CONFIG/environment.local.txt"
jq --arg s "$V1SENT" '.autoMode as $am | {permissions: {allow: ["Bash(ls*)"]}, autoMode: ($am | .environment += [$s])}' "$ROOT/global/settings.json" >"$(cur_settings)"
dout=$(msync 2>&1)
! grep -q 'des phrases du kit ont été retirées' <<<"$dout" && jqc --arg s "$V1SENT" '(.autoMode.environment | index($s) == null) and (.autoMode.environment | index("Phrase locale de test.") != null)' "$(cur_settings)" \
  && ok_ "migration autoMode : avec phrases locales, pas d'avertissement et la phrase locale est appliquée" || ko_ "migration autoMode : phrases locales" "$dout"
cp "$ROOT/global/settings.v1.json" "$KITC/global/settings.v1.json"
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
# Une règle que le kit a livrée (elle est dans le registre) puis retirée, et listée dans global/settings.retired.json, disparaît
# et la sortie la nomme ; une règle identique que l'utilisateur seul a ajoutée (absente du registre) reste.
jq '.permissions.deny += ["Bash(retire-x)"]' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
msync >/dev/null 2>&1
jq '.permissions.deny += ["Bash(garde-y)"]' "$(cur_settings)" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
echo '{"permissions":{"deny":["Bash(retire-x)","Bash(garde-y)"],"ask":[]}}' >"$KITC/global/settings.retired.json"
dout=$(msync 2>&1)
jqc '(.permissions.deny | index("Bash(retire-x)")) == null and (.permissions.deny | index("Bash(garde-y)")) != null' "$(cur_settings)" \
  && ok_ "retired : la règle livrée puis retirée disparaît, l'identique ajoutée par l'utilisateur reste" || ko_ "retired : règle listée"
grep -q 'retiré de permissions.deny : "Bash(retire-x)"' <<<"$dout" && ok_ "retired : la règle retirée est nommée dans la sortie" || ko_ "retired : sortie" "$dout"
! grep -q 'garde-y' <<<"$dout" && ok_ "retired : la règle de l'utilisateur n'est pas nommée comme retirée" || ko_ "retired : garde-y nommée" "$dout"
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
env TMPDIR="$TMP/tmpd" KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 "$KITC/scripts/kit.sh" sync >/dev/null 2>&1 && rc=0 || rc=$?
[[ $rc != 0 && -z $(ls -A "$TMP/tmpd") && ! -e $KIT_CONFIG/settings.lock ]] && ok_ "échec : dossier temporaire et verrou nettoyés" || ko_ "échec : nettoyage" "code $rc : $(ls -A "$TMP/tmpd")"
cp "$TMP/snap.bak" "$KITC/global/settings.v1.json"

# 23. Verrou : tenu par un processus vivant, le second sync attend puis renonce ; un verrou orphelin est repris.
reset_home
msync >/dev/null 2>&1
jq --arg r "Bash(git add*)" '.permissions.allow |= map(select(. != $r))' "$KIT_ALLOW_JSON" >"$TMP/g.json" && cp "$TMP/g.json" "$KIT_ALLOW_JSON"
sleep 60 & holder=$!
mkdir "$KIT_CONFIG/settings.lock" && echo "$holder" >"$KIT_CONFIG/settings.lock/pid"
cp "$(cur_settings)" "$TMP/lock-before.json"
dout=$(env KIT_LOCK_WAIT=1 KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 "$KITC/scripts/kit.sh" sync 2>&1); rc=$?
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
dout=$(env PATH="$SHIM:$PATH" KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 "$KITC/scripts/kit.sh" sync 2>&1); rc=$?
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

# 3b. Registre modifié seulement dans sa table générée (kit sync d'anciennes versions) : restauré, la mise à jour passe ;
# une vraie modification du registre n'est jamais touchée.
mkdir -p "$SEED/global"
printf '# R\n<!-- kit:profiles:start -->\nA\n<!-- kit:profiles:end -->\nroutage\n' >"$SEED/global/skills-registry.md"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m reg && git -C "$SEED" push -q origin main
git -C "$KITCLONE" pull -q --ff-only
printf '# R\n<!-- kit:profiles:start -->\nB\n<!-- kit:profiles:end -->\nroutage\n' >"$KITCLONE/global/skills-registry.md"
push_commit v3r
echo $(($(date +%s) - 30000)) >"$KIT_CONFIG/autoupdate.stamp"
run_hook A=1
[[ $RC == 0 && $OUT == "kit mis à jour : "* && -z $(git -C "$KITCLONE" status --porcelain --untracked-files=no) ]] \
  && ok_ "registre modifié dans sa seule table générée : restauré, mise à jour faite" || ko_ "registre généré : restauré" "code $RC, sortie : $OUT"
printf '# R\n<!-- kit:profiles:start -->\nA\n<!-- kit:profiles:end -->\nroutage modifié\n' >"$KITCLONE/global/skills-registry.md"
push_commit v3s
before=$(head_of)
echo $(($(date +%s) - 30000)) >"$KIT_CONFIG/autoupdate.stamp"
run_hook A=1
[[ $RC == 0 && $OUT == *"ignorée"*"modifications locales"* && $(head_of) == "$before" ]] && grep -q 'routage modifié' "$KITCLONE/global/skills-registry.md" \
  && ok_ "registre vraiment modifié : conservé, mise à jour ignorée" || ko_ "registre modifié : conservé" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q -- global/skills-registry.md
rm -f "$KIT_CONFIG/autoupdate.skip.stamp"
echo $(($(date +%s) - 30000)) >"$KIT_CONFIG/autoupdate.stamp"
run_hook A=1

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

# 10. autoupdate.off : désactive le hook sur ce poste, même avec un commit en attente ; le retirer le réactive.
push_commit v6
before=$(head_of)
touch "$KIT_CONFIG/autoupdate.off"
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && -z $OUT && $(head_of) == "$before" ]] && ok_ "autoupdate.off : désactivé (aucune sortie, kit inchangé)" || ko_ "autoupdate.off : désactivé" "code $RC, sortie : $OUT"
rm -f "$KIT_CONFIG/autoupdate.off"
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == "kit mis à jour : "* && $(head_of) == "$(git -C "$ORIGIN" rev-parse main)" ]] \
  && ok_ "autoupdate.off retiré : le hook met à jour de nouveau" || ko_ "autoupdate.off retiré" "code $RC, sortie : $OUT"

# 11. autoupdate.pin : SHA complet (écrit par kit autoupdate pin) ; le hook ne suit que ce SHA.
setpin() { printf '%s\n%s\n' "$1" "${2:-nom}" >"$KIT_CONFIG/autoupdate.pin"; }
pinned_rec() { head -n 1 "$KIT_CONFIG/autoupdate.pinned" 2>/dev/null; }
v6_sha=$(git -C "$ORIGIN" rev-parse main)
git -C "$SEED" tag rel1 "$v6_sha"
push_commit v7
v7_sha=$(git -C "$ORIGIN" rev-parse main)
push_commit v8
v8_sha=$(git -C "$ORIGIN" rev-parse main)
git -C "$SEED" tag rel2 "$v8_sha"
git -C "$SEED" checkout -q -b side
echo side >"$SEED/SIDE"
git -C "$SEED" add SIDE
git -C "$SEED" commit -q -m side
side_sha=$(git -C "$SEED" rev-parse HEAD)
git -C "$SEED" checkout -q main
git -C "$SEED" push -q origin side rel1 rel2
git -C "$KITCLONE" fetch -q origin side
resolve() { "$KITCLONE/scripts/hooks/kit-autoupdate.sh" --resolve "$@" 2>"$TMP/resolve.err"; }
RES=$(resolve rel1); [[ $RES == "$v6_sha" ]] && ok_ "pin --resolve : un tag donne le SHA complet" || ko_ "pin --resolve tag" "$RES $(cat "$TMP/resolve.err")"
RES=$(resolve "${v8_sha:0:9}"); [[ $RES == "$v8_sha" ]] && ok_ "pin --resolve : un SHA abrégé donne le SHA complet" || ko_ "pin --resolve SHA abrégé" "$RES"
RES=$(resolve "$v8_sha"); [[ $RES == "$v8_sha" ]] && ok_ "pin --resolve : un SHA complet" || ko_ "pin --resolve SHA complet" "$RES"
RES=$(resolve main); [[ $RES == "$(git -C "$ORIGIN" rev-parse main)" ]] && ok_ "pin --resolve : une branche de origin (main)" || ko_ "pin --resolve main" "$RES"

setpin "$v6_sha" rel1
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && -z $OUT && $(head_of) == "$before" && $before == "$v6_sha" ]] \
  && ok_ "pin : déjà sur le SHA épinglé, origin/main plus récent ignoré (aucune sortie)" || ko_ "pin : déjà sur le SHA" "code $RC, sortie : $OUT"
setpin "$v8_sha" rel2
rm -f "$MARK"
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == "kit sur la version épinglée ${v8_sha:0:7} : "* && $(head_of) == "$v8_sha" ]] \
  && ok_ "pin : déplacé sur le SHA épinglé (message, HEAD détaché)" || ko_ "pin : déplacement" "code $RC, sortie : $OUT"
[[ -z $(git -C "$KITCLONE" symbolic-ref -q HEAD) && $(pinned_rec) == "$v8_sha" ]] && ok_ "pin : HEAD détaché, dernier SHA épinglé enregistré" || ko_ "pin : HEAD détaché ou enregistrement"
for _ in $(seq 1 50); do [[ -s $MARK ]] && break; sleep 0.1; done
[[ $(cat "$MARK" 2>/dev/null) == "sync" ]] && ok_ "pin : kit sync lancé après le déplacement" || ko_ "pin : kit sync" "$(cat "$MARK" 2>/dev/null)"
push_commit v9
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && -z $OUT && $(head_of) == "$v8_sha" ]] && ok_ "pin : un nouveau commit sur origin/main ne déplace pas un kit épinglé" || ko_ "pin : nouveau commit" "code $RC, sortie : $OUT"
setpin "$v6_sha" rel1
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"épinglée ${v6_sha:0:7}"* && $(head_of) == "$v6_sha" && $(pinned_rec) == "$v6_sha" ]] \
  && ok_ "pin : retour à une version plus ancienne (ancêtre de origin/main, au-dessus du socle)" || ko_ "pin : retour à v6" "code $RC, sortie : $OUT"
# Fichier invalide : un nom au lieu d'un SHA, une option, une valeur trop courte.
for bad in rel2 --upload-pack=x "${v8_sha:0:12}" "$(printf '%s' "$v8_sha" | tr 'a-f' 'A-F')"; do
  setpin "$bad"
  before=$(head_of)
  run_hook CLAUDE_CODE_REMOTE=true
  [[ $RC == 0 && $OUT == *"SHA de 40 caractères"* && $(head_of) == "$before" ]] && ok_ "pin : fichier invalide (${bad:0:14}…) : une ligne, rien ne bouge" || ko_ "pin : fichier invalide ${bad:0:14}" "code $RC, sortie : $OUT"
done
# SHA absent du dépôt local ; branche non fusionnée (le SHA existe localement mais n'est pas dans origin/main).
setpin 0123456789012345678901234567890123456789
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"refusée"*"absente du dépôt local"* && $(head_of) == "$before" ]] && ok_ "pin : SHA inconnu du dépôt refusé" || ko_ "pin : SHA inconnu" "code $RC, sortie : $OUT"
setpin "$side_sha" side
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"refusée"*"historique de origin/main"* && $(head_of) == "$before" ]] && ok_ "pin : SHA d'une branche non fusionnée refusé par le hook" || ko_ "pin : branche non fusionnée (hook)" "code $RC, sortie : $OUT"
RES=$(resolve side); rc=$?
[[ $rc != 0 && -z $RES && $(cat "$TMP/resolve.err") == *"refusé"*"historique de origin/main"* ]] && ok_ "pin --resolve : une branche non fusionnée est refusée" || ko_ "pin --resolve : branche non fusionnée" "$RES $(cat "$TMP/resolve.err")"
RES=$(resolve "${side_sha:0:10}"); rc=$?
[[ $rc != 0 && -z $RES ]] && ok_ "pin --resolve : le SHA d'une branche non fusionnée est refusé aussi" || ko_ "pin --resolve : SHA non fusionné" "$RES"
# Tag déplacé sur origin : le pin est un SHA, le hook n'en tient aucun compte ; la résolution par nom échoue ou garde l'ancien SHA.
git -C "$SEED" tag -f rel1 "$v8_sha" >/dev/null
git -C "$SEED" push -q -f origin rel1
setpin "$v6_sha" rel1
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && -z $OUT && $(head_of) == "$before" && $before == "$v6_sha" ]] && ok_ "pin : un tag déplacé sur origin est sans effet (le pin est un SHA)" || ko_ "pin : tag déplacé" "code $RC, sortie : $OUT"
RES=$(resolve rel1); rc=$?
[[ $RES != "$v8_sha" ]] && ok_ "pin --resolve : un tag déplacé sur origin ne résout pas vers le nouveau commit (rc $rc)" || ko_ "pin --resolve : tag déplacé" "$RES"
# Opération git en cours : rien ne bouge.
setpin "$v8_sha" rel2
for marker_f in BISECT_LOG MERGE_HEAD CHERRY_PICK_HEAD; do
  touch "$KITCLONE/.git/$marker_f"
  before=$(head_of)
  run_hook CLAUDE_CODE_REMOTE=true
  [[ $RC == 0 && $OUT == *"opération git en cours : $marker_f"* && $(head_of) == "$before" ]] && ok_ "pin : $marker_f présent, le hook ne déplace pas HEAD" || ko_ "pin : $marker_f" "code $RC, sortie : $OUT"
  rm -f "$KITCLONE/.git/$marker_f"
done
for marker_d in rebase-merge rebase-apply; do
  mkdir "$KITCLONE/.git/$marker_d"
  before=$(head_of)
  run_hook CLAUDE_CODE_REMOTE=true
  [[ $RC == 0 && $OUT == *"opération git en cours : $marker_d"* && $(head_of) == "$before" ]] && ok_ "pin : $marker_d présent, le hook ne déplace pas HEAD" || ko_ "pin : $marker_d" "code $RC, sortie : $OUT"
  rmdir "$KITCLONE/.git/$marker_d"
done
# HEAD détaché ailleurs que sur le dernier SHA épinglé : ignoré.
git -C "$KITCLONE" checkout -q --detach "$v7_sha"
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"autre révision que la dernière épinglée"* && $(head_of) == "$v7_sha" ]] && ok_ "pin : HEAD détaché ailleurs que sur le dernier SHA épinglé, ignoré" || ko_ "pin : détaché ailleurs" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q main
git -C "$KITCLONE" checkout -q -b feature-pin
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"épinglée ignorée"*"pas main"* && $(head_of) == "$before" ]] && ok_ "pin : branche de travail autre que main, ignoré" || ko_ "pin : branche de travail" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q main
git -C "$KITCLONE" branch -q -D feature-pin
echo dirty >>"$KITCLONE/VERSION"
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"modifications locales"* && $(head_of) == "$before" ]] && ok_ "pin : arbre modifié, ignoré" || ko_ "pin : arbre modifié" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q -- VERSION
# Fetch en échec : une ligne avec un pin (silence sans pin, voir plus haut).
git -C "$KITCLONE" remote set-url origin "file://$AU/inexistant.git"
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"fetch de origin impossible"* && $(head_of) == "$before" ]] && ok_ "pin : fetch en échec, une ligne et rien ne bouge" || ko_ "pin : fetch en échec" "code $RC, sortie : $OUT"
git -C "$KITCLONE" remote set-url origin "$ORIGIN"
# Épinglage retiré : suit main de nouveau ; opération git en cours aussi sans pin.
rm -f "$KIT_CONFIG/autoupdate.pin"
touch "$KITCLONE/.git/BISECT_LOG"
before=$(head_of)
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"opération git en cours : BISECT_LOG"* && $(head_of) == "$before" ]] && ok_ "sans pin : BISECT_LOG présent, le hook ne déplace pas HEAD" || ko_ "sans pin : BISECT_LOG" "code $RC, sortie : $OUT"
rm -f "$KITCLONE/.git/BISECT_LOG"
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == "kit mis à jour : "* && $(head_of) == "$(git -C "$ORIGIN" rev-parse main)" ]] && ok_ "épinglage retiré : le kit suit de nouveau origin/main" || ko_ "épinglage retiré" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q --detach "$v6_sha"
run_hook CLAUDE_CODE_REMOTE=true
[[ $RC == 0 && $OUT == *"détachée"*"pas main"* && $(head_of) == "$v6_sha" ]] && ok_ "sans pin : un kit détaché n'est pas déplacé tout seul" || ko_ "sans pin : détaché" "code $RC, sortie : $OUT"
git -C "$KITCLONE" checkout -q main

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
# skill/command descriptions, Superpowers on the /new-project path; 2c: state.md at session start; 2d: one hook process
# per Bash, Read, Edit, Write and Grep call). All budgets are now enforced.
ENFORCED='global_claude_md.words new_project_command.words skills_registry.words agent_descriptions.words skill_command_descriptions.words superpowers_path.words project_sessionstart.chars hooks_per_tool_call.Bash hooks_per_tool_call.Read hooks_per_tool_call.Edit hooks_per_tool_call.Write hooks_per_tool_call.Grep'
grep -E "^($(printf '%s' "$ENFORCED" | tr ' ' '|'))	" "$ROOT/scripts/context-budgets.tsv" >"$TMP/budgets-enforced.tsv"
if bash_out=$(BUDGET_ENFORCE=1 bash "$CB" --budgets "$TMP/budgets-enforced.tsv" --budget 2>&1); then
  ok_ "budgets appliqués (CLAUDE.md global, /new-project, registre, agents, skills et commandes, Superpowers, démarrage de projet) : respectés"
else
  ko_ "budgets appliqués dépassés" "$(grep 'DÉPASSÉ' <<<"$bash_out" | tr -s ' ' | paste -sd';' -)"
fi
echo "  -- autres budgets (avertissements seulement) --"
bash "$CB" --budget 2>&1 | sed 's/^/  /'
check "arbre réel : --budget sort 0 hors BUDGET_ENFORCE" bash "$CB" --budget

# ---------------------------------------------------------------------------
section "2c : tableau de bord retiré, démarrage de projet, mise à jour auto, version"
# Plus aucune trace du tableau de bord hors des plans, de la mesure, de l'instantané v1 (il en a besoin pour reconnaître
# les entrées des postes v1) et du code qui nettoie les postes (scripts/lib.sh) et le teste (ce fichier).
dash_hits=$(grep -rIlE 'kit-control|kit-emit|kit dash|task_create|task_update|wait_for_answer|checkpoint' \
  "$ROOT/global" "$ROOT/templates" "$ROOT/scripts" "$ROOT/install.sh" "$ROOT/README.md" "$ROOT/PLUGINS.md" "$ROOT/docs" "$ROOT/extras" "$ROOT/profiles" 2>/dev/null \
  | grep -vE '/global/collections-index\.json$|/docs/plans/|/docs/measure\.md$|/global/settings\.v1\.json$|/scripts/lib\.sh$|/scripts/test/run\.sh$' || true)
[[ -z $dash_hits ]] && ok_ "aucune mention du tableau de bord (kit-control, kit-emit, kit dash, task_*, checkpoint) hors plans et mesure" \
  || ko_ "mentions du tableau de bord restantes" "$(printf '%s' "$dash_hits" | sed "s#$ROOT/##" | paste -sd' ' -)"
kd_hits=$(grep -rIl 'KIT_DASH' "$ROOT/global" "$ROOT/templates" "$ROOT/scripts" "$ROOT/install.sh" "$ROOT/PLUGINS.md" "$ROOT/docs" "$ROOT/extras" "$ROOT/profiles" 2>/dev/null \
  | grep -vE '/global/collections-index\.json$|/docs/plans/|/docs/measure\.md$|/global/settings\.v1\.json$|/scripts/lib\.sh$|/scripts/test/run\.sh$' || true)
[[ -z $kd_hits ]] && ok_ "KIT_DASH_* : cité seulement dans le README (étapes de révocation), lib.sh (doctor) et les tests" || ko_ "KIT_DASH_* : mentions restantes" "$kd_hits"
[[ ! -e $ROOT/scripts/hooks/kit-emit.sh ]] && ok_ "kit-emit.sh supprimé" || ko_ "kit-emit.sh existe encore"
"$ROOT/scripts/kit.sh" help 2>&1 | grep -qi 'dash' && ko_ "usage : plus de section dashboard" || ok_ "usage : aucune section dashboard"
"$ROOT/scripts/kit.sh" dash status >/dev/null 2>&1 && ko_ "kit dash : sous-commande supprimée" || ok_ "kit dash : sous-commande supprimée"
grep -q 'KIT_DASH' "$ROOT/install.sh" "$ROOT/scripts/context-budget.sh" "$ROOT/scripts/kit.sh" && ko_ "KIT_DASH_* : plus géré" || ok_ "KIT_DASH_* : plus géré"
jqc '[.. | strings | select(test("kit-emit|kit-control|kit dash"))] | length == 0' "$ROOT/global/settings.json" && ok_ "global/settings.json : aucune entrée du tableau de bord" || ko_ "global/settings.json : entrée du tableau de bord"
jqc '[.hooks.PreToolUse[], .hooks.PostToolUse[]?] | map(.hooks | length) | add == 1' "$ROOT/global/settings.json" \
  && ok_ "hooks par appel d'outil : un seul (secrets)" || ko_ "hooks par appel d'outil"
# docs/plan.md est la seule liste de tâches : le gabarit suit le format de writing-plans.
PT="$ROOT/templates/project/docs/plan.md"
grep -q 'Agent:' "$PT" && grep -q 'Parallel with:' "$PT" && grep -q 'Done when:' "$PT" && grep -q -- '- \[ \]' "$PT" && ! grep -qiE 'dashboard|`#' "$PT" \
  && ok_ "gabarit docs/plan.md : lots, Agent / Parallel with / Done when, cases, plus de champ dashboard" || ko_ "gabarit docs/plan.md"
grep -q 'Agent: `<agent>` · Parallel with: <lot or none> · Done when:' "$ROOT/global/skills/writing-plans/SKILL.md" \
  && ok_ "writing-plans : la ligne de lot du gabarit est celle que le skill écrit" || ko_ "writing-plans : ligne de lot"

# Hook SessionStart du gabarit : state.md seul, 1 500 caractères au plus, coupé proprement avec un renvoi au fichier.
PROJ_HOOK=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/templates/project/.claude/settings.json")
[[ $(jq '.hooks.SessionStart | length' "$ROOT/templates/project/.claude/settings.json") == 1 ]] && ok_ "gabarit : un seul hook de démarrage" || ko_ "gabarit : plusieurs hooks de démarrage"
ss_run() { # dossier : sortie du hook (stdout) pour ce projet
  ( cd "$TMP" && env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$1" bash -c "$PROJ_HOOK" 2>/dev/null )
}
SSP="$TMP/ss-proj"
mkdir -p "$SSP/docs/memory"
printf '# État\n\n- **Fait** : lot 1\n- **Prochaines étapes** : lot 2\n' >"$SSP/docs/memory/state.md"
printf 'SECRET-HANDOFF-MARKER\n' >"$SSP/docs/memory/handoff.md"
printf 'SECRET-DECISIONS-MARKER\n' >"$SSP/docs/memory/decisions.md"
sso=$(ss_run "$SSP")
[[ $sso == *'- **Fait** : lot 1'* && $sso == *'lot 2'* ]] && ok_ "démarrage : state.md injecté" || ko_ "démarrage : state.md injecté" "$sso"
[[ $sso != *MARKER* ]] && ok_ "démarrage : ni handoff.md ni decisions.md" || ko_ "démarrage : autre fichier injecté"
[[ $sso != *tronqué* ]] && ok_ "démarrage : fichier court, pas de renvoi" || ko_ "démarrage : renvoi inutile"
# Plein : 60 lignes, puis une seule ligne géante, puis du texte accentué en C.UTF-8 : toujours <= 1 500 caractères.
awk 'BEGIN {for (i = 0; i < 60; i++) printf "- Fait : lot %d terminé, tests verts, prochaine étape documentée.\n", i}' >"$SSP/docs/memory/state.md"
sso=$(ss_run "$SSP")
n=$(printf '%s\n' "$sso" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')
((n <= 1500)) && ok_ "démarrage : état plein = $n caractères (<= 1 500)" || ko_ "démarrage : état plein trop long" "$n"
[[ $sso == *'tronqué : suite dans docs/memory/state.md'* ]] && ok_ "démarrage : coupé avec un renvoi à docs/memory/state.md" || ko_ "démarrage : renvoi absent"
last_kept=$(printf '%s\n' "$sso" | grep -v tronqué | tail -n 1)
[[ $last_kept == '- Fait : lot '*'documentée.' ]] && ok_ "démarrage : coupé à une fin de ligne (pas de ligne tronquée)" || ko_ "démarrage : ligne coupée" "$last_kept"
head -c 6000 /dev/zero | tr '\0' 'a' >"$SSP/docs/memory/state.md"
sso=$(ss_run "$SSP")
n=$(printf '%s\n' "$sso" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')
((n <= 1500)) && [[ $sso == *tronqué* ]] && ok_ "démarrage : une ligne géante est coupée aussi ($n caractères)" || ko_ "démarrage : ligne géante" "$n"
# Un lien symbolique, un état hors du projet ou l'absence de fichier : rien n'est injecté.
rm -f "$SSP/docs/memory/state.md"
[[ -z $(ss_run "$SSP") ]] && ok_ "démarrage : pas de state.md, aucune sortie" || ko_ "démarrage : sortie sans state.md"
printf 'HORS-PROJET\n' >"$TMP/ss-outside.md"
ln -s "$TMP/ss-outside.md" "$SSP/docs/memory/state.md"
[[ -z $(ss_run "$SSP") ]] && ok_ "démarrage : state.md lien symbolique ignoré" || ko_ "démarrage : lien symbolique suivi"
rm -f "$SSP/docs/memory/state.md"
# L est toujours uni à l'instantané v1 : ce qu'un sync v1 réécrit (retour arrière, autre poste) est retiré au sync v2 suivant ;
# deny et ask restent régis par settings.retired.json.
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
cp "$ROOT/global/settings.v1.json" "$KITC/global/settings.v1.json"
V1SENT2="Phrase v1 de test, réécrite par un sync v1."
jq --arg h "$(printf '%s' "$V1SENT2" | sha256_hex_t)" '.autoModeSha256.environment += [$h]' "$KITC/global/settings.v1.json" >"$TMP/g.json" && cp "$TMP/g.json" "$KITC/global/settings.v1.json"
reset_home
msync >/dev/null 2>&1
jq -s --arg s "$V1SENT2" '.[0] as $c | .[1] as $v | $c
    | .permissions.allow += ($v.permissions.allow + ["Bash(make lint)"])
    | .permissions.deny += ["Bash(mon-deny)"]
    | .hooks = (reduce ($v.hooks | keys[]) as $e (.hooks; .[$e] += $v.hooks[$e]))
    | .hooks.Stop += [{"hooks": [{"type": "command", "command": "echo mon-hook"}]}]
    | .autoMode.environment += [$s, "Mon serveur de test."]' "$(cur_settings)" "$ROOT/global/settings.v1.json" >"$TMP/d.json" && cp "$TMP/d.json" "$(cur_settings)"
jqc '(.permissions.allow | index("mcp__kit-control__ask") != null) and (.permissions.allow | index("Bash(kit api coolify *)") != null)' "$(cur_settings)" \
  && ok_ "L ∪ v1 : le sync v1 simulé a bien réécrit des entrées retirées" || ko_ "L ∪ v1 : fixture"
msync >/dev/null 2>&1
no_emit "$(cur_settings)" && jqc '[.permissions.allow[] | select(test("kit-control|kit dash"))] | length == 0' "$(cur_settings)" \
  && ok_ "L ∪ v1 : hooks kit-emit et autorisations kit-control réécrits par la v1 retirés" || ko_ "L ∪ v1 : hooks et autorisations"
jqc '.permissions.allow | index("Bash(kit api coolify *)") == null' "$(cur_settings)" && ok_ "L ∪ v1 : une règle allow v1 retirée du kit (kit api coolify *) est retirée" || ko_ "L ∪ v1 : règle allow v1"
jqc --arg s "$V1SENT2" '.autoMode.environment | index($s) == null' "$(cur_settings)" && ok_ "L ∪ v1 : une phrase d'environnement v1 réécrite est retirée" || ko_ "L ∪ v1 : phrase v1"
jqc '(.permissions.allow | index("Bash(make lint)") != null) and (.permissions.deny | index("Bash(mon-deny)") != null)
     and ([.hooks.Stop[].hooks[].command] | index("echo mon-hook") != null) and (.autoMode.environment | index("Mon serveur de test.") != null)' "$(cur_settings)" \
  && ok_ "L ∪ v1 : règle, hook, phrase de l'utilisateur et deny conservés" || ko_ "L ∪ v1 : ajouts utilisateur"
jqc '([.permissions.allow[] | select(. == "Bash(git status*)")] | length == 1) and (.hooks.SessionStart | length == 1)' "$(cur_settings)" \
  && ok_ "L ∪ v1 : les entrées du kit restent, sans doublon" || ko_ "L ∪ v1 : entrées du kit"
cp "$ROOT/global/settings.v1.json" "$KITC/global/settings.v1.json"
reset_home

# Domaines internes hors du dépôt public : aucune phrase autoMode ne nomme un hôte hors de la liste des API publiques.
bad_hosts=$(jq -r '[.autoMode[][] | strings] | map(scan("[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+(?:/[A-Za-z0-9_.-]+)?") | gsub("/.*$"; "") | ascii_downcase) | unique
  | map(select(. as $h | ["github.com", "api.cloudflare.com", "api.tailscale.com", "crates.io", "ghcr.io", "claude.ai", "skills.sh"] | index($h) | not))
  | map(select(test("\\.(org|net|com|be|app|io|dev|fr|eu)$"))) | .[]' "$ROOT/global/settings.json" 2>/dev/null | paste -sd' ' -)
[[ -z $bad_hosts ]] && ok_ "global/settings.json : aucun domaine interne dans autoMode (hôtes publics seulement)" || ko_ "global/settings.json : domaine dans autoMode" "$bad_hosts"
jqc '[.autoMode.environment[] | select(startswith("Trusted internal domains"))] | length == 0' "$ROOT/global/settings.json" \
  && ok_ "global/settings.json : plus de phrase « Trusted internal domains » (elle vit dans la surcharge locale)" || ko_ "global/settings.json : phrase des domaines internes"
# L'instantané v1 garde les 10 empreintes d'environnement : celles qui ne sont plus livrées sont reconnues comme venant du kit.
n_snap=$(jq '.autoModeSha256.environment | length' "$ROOT/global/settings.v1.json")
cur_h=$(jq -r '.autoMode.environment[]' "$ROOT/global/settings.json" | while IFS= read -r l; do printf '%s' "$l" | sha256_hex_t; done | jq -R . | jq -s .)
n_gone=$(jq --argjson cur "$cur_h" '[.autoModeSha256.environment[] | select(. as $h | $cur | index($h) | not)] | length' "$ROOT/global/settings.v1.json")
[[ $n_snap == 10 && $n_gone == 3 ]] && ok_ "instantané v1 : 10 empreintes d'environnement, dont 3 plus livrées (retirées au sync des postes qui les ont)" || ko_ "instantané v1 : empreintes d'environnement" "$n_snap dont $n_gone retirées"
[[ -z $(git -C "$ROOT" ls-files 2>/dev/null | grep -E '(^|/)(environment\.local\.txt|settings\.local\.json)$') ]] \
  && grep -qx 'environment.local.txt' "$ROOT/.gitignore" && grep -qx 'settings.local.json' "$ROOT/.gitignore" \
  && ok_ "fichiers locaux (environment.local.txt, settings.local.json) ignorés par Git et non versionnés" || ko_ ".gitignore des fichiers locaux"
# Génération de la surcharge locale à partir du fichier hors dépôt.
cp "$ROOT/global/settings.json" "$KIT_ALLOW_JSON"
cp "$ROOT/global/settings.v1.json" "$KITC/global/settings.v1.json"
reset_home
mkdir -p "$KIT_CONFIG"
printf '# commentaire\r\nTrusted internal domains: *.example.org: sites de test.\r\n\r\n   Key internal services: coolify.example.org   \n' >"$KIT_CONFIG/environment.local.txt"
dout=$(msync 2>&1)
OV="$KIT_CONFIG/settings.local.json"
jqc '.autoMode.environment == ["Trusted internal domains: *.example.org: sites de test.", "Key internal services: coolify.example.org"]' "$OV" \
  && ok_ "overlay : phrases du fichier texte écrites (commentaires, lignes vides, CRLF et espaces nettoyés)" || ko_ "overlay : contenu" "$(cat "$OV" 2>/dev/null)"
[[ $(fmode "$OV") == 600 ]] && ok_ "overlay : settings.local.json en 600" || ko_ "overlay : droits" "$(fmode "$OV")"
jqc '.autoMode.environment | index("Key internal services: coolify.example.org") != null and index("Trusted internal domains: *.example.org: sites de test.") != null' "$(cur_settings)" \
  && ok_ "overlay : phrases appliquées à settings.json par kit sync" || ko_ "overlay : appliquées à settings.json"
jqc '.autoMode.environment | index("Key internal services: coolify.example.org") != null' "$KIT_CONFIG/settings.managed.json" \
  && ok_ "overlay : le registre (K) les contient" || ko_ "overlay : registre"
! grep -q 'example.org' <<<"$dout" && grep -q 'autoMode.environment' <<<"$dout" && ok_ "overlay : le sync annonce le nombre de phrases sans les afficher" || ko_ "overlay : sortie du sync" "$dout"
cp "$(cur_settings)" "$TMP/ov1.json"; cp "$OV" "$TMP/ov1-local.json"; b1=$(n_backups)
msync >/dev/null 2>&1
cmp -s "$(cur_settings)" "$TMP/ov1.json" && cmp -s "$OV" "$TMP/ov1-local.json" && [[ $(n_backups) == "$b1" ]] \
  && ok_ "overlay : idempotent (settings.json, overlay et sauvegardes inchangés)" || ko_ "overlay : idempotence"
# Une phrase retirée du fichier texte disparaît de la surcharge et de settings.json au sync suivant.
printf 'Key internal services: coolify.example.org\n' >"$KIT_CONFIG/environment.local.txt"
msync >/dev/null 2>&1
jqc '(.autoMode.environment == ["Key internal services: coolify.example.org"])' "$OV" \
  && jqc '.autoMode.environment | index("Trusted internal domains: *.example.org: sites de test.") == null' "$(cur_settings)" \
  && ok_ "overlay : une phrase retirée du fichier texte est retirée partout" || ko_ "overlay : retrait d'une phrase"
# Les autres clés de la surcharge sont conservées.
jq '.permissions.allow = ["Bash(mon-outil *)"]' "$OV" >"$TMP/d.json" && cp "$TMP/d.json" "$OV"
printf 'Autre phrase locale.\n' >"$KIT_CONFIG/environment.local.txt"
msync >/dev/null 2>&1
jqc '(.permissions.allow == ["Bash(mon-outil *)"]) and (.autoMode.environment == ["Autre phrase locale."])' "$OV" \
  && jqc '.permissions.allow | index("Bash(mon-outil *)") != null' "$(cur_settings)" \
  && ok_ "overlay : les autres clés de settings.local.json (permissions) sont conservées" || ko_ "overlay : autres clés" "$(cat "$OV")"
# kit overlay env : fichier explicite, --clear, absence de fichier.
printf 'Phrase explicite.\n' >"$TMP/env-explicit.txt"
env KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay env "$TMP/env-explicit.txt" >/dev/null 2>&1
jqc '.autoMode.environment == ["Phrase explicite."]' "$OV" && ok_ "kit overlay env <fichier> : phrases du fichier données" || ko_ "kit overlay env <fichier>"
dout=$(env KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay env --clear 2>&1)
jqc '(.autoMode | not) and (.permissions.allow == ["Bash(mon-outil *)"])' "$OV" \
  && ok_ "kit overlay env --clear : phrases retirées, permissions conservées" || ko_ "kit overlay env --clear" "$(cat "$OV")"
rm -f "$KIT_CONFIG/environment.local.txt"
env KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay env >/dev/null 2>&1 && ko_ "kit overlay env sans fichier : erreur" || ok_ "kit overlay env sans fichier : erreur explicite"
env KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay bogus >/dev/null 2>&1 && ko_ "kit overlay : sous-commande inconnue refusée" || ok_ "kit overlay : sous-commande inconnue refusée"
# Ligne trop longue : refus, rien d'écrit.
reset_home
msync >/dev/null 2>&1
mkdir -p "$KIT_CONFIG"
head -c 900 /dev/zero | tr '\0' 'x' >"$KIT_CONFIG/environment.local.txt"
before_sum=$(cksum <"$(cur_settings)")
dout=$(msync 2>&1); rc=$?
[[ $rc == 0 && $dout == *"environment.local.txt ignoré"* && $dout == *"ligne(s) refusée(s)"* ]] \
  && ok_ "overlay : ligne de plus de 800 caractères refusée, avertissement, le sync continue (code 0)" || ko_ "overlay : ligne trop longue" "code $rc : $dout"
[[ $(cksum <"$(cur_settings)") == "$before_sum" && ! -e $KIT_CONFIG/settings.local.json ]] && ok_ "overlay refusée : settings.json intact, rien écrit" || ko_ "overlay refusée : écriture"
# Poste neuf, aucun fichier : aucune surcharge créée.
reset_home
msync >/dev/null 2>&1
[[ ! -e $KIT_CONFIG/settings.local.json ]] && ok_ "overlay : sans fichier texte, aucune surcharge créée" || ko_ "overlay : surcharge créée sans fichier"
# dry-run : annonce sans rien écrire.
mkdir -p "$KIT_CONFIG"
printf 'Phrase dry-run.\n' >"$KIT_CONFIG/environment.local.txt"
dout=$(msync --dry-run 2>&1)
[[ ! -e $KIT_CONFIG/settings.local.json ]] && grep -q 'seraient appliquées' <<<"$dout" && ok_ "overlay : --dry-run l'annonce sans écrire" || ko_ "overlay : dry-run" "$dout"
# Session cloud : la variable KIT_LOCAL_ENVIRONMENT alimente le fichier (600) puis la surcharge.
reset_home
env KIT_LOCAL_ENVIRONMENT=$'Phrase cloud 1.\nPhrase cloud 2.' KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 "$KITC/scripts/kit.sh" sync >/dev/null 2>&1
jqc '.autoMode.environment == ["Phrase cloud 1.", "Phrase cloud 2."]' "$OV" && [[ $(fmode "$KIT_CONFIG/environment.local.txt") == 600 ]] \
  && jqc '.autoMode.environment | index("Phrase cloud 2.") != null' "$(cur_settings)" \
  && ok_ "overlay : KIT_LOCAL_ENVIRONMENT (cloud) écrit le fichier (600) et la surcharge" || ko_ "overlay : variable cloud"
reset_home

# --- Durcissement de la source et de la cible de la surcharge (revue de sécurité de 2c) ---
OV="$KIT_CONFIG/settings.local.json"
ENVF="$KIT_CONFIG/environment.local.txt"
ovfresh() { reset_home; mkdir -p "$KIT_CONFIG"; chmod 700 "$KIT_CONFIG"; }
# Une erreur dans le fichier ne coupe pas le sync et garde les phrases précédentes (avertissement sur stderr).
ovfresh
printf 'Phrase valide 1.\n' >"$ENVF"
msync >/dev/null 2>&1
printf 'AGE-SECRET-KEY-1ABCDEF\n' >"$ENVF"
dout=$(msync 2>&1 >/dev/null); rc=$?
[[ $rc == 0 && $dout == *"ignoré"* ]] && jqc '.autoMode.environment == ["Phrase valide 1."]' "$OV" && jqc '.autoMode.environment | index("Phrase valide 1.") != null' "$(cur_settings)" \
  && ok_ "overlay : fichier refusé, sync terminé (0), avertissement sur stderr, phrases précédentes conservées" || ko_ "overlay : erreur non bloquante" "code $rc : $dout"
[[ $dout != *"AGE-SECRET"* ]] && ok_ "overlay : le contenu refusé n'est pas répété dans le message" || ko_ "overlay : contenu répété"
# Lien symbolique : source (défaut et explicite) et cible.
ovfresh
printf 'Phrase via lien.\n' >"$TMP/env-target.txt"
ln -s "$TMP/env-target.txt" "$ENVF"
dout=$(msync 2>&1 >/dev/null); rc=$?
[[ $rc == 0 && $dout == *"lien symbolique"* && ! -e $OV ]] && ok_ "overlay : environment.local.txt lien symbolique refusé (sync continue, rien écrit)" || ko_ "overlay : source symlink" "code $rc : $dout"
env KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay env "$ENVF" >/dev/null 2>&1 && ko_ "kit overlay env <lien> : refusé" || ok_ "kit overlay env <fichier lien symbolique> : refusé"
rm -f "$ENVF"
ovfresh
printf 'Phrase valide.\n' >"$ENVF"
printf '{"permissions":{"allow":["Bash(mon-outil *)"]}}\n' >"$TMP/elsewhere.json"
cp "$TMP/elsewhere.json" "$TMP/elsewhere.json.orig"
ln -s "$TMP/elsewhere.json" "$OV"
dout=$(msync 2>&1 >/dev/null); rc=$?
[[ $rc == 0 && $dout == *"settings.local.json est un lien symbolique"* ]] && cmp -s "$TMP/elsewhere.json" "$TMP/elsewhere.json.orig" \
  && ok_ "overlay : settings.local.json lien symbolique, jamais suivi à l'écriture (cible intacte)" || ko_ "overlay : cible symlink" "code $rc : $dout"
rm -f "$OV"
# Propriétaire et droits de la source.
ovfresh
printf 'Phrase valide.\n' >"$ENVF"
chmod 666 "$ENVF"
dout=$(msync 2>&1 >/dev/null)
[[ $dout == *"modifiable par d'autres"* && ! -e $OV ]] && ok_ "overlay : source modifiable par d'autres refusée" || ko_ "overlay : source 666" "$dout"
chmod 600 "$ENVF"
if [[ $(id -u) == 0 ]] && chown 12345 "$ENVF" 2>/dev/null; then
  dout=$(msync 2>&1 >/dev/null)
  [[ $dout == *"n'appartient pas"* && ! -e $OV ]] && ok_ "overlay : source d'un autre propriétaire refusée" || ko_ "overlay : source d'un autre propriétaire" "$dout"
else
  echo "  (chown indisponible ici : test du propriétaire ignoré)"
fi
# Phrases refusées : secrets, contrôles, invisibles, bidi, NUL, longueur, nombre.
ov_refused() { # description contenu-printf : refusé, rien écrit
  local d=$1 content=$2
  ovfresh
  printf -- "$content" >"$ENVF"
  local o; o=$(msync 2>&1 >/dev/null)
  if [[ $o == *"environment.local.txt ignoré"* && ! -e $OV ]]; then ok_ "overlay refuse : $d"; else ko_ "overlay refuse : $d" "$o"; fi
}
ov_refused "clé age" 'Cle AGE-SECRET-KEY-1QQQQQQQQQQQQ\n'
ov_refused "clé privée PEM" '-----BEGIN OPENSSH PRIVATE ''KEY-----\n'
ov_refused "jeton GitHub ghp_" 'jeton ghp_abcdef123456\n'
ov_refused "jeton GitHub github_pat_" 'github_pat_11ABCDEFG\n'
ov_refused "clé sk-" 'cle sk-abcdefghijklmnopqrstuvwxyz\n'
ov_refused "jeton Slack xoxb-" 'xo''xb-123456-abcdef\n'
ov_refused "suite hexadécimale de 40 caractères" 'hash 0123456789abcdef0123456789abcdef01234567\n'
ov_refused "suite base64 de 48 caractères" 'blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlq\n'
ov_refused "octet NUL" 'avant\000apres\n'
ov_refused "DEL (U+007F)" 'avant\177apres\n'
ov_refused "contrôle C0 (U+0001)" 'avant\001apres\n'
ov_refused "contrôle C1 (U+0085)" 'avant\302\205apres\n'
ov_refused "séparateur de ligne U+2028" 'avant\342\200\250apres\n'
ov_refused "séparateur de paragraphe U+2029" 'avant\342\200\251apres\n'
ov_refused "bidi U+202E" 'avant\342\200\256apres\n'
ov_refused "bidi U+2066" 'avant\342\201\246apres\n'
ov_refused "bidi U+2069" 'avant\342\201\251apres\n'
ov_refused "caractère de remplacement U+FFFD (UTF-8 invalide)" 'avant\377apres\n'
ov_refused "phrase de 801 caractères" "$(head -c 801 /dev/zero | tr '\0' 'a' | sed 's/aaaaaaaaaa/aaaaaaaaa /g')\n"
ov_refused "51 phrases" "$(awk 'BEGIN{for(i=1;i<=51;i++) printf "Phrase %d.\\n", i}')"
# Acceptés : phrases ordinaires (dont des mots proches des motifs), 50 phrases, accents.
ovfresh
printf 'Les tâches task-based et disk-usage de l equipe : domaines *.example.org.\nCoolify sur coolify.example.org (accès restreint).\n' >"$ENVF"
msync >/dev/null 2>&1
jqc '.autoMode.environment | length == 2' "$OV" && ok_ "overlay accepte : phrases ordinaires, accents, mots proches des motifs (task-based, disk-usage)" || ko_ "overlay : phrases ordinaires" "$(cat "$OV" 2>/dev/null)"
ovfresh
awk 'BEGIN{for(i=1;i<=50;i++) printf "Phrase %d.\n", i}' >"$ENVF"
msync >/dev/null 2>&1
jqc '.autoMode.environment | length == 50' "$OV" && ok_ "overlay accepte : 50 phrases" || ko_ "overlay : 50 phrases"
# --clear dure : le fichier source est mis de côté, le sync suivant ne remet rien.
ovfresh
printf 'Phrase a retirer.\n' >"$ENVF"
msync >/dev/null 2>&1
dout=$(env KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay env --clear 2>&1)
[[ ! -e $ENVF && -n $(ls "$KIT_CONFIG"/environment.local.txt.cleared-* 2>/dev/null) && $dout == *"mis de côté"* ]] && ok_ "overlay --clear : environment.local.txt renommé en .cleared-<date>" || ko_ "overlay --clear : renommage" "$dout"
msync >/dev/null 2>&1
jqc '(.autoMode // {}) | has("environment") | not' "$OV" && jqc '.autoMode.environment | index("Phrase a retirer.") == null' "$(cur_settings)" \
  && ok_ "overlay --clear dure : le sync suivant ne remet pas les phrases" || ko_ "overlay --clear : phrases revenues" "$(cat "$OV")"
dout=$(env KIT_LOCAL_ENVIRONMENT='Phrase variable.' KIT_HOME="$KITC" bash "$KITC/scripts/kit.sh" overlay env --clear 2>&1)
[[ $dout == *"KIT_LOCAL_ENVIRONMENT est défini"* ]] && ok_ "overlay --clear : avertit que KIT_LOCAL_ENVIRONMENT les remettrait" || ko_ "overlay --clear : variable" "$dout"
# Dry-run : jamais le texte des phrases d'environnement (comptes seulement), calculé depuis la surcharge simulée, sans résidu.
ovfresh
msync >/dev/null 2>&1
printf 'Domaine secret-interne.example.org de test.\nAutre phrase locale.\n' >"$ENVF"
mkdir -p "$TMP/dry-tmp"
dout=$(env TMPDIR="$TMP/dry-tmp" KIT_HOME="$KITC" KIT_SYNC_CONTEXT=0 "$KITC/scripts/kit.sh" sync --dry-run 2>&1)
! grep -q 'secret-interne' <<<"$dout" && ! grep -q 'Autre phrase locale' <<<"$dout" && ok_ "dry-run : le texte des phrases locales n'est jamais affiché" || ko_ "dry-run : phrases affichées" "$dout"
grep -q 'autoMode.environment : +2 -0' <<<"$dout" && grep -q 'phrases non affichées' <<<"$dout" \
  && ok_ "dry-run : l'écart vient de la surcharge simulée (+2) et n'affiche que le compte" || ko_ "dry-run : écart simulé" "$dout"
grep -q 'settings.local.json' <<<"$dout" && ! grep -q "$TMP/dry-tmp" <<<"$dout" && ok_ "dry-run : la surcharge est nommée par son vrai chemin, pas par le fichier temporaire" || ko_ "dry-run : nom de la surcharge" "$dout"
[[ ! -e $OV && -z $(ls -A "$TMP/dry-tmp") ]] && ok_ "dry-run : rien d'écrit, fichier temporaire de simulation supprimé" || ko_ "dry-run : résidu" "$(ls -A "$TMP/dry-tmp")"
jq '.autoMode.environment = ["Phrase déjà là."]' <<<'{}' >"$OV"
printf 'Phrase déjà là.\nNouvelle phrase.\n' >"$ENVF"
dout=$(msync --dry-run 2>&1)
! grep -q 'Nouvelle phrase' <<<"$dout" && ! grep -q 'Phrase déjà là' <<<"$dout" && ok_ "dry-run : aucune phrase affichée non plus quand la surcharge existe déjà" || ko_ "dry-run : surcharge existante" "$dout"
reset_home
# retire_dashboard : sans claude, avertissement sans erreur ; seul un lien vers ce kit est supprimé.
mkdir -p "$TMP/jqonly"
ln -sf "$(command -v jq)" "$TMP/jqonly/jq"
ln -sf "$(command -v rm)" "$TMP/jqonly/rm"
echo '{"mcpServers":{"kit-control":{"type":"http","url":"https://exemple.invalid/mcp"}}}' >"$HOME/.claude.json"
# shellcheck disable=SC2123
rd_out=$( ( source "$ROOT/scripts/lib.sh"; PATH="$TMP/jqonly"; retire_dashboard ) 2>&1 ); rd_rc=$?
[[ $rd_rc == 0 && $rd_out == *"encore déclaré"* ]] && ok_ "retire_dashboard : claude absent, avertissement, code 0" || ko_ "retire_dashboard : claude absent" "code $rd_rc : $rd_out"
rm -f "$HOME/.claude.json"
mkdir -p "$KIT_CONFIG/hooks" "$TMP/elsewhere-hooks"
echo mien >"$KIT_CONFIG/hooks/kit-emit.sh"
( source "$ROOT/scripts/lib.sh"; retire_dashboard ) >/dev/null 2>&1
[[ -f $KIT_CONFIG/hooks/kit-emit.sh && $(cat "$KIT_CONFIG/hooks/kit-emit.sh") == mien ]] && ok_ "retire_dashboard : un fichier ordinaire kit-emit.sh est conservé" || ko_ "retire_dashboard : fichier ordinaire supprimé"
rm -f "$KIT_CONFIG/hooks/kit-emit.sh"
echo mien >"$TMP/elsewhere-hooks/kit-emit.sh"
ln -s "$TMP/elsewhere-hooks/kit-emit.sh" "$KIT_CONFIG/hooks/kit-emit.sh"
( source "$ROOT/scripts/lib.sh"; retire_dashboard ) >/dev/null 2>&1
[[ -L $KIT_CONFIG/hooks/kit-emit.sh && -f $TMP/elsewhere-hooks/kit-emit.sh ]] && ok_ "retire_dashboard : un lien hors du kit est conservé" || ko_ "retire_dashboard : lien hors du kit supprimé"
rm -f "$KIT_CONFIG/hooks/kit-emit.sh"
ln -s "$ROOT/scripts/hooks/kit-emit.sh" "$KIT_CONFIG/hooks/kit-emit.sh"
( source "$ROOT/scripts/lib.sh"; retire_dashboard ) >/dev/null 2>&1
[[ ! -e $KIT_CONFIG/hooks/kit-emit.sh && ! -L $KIT_CONFIG/hooks/kit-emit.sh ]] && ok_ "retire_dashboard : le lien (cassé) vers ce kit est supprimé" || ko_ "retire_dashboard : lien du kit conservé"
# kit doctor : variables du tableau de bord encore dans l'environnement (noms seulement).
dd_out=$(KIT_DASH_TOKEN=valeur-secrete-de-test KIT_DASH_URL=https://exemple.invalid bash "$ROOT/scripts/kit.sh" doctor 2>&1)
[[ $dd_out == *"KIT_DASH_TOKEN KIT_DASH_URL"* && $dd_out != *valeur-secrete-de-test* && $dd_out != *exemple.invalid* ]] \
  && ok_ "kit doctor : signale KIT_DASH_TOKEN et KIT_DASH_URL par leur nom, jamais leur valeur" || ko_ "kit doctor : variables du tableau de bord" "$(grep -i 'KIT_DASH' <<<"$dd_out")"
dd_out=$(env -u KIT_DASH_TOKEN -u KIT_DASH_URL bash "$ROOT/scripts/kit.sh" doctor 2>&1)
[[ $dd_out != *KIT_DASH* ]] && ok_ "kit doctor : rien à signaler sans ces variables" || ko_ "kit doctor : faux avertissement"
reset_home
# Hook de démarrage : coupe sans casser un caractère UTF-8 (mawk, awk d'octets), ligne géante comprise.
ss_utf8_ok() { iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }
SSP2="$TMP/ss-utf8"
mkdir -p "$SSP2/docs/memory"
awk 'BEGIN {for (i = 0; i < 400; i++) printf "é"; printf " "; for (i = 0; i < 1500; i++) printf "ü "; print ""}' >"$SSP2/docs/memory/state.md"
sso=$(ss_run "$SSP2")
printf '%s\n' "$sso" | ss_utf8_ok && ((${#sso} <= 1500)) && [[ $sso == *tronqué* ]] && ok_ "démarrage : ligne géante accentuée coupée à une espace, UTF-8 valide" || ko_ "démarrage : UTF-8 (ligne géante)" "${#sso}"
awk 'BEGIN {for (i = 0; i < 3000; i++) printf "é"; print ""}' >"$SSP2/docs/memory/state.md"
sso=$(ss_run "$SSP2")
printf '%s\n' "$sso" | ss_utf8_ok && [[ $sso == *tronqué* ]] && ok_ "démarrage : ligne géante sans espace, aucun caractère coupé" || ko_ "démarrage : UTF-8 (sans espace)" "$sso"
awk 'BEGIN {for (i = 0; i < 80; i++) printf "- Fait : lot %d terminé, état à jour, été prévu, café servi.\n", i}' >"$SSP2/docs/memory/state.md"
sso=$(ss_run "$SSP2")
printf '%s\n' "$sso" | ss_utf8_ok && [[ $sso == *tronqué* ]] && ok_ "démarrage : texte accentué sur plusieurs lignes, coupe propre" || ko_ "démarrage : UTF-8 (lignes)"
# regen_registry : un profil qui n'a que des commentaires ne doit pas faire échouer kit registry ni kit sync (pipefail).
RG="$TMP/rgkit"
mkdir -p "$RG/global" "$RG/profiles" "$RG/scripts/hooks"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/kit.sh" "$ROOT/scripts/managed-settings.jq" "$RG/scripts/"
cp "$ROOT"/scripts/hooks/*.sh "$RG/scripts/hooks/"
cp "$ROOT"/global/settings*.json "$RG/global/"
printf '# commentaire seulement\n\n# autre commentaire\n' >"$RG/profiles/custom.txt"
printf 'vercel-labs/agent-skills --skill alpha beta\n' >"$RG/profiles/web.txt"
printf '# Registre\n<!-- kit:profiles:start -->\nancien\n<!-- kit:profiles:end -->\nfin\n' >"$RG/global/skills-registry.md"
reset_home
rg_out=$(env KIT_HOME="$RG" bash "$RG/scripts/kit.sh" registry 2>&1); rg_rc=$?
[[ $rg_rc == 0 ]] && grep -qF '| `custom` | (vide) |' "$RG/global/skills-registry.md" && grep -qF '| `web` |' "$RG/global/skills-registry.md" && ! grep -q ancien "$RG/global/skills-registry.md" \
  && ok_ "kit registry : un profil sans une seule ligne utile s'affiche (vide), code 0" || ko_ "kit registry : profil de commentaires" "code $rg_rc : $rg_out"
printf '# Registre\n<!-- kit:profiles:start -->\nancien\n<!-- kit:profiles:end -->\nfin\n' >"$RG/global/skills-registry.md"
rg_out=$(env KIT_HOME="$RG" KIT_SYNC_CONTEXT=0 bash "$RG/scripts/kit.sh" sync 2>&1); rg_rc=$?
[[ $rg_rc == 0 ]] && grep -qF '| `custom` | (vide) |' "$KIT_CONFIG/skills-registry.md" && ! grep -q ancien "$KIT_CONFIG/skills-registry.md" \
  && ok_ "kit sync (registre non masqué) : profil de commentaires, code 0, table régénérée dans \$KIT_CONFIG" || ko_ "kit sync : profil de commentaires" "code $rg_rc : $rg_out"
grep -q ancien "$RG/global/skills-registry.md" && ok_ "kit sync ne réécrit pas le registre suivi du dépôt du kit" || ko_ "kit sync a réécrit le registre suivi"
[[ $(readlink "$HOME/.claude/skills-registry.md") == "$KIT_CONFIG/skills-registry.md" ]] && ok_ "le lien skills-registry.md de .claude pointe vers la copie générée" || ko_ "lien du registre" "$(readlink "$HOME/.claude/skills-registry.md")"
reset_home

# kit --version : tag (ou révision) et date du commit.
KIT="$ROOT/scripts/kit.sh"
v=$(bash "$KIT" --version 2>&1)
[[ $v =~ ^kit\ .+\ \(20[0-9]{2}-[0-9]{2}-[0-9]{2}\)$ ]] && ok_ "kit --version : « $v »" || ko_ "kit --version" "$v"
[[ $(bash "$KIT" version 2>&1) == "$v" && $(bash "$KIT" -V 2>&1) == "$v" ]] && ok_ "kit version et -V : même sortie" || ko_ "kit version / -V"
VR="$TMP/vrepo"
git init -q -b main "$VR"
echo 1 >"$VR/f"
git -C "$VR" add f
GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' git -C "$VR" commit -q -m c1
git -C "$VR" tag v9.9.9
[[ $(env KIT_HOME="$VR" bash "$KIT" --version 2>&1) == "kit v9.9.9 (2026-01-02)" ]] && ok_ "kit --version : tag et date du commit" || ko_ "kit --version : tag" "$(env KIT_HOME="$VR" bash "$KIT" --version 2>&1)"
echo 2 >"$VR/f"
GIT_AUTHOR_DATE='2026-01-03T03:04:05Z' GIT_COMMITTER_DATE='2026-01-03T03:04:05Z' git -C "$VR" commit -q -am c2
[[ $(env KIT_HOME="$VR" bash "$KIT" --version 2>&1) =~ ^kit\ v9\.9\.9-1-g[0-9a-f]{7}\ \(2026-01-03\)$ ]] && ok_ "kit --version : commits depuis le tag (describe)" || ko_ "kit --version : describe" "$(env KIT_HOME="$VR" bash "$KIT" --version 2>&1)"
[[ $(env KIT_HOME="$TMP/pas-un-depot" bash "$KIT" --version 2>&1) == "kit version inconnue"* ]] && ok_ "kit --version : hors dépôt git, « version inconnue »" || ko_ "kit --version : hors dépôt"
# kit autoupdate : interrupteur et épinglage (les fichiers lus par le hook).
rm -rf "$KIT_CONFIG"
bash "$KIT" autoupdate off >/dev/null 2>&1
au_status() { bash "$KIT" autoupdate status 2>&1; }
[[ -e $KIT_CONFIG/autoupdate.off && $(au_status) == *'désactivée'* ]] && ok_ "kit autoupdate off : crée autoupdate.off, status le dit" || ko_ "kit autoupdate off"
bash "$KIT" autoupdate on >/dev/null 2>&1
[[ ! -e $KIT_CONFIG/autoupdate.off && $(au_status) == *'active'* ]] && ok_ "kit autoupdate on : retire autoupdate.off" || ko_ "kit autoupdate on"
# Dépôt de test avec les vrais scripts : un commit d'avant le socle d'épinglage, le commit courant (tag v-post), une
# branche non fusionnée.
FLS="$TMP/fl-seed"; FLO="$TMP/fl-origin.git"; FLC="$TMP/fl-clone"
git init -q --bare -b main "$FLO"
git init -q -b main "$FLS"
mkdir -p "$FLS/scripts/hooks"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/kit.sh" "$ROOT/scripts/managed-settings.jq" "$FLS/scripts/"
cp "$ROOT"/scripts/hooks/*.sh "$FLS/scripts/hooks/"
sed '/^KIT_PIN_FLOOR=/d' "$ROOT/scripts/hooks/kit-autoupdate.sh" >"$FLS/scripts/hooks/kit-autoupdate.sh"
git -C "$FLS" add -A && git -C "$FLS" commit -q -m pre-floor
pre_sha=$(git -C "$FLS" rev-parse HEAD)
cp "$ROOT/scripts/hooks/kit-autoupdate.sh" "$FLS/scripts/hooks/kit-autoupdate.sh"
git -C "$FLS" commit -q -am post-floor
post_sha=$(git -C "$FLS" rev-parse HEAD)
git -C "$FLS" tag v-post
git -C "$FLS" checkout -q -b side
echo x >"$FLS/SIDE" && git -C "$FLS" add SIDE && git -C "$FLS" commit -q -m side
side_sha=$(git -C "$FLS" rev-parse HEAD)
git -C "$FLS" checkout -q main
git -C "$FLS" remote add origin "$FLO"
git -C "$FLS" push -q origin main side v-post
git clone -q "$FLO" "$FLC"
fkit() { env KIT_HOME="$FLC" bash "$FLC/scripts/kit.sh" "$@"; }
fkit autoupdate pin v-post >/dev/null 2>&1
[[ $(sed -n 1p "$KIT_CONFIG/autoupdate.pin" 2>/dev/null) == "$post_sha" && $(sed -n 2p "$KIT_CONFIG/autoupdate.pin" 2>/dev/null) == v-post ]] \
  && ok_ "kit autoupdate pin <tag> : écrit le SHA complet (ligne 1) et le nom (ligne 2)" || ko_ "kit autoupdate pin <tag>" "$(cat "$KIT_CONFIG/autoupdate.pin" 2>/dev/null)"
[[ $(au_status) == *"épinglée sur ${post_sha:0:7} (v-post)"* ]] && ok_ "kit autoupdate status : SHA abrégé et nom" || ko_ "kit autoupdate status : pin" "$(au_status)"
# Refus : socle d'épinglage (version d'avant), branche non fusionnée ; le pin existant n'est pas touché.
dout=$(fkit autoupdate pin "$pre_sha" 2>&1); rc=$?
[[ $rc != 0 && $dout == *"socle d'épinglage"* && $(sed -n 1p "$KIT_CONFIG/autoupdate.pin") == "$post_sha" ]] \
  && ok_ "kit autoupdate pin : version d'avant le socle d'épinglage refusée (pin inchangé)" || ko_ "kit autoupdate pin : socle" "code $rc : $dout"
dout=$(fkit autoupdate pin "${pre_sha:0:8}" 2>&1); rc=$?
[[ $rc != 0 && $dout == *"socle d'épinglage"* ]] && ok_ "kit autoupdate pin : idem par SHA abrégé" || ko_ "kit autoupdate pin : socle (abrégé)" "code $rc : $dout"
dout=$(fkit autoupdate pin side 2>&1); rc=$?
[[ $rc != 0 && $dout == *"historique de origin/main"* && $(sed -n 1p "$KIT_CONFIG/autoupdate.pin") == "$post_sha" ]] \
  && ok_ "kit autoupdate pin : branche non fusionnée refusée (pin inchangé)" || ko_ "kit autoupdate pin : branche non fusionnée" "code $rc : $dout"
dout=$(fkit autoupdate pin "$side_sha" 2>&1); rc=$?
[[ $rc != 0 ]] && ok_ "kit autoupdate pin : SHA d'une branche non fusionnée refusé" || ko_ "kit autoupdate pin : SHA non fusionné" "$dout"
fkit autoupdate pin 'v1; rm -rf /' >/dev/null 2>&1 && ko_ "kit autoupdate pin : référence invalide refusée" || ok_ "kit autoupdate pin : référence invalide refusée"
fkit autoupdate pin -x >/dev/null 2>&1 && ko_ "kit autoupdate pin : option refusée" || ok_ "kit autoupdate pin : référence qui ressemble à une option refusée"
fkit autoupdate pin v-introuvable >/dev/null 2>&1 && ko_ "kit autoupdate pin : référence inconnue refusée" || ok_ "kit autoupdate pin : référence inconnue refusée"
# Un SHA abrégé est un objet, jamais un nom : un tag qui porte ce nom et vise un autre commit n'est pas suivi.
git -C "$FLS" tag "${post_sha:0:7}" "$pre_sha"
git -C "$FLS" push -q origin "${post_sha:0:7}"
rm -f "$KIT_CONFIG/autoupdate.pin"
dout=$(fkit autoupdate pin "${post_sha:0:7}" 2>&1)
[[ $(sed -n 1p "$KIT_CONFIG/autoupdate.pin" 2>/dev/null) == "$post_sha" ]] && ok_ "kit autoupdate pin : un SHA abrégé masqué par un tag du même nom résout l'objet, pas le tag" || ko_ "kit autoupdate pin : SHA masqué par un tag" "$(cat "$KIT_CONFIG/autoupdate.pin" 2>/dev/null) $dout"
# Le hook refuse aussi un pin d'avant le socle écrit à la main.
printf '%s\n%s\n' "$pre_sha" vieux >"$KIT_CONFIG/autoupdate.pin"
hout=$(env CLAUDE_CODE_REMOTE=true KIT_CONFIG="$KIT_CONFIG" "$FLC/scripts/hooks/kit-autoupdate.sh" </dev/null 2>&1)
[[ $hout == *"refusée"*"socle d'épinglage"* && $(git -C "$FLC" rev-parse HEAD) == "$post_sha" ]] && ok_ "hook : un pin d'avant le socle est refusé, HEAD inchangé" || ko_ "hook : pin d'avant le socle" "$hout"
printf 'garbage\n' >"$KIT_CONFIG/autoupdate.pin"
[[ $(au_status) == *"invalide"* ]] && ok_ "kit autoupdate status : un pin invalide est signalé" || ko_ "kit autoupdate status : pin invalide" "$(au_status)"
touch "$KIT_CONFIG/autoupdate.pinned"
fkit autoupdate unpin >/dev/null 2>&1
[[ ! -e $KIT_CONFIG/autoupdate.pin && ! -e $KIT_CONFIG/autoupdate.pinned ]] && ok_ "kit autoupdate unpin : retire autoupdate.pin et autoupdate.pinned" || ko_ "kit autoupdate unpin"
[[ $(KIT_AUTOUPDATE=0 au_status) == *'KIT_AUTOUPDATE=0'* ]] && ok_ "kit autoupdate status : KIT_AUTOUPDATE=0 signalé" || ko_ "kit autoupdate status : variable"
usage_txt=$("$ROOT/scripts/kit.sh" help 2>&1)
[[ $usage_txt == *autoupdate.pin* && $usage_txt == *autoupdate.off* ]] && ok_ "usage : autoupdate.off et autoupdate.pin documentés" || ko_ "usage : autoupdate"
rm -rf "$KIT_CONFIG"
[[ $(bash "$CB" --json | jq '.project_sessionstart.chars') -le 1500 ]] && ok_ "context-budget : démarrage de projet <= 1 500 caractères (mémoire pleine)" || ko_ "context-budget : démarrage de projet"
grep -q 'project_sessionstart.chars' <<<"$ENFORCED" && ok_ "budget project_sessionstart.chars appliqué (liste ENFORCED)" || ko_ "budget project_sessionstart.chars non appliqué"

# ---------------------------------------------------------------------------
section "2d : autorisations (règles du kit, hook, fragments par pile)"
GS="$ROOT/global/settings.json"
GV="$ROOT/global/settings.vps.json"
GR="$ROOT/global/settings.retired.json"
# Une règle Bash(<motif>) contre une commande : glob shell, comme Claude Code (« * » = n'importe quelle suite).
rule_matches() { # règle commande
  local r=$1 c=$2 pat
  [[ $r == 'Bash('*')' ]] || return 1
  pat=${r#Bash(}; pat=${pat%)}
  # shellcheck disable=SC2053
  [[ $c == $pat ]]
}
hits() { # allow|ask|deny commande fichier... : nombre de règles de la liste qui s'appliquent à la commande
  local list=$1 cmd=$2 f r n=0
  shift 2
  for f in "$@"; do
    while IFS= read -r r; do if rule_matches "$r" "$cmd"; then n=$((n + 1)); fi; done < <(jq -r --arg l "$list" '(.permissions[$l] // [])[]' "$f")
  done
  echo "$n"
}
# Décision du propriétaire : fusion de PR, push sur main et docker compose up|down ne demandent jamais.
for c in "gh pr merge 41 --squash" "git push origin main" "git push" "docker compose up -d" "docker compose down"; do
  [[ $(hits ask "$c" "$GS" "$GV") == 0 && $(hits deny "$c" "$GS" "$GV") == 0 && $(hits allow "$c" "$GS") -ge 1 ]] \
    && ok_ "autorisé sans demande : $c" || ko_ "autorisé sans demande : $c" "ask=$(hits ask "$c" "$GS" "$GV") deny=$(hits deny "$c" "$GS" "$GV") allow=$(hits allow "$c" "$GS")"
done
# Seul « git rebase -i » demande parmi les opérations git ordinaires ; un rebase non interactif est autorisé.
for c in "git rebase -i HEAD~3" "git rebase --interactive main" "git rebase main -i"; do
  [[ $(hits ask "$c" "$GS") -ge 1 ]] && ok_ "ask : $c" || ko_ "ask : $c"
done
[[ $(hits ask "git rebase origin/main" "$GS") == 0 && $(hits allow "git rebase origin/main" "$GS") -ge 1 ]] \
  && ok_ "git rebase non interactif : autorisé" || ko_ "git rebase non interactif"
[[ $(hits ask "git push --force origin x" "$GS") -ge 1 ]] && ok_ "git push --force reste en ask (réécriture d'historique)" || ko_ "git push --force en ask"
for c in "kit autoupdate off" "kit autoupdate pin v1.2.0" "kit overlay env /tmp/f" "kit overlay env --clear"; do
  [[ $(hits ask "$c" "$GS") -ge 1 ]] && ok_ "ask : $c" || ko_ "ask : $c"
done
# tofu apply|destroy : refusés, y compris par le script d'infra et -chdir ; plan, fmt et validate : autorisés.
for c in "tofu apply" "tofu apply -auto-approve" "tofu destroy" "tofu -chdir=infra/cloudflare apply" "tofu -chdir=infra/cloudflare destroy" \
  "bash infra/tofu.sh cloudflare apply" "bash infra/tofu.sh cloudflare destroy" "terraform apply" "terraform destroy"; do
  [[ $(hits deny "$c" "$GS") -ge 1 ]] && ok_ "deny : $c" || ko_ "deny : $c"
done
for c in "tofu plan -out=plan.tfplan" "tofu fmt -check -recursive infra" "tofu validate" "tofu init -backend=false" "tofu -chdir=infra/cloudflare plan" "bash infra/tofu.sh cloudflare plan"; do
  [[ $(hits deny "$c" "$GS") == 0 && $(hits allow "$c" "$GS") -ge 1 ]] && ok_ "autorisé : $c" || ko_ "autorisé : $c" "deny=$(hits deny "$c" "$GS") allow=$(hits allow "$c" "$GS")"
done
for c in "git worktree add ../x" "git rev-parse HEAD" "git cherry-pick abc" "git merge-base a b" "kit sync" "kit sync --dry-run" "kit equip search laravel" "kit index" \
  "docker compose ps" "docker compose logs web" "docker compose build" "shellcheck -x a.sh" "bash infra/tofu.sh cloudflare plan" \
  "bash infra/tofu.sh tailscale plan -out=x" "tofu -chdir=infra/cloudflare plan" "tofu -chdir=infra/tailscale validate -json"; do
  [[ $(hits allow "$c" "$GS") -ge 1 && $(hits ask "$c" "$GS") == 0 && $(hits deny "$c" "$GS") == 0 ]] && ok_ "allow : $c" || ko_ "allow : $c"
done
[[ $(hits allow "kit sync --yes" "$GS") == 0 ]] && ok_ "kit sync --yes n'est pas autorisé d'office (accepte un defaultMode plus permissif)" || ko_ "kit sync --yes"
# Review of 2d: commands that can write a file or print secrets are no longer auto-allowed, and the tofu rules are anchored.
for c in "sort -o x y" "uniq a b" "sed -i s/a/b/ f" "awk BEGIN{system(1)}" "date -s now" "echo x" "docker compose config" "kit index --out /tmp/x" \
  "tofu -chdir=infra/cloudflare show -json" "tofu -chdir=infra/other plan" "bash infra/tofu.sh cloudflare show -json planfile" \
  "bash infra/tofu.sh cloudflare state pull" "tofu -chdir=infra/cloudflare state pull"; do
  [[ $(hits allow "$c" "$GS") == 0 ]] && ok_ "pas d'allow automatique : $c" || ko_ "allow trop large : $c"
done
for c in "git push origin +main" "git push origin main -f" "git push --mirror" "git push origin -d old" "git push -d origin old" \
  "git reset -q --hard" "git reset HEAD~1 --hard" "git rebase --exec 'cat x' main" "git rebase -x 'make' main" "git rebase main -x make"; do
  [[ $(hits ask "$c" "$GS") -ge 1 ]] && ok_ "ask : $c" || ko_ "ask : $c"
done
for c in "git push origin main" "git push" "git push -u origin claude/x" "git reset HEAD~1" "git rebase origin/main"; do
  [[ $(hits ask "$c" "$GS") == 0 ]] && ok_ "pas de ask : $c" || ko_ "ask indu : $c"
done
# shellcheck disable=SC2088  # literal ~/ paths: they are rule texts
for t in '~/.claude.json' '~/.docker/**' '~/.netrc' '~/.npmrc' '~/.cloudflared/**' '~/.wrangler/**' '~/.config/rclone/**' '~/.config/gh/**' '~/.aws/**'; do
  jq -e --arg r "Read($t)" '.permissions.deny | index($r) != null' "$GS" >/dev/null && ok_ "deny : Read($t)" || ko_ "deny manquant : Read($t)"
done
# Les réglages protégés ne s'éditent pas avec Edit ni Write.
jq -e '.permissions.deny | (index("Edit(~/.config/claude-kit/**)") != null and index("Write(~/.config/claude-kit/**)") != null
  and index("Edit(~/.claude/settings.json)") != null and index("Write(~/.claude/settings.json)") != null)' "$GS" >/dev/null \
  && ok_ "deny : Edit et Write sur ~/.config/claude-kit/** et ~/.claude/settings.json" || ko_ "deny : réglages protégés"
# Règles retirées : listées dans settings.retired.json, jamais à la fois dans le kit et dans la liste des retraits.
jq -e '.permissions.ask | index("Bash(git push*)") != null' "$GR" >/dev/null && ok_ "retired : ask « git push* » (profil vps) listé" || ko_ "retired : git push*"
jq -e '.permissions.ask | index("Bash(git push*)") == null' "$GV" >/dev/null && ok_ "vps : plus d'ask sur git push*" || ko_ "vps : ask git push*"
overlap=$(jq -rn --slurpfile r "$GR" --slurpfile a "$GS" --slurpfile v "$GV" \
  '[($r[0].permissions.ask // [])[], ($r[0].permissions.deny // [])[]] as $ret
   | [($a[0].permissions.ask // [])[], ($a[0].permissions.deny // [])[], ($v[0].permissions.ask // [])[], ($v[0].permissions.deny // [])[]] as $kit
   | [$ret[] | select(. as $x | $kit | index($x) != null)] | join(" ")')
[[ -z $overlap ]] && ok_ "retired : aucune règle retirée n'est encore dans le kit" || ko_ "retired : règles à la fois retirées et présentes" "$overlap"
# Hook secrets : un seul processus par appel d'outil, y compris Grep ; les budgets le font respecter.
cbj=$(bash "$CB" --json 2>/dev/null)
all_one=1
for t in Bash Read Edit Write MultiEdit NotebookEdit Grep; do [[ $(jq -r --arg t "$t" '.hooks_per_tool_call[$t]' <<<"$cbj") == 1 ]] || all_one=0; done
((all_one)) && ok_ "hooks par appel d'outil : 1 pour Bash, Read, Edit, Write, MultiEdit, NotebookEdit et Grep" || ko_ "hooks par appel d'outil" "$(jq -c .hooks_per_tool_call <<<"$cbj")"
jq -e '[.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("guard-secrets.sh")))] | length == 1 and (.[0].matcher | split("|") | index("Grep") != null)' "$GS" >/dev/null \
  && ok_ "guard-secrets : un seul groupe, matcher avec Grep" || ko_ "guard-secrets : matcher"
for t in Bash Read Edit Write Grep; do
  grep -q "^hooks_per_tool_call.$t	1	" "$ROOT/scripts/context-budgets.tsv" && ok_ "budget hooks_per_tool_call.$t = 1" || ko_ "budget hooks_per_tool_call.$t absent"
done

# kit sync : le changement de règles apparaît dans --dry-run, les règles retirées sont nommées, rien n'est perdu.
KITD="$TMP/kitcopy2"
mkdir -p "$KITD/global"
cp "$ROOT"/global/settings*.json "$KITD/global/"
cp -R "$ROOT/scripts" "$KITD/scripts"
dsync() { env KIT_HOME="$KITD" KIT_SYNC_CONTEXT=0 "$KITD/scripts/kit.sh" sync "$@"; }
reset_home
# Poste « avant 2d » : le kit sans les nouvelles règles ni Grep dans le matcher, déjà synchronisé (registre écrit).
cp "$KITD/global/settings.json" "$TMP/new-settings.json"
jq '.hooks.PreToolUse[0].matcher = "Bash|Read|Edit|Write|MultiEdit|NotebookEdit"
    | .permissions.ask += ["Bash(git push*)"]
    | .permissions.ask |= map(select(. != "Bash(git rebase -i*)" and . != "Bash(git rebase --interactive*)" and . != "Bash(git rebase * -i*)" and . != "Bash(kit autoupdate *)" and . != "Bash(kit overlay *)"))
    | .permissions.deny |= map(select((test("tofu|terraform|^(Edit|Write)[(]") | not)))' "$TMP/new-settings.json" >"$KITD/global/settings.json"
dsync >/dev/null 2>&1
jq '.permissions.ask += ["Bash(mine)"] | .permissions.deny += ["Bash(mine-deny)"]' "$(cur_settings)" >"$TMP/u.json" && cp "$TMP/u.json" "$(cur_settings)"
cp "$TMP/new-settings.json" "$KITD/global/settings.json"
before_sum=$(cksum <"$(cur_settings)")
dry=$(dsync --dry-run 2>&1)
[[ $(cksum <"$(cur_settings)") == "$before_sum" ]] && ok_ "sync --dry-run : rien n'est écrit" || ko_ "sync --dry-run a écrit"
grep -q 'permissions.deny : +' <<<"$dry" && grep -qF '+ "Bash(tofu apply*)"' <<<"$dry" && grep -qF '+ "Edit(~/.claude/settings.json)"' <<<"$dry" \
  && ok_ "sync --dry-run : deny ajoutés (tofu apply, Edit de settings.json)" || ko_ "sync --dry-run : deny" "$dry"
grep -qF '+ "Bash(git rebase -i*)"' <<<"$dry" && grep -qF '+ "Bash(kit autoupdate *)"' <<<"$dry" \
  && ok_ "sync --dry-run : ask ajoutés (git rebase -i, kit autoupdate)" || ko_ "sync --dry-run : ask"
grep -qF -- '- "Bash(git push*)"' <<<"$dry" && ok_ "sync --dry-run : le retrait de ask git push* apparaît" || ko_ "sync --dry-run : retrait de git push*" "$dry"
grep -q 'hooks.PreToolUse : +1 -1' <<<"$dry" && ok_ "sync --dry-run : le groupe guard-secrets est remplacé (Grep ajouté), pas dupliqué" || ko_ "sync --dry-run : hooks" "$dry"
sout=$(dsync 2>&1)
grep -qF '→ retiré de permissions.ask : "Bash(git push*)"' <<<"$sout" && ok_ "sync : la règle retirée est nommée (settings.retired.json)" || ko_ "sync : règle retirée non nommée" "$sout"
jqc '(.permissions.ask | index("Bash(git push*)") == null and index("Bash(mine)") != null and index("Bash(git rebase -i*)") != null)
     and (.permissions.deny | index("Bash(mine-deny)") != null and index("Bash(tofu destroy*)") != null)' "$(cur_settings)" \
  && ok_ "sync : ask et deny de l'utilisateur gardés, ceux du kit posés" || ko_ "sync : ask et deny"
jqc '[.hooks.PreToolUse[] | select(any(.hooks[]; .command | endswith("guard-secrets.sh")))] | length == 1 and (.[0].matcher | contains("Grep"))' "$(cur_settings)" \
  && ok_ "sync : un seul guard-secrets, avec Grep" || ko_ "sync : guard-secrets"
cp "$(cur_settings)" "$TMP/s1.json"
dsync >/dev/null 2>&1
cmp -s "$(cur_settings)" "$TMP/s1.json" && ok_ "sync : idempotent après le changement de règles" || ko_ "sync : idempotence"
reset_home

# Fragments par pile : forme, cohérence avec la liste blanche de kit perms, carte type -> pile, pose par kit project add.
PF="$ROOT/templates/permissions"
for st in node astro next go rust pocketbase python tofu; do
  [[ -f $PF/$st.json ]] && ok_ "fragment : $st.json existe" || ko_ "fragment : $st.json absent"
done
for f in "$PF"/*.json; do
  st=$(basename "$f" .json)
  jq -e '(keys == ["permissions"]) and (.permissions | keys == ["allow"]) and (.permissions.allow | length > 0 and (length == (unique | length)) and all(type == "string" and startswith("Bash(")))' "$f" >/dev/null \
    && ok_ "fragment $st : seulement permissions.allow, sans doublon" || ko_ "fragment $st : forme"
  bad=""
  while IFS= read -r r; do "$PERMS" check "$r" >/dev/null 2>&1 || bad="$bad $r"; done < <(jq -r '.permissions.allow[]' "$f")
  [[ -z $bad ]] && ok_ "fragment $st : toutes les règles passent kit perms check" || ko_ "fragment $st : règles refusées par kit perms check" "$bad"
  clash=""
  while IFS= read -r r; do
    c=${r#Bash(}; c=${c%)}; c=${c% \*}
    [[ $(hits deny "$c" "$GS") == 0 && $(hits ask "$c" "$GS") == 0 ]] || clash="$clash $r"
  done < <(jq -r '.permissions.allow[]' "$f")
  [[ -z $clash ]] && ok_ "fragment $st : aucune règle ne tombe sous un deny ou un ask du kit" || ko_ "fragment $st : règles en conflit" "$clash"
done
reg_types=$(awk -F'|' '/^## Table de routage/ { on = 1; next } /^## / { on = 0 } on && /^\| `/ { gsub(/[ `]/, "", $2); print $2 }' "$ROOT/global/skills-registry.md")
bad=""
while IFS=$'\t' read -r ty sts; do
  [[ -z $ty || $ty == '#'* ]] && continue
  grep -qx "$ty" <<<"$reg_types" || bad="$bad type:$ty"
  for s in $sts; do [[ -f $PF/$s.json ]] || bad="$bad pile:$s"; done
done <"$PF/types.tsv"
[[ -z $bad ]] && ok_ "types.tsv : chaque type est au registre et chaque pile a son fragment" || ko_ "types.tsv incohérent" "$bad"

PP="$TMP/perm-proj"
mkdir -p "$PP/.claude" "$PP/docs/memory"
echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo bonjour"}]}]},"permissions":{"allow":["Bash(make lint)"],"deny":["Bash(make deploy)"]}}' >"$PP/.claude/settings.json"
pout=$("$ROOT/scripts/kit.sh" project add astro-static --no-skills --dir "$PP" 2>&1)
jqc '(.permissions.allow | index("Bash(npx astro check)") != null and index("Bash(npm run build)") != null and index("Bash(make lint)") != null and index("Bash(make lint)") < index("Bash(npm run build)"))
     and (.permissions.deny == ["Bash(make deploy)"]) and (.hooks.SessionStart[0].hooks[0].command == "echo bonjour")' "$PP/.claude/settings.json" \
  && ok_ "project add astro-static : règles de pile ajoutées après celles du projet, deny et hooks intacts" || ko_ "project add : fusion" "$pout"
grep -q 'piles : node astro' <<<"$pout" && ok_ "project add : annonce les piles posées (node astro)" || ko_ "project add : annonce" "$pout"
cp "$PP/.claude/settings.json" "$TMP/pp1.json"
pout=$("$ROOT/scripts/kit.sh" project add astro-static --no-skills --dir "$PP" 2>&1)
cmp -s "$PP/.claude/settings.json" "$TMP/pp1.json" && grep -q 'déjà présentes' <<<"$pout" && ok_ "project add : relançable, fichier identique, sans doublon" || ko_ "project add : idempotence" "$pout"
[[ $(jq '.permissions.allow | length - (unique | length)' "$PP/.claude/settings.json") == 0 ]] && ok_ "project add : aucun doublon" || ko_ "project add : doublons"
grep -q 'autorisations de pile (node astro)' "$PP/docs/memory/permissions.md" 2>/dev/null && ok_ "project add : journal docs/memory/permissions.md" || ko_ "project add : journal"
"$ROOT/scripts/kit.sh" project add python tofu --no-skills --dir "$PP" >/dev/null 2>&1
jqc '.permissions.allow | index("Bash(pytest *)") != null and index("Bash(tofu plan *)") != null and index("Bash(npx astro check)") != null' "$PP/.claude/settings.json" \
  && ok_ "project add python tofu : une pile seule (hors registre) pose ses règles, sans retirer les autres" || ko_ "project add python tofu"
"$ROOT/scripts/kit.sh" project add nonsense --dir "$PP" >/dev/null 2>&1 && ko_ "project add : un type inconnu doit échouer" || ok_ "project add : type ou pile inconnus refusés"
PG="$TMP/perm-go"
mkdir -p "$PG"
: >"$PG/go.mod"
"$ROOT/scripts/kit.sh" project perms --dir "$PG" >/dev/null 2>&1
jqc '.permissions.allow | index("Bash(go test ./...)") != null' "$PG/.claude/settings.json" && ok_ "project perms : sans argument, détecte la pile (go.mod)" || ko_ "project perms : détection"
PN="$TMP/perm-none"
mkdir -p "$PN"
"$ROOT/scripts/kit.sh" project add backend-rust --no-skills --no-permissions --dir "$PN" >/dev/null 2>&1
[[ ! -e $PN/.claude/settings.json ]] && ok_ "project add --no-permissions : aucun réglage posé" || ko_ "project add --no-permissions"
PL="$TMP/perm-link"
mkdir -p "$PL/.claude"
echo '{"permissions":{"allow":[]}}' >"$TMP/link-target.json"
ln -s "$TMP/link-target.json" "$PL/.claude/settings.json"
"$ROOT/scripts/kit.sh" project perms go --dir "$PL" >/dev/null 2>&1 && ko_ "project perms : un lien symbolique doit être refusé" || ok_ "project perms : lien symbolique refusé"
jqc '.permissions.allow == []' "$TMP/link-target.json" && ok_ "project perms : la cible du lien n'est pas modifiée" || ko_ "project perms : cible du lien modifiée"
PNEW="$TMP/perm-new"
"$ROOT/scripts/kit.sh" project new "$PNEW" backend-go --no-skills >/dev/null 2>&1
jqc '(.permissions.allow | index("Bash(go vet ./...)") != null) and (.hooks | has("SessionStart"))' "$PNEW/.claude/settings.json" \
  && ok_ "project new backend-go : règles de pile et hook de démarrage du gabarit réunis" || ko_ "project new : règles de pile" "$(jq -c . "$PNEW/.claude/settings.json" 2>&1 | cut -c1-200)"
"$ROOT/scripts/kit.sh" help 2>&1 | grep -q 'kit project perms' && ok_ "usage : kit project perms documenté" || ko_ "usage : kit project perms"

# ---------------------------------------------------------------------------
section "gabarits de CI (templates/ci)"
CID="$ROOT/templates/ci"
ci_stacks=$(sed -n 's/^CI_STACKS="\(.*\)"$/\1/p' "$ROOT/scripts/kit.sh")
ci_files=$(cd "$CID" && ls ./*.yml 2>/dev/null | sed 's#^\./##; s#\.yml$##' | sort | paste -sd' ' -)
[[ $(tr ' ' '\n' <<<"$ci_stacks" | sort | paste -sd' ' -) == "$ci_files" && $(wc -w <<<"$ci_files") -eq 9 ]] \
  && ok_ "templates/ci : 9 gabarits, les piles de CI_STACKS (kit.sh)" || ko_ "templates/ci : gabarits et CI_STACKS divergent" "$ci_files / $ci_stacks"
bad=""
while IFS=$'\t' read -r ty st; do
  [[ -z $ty || $ty == '#'* ]] && continue
  grep -qx "$ty" <<<"$reg_types" || bad="$bad type:$ty"
  [[ -f $CID/$st.yml ]] || bad="$bad gabarit:$st"
done <"$CID/types.tsv"
[[ -z $bad ]] && ok_ "templates/ci/types.tsv : chaque type est au registre et chaque gabarit existe" || ko_ "templates/ci/types.tsv incohérent" "$bad"
for f in "$CID"/*.yml; do
  n=$(basename "$f")
  # Every uses: is a data.forgejo.org action (or a GitHub action) pinned by a full SHA, with its version in a comment.
  ubad=$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$f" | grep -vE 'uses:[[:space:]]+https://(data\.forgejo\.org/actions|github\.com/[A-Za-z0-9_.-]+)/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+$' || true)
  [[ -z $ubad && $(grep -cE 'uses:' "$f") -ge 1 ]] && ok_ "$n : uses épinglés par SHA (40 hex) avec la version en commentaire" || ko_ "$n : uses non épinglé" "$ubad"
  grep -qE '^on: \[push\]$' "$f" && ok_ "$n : on: [push]" || ko_ "$n : déclencheur"
  if grep -qE 'secrets\.|\$\{\{[[:space:]]*secrets' "$f"; then ko_ "$n : utilise un secret"; else ok_ "$n : aucun secret"; fi
  grep -qE '^permissions:|^[[:space:]]+permissions:' "$f" && ko_ "$n : permissions (inutile sur Forgejo)" || ok_ "$n : pas de permissions:"
  grep -qE '^concurrency:' "$f" && ok_ "$n : concurrency" || ko_ "$n : concurrency absente"
done
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  ymlout=$(python3 - "$CID" <<'PY'
import glob, sys, yaml
for f in sorted(glob.glob(sys.argv[1] + "/*.yml")):
    n = f.rsplit("/", 1)[1]
    try:
        d = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception as e:
        print(f"{n}: YAML: {str(e).splitlines()[0]}"); continue
    on = d.get("on", d.get(True))  # YAML 1.1 reads the key `on` as true
    if on != ["push"]:
        print(f"{n}: on = {on!r}")
    if not d.get("name", "").startswith("ci-"):
        print(f"{n}: name")
    for j, job in (d.get("jobs") or {}).items():
        if not isinstance(job.get("timeout-minutes"), int):
            print(f"{n}: job {j} without timeout-minutes")
        if job.get("runs-on") != "ubuntu-latest":
            print(f"{n}: job {j} runs-on {job.get('runs-on')!r}")
        if not job.get("steps"):
            print(f"{n}: job {j} without steps")
    if not d.get("jobs"):
        print(f"{n}: no jobs")
PY
)
  [[ -z $ymlout ]] && ok_ "gabarits de CI : YAML valide, on: [push], timeout-minutes et runs-on par job (parseur strict)" || ko_ "gabarits de CI : YAML" "$(head -3 <<<"$ymlout")"
else
  echo "  (python3 + PyYAML absents : analyse YAML stricte ignorée)"
fi
# Renovate: the built-in github-actions manager updates the data.forgejo.org actions (forgejo-tags datasource), so the
# project template has no custom manager and nothing disables github-actions. Validator: opt-in (KIT_TEST_RENOVATE=1,
# downloads renovate from npm).
RENOVATE_VERSION=44.238.0
jqc '(has("customManagers") or has("regexManagers") | not)
     and ((.packageRules // []) | all((.matchManagers // []) | index("github-actions") == null))
     and (.minimumReleaseAge == "3 days")' "$ROOT/templates/project/renovate.json" \
  && ok_ "templates/project/renovate.json : ni customManagers ni github-actions désactivé, minimumReleaseAge 3 jours" || ko_ "templates/project/renovate.json : règle Renovate"
[[ ! -e $CID/renovate.json ]] && ok_ "templates/ci : plus de fragment Renovate (gestionnaire intégré)" || ko_ "templates/ci/renovate.json existe encore"
if [[ ${KIT_TEST_RENOVATE:-0} == 1 ]] && command -v npx >/dev/null 2>&1; then
  if rvout=$(cd "$TMP" && npx --yes --package "renovate@$RENOVATE_VERSION" -- renovate-config-validator --strict "$ROOT/templates/project/renovate.json" 2>&1); then
    ok_ "renovate-config-validator $RENOVATE_VERSION : templates/project/renovate.json valide"
  else
    ko_ "renovate-config-validator" "$(tail -3 <<<"$rvout")"
  fi
else
  echo "  (renovate-config-validator : KIT_TEST_RENOVATE=1 pour le lancer)"
fi
# actionlint: on PATH, or built at the pinned version with Go into the temp dir; skipped when neither works (offline).
ACTIONLINT_VERSION=v1.7.12
AL=$(command -v actionlint 2>/dev/null || true)
if [[ -z $AL ]] && command -v go >/dev/null 2>&1; then
  if GOBIN="$TMP/gobin" GOFLAGS=-mod=mod go install "github.com/rhysd/actionlint/cmd/actionlint@$ACTIONLINT_VERSION" >/dev/null 2>&1; then AL="$TMP/gobin/actionlint"; fi
fi
if [[ -n $AL ]]; then
  # Forgejo-only syntax (`uses: https://<host>/...`) is the one expected finding.
  if alout=$("$AL" -ignore 'specifying action "https://data\.forgejo\.org/' "$CID"/*.yml 2>&1); then ok_ "actionlint ($("$AL" -version 2>/dev/null | head -n1)) : gabarits sans erreur"; else ko_ "actionlint" "$(head -5 <<<"$alout")"; fi
else
  echo "  (actionlint absent et non installable : ignoré)"
fi

section "kit project ci"
KIT="$ROOT/scripts/kit.sh"
CIP="$TMP/ci"
mkdir -p "$CIP"
cidet() { # dossier : piles détectées, une ligne
  ( # shellcheck disable=SC1090
    source <(sed -n '/^detect_ci_stacks()/,/^}/p' "$KIT"); detect_ci_stacks "$1" | paste -sd' ' - )
}
mkdir -p "$CIP/astro" "$CIP/next" "$CIP/vite" "$CIP/gocli" "$CIP/goweb" "$CIP/rust" "$CIP/tauri/src-tauri" "$CIP/pb/pb_hooks" "$CIP/static" "$CIP/empty" "$CIP/pbvite/pb_migrations"
echo '{"dependencies":{"astro":"^5.0.0"}}' >"$CIP/astro/package.json"
echo '{"dependencies":{"next":"16.0.0","react":"19.0.0"}}' >"$CIP/next/package.json"
echo '{"devDependencies":{"vite":"7.0.0"}}' >"$CIP/vite/package.json"
echo '{"devDependencies":{"vite":"7.0.0"}}' >"$CIP/pbvite/package.json"
: >"$CIP/gocli/go.mod"; : >"$CIP/gocli/.goreleaser.yaml"; : >"$CIP/goweb/go.mod"
: >"$CIP/rust/Cargo.toml"
echo '{"devDependencies":{"@tauri-apps/cli":"2.12.4","vite":"7.0.0"}}' >"$CIP/tauri/package.json"; : >"$CIP/tauri/src-tauri/Cargo.toml"
echo '<!DOCTYPE html>' >"$CIP/static/index.html"
dres=""
for c in "astro:astro" "next:next" "vite:vite" "gocli:go-cli" "goweb:go-web" "rust:rust" "tauri:tauri" "pb:pocketbase" "static:static" "empty:" "pbvite:vite pocketbase"; do
  got=$(cidet "$CIP/${c%%:*}")
  [[ $got == "${c#*:}" ]] || dres="$dres ${c%%:*}=[$got]"
done
[[ -z $dres ]] && ok_ "project ci : détection (astro, next, vite, go-cli, go-web, rust, tauri, pocketbase, static, vide, pocketbase+vite)" || ko_ "project ci : détection" "$dres"
cout=$("$KIT" project ci --dir "$CIP/astro" 2>&1)
cmp -s "$CIP/astro/.forgejo/workflows/ci.yml" "$CID/astro.yml" && grep -q 'piles de CI détectées : astro' <<<"$cout" \
  && ok_ "project ci : sans argument, pose .forgejo/workflows/ci.yml de la pile détectée" || ko_ "project ci : écriture" "$cout"
[[ $(grep -v '^#' "$CIP/astro/.fs0/bridge.yaml") == 'enabled: true' ]] && ok_ "project ci : .fs0/bridge.yaml minimal (enabled: true)" || ko_ "project ci : bridge.yaml"
cmp -s "$CIP/astro/renovate.json" "$ROOT/templates/project/renovate.json" && ok_ "project ci : renovate.json absent = gabarit du projet" || ko_ "project ci : renovate.json créé"
echo "# edited" >>"$CIP/astro/.forgejo/workflows/ci.yml"
cp "$CIP/astro/.forgejo/workflows/ci.yml" "$TMP/ci-edited.yml"
"$KIT" project ci --dir "$CIP/astro" >/dev/null 2>&1 && ko_ "project ci : un ci.yml existant doit être refusé sans --force" || ok_ "project ci : ci.yml existant refusé sans --force"
cmp -s "$CIP/astro/.forgejo/workflows/ci.yml" "$TMP/ci-edited.yml" && ok_ "project ci : ci.yml existant intact" || ko_ "project ci : ci.yml écrasé"
echo 'enabled: false' >"$CIP/astro/.fs0/bridge.yaml"
"$KIT" project ci vite --force --dir "$CIP/astro" >/dev/null 2>&1
cmp -s "$CIP/astro/.forgejo/workflows/ci.yml" "$CID/vite.yml" && ok_ "project ci vite --force : écrase avec la pile donnée" || ko_ "project ci --force"
[[ $(cat "$CIP/astro/.fs0/bridge.yaml") == 'enabled: false' ]] && ok_ "project ci : un .fs0/bridge.yaml existant n'est jamais réécrit" || ko_ "project ci : bridge.yaml réécrit"
"$KIT" project ci backend-go pocketbase --force --dir "$CIP/astro" >/dev/null 2>&1
cmp -s "$CIP/astro/.forgejo/workflows/ci.yml" "$CID/go-web.yml" && cmp -s "$CIP/astro/.forgejo/workflows/ci-pocketbase.yml" "$CID/pocketbase.yml" \
  && ok_ "project ci backend-go pocketbase : type du registre traduit (go-web), seconde pile dans ci-pocketbase.yml" || ko_ "project ci : plusieurs piles"
"$KIT" project ci nonsense --dir "$CIP/empty" >/dev/null 2>&1 && ko_ "project ci : une pile inconnue doit échouer" || ok_ "project ci : pile inconnue refusée"
cout=$("$KIT" project ci --dir "$CIP/empty" 2>&1)
[[ ! -e $CIP/empty/.forgejo && ! -e $CIP/empty/.fs0 ]] && grep -q 'aucune pile de CI' <<<"$cout" && ok_ "project ci : rien détecté, rien écrit" || ko_ "project ci : dossier sans pile" "$cout"
# Symbolic links: the workflow file, the workflows directory, bridge.yaml, renovate.json.
mkdir -p "$CIP/l1/.forgejo/workflows" "$TMP/ci-out"
: >"$CIP/l1/go.mod"
echo keep >"$TMP/ci-out/target.yml"
ln -s "$TMP/ci-out/target.yml" "$CIP/l1/.forgejo/workflows/ci.yml"
"$KIT" project ci --force --dir "$CIP/l1" >/dev/null 2>&1 && ko_ "project ci : ci.yml en lien symbolique doit être refusé" || ok_ "project ci : ci.yml en lien symbolique refusé (même avec --force)"
[[ $(cat "$TMP/ci-out/target.yml") == keep ]] && ok_ "project ci : la cible du lien n'est pas modifiée" || ko_ "project ci : cible du lien modifiée"
mkdir -p "$CIP/l2/.forgejo"
: >"$CIP/l2/go.mod"
ln -s "$TMP/ci-out" "$CIP/l2/.forgejo/workflows"
"$KIT" project ci --dir "$CIP/l2" >/dev/null 2>&1 && ko_ "project ci : .forgejo/workflows en lien doit être refusé" || ok_ "project ci : dossier .forgejo/workflows en lien refusé"
[[ ! -e $TMP/ci-out/ci.yml ]] && ok_ "project ci : rien écrit à travers le lien" || ko_ "project ci : écrit à travers le lien"
mkdir -p "$CIP/l3"
: >"$CIP/l3/go.mod"
echo '{}' >"$TMP/ci-out/renovate.json"
ln -s "$TMP/ci-out/renovate.json" "$CIP/l3/renovate.json"
"$KIT" project ci --dir "$CIP/l3" >/dev/null 2>&1 && ko_ "project ci : renovate.json en lien doit être refusé" || ok_ "project ci : renovate.json en lien refusé"
[[ ! -e $CIP/l3/.forgejo && $(cat "$TMP/ci-out/renovate.json") == '{}' ]] && ok_ "project ci : refus avant toute écriture" || ko_ "project ci : écriture partielle avant refus"
: >"$HOME/go.mod"
"$KIT" project ci --dir "$HOME" >/dev/null 2>&1 && ko_ "project ci : le dossier personnel doit être refusé" || ok_ "project ci : dossier personnel refusé"
[[ ! -e $HOME/.forgejo ]] && ok_ "project ci : rien écrit dans le dossier personnel" || ko_ "project ci : écrit dans le dossier personnel"
rm -f "$HOME/go.mod"
# Renovate: an existing renovate.json is never touched; another Renovate config file means none is created.
mkdir -p "$CIP/r1" "$CIP/r3"
for d in r1 r3; do : >"$CIP/$d/go.mod"; done
echo '{"extends":["config:base"]}' >"$CIP/r1/renovate.json"
"$KIT" project ci --dir "$CIP/r1" >/dev/null 2>&1
[[ $(cat "$CIP/r1/renovate.json") == '{"extends":["config:base"]}' ]] && ok_ "project ci : renovate.json existant laissé intact" || ko_ "project ci : renovate.json existant modifié"
echo '{}' >"$CIP/r3/renovate.json5"
"$KIT" project ci --dir "$CIP/r3" >/dev/null 2>&1
[[ ! -e $CIP/r3/renovate.json && $(cat "$CIP/r3/renovate.json5") == '{}' ]] \
  && ok_ "project ci : autre fichier Renovate (renovate.json5) : aucun renovate.json créé" || ko_ "project ci : renovate.json5"
mkdir -p "$CIP/gh/.github/workflows"
: >"$CIP/gh/go.mod"
cout=$("$KIT" project ci --dir "$CIP/gh" 2>&1)
grep -q '.github/workflows/ existe' <<<"$cout" && ok_ "project ci : prévient quand .github/workflows/ existe" || ko_ "project ci : avertissement .github" "$cout"
# kit project add / new: CI of the type when absent, existing workflow left untouched, --no-ci.
PA="$TMP/ci-add"
mkdir -p "$PA"
"$KIT" project add astro-static --no-skills --dir "$PA" >/dev/null 2>&1
cmp -s "$PA/.forgejo/workflows/ci.yml" "$CID/astro.yml" && [[ -f $PA/.fs0/bridge.yaml ]] && ok_ "project add astro-static : pose la CI astro et .fs0/bridge.yaml" || ko_ "project add : CI"
echo "# mine" >"$PA/.forgejo/workflows/ci.yml"
cout=$("$KIT" project add backend-go --no-skills --dir "$PA" 2>&1); rc=$?
[[ $rc == 0 && $(cat "$PA/.forgejo/workflows/ci.yml") == '# mine' ]] && grep -q 'CI déjà présente' <<<"$cout" \
  && ok_ "project add : CI existante laissée telle quelle, sans erreur" || ko_ "project add : CI existante" "$cout"
PB="$TMP/ci-add2"
mkdir -p "$PB"
"$KIT" project add backend-rust --no-skills --no-ci --dir "$PB" >/dev/null 2>&1
[[ ! -e $PB/.forgejo && ! -e $PB/.fs0 ]] && ok_ "project add --no-ci : aucune CI posée" || ko_ "project add --no-ci"
cmp -s "$PNEW/.forgejo/workflows/ci.yml" "$CID/go-web.yml" && ok_ "project new backend-go : CI go-web posée" || ko_ "project new : CI"
"$KIT" help 2>&1 | grep -q 'kit project ci' && ok_ "usage : kit project ci documenté" || ko_ "usage : kit project ci"
grep -q 'kit project add <type>...` (pose aussi la CI Forgejo)' "$ROOT/global/commands/new-project.md" && ok_ "/new-project : kit project add pose la CI" || ko_ "/new-project : CI non citée"
grep -qF -- '- CI dans `.forgejo/workflows/`, jamais `.github/workflows/`.' "$ROOT/global/CLAUDE.md" && ok_ "CLAUDE.md global : CI dans .forgejo/workflows/" || ko_ "CLAUDE.md global : règle de CI absente"

# kit sync ne salit pas le dépôt du kit, et refuse d'appliquer des réglages si scripts/ ou global/settings*.json y ont des
# modifications non commitées (un agent aurait pu y écrire un hook ou une règle).
KG="$TMP/kitgit"
mkdir -p "$KG"
cp -R "$ROOT/global" "$ROOT/profiles" "$ROOT/scripts" "$ROOT/templates" "$KG/"
rm -rf "$KG/scripts/test"
git -C "$KG" init -q -b main
git -C "$KG" add -A && git -C "$KG" commit -q -m kit
ksync() { env KIT_HOME="$KG" KIT_SYNC_CONTEXT=0 bash "$KG/scripts/kit.sh" sync "$@"; }
reset_home
ksout=$(ksync 2>&1)
[[ -z $(git -C "$KG" status --porcelain --untracked-files=all) ]] && ok_ "kit sync : git status --porcelain du dépôt du kit vide après un sync" || ko_ "kit sync a sali le dépôt du kit" "$(git -C "$KG" status --porcelain | head -3)"
grep -q 'kit:profiles:start' "$KIT_CONFIG/skills-registry.md" && [[ ! -L $KIT_CONFIG/skills-registry.md ]] && ok_ "kit sync : copie générée du registre dans \$KIT_CONFIG" || ko_ "copie du registre" "$ksout"
jqc '.permissions.allow | index("Bash(git status*)") != null' "$(cur_settings)" && ok_ "kit sync : réglages appliqués (arbre propre)" || ko_ "kit sync : réglages" "$ksout"
jqc 'any(.permissions.deny[]; startswith("Edit(") and endswith("/scripts/**)") and contains("kitgit"))' "$(cur_settings)" \
  && ok_ "kit sync : deny Edit/Write du kit installé (scripts/**) posé pour ce poste" || ko_ "deny du kit installé" "$(jq -c '[.permissions.deny[] | select(startswith("Edit("))]' "$(cur_settings)")"
jqc 'any(.permissions.deny[]; startswith("Write(") and endswith("/global/settings*.json)") and contains("kitgit"))' "$(cur_settings)" \
  && ok_ "kit sync : deny Write du kit installé (global/settings*.json) posé" || ko_ "deny Write du kit installé"
cp "$(cur_settings)" "$TMP/ks0.json"
echo "# modifié hors du dépôt par un agent" >>"$KG/scripts/hooks/guard-secrets.sh"
jq '.permissions.allow += ["Bash(evil *)"]' "$KG/global/settings.json" >"$TMP/ks-evil.json" && cp "$TMP/ks-evil.json" "$KG/global/settings.json"
ksout=$(ksync 2>&1)
grep -q 'réglages non appliqués' <<<"$ksout" && cmp -s "$(cur_settings)" "$TMP/ks0.json" \
  && ok_ "kit sync : modifications non commitées de scripts/ ou global/settings*.json : réglages non appliqués, fichier intact" || ko_ "kit sync : arbre modifié" "$ksout"
kdry=$(ksync --dry-run 2>&1)
grep -q 'réglages non appliqués' <<<"$kdry" && grep -qF '+ "Bash(evil *)"' <<<"$kdry" && cmp -s "$(cur_settings)" "$TMP/ks0.json" \
  && ok_ "kit sync --dry-run : prévient et montre quand même l'écart, sans rien écrire" || ko_ "kit sync --dry-run : arbre modifié" "$kdry"
ksout=$(ksync --yes 2>&1)
jqc '.permissions.allow | index("Bash(evil *)") != null' "$(cur_settings)" && ok_ "kit sync --yes : accepte les modifications relues" || ko_ "kit sync --yes" "$ksout"
git -C "$KG" checkout -q -- .
# Un registre suivi modifié par erreur (table générée) ne bloque pas kit sync ; kit update le restaure.
printf '\n<!-- bruit -->\n' >>"$KG/global/skills-registry.md"
ksout=$(ksync 2>&1)
grep -q 'réglages non appliqués' <<<"$ksout" && ko_ "un registre modifié ne doit pas bloquer kit sync" "$ksout" || ok_ "kit sync : le registre suivi n'entre pas dans la protection de l'arbre"
git -C "$KG" checkout -q -- .
awk '/kit:profiles:start/ { print; print "| fantôme | x |"; next } { print }' "$KG/global/skills-registry.md" >"$TMP/reg-gen.md" && cp "$TMP/reg-gen.md" "$KG/global/skills-registry.md"
( source "$ROOT/scripts/lib.sh"; restore_generated_registry "$KG" )
[[ -z $(git -C "$KG" status --porcelain) ]] && ok_ "restore_generated_registry : la table générée modifiée est restaurée" || ko_ "restore_generated_registry (table)"
printf '\nligne ajoutée à la main\n' >>"$KG/global/skills-registry.md"
( source "$ROOT/scripts/lib.sh"; restore_generated_registry "$KG" )
grep -q 'ligne ajoutée à la main' "$KG/global/skills-registry.md" && ok_ "restore_generated_registry : une vraie modification est conservée" || ko_ "restore_generated_registry (vraie modification)"
git -C "$KG" checkout -q -- .
reset_home

# ---------------------------------------------------------------------------
section "en-têtes YAML des agents, skills et commandes"
# A plain (unquoted) scalar containing ": " is invalid YAML for strict parsers
# (npx skills, js-yaml): French typography puts a space before the colon.
fmbad=$(find "$ROOT/global" "$ROOT/extras" "$ROOT/templates" -name '*.md' -type f 2>/dev/null | while IFS= read -r f; do
  awk -v f="$f" '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[ \t]*$/ { exit }
    /^[A-Za-z_-]+:[ \t]/ {
      v = $0; sub(/^[A-Za-z_-]+:[ \t]+/, "", v)
      if (v !~ /^["\047|>\[{]/ && (index(v, ": ") || v ~ /:$/ || v ~ / #/)) print f ": " $0
    }' "$f"
done)
[[ -z $fmbad ]] && ok_ "aucun scalaire YAML nu avec « : » dans un en-tête" || ko_ "scalaire YAML nu avec « : »" "$(printf '%s' "$fmbad" | head -3)"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  fmparse=$(python3 - "$ROOT" <<'PY'
import glob, sys, yaml
root = sys.argv[1]
for d in ("global", "extras", "templates"):
    for f in glob.glob(f"{root}/{d}/**/*.md", recursive=True):
        s = open(f, encoding="utf-8").read()
        if not s.startswith("---\n"):
            continue
        end = s.find("\n---", 4)
        try:
            yaml.safe_load(s[4:end])
        except Exception as e:
            print(f, str(e).splitlines()[0])
PY
)
  [[ -z $fmparse ]] && ok_ "en-têtes YAML lus par un parseur strict" || ko_ "en-tête YAML invalide" "$(printf '%s' "$fmparse" | head -3)"
fi
kh=$(mktemp -d); mkdir -p "$kh/global/agents" "$kh/global/skills"
( # shellcheck disable=SC1090
  source <(sed -n '/^fm_get()/,/^}/p; /^yaml_q()/,/^}/p' "$ROOT/scripts/kit.sh")
  printf -- '---\nname: t\ndescription: %s\n---\n' "$(yaml_q 'Fait x : y, "z" et \w')" >"$kh/t.md"
  [[ $(fm_get "$kh/t.md" description) == 'Fait x : y, "z" et \w' ]] ) \
  && ok_ "yaml_q puis fm_get rendent la description d'origine" || ko_ "yaml_q / fm_get : aller-retour faux"
rm -rf "$kh"

# ---------------------------------------------------------------------------
section "dépôt du kit"
[[ $(repo_state) == "$REPO_STATE0" ]] && ok_ "aucune écriture dans le dépôt du kit pendant les tests" || ko_ "le dépôt du kit a été modifié pendant les tests" "$(git -C "$ROOT" status --porcelain | head -5)"

# ---------------------------------------------------------------------------
echo
echo "$pass passed, $fail failed"
HOME=$REAL_HOME
((fail == 0))
