---
title: Handovers timeline
type: dashboard
last_updated: 2026-04-22
---

# Handovers timeline

Claude session handovers, newest first, with length proxies.

```dataview
TABLE session_id, word_count AS "words", reading_time_min AS "min", last_updated
FROM "wiki/sources"
WHERE source_type = "handover"
SORT last_updated DESC
```
