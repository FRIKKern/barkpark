# CCH wave 13 — drivability census (re-derivation recipes)

Verifier lane `drivability-census`. Question: does the missing successful-login
fixture (`cch-w12-followup-login-fixture-gap`) block proof-by-driving for
movement one? **Answer: NO.** The gap is scoped to the logged-out → logged-in
IDENTITY TRANSITION only. 93 of 99 scenarios carry `authed: true`; mock.js seeds
`bpcloud.session` synchronously before app.js boots, so every authenticated
console surface mounts.

All commands assume an origin/main export (the working checkout is 201 commits
behind origin/main as of 2026-07-31 — do NOT measure in it):

```sh
D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C "$D"
S="$D/cloud/priv/static"
```

## R1 — smoke, all 99 scenarios boot the real app.js

```sh
cd "$S" && node __preview__/smoke.mjs; echo "exit=$?"
# → "all 99 scenarios rendered", exit=0
```

## R2 — the deepLink census (run on a NON-DEFAULT port; 4180 collides with
## other concurrent wave agents and the run dies mid-flight)

```sh
cd "$S" && PORT=4188 bash __preview__/shoot.sh
# → ">> Census (derived from scenarios.mjs): 85 of 99 scenarios carry a deepLink"
```

The 14 without a deepLink are NOT undrivable — they mount by pathname/search or
by a click, and shoot.sh already shoots all of them:
* 4 × `/new` (`new-launch`, `theater-midflight`, `theater-failed`, `theater-ready`)
* 5 × `/activate` (`activate-entry|confirm|gone|rate-limited|logged-out`)
* 5 × `account-modal*` (opened via `&modal=account`, shoot.sh:270)

## R3 — scenario → deepLink/pathname/search table

```sh
cd "$S/__preview__" && node -e 'import("./scenarios.mjs").then(m=>{for(const [k,v] of Object.entries(m.SCENARIOS)) console.log([k,v.deepLink||"-",v.pathname||"-",v.search||"-"].join(" | "))})'
```

## R4 — drive the minute (real Chrome, computed style + DOM)

```sh
node "$S/__preview__/serve.mjs" --port 4187 &
# rail, mid-flight:
#   http://localhost:4187/new?scen=theater-midflight&theme=light&template=astro-blog&bp=5b2c1e00-0000-4000-8000-0000000000e1
# failure copy, verbatim:
#   http://localhost:4187/new?scen=theater-failed&theme=light&template=astro-blog&bp=5b2c1e00-0000-4000-8000-0000000000e2
# provider rotate form + wire:
#   http://localhost:4187/?scen=providers-connected&theme=light#settings/providers
# deploy status pills:
#   http://localhost:4187/?scen=site-states&theme=light#site/5b2c1e00-0000-4000-8000-0000000000c1
```

NOTE: the scenario's own `search` must be appended by hand — mock.js reads only
`?scen=`, while app.js's `/new` flow reads `?template=` and `&bp=`. Without them
`/new` renders the template picker, not the theater.

Measured on origin/main, 2026-07-31:
* theater-midflight: 31 `.new-step*` nodes; `.prov-overall-track[role=progressbar]`
  `aria-valuenow=78`; body text "Step 3 of 5 · about 26s left" — the numeric
  promise only the CONSTANT-paced rail makes.
* theater-failed: `.new-fail-copy` carries `provision_error` verbatim.
* providers-connected: `GET /v1/providers` → 200, body carries
  `{id,kind,label,team_id,inserted_at}` and NO identity field.
* site-states: `.dep-pill.dep-cancelled` computes
  `background rgb(236,238,242) / color rgb(61,72,89)` — byte-identical to
  `.dep-queued`, because `.dep-queued { color: var(--muted-text); }` (app.css:1641)
  is the `.dep-pill` base and no `.dep-cancelled` rule exists at all.

## R5 — the 231px tablet content cliff, driven

Resize a real page and read `.content` clientWidth:
* innerWidth 720 → `.content` 720 (folded, `.app-shell` max-width:720 app.css:4241)
* innerWidth 721 → `.content` 489, `.sidebar` 231

Reproduced independently on `#settings/providers`, one of the seven screens
`gr-backlog-tablet-width-audit` says has never been rendered at tablet width.

## R6 — the login gap, at its source

```sh
grep -n "auth/login" "$S/__preview__/scenarios.mjs"      # :3105  d.login only
grep -n "two_factor_required" "$S/__preview__/scenarios.mjs"  # :1962, the SOLE fixture
```

`cch-w12-followup-login-fixture-gap` is parented to `cch-instruments-epic`, not
to the console epic.
