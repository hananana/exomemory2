#!/bin/bash
# exomemory2 SessionStart hook
#
# Emits a tiny `additionalContext` line reporting when auto-ingest last ran,
# so Claude can notice (a) wiki freshness and (b) silent failure of the
# background ingest pipeline. Hidden from the user (additionalContext is
# Claude-only context per Claude Code hook spec).
#
# Behavior: exits silently (0) if the vault is unset, missing, or has no
# .last-ingest record. Never blocks session start.

set -eo pipefail

VAULT="${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
if [ -z "$VAULT" ] || [ ! -f "$VAULT/WIKI.md" ]; then
  exit 0
fi

LAST_FILE="$VAULT/.last-ingest"
if [ ! -f "$LAST_FILE" ]; then
  exit 0
fi

LAST=$(cat "$LAST_FILE" 2>/dev/null)
case "$LAST" in
  ''|*[!0-9]*) exit 0 ;;  # missing or non-integer
esac

NOW=$(date +%s)
ELAPSED=$((NOW - LAST))

# Format elapsed time as a short human-readable string.
if [ "$ELAPSED" -lt 60 ]; then
  ago="${ELAPSED}s ago"
elif [ "$ELAPSED" -lt 3600 ]; then
  ago="$((ELAPSED / 60))m ago"
elif [ "$ELAPSED" -lt 86400 ]; then
  ago="$((ELAPSED / 3600))h ago"
else
  ago="$((ELAPSED / 86400))d ago"
fi

# date -r is BSD/macOS; GNU date uses -d @<epoch>. Try BSD first, fall back.
if timestamp=$(date -r "$LAST" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
  :
else
  timestamp=$(date -d "@$LAST" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$LAST")
fi

context="exomemory2: last auto-ingest at $timestamp ($ago). See $VAULT/wiki/log.md for details."

# Emit JSON for Claude Code SessionStart hook.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$context" '{additionalContext: $ctx}'
else
  # Minimal JSON without jq (safe because $context is plain ASCII).
  printf '{"additionalContext": "%s"}\n' "$context"
fi

exit 0
