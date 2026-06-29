---
'@barkpark/core': minor
---

Multi-field ordering — `.order()` now appends sort keys instead of replacing, so `.order('status:asc').order('title:desc')` sorts by status then title as a tiebreak (matching Sanity/Strapi secondary sorts). A single `.order()` call is unchanged. The server parses comma-separated specs (`order=status:asc,title:desc`) and applies them in sequence.
