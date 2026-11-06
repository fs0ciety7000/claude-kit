#!/usr/bin/env bash
# Hook Claude Code -> dashboard claude-kit (kit.fs0ciety.org).
# Envoie chaque événement (session, prompt, outils, sous-agents, fin de tour) au dashboard.
# Ne bloque jamais Claude : l'envoi part en arrière-plan, toute erreur est ignorée.
#
# Configuration (rien = hook inactif) :
#   KIT_DASH_URL    ou ~/.config/claude-kit/dash.url   (kit dash setup <url>)
#   KIT_DASH_TOKEN  variable d'environnement si présente ; sinon :
#                   - session cloud : jeton injecté par le proxy (network secret de l'hôte du dashboard)
#                   - machine locale : secret global chiffré injecté par `kit secrets run -g`
# Données ajoutées : dépôt, branche, commit, source (cloud/terminal/vps), mémoire du projet
# (.claude/memory/*.md) au début et à la fin de chaque tour, commits faits pendant la session.
# Les valeurs qui ressemblent à des secrets sont masquées avant l'envoi.
# Au SessionStart, le hook écrit aussi le session_id dans le contexte de Claude (outils kit-control).
# kit-emit.sh --headers : en-tête Authorization pour le serveur MCP kit-control (headersHelper).
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/claude-kit
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/claude-kit/sessions

# --- mode interne : POST du fichier $2 vers $3, jeton lu dans l'environnement ---
if [[ ${1:-} == --post ]]; then
  file=$2 url=$3
  if [[ -z ${KIT_DASH_TOKEN:-} ]]; then
    # Session cloud sans variable : le proxy de l'environnement injecte le jeton (network secret).
    curl -sS -o /dev/null --max-time 8 -H 'Content-Type: application/json' \
      --data-binary "@$file" "${url%/}/ingest"
    rm -f "$file"
    exit 0
  fi
  [[ $KIT_DASH_TOKEN != *[\"\\[:space:]]* ]] || exit 0
  # Le jeton passe par stdin (curl -K -), jamais dans les arguments d'un processus.
  printf 'header = "Authorization: Bearer %s"\n' "$KIT_DASH_TOKEN" |
    curl -sS -o /dev/null --max-time 8 -K - -H 'Content-Type: application/json' \
      --data-binary "@$file" "${url%/}/ingest"
  rm -f "$file"
  exit 0
fi

# --- mode headersHelper du serveur MCP kit-control (machine locale, via kit secrets run -g) ---
if [[ ${1:-} == --headers ]]; then
  [[ -n ${KIT_DASH_TOKEN:-} ]] || { echo '{}'; exit 0; }
  jq -cn --arg t "$KIT_DASH_TOKEN" '{Authorization: ("Bearer " + $t)}'
  exit 0
fi

input=$(cat)
url=${KIT_DASH_URL:-$(cat "$CONF/dash.url" 2>/dev/null || true)}
[[ -n $url ]] || exit 0
command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || exit 0

# SessionStart : donne à Claude l'identifiant de session à passer aux outils kit-control
# (seule sortie synchrone du hook ; elle est ajoutée au contexte de la session).
if [[ $(jq -r '.hook_event_name // empty' <<<"$input") == SessionStart ]]; then
  sid=$(jq -r '.session_id // empty' <<<"$input")
  if [[ $sid =~ ^[A-Za-z0-9._-]+$ ]]; then
    jq -cn --arg c "kit-control session_id=$sid — dashboard ${url%/} : passe ce session_id aux outils mcp__kit-control__* (checkpoint, ask, task_*)." \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
  fi
fi

send() {
  local hook sid cwd remote repo branch commit host source memory commits start
  hook=$(jq -r '.hook_event_name // empty' <<<"$input")
  sid=$(jq -r '.session_id // empty' <<<"$input")
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  [[ -n $hook && -n $sid ]] || return 0
  [[ -d $cwd ]] || cwd=$PWD
  [[ $sid =~ ^[A-Za-z0-9._-]+$ ]] || return 0

  remote=$(git -C "$cwd" remote get-url origin 2>/dev/null || true)
  # github.com/owner/repo, git@github.com:owner/repo.git, proxy cloud …/git/owner/repo : garde owner/repo.
  repo=$(sed -E 's#\.git$##; s#/+$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#' <<<"$remote")
  [[ $repo == */* ]] || repo=""
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  commit=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)
  host=$(hostname 2>/dev/null || echo unknown)
  if [[ ${CLAUDE_CODE_REMOTE:-} == true ]]; then source=cloud
  elif [[ -n ${KIT_SOURCE:-} ]]; then source=$KIT_SOURCE
  elif [[ "$(cat "$CONF/profile" 2>/dev/null)" == vps ]]; then source=vps
  else source=terminal; fi

  mkdir -p "$STATE"
  [[ $hook == SessionStart && ! -f $STATE/$sid ]] && date +%s >"$STATE/$sid"

  memory='{}'
  commits='[]'
  case $hook in
    SessionStart | Stop | SessionEnd)
      if [[ -d $cwd/.claude/memory ]]; then
        local f n=0
        for f in "$cwd"/.claude/memory/*.md; do
          [[ -f $f && ! -L $f ]] || continue
          ((n++ < 12)) || break
          memory=$(jq -c --arg k "$(basename "$f")" --rawfile v <(head -c 65536 "$f") '. + {($k): $v}' <<<"$memory")
        done
      fi
      start=$(cat "$STATE/$sid" 2>/dev/null || true)
      if [[ $hook != SessionStart && -n $start && -n $commit ]]; then
        commits=$(git -C "$cwd" log --since="@$start" -n 30 --format='%H%x1f%s%x1f%ct' 2>/dev/null |
          jq -Rnc '[inputs | select(length>0) | split("\u001f") | {sha: .[0], message: .[1], ts: ((.[2]|tonumber)*1000)}]' 2>/dev/null || echo '[]')
      fi
      ;;
  esac
  [[ $hook == SessionEnd ]] && rm -f "$STATE/$sid"
  find "$STATE" -type f -mtime +7 -delete 2>/dev/null

  # Contexte utilisé : usage du dernier message de Claude dans le transcript (vue Live du dashboard).
  # Fenêtre : 1M si le modèle l'indique ou si l'usage dépasse 200k, sinon 200k.
  context='{}'
  case $hook in
    UserPromptSubmit | Stop | SubagentStop | PreCompact)
      local tp
      tp=$(jq -r '.transcript_path // empty' <<<"$input")
      if [[ -n $tp && -f $tp && ! -L $tp ]]; then
        context=$(tail -n 300 "$tp" | jq -sc '
          [ .[] | select(.type == "assistant" and (.message.usage | type) == "object") ] | last // empty
          | (.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) as $used
          | (.message.model // "") as $m
          | {context_tokens: $used, model: $m,
             context_max: (if ($m | test("1m|\\[1m\\]")) or $used > 200000 then 1000000 else 200000 end)}' 2>/dev/null)
        [[ -n $context ]] || context='{}'
      fi
      ;;
  esac

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/kit-emit.XXXXXX") || return 0
  # Masquage côté client (le serveur le refait) ; chaînes tronquées à 6 000 caractères.
  jq -c \
    --arg project "$(basename "${repo:-$cwd}")" --arg repo "$repo" --arg branch "$branch" --arg commit "$commit" \
    --arg host "$host" --arg source "$source" --argjson memory "$memory" --argjson commits "$commits" \
    --argjson context "$context" '
    def redact: if type == "string" then
        (if length > 6000 then .[0:6000] + "…" else . end)
        | gsub("sk-ant-[A-Za-z0-9_-]{10,}"; "[REDACTED]")
        | gsub("sk-[A-Za-z0-9_-]{20,}"; "[REDACTED]")
        | gsub("gh[pousr]_[A-Za-z0-9]{20,}"; "[REDACTED]")
        | gsub("github_pat_[A-Za-z0-9_]{20,}"; "[REDACTED]")
        | gsub("kd_[a-f0-9]{32,}"; "[REDACTED]")
        | gsub("AKIA[0-9A-Z]{16}"; "[REDACTED]")
        | gsub("xox[baprs]-[A-Za-z0-9-]{10,}"; "[REDACTED]")
        | gsub("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"; "[REDACTED]")
        | gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "[REDACTED]")
        | gsub("(?<p>(?i)bearer\\s+)[A-Za-z0-9._~+/-]{16,}=*"; "\(.p)[REDACTED]")
        | gsub("(?<p>(?i)(api[_-]?key|token|secret|password|passwd|pwd|access[_-]?key)[\"'\'']?\\s*[:=]\\s*[\"'\'']?)[^\\s\"'\'',;]{6,}"; "\(.p)[REDACTED]")
      elif type == "object" then map_values(redact)
      elif type == "array" then .[0:200] | map(redact)
      else . end;
    { event: (. | redact),
      meta: ({project: $project, repo: $repo, branch: $branch, commit: $commit, host: $host, source: $source} + $context),
      memory: ($memory | map_values(redact)),
      commits: ($commits | map(.message |= redact)) }' <<<"$input" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

  if [[ -n ${KIT_DASH_TOKEN:-} || ${CLAUDE_CODE_REMOTE:-} == true ]]; then
    "$SELF" --post "$tmp" "$url"
  elif [[ "$(cat "$CONF/profile" 2>/dev/null)" != cloud ]] && command -v kit >/dev/null 2>&1; then
    # Machine locale : le jeton vient du secret global chiffré, injecté dans ce seul processus.
    kit secrets run -g -- "$SELF" --post "$tmp" "$url"
  fi
  rm -f "$tmp"
}

# Détaché : Claude n'attend pas le réseau.
(send) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
