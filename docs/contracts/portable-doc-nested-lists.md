<!-- doc-tier: agent | canonical-for: portable-doc-nested-lists | budget: 900tok -->
# Nested-list reader and authoring contract

A list item remains its
existing inline array, scalar or `{content, text, ...metadata}` map. A map may
add `children`, an array of nested list blocks. Its own inline body is read
first, followed by child lists in order. Nonempty `content` wins over `text`.

```json
{"type":"list","items":[{"text":"Parent","children":[
  {"type":"list","ordered":true,"items":["Child"]}
]}]}
```

Child blocks accept `list` and the existing list aliases: `bulletList`,
`bullet_list`, `bulleted-list`, `bulleted_list`, `ordered-list`, `numbered_list`.
Ordered aliases force numbering as they do at the root. Each child must have an
`items` array. Other `children` shapes are opaque, not coerced into prose. This
field does not enable arbitrary blocks or multiple paragraphs inside an item.

Readers preserve parent/child order, nesting and mixed ordered/unordered markers.
Article and email retain semantic nested lists; terminal continuation lines and
children hang under their parent's body. Plain-text extraction includes child
words in reading order. Rendering never mutates source carriers or metadata.

Compatibility census, 8 September 2026: all 1,047 published Papers, including all
seven list aliases, contain 2,932 list blocks and 19,642 items. The 67 item maps
have only `id` and `content`; none uses `children`, `blocks` or `items`. This is
a dated census, not a guarantee about future writes. Existing unknown fields
remain untouched; no stored-document migration is performed.

Shared fixture: `api/test/support/fixtures/nested-list-carriers.json`, covering
three levels, mixed markers, rich primary text, inactive fallback, plain
siblings, item IDs and opaque metadata. HTML/email, React/plain-text, mobile
element-tree and Go/profile tests consume this same input.

Chrome pins mixed markers: `ul` inside `ol` stays bulleted. Surface/editor
selectors use immediate `> li` children; the old ancestor selector fails.

Package byte evidence (fresh baseline `6dcc2b8c3`, same frozen dependencies):
client 24,565 → 24,631 B (+66), RSC 23,547 → 23,622 B (+75), standalone renderer
20,646 → 20,700 B (+54), gzip. Shared validation, existing `renderBlocks` and
one `flatMap` remove duplicate joins. RSC had only 3 B spare before the feature;
the remeasured caps are 24,660 / 23,650 / 20,730 B. All six entries are recorded
together; the three unaffected entries and their caps stay unchanged. No new
dependency or core-package growth.

## Inline authoring boundary

The editor projects one paragraph per item followed by nested lists. Tab and
Shift-Tab indent/outdent; Enter splits; Backspace at the next item's start joins
adjacent inline bodies when the preceding item has no child list. The join uses
one transaction, avoiding a two-paragraph intermediate shape. Other edits
still pass the lossless-shape guard.

Private item and frame attributes preserve original carriers, IDs and metadata
through moves and history; HTML cannot supply them. A copied frame keeps its
original identity only once, with further frames canonicalized. Newly nested
scalar/inline-array parents become maps; untouched carriers remain exact.
Opaque child entries survive in their existing slots. Empty nested lists retain
their empty stored items rather than persisting the editor placeholder.

Hard breaks, multiple paragraphs, arbitrary child blocks and custom numbering
starts are explicitly rejected. Mounted tests alone are not native-browser or
whole-inventory sign-off.
