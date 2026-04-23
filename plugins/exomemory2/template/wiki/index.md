# Index

This catalog lists every page in the wiki. Entries are appended here on each ingest.

## Activity heatmap

Yearly capture density across the vault. Requires the [Contribution Graph](https://github.com/vran-dev/obsidian-contribution-graph) plugin (no DataviewJS needed).

```contributionGraph
title: 'Activity'
days: 365
query: '"wiki/sources"'
dateField: 'last_updated'
graphType: 'default'
startOfWeek: 1
cellStyleRules:
  - color: '#9be9a8'
    min: 1
    max: 3
  - color: '#40c463'
    min: 3
    max: 7
  - color: '#216e39'
    min: 7
    max: 999
```

## Sources

<!-- source pages will be listed here: `- [[<slug>]] — <title>` -->

## Entities

<!-- entity pages will be listed here -->

## Concepts

<!-- concept pages will be listed here -->
