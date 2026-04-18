---
description: Query the wiki and synthesize an answer with wikilink citations
argument-hint: <question> [--vault <path>] [--save]
allowed-tools: Bash(test:*), Bash(ls:*), Bash(pwd:*), Bash(echo:*), Bash(date:*), Read, Write, Edit, Glob, Grep
---

# /wiki-query

Answer a question by reading the active vault's wiki and synthesizing across pages.

Arguments received: `$ARGUMENTS`

## Step 1: Parse arguments

From `$ARGUMENTS`:
- Extract any `--vault <path>` flag
- Extract any `--save` flag (no value, just presence)
- The remainder (concatenated) is the question

If the question is empty, report usage and stop:
```
Usage: /wiki-query <question> [--vault <path>] [--save]
```

## Step 2: Resolve the vault

Same resolution as `/wiki-ingest`:

1. `--vault` if provided
2. `CLAUDE_MEMORY_VAULT` env var: !`echo "${CLAUDE_MEMORY_VAULT:-}"`
3. Ancestor search from cwd: !`pwd`, then walk up looking for `WIKI.md`

If none found, stop with:
```
Vault not found.
Set CLAUDE_MEMORY_VAULT, pass --vault, or cd into a vault.
```

Record as `$VAULT`.

## Step 3: Load the schema

Read `<VAULT>/WIKI.md` to understand page formats and wikilink conventions.

## Step 4: Identify relevant pages

1. Read `<VAULT>/wiki/index.md` to see what pages exist
2. Identify candidate pages relevant to the question:
   - Title match
   - Keyword overlap
   - Thematic relation
3. Optionally grep for specific terms across `<VAULT>/wiki/` if needed

## Step 5: Read candidates

For each candidate page, read its full content. Track which pages contributed which facts.

## Step 6: Synthesize

Compose an answer:

- Use `[[slug]]` wikilink citations inline for every significant claim, pointing to the page that supports it
- If pages contradict each other, surface the disagreement explicitly rather than picking one silently
- If the wiki does not adequately cover the question, say so plainly — do **not** fabricate or fill gaps from general knowledge. Suggest what to ingest next.

## Step 7: Output (and optional save)

Return the answer to the user.

If `--save` was specified:

1. Generate a `slug` from the question: kebab-case, lowercase, strip punctuation, max ~60 chars
2. Ensure `<VAULT>/wiki/syntheses/` exists (create if not)
3. Write `<VAULT>/wiki/syntheses/<slug>.md` with:
   ```yaml
   ---
   title: <the question>
   type: synthesis
   tags: [query]
   last_updated: YYYY-MM-DD
   ---
   ```
   followed by the answer (preserving `[[wikilink]]` citations)
4. Append to `<VAULT>/wiki/index.md` under the appropriate section (add a `## Syntheses` section if missing)
5. Append to `<VAULT>/wiki/log.md`: `## [YYYY-MM-DD] CREATE | syntheses/<slug>`
6. Today's date: !`date +%Y-%m-%d`

## Notes

- The wiki is the single source of truth for answering. Do not rely on your training knowledge unless explicitly asked to compare.
- Prefer concise, well-cited answers over long expository ones.
- If the question is ambiguous, ask a clarifying question instead of guessing.
