# Phase 8 Live Product Shake-Down — 2026-04-19

**Task:** #8
**Slice under test:** 8.2 (preview publish — CI run 24625047707)
**Coordinator:** Subtaskmaster W8
**Workers:** 4 parallel (W8.1 SDK e2e · W8.2 CLI+starters · W8.3 marketing+demo · W8.4 API+Studio)
**Mode:** Read-only audit. No source modifications. 14 defects filed via `doey task create`.

---

## Executive summary

Slice 8.2 ships installable npm artefacts but **none of the documented end-user paths work out-of-box**. A fresh consumer cannot read data with the SDK, cannot scaffold a runnable app with the CLI, and cannot reach the product from the marketing site. The Phoenix backend is the one bright spot — perspectives, publish round-trip, auth, and Studio shell all function correctly under live test.

| Expectation | Verdict | Evidence |
|---|---|---|
| **E1** — `pnpm install @barkpark/nextjs@preview` completes ≤5 min | ✅ **PASS** | W1: `npm install` of all 4 packages = **15.1s**, 0 vulns, 0 warnings. |
| **E2** — `create-barkpark-app@preview` scaffold typechecks with zero TS errors | ❌ **FAIL** | W2: scaffold cannot even install (`ETARGET` on `@barkpark/core@0.1.0`). After manual patch + `--legacy-peer-deps`, runtime crashes with `createContext` TypeError in dev (HTTP 500) and build (exit 1). W1: even pure-SDK consumer hits TS7016 until manually adding `@types/react`. |
| **E3** — perspectives correct + `drafts.{id}` ↔ `{id}` publish round-trip | ✅ **PASS** | W4: 21 endpoint checks. `published=18`, `drafts=65` (53 drafts overlay + 12 published projections), `raw=71`. Full create→publish→unpublish→delete cycle on `shakedown-w4` completed and cleaned. Sub-20ms latencies. |

**Headline:** Slice 8.2 is a clean publish but not a usable product. **External beta (slice 8.3) is blocked** until the four P0 defects below are fixed.

---

## Per-surface findings

### W8.1 — JS/TS SDK e2e — `docs/ops/shakedown/w1-sdk-e2e.md`

1. **`@barkpark/core` query envelope is broken (P0, #16).** `client.docs(type).find()` reads `data.result.documents` but Phoenix returns the documents flat at the top level (`{count, documents, perspective}`). Every list query throws `TypeError: Cannot read properties of undefined (reading 'documents')`. Source: `dist/index.mjs:550`.
2. **`@barkpark/core` `client.doc()` silently returns undefined (P0, #18).** Same envelope-wrapper bug in `getDoc` (`dist/index.mjs:432-448`). Consumers see ghost-missing docs with no error path. D1 + D2 share root cause and should be fixed under one ADR.
3. **Transport, auth, and perspective passthrough all work.** `fetchRaw` escape hatch returns clean Phoenix JSON; `?perspective=drafts` traversal verified on the wire (count=20, includes `drafts.*` IDs); npm install + tarball SHA-512 integrity all check out.

### W8.2 — CLI + starters — `docs/ops/shakedown/w2-cli-starters.md`

1. **Scaffold pins `@barkpark/{core,nextjs,react}@0.1.0` (P0, #17).** Only `1.0.0-preview.0` is published. First `npm install` hits `ETARGET`. The CLI then exits 0 and prints `└ Done.` (P1, #22) — misleading.
2. **`@barkpark/nextjs` requires React ≥19; starter + README pin React 18 (P0, #19).** After patching DEF-1, install fails with `ERESOLVE`. With `--legacy-peer-deps`, `pnpm dev` boots but every page returns HTTP 500 with `TypeError: createContext is not a function`; `pnpm build` exits 1 with the same error. This breaks E2 entirely.
3. **`scripts.codegen` references missing CLI binary (P1, #20)** and `@barkpark/{client,website-starter,blog-starter}` are not on the registry (P2, #23). No standalone starter installation path exists.

### W8.3 — Marketing site + demo — `docs/ops/shakedown/w3-marketing-demo.md`

1. **Vercel `BARKPARK_API_URL` env var missing (P1, #11).** All proxy routes (`/api/barkpark/*`) return HTTP 502 with body `{"error":"BARKPARK_API_URL is not set"}`. Task #1 set `NEXT_PUBLIC_API_URL` but `apps/demo` reads the un-prefixed `BARKPARK_API_URL` server-side. `/blog`, `/post` are functionally dead.
2. **Primary "Get Started" CTA broken (P1, #12).** `/docs` 308-redirects to `docs.barkpark.cloud` which has no DNS record (HTTP 000, connection failure). Combined with #11, every visible CTA on the homepage leads nowhere.
3. **SEO/discoverability papercuts.** No top-nav (P2, #14): `/blog`, `/pricing`, `/post` unreachable from non-home pages. 404 returns HTTP 200 (P3, #13). `/post` page uses generic `Barkpark Demo` title (P3, #15).

### W8.4 — Phoenix API + Studio — `docs/ops/shakedown/w4-api-studio.md`

1. **Backend is healthy.** All 21 endpoint checks pass; perspectives semantically correct (`published=18 / drafts=65 / raw=71`); auth enforces 401 on missing/bad tokens across `/v1/schemas/production`, `/v1/data/mutate/production`, and `/media/upload`.
2. **Publish round-trip works as specified.** `create → drafts.shakedown-w4`, `publish → shakedown-w4`, `unpublish → drafts.shakedown-w4`, `delete` round-trip completed with full cleanup. Sub-20ms latencies throughout.
3. **One docs-vs-code mismatch (P2, #9).** `delete` mutation requires `{"id":"x","type":"post"}`; CLAUDE.md API Quick Reference shows id-only `{"delete":{"id":"x"}}` which returns HTTP 400 `malformed`. Either accept id-only or update docs.

---

## Defect inventory

All defects filed via `doey task create --created-by W8.<n>` and tracked under task #8 in this team.

| # | Severity | Surface | Title |
|---|---|---|---|
| #16 | **P0** | W1 SDK | `@barkpark/core` query path cannot decode Phoenix response envelope |
| #17 | **P0** | W2 CLI | `create-barkpark-app` scaffolds wrong dep versions (`@barkpark/core@0.1.0` — only `1.0.0-preview.0` published) |
| #18 | **P0** | W1 SDK | `@barkpark/core` `client.doc()` returns `undefined` against live API (same envelope bug as #16) |
| #19 | **P0** | W2 CLI | `@barkpark/nextjs` preview requires React 19 but starter pins React 18 — dev + build crash with `createContext` TypeError |
| #11 | P1 | W3 Marketing | Vercel `BARKPARK_API_URL` env var missing — `/blog`, `/post`, all proxy routes return 502 |
| #12 | P1 | W3 Marketing | Primary 'Get Started' CTA broken — `/docs` redirects to `docs.barkpark.cloud` (HTTP 000, DNS fail) |
| #20 | P1 | W2 CLI | Scaffold `codegen` script calls `barkpark` CLI but no package providing it is in deps |
| #21 | P1 | W1 SDK | `@barkpark/react` types break consumer `tsc` without `@types/react` (DX) |
| #22 | P1 | W2 CLI | `create-barkpark-app` reports `Done.` on success path even when `npm install` fails |
| #9 | P2 | W4 API | `delete` mutation requires `type` field; docs say id-only |
| #14 | P2 | W3 Marketing | Marketing site has no top-nav — `/blog`, `/pricing`, `/post` unreachable from non-home pages |
| #23 | P2 | W2 CLI | `@barkpark/client`, `@barkpark/website-starter`, `@barkpark/blog-starter` not published |
| #13 | P3 | W3 Marketing | Site 404 returns HTTP 200 (Next.js streamed not-found) — SEO/crawler risk |
| #15 | P3 | W3 Marketing | `/post` page uses generic layout title `Barkpark Demo` — no type-specific `<title>` |

**Totals:** 4 × P0 · 5 × P1 · 3 × P2 · 2 × P3 = **14 defects**.

---

## Recommended next-sprint priorities

### Slice 8.3 (external beta) — blockers

The four **P0** defects must be fixed and re-published as `1.0.0-preview.1` before any external beta invitation. Recommended grouping:

1. **SDK envelope contract** — fix #16 + #18 together. Either change `@barkpark/core` to read flat envelope, or change Phoenix to emit `{result: {documents, ...}}`. Document the chosen contract in an ADR before the cut.
2. **Scaffold versioning + React 19 alignment** — fix #17 + #19 together in `create-barkpark-app`. Pin `@barkpark/*` to `^1.0.0-preview.1` (or use `latest` dist-tag) and align starter `react`/`react-dom` to `^19.0.0`. Update README copy.

### Slice 8.3 (external beta) — should-fix-before-beta

The five **P1** defects degrade the first-touch experience to the point where a beta invite would generate noise rather than signal:

- **#11 + #12** make the marketing site functionally inert from a visitor's perspective. Set `BARKPARK_API_URL` + `BARKPARK_PUBLIC_READ_TOKEN` in Vercel Production env; fix or remove the `/docs` redirect.
- **#20 + #22** make CLI failures invisible. Cheap fixes (CLI exit-code propagation + add `@barkpark/codegen` to scaffold deps).
- **#21** trips every fresh TypeScript consumer. Add `@types/react` peer or inline types.

### Backlog (P2/P3)

- #9, #14, #23 — paper over before slice 8.4 (Lighthouse) so the audit doesn't pick them up as marketing failures.
- #13, #15 — bundle into a slice 8.4 SEO sweep alongside the Lighthouse work.

### Re-shakedown gate

After `1.0.0-preview.1` ships, **re-run W1 + W2 only**. W3 + W4 outcomes are decoupled from the SDK fixes (W3 wants Vercel env updates; W4 only needs a docs-vs-code reconciliation). A focused W1+W2 re-run in ~30 minutes will confirm the SDK + CLI gate is unblocked.

---

## Artefacts

- `docs/ops/shakedown/w1-sdk-e2e.md` — 17 KB, full SDK transcript + tarball integrity + envelope source pinpoints
- `docs/ops/shakedown/w2-cli-starters.md` — 11 KB, full scaffold transcript + 5 install attempts + dev/build crash logs
- `docs/ops/shakedown/w3-marketing-demo.md` — 9 KB, full HTTP audit + broken-link sweep + CTA matrix
- `docs/ops/shakedown/w4-api-studio.md` — 10 KB, 21-row endpoint table + perspective deltas + auth matrix + round-trip transcript
