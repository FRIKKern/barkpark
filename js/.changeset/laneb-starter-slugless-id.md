---
'create-barkpark-app': patch
---

Starters: a post (or tag) with no slug is now reachable. Every list page links a document as `slugOf(doc.slug) ?? doc._id`, but `getDocBySlug` matched only `slug.current` and `slug`, so a slugless post's link from the home page answered 404. `getDocBySlug` now falls back to a by-id read and returns that document only when it has no slug of its own, so a slugged document keeps exactly one URL and an id never shadows another document's slug.
