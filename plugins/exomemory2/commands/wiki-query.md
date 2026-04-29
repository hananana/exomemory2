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
2. `EXOMEMORY_VAULT` env var (preferred); falls back to `CLAUDE_MEMORY_VAULT` (deprecated, removed in v0.3 — emit a stderr warning when used):
   ```bash
   echo "${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
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
Set EXOMEMORY_VAULT, pass --vault, or cd into a vault.
```

Call the resolved absolute vault path `VAULT`.

## Step 2.5: Wait for any in-progress auto-ingest

To avoid reading a half-updated wiki while a background `claude -p "/wiki-ingest …"` (spawned by the SessionEnd / PreCompact hooks) is still writing, briefly wait for the lock to clear.

```bash
LOCK="<VAULT>/.ingest.lock"
WAIT_TIMEOUT=300  # seconds
waited=0
while [ -f "$LOCK" ]; do
  pid=$(cat "$LOCK" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    # Stale lock (process died without cleanup). Proceed.
    break
  fi
  if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
    echo "[wiki-query] auto-ingest still running after ${WAIT_TIMEOUT}s, proceeding with possibly inconsistent state" >&2
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
```

If `<VAULT>/.ingest.lock` is absent, this step is effectively a no-op — proceed immediately.

## Step 3: Load the schema

Read `<VAULT>/WIKI.md` for page formats and wikilink conventions.

## Step 4: Identify relevant pages

1. Read `<VAULT>/wiki/index.md` to see what pages exist
2. Select candidates by title match, keyword overlap, and thematic relation
3. Optionally grep across `<VAULT>/wiki/` for specific terms

## Step 4.5: Apply stale filter (v0.9+)

Filter the candidate set deterministically based on the rules below. **Run this as a Bash preprocess** — do not let LLM judgement drift this filter.

The filter excludes pages with `stale: true` from the candidate set unless one of the include-rules R-2 / R-3 / R-4 fires. Compute these once per `/wiki-query` invocation, before reading candidate bodies:

```bash
# Variables expected in scope: VAULT, QUESTION (raw question text), CANDIDATES (newline-separated absolute paths to wiki/*.md candidates)

# R-2: history keyword in the question (case-insensitive substring + 1 regex)
HISTORY_HIT=0
case "$QUESTION" in
  *history*|*History*|*HISTORY*) HISTORY_HIT=1 ;;
  *deprecated*|*DEPRECATED*) HISTORY_HIT=1 ;;
  *previous*|*PREVIOUS*) HISTORY_HIT=1 ;;
  *old*|*Old*|*OLD*) HISTORY_HIT=1 ;;
  *経緯*|*以前*|*昔*|*古い*|*廃止*) HISTORY_HIT=1 ;;
esac
# regex: なぜ.*やめ
if printf '%s' "$QUESTION" | grep -qE 'なぜ.*やめ'; then HISTORY_HIT=1; fi

# helper: check if page has stale: true in its frontmatter
is_stale() {
  awk '
    /^---$/ { state++; if (state == 2) exit; next }
    state == 1 && /^stale:[[:space:]]*true[[:space:]]*$/ { print "yes"; exit }
  ' "$1" | grep -q yes
}

# helper: get a frontmatter scalar value (first occurrence)
fm_value() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---$/ { state++; if (state == 2) exit; next }
    state == 1 {
      n = index($0, ":")
      if (n > 0) {
        line_key = substr($0, 1, n - 1)
        gsub(/[[:space:]]+$/, "", line_key)
        gsub(/^[[:space:]]+/, "", line_key)
        if (line_key == k) {
          val = substr($0, n + 1)
          gsub(/^[[:space:]]+/, "", val)
          gsub(/[[:space:]]+$/, "", val)
          if (val ~ /^".*"$/ || val ~ /^\x27.*\x27$/) val = substr(val, 2, length(val) - 2)
          print val
          exit
        }
      }
    }
  ' "$file"
}

# helper: extract the slug from a "[[slug]]" string (strip outer brackets)
unwrap_link() {
  printf '%s' "$1" | sed -E 's/^\[\[//; s/\]\]$//'
}

INCLUDE=()
SUPERSEDES_LINKS=()  # slugs to add via R-4 traversal

for c in $CANDIDATES; do
  base=$(basename "$c" .md)
  title=$(fm_value "$c" title)

  if ! is_stale "$c"; then
    # R-1: default include for non-stale
    INCLUDE+=("$c")
    # R-4 prep: collect supersedes link from this non-stale candidate
    sup=$(fm_value "$c" supersedes)
    if [ -n "$sup" ]; then
      SUPERSEDES_LINKS+=("$(unwrap_link "$sup")")
    fi
    continue
  fi

  # Page is stale. Apply R-2 / R-3.
  if [ "$HISTORY_HIT" = "1" ]; then
    INCLUDE+=("$c")  # R-2
    continue
  fi
  # R-3: question contains [[<slug>]] or exact title
  if printf '%s' "$QUESTION" | grep -qF "[[$base]]"; then
    INCLUDE+=("$c")
    continue
  fi
  if [ -n "$title" ] && printf '%s' "$QUESTION" | grep -qF "$title"; then
    INCLUDE+=("$c")
    continue
  fi
  # else: skip this stale page
done

# R-4 (supersession traversal): for each supersedes link captured above,
# include the corresponding stale page even though it didn't pass R-1..R-3.
for slug in "${SUPERSEDES_LINKS[@]}"; do
  for d in "$VAULT"/wiki/entities "$VAULT"/wiki/concepts; do
    cand="$d/$slug.md"
    if [ -f "$cand" ]; then
      already=0
      for inc in "${INCLUDE[@]}"; do
        if [ "$inc" = "$cand" ]; then already=1; break; fi
      done
      [ "$already" = "0" ] && INCLUDE+=("$cand")
    fi
  done
done
```

The resulting `INCLUDE` array is the set of pages to read in Step 5. Pages not in `INCLUDE` are dropped. If `INCLUDE` is empty after filtering, fall back to including every candidate that exists (ensures the user always gets some answer rather than a silent empty-result).

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
