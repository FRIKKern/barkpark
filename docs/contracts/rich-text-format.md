<!-- doc-tier: agent | canonical-for: rich-text-format | budget: 1500tok -->
# Rich text format

A `richText` field stores one of two formats. The schema says which with `format` (owner decision D1 on task-ab40acaf75927e0e).

| `format` | Stored value | Edited by |
|---|---|---|
| `portableText` | Sanity's Portable Text: a list of `_type: "block"` nodes with `children` spans and `markDefs`, plus keyed custom blocks | the Classic rich-text editor, which edits HTML and saves blocks |
| `portableDoc` | PortableDoc blocks (`type`, `id`) | the block editor; the schema save adds `editor: "blocks"` |

With no `format`, the old rule holds. `editor: "blocks"` means PortableDoc. A field named `body` or `blocks` is read by its stored value: Portable Text when it holds Portable Text, PortableDoc otherwise. Any other `richText` is Portable Text. A schema save refuses an unknown `format` and `portableText` together with `editor: "blocks"`.

A Portable Text field saves the editor's HTML as a Portable Text array from the first edit, including a new or empty field named `body`. A `body` with no `format` still saves an HTML string until it holds blocks.

## Aliases

The schema save stores both of these as `richText` with `format: "portableText"`, in any position a field can sit:

- `{"type": "portableText"}`.
- Sanity's `{"type": "array", "of": [{"type": "block", …}, …]}`. The block member's `styles`, `lists` and `marks.decorators` become `blocks.styles`, `blocks.lists` and `blocks.marks`; `marks.annotations` becomes `blocks.annotations` and the block member's `of` becomes `blocks.inline`, each entry `{name, title, fields}`; the array's other members become `blocks.of`. A value may be a string or `{title, value}`. A key Sanity leaves out stays out.

## Vocabulary

`blocks` names what a field admits. `strike-through` (Portable Text) and `strikethrough` (PortableDoc) are the same decorator. An `annotations` entry may carry `fields`.

A `blocks.of` or `blocks.inline` entry that names an object type and declares no `fields` (`{"name": "mediaModule"}`) is read with that type's fields (`Schema.get_schema/3`), one level deep: a richText inside those fields keeps its entries as names.

The block editor's default, when a field declares no `blocks`: `styles` normal, h1 to h6, blockquote; `lists` bullet, number; `marks` strong, em, strikethrough, underline, code; `annotations` link; `of` image, divider, code, diagram. Its block writes outside the vocabulary are refused.

## Portable Text checks

`Content.PortableTextValidation` checks a stored Portable Text array on every validation pass:

- blocks, spans, mark definitions and inline objects have a non-empty `_key`, unique among siblings;
- a span's `text` is a string, and each mark is a declared decorator or the `_key` of a mark definition in the same block;
- `style` and `listItem` are in the vocabulary; `level` is a positive integer;
- a custom block's `_type` is in `of`, an inline object's in `inline`, a mark definition's in `annotations`, and each is checked against the fields its entry declares. A field is required only by its own `validation`, so a link without `linkType` passes.

A field with no `blocks` gets only the structural checks. With `blocks` and `format: "portableText"`, a kind the field leaves out takes Sanity's default: `styles` normal, h1 to h6, blockquote; `lists` bullet, number; `marks` strong, em, code, underline, strike-through; `annotations` link; no `of` or `inline`. With `blocks` and no `format`, a kind left out is not checked.

The structural findings (codes `pt_*`) are warnings. On a dataset listed in `BARKPARK_SCHEMA_ENFORCE_DATASETS` they are errors, and the mutate door refuses the write. A custom block's own field rules keep their own level.

Keyed patch paths address any node: `body[_key=="b"].children[_key=="s"].text`, `body[_key=="b"].markDefs[_key=="m"]`, `insert` `after` `body[_key=="b"]`.

## Classic editor

A Portable Text field with `blocks` gets `data-vocabulary` on its editor (`PortableText.editor_vocabulary/2`). The toolbar then offers only the declared styles, lists and decorators; a field with only `normal` shows no style button. Each declared annotation has a button, and the declared inline objects an "Insert inline" menu. Both open the object dialog, built from the entry's `fields` (a `link` with none gets `href`), else from the named object type. Nothing in it is required. The editor makes the new `_key`; the HTML names a mark definition and an inline object by key, and `from_html/3` keeps the stored one. A field without `blocks`, or whose `blocks` leave annotations open, keeps the link row and its `link`/`linkAnnotation` guess. A richText inside a composite has no dialog host, so it gets the toolbar part only.

## Code anchors

- `api/lib/barkpark/content/rich_text_format.ex` — `format/1`, `normalise_fields/1`, `format_problems/2`
- `api/lib/barkpark/content/portable_text_validation.ex` — `vocabulary/1`, `findings/5`
- `api/lib/barkpark/content/validation.ex` — the richText clause of the field walk
- `api/lib/barkpark/content/schema.ex` — `inline_vocabulary/3`
- `api/lib/barkpark/content/forms.ex` — `plain_rich_text?/1`
- `api/lib/barkpark/content/portable_text.ex` — `editor_vocabulary/2`, `from_html/3`
- `api/lib/barkpark_web/live/studio/studio_live/handlers/object_blocks.ex` — `insert_def/2`, `insert_inline/2`
