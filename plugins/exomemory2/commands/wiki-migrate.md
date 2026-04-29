---
description: Retrofit the vault to the current schema (derived frontmatter, dashboards, index heatmap)
argument-hint: "[--dry-run] [--skip-schema-update] [--force] [--vault <path>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# /wiki-migrate

Bring a vault up to the current exomemory2 schema. This generalizes the prior `/wiki-migrate-dataview` command (v0.4) by also handling v0.5 additions. The command performs, in order:

1. (v0.4) For every `wiki/sources/*.md`, recompute derived frontmatter fields (`source_type`, `word_count`, `reading_time_min`, and handover/web-clip specific fields)
2. (v0.4) Replace the vault's `WIKI.md` with the current template when the line-1 schema marker is absent or points at an older version
3. (v0.4) Copy `wiki/dashboards/` files that are missing in the vault
4. (v0.5+) Insert decorative sections into `wiki/index.md` if missing — Activity heatmap (v0.5), Handover calendar (v0.6), extensible. See Step 9 for the decision flow

This command is **idempotent**: derived fields are pure functions of the raw file and `source_id`, and the heatmap insert is gated by section presence, so re-running on a fully-migrated vault produces zero diff.

## Arguments

```
$ARGUMENTS
```

## Step 1: Parse arguments

Tokenize `$ARGUMENTS` and set the following shell variables used by later steps:

- `DRY_RUN=1` if `--dry-run` is present, else `0`
- `SKIP_SCHEMA_UPDATE=1` if `--skip-schema-update` is present, else `0`
- `FORCE=1` if `--force` is present, else `0` (v0.5+: used by Step 10 to prepend the heatmap into a customized `index.md`)
- `EXPLICIT_VAULT=<path>` if `--vault <path>` is supplied, else unset

Export `DRY_RUN`, `SKIP_SCHEMA_UPDATE`, and `FORCE` so embedded `python3` and sub-blocks can read them.

Any unrecognized token is an error; reply with usage and stop:

```
Usage: /wiki-migrate [--dry-run] [--skip-schema-update] [--force] [--vault <path>]
```

## Step 2: Resolve the vault

Same 3-tier resolution as `/wiki-query`, `/wiki-clip`, and `/wiki-gc`:

1. `--vault <path>` → verify `WIKI.md` exists
2. `EXOMEMORY_VAULT` env var (fall back to `CLAUDE_MEMORY_VAULT` with deprecation warning)
3. Ancestor search from `pwd`

Stop with a clear error if no vault is resolved. Call the resolved absolute path `VAULT`.

## Step 3: Wait for in-progress auto-ingest

Migration writes frontmatter that `/wiki-ingest` may also be updating on a background session. Overlap is unsafe — wait for the lock.

```bash
LOCK="$VAULT/.ingest.lock"
WAIT_TIMEOUT=300
waited=0
while [ -f "$LOCK" ]; do
  pid=$(cat "$LOCK" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
    echo "[wiki-migrate] auto-ingest still running after ${WAIT_TIMEOUT}s, aborting" >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
```

## Step 4: Locate the plugin template

`/wiki-init` installs the template at the plugin root. We need access to the v0.4 `WIKI.md` and `wiki/dashboards/` that will be copied into the vault.

```bash
# Resolve the plugin template directory. The slash command runs under the plugin's
# working directory, so CLAUDE_PLUGIN_ROOT is set by the plugin runtime.
TEMPLATE_DIR="${CLAUDE_PLUGIN_ROOT}/template"
if [ ! -f "$TEMPLATE_DIR/WIKI.md" ]; then
  echo "[wiki-migrate] plugin template not found at $TEMPLATE_DIR" >&2
  exit 1
fi
```

## Step 5: Enumerate wiki source pages

```bash
SOURCES_DIR="$VAULT/wiki/sources"
if [ ! -d "$SOURCES_DIR" ]; then
  echo "No wiki/sources/ directory; nothing to migrate."
  exit 0
fi

pages=$(find "$SOURCES_DIR" -maxdepth 1 -type f -name '*.md' | sort)
page_count=$(printf '%s\n' "$pages" | grep -c . || true)
echo "Found $page_count source pages to process"
```

## Step 6: For each page, recompute derived fields and merge frontmatter

The per-page logic is implemented in bash with small awk helpers. Counters are accumulated for the summary.

```bash
DRY_RUN="${DRY_RUN:-0}"   # set by Step 1 based on --dry-run flag

processed=0
changed=0
orphan=0
error=0

# helper: extract a scalar value for <key> from a YAML frontmatter block in stdin
fm_get() {
  awk -v k="$1" '
    /^---$/ { state++; next }
    state==1 {
      # match "key: value" or "key:value"
      if (match($0, /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:/)) {
        line_key = substr($0, 1, RLENGTH-1)
        gsub(/[[:space:]]+$/, "", line_key)
        if (line_key == k) {
          val = substr($0, RLENGTH+1)
          sub(/^[[:space:]]*/, "", val)
          sub(/[[:space:]]+$/, "", val)
          # strip surrounding quotes
          if (val ~ /^".*"$/ || val ~ /^\x27.*\x27$/) val = substr(val, 2, length(val)-2)
          print val
          exit
        }
      }
    }
  '
}

# helper: strip frontmatter from stdin and print body
body_of() {
  awk '
    BEGIN { state = 0 }
    state == 0 && /^---$/ { state = 1; next }
    state == 1 && /^---$/ { state = 2; next }
    state == 0 { print; next }   # no frontmatter at all, pass through
    state == 2 { print }
  '
}

# helper: count words (whitespace tokens) in stdin
count_words() {
  tr -s '[:space:]' '\n' | grep -c . || echo 0
}

# helper: ceil division
ceil_div() {
  local n="$1" d="$2"
  echo $(( (n + d - 1) / d ))
}

# helper: map source_id prefix → source_type
map_source_type() {
  case "$1" in
    handovers/*) echo handover ;;
    web/*)       echo web-clip ;;
    *)           echo manual ;;
  esac
}

# helper: lowercased host from URL
extract_domain() {
  printf '%s' "$1" \
    | sed -E 's#^[a-zA-Z]+://##' \
    | sed -E 's#/.*$##' \
    | sed -E 's#:[0-9]+$##' \
    | tr '[:upper:]' '[:lower:]'
}
```

Now iterate over pages. For each page:

```bash
for page in $pages; do
  processed=$((processed + 1))
  page_fm=$(awk '/^---$/{c++; print; next} c==1{print} c==2{exit}' "$page")
  source_id=$(printf '%s\n' "$page_fm" | fm_get source_id)
  source_hash=$(printf '%s\n' "$page_fm" | fm_get source_hash)

  if [ -z "$source_id" ]; then
    echo "[error] $page: no source_id, skipping" >&2
    error=$((error + 1))
    {
      printf '\n## [%s] MIGRATE-ERROR | %s\n' "$(date +%Y-%m-%d)" "$(basename "$page" .md)"
    } >> "$VAULT/wiki/log.md"
    continue
  fi

  raw_file="$VAULT/raw/$source_id"
  if [ ! -f "$raw_file" ]; then
    orphan=$((orphan + 1))
    {
      printf '\n## [%s] MIGRATE-ORPHAN | %s\n' "$(date +%Y-%m-%d)" "$(basename "$page" .md)"
    } >> "$VAULT/wiki/log.md"
    continue
  fi

  # Derived values
  source_type=$(map_source_type "$source_id")
  word_count=$(body_of < "$raw_file" | count_words)
  reading_time_min=$(ceil_div "$word_count" 200)

  session_id=""
  if [ "$source_type" = "handover" ]; then
    # source_id is handovers/<id>.md → session_id = <id>
    session_id=$(printf '%s' "$source_id" | sed -E 's#^handovers/##; s#\.md$##')
  fi

  source_url="" domain="" captured_at="" captured_by=""
  if [ "$source_type" = "web-clip" ]; then
    raw_fm=$(awk '/^---$/{c++; print; next} c==1{print} c==2{exit}' "$raw_file")
    source_url=$(printf '%s\n' "$raw_fm" | fm_get source_url)
    captured_at=$(printf '%s\n' "$raw_fm" | fm_get captured_at)
    captured_by=$(printf '%s\n' "$raw_fm" | fm_get captured_by)
    [ -z "$captured_by" ] && captured_by="unknown"
    [ -n "$source_url" ] && domain=$(extract_domain "$source_url")
  fi

  # Rewrite frontmatter in place (or just check diff if --dry-run). Python handles
  # all parsing, merging, writing, and emits a single status word on stdout so
  # command substitution doesn't mangle newlines in the file itself.
  status=$(DRY_RUN="$DRY_RUN" python3 - "$page" "$source_type" "$word_count" "$reading_time_min" \
                       "$session_id" "$source_url" "$domain" "$captured_at" "$captured_by" <<'PYEOF'
import os, sys, re, pathlib
from collections import OrderedDict

page, source_type, word_count, reading_time_min, session_id, source_url, domain, captured_at, captured_by = sys.argv[1:10]
dry_run = os.environ.get("DRY_RUN", "0") == "1"

text = pathlib.Path(page).read_text(encoding="utf-8")
m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
if not m:
    print("PARSE_ERROR")
    sys.exit(0)
fm_block, body = m.group(1), m.group(2)

existing = OrderedDict()
for i, line in enumerate(fm_block.split("\n")):
    km = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$", line)
    if km:
        existing[km.group(1)] = line
    else:
        existing[f"__raw_{i}__"] = line

def setkv(k, v):
    if v == "" or v is None:
        existing.pop(k, None)
        return
    existing[k] = f"{k}: {v}"

setkv("source_type", source_type)
setkv("word_count", word_count)
setkv("reading_time_min", reading_time_min)
if source_type == "handover" and session_id:
    setkv("session_id", session_id)
if source_type == "web-clip":
    setkv("source_url", source_url)
    setkv("domain", domain)
    setkv("captured_at", captured_at)
    setkv("captured_by", captured_by)

new_fm_block = "\n".join(existing.values())
new_text = f"---\n{new_fm_block}\n---\n{body}"

if new_text == text:
    print("UNCHANGED")
else:
    if not dry_run:
        pathlib.Path(page).write_text(new_text, encoding="utf-8")
    print("CHANGED")
PYEOF
)

  case "$status" in
    PARSE_ERROR)
      echo "[error] $page: failed to parse frontmatter" >&2
      error=$((error + 1))
      if [ "$DRY_RUN" = "0" ]; then
        printf '\n## [%s] MIGRATE-ERROR | %s\n' "$(date +%Y-%m-%d)" "$(basename "$page" .md)" >> "$VAULT/wiki/log.md"
      fi
      ;;
    CHANGED)
      changed=$((changed + 1))
      ;;
    UNCHANGED)
      :
      ;;
    *)
      echo "[error] $page: unexpected status from migration helper: $status" >&2
      error=$((error + 1))
      ;;
  esac
done
```

## Step 7: Update WIKI.md via schema marker (unless `--skip-schema-update`)

```bash
if [ "$SKIP_SCHEMA_UPDATE" != "1" ]; then
  vault_wiki="$VAULT/WIKI.md"
  template_wiki="$TEMPLATE_DIR/WIKI.md"
  first_line=$(head -n 1 "$vault_wiki" 2>/dev/null || true)

  if [ "$first_line" = "<!-- exomemory2-schema: v0.9 -->" ]; then
    echo "WIKI.md already at schema v0.9, no update needed"
  else
    if [ "$DRY_RUN" = "0" ]; then
      if [ -f "$vault_wiki.bak" ]; then
        mv "$vault_wiki.bak" "$vault_wiki.bak.$(date +%s)"
      fi
      cp "$vault_wiki" "$vault_wiki.bak"
      cp "$template_wiki" "$vault_wiki"
      echo "WIKI.md upgraded to schema v0.9 (backup: WIKI.md.bak)"
    else
      echo "[dry-run] would upgrade WIKI.md to schema v0.9"
    fi
  fi
fi
```

## Step 8: Copy dashboards if missing (unless `--skip-schema-update`)

Existing dashboard files are never overwritten — only missing ones are added.

```bash
if [ "$SKIP_SCHEMA_UPDATE" != "1" ]; then
  template_dashboards="$TEMPLATE_DIR/wiki/dashboards"
  vault_dashboards="$VAULT/wiki/dashboards"
  if [ -d "$template_dashboards" ]; then
    [ "$DRY_RUN" = "0" ] && mkdir -p "$vault_dashboards"
    added_dash=0
    for f in "$template_dashboards"/*.md; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      if [ ! -e "$vault_dashboards/$name" ]; then
        if [ "$DRY_RUN" = "0" ]; then
          cp "$f" "$vault_dashboards/$name"
        fi
        added_dash=$((added_dash + 1))
      fi
    done
    echo "Dashboards: $added_dash new, $(($(ls "$template_dashboards"/*.md 2>/dev/null | wc -l) - added_dash)) already present"
  fi
fi
```

## Step 9: Insert decorative sections into index.md (v0.5+)

Add the template's decorative sections to the vault's `wiki/index.md` if missing. Driven by a sections list (heatmap, calendar) so v0.7+ can add more entries here without refactoring. The decision flow is conservative — customized indexes are never overwritten without `--force`.

**Current sections (v0.6):**
| # | Heading | Anchor (insert after) | Introduced |
|---|---------|-----------------------|------------|
| 1 | `## Activity heatmap` | `# Index` (H1, stricter anchor detection) | v0.5 |
| 2 | `## Handover calendar` | `## Activity heatmap` (H2) | v0.6 |

Each section is evaluated independently:
- **Already present** (heading found in vault) → skip (no-op, idempotent case)
- **Missing, anchor present** → insert the block immediately after the anchor section's content
- **Missing, anchor not found** → skip + warning by default; `--force` prepends the block to the file top (after YAML frontmatter if any)

Sections are processed in order, so inserting heatmap in the same run unlocks the calendar's anchor.

```bash
vault_index="$VAULT/wiki/index.md"
template_index="$TEMPLATE_DIR/wiki/index.md"
index_updated=0
index_status=""

if [ ! -f "$vault_index" ]; then
  # Vault has no index.md at all (e.g. pre-v0.3) — copy the full template
  if [ "$DRY_RUN" = "0" ]; then
    mkdir -p "$VAULT/wiki"
    cp "$template_index" "$vault_index"
  fi
  index_status="created index.md from template"
  index_updated=1
else
  index_status=$(python3 - "$vault_index" "$template_index" "$DRY_RUN" "$FORCE" <<'PYEOF'
import sys, pathlib, re

vault_path, template_path, dry_run, force = sys.argv[1:5]
dry_run = dry_run == "1"
force = force == "1"

# Sections to maintain on index.md, ordered. `anchor_level=1` triggers strict
# "first non-blank non-frontmatter line" detection; level=2 is a simple heading match.
SECTIONS = [
    {"heading": "## Activity heatmap", "anchor": "# Index",           "anchor_level": 1},
    {"heading": "## Handover calendar", "anchor": "## Activity heatmap", "anchor_level": 2},
]

original_text = pathlib.Path(vault_path).read_text(encoding="utf-8")
template_text = pathlib.Path(template_path).read_text(encoding="utf-8")

def extract_block(text, heading):
    """Extract a section (heading line through the line before the next `## ` heading, or EOF)."""
    h_esc = re.escape(heading)
    m = re.search(rf"({h_esc}\n.*?)(?=^## |\Z)", text, re.S | re.M)
    if not m:
        return None
    return m.group(1).rstrip() + "\n\n"

def skip_frontmatter_and_blanks(lines):
    i = 0
    if lines and lines[0].rstrip("\n") == "---":
        for j in range(1, len(lines)):
            if lines[j].rstrip("\n") == "---":
                i = j + 1
                break
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    return i

def find_h1_anchor(lines, heading):
    """Return index of the heading if it's the first non-blank non-frontmatter line; else -1."""
    i = skip_frontmatter_and_blanks(lines)
    if i < len(lines) and lines[i].rstrip("\n").rstrip() == heading:
        return i
    return -1

def find_h2_anchor(lines, heading):
    """Return line index of an H2 heading matching exactly, or -1."""
    h = heading.rstrip()
    for idx, line in enumerate(lines):
        if line.rstrip("\n").rstrip() == h:
            return idx
    return -1

def content_end_after(lines, start_idx):
    """Given a heading line at start_idx, return position before the next `## ` heading (or EOF)."""
    k = start_idx + 1
    while k < len(lines) and not lines[k].startswith("## "):
        k += 1
    return k

lines = original_text.splitlines(keepends=True)
messages = []
any_change = False

for section in SECTIONS:
    heading = section["heading"]
    anchor = section["anchor"]
    level = section["anchor_level"]

    # Idempotent skip: heading already in the file
    if any(line.rstrip("\n").rstrip() == heading for line in lines):
        messages.append(f"{heading}: already present")
        continue

    block = extract_block(template_text, heading)
    if block is None:
        messages.append(f"{heading}: error — template missing section")
        continue

    anchor_idx = find_h1_anchor(lines, anchor) if level == 1 else find_h2_anchor(lines, anchor)

    if anchor_idx >= 0:
        insert_at = content_end_after(lines, anchor_idx)
        block_lines = block.splitlines(keepends=True)
        lines = lines[:insert_at] + block_lines + lines[insert_at:]
        messages.append(f"{heading}: inserted after `{anchor}`")
        any_change = True
    elif force:
        p = skip_frontmatter_and_blanks(lines)
        block_lines = block.splitlines(keepends=True)
        lines = lines[:p] + block_lines + lines[p:]
        messages.append(f"{heading}: prepended via --force (anchor `{anchor}` not found)")
        any_change = True
    else:
        messages.append(f"{heading}: WARN — anchor `{anchor}` not found, skipped (use --force to prepend)")

new_text = "".join(lines)

if any_change and new_text != original_text and not dry_run:
    pathlib.Path(vault_path + ".bak").write_text(original_text, encoding="utf-8")
    pathlib.Path(vault_path).write_text(new_text, encoding="utf-8")

for msg in messages:
    prefix = "(dry-run) " if dry_run and any_change else ""
    print(prefix + msg)
PYEOF
)
  if echo "$index_status" | grep -q -E '(inserted|prepended)'; then
    index_updated=1
  fi
fi

echo "index.md:"
echo "$index_status" | sed 's/^/  /'
```

## Step 9.5: Install Calendar CSS snippet (v0.8.2+)

Place the bundled CSS snippet in the vault's `.obsidian/snippets/` directory and ensure it is enabled in `appearance.json`. The snippet caps the Handover calendar's day cell height so dense days don't push the monthly grid out of alignment.

Idempotent: re-running this step on a vault that already has the snippet does not duplicate-write or duplicate-enable.

```bash
snippet_count=0
snippet_msg="up-to-date"
if [ "$DRY_RUN" = "0" ]; then
  src="${TEMPLATE_DIR}/.obsidian/snippets/exomemory2-calendar.css"
  dst_dir="${VAULT}/.obsidian/snippets"
  dst="${dst_dir}/exomemory2-calendar.css"
  appearance="${VAULT}/.obsidian/appearance.json"
  if [ -f "$src" ]; then
    mkdir -p "$dst_dir"
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      snippet_count=1
      snippet_msg="installed/updated"
    fi
    # Ensure enabledCssSnippets includes "exomemory2-calendar".
    if [ -f "$appearance" ]; then
      cp "$appearance" "${appearance}.bak"
      jq --arg s "exomemory2-calendar" \
        '.enabledCssSnippets = ((.enabledCssSnippets // []) + [$s] | unique)' \
        "$appearance" > "${appearance}.tmp" && mv "${appearance}.tmp" "$appearance"
    else
      mkdir -p "$(dirname "$appearance")"
      printf '{\n  "enabledCssSnippets": ["exomemory2-calendar"]\n}\n' > "$appearance"
    fi
  else
    snippet_msg="template snippet missing (skipped)"
  fi
fi
echo "calendar snippet: $snippet_msg"
```

## Step 9.6: Backfill `last_captured_at` for pre-v0.8.2 handovers

Before v0.8.2, `handover-build.sh` set `last_captured_at` to the current UTC time, which caused all rebuilt handovers to cluster on a single day in the calendar after an orphan rescue run. v0.8.2 onwards reads the timestamp from the transcript's first message and tags the handover with `captured_at_source: "transcript-first-message"`.

This step rewrites any handover lacking that tag, **only when** the source transcript still has a usable timestamp. Idempotent (already-tagged handovers are skipped; transcripts without timestamps are skipped to avoid `fallback-now` thrashing).

```bash
backfill_done=0
backfill_skipped_current=0
backfill_skipped_no_transcript=0
backfill_skipped_no_timestamp=0

if [ "$DRY_RUN" = "0" ]; then
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/lib/handover-build.sh"
  for f in "$VAULT/raw/handovers/"*.md; do
    [ -f "$f" ] || continue
    if grep -q '^captured_at_source: "transcript-first-message"$' "$f"; then
      backfill_skipped_current=$((backfill_skipped_current + 1))
      continue
    fi
    sid="$(basename "$f" .md)"
    transcript="$(find "$HOME/.claude/projects" -maxdepth 4 -type f -name "${sid}.jsonl" -not -path '*/subagents/*' -print -quit 2>/dev/null)"
    if [ -z "$transcript" ]; then
      backfill_skipped_no_transcript=$((backfill_skipped_no_transcript + 1))
      continue
    fi
    ts="$(jq -r 'select((.type == "user" or .type == "assistant") and (.timestamp != null)) | .timestamp' "$transcript" 2>/dev/null | head -n 1)"
    if [ -z "$ts" ]; then
      backfill_skipped_no_timestamp=$((backfill_skipped_no_timestamp + 1))
      continue
    fi
    if build_handover "$VAULT" "$transcript" "$sid" "wiki-migrate-backfill"; then
      backfill_done=$((backfill_done + 1))
    fi
  done
fi
echo "captured_at backfill: done=$backfill_done already=$backfill_skipped_current no-transcript=$backfill_skipped_no_transcript no-ts=$backfill_skipped_no_timestamp"
```

## Step 9.7: v0.9 entity/concept confidence backfill

For every `wiki/entities/*.md` and `wiki/concepts/*.md`, recompute and upsert `sources` / `last_verified` / `confidence` per the v0.9 schema. Idempotent — re-runs produce no diff once the page is already at v0.9.

`scripts/migrate-entity-confidence.py` is stdlib-only Python (no PyYAML). Pages with nested YAML in their frontmatter are skipped with a warning; everything else is processed in place.

```bash
confidence_changed=0
confidence_unchanged=0
confidence_skipped_nested=0
confidence_parse_error=0

if [ -d "$VAULT/wiki/entities" ] || [ -d "$VAULT/wiki/concepts" ]; then
  args=("$VAULT")
  [ "$DRY_RUN" = "1" ] && args+=("--dry-run")
  out=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-entity-confidence.py" "${args[@]}" 2>&1) || true
  while IFS= read -r line; do
    case "$line" in
      "CHANGED "*)         confidence_changed=$((confidence_changed + 1)) ;;
      "UNCHANGED "*)       confidence_unchanged=$((confidence_unchanged + 1)) ;;
      "SKIPPED-NESTED "*)  confidence_skipped_nested=$((confidence_skipped_nested + 1)) ;;
      "PARSE-ERROR "*)     confidence_parse_error=$((confidence_parse_error + 1)) ;;
    esac
  done <<<"$out"
  if [ "$DRY_RUN" = "0" ] && [ "$confidence_changed" -gt 0 ]; then
    today=$(date +%Y-%m-%d)
    while IFS= read -r line; do
      case "$line" in
        "CHANGED "*)
          slug=$(printf '%s' "$line" | sed -E 's#^CHANGED .*/([^/]+)\.md$#\1#')
          printf '\n## [%s] MIGRATE-CONFIDENCE | %s\n' "$today" "$slug" >> "$VAULT/wiki/log.md"
          ;;
      esac
    done <<<"$out"
  fi
fi
echo "entity-confidence backfill: changed=$confidence_changed unchanged=$confidence_unchanged skipped-nested=$confidence_skipped_nested parse-error=$confidence_parse_error"
```

## Step 9.8: v0.9 typed-Connections retrofit

For every `wiki/entities/*.md` and `wiki/concepts/*.md`, prefix any bare `- [[X]] ...` line in `## Connections` with `- related_to:: `. Lines that already use a vocabulary key (`depends_on::` / `contradicts::` / `caused_by::` / `fixed_in::` / `supersedes::` / `related_to::`) and any custom lines (e.g. `- (memo) [[X]]`) are left untouched. Idempotent.

```bash
typed_changed=0
typed_unchanged=0
typed_no_connections=0
typed_parse_error=0

if [ -d "$VAULT/wiki/entities" ] || [ -d "$VAULT/wiki/concepts" ]; then
  args=("$VAULT")
  [ "$DRY_RUN" = "1" ] && args+=("--dry-run")
  out=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-typed-connections.py" "${args[@]}" 2>&1) || true
  while IFS= read -r line; do
    case "$line" in
      "CHANGED "*)         typed_changed=$((typed_changed + 1)) ;;
      "UNCHANGED "*)       typed_unchanged=$((typed_unchanged + 1)) ;;
      "NO-CONNECTIONS "*)  typed_no_connections=$((typed_no_connections + 1)) ;;
      "PARSE-ERROR "*)     typed_parse_error=$((typed_parse_error + 1)) ;;
    esac
  done <<<"$out"
  if [ "$DRY_RUN" = "0" ] && [ "$typed_changed" -gt 0 ]; then
    today=$(date +%Y-%m-%d)
    while IFS= read -r line; do
      case "$line" in
        "CHANGED "*)
          slug=$(printf '%s' "$line" | sed -E 's#^CHANGED .*/([^/]+)\.md$#\1#')
          printf '\n## [%s] MIGRATE-CONNECTIONS | %s\n' "$today" "$slug" >> "$VAULT/wiki/log.md"
          ;;
      esac
    done <<<"$out"
  fi
fi
echo "typed-connections retrofit: changed=$typed_changed unchanged=$typed_unchanged no-connections=$typed_no_connections parse-error=$typed_parse_error"
```

## Step 9.9: v0.9.1 index.md section reorder

Reorder the three content sections in `wiki/index.md` to **Concepts → Entities → Sources** (so the conceptual layer reads first, raw sources last). Idempotent — runs only when the current order differs from the desired one. Skips when any of the three sections is missing or when a foreign H2 sits between them (treated as a customized index, never reordered without manual intent).

```bash
order_changed=0
order_unchanged=0
order_missing=0
order_no_index=0

args=("$VAULT")
[ "$DRY_RUN" = "1" ] && args+=("--dry-run")
out=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-index-order.py" "${args[@]}" 2>&1) || true
while IFS= read -r line; do
  case "$line" in
    "CHANGED "*)           order_changed=1 ;;
    "UNCHANGED "*)         order_unchanged=1 ;;
    "MISSING-SECTIONS "*)  order_missing=1 ;;
    "NO-INDEX "*)          order_no_index=1 ;;
  esac
done <<<"$out"

if [ "$DRY_RUN" = "0" ] && [ "$order_changed" = "1" ]; then
  printf '\n## [%s] MIGRATE-INDEX-ORDER | reordered\n' "$(date +%Y-%m-%d)" >> "$VAULT/wiki/log.md"
fi

case "1" in
  $order_changed)      echo "index-order: reordered to Concepts → Entities → Sources" ;;
  $order_unchanged)    echo "index-order: already correct" ;;
  $order_missing)      echo "index-order: skipped (missing section or foreign H2 between trio)" ;;
  $order_no_index)     echo "index-order: skipped (no index.md)" ;;
  *)                   echo "index-order: unknown state" ;;
esac
```

## Step 10: Log and summarize

Append a single summary line to `<VAULT>/wiki/log.md` (skipped in `--dry-run`):

```bash
if [ "$DRY_RUN" = "0" ]; then
  today=$(date +%Y-%m-%d)
  mkdir -p "$VAULT/wiki"
  printf '\n## [%s] MIGRATE | processed=%d, changed=%d, orphan=%d, error=%d, index_updated=%d, snippet=%d, backfill=%d, confidence_changed=%d, typed_changed=%d, order_changed=%d\n' \
    "$today" "$processed" "$changed" "$orphan" "$error" "$index_updated" "$snippet_count" "$backfill_done" "$confidence_changed" "$typed_changed" "$order_changed" >> "$VAULT/wiki/log.md"
fi

cat <<EOF
Migration complete.
  Processed: $processed pages
  Changed:   $changed pages
  Orphan:    $orphan (wiki page exists but raw file missing — logged as MIGRATE-ORPHAN)
  Error:     $error (frontmatter parse failure — logged as MIGRATE-ERROR)
  Index:     updated=$index_updated
  Calendar snippet: $snippet_msg
  Captured_at backfill: $backfill_done handovers (skipped: $backfill_skipped_current already-current, $backfill_skipped_no_transcript no-transcript, $backfill_skipped_no_timestamp no-timestamp)
  v0.9 entity confidence: changed=$confidence_changed, unchanged=$confidence_unchanged, skipped-nested=$confidence_skipped_nested, parse-error=$confidence_parse_error
  v0.9 typed Connections: changed=$typed_changed, unchanged=$typed_unchanged, no-connections=$typed_no_connections, parse-error=$typed_parse_error
  v0.9.1 index order: changed=$order_changed
EOF
```

## Notes

- **Idempotency**: re-running on the same vault produces `changed=0` because derived fields are pure functions of raw content and `source_id`
- **Bugfix propagation**: if a future release fixes a derived-field computation bug, re-running `/wiki-migrate` automatically reconciles all pages — there is no "frozen bad value" risk
- **Raw files are never modified** — the command reads raw to compute derived values but does not write to `raw/`
- **Body preservation**: only the frontmatter block (everything between the first two `---` lines) is touched. Summary / Key Claims / Connections sections are left intact
- **User-added frontmatter keys are preserved** — only the known derived keys (`source_type`, `word_count`, `reading_time_min`, `session_id`, `source_url`, `domain`, `captured_at`, `captured_by`) and the pre-existing v0.3 keys (`title`, `type`, `tags`, `source_id`, `source_hash`, `last_updated`) are recognized; everything else is passed through unchanged
- **Dependency**: `python3` (macOS/Linux default). No `yq` required
- Run `--dry-run` first on a real vault to see what would change; run without flags once satisfied
