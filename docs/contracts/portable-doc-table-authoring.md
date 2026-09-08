<!-- doc-tier: agent | canonical-for: portable-doc-table-authoring | budget: 700tok -->
# Table source preservation

New Public/Studio mounts retain the lossless contextual Table editor and its
server-owned positional operations. The continuous canvas remains a compatibility
receiver for already-mounted runs and newly slash-inserted tables; this repair
does not change server partitioning or expand contextual admission.

In that compatibility canvas, cell text lives
in ProseMirror; private `bpTableSource` and `bpTableCellSource` attributes retain
the original block and cell carriers. They are not rendered to HTML or imported
from pasted HTML.

An unchanged cell serializes its original source, including inline metadata.
Editing a content-map cell replaces its `content` while retaining sibling fields.
Other edited cells use canonical inline arrays. Structural controls carry source
with surviving cells; new cells have no inherited source identity. Undo restores
the previous grid and carriers. Source echoes establish a new confirmed baseline.

Table-level metadata and absent/null/empty `head` distinctions remain intact.
Deliberately removing an existing header emits `head: []`; omitting `head` from a
patch is not header removal.

## Boundaries

This is not a new storage dialect. Existing server normalization converts string
cells and simple wrappers into canonical inline arrays. Tests compare native
save/reload against the freshly stored source, not pre-publication input.

Numeric/null cells, malformed or ragged grids, and legacy header/column aliases
remain guarded rather than exposing an editor that cannot safely save them.
Contextual table admission is unchanged. A fail-closed block is preserved, not
silently normalized or discarded. Unknown inline content is not a promise of
lossless editing inside that cell; untouched source preservation is distinct
from support for editing every possible inline dialect.

## Verification

`npm test` in `api/assets/paper-editor` includes `src/__table.test.mjs` and mounted
`src/canvas/__control_matrix.test.mjs`. Server persistence and existing numeric/null
refusals are pinned in `api/test/barkpark/content/paper_table_source_test.exs`.
Native Public and Studio checks additionally verify the unchanged contextual
path's stored blocks after editing, structural operations and reload. Those checks
are not evidence that every legacy carrier is newly editable.

Code: `api/assets/paper-editor/src/canvas/run-convert.js` and `table-node.js`.
