---
---

No release. `@barkpark/nextjs` and `create-barkpark-app` had their `package.json`
version literals aligned to the versions npm already owns
(`@barkpark/nextjs@1.0.0-preview.3`, published 2026-04-27T21:09:39.144Z;
`create-barkpark-app@1.0.0-preview.1`, published 2026-04-19T15:30:26.525Z) so the
next `changeset version` lands on `preview.4` / `preview.2` — versions the
registry does not own — instead of re-proposing an already-published version that
`changeset publish` silently skips at exit 0. Same move as ff067514e made for
`@barkpark/core`. No source, no public API, no behaviour changed.
