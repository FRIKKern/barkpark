---
'@barkpark/react': minor
---

`PortableDoc` and `renderPortableDocument` take an optional `strings` map: the renderer's own words for forms and tasks (a form's Yes/No, task status labels and meanings, task empty states and details) in the caller's language. The map is keyed by the English text the renderer emits — the same keys the Barkpark server renders with when a paper's workspace speaks another language — so a Norwegian page reads the same through either renderer. Without `strings`, output is unchanged. The words ride an explicit per-render context, never module state, so concurrent server renders cannot see each other's language. The `ChromeStrings` type is exported from both entry points.
