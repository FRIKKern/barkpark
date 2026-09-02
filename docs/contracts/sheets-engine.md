<!-- doc-tier: agent | canonical-for: sheets-engine | budget: 900tok -->
# Sheets — engine, plugin wiring, embed pipeline

Split out of `api/CLAUDE.md` to restore byte headroom there; this file is the owner of
the Sheets subsystem. `api/CLAUDE.md` §Sheets keeps a one-line pointer, and
`docs/cards/plugins.md` cites that section as the worked lifecycle-hooks example.

`type:"sheet"` docs (multi-tab, sparse A1 `cells` maps) plus a `"sheet"` embed block
carrying a dense snapshot — Bulldocs split again: core machinery, thin plugin wiring,
fresh-install invariant intact.

## Core

| Module | Role |
|---|---|
| `Barkpark.Plugins.Sheets.Core` | A1 addressing + snapshot synthesis, 200k cap |
| `Barkpark.Plugins.Sheets.Engine` | formula subset; eager-IF deps → `#CYCLE!` |
| `Barkpark.Plugins.Sheets.Session` | lazy per-sheet GenServer |
| `Barkpark.Plugins.Sheets.Structure` | ref-shift on structural ops |
| `BarkparkWeb.SheetsReaderLive` | public reader |
| `BarkparkWeb.Studio.SheetGrid` | Studio grid component |

`Session` serializes cell / structural / undo ops, ≤1000 per call, and persists on a
debounce of 2s or 25 ops, plus on terminate.

## Plugin (`plugins/sheets.ex`)

- Declares the `sheet` schema.
- **before_save gate:** A1 keys, XFD grid bounds, merge ≤10k → 409 `halted`.
- **`:ingest` API:** import (xlsx/csv/tsv, with size and cell caps) · export
  `.{xlsx,csv,tsv,md,html}` (flush-first) · `/ops` (batch caps).
- **`:public_root` reader:** `/sheets/:slug`, published-only.
- Error envelopes (413/422/503) live in `plugins/sheets.ex`.

## Embed pipeline

Sheet saves run an Engine recompute, then the write-through refreshes every embedding
paper's snapshot. Hydration mirrors it when a paper save adds a
`{"type":"sheet","ref":…}` block. Both taps are in `content/sheets.ex` —
`tap_sheet_writethrough` and `hydrate_sheet_embed_snapshots`.

Session deltas: `{:sheets_op, %{rev, tab, changed}}` on `doc_topic <> ":sheets:op"`.
SSE document events fire only on the debounced persist, never per op.
