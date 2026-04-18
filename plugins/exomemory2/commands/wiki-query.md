---
description: Query the wiki and synthesize an answer with wikilink citations
argument-hint: <question> [--vault <path>] [--save]
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# /wiki-query

Answer a question using the active vault's wiki, synthesizing across pages.

## Arguments

```
$ARGUMENTS
```

## Step 1: Parse arguments

If `$ARGUMENTS` is empty, stop and reply:

```
Usage: /wiki-query <question> [--vault <path>] [--save]
```

Otherwise, extract:
- `--vault <path>` flag, if present
- `--save` flag (boolean, present or absent)
- The remaining text (concatenated) is the **question**

If no question remains after removing flags, stop with the usage message.

## Step 2: Resolve the vault

Try in order:

1. `--vault <path>` from step 1 → verify `WIKI.md` exists there:
   ```bash
   test -f "<explicit-vault>/WIKI.md" && echo "OK" || echo "MISSING"
   ```
2. `CLAUDE_MEMORY_VAULT` env var:
   ```bash
   echo "${CLAUDE_MEMORY_VAULT:-}"
   ```
3. Ancestor search from cwd:
   ```bash
   pwd
   d="$(pwd)"
   while [ "$d" != "/" ]; do
     if [ -f "$d/WIKI.md" ]; then echo "FOUND: $d"; break; fi
     d="$(dirname "$d")"
   done
   ```

If none found, stop:

```
Vault not found.
Set CLAUDE_MEMORY_VAULT, pass --vault, or cd into a vault.
```

Call the resolved absolute vault path `VAULT`.

## Step 3: Load the schema

Read `<VAULT>/WIKI.md` for page formats and wikilink conventions.

## Step 4: Identify relevant pages

1. Read `<VAULT>/wiki/index.md` to see what pages exist
2. Select candidates by title match, keyword overlap, and thematic relation
3. Optionally grep across `<VAULT>/wiki/` for specific terms

## Step 5: Read candidates

Read each candidate page fully. Track which page supports which claim.

## Step 6: Synthesize

Compose the answer:

- Inline `[[slug]]` wikilink citations for every significant claim
- If pages contradict, surface the disagreement explicitly
- If the wiki does not cover the question, say so plainly. Do **not** fabricate or fill in from general knowledge. Suggest what to ingest next.

## Step 7: Output (and optional save)

Return the answer to the user.

If `--save` was specified:

1. Generate a `slug` from the question (kebab-case, lowercase, strip punctuation, max ~60 chars)
2. Ensure `<VAULT>/wiki/syntheses/` exists:
   ```bash
   mkdir -p "<VAULT>/wiki/syntheses"
   ```
3. Write `<VAULT>/wiki/syntheses/<slug>.md`:
   ```yaml
   ---
   title: <the question>
   type: synthesis
   tags: [query]
   last_updated: <today>
   ---
   ```
   followed by the answer (preserving `[[wikilink]]` citations)
4. Append to `<VAULT>/wiki/index.md` under a `## Syntheses` section (add if missing)
5. Append to `<VAULT>/wiki/log.md`: `## [<today>] CREATE | syntheses/<slug>`
6. Today's date:
   ```bash
   date +%Y-%m-%d
   ```

## Notes

- The wiki is the sole source of truth for the answer. Use training knowledge only when explicitly asked to compare.
- Prefer concise, well-cited answers over long expository ones.
- If the question is ambiguous, ask one clarifying question instead of guessing.
