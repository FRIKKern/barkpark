<!-- doc-tier: agent | canonical-for: portable-doc-table-authoring | budget: 700tok -->
# Table source preservation

Public/Studio use positional Table operations. Canonical tables keep
their v1 projection. A table containing supported opaque inline metadata
uses v2; ordinary cells retain their carrier strings. Protected cells describe
`{kind, inline: {v: 1, anchors, opaque}}`: ordered unique opaque roles plus terminal
`text`, and the nonempty subset carrying extras. Free wrappers are not anchors,
so formatting cannot invalidate a queued text edit. Metadata values stay on
the server, never in ProseMirror, HTML source attributes, or operation receipts.

## Contextual metadata lens

Each protected cell admits one recognized wrapper chain ending in one nonempty
text leaf. Extras may use arbitrary keys outside the renderer's semantic namespace;
semantic collisions and unknown types remain read-only. Sanitized projection must
render identically, and whole-table normalization must remain exact.

Saving re-projects authoritative source and exact-matches shape before merging.
Only the text value changes on an opaque text role. Opaque wrapper roles and their
semantic attributes must remain unchanged; metadata-free wrappers may change.
Splits, multiple leaves, empty deletion, or removal of a protected role are refused
with accessible feedback, without changing the draft or marking it dirty.
Moves retain source carriers; explicit row/column deletion removes those carriers.
New cells inherit no metadata. Ordinary cells retain their existing editing grammar.

## Compatibility canvas and boundaries

Already-mounted runs and slash-inserted tables retain the compatibility canvas.
Private `bpTableSource`/`bpTableCellSource` attributes preserve untouched source;
they are neither rendered nor imported from pasted HTML. Edited content maps keep
sibling fields; other edited cells use canonical inline arrays. Undo restores
carriers and source echoes establish a confirmed baseline.

Numeric/null cells, ragged grids and legacy aliases remain guarded. Existing server
normalization canonicalizes strings/simple wrappers; native comparisons use stored
source, not pre-publication input. Table metadata and absent/null/empty `head` stay
distinct. Explicit header removal emits `head: []`; omission is not removal.

## Verification

Server: `api/lib/barkpark/portable_doc/table_editing.ex` and its matching test.
Client: `api/assets/paper-editor/src/convert.js`, `index.js`,
`__table_contextual.test.mjs`; compatibility tests: `__table.test.mjs` and
`canvas/__control_matrix.test.mjs`. Native checks compare exact stored source after
typing, formatting/refusal, structure, undo, echoes and reload in both hosts.

Compatibility code: `canvas/run-convert.js` and `canvas/table-node.js`.
