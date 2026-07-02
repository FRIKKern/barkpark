---
'@barkpark/react': patch
---

`<BarkparkImage>` now logs a one-time dev warning when a `preset` is requested on an asset with no resolvable id (a bare URL string or an id-less expanded asset). Such an asset can't be turned into a rendition path, so it silently fell back to the full-size original — now that invisible performance fallback is signalled. Behavior is otherwise unchanged.
