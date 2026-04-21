---
title: Web clips by domain
type: dashboard
last_updated: 2026-04-22
---

# Web clips by domain

Web-clip sources grouped by `domain`, with count and page links.

```dataview
TABLE length(rows) AS "count", rows.file.link AS "pages"
FROM "wiki/sources"
WHERE source_type = "web-clip"
GROUP BY domain
SORT length(rows) DESC
```
