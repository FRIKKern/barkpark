# W8.3 — Marketing site + demo audit (read-only)

**Worker:** W8.3 · **Task #:** 8 / subtask 3 · **Date:** 2026-04-19
**Scope:** barkpark.cloud (Vercel-hosted) + `apps/demo/` in repo.
**Method:** curl-only. No source edits. No redeploys.

---

## 1. HTTP headers & metadata (homepage)

```
$ curl -sI https://barkpark.cloud/
HTTP/2 200
server: Vercel
content-type: text/html; charset=utf-8
x-nextjs-prerender: 1
x-vercel-cache: HIT
strict-transport-security: max-age=63072000; includeSubDomains; preload
access-control-allow-origin: *
cache-control: public, max-age=0, must-revalidate
vary: rsc, next-router-state-tree, next-router-prefetch, next-router-segment-prefetch
etag: "87f7dd20ba55c34d935e76ac03f5046a"
content-length: 11012
```

**Title:** `Barkpark — Headless CMS for Next.js`
**Meta description:** `Apache-2.0 headless CMS for the Next.js App Router. Self-host in one command.`
**Viewport:** `width=device-width, initial-scale=1`
**Charset:** utf-8

Nothing else in `<head>` — no Open Graph, no Twitter card, no canonical, no favicon link, no robots meta, no sitemap reference.

## 2. Heading hierarchy (per page)

| URL | `<title>` | h1 | h2 | h3 |
|---|---|---|---|---|
| `/` | Barkpark — Headless CMS for Next.js | `Barkpark Demo` (header) | `Headless CMS for Next.js. Apache-2.0. Self-host in one command.` | `TypeScript-first`, `Real-time Studio`, `Zero vendor lock-in` |
| `/post` | **Barkpark Demo** (layout fallback — DEFECT) | `Barkpark Demo` (header) | `post` | — |
| `/blog` | Blog — Barkpark (assumed) | `Blog` | — | — |
| `/pricing` | Pricing — Barkpark | `Pricing` | `Open Source`, `Coming later: Hosted` | — |

Heading use is semantically loose — homepage uses an `<h2>` for the hero headline while the site brand sits in an `<h1>` in the header. Not blocking, but crawlers will see "Barkpark Demo" as the dominant page headline on every page.

## 3. API wiring observation

- **No client-side API calls.** Inspecting the rendered HTML: no `89.167.28.206`, no `api.barkpark.cloud`, no `NEXT_PUBLIC_API_URL` leak. All data-fetching happens server-side.
- Architecture (per `apps/demo/README.md`): browser → Vercel edge → Next.js route handlers (`/api/barkpark/*`) → Barkpark API. Intentional to dodge mixed-content blocking (HTTP origin behind an HTTPS site).
- **The demo does NOT import `@barkpark/nextjs@preview`.** `apps/demo/package.json` dependencies: only `next`, `react`, `react-dom`. It uses an in-repo helper `lib/barkpark.ts` that reads `process.env.BARKPARK_API_URL` and calls `fetch()` directly. The task hint assumed `@preview` consumption; this is either a conscious design choice (demo pre-dates the SDK) or a gap worth deciding on.

## 4. Broken links table

| URL | HTTP | Source | Notes |
|---|---|---|---|
| `/` | 200 | self | — |
| `/docs` | 308 → `https://docs.barkpark.cloud/` → **000** | homepage primary CTA | Subdomain unresolved/unreachable. **BROKEN.** |
| `/post` | 200 | homepage secondary CTA | Body renders `Upstream error (502)` — see §5. |
| `/post/p1` | 200 | `/post` (if rendered) | Same upstream error path. |
| `/blog` | 200 | (not linked from /) | Body renders `Could not load posts right now.` — same root cause. |
| `/pricing` | 200 | (not linked from /) | OK, no API dependency. |
| `/api/barkpark/schemas` | 200 | internal | Falls back to static `PUBLIC_SCHEMAS` — works. |
| `/api/barkpark/query/post` | **502** | internal | `{"error":"BARKPARK_API_URL is not set"}` |
| `/api/barkpark/doc/post/p1` | **502** | internal | Same. |
| `/nonexistent` | **200** | n/a | Next.js default not-found streamed inside HTTP 200 — SEO risk. |

HSTS + HTTPS + Vercel CDN caching all look healthy.

## 5. CTA audit

| CTA text | Target | Resolves to | Matches reality? |
|---|---|---|---|
| **Get Started** (primary, black button) | `/docs` | 308 → `https://docs.barkpark.cloud/` → HTTP 000 | ❌ **BROKEN.** Docs subdomain is not live. |
| **View Live Demo** (secondary) | `/post` | 200, renders `Upstream error (502). Confirm BARKPARK_API_URL and BARKPARK_PUBLIC_READ_TOKEN are set.` | ❌ Page loads but data is dead. |

The homepage also has zero install-instruction copy (`npm create barkpark-app@preview`, `pnpm add @barkpark/nextjs`, etc.). The only mention of install appears in the `<meta description>`: "Self-host in one command" — no command shown anywhere on `/`.

## 6. Demo app audit (`apps/demo/`)

**`package.json`** (name `@barkpark/demo`, version `0.1.0`, private):
- `next@^15.1.0`, `react@^19.0.0`, `react-dom@^19.0.0`
- No dependency on `@barkpark/nextjs@preview` — uses raw fetch through `lib/barkpark.ts`.
- pnpm 9.15.9.

**Structure:**
```
app/
  page.tsx                     # hero + 3 features, links to /docs & /post
  layout.tsx                   # header + inline style shell
  docs/route.ts                # GET → 308 redirect to docs.barkpark.cloud (broken)
  [type]/page.tsx              # list published docs of a type
  [type]/[id]/page.tsx         # doc detail
  blog/page.tsx                # blog index (ISR, revalidate 60s)
  blog/[slug]/page.tsx         # blog post detail
  pricing/page.tsx             # static pricing
  api/barkpark/schemas/route.ts        # returns fallback list
  api/barkpark/query/[type]/route.ts   # proxy → /v1/data/query/... (502 in prod)
  api/barkpark/doc/[type]/[id]/route.ts # proxy → /v1/data/doc/... (502 in prod)
lib/
  barkpark.ts                  # fetch + types + BarkparkFetchError
  public-schemas.ts            # static fallback
  revalidate.ts                # ISR helper (60s default)
next.config.mjs                # image remotePatterns allow 89.167.28.206 + api.barkpark.cloud
vercel.json                    # fra1 region, HSTS header, cleanUrls
.env.example                   # documents BARKPARK_API_URL + BARKPARK_PUBLIC_READ_TOKEN
```

**Run result:** not attempted — audit-only. Local run would require `.env.local` with a valid token; the required vars are not committed.

**Reality check vs reality:**
- `.env.example` states `BARKPARK_API_URL=http://89.167.28.206` (IP only, no port) — the CLAUDE.md and API actually answer on port 4000 directly (but Caddy fronts :80, so bare IP is correct). Backend API URL can also be `https://api.barkpark.cloud` per recent task #4 TLS cutover — the demo’s `next.config.mjs` already whitelists both, but the README still documents the IP form. Minor drift.
- README `## Vercel deploy` step 4 lists `BARKPARK_API_URL` and `BARKPARK_PUBLIC_READ_TOKEN` — matches code.

## 7. Copy issues & missing pages

- **No install instructions anywhere on `/`.** "Self-host in one command" is claimed but never shown. The hero should include a one-liner `npm create barkpark-app@preview` or `curl … | bash`.
- **No nav / footer.** Non-home pages offer only `← Back` — `/blog` and `/pricing` are unreachable from `/` entirely. File tree exists; discoverability does not.
- **`/post` title is `Barkpark Demo`** (layout fallback). Needs `generateMetadata` on `[type]/page.tsx`.
- **`/blog` shows red error text** to end-users (`Could not load posts right now.`). Fine for a fallback but fingers the root cause in §5.
- **404 page returns HTTP 200.** Next.js's streamed default-not-found — search engines will index dud URLs.
- **No Open Graph / Twitter meta**, no canonical, no `robots.txt` fetched (not tested here), no sitemap.
- The pricing page text "Coming later: Hosted" is fine but the email signup form is a `<p>` not an actual form — verify on the rendered page if a newsletter provider is expected.

## 8. Forms / interactive embeds

None detected in the rendered HTML for `/`, `/post`, `/blog`, `/pricing` — no `<form>` tags, no hCaptcha/Turnstile, no newsletter embed script. Pricing page mentions email signup as body copy only. **Manual test not required — nothing interactive is wired up.**

## 9. DEFECTS (filed)

| # | Task ID | Severity | Title |
|---|---|---|---|
| 1 | **#11** | P1 | Vercel `BARKPARK_API_URL` env var missing — `/blog`, `/post`, all proxy routes return 502 |
| 2 | **#12** | P1 | Primary 'Get Started' CTA broken — `/docs` → `docs.barkpark.cloud` (HTTP 000) |
| 3 | **#13** | P3 | Site 404 returns HTTP 200 (Next.js streamed not-found) — SEO/crawler risk |
| 4 | **#14** | P2 | Marketing site has no top-nav — `/blog`, `/pricing` unreachable from non-home pages |
| 5 | **#15** | P3 | `/post` page uses generic layout title `Barkpark Demo` — add `generateMetadata` |

### Severity summary

- **P1 (blocking shake-down):** 2 defects. Both CTAs on the homepage are dead (`/docs` DNS-fails; `/post` loads but shows a 502 from the upstream proxy). Any visitor reaching the site today cannot reach the product.
- **P2:** 1 defect — navigation/discoverability.
- **P3:** 2 defects — SEO hygiene and metadata.

### Root cause concentration

`#11` is almost certainly the same root cause as the "Upstream error" seen on `/post`, `/post/p1`, and the red error on `/blog`. Fixing the Vercel env var (and adding the read token) should turn all three pages green. Task #1 logged "`NEXT_PUBLIC_API_URL` set" — but the demo reads the un-prefixed `BARKPARK_API_URL` (intentional, per `.env.example`: "NEVER prefix with NEXT_PUBLIC_"). The handoff mis-named the variable.

---

**End of report — W8.3 audit complete.**
