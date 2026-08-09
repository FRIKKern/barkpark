# loadSite paints "It may have been removed." for six distinct failure statuses — w66 verify

Baseline: `origin/main` = `45e26115527c875f50769eb7df922b0f97842be8` (2026-08-10).
Host was at ENOSPC (117Mi free on `/`); the `Bash` tool was unusable for the whole
phase — every call died writing its own `tasks/*.output`. All commands below were
executed through the `Monitor` tool, which streams stdout instead. Scratch lives on
`/Volumes/SATECHI/tmp-w66/` because `/private/tmp` had no space.

## Re-derivation recipes

Extract the two baselines (never read the working tree — it is dirty for both files):

    cd /Volumes/SATECHI/github/barkpark
    mkdir -p /Volumes/SATECHI/tmp-w66
    git show origin/main:cloud/priv/static/app.js        > /Volumes/SATECHI/tmp-w66/app_origin.js
    git show origin/main:cloud/priv/static/__app.test.mjs > /Volumes/SATECHI/tmp-w66/t.mjs
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
        > /Volumes/SATECHI/tmp-w66/charter.md

`app_origin.js` is 23339 lines; `charter.md` is 8189.

### The defect predicate

    sed -n '12037,12056p' /Volumes/SATECHI/tmp-w66/app_origin.js

`loadSite` line 12051 is `if (sr.status === 404 || !sr.ok || !sr.data || !sr.data.site)`.
`!sr.ok` swallows every non-2xx AND `api()`'s `status: 0` transport envelope.

### Both-arms run proof (drives the shipped bytes, not a reimplementation)

`/Volumes/SATECHI/tmp-w66/drive.mjs` slices lines 12037..12107 verbatim out of
`app_origin.js`, guards that the slice really starts `function loadSite(id, opts)`
and really contains the copy (exit 2 otherwise — the guard can lose), then `new
Function(...)`s it against stubbed `api`/`$`/`ensureFleet` and reads back what was
assigned to `box.innerHTML`.

    node /Volumes/SATECHI/tmp-w66/drive.mjs

Six failure statuses — 0, 403, 404, 500, 502, 504 — return the byte-identical
`<h2>Site not found</h2><p>It may have been removed. …</p>`.

### Coverage census (absence is the finding)

    grep -c 'Site not found' /Volumes/SATECHI/tmp-w66/t.mjs        # 0
    grep -in 'may have been removed' /Volumes/SATECHI/tmp-w66/charter.md   # no output

Zero committed assertions on the sentence; zero D-rulings on it. A fail-before is
free and cannot be vacuous.

### The blast-radius answer

    grep -n 'friendly\|faultCopy\|data\.detail' /Volumes/SATECHI/tmp-w66/charter.md

Eleven D-rows already rule on `friendly()` (D353 D395 D404 D406 D412 D415 D416 D417
D418 D419 D740). D395 kills the spray; D740 files the one-line unwrap as NOT-this-wave
because it moves behaviour under ~55 delegating call sites (73 real calls; the raw
grep of 115 is 41 comment mentions). The status-first helper the fix needs already
exists on main:

    sed -n '421,428p;471,496p' /Volumes/SATECHI/tmp-w66/app_origin.js

`faultCopy(status, data, fallback, transport)` at :421, `faultDetail(text)` at :471,
and `fleetLoadErrorHtml(fault)` at :489 — a shipped precedent for this exact screen.

### Comparator (teardown) re-check

    grep -c 'api("DELETE"' /Volumes/SATECHI/tmp-w66/app_origin.js         # 14
    grep -n  'api("DELETE"' /Volumes/SATECHI/tmp-w66/app_origin.js        # only /v1/sites hit is :13778 …/github
    grep -c 'teardown_failed' /Volumes/SATECHI/tmp-w66/app_origin.js      # 0

Confirmed: no console caller for `DELETE /v1/sites/:id`.

### What the digest got wrong

    sed -n '11797,11812p' /Volumes/SATECHI/tmp-w66/app_origin.js

`loadSiteDomains` does NOT leave the checklist blank by omission — on `!r.ok` it
calls `restoreDomainRecheck(b)` and returns, under a comment that states the
leave-as-it-stands rule on purpose. It is the honest arm, not a defect.
