---
title: Low confidence
type: dashboard
last_updated: 2026-04-29
---

# Low confidence

Entity / concept pages whose `confidence` score is below 0.5. These are pages that either rest on too few sources (≤2) or have at least one `- contradicts::` link in their Connections (the formula caps confidence at 0.5 when contradictions are present).

Use this view as a worklist: review each page, decide whether to ingest more sources, resolve the contradiction, or accept the lower score.

```dataview
TABLE
  confidence,
  sources,
  last_verified,
  choice(stale = true, "stale", "") AS "flag"
FROM "wiki/entities" OR "wiki/concepts"
WHERE confidence != null AND confidence < 0.5
SORT confidence ASC, last_verified ASC
```

> Confidence is a derived field. It is recomputed on every `/wiki-ingest` MERGE and every `/wiki-migrate`. Don't hand-edit it — fix the underlying signals (more sources, resolved contradictions) and let the next ingest update the score.
