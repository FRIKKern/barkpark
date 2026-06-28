---
'create-barkpark-app': patch
---

Fix the blog-starter `post.tags` schema: it declared `type: 'array'` with a single-object `of` (`{ type: 'reference', refType: 'tag' }`), but the server's `array` parser expects `of` as a *list* and silently defaulted to array-of-string — dropping `refType`, so tags were not recognized as references (broken in Studio, validation, and `?expand`). Changed to the canonical `type: 'arrayOf'`, which takes a single-object `of` — exactly the shape already present. Storage and page code are unchanged (tags remain `{ _ref }` objects).
