---
description: Clip a web page into raw/web/ with Readability-extracted Markdown and downloaded images (content-addressed)
argument-hint: "[<url>] [--browser] [--batch <queue-file>] [--vault <path>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# /wiki-clip

Clip a web page into the active vault's `raw/web/` as a Readability-extracted Markdown file, with all embedded images downloaded into the content-addressed pool `raw/assets/`. The clipped file is picked up by the next `/wiki-ingest` run and folded into the knowledge layer.

Three fetch modes:
- **curl** (default for public URLs) — no auth, fastest
- **browser-use with URL** — opens the URL in the user's logged-in Chrome profile. Used automatically for known auth-walled domains (`notion.so`, `atlassian.net`, `slack.com`, `linear.app`, `docs.google.com`, etc.) or when forced with `--browser`, or as a fallback on HTTP 401/403
- **browser-use current tab** — when `/wiki-clip` is invoked with no URL, attaches to the user's running Chrome via CDP and clips whatever tab is active. Useful for pages you're already reading

## Arguments

```
$ARGUMENTS
```

## Step 1: Parse arguments

Tokenize `$ARGUMENTS` by whitespace. Extract:

- `--vault <path>` — optional explicit vault override
- `--batch <queue-file>` — if present, read URLs from `<queue-file>` (one URL per line) and process each in turn instead of treating the remaining token as a single URL
- `--browser` — force the browser-use path even if the URL looks public
- `--captured-by <value>` — optional override for the frontmatter `captured_by` field (defaults to `manual-clip`). `capture.sh` passes `auto-webfetch` when processing the queue
- The remaining positional token (after removing flags) is the **URL** to clip (ignored when `--batch` is used). **If no URL is given and `--batch` is absent, the active Chrome tab is clipped.**

Usage summary:

```
/wiki-clip                                   # clip current Chrome tab
/wiki-clip <url>                             # clip the given URL
/wiki-clip <url> --browser                   # force browser-use even for public URLs
/wiki-clip --batch <queue-file>              # batch mode (one URL per line)
```

## Step 2: Resolve the vault

Same 3-tier resolution as `/wiki-ingest`:

1. `--vault <path>` → verify `WIKI.md` exists
2. `EXOMEMORY_VAULT` env var (fall back to `CLAUDE_MEMORY_VAULT` with deprecation warning)
3. Ancestor search from `pwd`

If none resolves, stop:

```
Vault not found.
Set EXOMEMORY_VAULT, pass --vault, or cd into a vault.
```

Call the resolved absolute path `VAULT`.

## Step 3: Wait for in-progress auto-ingest

To avoid racing with `claude -p "/wiki-ingest ..."` spawned by hooks, briefly wait for `<VAULT>/.ingest.lock` to clear (same policy as `/wiki-query`):

```bash
LOCK="$VAULT/.ingest.lock"
WAIT_TIMEOUT=300
waited=0
while [ -f "$LOCK" ]; do
  pid=$(cat "$LOCK" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    break  # stale lock
  fi
  if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
    echo "[wiki-clip] auto-ingest still running after ${WAIT_TIMEOUT}s, proceeding anyway" >&2
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
```

## Step 4: Ensure output directories exist

```bash
mkdir -p "$VAULT/raw/web" "$VAULT/raw/assets"
```

## Step 5: Dispatch — batch, single URL, or current tab

If `--batch <queue-file>` was provided, iterate over non-empty, non-comment lines:

```bash
# Collect URLs from queue (dedup, ignore blanks and `#` comments)
urls=$(grep -vE '^\s*(#|$)' "<queue-file>" | awk '!seen[$0]++')
```

Then loop over `urls` applying Steps 6–13 to each. Accumulate per-URL outcomes (`CREATED`, `SKIPPED`, `FAILED`) for the final summary.

If a single URL was provided, skip the loop and run Steps 6–13 once.

If **no URL and no `--batch`** was provided, this is the **current-tab mode**. Resolve the URL from the user's running Chrome:

```bash
# Attach to user's Chrome via CDP (daemon stays alive across commands).
# Falls back to --profile Default if CDP connection is not available.
browser-use connect >/dev/null 2>&1 || {
  # If connect fails (no Chrome with CDP), we can't read "current tab".
  # Bail with guidance.
  echo "Cannot attach to Chrome via CDP. Either:" >&2
  echo "  1. Start Chrome with --remote-debugging-port=9222" >&2
  echo "  2. Or pass a URL explicitly: /wiki-clip <url>" >&2
  exit 1
}
URL=$(browser-use --json state 2>/dev/null | jq -r '.url // empty')
if [ -z "$URL" ] || [ "$URL" = "about:blank" ]; then
  echo "No active tab found, or current tab is blank." >&2
  exit 1
fi
NO_URL_MODE=1
echo "Clipping current tab: $URL"
```

In this mode, the HTML will be pulled from the already-loaded tab rather than re-fetched, preserving auth and JS-rendered content. Set `MODE=browser-current` so Step 8 takes the browser path.

## Step 6: Normalize the URL and derive the slug

For the given URL `U`:

1. **Strip fragment**: drop anything after `#` (fragments are client-side only)
2. **Strip query** (by default) — drop anything after `?`. Rationale: query strings are often tracking params (`utm_*`, session IDs) that don't change content. Edge cases where query is semantically significant (e.g. `https://example.com/search?q=foo`) are rare; we accept occasional over-dedup
3. **Parse** scheme, host, path:
   ```bash
   u="<URL>"
   # drop fragment
   u="${u%%#*}"
   # drop query
   u="${u%%\?*}"
   # strip scheme
   rest="${u#*://}"
   host="${rest%%/*}"
   path="/${rest#*/}"
   # handle URL with no path (e.g. https://example.com)
   [ "$host" = "$rest" ] && path=""
   ```
4. **Normalize host**: lowercase, replace `.` with `-`
   ```bash
   host_safe=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr '.' '-')
   ```
5. **Normalize path**:
   - Trim leading and trailing `/`
   - Replace `/` with `--`
   - Lowercase, replace any character outside `[a-z0-9._-]` with `-`
   - **Do not** run a dash-collapse (`-+` → `-`) step: that would destroy the `--` path separator. Accept that rare URLs with `//` produce `----`, which is ugly but functional
   ```bash
   path_trim="${path#/}"
   path_trim="${path_trim%/}"
   path_safe=$(printf '%s' "$path_trim" \
     | tr '[:upper:]' '[:lower:]' \
     | sed -E 's|/|--|g; s|[^a-z0-9._-]|-|g' \
     | sed -E 's|^-+||; s|-+$||')
   ```
6. **Assemble source_id and slug**:
   ```bash
   if [ -n "$path_safe" ]; then
     base="${host_safe}--${path_safe}"
   else
     base="$host_safe"
   fi
   # Truncate overly long bases to 120 chars (preserving prefix, adding short hash suffix for uniqueness)
   if [ ${#base} -gt 120 ]; then
     hash=$(printf '%s' "$base" | shasum -a 256 | cut -c1-8)
     base="${base:0:110}-${hash}"
   fi
   source_id="web/${base}.md"
   slug="web--${base}"
   target_file="$VAULT/raw/${source_id}"
   ```

7. **Non-ASCII host**: If `$host` contains non-ASCII bytes, Phase 1 does not attempt Punycode; emit a warning and fall back to URL-encoded form. Full Punycode handling is a future enhancement.

## Step 7: Dedup check

If `$target_file` already exists, **SKIP**. Do not touch the file (preserves `source_hash` invariant). Report:

```
SKIP: <slug> already exists (raw/web/<base>.md)
```

and move to the next URL (or finish if single-URL mode). Session attribution for this reuse is handled by the caller's handover containing the wikilink — no rewrite needed here.

## Step 7.5: Resolve fetch mode

If `MODE` was already set to `browser-current` in Step 5, skip this step.

Otherwise decide:

```bash
auth_domain_regex='notion\.so|notion\.site|atlassian\.net|atlassian\.com|slack\.com|linear\.app|docs\.google\.com|drive\.google\.com|sites\.google\.com'

if [ "$FORCE_BROWSER" = 1 ]; then
  MODE=browser-url
elif printf '%s' "$host" | grep -qiE "($auth_domain_regex)"; then
  MODE=browser-url
  echo "auth-walled domain detected: $host → using browser-use"
else
  MODE=curl
fi
```

`captured_by` defaults to `manual-clip`, but Phase 3's `--captured-by auto-webfetch` override stays respected.

## Step 8: Fetch the HTML

Three branches based on `$MODE`:

### 8a. `MODE=curl`

```bash
tmp_html=$(mktemp -t wiki-clip-html.XXXXXX)
http_code=$(curl -sSL -w '%{http_code}' -o "$tmp_html" \
  -A 'Mozilla/5.0 (wiki-clip/0.3)' \
  --max-time 30 \
  --max-filesize 20000000 \
  "$URL")
```

Outcomes:
- `http_code` is `200`: proceed to Step 9
- `http_code` is `401` or `403`: **auth-wall fallback** — discard this attempt, set `MODE=browser-url`, and re-enter Step 8 via the `browser-url` branch (single retry)
- `http_code` is `404`: report **FAILED** (page moved / deleted)
- `http_code` is other (5xx, timeout, etc.): report **FAILED** with the code
- `curl` exits non-zero: report **FAILED**

On terminal failures, `rm -f "$tmp_html"` and continue to the next URL.

### 8b. `MODE=browser-url`

Open the URL in the user's Chrome profile (which has their logins/cookies). Re-use the already-attached browser-use daemon if one was connected in Step 5; otherwise start fresh with the `Default` profile.

```bash
tmp_html=$(mktemp -t wiki-clip-html.XXXXXX)

# Prefer the existing CDP-attached instance (same as "current tab" path).
# If that fails, fall back to --profile Default, which spawns a fresh
# authenticated window.
if ! browser-use open "$URL" >/dev/null 2>&1; then
  browser-use --profile Default open "$URL" >/dev/null 2>&1 || {
    echo "FAILED: browser-use could not open $URL" >&2
    rm -f "$tmp_html"
    continue
  }
fi

# Wait for network-idle-ish state. Hacky but adequate for most pages.
browser-use wait text 'body' --timeout 10000 >/dev/null 2>&1 || true
sleep 2

# Get the rendered DOM of the active tab
if ! browser-use get html > "$tmp_html" 2>/dev/null || [ ! -s "$tmp_html" ]; then
  echo "FAILED: browser-use get html returned empty" >&2
  rm -f "$tmp_html"
  continue
fi
```

### 8c. `MODE=browser-current`

The URL was already resolved in Step 5 and the page is already loaded. Just pull the DOM:

```bash
tmp_html=$(mktemp -t wiki-clip-html.XXXXXX)
if ! browser-use get html > "$tmp_html" 2>/dev/null || [ ! -s "$tmp_html" ]; then
  echo "FAILED: could not read current tab HTML" >&2
  rm -f "$tmp_html"
  continue
fi
```

## Step 9: Readability extraction → Markdown

Run `readable` (from the `readability-cli` npm package, binary name `readable`) once with `--json` to get both metadata and extracted HTML in one pass. Use `--low-confidence force` so short or unusually-structured articles are still processed rather than rejected:

```bash
readable_json=$(readable --base "<URL>" --json --low-confidence force "$tmp_html" 2>/dev/null)
if [ -z "$readable_json" ]; then
  echo "FAILED: readable extraction error" >&2
  rm -f "$tmp_html"
  continue
fi

title=$(printf '%s' "$readable_json" | jq -r '.title // empty')
byline=$(printf '%s' "$readable_json" | jq -r '.byline // empty')
html_content=$(printf '%s' "$readable_json" | jq -r '.["html-content"] // empty')

if [ -z "$html_content" ]; then
  echo "FAILED: readable returned no html-content" >&2
  rm -f "$tmp_html"
  continue
fi

# Fallback title: derived from URL's last path segment, or host
if [ -z "$title" ]; then
  title="${path_safe##*--}"
  [ -z "$title" ] && title="$host_safe"
fi

# Convert to Markdown (gfm-raw_html drops <div>/<span> junk but keeps <img>)
tmp_md=$(mktemp -t wiki-clip-md.XXXXXX)
printf '%s' "$html_content" \
  | pandoc -f html -t gfm-raw_html --wrap=none -o "$tmp_md" || {
  echo "FAILED: pandoc conversion error" >&2
  rm -f "$tmp_html" "$tmp_md"
  continue
}
```

## Step 10: Extract and download images

Scan `$tmp_md` for Markdown image references `![alt](url)` and download each into `raw/assets/` with content-addressed naming.

```bash
# Extract image URLs (pandoc produces ![](u) form)
image_urls=$(grep -oE '!\[[^]]*\]\([^)]+\)' "$tmp_md" \
  | sed -E 's/^!\[[^]]*\]\(([^)]+)\)$/\1/' \
  | awk '!seen[$0]++')

declare -A url_to_local  # associative: remote URL → "../assets/<hash>.<ext>"

for img_url in $image_urls; do
  # Resolve relative URLs against page URL
  case "$img_url" in
    http://*|https://*) abs_url="$img_url" ;;
    //*) abs_url="https:$img_url" ;;
    /*) abs_url="https://${host}${img_url}" ;;
    *) abs_url="$(dirname "$URL")/$img_url" ;;
  esac

  img_tmp=$(mktemp -t wiki-clip-img.XXXXXX)
  dl_ok=0

  # Primary: curl. Works for any public or signed-URL image.
  if curl -fsSL --max-time 30 --max-filesize 20000000 \
        -A 'Mozilla/5.0 (wiki-clip/0.3)' \
        -o "$img_tmp" "$abs_url" 2>/dev/null; then
    [ -s "$img_tmp" ] && dl_ok=1
  fi

  # Fallback for browser modes: fetch via the page's own origin so
  # authenticated images (Notion signed URLs, Confluence attachments, etc.)
  # come through with the user's cookies.
  if [ "$dl_ok" = 0 ] && [ "$MODE" != "curl" ]; then
    js=$(cat <<'JS'
(async (u) => {
  try {
    const r = await fetch(u, { credentials: 'include' });
    if (!r.ok) return null;
    const b = await r.blob();
    const data = await new Promise(res => {
      const fr = new FileReader();
      fr.onloadend = () => res(fr.result);
      fr.readAsDataURL(b);
    });
    return data;  // "data:<mime>;base64,<payload>"
  } catch (e) { return null; }
})(%URL%)
JS
)
    # Safely inject the URL as a JS string literal
    js_url=$(printf '%s' "$abs_url" | sed -E 's|\\|\\\\|g; s|"|\\"|g')
    js_invoke="${js/%URL%/\"$js_url\"}"
    data_uri=$(browser-use eval "$js_invoke" 2>/dev/null | tr -d '\r\n')
    # Strip outer quotes if browser-use returned a JSON string
    data_uri="${data_uri#\"}"; data_uri="${data_uri%\"}"
    if [ -n "$data_uri" ] && [ "$data_uri" != "null" ]; then
      # data:image/png;base64,XXXX...  →  decode to file
      payload="${data_uri#*base64,}"
      if [ "$payload" != "$data_uri" ] && printf '%s' "$payload" | base64 -D > "$img_tmp" 2>/dev/null; then
        [ -s "$img_tmp" ] && dl_ok=1
      fi
    fi
  fi

  if [ "$dl_ok" = 0 ]; then
    echo "  warn: image DL failed: $abs_url" >&2
    rm -f "$img_tmp"
    continue  # leave original URL in Markdown
  fi

  # Compute hash
  img_hash=$(shasum -a 256 "$img_tmp" | awk '{print $1}')

  # Determine extension: prefer Content-Type via curl -I, fall back to URL suffix, default png
  ext=$(printf '%s' "$abs_url" | sed -E 's|.*\.([a-zA-Z0-9]{1,5})(\?.*)?$|\1|' | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    jpg|jpeg|png|gif|webp|svg|avif|bmp|ico) : ;;  # OK
    *)
      # Sniff via file(1) as fallback
      mime=$(file -b --mime-type "$img_tmp")
      case "$mime" in
        image/jpeg) ext=jpg ;;
        image/png) ext=png ;;
        image/gif) ext=gif ;;
        image/webp) ext=webp ;;
        image/svg+xml) ext=svg ;;
        image/avif) ext=avif ;;
        *) ext=bin ;;  # unknown; still saved
      esac
      ;;
  esac

  dest="$VAULT/raw/assets/${img_hash}.${ext}"
  if [ ! -f "$dest" ]; then
    mv "$img_tmp" "$dest"
  else
    rm -f "$img_tmp"  # dedup: same bytes already present
  fi

  url_to_local[$img_url]="../assets/${img_hash}.${ext}"
done
```

## Step 11: Rewrite image paths

For each entry in `url_to_local`, replace occurrences in `$tmp_md`. Use an explicit `sed` with a delimiter unlikely to appear in URLs:

```bash
for orig in "${!url_to_local[@]}"; do
  local_path="${url_to_local[$orig]}"
  # escape sed special chars in the original URL
  orig_esc=$(printf '%s' "$orig" | sed -E 's|[&/\|]|\\&|g')
  local_esc=$(printf '%s' "$local_path" | sed -E 's|[&/\|]|\\&|g')
  sed -i '' -E "s|\]\(${orig_esc}\)|](${local_esc})|g" "$tmp_md"
done
```

(On Linux, `sed -i` without the empty string; adapt if we support non-macOS in future.)

## Step 12: Compose and write the raw file

Build the final frontmatter + body:

```bash
captured_by="${CAPTURED_BY_OVERRIDE:-manual-clip}"  # overridden via --captured-by
now_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
today=$(date '+%Y-%m-%d')

# YAML-escape title (double-quote, backslash-escape embedded quotes and backslashes)
title_yaml=$(printf '%s' "$title" | sed -E 's/\\/\\\\/g; s/"/\\"/g')

# Assemble the file
{
  printf -- '---\n'
  printf 'title: "%s"\n' "$title_yaml"
  printf 'type: source\n'
  printf 'tags: [web-clip]\n'
  printf 'source_id: %s\n' "$source_id"
  printf 'source_url: %s\n' "<URL>"
  printf 'captured_at: %s\n' "$now_utc"
  printf 'captured_by: %s\n' "$captured_by"
  printf 'last_updated: %s\n' "$today"
  [ -n "$byline" ] && printf 'byline: "%s"\n' "$(printf '%s' "$byline" | sed -E 's/\\/\\\\/g; s/"/\\"/g')"
  printf -- '---\n\n'
  cat "$tmp_md"
} > "$target_file"
```

**Critical invariants** (per WIKI.md "Notes on web clips"):
- Do **not** include `source_hash` in the frontmatter (`/wiki-ingest` recomputes from raw bytes)
- Do **not** include `referenced_by` (that would force re-writing later and break `source_hash` stability)
- Do **not** re-write this file later for any reason. Session attribution lives in the caller's handover wikilinks

Clean up temp files:

```bash
rm -f "$tmp_html" "$tmp_md"
```

## Step 13: Report

For single-URL mode, reply with:

```
CREATED: raw/web/<base>.md
  title: <title>
  images: <N> downloaded, <M> dedupped
  next: /wiki-ingest will pick this up on the next run
```

For `--batch` mode, summarize:

```
Batch complete.
  CREATED: <n>
  SKIPPED: <k>  (already clipped)
  FAILED:  <m>  (see individual errors above)
```

## Notes

- This skill deliberately does **not** update `wiki/` — that is `/wiki-ingest`'s job and is deferred to the next ingest cycle
- On `SKIP` (file exists), the skill does not modify the raw file. Session attribution is the caller's responsibility — for auto-clip via `PostToolUse[WebFetch]`, `capture.sh` writes the wikilink into the handover, and `/wiki-ingest` builds the handover → clip Connection from there
- Image download failures are non-fatal: the original URL stays in the Markdown, and the clip still succeeds with whatever images did download
- For auth-walled domains (Notion, Confluence, Slack, etc.), the skill relies on the user's Chrome profile already being logged in. If the page redirects to a login screen, the clip will contain the login HTML rather than the real content — inspect the output and re-authenticate if needed
- **Current-tab mode** (`/wiki-clip` with no URL) requires Chrome to have been launched with `--remote-debugging-port=9222` so browser-use can attach via CDP. If that's not available, pass the URL explicitly
- Corporate data handling: clipping authenticated pages from work tools (Notion, Confluence, private repos) may conflict with DLP / data-handling policies at your organization. Confirm before clipping internal docs
