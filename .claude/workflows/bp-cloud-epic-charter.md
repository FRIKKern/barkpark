# Epic charter — Consumer web-demo & scaffold-template correctness audit

Epic task: `web-templates-correctness-audit`
Wave Paper: `web-templates-correctness-wave-2026-08-18`
Audited against origin/main `9fd1e383e7affd6281742566a07a979967737397`.

## Vision

An improvement-only, evidence-based correctness/robustness/UX sweep of the Next.js consumer surfaces users COPY — the `web/` demo (app, components, lib) and the two `create-barkpark-app` scaffolds (`blog-starter`, `website-starter`). A bug in a template ships to EVERY scaffolded project, so correctness in the higher-reach tier has multiplied blast radius. This is a DISTINCT lens from the merged consumer CSP/XSS security work (injection); do NOT re-pave the `proxy.ts` nonce, `lib/csp.ts`, or the template `middleware.ts`. NON-security. Four classes: (1) data-fetching & error states, (2) rendering correctness, (3) Next patterns, (4) async & state. The deliverable is an HONEST per-class verdict — the count stated even when zero — where every REAL finding carries a concrete input/state → broken-UI-or-crash reproduced against origin/main and is fixed with a test or before/after repro (or filed if larger), and every SAFE pattern is cited by the specific guard that makes it safe (error-boundaried, optional-chained, fallback-rendered, awaited). The honest cited-safe verdict IS the A-grade; a manufactured finding count is the failure mode.

Fence: `web/` (app, components, lib) + `js/packages/create-barkpark-app/templates` + any test tree (`web/__tests__`) ONLY. DISJOINT from the running JS-SDK wave (`js/packages/core`, `js/packages/nextjs`, `js/packages/react`) and the search+media wave (`api/lib/barkpark/search`, `api/lib/barkpark/media`). A template change touching a file vendored into `cloud/priv/templates` requires `make cloud-templates-sync` — the ONLY permitted `cloud/` touch. No `api/`, no `internal/`.

## Decisions

- **D1 — The `web/` demo ships ZERO correctness fixes; the honest per-class zero IS the finding.** Why: 17 scouts plus a dedicated graph-view verifier re-derived every web/ candidate to a cited guard (bp-fetch throws only structured `BpUpstreamError`; `app/error.tsx`+`global-error.tsx`+`not-found.tsx` cover let-throw fetches; 3 date formatters NaN-guard; `fetchCorpusGraph` never-throws and always returns arrays; every effect has cleanup, every promise a catch). Manufacturing a fix on a guarded path is the exact failure the reach-weighted direction rejected.
- **D2 — All five real findings are template-tier; fix the four offline-provable ones, file the fifth.** Why: the reach-weighting prediction held exactly — bugs are dense where comment density drops, which is the scaffold edges the demo has no analogue for (by-id 404, module-eval webhook throw, unguarded sitemaps, pre-seed empty data).
- **D3 (CROWN) — Swallow `BarkparkNotFoundError` → `null` in `getDocById` (blog) AND `getDoc` (website).** Why: the by-id endpoint 404s a missing doc, and `barkparkFetch` throws `BarkparkNotFoundError` (a plain error with NO `NEXT_NOT_FOUND` digest) → renders `error.tsx` (500) not `not-found.tsx` (404), making `if(!x) notFound()` DEAD CODE. Swallowing is symmetric with `getDocBySlug` and the SDK's own `client.doc` 404→null convention, and every one of the six call sites already branches on null. Fixes authors/[id] 500, dangling-ref valid-post 500, AND the fresh-scaffold pre-seed home/about/pricing 500. HIGH-FLIP (ships to every scaffold).
- **D4 — The webhook fix defers validation to request time (lazy handler → 503 when unset), NOT a `.env.example` default.** Why: `createWebhookHandler({secret: process.env.BARKPARK_WEBHOOK_SECRET!})` runs at MODULE-EVAL and throws `TypeError` on the unset secret, failing `next build` at "Collecting page data" for every fresh scaffold (build-probe confirmed exit 1 unset / exit 0 set). A guessable `changeme` default would ship a live webhook secret; deferring the throw un-breaks the build while keeping fail-CLOSED (an unconfigured webhook 503s, never fail-open verifies). HIGH-FLIP.
- **D5 — Template sitemaps adopt the demo's degrade-to-static pattern + a NaN date guard.** Why: `web/app/sitemap.ts` already proves the pattern ("NEVER throws: any upstream failure degrades to the static routes"); the template sitemaps have NO try/catch (crash on API 500/network during build or crawl) and hand an Invalid Date to Next's `lastModified` → `.toISOString()` `RangeError`.
- **D6 — Render-tier dates get a per-template `formatDate` helper; fractional `?page` floored; portable-doc `void` gets `.catch()`.** Why: LOW severity but cheap and offline-provable — four render sites currently emit the literal "Invalid Date" behind a truthiness-only guard; `?page=2.5` sends a fractional offset to the API; the `void hydratePortableDoc()` leaves an unhandled rejection.
- **D7 — Every template fix runs `make cloud-templates-sync` and stages ONLY its own mirrored `cloud/priv/templates` paths — never `git add -A`, never the whole cloud dir.** Why: the drift test is bidirectional and armed (trees drift-clean today, Makefile:140); a full-tree sync followed by a broad add stages reverts of sibling slices' cloud copies at merge — the vendored-drift merge hazard.
- **D8 — Proof standard: templates have no harness, so each slice adds a self-contained extract-and-compare test in `web/__tests__` (runs under plain `node --test`, no workspace linking) PLUS a before/after node repro of the real template behavior.** Why: uniform verify bar; the wish accepts a `web/__tests__` analogue or a before/after repro, and the self-contained test needs neither the `@barkpark/*` dist build nor the server-only loader.
- **D9 — All wave-1 slices are round 1 (distinct files, no cross-slice code dependency); builder model opus@medium throughout.** Why: Fable is capped until Aug 21 and none of these slices is visually designed (correctness, not CSS); the fixes are well-specified and file-disjoint, so they build in parallel this run.
- **D10 — The `BARKPARK_SERVER_TOKEN` dev-token default and the blog pagination-windowing UX gap are FILED, not built blind.** Why: the token default is a documented design tradeoff (a prod-guard that throws on `NODE_ENV==='production' && unset` is HIGH-FLIP and needs its own decision); the "fudged totalPages" (wire `countDocs` → true total) is a UX item outside the correctness fence.

## Roadmap

Wave 1 (this wave) — four file-disjoint round-1 slices, all opus@medium:

| Slice | Task | Surface | Size | Files (source; cloud mirror synced) |
|---|---|---|---|---|
| S1 crown 404→500 | `wtc-w1-s1-byid-notfound-swallow` | template lib | medium | blog+website `lib/barkpark.ts` |
| S2 webhook build-break | `wtc-w1-s2-webhook-lazy-init` | template route | medium | blog+website `app/api/barkpark/webhook/route.ts` |
| S3 sitemap degrade | `wtc-w1-s3-sitemap-degrade-nan` | template route | small | blog+website `app/sitemap.ts` |
| S4 render robustness | `wtc-w1-s4-render-date-page-hydrate` | template pages | medium | blog+website render pages + new `lib/format-date.ts`, blog page/draft-preview/portable-doc-surface |

Backlog (filed, future waves):
- `wtc-backlog-server-token-prod-guard` — fail-loud when `BARKPARK_SERVER_TOKEN` unset in production (documented tradeoff; needs a decision).
- `wtc-backlog-blog-pagination-true-total` — wire `countDocs` → true `totalPages` so the pagination window stops fudging (UX, out of correctness fence).

## Wave log

### Wave 2026-08-18 — wave 1 (grade A)

**Landed (4 file-disjoint template-tier slices, all gates re-run green on the reviewer's final branches):**

- **S1 crown — by-id 404→null** (`wtc-w1-s1-byid-notfound-swallow`, branch `loop-epic/s1-crown-swallow-barkparknotfounderror-n-0`). `getDocById` (blog) and `getDoc` (website) now swallow `BarkparkNotFoundError`→null so a by-id miss renders `not-found.tsx` (404) not `error.tsx` (500). Reviewer independently re-derived the crown: the thrower (`js/packages/nextjs/src/server/core.ts:211`) and the catcher both reference `BarkparkNotFoundError` from `@barkpark/core`, so `instanceof` matches in a deduped install — the SDK's own `client.doc` convention. HIGH-FLIP: an independent 2nd reviewer is owed before merge (manual lead step).
- **S2 webhook lazy-init** (`wtc-w1-s2-webhook-lazy-init`, branch `loop-epic/s2-webhook-lazy-init-createwebhookhandle-1`). Webhook route no longer calls `createWebhookHandler` at module-eval; an unset `BARKPARK_WEBHOOK_SECRET` now serves a fail-CLOSED 503 instead of breaking `next build`. `validateConfig` throw + `{POST,GET}` handler shape verified in source. HIGH-FLIP: 2nd reviewer owed.
- **S3 sitemap degrade + NaN guard** (`wtc-w1-s3-sitemap-degrade-nan`, final branch `loop-epic/s3-sitemap-degrade-to-static-on-upstream-2-r`). Both template sitemaps degrade-to-static on upstream failure and NaN-guard `_updatedAt`. **Reviewer fix:** the builder shipped without the required `create-barkpark-app` changeset (the changesets CI gate reds a public-package change without one); reviewer added it on the `-r` branch — integrate `-r`, not the original.
- **S4 render robustness** (`wtc-w1-s4-render-date-page-hydrate`, branch `loop-epic/s4-render-robustness-formatdate-helper-f-3`). `formatDate` null-guard against "Invalid Date", floored fractional `?page`, `.catch()` on the portable-doc hydrate. Sound.

**web/ demo:** honest ZERO across all four correctness classes, upheld — every candidate cited to a guard. The reach-weighting prediction (D2) held: all five real bugs were in the higher-reach scaffold tier where comment density drops.

**Filed, not built:** `wtc-backlog-server-token-prod-guard` (BARKPARK_SERVER_TOKEN prod-guard — needs a decision) and `wtc-backlog-blog-pagination-true-total` (UX, out of correctness fence).

**Ledger:** clean — every slice `in_progress` with all non-merge-gated criteria stamped with real evidence; the lead-owned "PR merged" row left open on each. The lead closes those on merge.

**Grade A.** Honest cited-safe verdict delivered exactly as the wish demanded; one point off A+ for the self-contained tests pinning logic-shape rather than importing the shipped template modules (unavoidable; compensated by drift-diff + git-diff) and S3's missing changeset (reviewer-fixed).

**Next wave:** merge wave 1 first (S1/S2/S4 originals + the S3 `-r` branch; give S1 + S2 an independent second reviewer before merge). Then the two backlog items become candidate slices once their decisions are made — the `BARKPARK_SERVER_TOKEN` prod-guard needs a flip-risk decision (throw on `NODE_ENV==='production' && unset`), and the blog pagination true-total wiring (`countDocs`→`totalPages`) is a UX slice.
