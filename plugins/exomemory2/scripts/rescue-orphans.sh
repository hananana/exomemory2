#!/bin/bash
# exomemory2 — SessionStart orphan rescue
#
# Discovers Claude Code transcripts that never produced a handover (or whose
# handover is older than the transcript), rebuilds them via build_handover(),
# collects any orphan clip queue files, then triggers ingest_spawn() with
# threshold bypass if anything was rescued.
#
# This script is normally launched by hooks/session-start.sh as a detached
# background subshell (it should never block hook execution). The script
# exits 0 on any soft failure to avoid noisy hook output.
#
# Usage:
#   rescue-orphans.sh --vault <VAULT> --self-session-id <SID>
#
# Config keys (in <VAULT>/.exomemory-config, KEY=INT only):
#   RESCUE_ORPHANS         (default 1)   — set 0 to disable rescue entirely.
#   RESCUE_SINCE_DAYS      (default 14)  — only consider transcripts whose
#                                          mtime falls within this window.
#   RESCUE_QUIESCENCE_SEC  (default 60)  — fallback live-session heuristic
#                                          when lsof can't resolve openers.
#
# Dependencies: bash, jq, find, stat, awk. lsof is preferred but optional.

set -eo pipefail

usage() {
  echo "Usage: $0 --vault <VAULT> --self-session-id <SID>" >&2
}

VAULT=""
SELF_SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vault)
      VAULT="${2:-}"; shift 2 ;;
    --self-session-id)
      SELF_SID="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage; exit 2 ;;
  esac
done

if [ -z "$VAULT" ]; then
  usage; exit 2
fi
if [ ! -f "$VAULT/WIKI.md" ]; then
  echo "[exomemory2] rescue: vault missing WIKI.md: $VAULT" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[exomemory2] rescue: jq not found in PATH, skipping" >&2
  exit 0
fi

# ---- Strict whitelist parser for .exomemory-config (rescue keys only) ----
RESCUE_ORPHANS=1
RESCUE_SINCE_DAYS=14
RESCUE_QUIESCENCE_SEC=60
CONFIG="$VAULT/.exomemory-config"
if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*|"") continue ;;
    esac
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=([0-9]+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "$key" in
        RESCUE_ORPHANS)        RESCUE_ORPHANS="$val" ;;
        RESCUE_SINCE_DAYS)     RESCUE_SINCE_DAYS="$val" ;;
        RESCUE_QUIESCENCE_SEC) RESCUE_QUIESCENCE_SEC="$val" ;;
      esac
    fi
  done < "$CONFIG"
fi

if [ "$RESCUE_ORPHANS" != "1" ]; then
  echo "[exomemory2] rescue: RESCUE_ORPHANS=0, skipping" >&2
  exit 0
fi

PROJ_ROOT="$HOME/.claude/projects"
if [ ! -d "$PROJ_ROOT" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/handover-build.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/ingest-spawn.sh"

NOW=$(date +%s)
HANDOVER_DIR="$VAULT/raw/handovers"
mkdir -p "$HANDOVER_DIR"

# BSD (macOS) and GNU stat differ. Try BSD first, then GNU.
file_mtime_epoch() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0
}

# A transcript belongs to a live session if either:
#   1. lsof finds at least one process holding it open AND that PID is alive
#   2. lsof unavailable / silent, and mtime > now - quiescence_sec
# Returns 0 (live) or 1 (quiescent).
is_live_transcript() {
  local f="$1"
  if command -v lsof >/dev/null 2>&1; then
    local pids pid
    pids=$(lsof -t -- "$f" 2>/dev/null | head -n 5)
    if [ -n "$pids" ]; then
      while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
          return 0
        fi
      done <<< "$pids"
    fi
  fi
  local mtime
  mtime=$(file_mtime_epoch "$f")
  if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] && [ $((NOW - mtime)) -lt "$RESCUE_QUIESCENCE_SEC" ]; then
    return 0
  fi
  return 1
}

# ---- Phase 1: rebuild handovers from orphan transcripts ----
rebuilt=0
empty_skip=0
err=0

while IFS= read -r -d '' tpath; do
  base=$(basename "$tpath")
  sid="${base%.jsonl}"
  [ -z "$sid" ] && continue
  [ "$sid" = "$SELF_SID" ] && continue

  if is_live_transcript "$tpath"; then
    continue
  fi

  out_md="$HANDOVER_DIR/${sid}.md"
  if [ -f "$out_md" ]; then
    md_mtime=$(file_mtime_epoch "$out_md")
    t_mtime=$(file_mtime_epoch "$tpath")
    # Only rebuild when the transcript is strictly newer than the existing
    # handover (PreCompact-built mid-session handovers have older mtime than
    # the final transcript and must be refreshed).
    if [ "$t_mtime" -le "$md_mtime" ]; then
      continue
    fi
  fi

  set +e
  build_handover "$VAULT" "$tpath" "$sid" "session-start-rescue"
  rc=$?
  set -e
  case "$rc" in
    0) rebuilt=$((rebuilt + 1)) ;;
    1) empty_skip=$((empty_skip + 1)) ;;
    *) err=$((err + 1)) ;;
  esac
done < <(find "$PROJ_ROOT" -maxdepth 4 -type f -name '*.jsonl' -not -path '*/subagents/*' -mtime "-${RESCUE_SINCE_DAYS}" -print0 2>/dev/null)

# ---- Phase 2: collect orphan clip queue files ----
orphan_queues=""
queue_count=0
if [ -d "$VAULT/.clip-queue" ]; then
  while IFS= read -r -d '' qf; do
    qbase=$(basename "$qf")
    qsid="${qbase%.txt}"
    [ -z "$qsid" ] && continue
    [ "$qsid" = "$SELF_SID" ] && continue

    qtx=$(find "$PROJ_ROOT" -maxdepth 4 -type f -name "${qsid}.jsonl" -not -path '*/subagents/*' -print -quit 2>/dev/null)
    if [ -n "$qtx" ] && is_live_transcript "$qtx"; then
      continue
    fi

    if [ -n "$orphan_queues" ]; then
      orphan_queues="${orphan_queues}
${qf}"
    else
      orphan_queues="$qf"
    fi
    queue_count=$((queue_count + 1))
  done < <(find "$VAULT/.clip-queue" -maxdepth 1 -type f -name '*.txt' -print0 2>/dev/null)
fi

echo "[exomemory2] rescue: rebuilt=$rebuilt empty=$empty_skip err=$err queues=$queue_count" >&2

# ---- Phase 3: ingest with threshold bypass when we actually rescued anything ----
bypass=0
if [ "$rebuilt" -gt 0 ] || [ "$queue_count" -gt 0 ]; then
  bypass=1
fi

# Always invoke ingest_spawn so a previously-dirty vault still gets a chance,
# governed by the standard threshold/interval gates when bypass=0.
ingest_spawn "$VAULT" "$bypass" "$orphan_queues"

exit 0
