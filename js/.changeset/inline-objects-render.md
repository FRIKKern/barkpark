---
'@barkpark/react': minor
---

Inline objects render instead of vanishing. An inline object is an inline node with no built-in renderer, stored flat as `{ type, ...fields }`. A schema declares these under a richText field's `blocks.inline`, as Sanity does with a `block`'s `of`.

- `PortableDoc` and `renderPortableDocument` take `inlineObjects`, a map from type to a function that gets the stored node and returns HTML. The function owns escaping (`escapeHtml` is exported). If it throws or returns a non-string, the default span is used.
- Without a registered renderer, the node shows its text in `<span class="bp-inline-object" data-inline-type="…">`. The text is the first non-empty string among `text`, `title`, `label`, `name` and `value`. A node with none renders nothing, as before. The Phoenix renderer and the Go TUI follow the same rule, locked by one shared fixture.
- The `PortableText` shim renders a Sanity inline object (a block child whose `_type` is not `span`) through `components.types[_type]`, or `unknownType`, passing `isInline: true`. Without a component it renders nothing, as before.
