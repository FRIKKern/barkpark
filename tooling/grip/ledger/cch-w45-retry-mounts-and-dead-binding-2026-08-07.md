# cch-w45 — retry mounts, the dead `#inst-retry` binding, and what the census actually counts

Re-derivation recipes. Every command below is literal and was run against `origin/main = b00d793c0`
on 2026-08-07. The local checkout was at `0789ab90a` (BEHIND main, and `__binding_census.mjs`
did not exist in the worktree) — so every reading is `git show origin/main:…`, never a worktree read.

## R1 — `#inst-retry` is DEAD: one reader, zero emitters, repo-wide

    git grep -n 'inst-retry' origin/main -- cloud/ | grep -v inst-remove-retry
    git grep -ln 'inst-retry' origin/main

Both return exactly one file / one line: `cloud/priv/static/app.js:6903  var retry = $("#inst-retry");`
No markup, no test, no fixture emits the id.

## R2 — it died by REGRESSION, not by never being written

    git log --oneline -S'inst-retry' origin/main -- cloud/
    git show 64f690663~1:cloud/priv/static/app.js | grep -n 'inst-retry'
    git show 64f690663 -- cloud/priv/static/app.js | grep -n 'inst-retry'
    git show -s --format='%ci %h %s' 637fea309 64f690663

Emitter + wire were born together in `637fea309` (2026-06-28). `64f690663` (2026-07-03, the
"provisioning timeline — one renderer, three mounts" migration) deleted ONLY the emitter line
(`- … id="inst-retry" … Retry</button>`) and left the wire orphaned. Dead for 35 days.

## R3 — every LIVE mount of `retryInstance`

    git show origin/main:cloud/priv/static/app.js | grep -n 'retryInstance'

    6904  DEAD  — wireInstanceActions, reads #inst-retry (no emitter, see R1)
    10522 LIVE  — verify card, [data-vf-reprovision], emitted at :10481 by
                  verifyNoteHtml("no_admin_token", bp)
    16610 LIVE  — provisioning timeline, [data-tl-retry], emitted at :16447 by
                  instanceTimelineHtml, gated on `failed = isProvisionFailed(bp)`

## R4 — the census counts CALL SITES, not affordances. Proof by mutation.

Run it out-of-tree against origin/main sources (the file takes argv paths):

    D=$(mktemp -d)
    git show origin/main:cloud/priv/static/__binding_census.mjs > $D/census.mjs
    git show origin/main:cloud/priv/static/app.js               > $D/app.js
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > $D/router.ex
    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex   > $D/accounts.ex
    git show origin/main:cloud/lib/barkpark_cloud/accounts/authz.ex > $D/authz.ex
    node $D/census.mjs $D/app.js $D/router.ex $D/accounts.ex $D/authz.ex; echo rc=$?

BASELINE: `79 call sites · 40 ELEVATED · 22 PREDICATED · 18 UNPREDICATED`, rc 0.

MUTATION A — predicate BOTH live retryInstance mounts (`if (rp && instanceAdminAuthority() === "grant")`
and the same on both `if (retry) …` wire lines), leave the PIN untouched:
census still prints `22 PREDICATED · 18 UNPREDICATED`, rc 0.

MUTATION B — delete the two dead `#inst-retry` lines entirely:
census still prints `22 PREDICATED · 18 UNPREDICATED`, rc 0, `OK: all 79 … match the 79-row pin`.

Both follow from the file's own LIMIT 1 ("`elevated` AND `predicate` ARE PINNED JUDGEMENTS,
NOT DERIVED") and from its key being `<enclosing fn>|<VERB> <route>`.

## R5 — the two `/retry` census rows are NOT two retry mounts

    grep -n "route: \"/v1/barkparks/:\\*/retry\"" cloud/priv/static/__binding_census.mjs

`retryInstance` (one row, one `api()` call in its body) and `newRenderFailed` (the /new flow's own
inline `api("POST", …/retry)` at app.js:17801, `#new-retry`). Two functions, one route, two rows.

## R6 — which gating states the committed preview corpus can actually render

    git grep -n 'deprovision_status' origin/main -- cloud/priv/static/__preview__
    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'autoupdate\|channel:'
    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | sed -n '65,105p'   # bpBase

`bpBase` has no `channel` / `autoupdate_enabled` / `autoupdate_paused` / `pinned_release`, so
`hasAutoupdatePolicy()` is FALSE for every instance-detail fixture → the four `data-au` buttons
render in ZERO scenarios. `deprovision_status` is `null` in every scenario → `lc.removeFailed`
is never true → `#inst-remove-retry` (removeInstance's ONLY mount) renders in ZERO scenarios.
`liveInstance.update_state === "current"` → `#inst-update` renders in ZERO instance-detail
scenarios (`behindInstance` is a fleet-list row).
