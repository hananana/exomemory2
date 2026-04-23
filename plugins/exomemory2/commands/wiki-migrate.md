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
4. (v0.5) Insert an `## Activity heatmap` section into `wiki/index.md` if missing — see Step 10 for the decision flow

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

  if [ "$first_line" = "<!-- exomemory2-schema: v0.4 -->" ]; then
    echo "WIKI.md already at schema v0.4, no update needed"
  else
    if [ "$DRY_RUN" = "0" ]; then
      if [ -f "$vault_wiki.bak" ]; then
        mv "$vault_wiki.bak" "$vault_wiki.bak.$(date +%s)"
      fi
      cp "$vault_wiki" "$vault_wiki.bak"
      cp "$template_wiki" "$vault_wiki"
      echo "WIKI.md upgraded to schema v0.4 (backup: WIKI.md.bak)"
    else
      echo "[dry-run] would upgrade WIKI.md to schema v0.4"
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

## Step 9: Insert Activity heatmap into index.md (v0.5+)

Add the Contribution Graph heatmap section to the vault's `wiki/index.md` if missing. The decision flow is conservative — customized indexes are never overwritten without `--force`.

```bash
vault_index="$VAULT/wiki/index.md"
template_index="$TEMPLATE_DIR/wiki/index.md"
heatmap_inserted=0
heatmap_status=""

if [ ! -f "$vault_index" ]; then
  # (1) Vault has no index.md at all (e.g. pre-v0.3) — copy the full template
  if [ "$DRY_RUN" = "0" ]; then
    mkdir -p "$VAULT/wiki"
    cp "$template_index" "$vault_index"
  fi
  heatmap_status="created index.md from template"
  heatmap_inserted=1
elif grep -q '^## Activity heatmap$' "$vault_index"; then
  # (2) Section already present — no-op (idempotent case)
  heatmap_status="heatmap section already present"
else
  heatmap_status=$(python3 - "$vault_index" "$template_index" "$DRY_RUN" "$FORCE" <<'PYEOF'
import sys, pathlib, re

vault_path, template_path, dry_run, force = sys.argv[1:5]
dry_run = dry_run == "1"
force = force == "1"

vault_text = pathlib.Path(vault_path).read_text(encoding="utf-8")
template_text = pathlib.Path(template_path).read_text(encoding="utf-8")

# Extract the heatmap block from the template (from "## Activity heatmap" up to the next "## " heading, exclusive).
m = re.search(r"(## Activity heatmap\n.*?)(?=^## )", template_text, re.S | re.M)
if not m:
    print("error: template missing Activity heatmap section")
    sys.exit(2)
heatmap_block = m.group(1).rstrip() + "\n\n"

lines = vault_text.splitlines(keepends=True)
# Skip YAML frontmatter if present at file top
i = 0
if lines and lines[0].rstrip("\n") == "---":
    for j in range(1, len(lines)):
        if lines[j].rstrip("\n") == "---":
            i = j + 1
            break
# Skip blank lines
while i < len(lines) and lines[i].strip() == "":
    i += 1

# Anchor detection: first non-blank non-frontmatter line must be "# Index"
if i < len(lines) and lines[i].rstrip("\n").rstrip() == "# Index":
    anchor_idx = i
    # Insert heatmap block after the "# Index" heading and any existing intro paragraph.
    # Find the next section boundary: either the next heading (## ) or end of file.
    insert_at = anchor_idx + 1
    # Preserve the intro paragraph immediately following # Index (up to but not including first ## heading)
    k = insert_at
    while k < len(lines) and not lines[k].startswith("## "):
        k += 1
    insert_at = k

    new_lines = lines[:insert_at] + [heatmap_block] + lines[insert_at:]
    new_text = "".join(new_lines)
    if not dry_run:
        pathlib.Path(vault_path + ".bak").write_text(vault_text, encoding="utf-8")
        pathlib.Path(vault_path).write_text(new_text, encoding="utf-8")
    print("inserted after `# Index` anchor" + (" (dry-run)" if dry_run else ""))
elif force:
    # --force: prepend heatmap to the file (after frontmatter if any)
    prepend_at = i  # after frontmatter + blanks
    new_lines = lines[:prepend_at] + [heatmap_block] + lines[prepend_at:]
    new_text = "".join(new_lines)
    if not dry_run:
        pathlib.Path(vault_path + ".bak").write_text(vault_text, encoding="utf-8")
        pathlib.Path(vault_path).write_text(new_text, encoding="utf-8")
    print("prepended via --force (anchor `# Index` not found)" + (" (dry-run)" if dry_run else ""))
else:
    print("WARN: index.md: cannot locate `# Index` anchor (customized). Paste the Activity heatmap block manually, or re-run with --force to prepend.")
PYEOF
)
  case "$heatmap_status" in
    inserted*|prepended*) heatmap_inserted=1 ;;
    WARN*) heatmap_inserted=0 ;;
    error*) echo "[error] $heatmap_status" >&2 ;;
  esac
fi

echo "index.md: $heatmap_status"
```

## Step 10: Log and summarize

Append a single summary line to `<VAULT>/wiki/log.md` (skipped in `--dry-run`):

```bash
if [ "$DRY_RUN" = "0" ]; then
  today=$(date +%Y-%m-%d)
  mkdir -p "$VAULT/wiki"
  printf '\n## [%s] MIGRATE | processed=%d, changed=%d, orphan=%d, error=%d, heatmap=%d\n' \
    "$today" "$processed" "$changed" "$orphan" "$error" "$heatmap_inserted" >> "$VAULT/wiki/log.md"
fi

cat <<EOF
Migration complete.
  Processed: $processed pages
  Changed:   $changed pages
  Orphan:    $orphan (wiki page exists but raw file missing — logged as MIGRATE-ORPHAN)
  Error:     $error (frontmatter parse failure — logged as MIGRATE-ERROR)
  Heatmap:   $heatmap_status
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
