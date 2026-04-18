---
description: Ingest raw sources into the wiki (CREATE/UPDATE/SKIP with dedup)
argument-hint: <raw-file-or-dir> [--vault <path>]
allowed-tools: Bash(shasum:*), Bash(find:*), Bash(ls:*), Bash(cat:*), Bash(test:*), Bash(realpath:*), Bash(pwd:*), Read, Write, Edit
---

# /wiki-ingest

Ingest a raw source (file or directory) into the active vault's wiki, following the vault's `WIKI.md` workflow.

Arguments received: `$ARGUMENTS`

## Step 1: Parse arguments

Split `$ARGUMENTS` by whitespace. The first positional argument is the raw file or directory path. If you see `--vault <path>` anywhere, capture that path as the explicit vault override.

## Step 2: Resolve the vault

Try in this order; stop at the first success:

1. **Explicit `--vault`** from step 1, if provided
2. **Environment variable** `CLAUDE_MEMORY_VAULT`:
   - !`echo "${CLAUDE_MEMORY_VAULT:-}"`
3. **Ancestor search** from current working directory upward, looking for a directory containing `WIKI.md`:
   - !`pwd`
   - Then walk up the directory tree and check for `WIKI.md`

A directory is a valid vault if it contains `WIKI.md` directly, plus `raw/` and `wiki/` subdirectories.

If no vault is resolved, **stop** and report:
```
Vault not found.
Set CLAUDE_MEMORY_VAULT to a vault path, or pass --vault <path>, or cd into a vault.
Run /wiki-init <path> to create one.
```

Record the resolved absolute vault path for use below. Call it `$VAULT` in your reasoning.

## Step 3: Load the schema

Read `<VAULT>/WIKI.md` to understand the ingest workflow, page format, slug rules, and MERGE semantics for this vault. **The WIKI.md is authoritative** — if it disagrees with anything below, WIKI.md wins.

## Step 4: Validate and enumerate raw inputs

The raw argument can be absolute or relative:

- If **absolute path**: verify it exists, and that its absolute path starts with `<VAULT>/raw/`. If outside vault's raw, stop with error.
- If **relative path**: interpret it relative to `<VAULT>/raw/`. Verify the resolved absolute path exists.

If the target is a directory, recurse and collect every regular file inside (any extension — markdown expected, but we tolerate other formats that `/wiki-ingest` can read as text).

## Step 5: For each raw file, follow WIKI.md's ingest workflow

For each file in the enumerated set:

### 5a. Compute identity

- `source_id` = path relative to `<VAULT>/` with the `raw/` prefix stripped, POSIX-separated
- `slug` = `source_id` with `/` → `--` and the file extension stripped only if it is `.md`. For other extensions, keep the extension in the slug (e.g. `papers--foo.pdf`). Sanitize any leftover characters that are unsafe for filenames by replacing with `-`.
- `source_hash` = sha256 of the raw file:
  - !`shasum -a 256 "<full raw file path>" | awk '{print $1}'`

### 5b. Decide operation

Read `<VAULT>/wiki/sources/<slug>.md` if it exists.

- Not exists → `CREATE`
- Exists and frontmatter `source_id` matches and `source_hash` matches → `SKIP`
- Exists and `source_id` matches but `source_hash` differs → `UPDATE`
- Exists and `source_id` does NOT match → `ERROR` (slug collision). Report to user, do not touch this file, move on to next.

### 5c. Execute

For **CREATE** / **UPDATE**:

1. Read the raw file
2. Extract title, summary, key claims, mentioned entities, mentioned concepts, and any contradictions with existing wiki pages (check `<VAULT>/wiki/overview.md` and entities/concepts that may relate)
3. Write `<VAULT>/wiki/sources/<slug>.md` following the Source Page Format in WIKI.md (frontmatter with `title`, `type: source`, `tags`, `source_id`, `source_hash`, `last_updated`, plus `## Summary / Key Claims / Connections / Contradictions` sections)
4. For each mentioned entity:
   - Compute entity `slug` (kebab-case of canonical name)
   - If `<VAULT>/wiki/entities/<slug>.md` does not exist: CREATE a new entity page with "About" section and a "Connections" entry back to this source
   - If exists: MERGE (append new Connection line; if new "About" info, append as new paragraph, do not overwrite existing content)
5. For each mentioned concept: same pattern, but in `<VAULT>/wiki/concepts/`
6. Update `<VAULT>/wiki/index.md`:
   - For each newly-created page (source/entity/concept), append `- [[<slug>]] — <title>` to the relevant section. Do not add duplicates.
7. Update `<VAULT>/wiki/overview.md`:
   - Read existing content, append or lightly revise to reflect new knowledge. **Do not rewrite the file from scratch** — preserve existing synthesis.
8. Append one line per affected page to `<VAULT>/wiki/log.md`:
   - `## [YYYY-MM-DD] CREATE | <slug>` (or `UPDATE` / `MERGE` as appropriate)
   - Use today's date: !`date +%Y-%m-%d`

For **SKIP**:
- Append `## [YYYY-MM-DD] SKIP | <slug>` to `<VAULT>/wiki/log.md`

For **ERROR**:
- Do not modify any file. Report the collision to the user.

## Step 6: Report

After processing all files, summarize to the user:

```
Ingest complete.
  CREATE: N sources, M entities, K concepts
  UPDATE: ...
  MERGE (entities/concepts): ...
  SKIP: ...
  ERROR: ... (if any)

Wiki: <VAULT>/wiki/
View with Obsidian: open -a Obsidian <VAULT>
```

## Notes

- Keep changes atomic per-file: if something fails mid-file, don't leave partial state. Write the source page last, after all entity/concept MERGEs succeed.
- Treat entity/concept MERGE conservatively: when unsure whether two names refer to the same entity, prefer creating separate pages over merging.
- Trust WIKI.md. If the vault's WIKI.md has domain-specific conventions, follow those.
