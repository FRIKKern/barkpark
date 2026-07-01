---
'@barkpark/core': patch
---

`imageUrl` now wraps the rendition `preset` in `encodeURIComponent`, matching the already-encoded id segment. `RenditionPreset` is an open union (arbitrary strings type-check, and `<BarkparkImage>` forwards a caller-supplied preset through), so a preset with a space or a URL-reserved character (`#`, `?`, …) no longer produces a broken or ambiguous `<img src>`. No-op for the known presets (`hero`, `thumb`, …), which encode to themselves.
