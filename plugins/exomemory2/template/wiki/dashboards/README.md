---
title: Dashboards
type: dashboard-index
last_updated: 2026-04-22
---

# Dashboards

Cross-cutting views over the wiki, powered by the [Obsidian Dataview](https://github.com/blacksmithgu/obsidian-dataview) plugin.

## Prerequisites

1. **Install Dataview** — Obsidian → Settings → Community plugins → Browse → search "Dataview" → Install and Enable
2. **Render these pages in Obsidian** — DQL code blocks (```dataview) only execute under Obsidian with the Dataview plugin loaded. In plain Markdown viewers (GitHub, VS Code, etc.) the block is shown as source

## Available dashboards

| Dashboard | What it shows |
|-----------|---------------|
| [[recent]] | Sources updated in the last 30 days |
| [[by-source-type]] | Counts grouped by `source_type` (handover / web-clip / manual) |
| [[by-domain]] | Web clips grouped by `domain`, with page counts |
| [[handovers-timeline]] | Claude handover sessions, newest first, with turn counts |
| [[popular-entities]] | Entities ranked by how many pages link to them |
| [[orphan-concepts]] | Concepts with one or zero inbound links (candidates for pruning or enrichment) |
| [[long-reads]] | Sources with estimated reading time ≥ 10 minutes |

## Customizing

Each dashboard file is just a DQL snippet — edit freely. The v0.4 frontmatter fields available on source pages are:

- Common: `source_type`, `word_count`, `reading_time_min`, `last_updated`, `tags`
- Handover: `session_id`
- Web clip: `source_url`, `domain`, `captured_at`, `captured_by`

Entity and concept pages have no extra frontmatter; use Dataview natives `file.inlinks`, `file.ctime`, `file.mtime` instead.
