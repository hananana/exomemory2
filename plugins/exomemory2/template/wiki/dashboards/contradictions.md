---
title: Contradictions
type: dashboard
last_updated: 2026-04-29
---

# Contradictions

Pages whose `## Connections` section contains at least one `- contradicts:: [[X]]` line. Their `confidence` is automatically capped at 0.5 (see formula in WIKI.md "Confidence scoring (v0.9+)").

```dataview
TABLE
  confidence,
  sources,
  last_verified
FROM "wiki/entities" OR "wiki/concepts"
WHERE contains(string(file.lists.text), "contradicts::")
SORT confidence ASC, file.name ASC
```

## All `contradicts::` edges

A flattened list of every `- contradicts:: [[X]]` line, useful for tracing knowledge conflicts across the wiki.

```dataview
TABLE WITHOUT ID
  file.link AS "from",
  L.text AS "contradicts edge"
FROM "wiki/entities" OR "wiki/concepts"
FLATTEN file.lists AS L
WHERE contains(L.text, "contradicts::")
SORT file.name ASC
```

> If a contradiction has been resolved (one side is now the consensus), update both pages: remove the `- contradicts::` line on the winning side and consider whether the losing side should be marked `stale: true` via supersession.
