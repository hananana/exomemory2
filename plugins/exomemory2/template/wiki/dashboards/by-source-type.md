---
title: Sources by type
type: dashboard
last_updated: 2026-04-22
---

# Sources by type

Count of source pages grouped by `source_type`.

```dataview
TABLE length(rows) AS "count"
FROM "wiki/sources"
GROUP BY source_type
SORT length(rows) DESC
```
