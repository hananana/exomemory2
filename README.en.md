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

Manual `/wiki-ingest` / `/wiki-query` commands are also provided, but they're secondary — for when you want to explicitly ingest external sources (papers, web clippings) dropped into `raw/`, or query the accumulated wiki directly.

## Requirements

| Item | Purpose |
|---|---|
| `jq` | Capture hook uses it to extract transcript JSON (required) |
| `python3` | Used by `/wiki-init` for path expansion (ships on macOS / most Linux distros by default) |
| [Obsidian](https://obsidian.md) | **Strongly recommended.** Technically optional — the vault is plain Markdown and works in any editor — but the UX Karpathy's original gist assumes (Graph View / Backlinks / Web Clipper / Dataview) only comes together in Obsidian. Skipping it means losing half of the LLM-wiki pattern |

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

- **Dataview** — SQL-like queries over YAML frontmatter (e.g. list all `type: entity` pages)
- **Obsidian Web Clipper** — browser extension; configure it to save web articles under `<vault>/raw/web/`, then run `/wiki-ingest raw/web/` to fold them into the wiki

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

See [Commands](#commands) for manual ingest / query (for papers, web clippings, or direct wiki queries).

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

Only `raw/handovers/*.md` is ingested automatically. Other `raw/` subdirectories (`raw/papers/`, `raw/web/`, ...) require manual `/wiki-ingest raw/papers/` to avoid surprise LLM runs.

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

## Commands

| Command | Purpose |
|---|---|
| `/wiki-init [<vault-path>]` | Scaffold a new vault (defaults to `~/vault`) |
| `/wiki-ingest [<file-or-dir>] [--vault <path>]` | Compile raw sources into wiki pages (no argument = scan whole `raw/`) |
| `/wiki-query <question> [--vault <path>] [--save]` | Synthesize an answer from the wiki |

## Vault layout

```
<vault>/
├── WIKI.md                 # Schema and workflow (authoritative for Claude)
├── .obsidian/              # Obsidian preset (graph color groups, core plugins enabled)
├── raw/                    # Immutable source documents (user drops files here)
│   └── handovers/          # Auto-captured conversations
└── wiki/                   # LLM-maintained knowledge layer
    ├── index.md
    ├── log.md
    ├── overview.md
    ├── sources/            # One page per raw source
    ├── entities/           # People, organizations, projects, products
    └── concepts/           # Ideas, frameworks, methods, theories
```

Every page is plain Markdown with YAML frontmatter and `[[wikilink]]` cross-references. Works with Obsidian, VS Code, or any Markdown viewer. If you don't use Obsidian, `.obsidian/` is harmless — ignore or delete it.

## Design notes

- **Claude Code only** — commands and hooks are Claude-Code-native. No Python tooling to maintain.
- **File over app** — the wiki is just Markdown files; no lock-in. Obsidian is the recommended frontend, but the data is plain Markdown, so VS Code or any other viewer works too.
- **Compounds over time** — entity and concept pages are MERGEd across sources, never overwritten.
- **Local by default** — no cloud, no account. Your vault is yours.

## Roadmap

- v0.2: Auto-ingest on `SessionStart` (opt-in via env flag)
- v0.3: Privacy filter at capture time (block sensitive topics)
- v0.4: Graph-aware lint (orphans, broken links, contradictions)
- Later: Obsidian Bases/Canvas templates, HTML publishing via Quartz

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
