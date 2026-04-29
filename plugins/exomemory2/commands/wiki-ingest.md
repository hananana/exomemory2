---
description: Ingest raw sources into the wiki (CREATE/UPDATE/SKIP with dedup)
argument-hint: "[<raw-file-or-dir>] [--vault <path>] [--limit <N>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# /wiki-ingest

Bash-driven hot path. The LLM only intervenes for files that genuinely need new wiki content (CREATE / UPDATE). For the common case where every raw file is unchanged, this command is one bash call plus a one-line report.

## Arguments

```
$ARGUMENTS
```

## Step 1: Resolve vault + run preflight (single Bash call)

Resolve `VAULT` (priority: `--vault` arg → `EXOMEMORY_VAULT` env → ancestor search), then resolve `RAW_TARGET` (positional arg if given, else `${VAULT}/raw`), then invoke preflight. **Do this in one Bash call** — there is no value in running env checks as separate turns.

```bash
# Parse args
ARGS="$ARGUMENTS"
VAULT_OVERRIDE=""
RAW_ARG=""
LIMIT=""
set -- $ARGS
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_OVERRIDE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    *) RAW_ARG="${RAW_ARG:-$1}"; shift ;;
  esac
done

# Resolve vault
if [ -n "$VAULT_OVERRIDE" ]; then
  VAULT="$VAULT_OVERRIDE"
elif [ -n "${EXOMEMORY_VAULT:-}" ]; then
  VAULT="$EXOMEMORY_VAULT"
elif [ -n "${CLAUDE_MEMORY_VAULT:-}" ]; then
  VAULT="$CLAUDE_MEMORY_VAULT"
  echo "[wiki-ingest] CLAUDE_MEMORY_VAULT is deprecated, use EXOMEMORY_VAULT" >&2
else
  d="$(pwd)"
  while [ "$d" != "/" ]; do
    if [ -f "$d/WIKI.md" ]; then VAULT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi
if [ -z "${VAULT:-}" ] || [ ! -f "$VAULT/WIKI.md" ]; then
  echo "Vault not found. Set EXOMEMORY_VAULT, pass --vault <path>, or cd into a vault. Run /wiki-init <path> to create one."
  exit 1
fi

# Resolve raw target
if [ -z "$RAW_ARG" ]; then
  RAW_TARGET="$VAULT/raw"
else
  case "$RAW_ARG" in
    /*) RAW_TARGET="$RAW_ARG" ;;
    *)  RAW_TARGET="$VAULT/raw/$RAW_ARG" ;;
  esac
  case "$RAW_TARGET" in
    "$VAULT/raw"|"$VAULT/raw/"*) ;;
    *) echo "raw target outside vault/raw/: $RAW_TARGET"; exit 1 ;;
  esac
  [ ! -e "$RAW_TARGET" ] && { echo "raw target missing: $RAW_TARGET"; exit 1; }
fi

# Preflight: classifies every raw file and batch-appends SKIP / SKIP-empty
# lines to wiki/log.md.
MANIFEST="/tmp/ingest-manifest-$$.ndjson"
SUMMARY="/tmp/ingest-summary-$$.txt"
DIRTY="/tmp/ingest-dirty-$$.ndjson"
"${CLAUDE_PLUGIN_ROOT}/scripts/ingest-preflight.sh" "$VAULT" "$RAW_TARGET" \
  > "$MANIFEST" 2>"$SUMMARY"

# DIRTY: only the work the LLM has to do (CREATE/UPDATE).
# ERROR records (slug collisions) are tallied below and reported in Step 3
# without going through the per-file LLM loop — they require human triage,
# not generation. Keeping ERROR out of DIRTY also prevents starvation when
# --limit is used (otherwise stuck ERROR rows at the head of the list would
# block CREATE/UPDATE forever).
jq -c 'select(.op == "CREATE" or .op == "UPDATE")' "$MANIFEST" > "$DIRTY"

# Apply --limit to CREATE/UPDATE only. The whole point of --limit is to keep
# a single invocation small enough to terminate; ERROR is unaffected.
if [ -n "${LIMIT:-}" ] && [ "$LIMIT" -gt 0 ]; then
  full_work=$(awk 'END{print NR}' "$DIRTY")
  head -n "$LIMIT" "$DIRTY" > "$DIRTY.tmp" && mv "$DIRTY.tmp" "$DIRTY"
  kept=$(awk 'END{print NR}' "$DIRTY")
  echo "limited_to=$LIMIT (full_work=$full_work, deferred=$((full_work - kept)))"
fi

# ERROR tally for Step 3 (no LLM work).
ERROR_COUNT=$(jq -c 'select(.op == "ERROR")' "$MANIFEST" | awk 'END{print NR}')
ERROR_SLUGS=$(jq -r 'select(.op == "ERROR") | .slug' "$MANIFEST" | paste -sd, -)

echo "VAULT=$VAULT"
echo "MANIFEST=$MANIFEST"
echo "DIRTY=$DIRTY"
cat "$SUMMARY"
echo "dirty_count=$(awk 'END{print NR}' "$DIRTY")"
echo "error_count=$ERROR_COUNT"
echo "error_slugs=$ERROR_SLUGS"
```

The summary line `# preflight: total=N skip=X skip_empty=Y skip_asset=Z create=A update=B error=E dirty=D` tells the LLM whether work remains.

**If `dirty_count == 0`, jump straight to Step 3 and report — no per-file LLM work needed.**

## Step 2: Process dirty files (only when `dirty_count > 0`)

Skip this step entirely when no dirty files. Otherwise, read `WIKI.md` once for the schema (`Read /VAULT/WIKI.md`), then for each record in `$DIRTY`:

1. Read the raw file at the record's `path`.
2. Extract: title, summary (2-4 paragraphs), key claims, mentioned entities, mentioned concepts, contradictions vs existing wiki content.
3. **Use the derived frontmatter the preflight record already carries** (`source_type`, `word_count`, `reading_time_min`, plus `session_id` for handover or `source_url`/`captured_at`/`captured_by`/`domain` for web-clip). Do not recompute these.
4. Write `<VAULT>/wiki/sources/<slug>.md` (Source Page Format from WIKI.md). On **UPDATE** (record's `existing_page` set): merge frontmatter — overwrite only the derived fields above plus `title`, `tags`, `source_hash`, `last_updated`. **Preserve any other frontmatter keys the user added by hand.**
5. For each mentioned entity / concept: CREATE if missing, MERGE (append typed Connection + new About paragraph) if existing. Apply the **MERGE Rule decision tree** in WIKI.md when the new claim conflicts with existing About text. Connection bullets must use a typed key (`depends_on::` / `contradicts::` / `caused_by::` / `fixed_in::` / `supersedes::` / `related_to::`). When unsure, use `related_to::`.
6. **For each entity/concept page touched in step 5 (CREATE or MERGE), recompute `sources` and `confidence` (v0.9+)**:
   - `sources` = count of `wiki/sources/*.md` files containing `[[<entity-slug>]]`, `[[<entity-slug>|...]]`, or `[[<entity-slug>#...]]` (use `grep -l -E "\[\[<slug>(\\\||#|\\])"`)
   - `confidence` = `clamp(sources/5.0, 0.3, 1.0)` (= 0.3, 0.4, 0.6, 0.8, 1.0 for sources 1..5+); cap at 0.5 if the page's `## Connections` section contains at least one `- contradicts::` line
   - Set `last_verified` to today's date (`date +%Y-%m-%d`)
   - Write all three fields back into the page's frontmatter (preserve all other keys)
7. **Supersession check (v0.9+)**: scan the source body for the trigger phrases in WIKI.md "Supersession (v0.9+)". For each match where both X and Y resolve to wiki entity/concept slugs:
   - Old page X: set `stale: true`, `superseded_by: [[<Y-slug>]]`, `superseded_at: <today>`
   - New page Y: set `supersedes: [[<X-slug>]]`, add `- supersedes:: [[<X-slug>]]` to Y's Connections if not already present
   - Append `## [<today>] SUPERSEDE | <X-slug> -> <Y-slug>` to log.md
   - **Never delete the old page's body**
8. Update `<VAULT>/wiki/index.md`: append `- [[<slug>]] — <title>` under `## Sources` / `## Entities` / `## Concepts`. Do not duplicate. Never overwrite the file — preserve content above those sections (e.g. `## Activity heatmap`, `## Handover calendar`).
9. Update `<VAULT>/wiki/overview.md`: append / light revise. **Do not rewrite from scratch.**
10. Append to `<VAULT>/wiki/log.md`: `## [YYYY-MM-DD] CREATE | <slug>` (or `UPDATE` / `MERGE` / `SUPERSEDE`).

**SKIP and SKIP-empty are already in `log.md`** — preflight wrote them in batch before Step 1 returned. Do not re-emit them.

**ERROR records are not in `$DIRTY`.** They were tallied in Step 1 (`error_count` / `error_slugs` from the Bash output) and are reported in Step 3 as-is. ERROR means slug collision — distinct raw paths produced the same wiki slug — which requires human triage (rename one of the source files), not LLM action. Do not attempt to resolve them here.

## Step 3: Report

Use the preflight summary for SKIP / SKIP-empty / SKIP-asset counts. Use the Bash output's `error_count` / `error_slugs` for ERROR. Use your own bookkeeping from Step 2 for CREATE / UPDATE / MERGE. If the Step 1 Bash output included a `limited_to=...` line, mention how many records were deferred to the next run.

```
Ingest complete.
  CREATE: N sources, M entities, K concepts
  UPDATE: ...
  MERGE (entities/concepts): ...
  SKIP: ...
  SKIP-empty: ...
  ERROR: <error_count> (slug collisions: <error_slugs>) (if error_count > 0)
  DEFERRED: <deferred> (next run will pick these up) (if --limit kicked in)

Wiki: <VAULT>/wiki/
```

## Notes

- Write order per dirty file: entities/concepts MERGE → confidence/sources recompute → supersession check → index → overview → sources → log. If the source write fails, the wiki is still consistent.
- Be conservative with entity / concept MERGE: when unsure two names refer to the same thing, prefer separate pages.
- **Supersession is narrow on purpose** — only the explicit linguistic triggers in WIKI.md fire it. Do not invent your own (e.g. "X is better than Y" is **not** a trigger). False supersession damages future retrieval.
- **Connection types** — when a Connection clearly fits `depends_on` / `contradicts` / `caused_by` / `fixed_in` / `supersedes`, use that key. When unclear, use `related_to::` (the default catch-all). Never emit a bare `- [[X]]` line in v0.9+ ingests.
- **`confidence` is a derived field** — never invent or hand-write a value. Always compute it from `sources` and the `contradicts::` presence per the formula in WIKI.md.
- WIKI.md is the schema authority. If anything below disagrees, WIKI.md wins.
