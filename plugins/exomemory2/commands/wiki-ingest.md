---
description: Ingest raw sources into the wiki (CREATE/UPDATE/SKIP with dedup)
argument-hint: "[<raw-file-or-dir>] [--vault <path>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# /wiki-ingest

Ingest raw sources (file or directory) into the active vault's wiki, following the vault's `WIKI.md` workflow.

With no arguments, the entire `raw/` tree under the active vault is scanned and ingested. The dedup logic in `WIKI.md` (`source_hash` match → `SKIP`) ensures unchanged files are not re-processed, so rerunning is cheap for already-ingested sources.

## Arguments

```
$ARGUMENTS
```

## Step 1: Parse arguments

Tokenize `$ARGUMENTS` by whitespace. If `--vault <path>` appears anywhere, capture that path as the explicit vault override.

The first non-`--vault` positional token (if any) is the raw file or directory path. If no positional token is present (i.e. `$ARGUMENTS` is empty or contains only `--vault <path>`), treat the raw target as **the entire `<VAULT>/raw/` tree** — record this as `RAW_TARGET=<unset>` and resolve it after Step 2.

## Step 2: Resolve the vault

Try in order; stop at the first success. Use `Bash` tool for each check:

1. **Explicit `--vault`** from step 1, if provided. Verify the path contains `WIKI.md`:
   ```bash
   test -f "<explicit-vault>/WIKI.md" && echo "OK" || echo "MISSING"
   ```
2. **Environment variable** `EXOMEMORY_VAULT` (preferred) or `CLAUDE_MEMORY_VAULT` (deprecated, falls back if `EXOMEMORY_VAULT` is unset; will be removed in v0.3):
   ```bash
   echo "${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
   ```
   If non-empty, verify `WIKI.md` exists at that path. If only the legacy `CLAUDE_MEMORY_VAULT` is set, also emit a deprecation warning to stderr.
3. **Ancestor search** from current working directory upward, looking for a directory containing `WIKI.md`:
   ```bash
   pwd
   d="$(pwd)"
   while [ "$d" != "/" ]; do
     if [ -f "$d/WIKI.md" ]; then echo "FOUND: $d"; break; fi
     d="$(dirname "$d")"
   done
   ```

If no vault is resolved, **stop** and reply:

```
Vault not found.
Set EXOMEMORY_VAULT to a vault path, pass --vault <path>, or cd into a vault.
Run /wiki-init <path> to create one.
```

Call the resolved absolute vault path `VAULT`.

## Step 3: Load the schema

Read `<VAULT>/WIKI.md`. **The WIKI.md is authoritative** — if it disagrees with anything below, WIKI.md wins.

## Step 4: Validate and enumerate raw inputs

If no positional raw target was supplied (`RAW_TARGET=<unset>` from Step 1), use `<VAULT>/raw/` as the target directory.

Otherwise, the raw argument can be absolute or relative to `<VAULT>/raw/`.

- If **absolute**: verify it exists. Check it is inside `<VAULT>/raw/` (prefix match on absolute paths). If outside, stop with error.
- If **relative**: interpret as `<VAULT>/raw/<arg>`. Verify the resolved absolute path exists.

If the target is a directory, recurse and collect every regular file inside.

When scanning `<VAULT>/raw/` with no filter (the no-argument case), it is normal for the set to include `raw/handovers/*.md` plus anything the user has manually dropped (e.g. `raw/papers/`, `raw/web/`). Unchanged files are detected in Step 5b and get `SKIP`, so scanning the whole tree is cheap even when most files are already ingested.

## Step 5: For each raw file, follow WIKI.md's ingest workflow

### 5.0 Skip empty raw files

Before computing identity, check whether the raw file has any meaningful content beyond YAML frontmatter. A file that contains only frontmatter (or only whitespace after the closing `---`) is an "empty session" and must not produce a wiki source page — those pages are noise.

Detection rule: strip the first YAML frontmatter block (from the opening `---` line to the matching closing `---` line), then check whether any non-whitespace characters remain.

```bash
# Returns 0 (true) if the file is empty after stripping frontmatter.
awk '
  BEGIN { in_fm = 0; past_fm = 0 }
  NR == 1 && /^---$/ { in_fm = 1; next }
  in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
  in_fm { next }
  past_fm && /[^[:space:]]/ { has_body = 1; exit }
  !past_fm && /[^[:space:]]/ { has_body = 1; exit }
  END { exit (has_body ? 1 : 0) }
' "<raw-file-abs>"
```

If empty, operation is `SKIP-empty`. Append `## [<today>] SKIP-empty | <slug>` to log.md once, and move to the next file. Do **not** create a wiki source page for it. Do not ERROR even if a stale source page happens to already exist — that case is handled by manual cleanup (future enhancement could auto-prune, but we don't do it here).

### 5a. Compute identity

Use Bash for the hash:

```bash
shasum -a 256 "<raw-file-abs>" | awk '{print $1}'
```

Derive:

- `source_id` = path relative to `<VAULT>/` with `raw/` prefix stripped, POSIX-separated
- `slug` = `source_id` with `/` → `--`, `.md` extension stripped (keep other extensions), unsafe chars replaced with `-`
- `source_hash` = output of the shasum above

### 5b. Decide operation

Read `<VAULT>/wiki/sources/<slug>.md` if it exists.

- Not exists → `CREATE`
- Exists, frontmatter `source_id` matches, `source_hash` matches → `SKIP`
- Exists, `source_id` matches, `source_hash` differs → `UPDATE`
- Exists, `source_id` does NOT match → `ERROR` (slug collision). Report to user, do not touch, move on.

### 5c. Execute

For **CREATE** or **UPDATE**:

1. Read the raw file
2. Extract: title, summary (2-4 paragraphs), key claims, mentioned entities, mentioned concepts, any contradictions with existing wiki content
3. Write `<VAULT>/wiki/sources/<slug>.md` using the Source Page Format from WIKI.md (frontmatter + Summary / Key Claims / Connections / Contradictions)
4. For each mentioned entity:
   - slug = kebab-case of canonical name
   - If `<VAULT>/wiki/entities/<slug>.md` does not exist → CREATE (About + Connections back to this source)
   - If exists → MERGE (append new Connection line; new About info appended as paragraph, do NOT overwrite)
5. For each mentioned concept: same pattern in `<VAULT>/wiki/concepts/`
6. Update `<VAULT>/wiki/index.md`:
   - Under the relevant section (Sources / Entities / Concepts), append `- [[<slug>]] — <title>` for each newly-created page. No duplicates.
7. Update `<VAULT>/wiki/overview.md`: append or lightly revise. **Do not rewrite from scratch**.
8. Append to `<VAULT>/wiki/log.md`: `## [<today>] CREATE | <slug>` (or `UPDATE` / `MERGE`). Get today's date:
   ```bash
   date +%Y-%m-%d
   ```

For **SKIP**: append `## [<today>] SKIP | <slug>` to log.md.

For **ERROR**: do not modify any file. Report collision to user.

## Step 6: Report

Summarize to the user:

```
Ingest complete.
  CREATE: N sources, M entities, K concepts
  UPDATE: ...
  MERGE (entities/concepts): ...
  SKIP: ...
  ERROR: ... (if any)

Wiki: <VAULT>/wiki/
```

## Notes

- Write changes in this order per file to stay atomic: entities/concepts MERGE → index → overview → sources → log. If the sources write fails, the wiki is still in a consistent state.
- Be conservative with entity/concept MERGE: if unsure two names refer to the same thing, prefer separate pages.
- Trust WIKI.md. Domain-specific conventions there override this file.
