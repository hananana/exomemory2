#!/bin/bash
# exomemory2 post-WebFetch hook
#
# Fires on PostToolUse[WebFetch]. Appends the fetched URL to a per-session
# queue file under <vault>/.clip-queue/<session-id>.txt. The actual /wiki-clip
# processing runs at SessionEnd (see capture.sh) — this hook is intentionally
# feather-light so it never slows down the interactive session.
#
# Requires: jq
# Behavior: exits silently (0) on any non-fatal condition (vault unset,
# URL blocked, queue cap hit, etc.) so the user's session never stalls.

set -eo pipefail

# ---------------------------------------------------------------------------
# Resolve vault (same policy as capture.sh). No ancestor search in hooks.
# ---------------------------------------------------------------------------
VAULT="${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
if [ -z "$VAULT" ]; then
  exit 0
fi
if [ ! -f "$VAULT/WIKI.md" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Require jq for hook input parsing.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Load config (only the INT-valued keys we need).
# ---------------------------------------------------------------------------
AUTO_CLIP=1
AUTO_CLIP_MAX_PER_SESSION=20
config="$VAULT/.exomemory-config"
if [ -f "$config" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*|"") continue ;;
    esac
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=([0-9]+)$ ]]; then
      case "${BASH_REMATCH[1]}" in
        AUTO_CLIP) AUTO_CLIP="${BASH_REMATCH[2]}" ;;
        AUTO_CLIP_MAX_PER_SESSION) AUTO_CLIP_MAX_PER_SESSION="${BASH_REMATCH[2]}" ;;
      esac
    fi
  done < "$config"
fi

if [ "$AUTO_CLIP" != "1" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse hook input from stdin.
# Expected shape (Claude Code PostToolUse):
#   {
#     "session_id": "...",
#     "tool_name": "WebFetch",
#     "tool_input":  { "url": "...", ... },
#     "tool_response": { ... }  or  "string"  or  { "error": ... }
#   }
# ---------------------------------------------------------------------------
input="$(cat)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // .hook_event_name // empty')"
# Matcher in hooks.json already scopes us to WebFetch; double-check anyway.
case "$tool_name" in
  WebFetch|webfetch|web_fetch) : ;;
  *) exit 0 ;;
esac

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
url="$(printf '%s' "$input" | jq -r '.tool_input.url // empty')"

[ -z "$session_id" ] && exit 0
[ -z "$url" ] && exit 0

# Bail if the tool call itself errored. Several possible shapes:
#   tool_response is a string starting with "Error" / "FAILED"
#   tool_response.is_error == true
#   tool_response.error set
tool_err="$(printf '%s' "$input" | jq -r '
  (.tool_response // empty) as $r
  | if ($r | type) == "string" then
      (if ($r | test("^(Error|FAILED|error):"; "i")) then "err" else "" end)
    elif ($r | type) == "object" then
      (if ($r.is_error // false) or ($r.error // false) then "err" else "" end)
    else "" end
')"
[ "$tool_err" = "err" ] && exit 0

# ---------------------------------------------------------------------------
# URL filters.
# ---------------------------------------------------------------------------
# Accept only http(s)
case "$url" in
  http://*|https://*) : ;;
  *) exit 0 ;;
esac

# Drop localhost / loopback / private IPs / .internal TLDs.
host_raw="${url#*://}"
host_raw="${host_raw%%/*}"
host_raw="${host_raw%%:*}"       # strip :port
host_raw="${host_raw%%\?*}"       # defensive
host_raw="$(printf '%s' "$host_raw" | tr '[:upper:]' '[:lower:]')"

case "$host_raw" in
  localhost|127.*|10.*|192.168.*|169.254.*) exit 0 ;;
  172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)   exit 0 ;;
  *.internal|*.local|*.localhost)           exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Append to queue (atomic; dedup is handled at SessionEnd / by /wiki-clip).
# ---------------------------------------------------------------------------
queue_dir="$VAULT/.clip-queue"
queue="$queue_dir/$session_id.txt"
mkdir -p "$queue_dir"

# Cap per-session queue size to avoid runaway auto-capture (e.g. a Claude
# session that WebFetches 200 URLs). Count current lines and bail if we are
# at or above the limit.
if [ -f "$queue" ]; then
  cur=$(wc -l < "$queue" | tr -d ' ')
  if [ "$cur" -ge "$AUTO_CLIP_MAX_PER_SESSION" ]; then
    exit 0
  fi
fi

# Append URL atomically. Strip CR/LF to keep one URL per line.
safe_url="$(printf '%s' "$url" | tr -d '\r\n\0')"
printf '%s\n' "$safe_url" >> "$queue"

exit 0
