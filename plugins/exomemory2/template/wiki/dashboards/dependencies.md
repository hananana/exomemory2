---
title: Dependencies
type: dashboard
last_updated: 2026-04-29
---

# Dependencies

Pages with explicit `- depends_on:: [[X]]` typed connections. Useful for tracing dependency graphs across libraries, prerequisite knowledge, or upstream code.

## Pages that declare dependencies

```dataview
TABLE WITHOUT ID
  file.link AS "page",
  length(filter(file.lists.text, (t) => contains(t, "depends_on::"))) AS "deps"
FROM "wiki/entities" OR "wiki/concepts"
WHERE contains(string(file.lists.text), "depends_on::")
SORT length(filter(file.lists.text, (t) => contains(t, "depends_on::"))) DESC
```

## All `depends_on::` edges

```dataview
TABLE WITHOUT ID
  file.link AS "from",
  L.text AS "depends_on edge"
FROM "wiki/entities" OR "wiki/concepts"
FLATTEN file.lists AS L
WHERE contains(L.text, "depends_on::")
SORT file.name ASC
```

> A `depends_on::` edge says: "the source page would not work / make sense without the linked page". Use it for libraries, frameworks, prerequisite concepts, or upstream services. For weaker associations use `- related_to::` (the default).
