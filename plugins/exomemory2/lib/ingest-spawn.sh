#!/bin/bash
# exomemory2 — ingest spawn helpers
#
# Source this file from another bash script. Do not run directly.
#
# Provides:
#   ingest_spawn <vault> <bypass_threshold> <queue_files_lf>
#
#     <vault>            vault root (must contain WIKI.md)
#     <bypass_threshold> "1" to ignore AUTO_INGEST_THRESHOLD, "0" to honor
#     <queue_files_lf>   newline-separated list of queue files to merge,
#                        feed to /exomemory2:wiki-clip --batch, and remove
#                        on success. Empty string = no clip work.
#
# Behavior:
#   - Strictly parses <vault>/.exomemory-config (KEY=INT only, never sourced).
#   - Honors AUTO_INGEST, AUTO_CLIP, AUTO_INGEST_INTERVAL_SEC always; ignores
#     AUTO_INGEST_THRESHOLD only when bypass_threshold == "1".
#   - Spawns a detached background subshell guarded by <vault>/.ingest.lock.
#   - Per phase (clip and/or ingest), captures stream-json output to a tmp
#     file, appends it to .ingest.log, and decides success/failure from BOTH
#     the exit code AND the final {"type":"result", "is_error": false}.
#   - On ingest success: updates <vault>/.last-ingest.
#   - On clip success: removes each input queue file.
#   - On failure: leaves .last-ingest / queue files untouched (the next
#     SessionStart rescue retries).
#   - Always returns 0; the caller does not block on the spawn.
#
# Dependencies: bash, jq, claude CLI, the ingest-preflight.sh script.

# Resolve our own directory at source time. Doing this inside a function
# would re-evaluate BASH_SOURCE[0] in a context where the array can lose
# the path prefix (e.g. inside command substitutions invoked by callers
# whose cwd differs from the script location), making _count_dirty pick
# up the wrong preflight path.
EXOMEM2_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Strictly parse a vault config file. Whitelisted KEY=INT lines only.
# Any other content (including command substitutions) is silently ignored.
# Defaults are written to AUTO_INGEST / AUTO_INGEST_THRESHOLD /
# AUTO_INGEST_INTERVAL_SEC / AUTO_CLIP in the caller's scope.
_load_exomem_config() {
  local config="$1"
  AUTO_INGEST=1
  AUTO_INGEST_THRESHOLD=3
  AUTO_INGEST_INTERVAL_SEC=1800
  AUTO_CLIP=1
  INGEST_BATCH_SIZE=10
  [ -f "$config" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*|"") continue ;;
    esac
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=([0-9]+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "$key" in
        AUTO_INGEST) AUTO_INGEST="$val" ;;
        AUTO_INGEST_THRESHOLD) AUTO_INGEST_THRESHOLD="$val" ;;
        AUTO_INGEST_INTERVAL_SEC) AUTO_INGEST_INTERVAL_SEC="$val" ;;
        AUTO_CLIP) AUTO_CLIP="$val" ;;
        INGEST_BATCH_SIZE) INGEST_BATCH_SIZE="$val" ;;
      esac
    fi
  done < "$config"
}

# Count dirty raw files via ingest-preflight.sh --count-only. Returns 0 on
# any error (so a missing preflight script doesn't trigger spurious ingests).
_count_dirty() {
  local vault="$1"
  local preflight="$EXOMEM2_LIB_DIR/../scripts/ingest-preflight.sh"
  if [ ! -x "$preflight" ]; then
    echo "[exomemory2] preflight script missing: $preflight" >&2
    echo 0
    return
  fi
  local summary
  summary=$("$preflight" --count-only "$vault" 2>&1 1>/dev/null) || {
    echo "[exomemory2] preflight failed: $summary" >&2
    echo 0
    return
  }
  local n
  n=$(printf '%s' "$summary" | awk '
    match($0, /dirty=[0-9]+/) {
      val = substr($0, RSTART + 6, RLENGTH - 6)
      print val + 0
      exit
    }
  ')
  echo "${n:-0}"
}

# Capture this subshell's PID into MY_PID. NEVER call via $(...) — that returns
# the command-substitution subshell's PID, which dies immediately and looks
# stale to the next caller's PID-liveness check.
_capture_self_pid() {
  if [ -n "${BASHPID:-}" ]; then
    MY_PID="$BASHPID"
  else
    local _tmp
    _tmp=$(mktemp -t exomem-pid)
    sh -c 'echo $PPID > "$0"' "$_tmp"
    MY_PID=$(cat "$_tmp")
    rm -f "$_tmp"
  fi
}

# Atomic lock acquisition via noclobber + PID liveness. Returns 0 if acquired.
_acquire_lock() {
  local lockfile="$1"
  local my_pid="$2"
  if ( set -o noclobber; echo "$my_pid" > "$lockfile" ) 2>/dev/null; then
    return 0
  fi
  local old_pid
  old_pid=$(cat "$lockfile" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    return 1
  fi
  rm -f "$lockfile"
  if ( set -o noclobber; echo "$my_pid" > "$lockfile" ) 2>/dev/null; then
    return 0
  fi
  return 1
}

# Decide success from a stream-json log file: exit-zero is necessary but not
# sufficient — `claude -p` can return 0 while the run aborted. The
# authoritative signal is the final {"type":"result","is_error":<bool>}
# record **for the main invocation's session_id**.
#
# Why filter on session_id: stream-json mixes the main session's records with
# subagent records (each Task / parallel sub-invocation also emits its own
# init / result). Subagent results can arrive after the main result, so a
# naive `grep ... | tail -n 1` picks up the wrong one and misclassifies a
# successful run as failed (observed in v0.8.0 when /wiki-clip --batch
# spawned parallel subagents). The first {"type":"system","subtype":"init"}
# always belongs to the main invocation.
_is_success() {
  local f="$1"
  [ -s "$f" ] || return 1
  local main_sid
  main_sid=$(grep -m 1 '"type":"system","subtype":"init"' "$f" 2>/dev/null \
             | jq -r '.session_id // empty' 2>/dev/null)
  [ -z "$main_sid" ] && return 1
  local last_result
  last_result=$(grep '"type":"result"' "$f" 2>/dev/null \
                | jq -c --arg sid "$main_sid" 'select(.session_id == $sid)' 2>/dev/null \
                | tail -n 1)
  [ -z "$last_result" ] && return 1
  local is_error
  # Do NOT use `.is_error // true` — jq's `//` treats boolean false as falsy
  # too, so `false // true` evaluates to true and would mark every successful
  # run as failed (this was the v0.8.0 "clip FAILED rc=0" bug). Read the raw
  # value and compare to the string "false". Anything else (true, null,
  # missing, parse error) is treated as failure — conservative by design.
  is_error=$(printf '%s' "$last_result" | jq -r '.is_error' 2>/dev/null)
  [ "$is_error" = "false" ]
}

ingest_spawn() {
  local vault="$1"
  local bypass_threshold="${2:-0}"
  local queue_files_lf="${3:-}"

  if [ -z "$vault" ] || [ ! -f "$vault/WIKI.md" ]; then
    return 0
  fi

  local AUTO_INGEST AUTO_INGEST_THRESHOLD AUTO_INGEST_INTERVAL_SEC AUTO_CLIP INGEST_BATCH_SIZE
  _load_exomem_config "$vault/.exomemory-config"

  # ---- has_queue: merge listed queue files into a deduped temp ----
  local has_queue=0
  local merged_queue=""
  if [ "$AUTO_CLIP" = "1" ] && [ -n "$queue_files_lf" ]; then
    merged_queue=$(mktemp -t exomem-merge-queue)
    while IFS= read -r qf; do
      [ -z "$qf" ] && continue
      [ -f "$qf" ] && cat "$qf" >> "$merged_queue"
    done <<< "$queue_files_lf"
    awk 'NF && !seen[$0]++' "$merged_queue" > "$merged_queue.dedup"
    mv "$merged_queue.dedup" "$merged_queue"
    if [ -s "$merged_queue" ]; then
      has_queue=1
    else
      rm -f "$merged_queue"
      merged_queue=""
    fi
  fi

  # ---- should_ingest: dirty (with optional threshold bypass) + interval ----
  local should_ingest=0
  local DIRTY=0
  if [ "$AUTO_INGEST" = "1" ]; then
    DIRTY=$(_count_dirty "$vault")
    local threshold_ok=1
    if [ "$bypass_threshold" != "1" ] && [ "$DIRTY" -lt "$AUTO_INGEST_THRESHOLD" ]; then
      threshold_ok=0
      echo "[exomemory2] ingest: $DIRTY dirty < threshold $AUTO_INGEST_THRESHOLD, skipping" >&2
    fi
    local interval_ok=1
    if [ -f "$vault/.last-ingest" ]; then
      local LAST NOW
      LAST=$(cat "$vault/.last-ingest" 2>/dev/null)
      NOW=$(date +%s)
      if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt "$AUTO_INGEST_INTERVAL_SEC" ]; then
        interval_ok=0
        echo "[exomemory2] ingest: last $((NOW - LAST))s ago < interval $AUTO_INGEST_INTERVAL_SEC, skipping" >&2
      fi
    fi
    if [ "$threshold_ok" = "1" ] && [ "$interval_ok" = "1" ]; then
      should_ingest=1
    fi
  fi

  if [ "$has_queue" = "0" ] && [ "$should_ingest" = "0" ]; then
    [ -n "$merged_queue" ] && rm -f "$merged_queue"
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "[exomemory2] 'claude' CLI not found in PATH, skipping" >&2
    [ -n "$merged_queue" ] && rm -f "$merged_queue"
    return 0
  fi

  local LOCK="$vault/.ingest.lock"
  local LOG="$vault/.ingest.log"

  # ---- Detached background subshell ----
  # Variables captured here (vault, has_queue, should_ingest, merged_queue,
  # queue_files_lf, LOCK, LOG, DIRTY) are inherited by the subshell at fork.
  (
    _capture_self_pid
    if ! _acquire_lock "$LOCK" "$MY_PID"; then
      [ -n "$merged_queue" ] && rm -f "$merged_queue"
      exit 0
    fi
    local clip_ok=0 ingest_ok=0

    # Cleanup runs on EXIT. Inline the variable expansions so the trap body
    # captures values at registration time (the variables are subshell-local
    # from here on, but spelling them out keeps the trap robust against later
    # local re-bindings).
    trap '
      rm -f "'"$LOCK"'"
      if [ "$ingest_ok" = "1" ]; then
        date +%s > "'"$vault"'/.last-ingest"
      fi
      if [ "$clip_ok" = "1" ] && [ -n "'"$queue_files_lf"'" ]; then
        while IFS= read -r qf; do
          [ -z "$qf" ] && continue
          [ -f "$qf" ] && rm -f "$qf"
        done <<< "'"$queue_files_lf"'"
      fi
      [ -n "'"$merged_queue"'" ] && rm -f "'"$merged_queue"'"
    ' EXIT

    # Phase 1: batch clip (if anything queued).
    if [ "$has_queue" = "1" ]; then
      local tmp_out
      tmp_out=$(mktemp -t exomem-clip-XXXX)
      printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"/exomemory2:wiki-clip --batch $merged_queue --captured-by auto-rescue\"}}" | \
        EXOMEMORY_VAULT="$vault" nohup claude -p \
          --input-format stream-json \
          --output-format stream-json \
          --verbose \
          --no-session-persistence \
          --permission-mode bypassPermissions \
          > "$tmp_out" 2>&1
      local rc=$?
      cat "$tmp_out" >> "$LOG"
      if [ "$rc" -eq 0 ] && _is_success "$tmp_out"; then
        clip_ok=1
      else
        echo "[exomemory2] clip FAILED rc=$rc (queue files retained for retry)" >> "$LOG"
      fi
      rm -f "$tmp_out"
    fi

    # Phase 2: wiki-ingest (if dirty/bypass and interval allow).
    if [ "$should_ingest" = "1" ]; then
      # Cap LLM workload per invocation. INGEST_BATCH_SIZE=0 disables the cap.
      local ingest_content="/exomemory2:wiki-ingest"
      if [ "$INGEST_BATCH_SIZE" -gt 0 ]; then
        ingest_content="$ingest_content --limit $INGEST_BATCH_SIZE"
      fi
      local ingest_msg
      ingest_msg=$(jq -nc --arg c "$ingest_content" \
        '{type:"user", message:{role:"user", content:$c}}')

      local tmp_out
      tmp_out=$(mktemp -t exomem-ingest-XXXX)
      printf '%s\n' "$ingest_msg" | \
        EXOMEMORY_VAULT="$vault" nohup claude -p \
          --input-format stream-json \
          --output-format stream-json \
          --verbose \
          --no-session-persistence \
          --permission-mode bypassPermissions \
          > "$tmp_out" 2>&1
      local rc=$?
      cat "$tmp_out" >> "$LOG"
      if [ "$rc" -eq 0 ] && _is_success "$tmp_out"; then
        ingest_ok=1
      else
        echo "[exomemory2] ingest FAILED rc=$rc (.last-ingest not advanced)" >> "$LOG"
      fi
      rm -f "$tmp_out"
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown

  echo "[exomemory2] spawned: clip=$has_queue ingest=$should_ingest dirty=$DIRTY bypass=$bypass_threshold" >&2
  return 0
}
