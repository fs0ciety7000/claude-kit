#!/usr/bin/env bash
# build-index.sh — builds global/collections-index.json from the collections listed in global/agent-sources.txt.
#
# Each source is shallow-cloned (no GitHub API: works locally, in cloud sessions and in CI), then every Markdown file
# whose YAML header has `name` and `description` is indexed:
#   - SKILL.md            -> kind "skill"  (install: kit add-skill <owner/repo> --skill <name>)
#   - any other *.md      -> kind "agent"  (install: kit add-agent gh:<owner/repo>/<path>)
# Files under commands/, hooks/, templates/, docs/ and examples/ are skipped. Descriptions are third-party text:
# they are cut to 300 characters and must be treated as data, never as instructions.
#
# Usage: scripts/build-index.sh [--out file] [--keep]
set -euo pipefail
KIT_HOME=${KIT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}
SOURCES="$KIT_HOME/global/agent-sources.txt"
OUT="$KIT_HOME/global/collections-index.json"
KEEP=0
while (($#)); do
  case $1 in
    --out) OUT=${2:?}; shift ;;
    --keep) KEEP=1 ;;
    *) echo "usage: $0 [--out file] [--keep]" >&2; exit 1 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
WORK=$(mktemp -d)
((KEEP)) || trap 'rm -rf "$WORK"' EXIT

# Prints the YAML header of a Markdown file (between the first two --- lines), at most 60 lines.
header() { awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 {print} NR>61 {exit}' "$1"; }
# Value of a top-level key in a header (quotes removed). A block scalar (`key: |` or `key: >`) is folded into one line.
field() {
  awk -v k="$1" '
    found && /^[^[:space:]]/ { exit }
    found { sub(/^[[:space:]]+/, ""); v = v (v ? " " : "") $0; next }
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2); sub(/^[[:space:]]+/, "", v)
      if (v ~ /^[|>][-+]?$/) { v = ""; found = 1; next }
      print v; exit
    }
    END { if (found) print v }' <<<"$2" | head -1 | sed -E 's/^["'"'"']//; s/["'"'"']$//'
}
# Category: the closest folder that is not a generic container name (plugins/x/agents/y.md -> x).
category() {
  local d=$1 b
  while [[ $d != . && $d != / ]]; do
    b=$(basename "$d")
    case $b in agents|skills|plugins|categories|components|cli-tool|src|.claude) ;; *) echo "$b"; return ;; esac
    d=$(dirname "$d")
  done
  echo ""
}

entries="$WORK/entries.jsonl"
: >"$entries"
: >"$WORK/sources.jsonl"
while read -r repo prefix _; do
  [[ -z ${repo:-} || $repo == \#* ]] && continue
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "skip invalid source: $repo" >&2; continue; }
  dir="$WORK/${repo//\//__}"
  if ! git clone -q --depth 1 "https://github.com/$repo" "$dir" 2>/dev/null; then
    echo "clone failed: $repo" >&2
    continue
  fi
  commit=$(git -C "$dir" log -1 --format=%cs 2>/dev/null || echo "")
  license=""
  for l in LICENSE LICENSE.md LICENSE.txt license; do
    [[ -f $dir/$l ]] && { license=$(head -3 "$dir/$l" | tr -s ' \n' ' ' | cut -c1-60); break; }
  done
  # Folders holding a SKILL.md: any other Markdown file below them is a resource of that skill, not an agent.
  skilldirs="$WORK/skilldirs"
  find "$dir" -name SKILL.md -type f -printf '%h\n' | sed "s|^$dir/||" | sort -u >"$skilldirs"
  n=0
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    base=$(basename "$rel")
    case "/$rel" in
      */assets/*|*/references/*|*/rules/*|*/resources/*|*/prompts/*) continue ;;
    esac
    case $base in TEMPLATE.md|template.md|SKILL.*.md) continue ;; esac
    if [[ $base != SKILL.md ]]; then
      d=$(dirname "$rel") inside=0
      while [[ $d != . ]]; do
        grep -qxF "$d" "$skilldirs" && { inside=1; break; }
        d=$(dirname "$d")
      done
      ((inside)) && continue
    fi
    [[ -n ${prefix:-} && $rel != "$prefix"* ]] && continue
    case "/$rel" in
      */commands/*|*/hooks/*|*/templates/*|*/docs/*|*/examples/*|*/.github/*|*/scripts/*|*/integrations/*) continue ;;
      */.codex/*|*/.gemini/*|*/.cursor/*|*/node_modules/*) continue ;;
    esac
    [[ $(head -c 3 "$f") == "---" ]] || continue
    h=$(header "$f")
    name=$(field name "$h")
    desc=$(field description "$h")
    [[ -n $name && -n $desc ]] || continue
    if [[ $(basename "$rel") == SKILL.md ]]; then
      kind=skill
      cat=$(category "$(dirname "$(dirname "$rel")")")
    else
      kind=agent
      cat=$(category "$(dirname "$rel")")
    fi
    jq -nc --arg kind "$kind" --arg source "$repo" --arg path "$rel" --arg name "$name" \
      --arg desc "${desc:0:300}" --arg tools "$(field tools "$h")" --arg model "$(field model "$h")" \
      --arg category "$cat" --arg commit "$commit" '
      {kind: $kind, source: $source, path: $path, name: $name, description: $desc, tools: $tools, model: $model,
       category: $category, updated: $commit,
       install: (if $kind == "skill" then "kit add-skill " + $source + " --skill " + $name
                 else "kit add-agent gh:" + $source + "/" + $path end)}' >>"$entries"
    n=$((n + 1))
  done < <(find "$dir" -name '*.md' -type f -print0)
  jq -nc --arg source "$repo" --arg license "$license" --arg updated "$commit" --argjson count "$n" \
    '{source: $source, license: $license, updated: $updated, count: $count}' >>"$WORK/sources.jsonl"
  echo "$repo: $n entries ($commit)" >&2
  rm -rf "$dir/.git"
done <"$SOURCES"

jq -n --arg built "$(date -u +%Y-%m-%d)" --slurpfile e "$entries" --slurpfile s "$WORK/sources.jsonl" \
  '{built: $built, count: ($e | length), sources: $s,
    entries: ($e | unique_by(.source + "/" + .path) | sort_by(.kind, .source, .name))}' >"$OUT"
echo "index: $(jq .count "$OUT") entries -> ${OUT#"$KIT_HOME"/}" >&2
