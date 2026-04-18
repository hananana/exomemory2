#!/bin/bash
# exomemory2 capture hook
#
# Fires on PreCompact and SessionEnd. Reads the Claude Code transcript
# (via stdin JSON) and writes a Markdown handover file into the active
# vault's raw/handovers/ directory. Filename is keyed by session_id so
# multiple compacts within one session converge into a single file.
#
# Requires: jq
# Behavior: exits silently (0) if CLAUDE_MEMORY_VAULT is unset or the
# transcript is unreadable.

set -eo pipefail

# Require CLAUDE_MEMORY_VAULT. Skip silently if not configured.
if [ -z "${CLAUDE_MEMORY_VAULT:-}" ]; then
  echo "[exomemory2] CLAUDE_MEMORY_VAULT not set, skipping capture" >&2
  exit 0
fi

# Validate the vault exists and looks like a vault.
if [ ! -f "${CLAUDE_MEMORY_VAULT}/WIKI.md" ]; then
  echo "[exomemory2] \$CLAUDE_MEMORY_VAULT does not contain WIKI.md: ${CLAUDE_MEMORY_VAULT}" >&2
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

handover_dir="${CLAUDE_MEMORY_VAULT}/raw/handovers"
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

echo "[exomemory2] captured: $out_md" >&2
exit 0
