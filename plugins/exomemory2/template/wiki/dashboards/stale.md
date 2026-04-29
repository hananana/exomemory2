---
title: Stale (superseded)
type: dashboard
last_updated: 2026-04-29
---

# Stale (superseded)

Entity / concept pages that have been explicitly superseded by a newer page (linguistic supersession trigger detected during ingest). These pages are excluded from default `/wiki-query` results, but remain queryable via:

- A `/wiki-query` containing one of the history keywords (`history`, `経緯`, `以前`, `昔`, `deprecated`, `古い`, `previous`, `old`, `廃止`, or matches `なぜ.*やめ`)
- A direct `[[<slug>]]` reference in the question text
- One-hop `supersedes` traversal from the new page (so "what did Y replace?" reaches the stale predecessor automatically)

```dataview
TABLE
  superseded_by,
  superseded_at,
  confidence,
  sources
FROM "wiki/entities" OR "wiki/concepts"
WHERE stale = true
SORT superseded_at DESC
```

> Stale pages are never deleted — they are an honest record of what the wiki used to say. Re-promoting a stale page is a manual operation: remove the `stale: true` line and adjust `superseded_by` / `superseded_at` accordingly, then run `/wiki-migrate` to re-derive the metadata.
