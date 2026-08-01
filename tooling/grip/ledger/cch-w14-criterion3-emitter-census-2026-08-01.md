# cch-w14 criterion 3 — .status-pill emitter census (re-derivation recipe)

Verifier phase, Cloud Console Hardening wave 18. Read-only measurement against
UNTOUCHED `origin/main` bytes (b266a1a5e89fd69919e69ad07b0112964fbe95e1).

## 1. Enumerate the emitters

    git show origin/main:cloud/priv/static/app.js | grep -n 'class="status-pill'

Six distinct emitters: `statusPill()` :4585 (shared, 4 call sites — :4699 fleet
row, :4968 attention row, :5049 overview instance card, :5625 instance-detail
head), overview-ok :5271, update-badge :6670, `operatorPillHtml` :6970
(2 call sites — `.op-gate` :7002, `.set-row-side` :7016), `siteBindingPill`
:7535 (rail :9791 + chip :7540), webhook Active/Disabled :7644,
`siteStatusPill` :9488.

## 2. Confirm the merged remedy's scope

    git show origin/main:cloud/priv/static/app.css | grep -n 'status-pill'

Only `.detail-rail .status-pill*` (:5310-5320) and `.fleet-status .status-pill*`
(:5332-5341) are wrapper-scoped. Every other emitter rides base
`.status-pill { height: 24px; white-space: nowrap }` (:2923-2937).

## 3. Reproduce the census

    D=$(mktemp -d) && git -C <repo> archive origin/main cloud | tar -x -C $D && cd $D
    export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    OVERFLOW_GUARD_PORT=4384 node cloud/priv/static/__preview__/overflow-guard.mjs --defect W13-detail-route-band

Then the standalone probe (scratchpad, not committed): spawn
`cloud/priv/static/__preview__/serve.mjs`, drive Chrome over CDP, navigate to
`http://127.0.0.1:<port>/?scen=<scen>&theme=<light|dark><#hash>`, and for every
`document.querySelectorAll('.status-pill')` record parent className, computed
`white-space`/`height`, and `scrollWidth/clientWidth` + `scrollHeight/clientHeight`
on the pill AND on each `.status-pill-label` / `.status-pill-detail`.

Routes: `mixed-fleet#overview`, `fleet-usage#overview`, `shell-root#overview`,
`mixed-fleet#fleet`, `sites#sites`, `sites-on-instance#instance/<INST>`,
`webhooks-panel#instance/<INST>/webhooks`, `panel-overview#instance/<INST>`,
`panel-overview#instance/<INST>/settings`, `env-editor#site/<SITE>`,
`operator-console|operator-halted|operator-zero-staging#operator`,
`site-binding-bound|-unknown|-mismatch` and `site-states` at their own
`SCENARIOS[k].deepLink` site hashes (`…cb`, `…cc`, `…cd`, `…c1`).

## 4. Results to expect

- At 900/1024/1440, both themes: **0 red**, 9 wrapper families, 192+ pill
  measurements. Criterion 3's literal band is CLEAN.
- Below 900 the same census reds in exactly TWO wrappers, both on `#overview`:
  `.instance-card-head` and `.attention-row`.
- `operator-visible` renders ZERO `.status-pill` — use `operator-console`
  (and `operator-halted` / `operator-zero-staging`) to reach `operatorPillHtml`.
- `sites-on-instance` renders ZERO `.status-pill` inside `.site-row`
  (`siteBindingChip` returns "" for all six fixture rows).

## 5. Gotchas that cost time here

- Passing an empty hash does NOT fall back to the scenario `deepLink` — pass the
  hash explicitly.
- `boundSite` / `unknownBindingSite` / `mismatchedBindingSite` are **not
  exported** from scenarios.mjs (exports: `IDS`, `SCENARIOS`, `SCENARIO_NAMES`,
  `DEFAULT_SCENARIO`, `route`). A per-route site id in `BAND_ROUTES` must come
  from `SCENARIOS[<name>].deepLink` or from three literal UUIDs, not `boundSite.id`.
- overflow-guard.mjs imports nothing from scenarios.mjs; its `INST`/`SITE` are
  hardcoded literals at :251-252.
