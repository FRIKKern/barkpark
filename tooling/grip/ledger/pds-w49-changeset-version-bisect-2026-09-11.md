# `pnpm changeset version` could not run: bisected to the GraphQL BATCH, not the backlog (2026-09-11)

Task `pds-bl-w49-changeset-version-cannot-run` (PDS-D701 / D704). Filed with the
cause explicitly UNBISECTED: "342 pending changesets is the obvious suspect ...
but that was NOT isolated". This note isolates it.

Measured in an isolated worktree off `origin/main`
(`fcfae44ee`), `js/`, `pnpm install --frozen-lockfile`, `GITHUB_TOKEN=$(gh auth token)`
proven for GraphQL first: `gh api graphql -f query='{viewer{login}}'` ->
`{"data":{"viewer":{"login":"FRIKKern"}}}`.

## The bisect

N changesets were copied into `js/.changeset/` and `pnpm exec changeset version`
run; the tree was restored with `git checkout -- js/ && git clean -fd js/` after
every run and `git status --porcelain js/` confirmed empty. No version bump, no
CHANGELOG rewrite, and no deleted changeset was ever committed.

| N | rc | elapsed | first error line |
|---|---|---|---|
| 1 | 0 | 1s | — `All files have been updated` |
| 50 | 0 | 8s | — `All files have been updated` |
| 100 | 1 | 13s | `{"message":"We couldn't respond to your request in time. Sorry about that. Please try resubmitting your request and contact us if the problem persists."}` |
| 150 | 1 | 13s | `FetchError: invalid json response body ... Unexpected token '<', "<html>` |
| 200 | 1 | 14s | `FetchError: invalid json response body ... Unexpected token '<', "<html>` |
| 440 | 1 | 17s | `FetchError: invalid json response body ... Unexpected token '<', "<html>` |

N=1 rc 0 settles what the row could not: it is **not** auth, **not** the token
scope, **not** a misconfigured repo. And N=100 is the finding rather than a
hypothesis — GitHub names its own failure, in JSON, in its own words: it ran out
of time serving the query. Past that the timeout degrades into an HTML error
page, which is the `Unexpected token '<'` the row had been staring at.

Note the row quotes `Unexpected end of JSON input` (an EMPTY body) where these
runs produced `Unexpected token '<', "<html>` (an HTML body) and, once,
`Unexpected token 'u', "upstream c"` (an edge "upstream connect error" page).
All three are the same thing seen through `node-fetch`'s `.json()`: a non-JSON
error response. The precise bytes vary with which GitHub tier gives up.

## The mechanism

`@changesets/get-github-info` holds ONE module-level DataLoader
(`node_modules/@changesets/get-github-info/dist/changesets-get-github-info.cjs.js`).
DataLoader collapses every `.load()` issued in a tick into a SINGLE GraphQL
query, and `makeQuery` emits one alias per changeset:

    a<sha>: object(expression: "<sha>") {
      ... on Commit { commitUrl associatedPullRequests(first: 50) { nodes { ... } } }
    }

So the query grows with the backlog and every alias drags up to 50 PR nodes
behind it. The library's own comment calls batching a feature ("instead of doing
a bunch of network requests, we can do a single one") and offers no cap: the
DataLoader is a `const` at module scope with default options.

The wall is a TIME budget, not a node count. That matters: the 50/100 boundary
is not a constant and must not be treated as one.

## The fix

`js/.changeset/changelog-github-batched.cjs`, wired in via
`js/.changeset/config.json` (`"changelog": ["./changelog-github-batched.cjs", { "repo": "FRIKKern/barkpark" }]`
— `apply-release-plan` resolves that with `resolveFrom(<cwd>/.changeset, ...)`,
so a relative path lands inside `.changeset/`).

It delegates every line to the configured `@changesets/changelog-github` and
only bounds how many `getInfo` lookups are in flight (25, overridable via
`CHANGESET_GITHUB_BATCH_SIZE`), which bounds the query.

**The gate placement was itself a wrong turn worth recording.** The first cut
gated the two exported generator functions. A probe on the DataLoader
(`requests.length`, printed per batch) showed batches of 25, 25, 25 — and then
**265**. `getDependencyReleaseLine` takes an ARRAY of changesets and does
`Promise.all(changesets.map(cs => getInfo(...)))` inside, so ONE permitted call
fans out to one lookup per changeset and walks straight through the cap. The
gate had to move onto `getInfo` itself. Re-probed after the move: max batch 25
across 47 batches.

A capped batch is not sufficient on its own. Turning one request into ~47
sequential ones exposes a second, independent defect: **nothing in this stack
retries**. A clean run that had already cleared the batch problem still died at
115s on `Unexpected token 'u', "upstream c"...` — one transient edge 5xx killing
the whole version bump. `getInfo` is therefore also retried with backoff (5
attempts, 500ms doubling) and ONLY for transport-shaped failures; a GraphQL
`errors` payload or a missing token still fails on the first attempt.

## The proof

Full run, all 440 changesets, un-instrumented, from the committed state:

    $ pnpm exec changeset version
    🦋  All files have been updated. Review them and commit at your leisure
    FINAL2 rc=0 elapsed=211s

11 files changed (5 CHANGELOGs, 5 package.jsons, `.changeset/pre.json`) and then
discarded — `git status --porcelain js/` empty afterwards. The version table it
produced, for the record, all five packages in prerelease mode:

| package | from | to |
|---|---|---|
| @barkpark/codegen | 1.0.0-preview.0 | 1.0.0-preview.1 |
| @barkpark/core | 1.0.0-preview.3 | 1.0.0-preview.4 |
| create-barkpark-app | 1.0.0-preview.1 | 1.0.0-preview.2 |
| @barkpark/nextjs | 1.0.0-preview.3 | 1.0.0-preview.4 |
| @barkpark/react | 1.0.0-preview.1 | 1.0.0-preview.2 |

(Order is the `git diff` order over `js/packages/*/package.json`.)

## CHANGELOG shape: unchanged, and that is checkable

The generator is not swapped — it is called. Rows still carry the PR link, the
commit link and the author, exactly as `@changesets/changelog-github` writes
them:

    - [#13686](https://github.com/FRIKKern/barkpark/pull/13686) [`bd1c82d`](https://github.com/FRIKKern/barkpark/commit/bd1c82d...) Thanks [@FRIKKern](https://github.com/FRIKKern)! - **Fix: patch mutations never reached the server (gh-8100).** ...

This is the shape the row said was LOST when the version table was obtained by
swapping to the offline `@changesets/cli/changelog` ("commit shas instead of PR
links"). It is not lost here.

## What guards it

`js/scripts/changelog-batched.selftest.mjs`, offline, run via
`pnpm --filter barkpark-js run selftest:changesets`. It drives a 40-wide fan-out
through a cap of 5 and asserts the observed peak, and pins `isTransient` against
the exact strings GitHub produced. Both mutations were run:

  - gate reverted to a pass-through -> `FAIL gate holds at cap under a 40-wide fan-out (peak 40 <= 5) — peak was 40`
  - `isTransient` inverted -> three reds (HTML 502, upstream-connect, GitHub timeout)

## Named follow-ups

1. **The selftest is not in CI.** Workflows were outside this change's fence.
   `.github/workflows/studio-instrument-selftests.yml` is the natural home but
   its glob is `scripts/studio-desk-*.test.mjs` / `scripts/measurements/*.test.mjs`
   and it carries a committed file-count floor, so wiring means editing the
   paths filter and raising the floor. Until then this guard does not fire by
   itself.
2. **The repo is in prerelease mode.** Every run warns `You are in prerelease
   mode`; `js/.changeset/pre.json` exists and changesets does NOT consume the
   `.md` files under it (440 before and after the successful run). Whoever cuts
   the first real release has to decide `changeset pre exit` deliberately. Out
   of scope here and NOT done.
3. **A 211s version bump is the new normal** and it scales with the backlog:
   ~47 sequential GitHub round trips today. Publishing regularly is the actual
   remedy; raising `CHANGESET_GITHUB_BATCH_SIZE` trades safety margin for speed.
4. **Upstream.** The real fix belongs in `@changesets/get-github-info` — a
   `maxBatchSize` on its DataLoader and a retry. This wrapper is a local
   workaround, and it monkeypatches that module's exports, so a major bump of
   `@changesets/changelog-github` should re-run the selftest and one real
   `changeset version`.
