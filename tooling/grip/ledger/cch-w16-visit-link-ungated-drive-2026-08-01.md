# Re-derivation recipe — `cch-w15-bl-visit-link-ungated-on-deployment-state` on post-#8743 bytes

Written 2026-08-01 by the wave-16 verifier `v-visit-link-post-8743`. Every claim below was
DRIVEN in headless Chrome or in the `node:vm` hook harness against `origin/main` bytes
(`c48fb17d5`), never read off app.js.

## 0. export the tree (use the FULL archive, not a path-scoped one)

    d=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C $d; cd $d
    node --test cloud/priv/static/__app.test.mjs 2>&1 | tail -5    # 757/757 pass, fail 0

TRAP: `git archive origin/main cloud/priv/static` (the path-scoped form) makes the suite report
`# fail 2` — both are `ENOENT .../internal/taskboard/testdata/styleguide_lifecycle.txt` from the
two `coherence:` tests. That is an artefact of the partial export, not a red on main.

## 1. the three (four-anchor) call sites

    git show origin/main:cloud/priv/static/app.js | grep -n 'siteOpenLink\|siteLiveUrl'

    7285  function siteOpenLink(url)          — the shared helper, gated ONLY on a URL string
    7534  siteRow            (instance workspace list)   — 1 anchor
    9497  globalSiteRow      (global #sites list)        — 1 anchor
    9713-9723  siteDetailHtml (site DETAIL head)         — 2 anchors: `.fleet-url` liveLine + `.fleet-badges` Visit

Charter D182 and the task body name only 7534/9497. The DETAIL head is unnamed in both.

## 2. drive the list (real Chrome, real CSS)

    cd $d/cloud/priv/static && node __preview__/serve.mjs --port 4180 &
    # then a CDP probe over `?scen=sites&theme=light#sites`, reading per `.site-row`:
    #   .status-pill-label text, .fleet-badges rect, .site-open tag/text/title/href

Measured at 1280 / 900 / 390 / 320, light and dark — identical:

    acme-labs   pill="Not deployed"   open=<A> "Visit ↗" w=49  title="Open the live site"
                href="production-5b2c1e.barkpark.cloud/sites/acme-labs/"

All five states (Live / Rebuilding / Deploy failed / Not deployed / Cancelled) carry the same
anchor with the same `title`.

## 3. the detail head, on a never-deployed site

    ?scen=sites&theme=light#site/5b2c1e00-0000-4000-8000-0000000000c6   (acme-labs)

    detail-head status chip: (NO STATUS CHIP)
    <A class=site-open> in .fleet-url     "…/sites/acme-labs/ ↗"  w=379.23
    <A class=site-open> in .fleet-badges  "Visit ↗"               w=51.75

`siteStatusChip` (app.js:9656) emits "" unless a deployment is active or `current_deployment_id`
resolves to a `status:"live"` row — so the detail is WORSE than the list: it offers to open the
site and says nothing at all about deployment state.

## 4. remedy shapes, measured by mutation (patch `globalSiteRow`'s `siteOpenLink(...)` call)

| variant | predicate | `.fleet-badges` width @1280 (live / not-deployed) | anatomy |
|---|---|---|---|
| base | url exists | 179.92 / 150.19 | — |
| gated | `last_deployment.status === "live"` | 179.92 / 93.19 | badge band shifts −57px on 4 of 5 states |
| inert | live → anchor, else inert `<span class="site-open is-inert">` | 179.92 / 150.19 | byte-identical to base at 1280 and 390 |
| curdep | `current_deployment_id` | 122.92 / 93.19 | **hides Visit on the LIVE row too** |

`rowH` is 92 @1280 and 166 @390 in every variant.

## 5. the fixture trap (worse than filed)

    grep -n 'current_deployment_id' cloud/priv/static/__preview__/scenarios.mjs
    242:      current_deployment_id: null,     # the site() factory default

No row in `sitesListRows` (scenarios.mjs:330-374) overrides it. A `current_deployment_id` gate
therefore removes the Visit affordance from ALL FIVE list rows — including `acme-web`, whose pill
reads **Live** — and the corpus cannot tell that gate apart from deleting the link outright.
The list's only deployment fact is `last_deployment.status`; the detail's is
`current_deployment_id` resolved against the fetched deployment list.
