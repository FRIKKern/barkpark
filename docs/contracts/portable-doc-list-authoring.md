<!-- doc-tier: agent | canonical-for: portable-doc-list-authoring | budget: 1000tok -->
# PortableDoc list authoring

Existing `list` blocks keep their `ordered` flag and `items` array. This editor
repair introduces no new stored nesting format and does not migrate Papers.

## Item carriers

The editor follows the existing Elixir, React and Go readers:

| Stored item | Visible inline content | Save behavior |
| --- | --- | --- |
| Inline array | Array as authored | Untouched source retained |
| Plain string | Literal text | Plain edits retain the string; rich edits become inline arrays |
| JSON string encoding an inline-object array | Decoded inline content | Edits retain the encoded-array carrier |
| Map with nonempty `content` array | `content` | Edits replace `content`, retaining other item fields |
| Map with absent/empty `content` and string `text` | `text` | Plain edits replace `text`; rich edits use `content` |
| Other scalar | Its text representation, or empty for null | Untouched scalar retained; edits use inline arrays |

When clearing a content-backed item, a string `text` fallback is also cleared;
otherwise the readers would display the stale fallback instead of an empty item.
Unknown item-level fields and IDs stay on their owning item. Newly split items
do not inherit the source ID or metadata. Undo restores the original carrier.

`bpListSource` is editor-only state: it is neither rendered to HTML nor parsed
from pasted HTML. Item source travels with native list-item moves/history, not
with an index lookup. No-op comparison tolerates ProseMirror merging adjacent
text nodes while retaining the exact original wire value.

JSON decoding is list-specific. JSON-looking strings in paragraph content remain
literal prose.

## Current boundary

Nested lists, multiple paragraphs per item and hard breaks remain rejected
before a transaction enters history or emits a save. Enabling them requires an
explicit cross-reader representation and separate round-trip/browser proof.
The carrier repair is a prerequisite, not completion of nested authoring.

## Verification

`npm test` in `api/assets/paper-editor` includes the pure carrier tests and mounted
canvas/single-block split/undo tests. Chrome verification additionally checks
the saved wire data after immediate View and reload.

Code: `api/assets/paper-editor/src/convert.js`, `list-item-source.js`,
`portable-text-boundary.js`, and `canvas/__list_lossless.test.mjs`.
