<!-- exomemory2-schema: v0.9 -->
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
sources: <int>                # v0.9+, count of wiki/sources/ pages linking to this page
last_verified: YYYY-MM-DD     # v0.9+, last CREATE/MERGE date (separate from last_updated)
confidence: <float 0.0-1.0>   # v0.9+, derived (see "Confidence scoring" below)
# Optional v0.9+ fields, only present when set:
# stale: true
# superseded_by: [[<slug>]]
# superseded_at: YYYY-MM-DD
# supersedes: [[<slug>]]
---
```

### Concept page

```yaml
---
title: <canonical name>
type: concept
tags: [framework | method | theory | ...]
last_updated: YYYY-MM-DD
sources: <int>                # v0.9+
last_verified: YYYY-MM-DD     # v0.9+
confidence: <float 0.0-1.0>   # v0.9+
# Optional v0.9+: stale, superseded_by, superseded_at, supersedes
---
```

The `sources` / `last_verified` / `confidence` triple is **derived** — Claude computes it during ingest/MERGE and `/wiki-migrate` recomputes it for older pages. Users do not write these by hand. See "Confidence scoring (v0.9+)" and "Supersession (v0.9+)" sections below for the exact rules.

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

- depends_on:: [[<slug>]] — note
- contradicts:: [[<slug>]] — note
- caused_by:: [[<slug>]] — note
- fixed_in:: [[<slug>]] — note
- supersedes:: [[<slug>]] — note
- related_to:: [[<slug>]] — note
- ...
```

**Typed connections (v0.9+)**: Each Connection bullet is a **Dataview inline field** with one of the keys below. The value `[[<slug>]] — note` is preserved as a string by Dataview, while the wikilink remains parseable for the graph view.

| key | meaning |
|-----|---------|
| `depends_on` | The current page depends on the linked page (lib, upstream code, prerequisite knowledge) |
| `contradicts` | The two pages express incompatible claims or designs |
| `caused_by` | The current page exists because of the linked page (cause, root incident) |
| `fixed_in` | The current page was fixed/resolved in the linked page (version, commit, ticket) |
| `supersedes` | The current page replaces the linked page (paired with `superseded_by` on the linked page) |
| `related_to` | Default catch-all for weak associations |

**Backwards compatibility**: A bare `- [[<slug>]] — note` line (no key) is treated as `related_to::` for retrieval. New ingests should always emit a typed key. `/wiki-migrate` retrofits bare lines by prepending `related_to:: `.

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
   - If `wiki/entities/<slug>.md` not exists → `CREATE` (write a fresh "About" based on what the source says, plus a typed Connection back to this source — usually `- related_to:: [[<this-source-slug>]]`, or a more specific key if obvious)
   - If exists → `MERGE`: read existing page, append a typed Connection entry, follow the conflict resolution decision tree (see "MERGE Rule for Entities and Concepts" below) for any contradicting About content
   - After CREATE / MERGE: recompute `sources` (count of `wiki/sources/*.md` files containing `[[<entity-slug>]]`, `[[<entity-slug>|...]]`, or `[[<entity-slug>#...]]`) and recompute `confidence` per the formula in "Confidence scoring (v0.9+)"
   - Set `last_verified` to today's date
5. For **each mentioned concept**: same logic, but in `wiki/concepts/`
6. **Supersession check (v0.9+)**: scan the source body for the trigger phrases listed in "Supersession (v0.9+)". If a trigger fires AND both X and Y resolve to wiki entity-or-concept slugs (either pre-existing or just created in this ingest), apply the supersession marking on both pages and append a `## [YYYY-MM-DD] SUPERSEDE | <X-slug> -> <Y-slug>` line to log.md
7. Update `wiki/index.md`:
   - Under appropriate section (Sources / Entities / Concepts), append new pages as `- [[<slug>]] — <title>` (if not already listed)
8. Update `wiki/overview.md`:
   - Read existing content
   - Append or revise relevant parts to reflect new knowledge (do NOT rewrite the whole file — preserve existing synthesis)
9. Append to `wiki/log.md`:
   - `## [YYYY-MM-DD] CREATE | <slug>` (or `UPDATE`, `MERGE`, `SKIP`, `SUPERSEDE`)
   - One line per affected page

For `SKIP`: just append `## [YYYY-MM-DD] SKIP | <slug>` to log.md and stop.

For `ERROR`: report to user and stop processing this file.

## Query Workflow

When Claude processes a `/wiki-query` call:

1. Read `wiki/index.md` to understand what's available
2. Identify pages relevant to the question (by title match, keyword overlap, or concept relatedness)
3. **Apply the stale filter (v0.9+)** — see "Stale filter (v0.9+)" below. Pages with `stale: true` are excluded from the candidate list unless one of rules R-2/R-3/R-4 applies
4. Read the surviving candidates fully
5. Synthesize an answer:
   - Use `[[wikilink]]` citations for every significant claim, pointing to the page that supports it
   - If contradictions exist between pages, surface them explicitly
   - If the wiki doesn't cover the question, say so plainly — do not fabricate
6. If `--save` was specified, write the answer to `wiki/syntheses/<slug>.md` with frontmatter `type: synthesis`, and append `## [YYYY-MM-DD] CREATE | syntheses/<slug>` to log.md

### Stale filter (v0.9+)

A page is included in the candidate set if **any** of the following rules matches. Rules are checked deterministically (no LLM judgement) by `commands/wiki-query.md`'s Bash preprocess.

| Rule | Condition | Action |
|------|-----------|--------|
| **R-1** (default include) | `stale != true` (frontmatter has no `stale: true` line) | Always include |
| **R-2** (history keyword) | The user's question contains any of: `history`, `経緯`, `以前`, `昔`, `deprecated`, `古い`, `previous`, `old`, `廃止`, `なぜ.*やめ` (case-insensitive substring; regex for the last) | Include all candidates regardless of `stale` |
| **R-3** (direct page reference) | The question contains a literal `[[<slug>]]` for the page, OR contains the page's `title` as an exact substring | Include that specific page even if `stale: true` |
| **R-4** (supersession traversal) | A non-stale page already in the candidate set has `supersedes: [[X]]` in its frontmatter | Add `X` (one hop) to the candidate set even if `stale: true` |

R-4 is critical: it ensures that questions like "What was Y's predecessor?" or "Why did we move off X?" can reach the stale predecessor through the new page's `supersedes` link.

## MERGE Rule for Entities and Concepts

Never overwrite entity or concept pages — always MERGE. Rationale: these pages accumulate information across many sources, and overwriting risks information loss.

**Base merge procedure:**

1. Read existing page
2. Keep all existing sections intact
3. Add new information (see decision tree below for conflict handling):
   - New Connection lines (with typed key) at the bottom of Connections section
   - New "About" info appended as additional paragraph
4. Recompute `sources` (count of `wiki/sources/*.md` pages with a wikilink to this page's slug)
5. Recompute `confidence` (see "Confidence scoring (v0.9+)" section)
6. Update `last_updated` and `last_verified` in frontmatter (today's date)
7. Append `## [YYYY-MM-DD] MERGE | <slug>` to log.md

### Conflict resolution decision tree (v0.9+)

When a new claim from a source contradicts what's already on the entity/concept page, choose **the first matching rule**:

1. **Supersession trigger** — The new source contains explicit linguistic markers (see "Supersession (v0.9+)" section). →
   - Mark old page: `stale: true`, `superseded_by: [[<new-slug>]]`, `superseded_at: <today>`
   - Mark new page: `supersedes: [[<old-slug>]]`
   - **Both pages keep their existing body**. The old page is hidden from default queries but never deleted.

2. **Recency winner** — The new claim is dated within the last 30 days AND the existing claim is older than 90 days AND both refer to the same "current state" fact (which lib is currently used, current design, etc.). →
   - Insert new claim at the start of the "About" section
   - Prefix the old text with `(過去の記述: ... as of YYYY-MM-DD)` / `(prior: ... as of YYYY-MM-DD)`
   - Both texts remain on the page

3. **Authority winner** — The new source has any of:
   - `tags` containing `paper`, `official`, or `spec`
   - `source_type == manual` AND `domain` is empty (= user-placed raw, treated as authoritative)

   If both old and new are authoritative, fall through to rule 2 (recency). Otherwise the authoritative side wins:
   - Authoritative claim goes into the "About" lead paragraph
   - The non-authoritative claim becomes a footnote-style trailing paragraph

4. **Default — dual statement**: Add a `## Notes (YYYY-MM-DD)` section enumerating both views. Add a `- contradicts:: [[<other-slug>]]` line in Connections if a corresponding wiki page exists. Confidence is **automatically capped at 0.5** for any page whose Connections contain at least one `contradicts::` line (see formula).

Apply the tree per individual fact. A single MERGE may trigger different rules for different claims in the same source.

> **Note on the `## Contradictions` section**: Source pages may carry a top-level `## Contradictions` section (see "Source Page Format" above). That section is for **source pages only** and lists raw vs wiki disagreements. Entity / concept pages do **not** use a `## Contradictions` section — their contradictions live as `- contradicts:: [[X]]` lines inside `## Connections`. The two are distinct and confidence is computed only from the latter.

## Log.md Format

Append-only. One line per operation:

```
## [YYYY-MM-DD] <op> | <slug>
```

Where `<op>` ∈ `{CREATE, UPDATE, MERGE, SKIP, SKIP-empty, SUPERSEDE, MIGRATE-DATAVIEW, MIGRATE-CONFIDENCE, MIGRATE-CONNECTIONS, MIGRATE-ORPHAN, MIGRATE-ERROR}`. For slug collisions that triggered an error, do not log (the error is reported to the user only).

`/wiki-migrate` writes a single summary line of the form `## [YYYY-MM-DD] MIGRATE | processed=<N>, changed=<C>, orphan=<O>, error=<E>` plus per-page `MIGRATE-CONFIDENCE` / `MIGRATE-CONNECTIONS` lines for v0.9+ retrofits. `SUPERSEDE` lines (form: `## [YYYY-MM-DD] SUPERSEDE | <old-slug> -> <new-slug>`) are written by `/wiki-ingest` when a supersession trigger fires. Individual skipped pages are logged as `MIGRATE-ORPHAN` (raw file missing) or `MIGRATE-ERROR` (unparseable frontmatter). (Vaults migrated under v0.4 may have historical `MIGRATE-DATAVIEW` entries — those are left intact.)

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

**Source pages** carry Dataview-queryable derived fields (`source_type`, `word_count`, `reading_time_min`, `domain`).

**Entity / concept pages (v0.9+)** carry `sources`, `last_verified`, `confidence`, and the optional `stale` / `supersedes` / `superseded_by` / `superseded_at`. Dataview native fields are still useful in parallel:

- `length(file.inlinks)` — real-time inbound link count (note: counts links from anywhere, not just `wiki/sources/`)
- `file.ctime` — first created
- `file.mtime` — last modified

The frontmatter `sources` is the **ingest-time snapshot** counted across `wiki/sources/*.md` only (used for confidence). Both signals coexist; pick the one that fits the dashboard.

**Bringing an existing vault to v0.9:**

Run `/wiki-migrate` once. It will:

1. Retrofit derived fields on all `wiki/sources/*.md` pages (idempotent — re-runs produce no diff)
2. Backfill `sources` / `last_verified` / `confidence` on every `wiki/entities/*.md` and `wiki/concepts/*.md` (v0.9+, idempotent)
3. Prefix bare `- [[X]]` lines in entity/concept Connections sections with `- related_to:: ` (v0.9+, idempotent)
4. Replace the vault's `WIKI.md` with the current template when the line-1 schema marker is older than `v0.9`
5. Copy `wiki/dashboards/` files that are missing (never overwrites existing ones)

After the migration, new `/wiki-ingest` operations produce pages already conformant with the v0.9 schema.

## Confidence scoring (v0.9+)

Every entity and concept page has a `confidence` value derived from objective signals on the page itself. **Users do not write `confidence` by hand** — it is recomputed on every CREATE/MERGE and on every `/wiki-migrate`.

**Formula** (deterministic, identical in ingest and migrate paths):

```
base = clamp(sources / 5.0, 0.3, 1.0)
# 1 source → 0.3, 2 → 0.4, 3 → 0.6, 4 → 0.8, 5+ → 1.0

if contradictions_present:
    confidence = min(base, 0.5)
else:
    confidence = base
```

**`sources` definition**: count of `wiki/sources/*.md` files that contain a `[[<this-page-slug>]]` wikilink (matched as `[[slug]]`, `[[slug|alias]]`, or `[[slug#anchor]]`). The grep is run during ingest/MERGE and during migrate; both paths must produce the same number. **`length(file.inlinks)` is not used** for confidence (it counts inbound links from anywhere, including index/dashboards/syntheses, which would skew the score).

**`contradictions_present` definition**: at least one bullet inside the page's `## Connections` section starts with `- contradicts::`. Connections section absent or empty → false.

**stale pages still get confidence computed** — the `stale: true` flag does **not** force confidence down. Stale pages remain queryable for history-style questions and keep an honest score of how well-sourced their (outdated) claims were.

## Supersession (v0.9+)

Supersession marks an entity/concept page as outdated and points to the newer page that replaced it. It is triggered **only** by explicit linguistic markers in the new source — never by mere recency, by general improvements, or by Claude's own judgement that "X looks better than Y".

**Trigger phrases** (case-insensitive substring match in the new source's body):

| Language | Phrase pattern |
|----------|----------------|
| English | "switched from X to Y" |
| English | "moved from X to Y" |
| English | "X was replaced by Y" / "replaced X with Y" |
| English | "deprecated X in favor of Y" |
| English | "X is no longer used, we use Y now" / "no longer use X" |
| Japanese | 「X から Y に移行」「X を Y に移行」 |
| Japanese | 「X をやめて Y にした」「X はやめて Y を使う」 |
| Japanese | 「X を Y で置き換え」「X を Y に置き換え」 |
| Japanese | 「X は廃止」「X を廃止して Y」 |

When a trigger is detected during ingest of a source that mentions both X and Y as known/new entity-or-concept slugs:

1. **Newer page Y (superseder)**:
   - Add `supersedes: [[X]]` to frontmatter
   - Add `- supersedes:: [[X]] — <one-line context>` to Connections
2. **Older page X (superseded)**:
   - Set `stale: true` in frontmatter
   - Add `superseded_by: [[Y]]`
   - Add `superseded_at: <today>`
   - **Do not delete or rewrite the body** — it remains as a record of the older state

Add the supersession to log.md as `## [YYYY-MM-DD] SUPERSEDE | <X-slug> -> <Y-slug>`.

**Adding new trigger phrases**: update this list and the corresponding pattern in `commands/wiki-ingest.md`. Trigger detection is intentionally narrow — false positives create false stale flags, which damage future retrieval.
