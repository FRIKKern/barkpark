<!-- doc-tier: agent | canonical-for: vercel-dns-cutover | budget: 2900tok -->
# Vercel custom domain attach for `barkpark.cloud`

**Status:** Runbook. Boss-executed via Vercel dashboard + registrar.
**Owner:** Boss. Platform worker supports.
**Resolves blockers:** §13.C B2 (Vercel Pro tier), B3 (DNS TTL propagation window).
**Target project:** `demo` (builds from `web/`) in the `guerrilla` Vercel team.
**Apex:** `barkpark.cloud` (production). **Subdomain:** `www.barkpark.cloud` (redirect to apex).

Out of scope: API subdomain TLS (see `docs/ops/adding-a-domain.md`), Phoenix-side CORS, deployment pipeline changes.

---

## Preconditions

All must be `yes` before starting. Any `no` = stop and resolve first.

| Check | How | Expected | Blocker ref |
|---|---|---|---|
| Vercel team plan | Vercel dashboard → team → Settings → Billing | **Pro** (~$20/seat/mo). Hobby tier will refuse `vercel domains add` for production. | B2 |
| `demo` project exists and is the Production deployment | Vercel dashboard → project list → `demo` | Project shows a Production deployment on branch `main`, building from `web/` | — |
| Registrar access | Boss has login to the current `barkpark.cloud` registrar | Can create/edit A, CNAME, TXT records | — |
| Domain `barkpark.cloud` is registered and under our control | `whois barkpark.cloud` from any shell | Registrant matches Boss (or org registration) | — |
| Current TTL on existing `barkpark.cloud` records | `dig barkpark.cloud +short` then check authoritative via `dig +nssearch barkpark.cloud` or registrar UI | TTL ≤ 3600 (1h). If higher, lower NOW and wait for old TTL to expire before cutover. | B3 |
| No conflicting root-level services | `dig barkpark.cloud A` and `dig barkpark.cloud MX` | A records can be replaced; if MX exists (email), do not remove — preserve alongside the new A record. | — |
| `demo` has `NEXT_PUBLIC_BARKPARK_API_URL` env var slot | Vercel project → Settings → Environment Variables | Variable exists (may need renaming from any Phase 7D placeholder or the legacy `NEXT_PUBLIC_API_URL`) | — |
| SSL/TLS compliance posture agreed | n/a | Vercel auto-provisions Let's Encrypt; no action. | — |

### TTL lowering (do this 48h before cutover)

Per v2 §13.C B3:

1. Visit registrar DNS UI.
2. For every existing record on `barkpark.cloud` (apex A, `www` CNAME, any TXT, MX), set TTL to **300 seconds**.
3. Save. Note the exact timestamp — cutover window opens after the OLD TTL expires (common defaults: 3600s, 14400s, 86400s).
4. Confirm lowered TTL is live from at least two geos: `dig @1.1.1.1 barkpark.cloud` and `dig @8.8.8.8 barkpark.cloud` — look at the TTL in the answer section.

**Do not proceed to the cutover steps below until the old (high) TTL has visibly expired.** If the registrar shows current records still report TTL 86400, wait 24h from the moment you lowered it.

## Step-by-step — Vercel dashboard actions (Boss performs)

These are the click paths as of 2026-04. Vercel UI changes periodically; if navigation differs, search for the underlined item name.

### 1. Upgrade team to Pro (if not already)

- Vercel dashboard → upper-left team switcher → **`guerrilla`** → **Settings** → **Billing**.
- If plan reads "Hobby", click **Upgrade to Pro**. Confirm billing email. Accept ~$20/user/mo charge.
- If the team has multiple members, decide who needs Pro seats now (Boss alone is enough for launch).

**Fallback if Pro blocked by budget** (see §13.C B2 Fallback A): skip the dashboard steps below, use `barkpark.cloud.vercel.app` as the live URL, and set a Cloudflare worker 301 redirect from `barkpark.cloud` → `barkpark.cloud.vercel.app`. Requires registering `barkpark.cloud` with Cloudflare's free tier.

### 2. Attach `barkpark.cloud` to the `demo` project

- Dashboard → **`demo`** project → **Settings** → **Domains** (left-nav).
- Text input **"Add Domain"** → enter `barkpark.cloud` → click **Add**.
- Vercel prompts: choose redirect posture.
  - **Primary domain:** `barkpark.cloud` (apex).
  - **Redirect:** `www.barkpark.cloud` → `barkpark.cloud` (301).
- Vercel displays the DNS records required. Screenshot them — they determine the registrar edits in step 4.

### 3. Configure production environment variables

- Same project → **Settings** → **Environment Variables**.
- Set for **Production** scope only:

  | Key | Value | Why |
  |---|---|---|
  | `NEXT_PUBLIC_BARKPARK_API_URL` | `https://api.barkpark.cloud` | SSR + client fetches target the TLS-terminated Phoenix (see `adding-a-domain.md`). Must be `https://`; Vercel-origin mixed-content protection rejects `http://`. (Legacy alias `NEXT_PUBLIC_API_URL` still read as a fallback.) |
  | `BARKPARK_TOKEN` | dev/prod read token (server-only — do **NOT** prefix with `NEXT_PUBLIC_`) | SSR fetches authenticate against scoped `/w/:workspace/p/:project/...` routes and the SSE listen proxy. Without it, those routes return 403/401 (anonymous). Do not check into git. (Legacy alias `BARKPARK_READ_TOKEN` still read as a fallback.) |
  | `BARKPARK_WEBHOOK_SECRET` | current HMAC secret (see slice 8.6 security audit) | Inbound webhook HMAC verifier in `app/api/barkpark/webhook/route.ts` uses this to sign `<timestamp>.<body>` via `node:crypto` SHA-256. Without it the route returns 500 (webhook_not_configured). |
  | `BARKPARK_WEBHOOK_PREVIOUS_SECRET` | prior HMAC secret during rotation window | `previousSecret` dual-verify path (slice 8.6, R-S5b). Leave empty when not rotating. |
  | `BARKPARK_DATASET` | `docs` | Dataset the web app queries and cache-busts against. Must match the dataset name in the live Barkpark instance — the webhook emits `dataset:"docs"` so this value and the webhook must stay in sync. |

- Optional feature flags (if referenced by the `web/` app):
  - `BARKPARK_FETCH_TIMEOUT_MS` — per-request timeout for the server-side
    Barkpark fetches. (An earlier revision listed `BARKPARK_PREVIEW_TTL_SECONDS`
    here; nothing in `web/` has ever read it — setting it is a no-op.)
  - `NEXT_TELEMETRY_DISABLED=1` — cosmetic, opt out of Next.js anonymized telemetry on build.

- Save. Do **not** trigger a redeploy yet — wait for DNS to propagate (step 4) so the first production hit after cutover uses the new config.

### 4. Registrar DNS records

Vercel will display either an A-record set or a CNAME-to-`cname.vercel-dns.com`, depending on whether you're using Vercel DNS or an external registrar. The typical set for apex + www on an external registrar:

| Record | Host | Type | Value | TTL |
|---|---|---|---|---|
| Apex | `@` (or blank) | `A` | `76.76.21.21` (Vercel's documented apex IP; verify against dashboard output) | 300 |
| www | `www` | `CNAME` | `cname.vercel-dns.com.` (trailing dot matters on some registrars) | 300 |
| TXT verification (if prompted) | `_vercel` (or whatever host Vercel shows) | `TXT` | value shown in dashboard | 300 |

**If Vercel provides different values in the dashboard, use those — the values above are current at time of writing but Vercel publishes canonical values in the "Add Domain" UI.**

Do NOT delete existing MX or DKIM records for email. Leave them alongside.

### 5. Verify and watch issuance

- Back in Vercel dashboard → Domains panel. The domain row will cycle through `Invalid Configuration` → `Verifying` → `Valid`. Typically 2–30 min after DNS propagates.
- Once `Valid`, Vercel auto-issues a Let's Encrypt cert. Status moves to `Issuing Certificate` → ✓.
- Click **Redeploy** on the latest Production deployment to pick up the new env vars (step 3).

## Verification

Run from a machine that is **not** the registrar's cache — ideally your laptop on mobile tether, to dodge ISP DNS caching.

```sh
# DNS resolves to Vercel
dig +short barkpark.cloud A
# Expected: 76.76.21.21 (or the value shown in Vercel dashboard)

dig +short www.barkpark.cloud CNAME
# Expected: cname.vercel-dns.com.

# HTTPS serves the Next.js app
curl -sS -I https://barkpark.cloud/ | head -5
# Expected: HTTP/2 200 and server: Vercel

# Apex loads (not www)
curl -sSI https://www.barkpark.cloud/ | head -5
# Expected: HTTP/2 308 (redirect) with location: https://barkpark.cloud/

# Vercel issued a real cert (not their self-signed placeholder)
echo | openssl s_client -connect barkpark.cloud:443 -servername barkpark.cloud 2>/dev/null | openssl x509 -noout -issuer -subject -dates
# Expected: issuer includes "Let's Encrypt", notAfter within 90 days

# The site actually talks to Phoenix
curl -sS "https://barkpark.cloud/api/find?q=test" | head -c 200
# /api/find is the server-only proxy that authenticates with BARKPARK_TOKEN.
# (There is no /api/barkpark/schemas route — web/app/api/barkpark/ holds only
#  webhook/. The routes that exist are find, find-event and search-seed.)
# Expected: JSON from Phoenix, proving BARKPARK_TOKEN and
#           NEXT_PUBLIC_BARKPARK_API_URL are both live.

# Multi-geo DNS check — confirm propagation reached major resolvers
for ns in 1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222; do
  echo "--- $ns"
  dig @$ns +short barkpark.cloud A
done
# Expected: all return the Vercel apex IP. If any return the old record,
# propagation is still in flight — wait another hour or two.
```

## Rollback

### Tier 1 — Cosmetic / misconfig (site loads but broken)

Unset the bad env var, redeploy. Does not touch DNS. Reversible in <5 min.

- Dashboard → project → Settings → Environment Variables → edit bad var → Save.
- Deployments → latest prod → **Redeploy** (without build cache if config-only).

### Tier 2 — Detach domain, keep Vercel project alive

- Dashboard → project → Settings → Domains → row for `barkpark.cloud` → **⋯ menu** → **Remove**.
- Confirm. Domain detaches; the Vercel project stays at its `*.vercel.app` URL.
- At registrar, restore pre-cutover A / CNAME records (keep the TTL-300 snapshot from preconditions). Expect ≤5 min DNS propagation since TTL is already low.
- `barkpark.cloud` now points wherever it pointed before the cutover (or NXDOMAIN if the domain was previously unused — which is the default assumption).

### Tier 3 — Whole-project burn-it-down

Only if the Vercel project itself is corrupted (bad deployment loop, state poisoned). Keep a known-good deployment as a rollback target in Vercel's deployment history — every merge to main creates a new immutable deployment; promote any older one to Production via the **Promote to Production** action.

## Post-cutover hygiene

After 7 days of stable operation:

- Remove the transitional `http://89.167.28.206` block from Caddy (see `adding-a-domain.md`).
- Raise DNS TTL back to 3600 for routine operations.
- Add `barkpark.cloud` + `api.barkpark.cloud` to Uptime Kuma (per slice 8.0 preflight item, not this doc).

## Known pitfalls

- **Vercel's apex IP is `76.76.21.21` as documented, but they reserve the right to change it.** Always copy-paste from the Vercel dashboard rather than trusting this doc for the live value.
- **Some registrars silently strip the trailing dot on CNAME values.** If `dig +short www.barkpark.cloud CNAME` returns an NS-loop or NXDOMAIN, check the registrar UI for missing dot.
- **Wildcard certs via Let's Encrypt require DNS-01 challenge.** Vercel only issues single-name certs for apex + www. If we later need `*.barkpark.cloud` (multiple tenants), Vercel won't cover it — move that to Cloudflare or a dedicated ACME client.
- **`NEXT_PUBLIC_` prefix leaks to browser.** Never put secrets (API tokens, HMAC secrets) behind `NEXT_PUBLIC_*`. Double-check env var list before marking done.
- **Preview deployments use a different domain and env scope.** Preview deployments at `<hash>-<project>.vercel.app` use the `Preview` env scope — set `NEXT_PUBLIC_BARKPARK_API_URL` there too, or preview builds will point at a placeholder and fail.
- **HTTP → HTTPS redirect is automatic on Vercel.** Do not configure your own redirect at the registrar — it will conflict with Vercel's edge redirect and cause loops.
- **Cached 3rd-party CDN resolvers** (Cloudflare 1.1.1.1, Google 8.8.8.8) respect the TTL you lower to 300, but corporate DNS caches and broken resolvers sometimes hold records for hours. Expect ~1% of traffic to see old records for up to 24h post-cutover even with TTL=300. This is normal; it is the reason we do the cutover ≥2 weeks before launch, not the day of.
