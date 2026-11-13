#!/usr/bin/env bash
# measure-session.sh — tokens, duration, validations and subagents of one Claude Code session, read from its local
# transcript (~/.claude/projects/<project>/<session>.jsonl and <session>/subagents/*.jsonl). Read only.
#
#   scripts/measure-session.sh                 latest session of the current directory's project
#   scripts/measure-session.sh <session-id>    a given session (searched in every project)
#   scripts/measure-session.sh <file.jsonl>    a given transcript
#   --json                                     machine-readable output (to compare v1 and v2 runs)
#
# Needs jq. Compatible bash 3.2 (macOS). Prints counts only: no prompt, file content or secret is shown.
set -euo pipefail

JSON=0 ARG=""
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) ARG="$a" ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "jq requis" >&2; exit 1; }
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"

if [ -n "$ARG" ] && [ -f "$ARG" ]; then MAIN="$ARG"
elif [ -n "$ARG" ]; then
  MAIN="$(ls "$PROJECTS"/*/"$ARG".jsonl 2>/dev/null | head -n1 || true)"
else
  proj="$PROJECTS/$(pwd | sed 's#[/.]#-#g')"
  MAIN="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -n1 || true)"
fi
[ -n "${MAIN:-}" ] && [ -f "$MAIN" ] || { echo "transcript introuvable (${ARG:-dossier courant})" >&2; exit 1; }
SUBDIR="${MAIN%.jsonl}/subagents"

# One file -> one JSON object of totals. Streamed chunks repeat the same message.id: count each message once.
summarize() {
  jq -s '
    [ .[] | select(.type=="assistant" and .message.id != null) ] as $a
    | ($a | group_by(.message.id) | map(.[-1])) as $msgs
    | [ .[] | .timestamp | select(. != null) ] as $ts
    | {
        messages:     ($msgs | length),
        input:        ($msgs | map(.message.usage.input_tokens // 0) | add // 0),
        cache_write:  ($msgs | map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
        cache_read:   ($msgs | map(.message.usage.cache_read_input_tokens // 0) | add // 0),
        output:       ($msgs | map(.message.usage.output_tokens // 0) | add // 0),
        models:       ($msgs | map(.message.model // "?") | unique),
        tools:        ($msgs | map(.message.content[]? | select(.type=="tool_use") | .name)),
        user_prompts: ([ .[] | select(.type=="user" and (.message.content | type) == "string") ] | length),
        first: ($ts | min), last: ($ts | max)
      }' "$1"
}

main="$(summarize "$MAIN")"
subs="[]"
if [ -d "$SUBDIR" ]; then
  for f in "$SUBDIR"/*.jsonl; do [ -f "$f" ] || continue; subs="$(jq -c --argjson s "$(summarize "$f")" '. + [$s]' <<<"$subs")"; done
fi

report="$(jq -n --argjson m "$main" --argjson s "$subs" --arg file "$(basename "$MAIN" .jsonl)" '
  def secs($a; $b): if $a and $b then (($b|sub("\\.[0-9]+Z$";"Z")|fromdate) - ($a|sub("\\.[0-9]+Z$";"Z")|fromdate)) else 0 end;
  def tot($k): ($m[$k] + ([$s[][$k]] | add // 0));
  {
    session: $file,
    duration_min: ((secs($m.first; $m.last) / 60) | floor),
    tokens: { input: tot("input"), cache_write: tot("cache_write"), cache_read: tot("cache_read"), output: tot("output"),
              total: (tot("input") + tot("cache_write") + tot("cache_read") + tot("output")) },
    main_messages: $m.messages, subagents: ($s | length), subagent_messages: ([$s[].messages] | add // 0),
    user_prompts: $m.user_prompts,
    validations: ([$m.tools[] | select(test("AskUserQuestion|ExitPlanMode"))] | length),
    agents_spawned: ([$m.tools[] | select(. == "Agent" or . == "Task")] | length),
    models: (($m.models + [$s[].models[]]) | unique),
    top_tools: ($m.tools | group_by(.) | map({(.[0]): length}) | add // {})
  }')"

if [ "$JSON" -eq 1 ]; then printf '%s\n' "$report"; exit 0; fi
jq -r '
  "session          : \(.session)",
  "durée            : \(.duration_min) min (premier → dernier événement)",
  "tokens           : total \(.tokens.total)  (entrée \(.tokens.input), cache écrit \(.tokens.cache_write), cache lu \(.tokens.cache_read), sortie \(.tokens.output))",
  "messages         : \(.main_messages) (session) + \(.subagent_messages) (\(.subagents) sous-agents)",
  "messages humains : \(.user_prompts)",
  "validations      : \(.validations) (questions, plans)",
  "agents lancés    : \(.agents_spawned)",
  "modèles          : \(.models | join(", "))"' <<<"$report"
