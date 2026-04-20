# WIKI.md — Schema and Workflow

This file defines the schema and workflow for this vault. Claude reads this file during every `/wiki-ingest` and `/wiki-query` operation.

Based on [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

## Vault Structure

```
<vault>/
├── WIKI.md                  # This file (schema)
├── raw/                     # Immutable source documents (you drop files here)
│   └── handovers/           # Auto-captured Claude conversations (via hooks)
└── wiki/                    # LLM-maintained knowledge layer
    ├── index.md             # Catalog of all pages
    ├── log.md               # Append-only operation log
    ├── overview.md          # Living synthesis
    ├── sources/             # One page per source document
    ├── entities/            # People, companies, projects, products
    └── concepts/            # Ideas, frameworks, methods, theories
```

**Rules:**
- `raw/` is immutable — never modify files here
- `wiki/` is LLM-write territory — can be freely updated
- All pages are Markdown with YAML frontmatter
- Links use `[[slug]]` Obsidian-compatible format

## Page Naming (Slug Rules)

### Sources

- `source_id` = raw file path relative to vault, without `raw/` prefix, POSIX-separated
  - `raw/papers/attention.md` → `source_id = papers/attention.md`
- `slug` = `source_id` with `/` replaced by `--` and `.md` extension stripped
  - `papers/attention.md` → `slug = papers--attention`
- Page location: `wiki/sources/<slug>.md`

### Entities and Concepts

- `slug` = kebab-case of the canonical name
  - `Andrej Karpathy` → `andrej-karpathy`
  - `Self-Attention` → `self-attention`
- Page location: `wiki/entities/<slug>.md` or `wiki/concepts/<slug>.md`

## YAML Frontmatter Specification

### Source page

```yaml
---
title: <human readable title>
type: source
tags: [tag1, tag2]
source_id: <vault-relative raw path>
source_hash: sha256:<hash>
last_updated: YYYY-MM-DD
---
```

### Entity page

```yaml
---
title: <canonical name>
type: entity
tags: [person | organization | project | product, ...]
last_updated: YYYY-MM-DD
---
```

### Concept page

```yaml
---
title: <canonical name>
type: concept
tags: [framework | method | theory | ...]
last_updated: YYYY-MM-DD
---
```

## Source Page Format

```markdown
---
<frontmatter>
---

## Summary

<2-4 paragraph overview of what this source is about>

## Key Claims

- Claim 1 with reference to where in the source
- Claim 2
- ...

## Connections

- [[entity-or-concept-slug]] — brief note on relevance
- ...

## Contradictions

<any claims that contradict what's already in the wiki, or note "None" if none detected>
```

## Entity / Concept Page Format

```markdown
---
<frontmatter>
---

## About

<2-3 paragraph description>

## Connections

- [[source-or-other-page]] — how this is related
- ...
```

## Ingest Workflow

When Claude processes a `/wiki-ingest` call, for **each raw file**:

### Step 0: Skip empty raw files

If the raw file has no body content beyond YAML frontmatter (only whitespace after the closing `---`), the operation is `SKIP-empty`: append `## [YYYY-MM-DD] SKIP-empty | <slug>` to log.md and move on. Empty sessions must never produce a wiki source page — they are noise.

### Step 1: Compute identity

1. Compute `source_id` from vault-relative path
2. Compute `slug` (see Page Naming rules above)
3. Compute `source_hash = sha256sum(raw_file)` (the first 64 hex chars)

### Step 2: Decide operation

1. Check if `wiki/sources/<slug>.md` exists
2. **If not exists** → operation is `CREATE`
3. **If exists**:
   - Read its frontmatter
   - **If `source_id` does not match** → operation is `ERROR` (slug collision). Stop processing this file and report to user to rename the raw file.
   - **If `source_id` matches and `source_hash` matches** → operation is `SKIP` (no content change, log once and move on)
   - **If `source_id` matches but `source_hash` differs** → operation is `UPDATE`

### Step 3: Execute operation

For `CREATE` or `UPDATE`:

1. Read the raw file fully
2. Extract or draft:
   - Title (from raw content, or first heading, or derived from filename)
   - Summary (2-4 paragraphs)
   - Key Claims (bullet list)
   - Mentioned entities (people, companies, projects, products)
   - Mentioned concepts (ideas, frameworks, methods)
   - Contradictions with existing wiki content (check against `overview.md` and linked pages)
3. Write `wiki/sources/<slug>.md` with frontmatter + section format above
4. For **each mentioned entity**:
   - Compute entity slug
   - If `wiki/entities/<slug>.md` not exists → `CREATE` (write a fresh "About" based on what the source says, plus Connection back to this source)
   - If exists → `MERGE`: read existing page, append new Connection entry (back to this source), and if the source contributes new "About" info, add it without deleting existing info
5. For **each mentioned concept**: same logic, but in `wiki/concepts/`
6. Update `wiki/index.md`:
   - Under appropriate section (Sources / Entities / Concepts), append new pages as `- [[<slug>]] — <title>` (if not already listed)
7. Update `wiki/overview.md`:
   - Read existing content
   - Append or revise relevant parts to reflect new knowledge (do NOT rewrite the whole file — preserve existing synthesis)
8. Append to `wiki/log.md`:
   - `## [YYYY-MM-DD] CREATE | <slug>` (or `UPDATE`, `MERGE`, `SKIP`)
   - One line per affected page

For `SKIP`: just append `## [YYYY-MM-DD] SKIP | <slug>` to log.md and stop.

For `ERROR`: report to user and stop processing this file.

## Query Workflow

When Claude processes a `/wiki-query` call:

1. Read `wiki/index.md` to understand what's available
2. Identify pages relevant to the question (by title match, keyword overlap, or concept relatedness)
3. Read those pages fully
4. Synthesize an answer:
   - Use `[[wikilink]]` citations for every significant claim, pointing to the page that supports it
   - If contradictions exist between pages, surface them explicitly
   - If the wiki doesn't cover the question, say so plainly — do not fabricate
5. If `--save` was specified, write the answer to `wiki/syntheses/<slug>.md` with frontmatter `type: synthesis`, and append `## [YYYY-MM-DD] CREATE | syntheses/<slug>` to log.md

## MERGE Rule for Entities and Concepts

Never overwrite entity or concept pages — always MERGE. Rationale: these pages accumulate information across many sources, and overwriting risks information loss.

**Merge procedure:**

1. Read existing page
2. Keep all existing sections intact
3. Add new information:
   - New Connection lines at the bottom of Connections section
   - New "About" info appended as additional paragraph (or in a dated note if it contradicts existing info)
4. Update `last_updated` in frontmatter
5. Append `## [YYYY-MM-DD] MERGE | <slug>` to log.md

## Log.md Format

Append-only. One line per operation:

```
## [YYYY-MM-DD] <op> | <slug>
```

Where `<op>` ∈ `{CREATE, UPDATE, MERGE, SKIP, SKIP-empty}`. For slug collisions that triggered an error, do not log (the error is reported to the user only).

## Notes on handovers

Files under `raw/handovers/` are automatically captured Claude conversation logs. They use `<session-id>` as the filename. When ingesting, treat them as any other source:

- `source_id` = `handovers/<session-id>.md`
- `slug` = `handovers--<session-id>`
- Extract meaningful discussion points, decisions, and mentioned entities/concepts
- Filter out trivial chit-chat or repeated reasoning traces

Since the capture overwrites the same file per session (no timestamps in filename), later compacts/exits in the same session update the same source. `source_hash` will differ, triggering `UPDATE` on re-ingest.
