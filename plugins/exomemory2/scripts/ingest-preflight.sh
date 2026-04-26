#!/usr/bin/env bash
# ingest-preflight.sh — pre-compute /wiki-ingest's per-file decisions in Bash
# so the LLM never has to read a file just to decide SKIP.
#
# Usage:
#   ingest-preflight.sh <VAULT> [<RAW_TARGET>]
#
# Outputs:
#   - NDJSON to stdout, one record per raw file (excluding raw/assets/*).
#     Records have op ∈ {SKIP, SKIP-empty, CREATE, UPDATE, ERROR}.
#   - One summary line `# preflight: ...` to stderr.
# Side effects:
#   - Appends `## [<today>] SKIP | <slug>` and `## [<today>] SKIP-empty | <slug>`
#     lines to <VAULT>/wiki/log.md in a single batched write per run.
#
# Dependencies: bash, awk, shasum, find, jq.
# (jq is already a hard dependency of plugins/exomemory2/hooks/capture.sh.)

set -euo pipefail

VAULT="${1:?usage: $0 <VAULT> [<RAW_TARGET>]}"
RAW_TARGET="${2:-$VAULT/raw}"

[ -d "$VAULT" ] || { echo "[preflight] vault not found: $VAULT" >&2; exit 2; }
[ -f "$VAULT/WIKI.md" ] || { echo "[preflight] WIKI.md missing: $VAULT" >&2; exit 2; }
[ -e "$RAW_TARGET" ] || { echo "[preflight] raw target not found: $RAW_TARGET" >&2; exit 2; }

VAULT="$(cd "$VAULT" && pwd)"
if [ -d "$RAW_TARGET" ]; then
  RAW_TARGET="$(cd "$RAW_TARGET" && pwd)"
elif [ -f "$RAW_TARGET" ]; then
  RAW_TARGET="$(cd "$(dirname "$RAW_TARGET")" && pwd)/$(basename "$RAW_TARGET")"
fi

case "$RAW_TARGET" in
  "$VAULT/raw"|"$VAULT/raw/"*) ;;
  *) echo "[preflight] raw target outside vault/raw/: $RAW_TARGET" >&2; exit 2 ;;
esac

TODAY="$(date +%Y-%m-%d)"
SOURCES_DIR="$VAULT/wiki/sources"
LOG_FILE="$VAULT/wiki/log.md"

# Counters
total=0 skip=0 skip_empty=0 skip_asset=0 create=0 update=0 error=0

SKIP_LOG_TMP="$(mktemp -t exomem-preflight-skip)"
trap 'rm -f "$SKIP_LOG_TMP"' EXIT

# Single-pass awk: extract source_id and source_hash from existing wiki page
# in one process. Outputs `source_id=...\nsource_hash=...` (missing keys empty).
parse_existing() {
  awk '
    BEGIN { in_fm = 0; n = 0; sid = ""; shash = "" }
    /^---$/ { n++; in_fm = (n == 1); if (n == 2) exit; next }
    !in_fm { next }
    {
      pos = index($0, ":")
      if (pos == 0) next
      k = substr($0, 1, pos - 1)
      sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k)
      v = substr($0, pos + 1)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      if (k == "source_id" && sid == "") sid = v
      else if (k == "source_hash" && shash == "") shash = v
    }
    END {
      sub(/^sha256:/, "", shash)
      printf "source_id=%s\nsource_hash=%s\n", sid, shash
    }
  ' "$1"
}

# Single-pass awk: extract source_url, captured_at, captured_by from raw web-clip frontmatter.
parse_web_clip_raw() {
  awk '
    BEGIN { in_fm = 0; n = 0; url = ""; ts = ""; by = "" }
    /^---$/ { n++; in_fm = (n == 1); if (n == 2) exit; next }
    !in_fm { next }
    {
      pos = index($0, ":")
      if (pos == 0) next
      k = substr($0, 1, pos - 1)
      sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k)
      v = substr($0, pos + 1)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      if (k == "source_url" && url == "") url = v
      else if (k == "captured_at" && ts == "") ts = v
      else if (k == "captured_by" && by == "") by = v
    }
    END { printf "source_url=%s\ncaptured_at=%s\ncaptured_by=%s\n", url, ts, by }
  ' "$1"
}

# Returns 0 (true) iff body after frontmatter has no non-whitespace content.
# Also computes the body word count as a side effect (printed to stdout).
# Output: `<is_empty>:<word_count>` where is_empty ∈ {0,1}.
body_stats() {
  awk '
    BEGIN { in_fm = 0; past_fm = 0; has_body = 0; wc = 0 }
    NR == 1 && /^---$/ { in_fm = 1; next }
    in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
    in_fm { next }
    {
      if (/[^[:space:]]/) has_body = 1
      for (i = 1; i <= NF; i++) wc++
    }
    END { printf "%d:%d\n", (has_body ? 0 : 1), wc }
  ' "$1"
}

# Lowercased host portion of a URL.
url_to_domain() {
  printf '%s' "$1" | awk '{
    sub(/^[a-zA-Z]+:\/\//, "")
    sub(/\/.*/, "")
    sub(/[?#].*/, "")
    sub(/:.*/, "")
    print tolower($0)
  }'
}

# Slugify: source_id (POSIX path) → slug.
make_slug() {
  local sid="$1"
  local slug="${sid%.md}"
  slug="${slug//\//--}"
  printf '%s' "$slug" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g'
}

emit_record() {
  # All args forwarded as `--arg k v` pairs to jq; final arg is filter.
  jq -nc "$@"
}

process_file() {
  local raw="$1"
  total=$((total + 1))

  local rel source_id source_type
  rel="${raw#$VAULT/raw/}"
  source_id="$rel"

  case "$source_id" in
    assets/*)
      skip_asset=$((skip_asset + 1))
      return
      ;;
    handovers/*) source_type="handover" ;;
    web/*) source_type="web-clip" ;;
    *) source_type="manual" ;;
  esac

  local slug
  slug="$(make_slug "$source_id")"
  local existing_page="$SOURCES_DIR/$slug.md"

  # Identity hash (always needed for SKIP/UPDATE).
  local source_hash
  source_hash="$(shasum -a 256 "$raw" | awk '{print $1}')"

  # Fast path: existing page → check SKIP/UPDATE/ERROR before reading body.
  local op="" existing_sid="" existing_hash=""
  if [ -f "$existing_page" ]; then
    local parsed
    parsed="$(parse_existing "$existing_page")"
    existing_sid="$(printf '%s' "$parsed" | awk -F= '/^source_id=/{print substr($0,11); exit}')"
    existing_hash="$(printf '%s' "$parsed" | awk -F= '/^source_hash=/{print substr($0,13); exit}')"

    if [ "$existing_sid" != "$source_id" ]; then
      op="ERROR"
    elif [ "$existing_hash" = "$source_hash" ]; then
      op="SKIP"
    else
      op="UPDATE"
    fi
  else
    op="CREATE"
  fi

  # SKIP path: emit minimal record + queue log line, no body parsing.
  if [ "$op" = "SKIP" ]; then
    skip=$((skip + 1))
    printf '## [%s] SKIP | %s\n' "$TODAY" "$slug" >> "$SKIP_LOG_TMP"
    emit_record \
      --arg op SKIP \
      --arg path "$raw" \
      --arg slug "$slug" \
      --arg source_id "$source_id" \
      --arg source_type "$source_type" \
      --arg source_hash "$source_hash" \
      '{op:$op, path:$path, slug:$slug, source_id:$source_id, source_type:$source_type, source_hash:$source_hash}'
    return
  fi

  if [ "$op" = "ERROR" ]; then
    error=$((error + 1))
    emit_record \
      --arg op ERROR \
      --arg path "$raw" \
      --arg slug "$slug" \
      --arg source_id "$source_id" \
      --arg existing_sid "$existing_sid" \
      --arg reason slug_collision \
      '{op:$op, path:$path, slug:$slug, source_id:$source_id, existing_source_id:$existing_sid, reason:$reason}'
    return
  fi

  # CREATE / UPDATE: compute body stats and per-type derived fields.
  local stats is_empty word_count reading_time_min
  stats="$(body_stats "$raw")"
  is_empty="${stats%%:*}"
  word_count="${stats##*:}"
  reading_time_min=$(( (word_count + 199) / 200 ))

  if [ "$is_empty" = "1" ]; then
    skip_empty=$((skip_empty + 1))
    printf '## [%s] SKIP-empty | %s\n' "$TODAY" "$slug" >> "$SKIP_LOG_TMP"
    emit_record \
      --arg op "SKIP-empty" \
      --arg path "$raw" \
      --arg slug "$slug" \
      --arg source_id "$source_id" \
      --arg source_type "$source_type" \
      '{op:$op, path:$path, slug:$slug, source_id:$source_id, source_type:$source_type}'
    return
  fi

  if [ "$op" = "CREATE" ]; then
    create=$((create + 1))
  else
    update=$((update + 1))
  fi

  # Type-specific derived fields.
  if [ "$source_type" = "handover" ]; then
    local session_id="${slug#handovers--}"
    emit_record \
      --arg op "$op" \
      --arg path "$raw" \
      --arg slug "$slug" \
      --arg source_id "$source_id" \
      --arg source_type "$source_type" \
      --arg source_hash "$source_hash" \
      --argjson word_count "$word_count" \
      --argjson reading_time_min "$reading_time_min" \
      --arg session_id "$session_id" \
      --arg existing_page "$existing_page" \
      '{op:$op, path:$path, slug:$slug, source_id:$source_id, source_type:$source_type, source_hash:$source_hash, word_count:$word_count, reading_time_min:$reading_time_min, session_id:$session_id, existing_page:$existing_page}'
  elif [ "$source_type" = "web-clip" ]; then
    local parsed_raw source_url captured_at captured_by domain
    parsed_raw="$(parse_web_clip_raw "$raw")"
    source_url="$(printf '%s' "$parsed_raw" | awk -F= '/^source_url=/{print substr($0,12); exit}')"
    captured_at="$(printf '%s' "$parsed_raw" | awk -F= '/^captured_at=/{print substr($0,13); exit}')"
    captured_by="$(printf '%s' "$parsed_raw" | awk -F= '/^captured_by=/{print substr($0,13); exit}')"
    [ -z "$captured_by" ] && captured_by="unknown"
    domain="$(url_to_domain "$source_url")"
    emit_record \
      --arg op "$op" \
      --arg path "$raw" \
      --arg slug "$slug" \
      --arg source_id "$source_id" \
      --arg source_type "$source_type" \
      --arg source_hash "$source_hash" \
      --argjson word_count "$word_count" \
      --argjson reading_time_min "$reading_time_min" \
      --arg source_url "$source_url" \
      --arg captured_at "$captured_at" \
      --arg captured_by "$captured_by" \
      --arg domain "$domain" \
      --arg existing_page "$existing_page" \
      '{op:$op, path:$path, slug:$slug, source_id:$source_id, source_type:$source_type, source_hash:$source_hash, word_count:$word_count, reading_time_min:$reading_time_min, source_url:$source_url, captured_at:$captured_at, captured_by:$captured_by, domain:$domain, existing_page:$existing_page}'
  else
    emit_record \
      --arg op "$op" \
      --arg path "$raw" \
      --arg slug "$slug" \
      --arg source_id "$source_id" \
      --arg source_type "$source_type" \
      --arg source_hash "$source_hash" \
      --argjson word_count "$word_count" \
      --argjson reading_time_min "$reading_time_min" \
      --arg existing_page "$existing_page" \
      '{op:$op, path:$path, slug:$slug, source_id:$source_id, source_type:$source_type, source_hash:$source_hash, word_count:$word_count, reading_time_min:$reading_time_min, existing_page:$existing_page}'
  fi
}

# Walk the target.
if [ -f "$RAW_TARGET" ]; then
  process_file "$RAW_TARGET"
else
  while IFS= read -r -d '' f; do
    process_file "$f"
  done < <(find "$RAW_TARGET" -type f -name '*.md' -not -path '*/assets/*' -print0)
fi

# Batch append SKIP / SKIP-empty lines once.
if [ -s "$SKIP_LOG_TMP" ]; then
  cat "$SKIP_LOG_TMP" >> "$LOG_FILE"
fi

dirty=$((create + update))
printf '# preflight: total=%d skip=%d skip_empty=%d skip_asset=%d create=%d update=%d error=%d dirty=%d\n' \
  "$total" "$skip" "$skip_empty" "$skip_asset" "$create" "$update" "$error" "$dirty" >&2
