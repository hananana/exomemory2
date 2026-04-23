<!-- exomemory2-schema: v0.4 -->
# WIKI.md — Schema and Workflow

This file defines the schema and workflow for this vault. Claude reads this file during every `/wiki-ingest` and `/wiki-query` operation.

**Schema version marker** (line 1): `/wiki-migrate` inspects the first line of this file to decide whether the schema needs to be upgraded to a newer template. Do not remove the marker even when hand-customizing this file. Use `--skip-schema-update` on migration if you want to keep a customized WIKI.md.

Based on [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

## Vault Structure

```
<vault>/
├── WIKI.md                  # This file (schema)
├── raw/                     # Immutable source documents (you drop files here)
│   ├── handovers/           # Auto-captured Claude conversations (via hooks)
│   ├── web/                 # Web clips (via /wiki-clip or PostToolUse[WebFetch])
│   │   └── <slug>.md
│   └── assets/              # Image pool for web clips (content-addressed)
│       ├── <sha256>.png
│       ├── <sha256>.jpg
│       └── .trash/          # /wiki-gc logical-deletes orphans here
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
- `raw/assets/` is a flat content-addressed image pool shared across all `raw/` subdirectories. Filenames are `<sha256 of bytes>.<ext>` (Karpathy pattern)

## Page Naming (Slug Rules)

### Sources

- `source_id` = raw file path relative to vault, without `raw/` prefix, POSIX-separated
  - `raw/papers/attention.md` → `source_id = papers/attention.md`
- `slug` = `source_id` with `/` replaced by `--` and `.md` extension stripped
  - `papers/attention.md` → `slug = papers--attention`
- Page location: `wiki/sources/<slug>.md`

### Web clips (subtype of Sources)

Files under `raw/web/` are web clips produced by `/wiki-clip` or auto-captured on `WebFetch`. They follow the same source naming rule, but the slug is derived from the URL:

- From URL `https://gist.github.com/karpathy/442a6b...` → `source_id = web/gist-github-com--karpathy--442a6b.md`
- Derivation: lowercase the host, replace `.` with `-` in host, POSIX-normalize path, replace `/` with `--`, drop query/fragment, Punycode for non-ASCII hosts
- `slug = web--<host-normalized>--<path-normalized>` (same `/` → `--` rule)
- Page location: `wiki/sources/web--<...>.md`

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
source_type: handover | web-clip | manual     # v0.4+, see mapping table below
tags: [tag1, tag2]
source_id: <vault-relative raw path>
source_hash: sha256:<hash>
word_count: <int>                             # v0.4+, raw body word count
reading_time_min: <int>                       # v0.4+, ceil(word_count / 200)
last_updated: YYYY-MM-DD
---
```

**`source_type` mapping** (authoritative key = `source_id` first segment):

| `source_id` prefix | `source_type` |
|-------------------|---------------|
| `handovers/…` | `handover` |
| `web/…` | `web-clip` |
| other (`papers/`, `notes/`, root, …) | `manual` |

**Handover-specific additions** (only when `source_type == handover`):

```yaml
session_id: <uuid>                            # extracted from filename
```

**Web-clip-specific additions** (only when `source_type == web-clip`, forwarded from the raw file's frontmatter):

```yaml
source_url: https://...
domain: <lowercased host>                     # derived from source_url
captured_at: <ISO8601>
captured_by: manual-clip | auto-webfetch | auto-browser
```

These v0.4+ derived fields are recomputed on every `/wiki-ingest` CREATE/UPDATE (see Step 3) and by `/wiki-migrate` for historical pages. Unknown frontmatter keys (user-authored notes, custom tags) are preserved on UPDATE.

### Web clip raw file frontmatter

This describes the frontmatter written by `/wiki-clip` to `raw/web/<slug>.md` (the **raw** file, not the wiki page). The wiki page is an ordinary `type: source` page and follows the "Source page" schema above, with the web-clip-specific fields forwarded from the raw.

Raw web-clip frontmatter omits `source_hash` because `/wiki-ingest` recomputes it from the raw bytes at ingest time. Writing `source_hash` into the raw would change the raw bytes and force `UPDATE` on every ingest.

```yaml
---
title: <readability-extracted title>
type: source
tags: [web-clip, ...]
source_id: web/<slug>.md
source_url: https://...
captured_at: <ISO8601>
captured_by: manual-clip | auto-webfetch | auto-browser
last_updated: YYYY-MM-DD
---
```

**Invariants** (critical for ingest stability):
- Once written, the raw file is **never modified**. No `referenced_by`, no timestamp bumps. This keeps `source_hash` stable so re-ingest reliably hits `SKIP`.
- Image references use **relative paths from the raw file**: `../assets/<sha256>.<ext>`. This works in both Obsidian and plain Markdown renderers.

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
3. Write `wiki/sources/<slug>.md` with frontmatter + section format above. Compute and include the following derived frontmatter fields (v0.4+):
   - `source_type` — from `source_id` prefix (see mapping table under "Source page")
   - `word_count` — whitespace-split tokens in the raw body (strip YAML frontmatter first if the raw file has one)
   - `reading_time_min` — `ceil(word_count / 200)`
   - For handover (`handovers/<id>.md`): `session_id` extracted from filename
   - For web-clip (`web/<slug>.md`): `source_url`, `captured_at`, `captured_by` forwarded from raw frontmatter; `domain` derived from `source_url` (lowercased host)
   - On **UPDATE**: merge frontmatter — overwrite the fields listed above plus `title`, `tags`, `source_hash`, `last_updated`; preserve any other keys (user-authored metadata)
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

Where `<op>` ∈ `{CREATE, UPDATE, MERGE, SKIP, SKIP-empty, MIGRATE-DATAVIEW, MIGRATE-ORPHAN, MIGRATE-ERROR}`. For slug collisions that triggered an error, do not log (the error is reported to the user only).

`/wiki-migrate` writes a single summary line of the form `## [YYYY-MM-DD] MIGRATE | processed=<N>, changed=<C>, orphan=<O>, error=<E>`. Individual skipped pages are logged as `MIGRATE-ORPHAN` (raw file missing) or `MIGRATE-ERROR` (unparseable frontmatter). (Vaults migrated under v0.4 may have historical `MIGRATE-DATAVIEW` entries — those are left intact.)

## Notes on handovers

Files under `raw/handovers/` are automatically captured Claude conversation logs. They use `<session-id>` as the filename. When ingesting, treat them as any other source:

- `source_id` = `handovers/<session-id>.md`
- `slug` = `handovers--<session-id>`
- `source_type = handover`
- `session_id` = `<session-id>` (derived from filename, written to wiki page frontmatter for Dataview queries)
- Extract meaningful discussion points, decisions, and mentioned entities/concepts
- Filter out trivial chit-chat or repeated reasoning traces

Since the capture overwrites the same file per session (no timestamps in filename), later compacts/exits in the same session update the same source. `source_hash` will differ, triggering `UPDATE` on re-ingest.

If the handover contains a `## Clips Captured in This Session` section (emitted by `capture.sh` when `PostToolUse[WebFetch]` queued URLs during the session), the listed `[[web--<slug>]]` wikilinks become Connections in `wiki/sources/handovers--<id>.md` through the existing wikilink-extraction ingest logic. No special handling is required.

## Notes on web clips

Files under `raw/web/` are web pages clipped via `/wiki-clip` or auto-captured on `WebFetch` (see `.exomemory-config: AUTO_CLIP`). Treat them as ordinary sources:

- `source_id` = `web/<slug>.md`
- `slug` derivation: see "Web clips" under Page Naming
- `source_type = web-clip`
- `source_url`, `captured_at`, `captured_by` are forwarded from the raw file's frontmatter to the wiki page's frontmatter on ingest
- `domain` is derived from `source_url` (lowercased host) and written to the wiki page for Dataview queries
- Body is readability-extracted Markdown; images live in `raw/assets/` referenced as `../assets/<sha256>.<ext>`

**Session attribution (v0.3 one-way graph):**

- `wiki/sources/handovers--<id>.md` records Connections to the web clips used in that session (via wikilinks in the handover's "Clips Captured" section)
- The reverse direction — listing which sessions touched a given web clip — is **not persisted** in `wiki/sources/web--<slug>.md` during v0.3, because the current ingest workflow does not MERGE back-edges into source pages. It remains retrievable by `grep` over handover wiki pages, and a future release may introduce bidirectional source-page MERGE

**Invariants for web-clip raw files:**

- `raw/web/<slug>.md` is written **once** and never modified. Revisiting the same URL from a new session produces `SKIP` (hash match) — attribution is handled by the new handover's own Connections, not by rewriting the existing clip
- `raw/assets/<sha256>.<ext>` is content-addressed. The same image bytes across different clips dedupe to one file. Never move, rename, or hand-edit these files; they are referenced by hash from multiple raw sources

## Notes on Dataview (v0.4+)

This vault is designed to play well with the [Obsidian Dataview](https://github.com/blacksmithgu/obsidian-dataview) plugin. Source-page frontmatter carries DataView-queryable derived fields (`source_type`, `word_count`, `reading_time_min`, and `domain` for web clips), and `wiki/dashboards/` ships pre-built DQL views.

**Why entity / concept pages have no extra fields:**

Dataview exposes native fields that make explicit counters unnecessary:

- `length(file.inlinks)` — how many pages link here (replaces `connection_count`)
- `file.ctime` — first created (replaces `first_seen`)
- `file.mtime` — last modified (replaces `last_connected`)

Dashboards under `wiki/dashboards/` use these native fields directly; no frontmatter retrofit is needed for `wiki/entities/` or `wiki/concepts/`.

**Bringing an existing vault to v0.4:**

Run `/wiki-migrate` once. It will:

1. Retrofit derived fields on all `wiki/sources/*.md` pages (idempotent — re-runs produce no diff)
2. Replace the vault's `WIKI.md` with the v0.4 template if the line-1 schema marker is absent or points at an older version (with `.bak` preserved)
3. Copy `wiki/dashboards/` if missing (never overwrites existing dashboard files)

After the migration, new `/wiki-ingest` operations produce pages already conformant with the v0.4 schema, so the migration command does not need to be re-run in normal operation.
