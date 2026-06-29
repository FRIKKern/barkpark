---
'@barkpark/core': minor
---

New `.select(fields)` on the query builder — field projection (`?fields=`). Return only the named content fields for smaller list-view payloads: `.select('title')` or `.select(['title', 'slug'])`. System fields (`_id`, `_type`, `_rev`, …) are always included; applied after `expand`. Matches Sanity projections / Strapi's `fields`.
