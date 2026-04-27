<h1 align="center">exomemory2</h1>

<p align="center">
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/hananana/exomemory2?color=blue"></a>
    <a href="https://github.com/hananana/exomemory2/releases"><img alt="Version" src="https://img.shields.io/github/v/tag/hananana/exomemory2"></a>
    <a href="https://docs.claude.com/en/docs/claude-code"><img alt="Claude Code Plugin" src="https://img.shields.io/badge/Claude_Code-Plugin-D97757"></a>
</p>

<h4 align="center">
    <p>
        <a href="./README.md">日本語</a> |
        <b>English</b>
    </p>
</h4>

<h3 align="center">
    <p>An external memory that lets Claude grow its own wiki from your conversations</p>
</h3>

A Claude Code plugin that implements [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) as an external memory for Claude.

**The focus is automation.** Every time a session ends, the conversation is saved to the vault's `raw/` directory, and once enough has accumulated, Claude is spawned in the background to compile the raw material into an interlinked markdown wiki. You don't have to do anything — the knowledge graph grows on its own as you keep using Claude.

Starting with v0.3, **web pages Claude reads via `WebFetch` also flow into the wiki automatically** (explicit clipping via `/wiki-clip` is also supported; authenticated pages go through `browser-use` to reuse your Chrome login session). Everything you and Claude read together gets captured.

As of v0.4, the accumulated wiki is queryable via **Obsidian Dataview**. Source pages are auto-tagged with `source_type` / `word_count` / `reading_time_min` / `domain` frontmatter, and `wiki/dashboards/` ships 8 pre-built views (recent sources, clips by domain, popular entities, orphan concepts, etc.). Existing vaults can be upgraded in place with `/wiki-migrate`.

As of v0.5, `wiki/index.md` embeds a **GitHub-style yearly activity heatmap** at the top (requires the [Contribution Graph](https://github.com/vran-dev/obsidian-contribution-graph) plugin). Opening the vault gives you an at-a-glance view of when and how much you've captured. DataviewJS is not required, so JS Queries can stay OFF. v0.5 also renames `/wiki-migrate-dataview` to `/wiki-migrate` (**breaking change**).

v0.6 adds a **Dataview `CALENDAR` monthly view** right below the heatmap, showing the daily density of Claude handover captures. No extra plugin needed (Dataview only, still no DataviewJS). The axis uses `last_captured_at` from `raw/handovers/*.md`, which is stable across re-ingests and page edits.

v0.8 adds **SessionStart orphan rescue**. When Claude Code dies via SIGHUP (e.g. `tmux prefix + x` killing the pane before SessionEnd hook can fire), the next session boot detects un-handovered transcripts and stranded clip queues, then rebuilds and ingests them in the background. Captures and ingest no longer leak through any close path, including hard kills. v0.8.1 caps each rescue/auto-ingest invocation at `INGEST_BATCH_SIZE` records (default 10), so initial large backfills or accumulated dirty piles no longer hang a single `claude -p` run. v0.8.1 also fixes a subagent-induced misclassification where a successful clip phase was marked as failed. v0.8.2 reads `last_captured_at` from the transcript's first message instead of "now", so rescued handovers no longer cluster on the rebuild date in the calendar; it also stops spawning useless ingest runs when dirty=0, and ships a CSS snippet that caps day-cell height in the Handover calendar so dense days don't break the monthly grid. Running `/wiki-migrate` once backfills `last_captured_at` on pre-v0.8.2 handovers. v0.8.3 hot-fixes the v0.8.2 CSS snippet whose selectors didn't match Dataview's actual DOM — the finalized version uses `table-layout:fixed` plus aggressive `!important` overrides on `.day` / `.dot-container`, verified against a vault with 30 dots in a single day.

Manual `/wiki-ingest` / `/wiki-query` commands are also provided, but they're secondary — for when you want to explicitly ingest external sources (papers) dropped into `raw/`, or query the accumulated wiki directly.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Obsidian (recommended frontend)](#obsidian-recommended-frontend)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Web clipping (v0.3+)](#web-clipping-v03)
- [Dataview dashboards (v0.4+)](#dataview-dashboards-v04)
- [Auto-ingest (v0.2+)](#auto-ingest-v02)
- [Vault layout](#vault-layout)
- [Design notes](#design-notes)
- [Roadmap](#roadmap)
- [Migrating from exomemory v1](#migrating-from-exomemory-v1)
- [License](#license)

## Requirements

| Item | Purpose | Required? |
|---|---|---|
| `jq` | Capture hook uses it to extract transcript JSON | Required |
| `python3` | Used by `/wiki-init` for path expansion (ships on macOS / most Linux distros by default) | Required |
| [Obsidian](https://obsidian.md) | **Strongly recommended.** Technically optional — the vault is plain Markdown and works in any editor — but the UX Karpathy's original gist assumes (Graph View / Backlinks / Web Clipper / Dataview) only comes together in Obsidian. Skipping it means losing half of the LLM-wiki pattern | Recommended |
| `readable` ([readability-cli](https://www.npmjs.com/package/readability-cli), `npm i -g readability-cli`) | `/wiki-clip` and auto-clip use it to extract article bodies from HTML | Required for v0.3 features |
| [`pandoc`](https://pandoc.org) | `/wiki-clip` uses it for HTML→Markdown conversion | Required for v0.3 features |
| [`browser-use`](https://github.com/browser-use/browser-use) | Fetches authenticated pages (Notion / Confluence / etc.) and the current tab via CDP | Required when clipping auth-walled pages |

## Install

From within Claude Code:

```
/plugin marketplace add hananana/exomemory2
/plugin install exomemory2@exomemory2
```

## Obsidian (recommended frontend)

The vault is plain Markdown, so it works in any editor. But to get the UX [Karpathy's original pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) assumes (Graph View, Backlinks, Web Clipper, Dataview), **Obsidian is the shortest path**.

### Install

- macOS: `brew install --cask obsidian`
- Linux / Windows: https://obsidian.md/download

### Open the vault

Launch Obsidian → "Open folder as vault" → pick the path you created with `/wiki-init`.

### What the bundled preset enables

Every vault created by `/wiki-init` includes an `.obsidian/` directory preconfigured with:

- **Core plugins enabled**: Graph view, Backlinks, Outgoing links, Tag pane, Properties, Page preview, etc.
- **Graph View color groups**:
  - `wiki/sources/` → blue
  - `wiki/entities/` → green
  - `wiki/concepts/` → orange

### Recommended community plugins (install separately in Obsidian)

- **Dataview** — **effectively required from v0.4 onward.** The 8 dashboards shipped under `wiki/dashboards/` and the v0.6 Handover calendar on `index.md` all rely on Dataview. Without it, the code blocks just show as source. See [Dataview dashboards](#dataview-dashboards-v04). JavaScript Queries (DataviewJS) can stay OFF — everything works with plain DQL
- **Contribution Graph** — **for the v0.5 Activity heatmap on `index.md`**. Obsidian → Settings → Community plugins → search "Contribution Graph". If not installed, the heatmap code block at the top of `index.md` just renders as source; nothing else breaks (the v0.6 Handover calendar is a pure Dataview query and does not depend on this plugin)

### Applying the `.obsidian/` preset to an existing vault

For vaults created before this preset existed:

**Case A: vault has no `.obsidian/` yet**

```bash
SRC=$(ls -d ~/.claude/plugins/cache/exomemory2/exomemory2/*/template/.obsidian | sort | tail -1)
cp -R "$SRC" <your-vault>/.obsidian
```

**Case B: vault already has `.obsidian/`**

Do not overwrite — back up and merge manually:

```bash
# 1. Back up
cp -R <your-vault>/.obsidian <your-vault>/.obsidian.bak

# 2. See the diff
SRC=$(ls -d ~/.claude/plugins/cache/exomemory2/exomemory2/*/template/.obsidian | sort | tail -1)
diff -r "$SRC" <your-vault>/.obsidian
```

Then apply selectively:

- `graph.json`: merge the three `colorGroups` entries from template into your existing array (do not replace the whole file)
- `core-plugins.json`: add plugin names you don't have yet (never overwrite)
- `app.json` / `appearance.json`: template ships empty; keep your existing files

Remove the backup once you're satisfied: `rm -rf <your-vault>/.obsidian.bak`

## Quick start

### 1. Create a vault

```
/wiki-init
```

This creates a vault skeleton at `~/vault` containing `WIKI.md`, `raw/`, `wiki/`, and `.obsidian/` (recommended preset). Pass an explicit path if you want somewhere else: `/wiki-init ~/vault-personal`.

### 2. Set `EXOMEMORY_VAULT`

The auto-capture hook only reads the environment variable, so conversations won't be saved without this. Add to `~/.zshrc`:

```bash
export EXOMEMORY_VAULT=~/vault
```

### 3. Open the vault in Obsidian

Obsidian → "Open folder as vault" → `~/vault` (or whatever path you used above). The bundled preset activates recommended core plugins and color-codes the graph (sources blue / entities green / concepts orange). See the [Obsidian](#obsidian-recommended-frontend) section above for install details.

### That's it — just keep using Claude

On every `/compact` and session exit, the conversation is saved to `raw/handovers/`. Once enough accumulate, Claude is spawned in the background to compile them into the wiki. Leave Obsidian's Graph View open to watch it grow.

### When you want to recall something from the wiki

Ask `/wiki-query` directly:

```
/wiki-query "What did we figure out during the auto-ingest bug investigation last week?"
```

Claude synthesizes an answer from the relevant pages with `[[wikilink]]` citations. For manually ingesting external sources (papers, web clippings), see [Commands](#commands).

## Commands

| Command | Purpose |
|---|---|
| `/wiki-init [<vault-path>]` | Scaffold a new vault (defaults to `~/vault`) |
| `/wiki-ingest [<file-or-dir>] [--vault <path>]` | Compile raw sources into wiki pages (no argument = scan whole `raw/`) |
| `/wiki-query <question> [--vault <path>] [--save]` | Synthesize an answer from the wiki |
| `/wiki-clip [<url>] [--browser] [--batch <queue>]` (v0.3+) | Clip a web page into `raw/web/` with images into `raw/assets/`. URL omitted ⇒ clip the current Chrome tab |
| `/wiki-gc [--dry-run] [--purge-older-than <days>]` (v0.3+) | Move orphan images to `.trash/`; physically delete entries older than 90 days |
| `/wiki-migrate [--dry-run] [--skip-schema-update] [--force]` (v0.5+) | Retrofit a vault from an older version to the current schema (v0.4 frontmatter fields + dashboards + v0.5 index heatmap). Named `/wiki-migrate-dataview` in v0.4 |

## Web clipping (v0.3+)

Expands the input side of the wiki from handovers alone (Claude conversation logs) to **web pages Claude reads**. Three channels feed `raw/web/`:

| Channel | Trigger | Use case |
|---|---|---|
| **auto-webfetch** | Claude calls `WebFetch` | When you ask Claude to "read this article", the URL is auto-captured. A `PostToolUse[WebFetch]` hook queues the URL and SessionEnd runs batch clip |
| **manual clip** | `/wiki-clip <url>` | Clip an explicit URL. Public URLs go through `curl + readable`; auth-walled domains (`notion.so` etc.) auto-switch to `browser-use` |
| **current tab** | `/wiki-clip` (no args) | Clip the Chrome tab you're reading right now. Requires Chrome launched with `--remote-debugging-port=9222` |

### Pipeline

```
Fetch HTML (curl or browser-use)
  ↓
readable extracts the article body (Readability.js)
  ↓
pandoc converts HTML → Markdown
  ↓
Download images (curl, fallback to page-context fetch via browser-use for auth walls)
  ↓
Save images content-addressed: raw/assets/<sha256>.<ext>
  ↓
Rewrite Markdown image refs to ../assets/<hash>.<ext>
  ↓
Write raw/web/<slug>.md (frontmatter is immutable after creation)
```

### Auth-walled domains

These automatically route through the browser-use path (reusing your Chrome profile's login session):

```
notion.so, notion.site, atlassian.net, atlassian.com,
slack.com, linear.app, docs.google.com, drive.google.com
```

Pass `--browser` to force browser-use for any URL.

### Session attribution (handover bridge)

Auto-captured clips get listed in the session's handover as a "Clips Captured" section:

```markdown
## Clips Captured in This Session

- [[web--gist-github-com--karpathy--442a6b...]] — https://gist.github.com/karpathy/442a6bf...
```

When the next `/wiki-ingest` runs, that wikilink creates a **handover → web-clip Connection in `wiki/sources/handovers--xxx.md` automatically**, so you can trace which session read which article through the wiki graph.

### Image pool & `/wiki-gc`

Images are content-addressed (`<sha256>.<ext>`), so the same image reused across articles stores only once. Deleting a clip leaves its images in the pool — run `/wiki-gc` periodically to sweep orphans:

```
/wiki-gc --dry-run                    # report counts and sample only
/wiki-gc                              # move orphans to raw/assets/.trash/<today>/
/wiki-gc --purge-older-than 90        # physically delete .trash/ entries older than 90 days (default)
```

Logical delete first, so recovery within 90 days is always possible.

### Configuration

`<vault>/.exomemory-config` keys added in v0.3 (INT-only, same strict parser as AUTO_INGEST):

```
# Auto-capture of WebFetch URLs (1 = enabled, 0 = disabled)
AUTO_CLIP=1

# Cap per-session auto-capture queue to prevent runaway
AUTO_CLIP_MAX_PER_SESSION=20
```

## Dataview dashboards (v0.4+)

Every source page gets **Dataview-queryable frontmatter**, and `wiki/dashboards/` ships 8 pre-built views. Enable the Dataview community plugin in Obsidian and they light up out of the box.

### Added frontmatter fields

Common to all source pages:

| Field | Meaning |
|-------|---------|
| `source_type` | `handover` / `web-clip` / `manual` (derived from `source_id` prefix) |
| `word_count` | Whitespace tokens in the raw body |
| `reading_time_min` | `ceil(word_count / 200)` |

Handover-only: `session_id` (the Claude session UUID).
Web-clip-only: `source_url`, `domain`, `captured_at`, `captured_by` (forwarded from the raw frontmatter).

Entity and concept pages are **unchanged** — Dataview's native fields (`length(file.inlinks)`, `file.ctime`, `file.mtime`) cover the same queries without needing retrofit frontmatter.

### Shipped dashboards (`wiki/dashboards/`)

| File | Purpose |
|------|---------|
| `recent.md` | Source pages updated in the last 30 days |
| `by-source-type.md` | Counts grouped by `source_type` |
| `by-domain.md` | Web clips grouped by `domain` |
| `handovers-timeline.md` | Claude sessions, newest first, with length proxies |
| `popular-entities.md` | Entities ranked by inbound wikilink count |
| `orphan-concepts.md` | Concepts with ≤ 1 inbound link (pruning candidates) |
| `long-reads.md` | Sources with `reading_time_min >= 10` |
| `README.md` | Dashboard index and frontmatter reference |

### Upgrading an existing vault

Vaults from older versions can be upgraded in place with `/wiki-migrate`:

```
/wiki-migrate --dry-run     # Preview changes without writing
/wiki-migrate               # Actually retrofit
```

(In v0.4 this command was called `/wiki-migrate-dataview`. It was renamed in v0.5 as a breaking change.)

What it does:

1. Adds derived frontmatter fields to every `wiki/sources/*.md` (body untouched, unknown keys preserved)
2. Replaces `WIKI.md` with the current template when the line-1 schema marker is absent or older (keeps `WIKI.md.bak`)
3. Copies `wiki/dashboards/` if missing (never overwrites existing dashboards)
4. (v0.5+) Inserts the `## Activity heatmap` section into `wiki/index.md` after the `# Index` heading if missing. If the heading is customized (user-edited, translated, etc.), the command skips with a warning; use `--force` to prepend instead. `index.md.bak` is created on edit.

**Idempotent**: re-running produces zero diff (derived fields are pure functions). Re-running after a bugfix release naturally re-aligns every page.

Pass `--skip-schema-update` to keep a hand-customized `WIKI.md` and `wiki/dashboards/` intact — page-level retrofit still runs.

### Enabling Dataview in Obsidian

Settings → Community plugins → Browse → search "Dataview" → Install + Enable. DataviewJS is not required (all shipped dashboards are plain DQL).

### Enabling Contribution Graph in Obsidian (v0.5+, for the Activity heatmap)

The Activity heatmap embedded at the top of `wiki/index.md` is rendered by [Contribution Graph](https://github.com/vran-dev/obsidian-contribution-graph). Install it the same way:

Settings → Community plugins → Browse → search "Contribution Graph" → Install + Enable.

DataviewJS is not required — the plugin provides its own `contributionGraph` code block, so JS Queries can stay OFF. If the plugin is not installed, `index.md` still opens fine; the code block is just shown as source.

## Auto-ingest (v0.2+)

After each PreCompact / SessionEnd, capture.sh evaluates a gate and, if all conditions hold, spawns a background `claude -p` to ingest the new handovers. **Enabled by default.**

### Flow

```
User runs /compact or /exit
  ↓
capture.sh writes handover to raw/handovers/<session-id>.md
  ↓
Gate check:
  - <vault>/.exomemory-config: AUTO_INGEST=1?
  - dirty count ≥ AUTO_INGEST_THRESHOLD?
  - elapsed since last ingest ≥ AUTO_INGEST_INTERVAL_SEC?
  ↓ all yes
nohup claude -p "/exomemory2:wiki-ingest raw/handovers/" & disown
  ↓
hook returns immediately (a few ms) — your terminal closes
  ↓ (in the background, ~2-3 min)
wiki/ updated, log.md appended, .last-ingest updated
  ↓
process exits, lock released
```

`/exit` still returns instantly. The background ingest survives `tmux kill-server` and Terminal.app close (adopted by `launchd`); it stops on macOS shutdown / logout.

### Configuration: `<vault>/.exomemory-config`

Bundled with every `/wiki-init` vault. **Strictly parsed** as `KEY=INT` lines (never `source`d, to prevent shell injection through vault content):

```
AUTO_INGEST=1                   # 1 = enabled (default), 0 = disabled
AUTO_INGEST_THRESHOLD=3         # min dirty handovers to trigger
AUTO_INGEST_INTERVAL_SEC=1800   # min seconds between runs
```

**To disable auto-ingest entirely**, set `AUTO_INGEST=0`.

### Concurrency control

`<vault>/.ingest.lock` holds the spawning subshell's PID. Stale locks are detected via `kill -0` (no time-based lease — long ingests are safe). `/wiki-query` waits up to 5 minutes for a held lock to clear, ensuring read consistency.

### Scope

- **handovers + auto-clipped web pages**: `raw/handovers/*.md` drives the dirty-count gate, and from v0.3 onward the URLs queued by `PostToolUse[WebFetch]` are batch-clipped at SessionEnd and then ingested in the same flow
- Manually populated sources like `raw/papers/` still require explicit `/wiki-ingest raw/papers/` — they don't count toward the dirty threshold, so they won't trigger surprise LLM runs
- Batch clip and ingest have **independent gates**: clip runs whenever the queue has URLs; ingest runs on the usual dirty ≥ threshold && interval elapsed gate

### State files (gitignored)

- `.ingest.log` — full stream-json output of background runs (debug)
- `.last-ingest` — last completion timestamp (epoch seconds)
- `.ingest.lock` — held during a run

The template `.gitignore` covers these. `.exomemory-config` is **not** ignored; commit it if you wish.

### SessionStart hook

On new sessions, exomemory2 injects a one-liner into Claude's hidden context: `exomemory2: last auto-ingest at YYYY-MM-DD HH:MM:SS (Nm ago)`. This lets Claude notice wiki freshness and silent ingest failures without bothering the user.

### Cost / runtime (measured)

Roughly **160 seconds / 31 turns** per handover. With Claude Max plan auth (`apiKeySource: none`), no extra billing — but it consumes plan quota. Defaults (`THRESHOLD=3`, `INTERVAL=1800`) aim for one or two runs per day, not per session.

### Requirements

- `claude` CLI in PATH (capture.sh checks with `command -v claude` and silent-skips otherwise)
- vault has `WIKI.md`
- `jq` in PATH (shared with the capture path)

## Vault layout

```
<vault>/
├── WIKI.md                 # Schema and workflow (authoritative for Claude)
├── .obsidian/              # Obsidian preset (graph color groups, core plugins enabled)
├── raw/                    # Immutable source documents (user drops files here)
│   ├── handovers/          # Auto-captured conversations
│   ├── web/                # Web clips (v0.3+, via /wiki-clip and auto-webfetch)
│   └── assets/             # Image pool (v0.3+, content-addressed <sha256>.<ext>)
└── wiki/                   # LLM-maintained knowledge layer
    ├── index.md
    ├── log.md
    ├── overview.md
    ├── sources/            # One page per raw source
    ├── entities/           # People, organizations, projects, products
    ├── concepts/           # Ideas, frameworks, methods, theories
    └── dashboards/         # Obsidian Dataview views (v0.4+)
```

Every page is plain Markdown with YAML frontmatter and `[[wikilink]]` cross-references. Works with Obsidian, VS Code, or any Markdown viewer. If you don't use Obsidian, `.obsidian/` is harmless — ignore or delete it.

## Design notes

- **Claude Code only** — commands and hooks are Claude-Code-native. No Python tooling to maintain.
- **File over app** — the wiki is just Markdown files; no lock-in. Obsidian is the recommended frontend, but the data is plain Markdown, so VS Code or any other viewer works too.
- **Compounds over time** — entity and concept pages are MERGEd across sources, never overwritten.
- **Local by default** — no cloud, no account. Your vault is yours.

## Roadmap

- [x] v0.2: Auto-ingest machinery (dirty-count gate + background spawn)
- [x] v0.3: Input-layer expansion — `/wiki-clip`, `PostToolUse[WebFetch]` auto-capture, `browser-use` for auth walls, `/wiki-gc` for orphan images
- [x] v0.4: Dataview support — auto-populated `source_type` / `word_count` / `domain` frontmatter, 8 shipped dashboards under `wiki/dashboards/`, `/wiki-migrate` for retrofitting existing vaults
- [x] v0.5: GitHub-style activity heatmap on `index.md` (Contribution Graph plugin; no DataviewJS) + `/wiki-migrate-dataview` renamed to `/wiki-migrate` (breaking change)
- [x] v0.6: Handover calendar (monthly view) on `index.md` via the built-in Dataview `CALENDAR` query — no extra plugin. `/wiki-migrate`'s index-section-insert logic is now driven by a `SECTIONS` list for easy extension.
- [ ] Later: pipeline to publish the vault as a static HTML site (e.g. via Quartz)

## Migrating from exomemory v1

The v1 plugin (`hananana/exomemory`) will be deprecated and archived once v2 stabilizes. To switch:

1. In your Claude Code `settings.json`, replace `exomemory` references with `exomemory2`:
   - `extraKnownMarketplaces`
   - `enabledPlugins`
2. Run `/wiki-init <path>` to create a fresh vault
3. Optionally migrate useful content from v1 memory files into `raw/` and re-ingest

v1's tiered memory (episodic/semantic/procedural) does not map 1:1 onto v2's sources/entities/concepts. Start fresh is the recommended path.

## License

MIT.
