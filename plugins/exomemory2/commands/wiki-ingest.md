---
description: Ingest raw sources into the wiki (CREATE/UPDATE/SKIP with dedup)
argument-hint: "[<raw-file-or-dir>] [--vault <path>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task
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
set -- $ARGS
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT_OVERRIDE="$2"; shift 2 ;;
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
jq -c 'select(.op == "CREATE" or .op == "UPDATE" or .op == "ERROR")' "$MANIFEST" > "$DIRTY"

echo "VAULT=$VAULT"
echo "MANIFEST=$MANIFEST"
echo "DIRTY=$DIRTY"
cat "$SUMMARY"
echo "dirty_count=$(wc -l < "$DIRTY")"
```

The summary line `# preflight: total=N skip=X skip_empty=Y skip_asset=Z create=A update=B error=E dirty=D` tells the LLM whether work remains.

**If `dirty_count == 0`, jump straight to Step 3 and report — no per-file LLM work needed.**

## Step 2: Process dirty files (only when `dirty_count > 0`)

Skip this step entirely when no dirty files. Otherwise read `WIKI.md` once (`Read $VAULT/WIKI.md`) for the schema, then proceed.

### Step 2.1: Extract content (parallel subagents when `dirty_count >= 2`)

Extraction (raw read → structured fields) is **read-only** — the per-file work has no shared state. Parallelize it via subagents to avoid serial LLM round-trips per dirty file.

- **`dirty_count == 1`**: inline the extraction in the main context. The single subagent overhead would not pay off.
- **`dirty_count >= 2`**: in **one** assistant message, invoke `Task` (`subagent_type=general-purpose`) **once per dirty record**, in parallel. Each subagent is given the prompt template below filled in with the record's fields, and returns ONE JSON object on stdout.

Subagent prompt template (substitute `<...>`):

```
Extract structured wiki content from a single raw source for /wiki-ingest.

Inputs:
- raw_path: <path>
- existing_wiki_page: <existing_page or "">  # set on UPDATE, empty on CREATE
- vault_wiki_dir: <VAULT>/wiki  # for cross-checking entities/concepts that already exist

Steps:
1. Read raw_path.
2. If existing_wiki_page is set, read it to understand prior summary/connections (so the extraction is a coherent UPDATE, not a from-scratch overwrite).
3. (Optional) Glob/Read entities/concepts dirs sparingly to avoid duplicate slugs for entities that already exist under a different surface form.
4. Extract and return ONE JSON object on stdout, no prose, no code fences:
   {
     "title": "...",
     "summary": "...",                  // 2-4 paragraphs, plain Markdown
     "key_claims": ["...", "..."],      // bullets
     "entities": [
       {"name": "...", "slug": "...", "about": "...", "connection_note": "..."},
       ...
     ],
     "concepts": [
       {"name": "...", "slug": "...", "about": "...", "connection_note": "..."},
       ...
     ],
     "contradictions": "None or text",
     "tags": ["...", "..."]
   }

You MUST NOT write any file. You MUST NOT update index.md, log.md, overview.md, sources/, entities/, concepts/. Only Read and return JSON.
```

If a subagent returns malformed JSON, fall back to inline extraction for that one file in the main context. Do not retry the subagent.

### Step 2.2: Write source pages and MERGE entities / concepts (main context)

Aggregate the extraction results. For each dirty record paired with its extraction:

1. Build the source page frontmatter: `title`, `type: source`, `tags` (from extraction), `source_id`, `source_hash`, `last_updated` (today), plus all derived fields the preflight record already provides (`source_type`, `word_count`, `reading_time_min`, `session_id` for handover, `source_url` / `captured_at` / `captured_by` / `domain` for web-clip).
2. Build the body: `## Summary` (extraction.summary) + `## Key Claims` (bullets from extraction.key_claims) + `## Connections` (`- [[<slug>]] — <connection_note>` for each entity / concept) + `## Contradictions` (extraction.contradictions).
3. Write `$VAULT/wiki/sources/<slug>.md`:
   - **CREATE**: write the full file fresh.
   - **UPDATE** (record's `existing_page` set): merge frontmatter — overwrite ONLY the derived fields above plus `title`, `tags`, `source_hash`, `last_updated`. **Preserve any other frontmatter keys the user added by hand.** Then replace the body wholesale (Summary/Key Claims/Connections/Contradictions are LLM-owned).

4. Aggregate entities and concepts across all dirty files (dedupe by slug). For each unique entity / concept:
   - If `$VAULT/wiki/entities/<slug>.md` (or `concepts/`) does not exist → CREATE with `## About` (the union of `about` strings from sources that mention it) and `## Connections` (one line per source that mentions it, `- [[<source-slug>]] — <connection_note>`).
   - If exists → MERGE: append the new Connection line(s); if the new About info is genuinely new (not already covered), append as a new paragraph. **Never overwrite existing About.**

### Step 2.3: Bookkeeping (main context, batched)

After all per-file writes are done:

1. **`$VAULT/wiki/index.md`**: in a single Edit, insert all new source / entity / concept entries under `## Sources` / `## Entities` / `## Concepts`. Format: `- [[<slug>]] — <title>`. Do not duplicate existing entries. **Never overwrite the file** — preserve content above those sections (e.g. `## Activity heatmap`, `## Handover calendar`).
2. **`$VAULT/wiki/overview.md`**: append / light revise. **Do not rewrite from scratch.** Skip if no material change.
3. **`$VAULT/wiki/log.md`**: append all CREATE / UPDATE / MERGE lines in one Bash `printf … >>` call. Format: `## [YYYY-MM-DD] CREATE | <slug>` (or `UPDATE` / `MERGE`). One line per affected page.

**SKIP and SKIP-empty are already in `log.md`** — preflight wrote them in batch before Step 1 returned. Do not re-emit them.

For **ERROR** records (slug collision): do not modify any file. Report to the user.

## Step 3: Report

Use the preflight summary for SKIP / SKIP-empty / SKIP-asset / ERROR counts. Use your own bookkeeping from Step 2 for CREATE / UPDATE / MERGE.

```
Ingest complete.
  CREATE: N sources, M entities, K concepts
  UPDATE: ...
  MERGE (entities/concepts): ...
  SKIP: ...
  SKIP-empty: ...
  ERROR: ... (if any)

Wiki: <VAULT>/wiki/
```

## Notes

- Write order per dirty file: entities/concepts MERGE → index → overview → sources → log. If the source write fails, the wiki is still consistent.
- Be conservative with entity / concept MERGE: when unsure two names refer to the same thing, prefer separate pages.
- WIKI.md is the schema authority. If anything below disagrees, WIKI.md wins.
