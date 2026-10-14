---
'@barkpark/react': minor
---

New opt-in subpath `@barkpark/react/field-blocks` for the schema field blocks: `field-string`, `field-slug`, `field-text`, `field-boolean`, `field-select`, `field-datetime`, `field-color`, `field-reference`, `field-image`, `composite`, `arrayOf`, `codelist` and `localizedText`.

Pass its `fieldBlocks` to `<PortableDoc blocks={fieldBlocks}>` or `renderPortableDocument(value, { blocks: fieldBlocks })`. Those blocks then render the same read-only definition row as the Phoenix reader: a `bp-field` label beside its value, checked against the Elixir goldens. Without the option they keep rendering the "Unsupported block" placeholder, and the core bundles do not carry them.

The new `blocks` option registers extra block types for a render. It never replaces a core type, and nested blocks inside containers see it too.
