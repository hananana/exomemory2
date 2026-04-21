---
title: Recent sources (last 30 days)
type: dashboard
last_updated: 2026-04-22
---

# Recent sources

All source pages updated in the last 30 days, newest first.

```dataview
TABLE source_type, reading_time_min AS "min", last_updated
FROM "wiki/sources"
WHERE date(last_updated) >= date(today) - dur(30 days)
SORT last_updated DESC
```
