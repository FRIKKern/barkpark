---
'create-barkpark-app': patch
---

Starters read a reference stored either as `{ _ref }` or as a bare id. `{ _ref }` is the canonical shape (owner ruling #42) and the Barkpark Studio now writes it, but documents last saved in the Studio before that store a bare id until their next save. The blog starter read only `author._ref` / `tags[]._ref`, so such a post showed no author and was missing from its author's and tags' pages. A new shared `refOf()` (`lib/ref.ts`) reads both shapes, every reference read goes through it, and the GROQ helpers in `lib/queries.ts` match both.
