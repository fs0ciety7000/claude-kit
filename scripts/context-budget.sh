#!/usr/bin/env bash
# context-budget.sh — measures what the harness puts in Claude Code's context, from the repository tree (never from
# ~/.claude): words and characters of each always-loaded item, so that v1 and v2 can be compared and budgets enforced.
#
#   scripts/context-budget.sh                 readable table
#   scripts/context-budget.sh --json          machine-readable output (stable keys)
#   scripts/context-budget.sh --budget        compares against scripts/context-budgets.tsv; warnings only, exit code
#                                             non-zero on an overrun only when BUDGET_ENFORCE=1
#   --root DIR                                measure another tree with the same layout (tests, a v1 checkout)
#   --budgets FILE                            budgets file (default: <root>/scripts/context-budgets.tsv)
#
# Measured (words = wc -w, chars = wc -m):
#   - global/CLAUDE.md and the files it imports with @path;
#   - frontmatter `description` of every agent (global/agents), skill (global/skills/*/SKILL.md: kit sync links each
#     folder of global/skills into ~/.claude/skills; vendor/superpowers holds docs only) and command (global/commands);
#   - SessionStart hooks: those of global/settings.json and of templates/project/.claude/settings.json, run in a
#     disposable HOME and project (sample docs/memory files filled past the hook cap), stdout size only;
#   - the project template CLAUDE.md + AGENTS.md (+ imports): what a new project loads;
#   - the /new-project path: command file, skills registry, team-builder, Superpowers skills it chains to;
#   - hook processes per tool call (PreToolUse + PostToolUse commands whose matcher matches the tool).
#
# Safe: the real HOME is never touched, the hooks run with a scrubbed environment (env -i), autoupdate and dockerd
# disabled, and curl pointed at a closed loopback proxy so nothing leaves the machine. A hook that would need the
# network is measured as 0 and the note says so. Needs jq. Compatible bash 3.2 (macOS). Prints counts only.
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
ROOT=$(cd "$(dirname "$SELF")/.." && pwd)
JSON=0 BUDGET=0 BUDGETS="" TAB=$(printf '\t')

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --budget) BUDGET=1 ;;
    --root) shift; [ -n "${1:-}" ] && [ -d "$1" ] || { echo "--root : dossier introuvable" >&2; exit 2; }; ROOT=$(cd "$1" && pwd) ;;
    --budgets) shift; BUDGETS=${1:-} ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { echo "jq requis" >&2; exit 1; }
[ -n "$BUDGETS" ] || BUDGETS="$ROOT/scripts/context-budgets.tsv"

# One UTF-8 locale for wc (characters, not bytes) on Linux and macOS.
UTF8=""
for l in C.UTF-8 en_US.UTF-8 UTF-8 en_GB.UTF-8; do
  if [ "$(printf 'é' | LC_ALL=$l wc -m 2>/dev/null | tr -d ' ')" = 1 ]; then UTF8=$l; break; fi
done
export LC_ALL=${UTF8:-C}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
METR="$TMP/metrics"    # key<TAB>number
DET="$TMP/detail.json" # details that are not plain numbers
: >"$METR"
echo '{}' >"$DET"
: >"$TMP/seen"

m() { printf '%s\t%s\n' "$1" "$2" >>"$METR"; }                              # m key value
g() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$METR" | head -n1; }         # g key
det() { jq -c --argjson x "$1" '. * $x' "$DET" >"$DET.new" && mv "$DET.new" "$DET"; } # det '{"a":{"b":1}}'

words_of() { wc -w <"$1" | tr -d ' '; }
chars_of() { wc -m <"$1" | tr -d ' '; }
str_words() { printf '%s' "$1" | wc -w | tr -d ' '; }
str_chars() { printf '%s' "$1" | wc -m | tr -d ' '; }

# Files imported with @path (not inside code fences or code spans), recursively, each file once, depth <= 5.
# @~/.claude/x resolves to <root>/global/x (that is how kit sync links it).
imports() { # file [depth] : prints the file, then its imports
  local f=$1 d=${2:-0} tok p dir
  grep -qxF "$f" "$TMP/seen" 2>/dev/null && return 0
  echo "$f" >>"$TMP/seen"
  echo "$f"
  [ "$d" -ge 5 ] && return 0
  dir=$(dirname "$f")
  for tok in $(awk '/^```/ {f = !f; next} !f' "$f" | sed 's/`[^`]*`//g' | grep -o '@[A-Za-z0-9_./~-]*' | sort -u); do
    p=${tok#@}
    # shellcheck disable=SC2088
    case "$p" in
      '~/.claude/'*) p="$ROOT/global/${p#'~/.claude/'}" ;;
      /*|'~'*) continue ;;
      *) p="$dir/$p" ;;
    esac
    [ -f "$p" ] && imports "$p" $((d + 1))
  done
}

# Sum words and chars of the files given on stdin (one path per line) -> "words chars count"
sum_files() {
  local f w=0 c=0 k=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    w=$((w + $(words_of "$f"))); c=$((c + $(chars_of "$f"))); k=$((k + 1))
  done
  echo "$w $c $k"
}

# Frontmatter `description` (single line, quoted, or folded/literal block) of a markdown file.
desc_of() {
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[ \t]*$/ { exit }
    cap && /^[ \t]+[^ \t]/ { sub(/^[ \t]+/, ""); val = val " " $0; next }
    cap { exit }
    /^description:/ {
      v = $0; sub(/^description:[ \t]*/, "", v)
      if (v ~ /^[>|][-+]?[ \t]*$/) { cap = 1; val = ""; next }
      val = v; exit
    }
    END {
      sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val)
      if (val ~ /^".*"$/ || val ~ /^'"'"'.*'"'"'$/) val = substr(val, 2, length(val) - 2)
      gsub(/\\"/, "\"", val)
      print val
    }' "$1"
}

# ---------------------------------------------------------------- 1. global CLAUDE.md (+ imports)
if [ -f "$ROOT/global/CLAUDE.md" ]; then
  # shellcheck disable=SC2046
  set -- $(imports "$ROOT/global/CLAUDE.md" | sum_files)
  m global_claude_md.words "$1"; m global_claude_md.chars "$2"; m global_claude_md.files "$3"
else
  m global_claude_md.words 0; m global_claude_md.chars 0; m global_claude_md.files 0
fi

# ---------------------------------------------------------------- 2. descriptions
describe() { # kind  (files on stdin) : fills metrics <kind>_descriptions.* and the top 5
  local kind=$1 f name d w c
  : >"$TMP/desc.$kind"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$kind" in
      skill) name=$(basename "$(dirname "$f")") ;;
      *) name=$(basename "$f" .md) ;;
    esac
    d=$(desc_of "$f")
    w=$(str_words "$d"); c=$(str_chars "$d")
    printf '%s\t%s\t%s\n' "$w" "$c" "$name" >>"$TMP/desc.$kind"
  done
  # shellcheck disable=SC2046
  set -- $(awk -F'\t' '{w += $1; c += $2; k++} END {print w + 0, c + 0, k + 0}' "$TMP/desc.$kind")
  m "${kind}_descriptions.words" "$1"; m "${kind}_descriptions.chars" "$2"; m "${kind}_descriptions.count" "$3"
  det "$(sort -t "$TAB" -k1,1nr -k3,3 "$TMP/desc.$kind" | head -n 5 |
    jq -Rn --arg k "${kind}_descriptions" '{($k): {top: [inputs | split("\t") | {name: .[2], words: (.[0] | tonumber), chars: (.[1] | tonumber)}]}}')"
}
ls "$ROOT"/global/agents/*.md 2>/dev/null | describe agent
ls "$ROOT"/global/skills/*/SKILL.md 2>/dev/null | describe skill
ls "$ROOT"/global/commands/*.md 2>/dev/null | describe command
m skill_command_descriptions.words $(($(g skill_descriptions.words) + $(g command_descriptions.words)))
m skill_command_descriptions.chars $(($(g skill_descriptions.chars) + $(g command_descriptions.chars)))
m skill_command_descriptions.count $(($(g skill_descriptions.count) + $(g command_descriptions.count)))

# ---------------------------------------------------------------- 3. SessionStart hooks (disposable HOME)
SB="$TMP/sandbox"
H="$SB/home" P="$SB/project"
mkdir -p "$H/.config/claude-kit/hooks" "$H/.claude" "$P/docs/memory"
if [ -d "$ROOT/scripts/hooks" ]; then
  for f in "$ROOT"/scripts/hooks/*.sh; do [ -f "$f" ] && ln -sf "$f" "$H/.config/claude-kit/hooks/$(basename "$f")"; done
fi
SID="00000000-0000-4000-8000-000000000000"
INPUT="{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$SID\",\"cwd\":\"$P\"}"

timeout_cmd() { # seconds cmd... (GNU timeout, gtimeout, or none)
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else "$@"; fi
}

# Runs one hook command string as Claude Code would at startup; prints the context it adds (stdout, or the
# additionalContext of a JSON output). Scrubbed environment; network switches off (see header).
run_start_hook() { # command
  local out ctx
  out=$(cd "$P" && timeout_cmd 15 env -i PATH="$PATH" HOME="$H" LC_ALL="$LC_ALL" TMPDIR="$SB" \
    CLAUDE_PROJECT_DIR="$P" CLAUDE_CODE_REMOTE= KIT_AUTOUPDATE=0 KIT_DOCKERD=0 \
    https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY= \
    bash -c "$1" <<<"$INPUT" 2>/dev/null) || true
  ctx=$(printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ctx=$out
  printf '%s' "$ctx"
}

hook_note() { # hook basename
  case "$1" in
    kit-autoupdate.sh) echo "network (git fetch): measured with KIT_AUTOUPDATE=0, i.e. 0; empty when the kit is up to date, one line after an update" ;;
    kit-dockerd.sh) echo "cloud sessions only: 0 on a local session" ;;
    *) echo "" ;;
  esac
}

kit_w=0 kit_c=0 kit_n=0
: >"$TMP/hooks.tsv"
if [ -f "$ROOT/global/settings.json" ]; then
  jq -r '(.hooks.SessionStart // [])[] | . as $e
         | select($e.matcher == null or $e.matcher == "" or $e.matcher == "*" or ("startup" | test("^(" + $e.matcher + ")$")))
         | $e.hooks[]? | select(.type == "command") | .command' "$ROOT/global/settings.json" >"$TMP/kit-start.cmds" 2>/dev/null || : >"$TMP/kit-start.cmds"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    out=$(run_start_hook "$cmd")
    hn=$(basename "$(printf '%s' "$cmd" | awk '{print $1}')")
    w=$(str_words "$out"); c=$(str_chars "$out")
    kit_w=$((kit_w + w)); kit_c=$((kit_c + c)); kit_n=$((kit_n + 1))
    printf '%s\t%s\t%s\t%s\n' "$hn" "$w" "$c" "$(hook_note "$hn")" >>"$TMP/hooks.tsv"
  done <"$TMP/kit-start.cmds"
fi
m sessionstart_kit.words "$kit_w"; m sessionstart_kit.chars "$kit_c"; m sessionstart_kit.hooks "$kit_n"
det "$(jq -Rn '{sessionstart_kit: {detail: [inputs | split("\t") | {name: .[0], words: (.[1] | tonumber), chars: (.[2] | tonumber), note: .[3]}]}}' <"$TMP/hooks.tsv")"

# Project template hook, with docs/memory/*.md filled past any cap (5000 ASCII chars each), then with the fresh template.
proj_hook="$ROOT/templates/project/.claude/settings.json"
pc=0 pw=0 fc=0 fw=0
if [ -f "$proj_hook" ]; then
  jq -r '(.hooks.SessionStart // [])[] | .hooks[]? | select(.type == "command") | .command' "$proj_hook" >"$TMP/proj-start.cmds" 2>/dev/null || : >"$TMP/proj-start.cmds"
  fill() { # file : 5000 ASCII chars of plain prose
    awk 'BEGIN {for (i = 0; length(s) < 5000; i++) s = s "Fait : lot " i " termine, tests verts, prochaine etape documentee. "; print substr(s, 1, 4999)}' >"$1"
  }
  # fresh template
  rm -rf "$P/docs"; mkdir -p "$P/docs"
  [ -d "$ROOT/templates/project/docs/memory" ] && cp -R "$ROOT/templates/project/docs/memory" "$P/docs/memory" || mkdir -p "$P/docs/memory"
  fresh=""
  while IFS= read -r cmd; do [ -n "$cmd" ] && fresh="$fresh$(run_start_hook "$cmd")"; done <"$TMP/proj-start.cmds"
  fc=$(str_chars "$fresh"); fw=$(str_words "$fresh")
  # realistic maximum
  for f in handoff state decisions stack; do fill "$P/docs/memory/$f.md"; done
  fill "$P/docs/plan.md"
  full=""
  while IFS= read -r cmd; do [ -n "$cmd" ] && full="$full$(run_start_hook "$cmd")"; done <"$TMP/proj-start.cmds"
  pc=$(str_chars "$full"); pw=$(str_words "$full")
fi
m project_sessionstart.chars "$pc"; m project_sessionstart.words "$pw"
m project_sessionstart.fresh_chars "$fc"; m project_sessionstart.fresh_words "$fw"

# ---------------------------------------------------------------- 4. project template (what a new project loads)
: >"$TMP/seen"
tpl_files=""
for f in "$ROOT/templates/project/CLAUDE.md" "$ROOT/templates/project/AGENTS.md"; do
  [ -f "$f" ] && tpl_files="$tpl_files$(imports "$f")
"
done
# shellcheck disable=SC2046
set -- $(printf '%s' "$tpl_files" | sed '/^$/d' | sum_files)
m project_template.words "$1"; m project_template.chars "$2"; m project_template.files "$3"

# ---------------------------------------------------------------- 5. /new-project path (on demand)
one() { # key file : metrics <key>.words/.chars (0 when the file is absent)
  if [ -f "$2" ]; then m "$1.words" "$(words_of "$2")"; m "$1.chars" "$(chars_of "$2")"
  else m "$1.words" 0; m "$1.chars" 0; fi
}
one new_project_command "$ROOT/global/commands/new-project.md"
one skills_registry "$ROOT/global/skills-registry.md"
one team_builder "$ROOT/global/skills/team-builder/SKILL.md"
# Superpowers on the path: brainstorming (phase 1, vague idea) and writing-plans (phase 3), the two Superpowers skills
# the kit keeps (the nine others were removed in v2). SKILL.md only: the companion files are read on demand. A skill
# that is not in global/skills counts for nothing.
PATH_SKILLS="brainstorming writing-plans"
sp_w=0 sp_c=0 sp_n=0
: >"$TMP/sp.tsv"
for s in $PATH_SKILLS; do
  f="$ROOT/global/skills/$s/SKILL.md"
  [ -f "$f" ] || continue
  w=$(words_of "$f"); c=$(chars_of "$f")
  sp_w=$((sp_w + w)); sp_c=$((sp_c + c)); sp_n=$((sp_n + 1))
  printf '%s\t%s\t%s\n' "$s" "$w" "$c" >>"$TMP/sp.tsv"
done
m superpowers_path.words "$sp_w"; m superpowers_path.chars "$sp_c"; m superpowers_path.skills "$sp_n"
det "$(jq -Rn '{superpowers_path: {detail: [inputs | split("\t") | {name: .[0], words: (.[1] | tonumber), chars: (.[2] | tonumber)}]}}' <"$TMP/sp.tsv")"
m new_project_path.words $(($(g new_project_command.words) + $(g skills_registry.words) + $(g team_builder.words) + sp_w))
m new_project_path.chars $(($(g new_project_command.chars) + $(g skills_registry.chars) + $(g team_builder.chars) + sp_c))

# ---------------------------------------------------------------- 6. hook processes per tool call
TOOLS="Bash Read Edit Write MultiEdit NotebookEdit Grep Glob Task WebFetch mcp__server__tool"
if [ -f "$ROOT/global/settings.json" ]; then
  for t in $TOOLS; do
    pre=$(jq -r --arg t "$t" '[(.hooks.PreToolUse // [])[] | . as $e
        | select($e.matcher == null or $e.matcher == "" or $e.matcher == "*" or ($t | test("^(" + $e.matcher + ")$")))
        | $e.hooks[]? | select(.type == "command")] | length' "$ROOT/global/settings.json" 2>/dev/null || echo 0)
    post=$(jq -r --arg t "$t" '[(.hooks.PostToolUse // [])[] | . as $e
        | select($e.matcher == null or $e.matcher == "" or $e.matcher == "*" or ($t | test("^(" + $e.matcher + ")$")))
        | $e.hooks[]? | select(.type == "command")] | length' "$ROOT/global/settings.json" 2>/dev/null || echo 0)
    key=$t; [ "$t" = mcp__server__tool ] && key=mcp
    m "hooks_per_tool_call.$key" $((pre + post))
  done
else
  for t in $TOOLS; do key=$t; [ "$t" = mcp__server__tool ] && key=mcp; m "hooks_per_tool_call.$key" 0; done
fi

# ---------------------------------------------------------------- 7. total loaded at startup
m startup_total.words $(($(g global_claude_md.words) + $(g agent_descriptions.words) + $(g skill_descriptions.words) \
  + $(g command_descriptions.words) + $(g sessionstart_kit.words) + $(g project_template.words) + $(g project_sessionstart.words)))
m startup_total.chars $(($(g global_claude_md.chars) + $(g agent_descriptions.chars) + $(g skill_descriptions.chars) \
  + $(g command_descriptions.chars) + $(g sessionstart_kit.chars) + $(g project_template.chars) + $(g project_sessionstart.chars)))

# ---------------------------------------------------------------- budgets
BUD="$TMP/budgets.tsv" # key<TAB>value<TAB>max<TAB>status
: >"$BUD"
over=0
if [ "$BUDGET" = 1 ]; then
  if [ ! -f "$BUDGETS" ]; then echo "fichier de budgets introuvable : $BUDGETS" >&2; exit 2; fi
  while IFS="$TAB" read -r key max _; do
    case "${key:-}" in ''|'#'*) continue ;; esac
    case "$max" in ''|*[!0-9]*) echo "budget invalide pour $key : $max" >&2; exit 2 ;; esac
    v=$(g "$key")
    if [ -z "$v" ]; then st=unknown; v=""
    elif [ "$v" -gt "$max" ]; then st=over; over=$((over + 1))
    else st=ok; fi
    printf '%s\t%s\t%s\t%s\n' "$key" "$v" "$max" "$st" >>"$BUD"
  done <"$BUDGETS"
fi

# ---------------------------------------------------------------- output
if [ "$JSON" = 1 ]; then
  jq -Rn '[inputs | split("\t")] | reduce .[] as $r ({}; setpath(($r[0] | split(".")); ($r[1] | tonumber)))' <"$METR" |
    jq --slurpfile d "$DET" --rawfile b "$BUD" --argjson budget "$BUDGET" --argjson over "$over" '
      . * $d[0]
      | {version: 1} + .
      | if $budget == 1 then . + {budget: {over: $over,
          items: [$b | split("\n")[] | select(length > 0) | split("\t")
                  | {item: .[0], value: (if .[1] == "" then null else (.[1] | tonumber) end), max: (.[2] | tonumber), status: .[3]}]}} else . end'
else
  row() { printf '  %-44s %8s %9s\n' "$1" "$2" "$3"; } # label words chars
  if [ "$BUDGET" = 0 ]; then
    printf 'Contexte du harness (arbre : %s)\n' "$(basename "$ROOT")"
    [ -z "$UTF8" ] && echo "  (aucune locale UTF-8 : caractères comptés en octets)"
    printf '\n  %-44s %8s %9s\n' "Toujours chargé" "mots" "caractères"
    row "CLAUDE.md global ($(g global_claude_md.files) fichier(s))" "$(g global_claude_md.words)" "$(g global_claude_md.chars)"
    row "descriptions agents ($(g agent_descriptions.count))" "$(g agent_descriptions.words)" "$(g agent_descriptions.chars)"
    row "descriptions skills ($(g skill_descriptions.count))" "$(g skill_descriptions.words)" "$(g skill_descriptions.chars)"
    row "descriptions commandes ($(g command_descriptions.count))" "$(g command_descriptions.words)" "$(g command_descriptions.chars)"
    row "SessionStart du kit ($(g sessionstart_kit.hooks) hooks)" "$(g sessionstart_kit.words)" "$(g sessionstart_kit.chars)"
    row "gabarit projet CLAUDE.md + AGENTS.md" "$(g project_template.words)" "$(g project_template.chars)"
    row "SessionStart du projet (mémoire pleine)" "$(g project_sessionstart.words)" "$(g project_sessionstart.chars)"
    row "TOTAL au démarrage" "$(g startup_total.words)" "$(g startup_total.chars)"
    printf '  (SessionStart d'"'"'un projet neuf : %s mots, %s caractères, non compté dans le total)\n' "$(g project_sessionstart.fresh_words)" "$(g project_sessionstart.fresh_chars)"
    for k in agent skill command; do
      printf '\n  5 plus longues descriptions (%s) :\n' "$k"
      sort -t "$TAB" -k1,1nr -k3,3 "$TMP/desc.$k" | head -n 5 | while IFS="$TAB" read -r w c nm; do printf '    %-40s %4s mots %5s car.\n' "$nm" "$w" "$c"; done
    done
    printf '\n  SessionStart du kit, hook par hook :\n'
    while IFS="$TAB" read -r hn w c note; do printf '    %-20s %5s mots %6s car.  %s\n' "$hn" "$w" "$c" "$note"; done <"$TMP/hooks.tsv"
    printf '\n  %-44s %8s %9s\n' "Sur demande : parcours /new-project" "mots" "caractères"
    row "commande /new-project" "$(g new_project_command.words)" "$(g new_project_command.chars)"
    row "registre des skills" "$(g skills_registry.words)" "$(g skills_registry.chars)"
    row "skill team-builder" "$(g team_builder.words)" "$(g team_builder.chars)"
    while IFS="$TAB" read -r s w c; do row "Superpowers : $s" "$w" "$c"; done <"$TMP/sp.tsv"
    row "Superpowers sur le parcours ($(g superpowers_path.skills))" "$(g superpowers_path.words)" "$(g superpowers_path.chars)"
    row "TOTAL du parcours" "$(g new_project_path.words)" "$(g new_project_path.chars)"
    printf '\n  %-44s %8s\n' "Processus de hook par appel d'outil" "hooks"
    for t in Bash Read Edit Write MultiEdit NotebookEdit Grep Glob Task WebFetch mcp; do
      printf '  %-44s %8s\n' "$t" "$(g "hooks_per_tool_call.$t")"
    done
  else
    printf 'Budgets (%s)\n' "$(basename "$BUDGETS")"
    printf '  %-34s %8s %8s  %s\n' "item" "valeur" "max" "état"
    while IFS="$TAB" read -r key v max st; do
      case "$st" in over) label="DÉPASSÉ" ;; unknown) label="inconnu" ;; *) label="ok" ;; esac
      printf '  %-34s %8s %8s  %s\n' "$key" "${v:--}" "$max" "$label"
    done <"$BUD"
    if [ "$over" -gt 0 ]; then
      printf '  %s budget(s) dépassé(s)%s\n' "$over" "$([ "${BUDGET_ENFORCE:-0}" = 1 ] || echo " (avertissement : BUDGET_ENFORCE=1 pour échouer)")" >&2
    else
      echo "  tous les budgets sont tenus"
    fi
  fi
fi

if [ "$BUDGET" = 1 ] && [ "$over" -gt 0 ] && [ "${BUDGET_ENFORCE:-0}" = 1 ]; then exit 1; fi
exit 0
