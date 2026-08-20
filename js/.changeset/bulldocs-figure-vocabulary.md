---
'@barkpark/react': minor
---

The jarl figure family joins the PortableDoc vocabulary (jdf-bl-historiene-renderer-reconciliation) — two new block types plus first-class provenance on `stat`, shape-parity-proven against the Elixir engine:

- **`duel`** — a two-arm comparison table: `{legendA, legendB, sourceDefault?, rows: [{label, delta?, valueA, valueB, unit?, source?}]}`. Legend A carries the accent; the `delta` annotation ("−30 %") renders under the row label; values are display strings, never reformatted. Both legends are required — otherwise the honest empty box.
- **`lineage`** — dated nodes on a line: `{sourceDefault?, nodes: [{overline?, title?, body?, value?, unit?, source?}]}`. `overline` is the date/period; `value` + `unit` an optional datum; nodes render in authored order.
- **`stat` grows `unit`, `body`, and `source`** — the unit is its own span beside the display number, `body` a one-line caption, and `source` the datum's provenance. `stats`/`stat-grid` grow `sourceDefault` and per-item `source`, aggregated into one deduped footer. Absent fields keep output byte-identical.
- **THE KILDE LAW**: every figure datum carries a source ref — `commit:<sha>` | `paper:<slug>` | `task:<id>` | `https://…` — surfaced as a small «kilde» stamp under the figure. Invalid refs never render; only https refs link out.
