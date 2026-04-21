---
title: Popular entities
type: dashboard
last_updated: 2026-04-22
---

# Popular entities

Entities ranked by inbound wikilink count. Uses the Dataview native `file.inlinks`, so no retrofit frontmatter is needed.

```dataview
TABLE length(file.inlinks) AS "refs"
FROM "wiki/entities"
SORT length(file.inlinks) DESC
LIMIT 20
```
