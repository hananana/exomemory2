---
title: Long reads
type: dashboard
last_updated: 2026-04-22
---

# Long reads

Source pages with estimated reading time of 10 minutes or more.

```dataview
TABLE source_type, reading_time_min AS "min", word_count AS "words"
FROM "wiki/sources"
WHERE reading_time_min >= 10
SORT reading_time_min DESC
```
