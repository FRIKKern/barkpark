fix(web): pin the listen SSE proxy's perspective so an anonymous caller cannot stream drafts (#14362)

`web/app/v1/data/listen/[dataset]/route.ts` is a same-origin SSE proxy: the
browser connects with NO token and the handler attaches the server-only
`READ_TOKEN` before forwarding upstream. It then forwarded the browser's whole
query string verbatim (`upstream.search = incoming.search`), so `perspective`
was a browser-controlled parameter on a privileged request.

The API clamps a caller to the published perspective only because that caller is
ANONYMOUS; a token-bearing request is not clamped. So
`GET /v1/data/listen/<dataset>?perspective=drafts` returned a drafts stream
under the server's credentials — content that caller could never read directly.

Every other read surface in `web/` already pins the published perspective:
`lib/barkpark-client.ts`, `lib/find-search.ts`, and the app's own live client in
`components/live-bridge.tsx`; `lib/papers.ts` states the intent outright ("draft
values never leak into the reader"). This proxy was the one surface that did not
enforce it — the same class of hole as the `[dataset]` path segment on the same
route, which is already clamped with a 404 before the token is attached.

Fix: `searchParams.set("perspective", "published")` after the verbatim forward.
One rule covers both cases — a supplied value is overwritten (and `set()`
collapses repeated copies, so a second value cannot be smuggled past), and an
omitted one is filled in rather than left to the upstream default. `types` and
`filter[...]` still ride through untouched.

Tests read the URL the handler actually sent upstream — asserting on the
response alone cannot tell a pinned request from a forwarded one — and each
asserts the Authorization header IS present, so a pass can never come from the
token going missing instead of the clamp working.

Verified in this worktree:
- new file RED on the unfixed route: 5 tests, 5 fail (route reverted to
  origin/main, test file unchanged)
- new file GREEN with the fix: 5 tests, 5 pass
- web suite baseline (my file removed): 461 tests from 56 files, 0 fail
- web suite with the fix: 466 tests from 57 files, 0 fail
- `pnpm typecheck` and `pnpm lint` both clean

Task: task-9009e2e4f0e5b5b6
