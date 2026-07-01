---
'@barkpark/core': patch
'@barkpark/react': patch
---

`RenditionPreset` is now an open union (`… | (string & {})`) so a newly-added server preset isn't a false compile error; autocomplete for the known presets (`thumb`/`preview`/`hero`/`og`) is preserved.
