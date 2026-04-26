#!/bin/bash
# exomemory2 — handover build helpers
#
# Source this file from another bash script. Do not run directly.
#
# Provides:
#   url_to_slug <url>
#     -> echoes the wiki-clip slug for the given URL.
#        MUST stay in sync with commands/wiki-clip.md (Step 6).
#   build_handover <vault> <transcript_path> <session_id> <trigger>
#     Writes <vault>/raw/handovers/<session_id>.md atomically (tmp + mv).
#     Returns:
#       0 -> wrote handover (created or overwritten)
#       1 -> empty session (no md written, no error)
#       2 -> error (jq failure, missing transcript, mkdir failure, etc.)
#
# Dependencies: jq, awk, shasum, mv, mkdir, date.

# Derive the web-clip slug from a URL.
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

build_handover() {
  local vault="$1"
  local transcript_path="$2"
  local session_id="$3"
  local trigger="${4:-unknown}"

  if [ -z "$vault" ] || [ -z "$transcript_path" ] || [ -z "$session_id" ]; then
    return 2
  fi
  if [ ! -f "$transcript_path" ]; then
    return 2
  fi

  local handover_dir="${vault}/raw/handovers"
  mkdir -p "$handover_dir" || return 2

  local out_md="${handover_dir}/${session_id}.md"
  local tmp_md="${handover_dir}/.${session_id}.md.tmp.$$"

  # Prefer the timestamp of the first user/assistant message in the
  # transcript so the calendar/heatmap reflect WHEN THE CONVERSATION
  # HAPPENED, not when this handover happens to be (re)built. This matters
  # for rescue rebuilds — without this, all rebuilt handovers cluster on
  # the rebuild date and break the calendar layout (v0.8.0 → v0.8.2 fix).
  # Falls back to the current time only when the transcript has no usable
  # timestamp (older Claude Code versions that didn't emit .timestamp).
  local captured_at captured_at_source
  captured_at="$(
    jq -r '
      select((.type == "user" or .type == "assistant") and (.timestamp != null))
      | .timestamp
    ' "$transcript_path" 2>/dev/null | head -n 1
  )"
  captured_at="$(printf '%s' "$captured_at" | sed -E 's/\.[0-9]+Z?$/Z/')"
  if [ -n "$captured_at" ]; then
    captured_at_source="transcript-first-message"
  else
    captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    captured_at_source="fallback-now"
  fi

  # Extract conversation text. Filter to type=="text" to drop tool_use /
  # tool_result. Skip messages that yield no text so handovers do not get
  # bare "## User" headers.
  local body
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
  )" || return 2

  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    return 1
  fi

  {
    printf -- '---\n'
    printf 'title: "Session %s"\n' "$session_id"
    printf 'session_id: "%s"\n' "$session_id"
    printf 'last_trigger: "%s"\n' "$trigger"
    printf 'last_captured_at: "%s"\n' "$captured_at"
    printf 'captured_at_source: "%s"\n' "$captured_at_source"
    printf -- '---\n\n'
    printf '%s\n' "$body"
  } > "$tmp_md" || { rm -f "$tmp_md"; return 2; }

  # Append "Clips Captured" section if PostToolUse[WebFetch] queued URLs
  # for this session_id. Wikilinks are URL-derived so the handover's own
  # text creates the handover → web-clip Connection during /wiki-ingest,
  # even if the clip raw file hasn't been materialized yet by batch-clip.
  local queue_file="$vault/.clip-queue/$session_id.txt"
  if [ -s "$queue_file" ]; then
    local queued_urls
    queued_urls=$(awk 'NF && !seen[$0]++' "$queue_file")
    if [ -n "$queued_urls" ]; then
      {
        printf '\n## Clips Captured in This Session\n\n'
        while IFS= read -r u; do
          [ -z "$u" ] && continue
          local slug
          slug=$(url_to_slug "$u")
          printf -- '- [[%s]] — %s\n' "$slug" "$u"
        done <<< "$queued_urls"
      } >> "$tmp_md"
    fi
  fi

  if ! mv "$tmp_md" "$out_md"; then
    rm -f "$tmp_md"
    return 2
  fi
  return 0
}
