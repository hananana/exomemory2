#!/bin/bash
# exomemory2 capture hook
#
# Fires on PreCompact and SessionEnd. Reads the Claude Code transcript
# (via stdin JSON) and writes a Markdown handover file into the active
# vault's raw/handovers/ directory. Filename is keyed by session_id so
# multiple compacts within one session converge into a single file.
#
# Requires: jq
# Behavior: exits silently (0) if EXOMEMORY_VAULT (or legacy
# CLAUDE_MEMORY_VAULT) is unset or the transcript is unreadable.

set -eo pipefail

# ---------------------------------------------------------------------------
# Helpers referenced during handover composition below must be defined up
# front (bash resolves function names at call time, but only functions that
# have been parsed so far).
# ---------------------------------------------------------------------------

# Derive the web-clip slug from a URL. MUST stay in sync with the URL
# normalization in commands/wiki-clip.md (Step 6). If you change one, change
# the other — ingest will create duplicate wiki pages otherwise.
url_to_slug() {
  local url="$1"
  local u="${url%%#*}"
  u="${u%%\?*}"
  local rest="${u#*://}"
  local host="${rest%%/*}"
  local path="/${rest#*/}"
  [ "$host" = "$rest" ] && path=""
  local host_safe
  host_safe=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
  local path_trim="${path#/}"
  path_trim="${path_trim%/}"
  local path_safe
  path_safe=$(printf '%s' "$path_trim" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|/|--|g; s|[^a-z0-9._-]|-|g' \
    | sed -E 's|^-+||; s|-+$||')
  local base
  if [ -n "$path_safe" ]; then
    base="${host_safe}--${path_safe}"
  else
    base="$host_safe"
  fi
  if [ ${#base} -gt 120 ]; then
    local h
    h=$(printf '%s' "$base" | shasum -a 256 | cut -c1-8)
    base="${base:0:110}-${h}"
  fi
  printf '%s' "web--${base}"
}

# Resolve vault: EXOMEMORY_VAULT preferred, CLAUDE_MEMORY_VAULT for backward
# compatibility (deprecated, will be removed in v0.3).
VAULT="${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
if [ -z "$VAULT" ]; then
  echo "[exomemory2] EXOMEMORY_VAULT not set, skipping capture" >&2
  exit 0
fi
if [ -z "${EXOMEMORY_VAULT:-}" ] && [ -n "${CLAUDE_MEMORY_VAULT:-}" ]; then
  echo "[exomemory2] CLAUDE_MEMORY_VAULT is deprecated; please use EXOMEMORY_VAULT (will be removed in v0.3)" >&2
fi

# Validate the vault exists and looks like a vault.
if [ ! -f "${VAULT}/WIKI.md" ]; then
  echo "[exomemory2] vault path does not contain WIKI.md: ${VAULT}" >&2
  exit 0
fi

# Require jq.
if ! command -v jq >/dev/null 2>&1; then
  echo "[exomemory2] jq not found in PATH, cannot extract transcript" >&2
  exit 0
fi

# Read stdin (Claude Code hook input JSON).
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

handover_dir="${VAULT}/raw/handovers"
mkdir -p "$handover_dir"

out_md="${handover_dir}/${session_id}.md"
captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Extract conversation text. Both user-content-string and user-content-array cases,
# filter to type=="text" to drop tool_use/tool_result dumps. Skip messages that
# yield no text to avoid empty "## User" headers.
body="$(
  jq -r '
    if .type == "user" then
      (if (.message.content | type) == "string"
       then "## User\n\n" + .message.content + "\n"
       else
         (.message.content
          | map(select(.type == "text") | .text)
          | join("\n\n")) as $text
         | if $text == "" then empty
           else "## User\n\n" + $text + "\n" end
       end)
    elif .type == "assistant" then
      (.message.content
       | map(select(.type == "text") | .text)
       | join("\n\n")) as $text
      | if $text == "" then empty
        else "## Assistant\n\n" + $text + "\n" end
    else empty end
  ' "$transcript_path"
)"

# Skip sessions with no meaningful body (transcript only contains tool_use /
# tool_result, or never got a text message). Otherwise we pollute raw/ with
# frontmatter-only files and create noisy wiki source pages.
if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
  echo "[exomemory2] skipping empty session: $session_id" >&2
  exit 0
fi

# Compose the full Markdown output with YAML frontmatter.
{
  printf -- '---\n'
  printf 'title: "Session %s"\n' "$session_id"
  printf 'session_id: "%s"\n' "$session_id"
  printf 'last_trigger: "%s"\n' "$trigger"
  printf 'last_captured_at: "%s"\n' "$captured_at"
  printf -- '---\n\n'
  printf '%s\n' "$body"
} > "$out_md"

# Append "Clips Captured" section if PostToolUse[WebFetch] queued URLs for
# this session. Wikilinks are computed from URLs so that the handover's own
# text creates the handover → web-clip Connection during /wiki-ingest, even
# if the clip raw file hasn't been materialized yet by batch-clip.
QUEUE_FILE="$VAULT/.clip-queue/$session_id.txt"
if [ -s "$QUEUE_FILE" ]; then
  queued_urls=$(awk 'NF && !seen[$0]++' "$QUEUE_FILE")
  if [ -n "$queued_urls" ]; then
    {
      printf '\n## Clips Captured in This Session\n\n'
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        slug=$(url_to_slug "$u")
        printf -- '- [[%s]] — %s\n' "$slug" "$u"
      done <<< "$queued_urls"
    } >> "$out_md"
  fi
fi

echo "[exomemory2] captured: $out_md" >&2

# ===========================================================================
# Auto-ingest gate (v0.2+)
#
# After capturing the handover, optionally spawn a background `claude -p`
# process to ingest it into the wiki. Controlled by <vault>/.exomemory-config
# (strictly parsed; never `source`d, see security note in load_config).
# ===========================================================================

# Strict whitelist parser for .exomemory-config.
# Only KEY=INT lines for known keys are honored; any other content is ignored.
load_config() {
  local config="$1"
  AUTO_INGEST=1
  AUTO_INGEST_THRESHOLD=3
  AUTO_INGEST_INTERVAL_SEC=1800
  AUTO_CLIP=1
  [ -f "$config" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*|"") continue ;;
    esac
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=([0-9]+)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      case "$key" in
        AUTO_INGEST) AUTO_INGEST="$val" ;;
        AUTO_INGEST_THRESHOLD) AUTO_INGEST_THRESHOLD="$val" ;;
        AUTO_INGEST_INTERVAL_SEC) AUTO_INGEST_INTERVAL_SEC="$val" ;;
        AUTO_CLIP) AUTO_CLIP="$val" ;;
      esac
    fi
  done < "$config"
}

# Count handovers in raw/ that are not yet ingested or have changed.
count_dirty_handovers() {
  local vault="$1"
  local handovers_dir="$vault/raw/handovers"
  local sources_dir="$vault/wiki/sources"
  local count=0
  [ -d "$handovers_dir" ] || { echo 0; return; }
  for raw_file in "$handovers_dir"/*.md; do
    [ -f "$raw_file" ] || continue
    local basename slug wiki_page stored_hash current_hash
    basename=$(basename "$raw_file")
    slug="handovers--${basename%.md}"
    wiki_page="$sources_dir/$slug.md"
    if [ ! -f "$wiki_page" ]; then
      count=$((count + 1))
      continue
    fi
    stored_hash=$(awk '
      /^---$/ { in_fm = !in_fm; next }
      in_fm && /^source_hash:/ {
        val = $2; gsub(/^"|"$/, "", val); sub(/^sha256:/, "", val); print val; exit
      }
    ' "$wiki_page")
    current_hash=$(shasum -a 256 "$raw_file" | awk '{print $1}')
    if [ "$stored_hash" != "$current_hash" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Capture the current subshell's PID into MY_PID (set as a side effect).
# Must NOT be invoked via $(...), because that would return the command
# substitution subshell's PID — which dies the moment $() completes,
# making any lockfile containing it look "stale" to the next caller.
# Bash 4+ exposes $BASHPID directly; bash 3 (macOS /bin/bash) needs a
# helper child whose $PPID is us.
capture_self_pid() {
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

# Atomic lock acquisition via noclobber + PID liveness check for stale.
# Returns 0 if acquired, 1 if held by another live process.
# my_pid must be passed in (computed via capture_self_pid) — computing it
# here via $() would store a transient subshell PID that dies immediately.
acquire_lock() {
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

# Load per-vault config (defaults applied if file is missing).
load_config "$VAULT/.exomemory-config"

# Two independent gates:
#   has_queue     — clips pending in $QUEUE_FILE (bypasses the dirty/interval gate)
#   should_ingest — the existing dirty+interval gate for /wiki-ingest
# Either gate firing triggers the background spawn; neither firing exits 0.
has_queue=0
if [ "$AUTO_CLIP" = "1" ] && [ -s "$QUEUE_FILE" ]; then
  has_queue=1
fi

should_ingest=0
if [ "$AUTO_INGEST" = "1" ]; then
  DIRTY=$(count_dirty_handovers "$VAULT")
  if [ "$DIRTY" -ge "$AUTO_INGEST_THRESHOLD" ]; then
    ingest_interval_ok=1
    if [ -f "$VAULT/.last-ingest" ]; then
      LAST=$(cat "$VAULT/.last-ingest" 2>/dev/null)
      NOW=$(date +%s)
      if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt "$AUTO_INGEST_INTERVAL_SEC" ]; then
        ingest_interval_ok=0
        echo "[exomemory2] auto-ingest: last run $((NOW - LAST))s ago < interval $AUTO_INGEST_INTERVAL_SEC, skipping ingest" >&2
      fi
    fi
    if [ "$ingest_interval_ok" = "1" ]; then
      should_ingest=1
    fi
  else
    echo "[exomemory2] auto-ingest: $DIRTY dirty < threshold $AUTO_INGEST_THRESHOLD, skipping ingest" >&2
  fi
fi

if [ "$has_queue" = "0" ] && [ "$should_ingest" = "0" ]; then
  exit 0
fi

# Verify `claude` is available before spawning.
if ! command -v claude >/dev/null 2>&1; then
  echo "[exomemory2] 'claude' CLI not found in PATH, skipping" >&2
  exit 0
fi

LOCK="$VAULT/.ingest.lock"
LOG="$VAULT/.ingest.log"

# Background subshell owns the lock for the lifetime of `claude -p`.
# nohup + disown lets it survive parent shell death (Claude Code exit, tmux
# kill-server, terminal close — adopted by launchd).
(
  capture_self_pid
  if ! acquire_lock "$LOCK" "$MY_PID"; then
    exit 0
  fi
  # Cleanup: always remove lock. Bump .last-ingest only if ingest actually
  # ran. Remove queue unconditionally (a failed batch leaves errors in
  # .ingest.log; retrying the same queue on the next SessionEnd is riskier
  # than forcing the user to re-invoke /wiki-clip manually).
  trap '
    rm -f "$LOCK"
    [ "'"$should_ingest"'" = "1" ] && date +%s > "'"$VAULT"'/.last-ingest"
    [ -f "'"$QUEUE_FILE"'" ] && rm -f "'"$QUEUE_FILE"'"
  ' EXIT

  # Batch clip first (if any). Runs even when the ingest gate is closed, so
  # short sessions still get their pending clips materialized into raw/web/.
  if [ "$has_queue" = "1" ]; then
    printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"/exomemory2:wiki-clip --batch $QUEUE_FILE --captured-by auto-webfetch\"}}" | \
      EXOMEMORY_VAULT="$VAULT" nohup claude -p \
        --input-format stream-json \
        --output-format stream-json \
        --verbose \
        --no-session-persistence \
        --permission-mode bypassPermissions \
        >>"$LOG" 2>&1
  fi

  # Ingest pass (only when the dirty/interval gate is open).
  if [ "$should_ingest" = "1" ]; then
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"/exomemory2:wiki-ingest"}}' | \
      EXOMEMORY_VAULT="$VAULT" nohup claude -p \
        --input-format stream-json \
        --output-format stream-json \
        --verbose \
        --no-session-persistence \
        --permission-mode bypassPermissions \
        >>"$LOG" 2>&1
  fi
) </dev/null >/dev/null 2>&1 &
disown

echo "[exomemory2] spawned background: clip=$has_queue ingest=$should_ingest (dirty=${DIRTY:-0})" >&2
exit 0
