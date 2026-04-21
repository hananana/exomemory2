---
title: Orphan concepts
type: dashboard
last_updated: 2026-04-22
---

# Orphan concepts

Concept pages with one or zero inbound links — candidates for pruning, merging, or enrichment.

```dataview
TABLE length(file.inlinks) AS "refs"
FROM "wiki/concepts"
WHERE length(file.inlinks) <= 1
SORT length(file.inlinks) ASC, file.name ASC
```
