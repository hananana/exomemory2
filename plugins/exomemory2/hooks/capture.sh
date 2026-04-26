#!/bin/bash
# exomemory2 capture hook (PreCompact / SessionEnd)
#
# Reads the Claude Code transcript referenced by the hook input JSON,
# writes/updates a handover file in the active vault, and conditionally
# spawns a background `claude -p` to ingest the wiki.
#
# Heavy lifting is delegated to:
#   lib/handover-build.sh — build_handover()
#   lib/ingest-spawn.sh   — ingest_spawn()
#
# Behavior: exits 0 silently on any soft failure (vault unset, jq missing,
# transcript unreadable, empty session) so that hook fires never block the
# user's session.

set -eo pipefail

VAULT="${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
if [ -z "$VAULT" ]; then
  echo "[exomemory2] EXOMEMORY_VAULT not set, skipping capture" >&2
  exit 0
fi
if [ -z "${EXOMEMORY_VAULT:-}" ] && [ -n "${CLAUDE_MEMORY_VAULT:-}" ]; then
  echo "[exomemory2] CLAUDE_MEMORY_VAULT is deprecated; please use EXOMEMORY_VAULT (will be removed in v0.3)" >&2
fi

if [ ! -f "${VAULT}/WIKI.md" ]; then
  echo "[exomemory2] vault path does not contain WIKI.md: ${VAULT}" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[exomemory2] jq not found in PATH, cannot extract transcript" >&2
  exit 0
fi

input="$(cat)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
trigger="$(printf '%s' "$input" | jq -r '.trigger // .hook_event_name // "unknown"')"

if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
  echo "[exomemory2] transcript_path missing or file not found: $transcript_path" >&2
  exit 0
fi
if [ -z "$session_id" ]; then
  echo "[exomemory2] session_id missing from hook input" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/handover-build.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ingest-spawn.sh"

build_handover "$VAULT" "$transcript_path" "$session_id" "$trigger"
build_rc=$?
case "$build_rc" in
  0)
    echo "[exomemory2] captured: ${VAULT}/raw/handovers/${session_id}.md" >&2
    ;;
  1)
    echo "[exomemory2] skipping empty session: $session_id" >&2
    exit 0
    ;;
  *)
    echo "[exomemory2] handover build failed (rc=$build_rc) for session: $session_id" >&2
    exit 0
    ;;
esac

# Capture-path queue scope: only the current session's queue is consumed,
# matching pre-v0.8 behavior. SessionStart rescue handles orphan queues.
QUEUE_FILE="$VAULT/.clip-queue/$session_id.txt"
queue_lf=""
[ -s "$QUEUE_FILE" ] && queue_lf="$QUEUE_FILE"

# Capture path never bypasses the dirty threshold. v0.8 reserves bypass for
# the SessionStart rescue path, where one missed handover is enough to
# warrant an ingest run.
ingest_spawn "$VAULT" "0" "$queue_lf"

exit 0
