# exomemory2

[日本語](./README.md)

A Claude Code plugin that implements [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) as an external memory for Claude.

Drop source documents into `raw/`, run `/wiki-ingest`, and Claude compiles them into a persistent, interlinked markdown wiki. Query the accumulated knowledge with `/wiki-query`. Conversations captured automatically on `/compact` and session exit.

## Status

Early MVP (v0.1). Core ingest, query, and auto-capture work. Obsidian integration, graph visualization, lint, and multi-vault routing are planned for later.

Supersedes [hananana/exomemory](https://github.com/hananana/exomemory) (v1), which used cognitive-science-inspired memory tiers. v2 is a ground-up redesign around Karpathy's wiki pattern.

## Install

From within Claude Code:

```
/plugin marketplace add hananana/exomemory2
/plugin install exomemory2@exomemory2
```

The hook script requires `jq` (usually pre-installed, otherwise `brew install jq`).

## Quick start

### 1. Create a vault

```
/wiki-init ~/vault-personal
```

This creates a vault skeleton at `~/vault-personal/` containing `WIKI.md`, `raw/`, and `wiki/`.

### 2. Set the active vault

Either export an environment variable (persistent):

```bash
export CLAUDE_MEMORY_VAULT=~/vault-personal
```

Or pass `--vault <path>` to each command, or `cd` into the vault (ancestor search).

### 3. Ingest sources

Drop markdown into `raw/`, then:

```
/wiki-ingest raw/papers/attention.md
```

Or ingest a directory:

```
/wiki-ingest raw/papers/
```

### 4. Query

```
/wiki-query "What does the wiki say about attention mechanisms?"
```

### 5. Auto-capture

Once `CLAUDE_MEMORY_VAULT` is set, the plugin's hooks write a markdown handover file to `raw/handovers/<session-id>.md` on every `/compact` and session exit. Ingest those later with `/wiki-ingest raw/handovers/` to fold conversations into the wiki.

## Commands

| Command | Purpose |
|---|---|
| `/wiki-init <vault-path>` | Scaffold a new vault |
| `/wiki-ingest <file-or-dir> [--vault <path>]` | Compile raw sources into wiki pages |
| `/wiki-query <question> [--vault <path>] [--save]` | Synthesize an answer from the wiki |

## Vault layout

```
<vault>/
├── WIKI.md                 # Schema and workflow (authoritative for Claude)
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

Every page is plain Markdown with YAML frontmatter and `[[wikilink]]` cross-references. Works with Obsidian, VS Code, or any Markdown viewer.

## Design notes

- **Claude Code only** — commands and hooks are Claude-Code-native. No Python tooling to maintain.
- **File over app** — the wiki is just Markdown files; no lock-in.
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
