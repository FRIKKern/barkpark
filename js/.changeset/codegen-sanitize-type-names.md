---
'@barkpark/codegen': patch
---

Generated interface names are now sanitized for schema names that aren't valid JS identifiers (e.g. `blog-post` → `interface Blog_post`), and the `BarkparkTypeMap` key keeps the real (quoted) schema name. Previously such a schema produced `interface Blog-post` — invalid TS that crashed the generate pass. Completes the non-identifier handling started for field names; identifier names are unchanged.
