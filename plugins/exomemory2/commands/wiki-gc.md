---
description: Garbage-collect orphan images from raw/assets/ (logical delete to .trash/, physical delete after N days)
argument-hint: "[--dry-run] [--purge-older-than <days>] [--vault <path>]"
allowed-tools: Bash, Read, Glob, Grep
---

# /wiki-gc

Scan `<VAULT>/raw/assets/` (the content-addressed image pool used by web clips) and move any files that no `raw/**/*.md` still references into `<VAULT>/raw/assets/.trash/<YYYY-MM-DD>/`. Entries in `.trash/` older than the configured retention window are then physically deleted.

Hash-based dedup means one image file can be referenced from many raw sources; an asset is an orphan only if **zero** raw sources reference it. The scan covers both relative-path references (`./assets/<hash>.<ext>`, `../assets/<hash>.<ext>`) and Obsidian wikilink references (`![[<hash>.<ext>]]`).

Logical delete gives a 90-day recovery window by default — if you find that something important was moved, restore from `.trash/` before the purge threshold.

## Arguments

```
$ARGUMENTS
```

## Step 1: Parse arguments

Tokenize `$ARGUMENTS`. Extract:

- `--vault <path>` — optional explicit vault override
- `--dry-run` — report only; do not move or delete any files
- `--purge-older-than <days>` — retention window for `.trash/` entries (default: `90`)

Any unrecognized token is an error; reply with usage:

```
Usage: /wiki-gc [--dry-run] [--purge-older-than <days>] [--vault <path>]
```

## Step 2: Resolve the vault

Same 3-tier resolution as `/wiki-query` and `/wiki-clip`:

1. `--vault <path>` → verify `WIKI.md` exists
2. `EXOMEMORY_VAULT` env var (fall back to `CLAUDE_MEMORY_VAULT` with deprecation warning)
3. Ancestor search from `pwd`

Stop with a clear error if no vault is resolved. Call the resolved absolute path `VAULT`.

## Step 3: Wait for in-progress auto-ingest

Same policy as `/wiki-clip`: if `<VAULT>/.ingest.lock` is held by a live PID, wait up to 5 minutes for it to clear. GC modifies `raw/assets/` which `/wiki-clip` may be writing to, so overlap is unsafe.

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
    echo "[wiki-gc] auto-ingest still running after ${WAIT_TIMEOUT}s, aborting" >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
```

## Step 4: Short-circuit if no assets directory

```bash
ASSETS="$VAULT/raw/assets"
if [ ! -d "$ASSETS" ]; then
  echo "No raw/assets/ directory; nothing to GC."
  exit 0
fi
```

## Step 5: Collect the referenced hash set

Scan every Markdown file under `<VAULT>/raw/` (excluding the `.trash/` subtree) for asset references and extract the `<sha256>.<ext>` basename.

Two reference shapes are supported:

- `](../assets/<hash>.<ext>)` — relative Markdown link (the standard form `/wiki-clip` writes for files in `raw/web/`)
- `](./assets/<hash>.<ext>)` — relative link from a raw file at the root of `raw/` (future-proofing)
- `![[<hash>.<ext>]]` — Obsidian embed

The `grep` regex captures either form and yields a partial match that still includes the `./assets/`, `../assets/`, or `![[` prefix. Two `sed` commands with a `#` delimiter (avoiding the `|` collision with regex alternation) strip the prefix to leave just `<hash>.<ext>`.

```bash
tmp_refs=$(mktemp -t wiki-gc-refs.XXXXXX)

# Find all .md files under raw/ except those in any .trash/ directory
find "$VAULT/raw" -type d -name .trash -prune -o -type f -name '*.md' -print \
  | while IFS= read -r f; do
      grep -oE '(\.\.?/assets/|!\[\[)[a-f0-9]{64}\.[a-z0-9]+' "$f" 2>/dev/null \
        | sed -E 's#^\.\.?/assets/##; s#^!\[\[##' \
        || true
    done \
  | sort -u > "$tmp_refs"

ref_count=$(wc -l < "$tmp_refs" | tr -d ' ')
echo "Referenced assets: $ref_count unique hashes"
```

## Step 6: Collect the existing hash set

List every regular file directly under `raw/assets/` (NOT recursive — `.trash/` is a subdirectory that should not be included in the "existing" set).

```bash
tmp_exist=$(mktemp -t wiki-gc-exist.XXXXXX)
find "$ASSETS" -maxdepth 1 -type f -name '[a-f0-9]*' \
  | xargs -I {} basename {} \
  | sort -u > "$tmp_exist"

exist_count=$(wc -l < "$tmp_exist" | tr -d ' ')
echo "Existing assets: $exist_count files"
```

## Step 7: Compute orphans

```bash
tmp_orphans=$(mktemp -t wiki-gc-orphans.XXXXXX)
comm -23 "$tmp_exist" "$tmp_refs" > "$tmp_orphans"
orphan_count=$(wc -l < "$tmp_orphans" | tr -d ' ')
echo "Orphans (existing but unreferenced): $orphan_count"
```

## Step 8: If `--dry-run`, report and exit

```bash
if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "Sample orphans (first 10):"
  head -10 "$tmp_orphans"
  rm -f "$tmp_refs" "$tmp_exist" "$tmp_orphans"
  exit 0
fi
```

## Step 9: Logical delete — move orphans to `.trash/<today>/`

```bash
moved=0
if [ "$orphan_count" -gt 0 ]; then
  today=$(date '+%Y-%m-%d')
  trash_dir="$ASSETS/.trash/$today"
  mkdir -p "$trash_dir"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    src="$ASSETS/$name"
    dst="$trash_dir/$name"
    if [ -f "$src" ] && [ ! -e "$dst" ]; then
      mv "$src" "$dst"
      moved=$((moved + 1))
    fi
  done < "$tmp_orphans"
fi
```

## Step 10: Physical purge — drop `.trash/` entries older than N days

Default retention is 90 days. Each `.trash/<YYYY-MM-DD>/` directory is the unit of purge: if its date is older than `today - N days`, the whole directory is removed.

```bash
purge_days="${PURGE_OLDER_THAN:-90}"
purged=0
trash_root="$ASSETS/.trash"
if [ -d "$trash_root" ]; then
  # Compute the cutoff date as "YYYY-MM-DD" (macOS BSD date syntax)
  cutoff=$(date -v-"${purge_days}"d '+%Y-%m-%d')
  for d in "$trash_root"/*/; do
    [ -d "$d" ] || continue
    dname=$(basename "$d")
    # Directory name must parse as a date; skip anything else
    if [[ "$dname" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      if [ "$dname" \< "$cutoff" ]; then
        count_in_dir=$(find "$d" -type f | wc -l | tr -d ' ')
        rm -rf "$d"
        purged=$((purged + count_in_dir))
      fi
    fi
  done
fi
```

## Step 11: Log and report

Append a single line to `<VAULT>/wiki/log.md` (create the file if missing):

```bash
today=$(date '+%Y-%m-%d')
log_line="## [$today] GC | ${moved} moved, ${purged} purged"
mkdir -p "$VAULT/wiki"
printf '%s\n' "$log_line" >> "$VAULT/wiki/log.md"
```

Print a summary to stdout:

```
GC complete.
  Referenced assets: <N>
  Existing assets:   <M>
  Orphans moved to .trash/<today>/: <moved>
  Purged from .trash/ (older than <days>d): <purged>
```

Clean up temp files:

```bash
rm -f "$tmp_refs" "$tmp_exist" "$tmp_orphans"
```

## Notes

- GC is **non-destructive by default** — orphans go to `.trash/` first, with the directory name being the date of GC. Use `ls raw/assets/.trash/` to browse past purges
- The `raw/assets/.trash/` subtree is intentionally excluded from both the reference scan (Step 5) and the "existing" list (Step 6), so GC never sees its own trash as either orphans or references
- To recover a moved file before purge: `mv raw/assets/.trash/<date>/<hash>.<ext> raw/assets/`
- Running `/wiki-gc --dry-run` periodically is safe and cheap — it just reports counts and exits
- The GC does NOT touch `raw/web/` or `raw/handovers/`; only `raw/assets/` is in scope
- **Warning on hand-added assets**: if you manually drop a non-hash-named image into `raw/assets/` (e.g., `my-diagram.png`), the Step 6 `find` with `-name '[a-f0-9]*'` will skip it, so it's not touched by GC. But it also won't be deduped or referenced correctly — use the hash-name convention or drop images in a separate directory like `raw/static/` instead
