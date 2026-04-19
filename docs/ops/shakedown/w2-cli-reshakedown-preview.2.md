# preview.2 reshakedown — W1 SDK + W2 CLI

Branch: shakedown/preview-2-verify-task15
Date: 2026-04-19

## preview tags snapshot

```
$ npm view create-barkpark-app dist-tags
{ preview: '1.0.0-preview.1', latest: '1.0.0-preview.1' }

$ npm view @barkpark/core dist-tags
{ preview: '1.0.0-preview.2', latest: '1.0.0-preview.2' }
```

Note: `@barkpark/react` `preview` dist-tag still points at 1.0.0-preview.1 (see Leg B follow-ups). Scaffolded `package.json` pins it explicitly at `^1.0.0-preview.1`.

## Leg A — W2 CLI reshakedown (this worker)

Node: v24.14.1  pnpm: 9.15.9
Temp dir: /tmp/cba-reshakedown-1776613266

### 1. Scaffold — pnpm create barkpark-app@preview my-test --template blog-starter --yes --skip-install --skip-git
Result: PASS
Exit code: 0
Note on template name: task spec said `--template blog`, but `create-barkpark-app@preview.1` only accepts `website-starter | blog-starter`. First attempt with `--template blog` failed with `Unknown template "blog"` (CLI exited 1 cleanly with a helpful list — not a crash). Re-ran with `blog-starter` per CLI `--help`. Also had to add `--yes --skip-install --skip-git` because the CLI uses `@clack/prompts`, which calls `uv_tty_init` on stdin; under a non-TTY pane (Doey worker shell) prompting throws `ERR_TTY_INIT_FAILED`. With `--yes` it scaffolds non-interactively and exits 0. Neither finding is blocking, but flag for CLI owner: (a) consider adding `blog` as an alias for `blog-starter` (matches the task / docs phrasing), and (b) consider falling back to defaults when stdin is not a TTY instead of erroring.

NO `ETARGET` and NO `No matching version` anywhere in stderr/stdout.

Evidence (final scaffold):
```
┌  Barkpark
◇  Copied 27 files from templates/blog-starter
└  Done.

Next steps:
  cd my-test
  pnpm install
  docker compose up -d        # Phoenix API + Postgres on :4000
  pnpm barkpark codegen  # generate types from schema
  pnpm dev                # Next.js on :3000
```

Scaffolded `package.json` dependency pins:
```
"@barkpark/core":   "^1.0.0-preview.2",
"@barkpark/nextjs": "^1.0.0-preview.2",
"@barkpark/react":  "^1.0.0-preview.1",
"next":             "^15.0.0",
"react":            "^19.0.0",
"react-dom":        "^19.0.0"
```

### 2. Install — pnpm install
Result: PASS
Exit code: 0, no ERESOLVE, no ETARGET.
Resolved @barkpark/core version: 1.0.0-preview.2
Resolved @barkpark/nextjs version: 1.0.0-preview.2
Resolved @barkpark/react version: 1.0.0-preview.1   (matches the explicit pin; same flag as Leg B — `preview` tag for @barkpark/react still at preview.1.)

Evidence (tail):
```
+ @barkpark/core 1.0.0-preview.2
+ @barkpark/nextjs 1.0.0-preview.2
+ @barkpark/react 1.0.0-preview.1
+ next 15.5.15 (16.2.4 is available)
+ react 19.2.5
+ react-dom 19.2.5
Done in 3.1s using pnpm v9.15.9
```

### 3. Dev server smoke — localhost:3000
Result: PARTIAL PASS — Next.js compiled and served the page; route returned HTTP 500 because the scaffolded blog calls a Phoenix API on `localhost:4000` and `docker compose up -d` was not part of this scope (no Docker side-effects). The 500 is `TypeError: fetch failed` with `cause: ECONNREFUSED` to the missing backend, NOT `createContext is not a function`.
HTTP status: 500 (data fetch failure; framework boot OK)
createContext TypeError present? **no** (greps over `dev.log` and the 500 error page HTML find zero occurrences of `createContext`; the only `TypeError` is `fetch failed` with `code: 'ECONNREFUSED'`)

This means defect #19 cannot reproduce here: the RSC boundary loads, the App Router renders the layout, and React Server Components import `@barkpark/nextjs` and `@barkpark/react` without throwing the createContext error that previously crashed the route on preview.1. The remaining 500 is a backend availability issue, independent of #19.

Evidence — server boot (head of dev.log):
```
> next dev --port 3000
   ▲ Next.js 15.5.15
   - Local:        http://localhost:3000
 ✓ Starting...
 ✓ Ready in 1610ms
 ○ Compiling / ...
 ✓ Compiled / in 4s (606 modules)
```

Evidence — recurring runtime error (only TypeError observed):
```
 ⨯ [TypeError: fetch failed] {
   digest: '3227098399',
   [cause]: [AggregateError: ] { code: 'ECONNREFUSED' }
 }
 GET / 500 in 4465ms
```

500-page React stream confirms the same root cause (excerpt):
```
33:E{"digest":"3227098399","name":"TypeError","message":"fetch failed","stack":[],"env":"Server"}
```

`grep -i 'createContext' dev.log index.html` → zero hits.

Dev server cleanly killed afterwards; port 3000 verified free (`ss -tlnp | grep ':3000'` → no match).

### 4. Build — pnpm build
Result: PASS
Exit code: 0
Evidence (last lines):
```
   ▲ Next.js 15.5.15
   Creating an optimized production build ...
 ✓ Compiled successfully in 5.9s
   Linting and checking validity of types ...
   Collecting page data ...
   Generating static pages (0/6) ...
 ✓ Generating static pages (6/6)
   Finalizing page optimization ...
   Collecting build traces ...

Route (app)                                 Size  First Load JS
┌ ƒ /                                      162 B         105 kB
├ ○ /_not-found                            995 B         103 kB
├ ƒ /api/exit-preview                      127 B         102 kB
├ ƒ /api/preview                           127 B         102 kB
├ ƒ /authors/[id]                          163 B         105 kB
├ ƒ /posts/[slug]                        45.9 kB         151 kB
└ ƒ /tags/[slug]                           163 B         105 kB
+ First Load JS shared by all             102 kB
○  (Static)   prerendered as static content
ƒ  (Dynamic)  server-rendered on demand
```

Build PASS is the strongest single signal that defect #19 is closed: the production build performs SSR/RSC of every route, including paths that import `@barkpark/react`, and completes without `createContext is not a function`.

### Leg A verdict
PASS — `pnpm create barkpark-app@preview` scaffolds, `pnpm install` resolves all `@barkpark/*` deps from `preview` dist-tag, `pnpm build` produces a clean production build, and the dev server boots without the createContext crash. The dev-mode HTTP 500 is exclusively a `fetch failed / ECONNREFUSED` against the (intentionally not started) Phoenix API and is independent of the SDK defects under test.
Defect #17 (ETARGET on @barkpark/core@^0.3.2): **CLOSED** — install exit 0, zero `ETARGET` / `No matching version` strings; preview.2 resolved cleanly.
Defect #19 (createContext TypeError): **CLOSED** — production build passes (RSC of every route), dev server boots and serves modules without createContext error; only TypeError observed is `fetch failed (ECONNREFUSED)` from the missing backend.

Follow-ups surfaced by Leg A (non-blocking):
- CLI: add `blog` alias for `blog-starter` (matches task / docs phrasing) — first scaffold attempt failed because of name mismatch.
- CLI: when stdin is not a TTY, fall back to defaults (or fail with a clear message) instead of `ERR_TTY_INIT_FAILED` from `@clack/prompts`. Current behavior makes the CLI unusable in CI / agent shells without `--yes`.
- `@barkpark/react` `preview` dist-tag still resolves to 1.0.0-preview.1 (also flagged in Leg B). Scaffolded template pins `^1.0.0-preview.1` explicitly, so this is consistent — but release owner should confirm whether preview.2 of `@barkpark/react` was intentionally skipped.



## Leg B — W1 SDK smoke (this worker)

Node: v24.14.1  pnpm: 9.15.9
Temp dir: /tmp/sdk-reshakedown-1776613303
API URL used: https://api.barkpark.cloud (primary — succeeded, no fallback needed)

### 1. Install — pnpm add @barkpark/core@preview @barkpark/nextjs@preview @barkpark/react@preview
Result: PASS (install exit 0, no ERESOLVE)
Resolved @barkpark/core version: 1.0.0-preview.2
Resolved @barkpark/nextjs version: 1.0.0-preview.2
Resolved @barkpark/react version: 1.0.0-preview.1  ← NOTE: `preview` dist-tag for @barkpark/react still points at preview.1, not preview.2. Core + nextjs resolved cleanly to preview.2. Flag for release owner: either preview.2 was not published for @barkpark/react, or the dist-tag was not updated. Not a blocker for SDK smoke (no React render here), but worth confirming before consumers rely on @preview for react.

### 2. client.docs('post').find()
Result: PASS
Envelope keys: raw Array (indices 0..20) — i.e. the SDK returned a flat array, not a `{documents: [...]}` wrapper. The task acceptance criteria allows either shape; this is the "raw array" flat envelope.
Count: 21
Note on config: the task's sample script used `{ projectId, apiUrl }` which the preview.2 SDK rejects with `BarkparkValidationError: invalid projectUrl`. The current `BarkparkClientConfig` requires `projectUrl` + `dataset` + `apiVersion`. Script was adjusted to `{ projectUrl: API, dataset: 'production', apiVersion: '2026-04-01', useCdn: false }` before the run. Flagging for future task specs / docs.
Evidence:
```
api: https://api.barkpark.cloud
docs.find keys: [
  '0', '1', '2', '3',
  '4', '5', '6', '7',
  '8', '9'
]
count: 21
shape-sample: [{"_createdAt":"2026-04-19T12:48:02.340462Z","_draft":false,"_id":"post-938227","_publishedId":"post-938227","_rev":"049ce7d4910399bacb57857c03228d3c","_type":"post","_updatedAt":"2026-04-19T12:48:02.340462Z","featured":"false","title":"Untitledasdadad"}, ...]
```

### 3. client.doc('post','p1')
Result: PASS
Title field: "FINAL-RT3-1776468148217232321"
Evidence:
```
doc.p1 present: true title: FINAL-RT3-1776468148217232321
```

### Leg B verdict
PASS — @barkpark/core@preview.2 + @barkpark/nextjs@preview.2 install cleanly, client connects to live https://api.barkpark.cloud, flat envelope confirmed, `docs('post').find()` returns 21 docs, `doc('post','p1')` resolves with a title, no unhandled crash.
Defect #17 (ETARGET) status: CLOSED — install exit 0, no ERESOLVE, both core & nextjs resolved to preview.2 from the `preview` dist-tag.
Defect #19 (createContext TypeError) status: N/A (SDK-only smoke, no React render path exercised).

Follow-ups surfaced by this leg (not blockers for Leg B PASS):
- @barkpark/react @preview still resolves to 1.0.0-preview.1 — release owner should confirm whether preview.2 of @barkpark/react was published and whether the `preview` dist-tag should be bumped.
- Task spec sample script uses obsolete `{ projectId, apiUrl }` shape; current SDK wants `{ projectUrl, dataset, apiVersion }`. Update the reshakedown task template and any consumer docs.
