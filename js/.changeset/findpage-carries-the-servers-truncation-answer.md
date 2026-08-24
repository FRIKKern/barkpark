---
'@barkpark/core': patch
---

`findPage()` now returns the truncation answer the server was already sending. `/v1/data/query` reads one row past the page and reports whether that row materialised, as `hasMore` — exact, on every response, for the price of one row and no `COUNT`. It also sends a `nextOffset` when a next page exists, and withholds it past the offset ceiling where a further read would re-serve the same page rather than advance.

The page executor received both and rebuilt its `QueryPage` from `documents` / `total` / `count` / `limit` / `offset` alone. Grepping the whole JS monorepo for `hasMore` turned up media and nothing else: the document query path had never read either field.

That left callers two ways to ask "is there more", and the cheap one is wrong. `count === limit` cannot tell a type holding exactly `limit` rows from one holding a million, and calls a merely-full page truncated. `offset + count < total` is correct, but only because `findPage` forces `?count=true` and pays for a second `COUNT` query on the server — to answer a question the server had already answered for free.

`QueryPage` gains `hasMore: boolean` (required — a page that cannot say whether more rows exist is not a page; `false` also stands in for a server too old to send it) and `nextOffset?: number` (omitted, never `0`, when there is no next page, so it can never read as a valid offset that re-serves the page you just read). Both are read from the `result`-wrapped and the flat envelope alike.

`hasMore` being required is a type-level break for anyone hand-constructing a `QueryPage`; nothing in this monorepo did except one test fixture. Callers of `findPage()` are unaffected.

No limit bump: the two fields are paid for by three provably-equivalent dedups — the three query executors fold onto one shared request (each keeping its own envelope-fallback chain and query string verbatim, both pinned by tests), `makeFilterExpression` hoists five identical `ARRAY_OPS.includes(op)` lookups of a never-reassigned parameter into one, and a `for…push` loop becomes a spread. Measured against `origin/main`'s own sources: ESM 16 262 → 16 276 B, CJS 16 955 → 16 966 B.
