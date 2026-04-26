#!/bin/bash
# exomemory2 SessionStart hook
#
# Two responsibilities:
#   1. Synchronously emit `additionalContext` reporting when auto-ingest last
#      ran, so Claude can notice (a) wiki freshness and (b) silent failure of
#      the background ingest pipeline.
#   2. Asynchronously spawn rescue-orphans.sh (v0.8+) to rebuild handovers
#      for transcripts that lost their SessionEnd hook (e.g. tmux kill-pane
#      sent SIGHUP), and then ingest them with threshold bypass.
#
# The rescue runs detached + disowned, so the hook always returns within
# milliseconds (the hook's 5s timeout never blocks on the rescue work).
#
# Behavior: exits silently (0) on any soft failure. Never blocks session
# start.

set -eo pipefail

VAULT="${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
if [ -z "$VAULT" ] || [ ! -f "$VAULT/WIKI.md" ]; then
  exit 0
fi

# Read hook input JSON to learn this session's id (for rescue self-exclusion).
# `cat` returns immediately at EOF; SessionStart hook always provides input.
input="$(cat 2>/dev/null || true)"
SELF_SID=""
if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
  SELF_SID="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

# ---- Spawn rescue in the background (detached + disowned) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESCUE="$SCRIPT_DIR/../scripts/rescue-orphans.sh"
if [ -x "$RESCUE" ]; then
  (
    EXOMEMORY_VAULT="$VAULT" "$RESCUE" \
      --vault "$VAULT" \
      --self-session-id "$SELF_SID" \
      </dev/null >>"$VAULT/.ingest.log" 2>&1
  ) &
  disown
fi

# ---- Synchronous freshness notice ----
LAST_FILE="$VAULT/.last-ingest"
if [ ! -f "$LAST_FILE" ]; then
  exit 0
fi

LAST=$(cat "$LAST_FILE" 2>/dev/null)
case "$LAST" in
  ''|*[!0-9]*) exit 0 ;;
esac

NOW=$(date +%s)
ELAPSED=$((NOW - LAST))

if [ "$ELAPSED" -lt 60 ]; then
  ago="${ELAPSED}s ago"
elif [ "$ELAPSED" -lt 3600 ]; then
  ago="$((ELAPSED / 60))m ago"
elif [ "$ELAPSED" -lt 86400 ]; then
  ago="$((ELAPSED / 3600))h ago"
else
  ago="$((ELAPSED / 86400))d ago"
fi

if timestamp=$(date -r "$LAST" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
  :
else
  timestamp=$(date -d "@$LAST" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$LAST")
fi

context="exomemory2: last auto-ingest at $timestamp ($ago). See $VAULT/wiki/log.md for details."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$context" '{additionalContext: $ctx}'
else
  printf '{"additionalContext": "%s"}\n' "$context"
fi

exit 0
