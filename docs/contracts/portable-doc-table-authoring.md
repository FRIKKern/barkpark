<!-- doc-tier: agent | canonical-for: portable-doc-table-authoring | budget: 700tok -->
# Table source preservation

Public/Studio use positional operations. Canonical tables keep v1; supported opaque inline metadata uses v2. Ordinary cells retain strings. Protected cells use `{kind, inline: {v: 1, anchors, opaque}}`: unique ordered opaque roles ending in `text`, plus the nonempty subset with extras. Free wrappers are not anchors. Metadata stays server-side, never in PM, HTML attributes or receipts.

Protected cells admit one recognized wrapper chain ending in nonempty text. Extras cannot collide with semantic keys; unknown types stay read-only. Rendering and table normalization stay exact. Saving re-projects authoritative source and checks shape: only opaque text values and metadata-free wrappers may change. Protected roles/semantic attributes remain exact. Splits, multiple leaves, empty deletion and protected-role removal refuse accessibly without dirtying. Moves retain carriers; row/column deletion removes them; new cells inherit no metadata.

Mounted/slash tables use the compatibility canvas. Private `bpTableSource`/`bpTableCellSource` are not rendered or accepted from HTML. Edited maps retain siblings; other edited cells use inline arrays. Undo restores carriers; echoes confirm baselines. Numeric/null cells, ragged grids and aliases stay guarded. Compare stored normalized source. Absent/null/empty `head` differ; removal requires `head: []`.

## Geometry and formats

- `spans: [{row,col,colspan,rowspan}]` covers body rows only. Covered positions remain `[]`; canvas/article omit them and put spans on origins. Merge a selection or right/below neighbour; split restores placeholders. One patch carries `rows` and `spans`; clearing uses `spans: []`. BPML emits every cell with origin attributes; Markdown uses its sentinel. Studio refuses spans; email keeps the plain grid.
- `cols[i].width` stores integer CSS pixels beside column type. Canvas/article use colgroups; each right-edge grip patches `cols` once (`[]` clears). BPML emits `<col type="num" width="220"/>`; email keeps the plain grid.
- `headCol: true` makes first-column body origins row headers, including spans; off patches false. Cell `{content, align: "center"|"right"}` styles canvas/article; left removes alignment but retains metadata. BPML uses `headcol`/cell `align`; email is plain. Studio refuses these attributes; untouched source remains exact.

Code/tests: `api/lib/barkpark/portable_doc/table_editing.ex`; `api/assets/paper-editor/src/{convert,index}.js`, `__table_contextual.test.mjs`, `__table.test.mjs`, `canvas/{run-convert,table-node}.js`, `canvas/__control_matrix.test.mjs`. Native checks: typing, formatting/refusal, structure, Undo, echoes and reload in both hosts.
