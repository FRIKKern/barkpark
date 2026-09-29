---
'@barkpark/react': patch
---

PortableDoc: the `table` block now renders the typed `cols` spec. A table may carry an optional `cols` attr — an index-aligned array of `{type}` maps tagging each column `text` | `num` | `delta` | `spark` — and the React reader had been ignoring it, emitting a bare `<td class="bp-table__td">` for every cell while the other two engines (the Go TUI renderer and the Phoenix `:article` renderer) already rendered the contract.

`num` and `delta` columns right-align (`bp-table__td--num`, and `bp-table__th--num` on the header so the label sits over its column); a `delta` cell's sign becomes a leading direction glyph followed by the unsigned magnitude, so the direction survives with zero colour; a `spark` cell's numeric series becomes one inline sparkline SVG (`bp-table__spark`) instead of a row of literal numbers. `text`, an unknown type, a column index past the end of `cols`, and a cell that does not carry the value its type needs all fall back to the legacy body.

`cols` ABSENT means every column is text, which is the previous code path exactly — the emitted bytes for an untyped table are unchanged.

The column type set, the right-aligned subset and the delta glyphs are read from the one cross-engine contract file the Elixir suite reads, not re-typed in the JS tests.
