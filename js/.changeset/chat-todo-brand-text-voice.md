---
"@barkpark/react": patch
---

The in-progress chat todo (its glyph, its text and the "Update todos" dot) is coloured `var(--primary-text, var(--primary))` instead of `var(--primary)`. The brand is now a light gold fill, which cannot be read as text on a light page; `--primary-text` is the brand's readable voice. A page that does not declare `--primary-text` keeps `--primary`, so nothing changes there.
