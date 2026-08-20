# Re-derivation recipes — `recheckSiteDeleted` reads five different answers as "the teardown completed after all" (cch wave 68, verify seat: recheck-optimism)

All recipes run from the repo root of `/Volumes/SATECHI/github/barkpark`. Every claim is
`origin/main` on 2026-08-17 unless the command says otherwise.

## R1 — the gone-predicate and the success sentence, on origin/main

```
git show origin/main:cloud/priv/static/app.js | grep -n -A24 'function recheckSiteDeleted'
```

Decisive bytes: `:13529` `var gone = r.status === 404 || (r.ok && !(r.data && r.data.site));`
and `:13535` `name + " is no longer registered — the teardown completed after all.",`.

## R2 — both functions are reachable through `__bpTestHook`, and NEITHER is driven today

```
git show origin/main:cloud/priv/static/app.js | grep -n 'siteDeleteSettlePlan\|recheckSiteDeleted'
# → :23302 siteDeleteSettlePlan, :23303 runSiteDelete + recheckSiteDeleted (the export map)
grep -c 'recheckSiteDeleted' cloud/priv/static/__app.test.mjs        # → 0
grep -rln 'recheckSiteDeleted' --include='*.mjs' --include='*.js' --include='*.exs' --include='*.ex' --include='*.md' .
# → cloud/priv/static/app.js   (the ONLY file in the repo that mentions it)
```

The export-presence test at `__app.test.mjs:20338-20343` lists only
`siteDeleteConfirmOpts / siteDeleteFailureCopy / siteDeleteSettlePlan / sitePreviewsSectionHtml` —
`runSiteDelete` and `recheckSiteDeleted` are exported but unlisted and undriven.

## R3 — DRIVE the defect (scratchpad probe, five fixtures + two negative controls)

Boot `git show origin/main:cloud/priv/static/app.js` in a `node:vm` sandbox copied from
`__app.test.mjs:30-79`, grab `hooks.recheckSiteDeleted`, swap `sandbox.fetch` /
`sandbox.document` (a `#cm-confirm` + `#toast-stack` realm), drive, drain 20 microtasks.
Probe kept out of the repo at
`<scratchpad>/probe_recheck.mjs`; re-create it from this recipe.

| fixture | today |
|---|---|
| `404 application/json {error:"not_found"}` | `succeed()` + "the teardown completed after all" |
| `200 text/html` interstitial | same |
| `200 application/json {}` | same |
| `404 text/html` (proxy/CDN, route never reached) | same |
| `204` no content | same |
| `200 {site:{…}}` (control) | inline "STILL REGISTERED" — correct |
| `500` (control) | inline "the re-check itself failed" — correct |

The two controls are what make the probe non-vacuous.

## R4 — the 404 collapses ≥4 server causes, and the DELETE-side copy already says so

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '6954,6974p'   # GET /v1/sites/:id
git show origin/main:cloud/lib/barkpark_cloud/registry.ex   | sed -n '5269,5281p'   # get_team_site
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8713,8718p'   # match _ catch-all
git show origin/main:cloud/priv/static/app.js | grep -n -A 12 'function siteDeleteFailureCopy' # arm 3
```

Causes of a byte-identical `404 {"error":"not_found"}`: `current_team` nil (`router.ex:6962`);
wrong-team id, non-UUID id (`uuid_or_nil`), genuinely-deleted row (all `router.ex:6971`);
plus the router catch-all (`:8716`). `siteDeleteFailureCopy`'s 404 arm (`app.js:13346-13353`)
enumerates four of them in prose — the same wave's DELETE reader hedges what its GET reader asserts.

## R5 — Delta 5: `#site-delete` is NOT unconditional

```
git show origin/main:cloud/priv/static/app.js | grep -n 'function loadSite\b'   # :12091
git show origin/main:cloud/priv/static/app.js | grep -n 'site-delete'           # :12143 wiring, :12436 markup (ONE occurrence)
```

`loadSite`'s guard (`:12105-12112`) paints `siteLoadFailureHtml(sr)` and `return`s before
`siteDetailHtml` (`:12136`), and `id="site-delete"` occurs exactly once, inside `siteDetailHtml`.
Any degraded site read hides the whole destroy tier.

## R6 — the INVERTED PIN a broader fix would red

```
sed -n '20288,20295p' cloud/priv/static/__app.test.mjs
```

`assert.equal(hooks.siteLoadFailureHtml(empty), W66_S3_NOT_FOUND_CARD, "a 200 with no site in it is an absence, not a failure")`
— cch-w66-s3 ratified the malformed-2xx-is-an-absence reading for the site CARD. Scope any
wave-68 fix to `recheckSiteDeleted` (zero pins) or carry a D-ruling that flips this line.

## R7 — the harness primitive for a losable test already exists

```
grep -n 'function proxyFaultFetch' -A 14 cloud/priv/static/__app.test.mjs   # :16734
grep -n 'function siteDeleteRealm' cloud/priv/static/__app.test.mjs          # :20589
grep -n 'async function driveSiteDelete' cloud/priv/static/__app.test.mjs   # :20610
cd cloud/priv/static && node --test __app.test.mjs | tail -6                # 1058/1058 pass, 0 fail
node --check cloud/priv/static/app.js                                       # exit 0
```

`proxyFaultFetch(200, "text/html", …)` + the existing `siteDeleteRealm` is the whole fixture;
no new primitive.
