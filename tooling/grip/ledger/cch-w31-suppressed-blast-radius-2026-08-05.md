# cch-w31 — re-derivation recipe: the FULL edit set for one `suppressed` delivery status

Verified against `origin/main` @ `467f7e2837b0690d45a2c8a573e7242b6d720833` on 2026-08-05.
All runs were done on an ISOLATED `git archive origin/main` extraction (the primary checkout is
434 commits BEHIND origin/main — running the suite in the checkout gives 720 tests, not 826).

## Set up the origin/main sandbox (mandatory — do not trust the checkout)

```sh
S=$(mktemp -d) && git archive origin/main cloud deploy internal/taskboard/testdata internal/pdrender/testdata scripts | tar -x -C "$S"
cd "$S/cloud/priv/static" && node --test __app.test.mjs 2>&1 | tail -5     # 826 pass / 0 fail
node __css_check.mjs; echo $?                                              # 0 errors
node __preview__/smoke.mjs 2>&1 | tail -2                                  # all 102 scenarios rendered
node __preview__/cssom-parity.mjs 2>&1 | tail -4                           # PARITY PASS, 1289 = baseline 1289
```

## 1 — `status` is a PLAIN STRING column. No migration.

```sh
git show origin/main:cloud/priv/repo/migrations/20260629120300_create_notification_deliveries.exs | sed -n '20,26p'
#   add :status, :string, null: false, default: "pending"
git grep -n 'notification_deliveries' origin/main -- cloud/priv/repo/migrations/   # 3 migrations, no CHECK, no CREATE TYPE
```

Only enforcement is `validate_inclusion(:status, @statuses)` in
`cloud/lib/barkpark_cloud/notifications/delivery.ex:19` (`~w(pending sent failed)`).
`Delivery.statuses/0` is dead code — no caller in `cloud/lib` or `cloud/test`
(contrast `Deployment.statuses()`, byte-pinned at `cloud/test/.../deployment_test.exs:54`).
Server read path needs NOTHING else: `delivery_json/1` (`cloud/lib/barkpark_cloud/web/router.ex:8810-8823`)
passes `status` verbatim, and the `?status=` filter is a free equality match
(`notifications.ex:583` `maybe_delivery_eq`) — no whitelist to widen.

## 2 — A `suppressed` row TODAY renders "Pending" in a blue pill (server-only ship = a NEW lie)

```sh
node <probe.mjs> app.js   # vm-loads app.js with the __app.test.mjs sandbox, calls the hooks
# TONE  = info
# LABEL = Pending
# ROW   = …<span class="wh-del-status wh-del-status--info">Pending</span>…
```

## 3 — The console edit set (all four are REQUIRED; none is guarded)

| file | line (origin/main) | why |
|---|---|---|
| `cloud/lib/barkpark_cloud/notifications/delivery.ex` | 19 | `@statuses` |
| `cloud/priv/static/app.js` | 2860 `notifDeliveryTone` | else-branch → `info` |
| `cloud/priv/static/app.js` | 2876 `notifDeliveryStatusLabel` | else-branch → `Pending` |
| `cloud/priv/static/app.js` | 3083-3088 `NOTIF_DELIVERY_STATUSES` | filter chip row (NOT a test hook; reached via `notifDeliveryFiltersHtml`) |
| `cloud/priv/static/app.css` | 4119-4121 | only `--ok / --danger / --info` tones exist |
| `cloud/priv/static/__preview__/cssom-heads.baseline` | last line `1289` | EXACT-count ratchet; a new CSS rule reds cssom-parity until bumped to 1290 |
| `cloud/priv/static/__preview__/scenarios.mjs` | 1677-1684 | fixture comment says `status ∈ pending|sent|failed`; no suppressed row exists |

NOT required: `cloud/priv/static/styleguide.html` and `index.html` never name `wh-del-status`
(the family has no swatch at all); `docs/openapi.json` carries no cloud notification schema;
`__app.test.mjs:12106-12117` hook-name loop only changes if a NEW builder function is exported.

## 4 — THREE GUARDS THAT CANNOT LOSE (mutation-proved)

**(a) `__css_check.mjs` cannot see a missing tone rule.** `wh-del-status wh-del-status--` is an
`ALLOW_PREFIXES` entry (`__css_check.mjs:276`), which waives the WHOLE dynamic head. There is a
value-space list only for `dep-` (`DEPLOY_STATUSES`, `__css_check.mjs:351`, added after `cancelled`
shipped ruleless). Proof — emit an unstyled tone and run all three console checks:

```sh
perl -0pi -e 's/(    if \(s === "failed"\) return "danger";\n)(    return "info";)/$1    if (s === "suppressed") return "suppressed";\n$2/' app.js
node __css_check.mjs | tail -1   # "865 classes checked … 0 error(s)"  → exit 0
node --test __app.test.mjs | tail -4   # 826 pass / 0 fail
node __preview__/smoke.mjs | tail -1   # all 102 scenarios rendered
```

**(b) `cssom-parity` DOES lose on the CSS rule — bump the sidecar in the same commit.**

```sh
perl -0pi -e 's/(\.wh-del-status--info \{[^\n]*\n)/$1.wh-del-status--suppressed { … }\n/' app.css
node __preview__/cssom-parity.mjs; echo $?
# "PARITY FAIL — baseline mismatch with 0 misses" … "Bump the sidecar to 1290 IN THE SAME COMMIT" … exit 1
```

**(c) The fixture row changes nothing on its own.** Adding a `status:"suppressed"` row to
`notifDeliveries` (scenarios.mjs:1678) leaves smoke (102 scenarios), overflow-guard (exit 0) and
breakpoint-sweep (0 fail) green — smoke's notif block asserts `wh-del-status--danger` / `Failed` /
`204 OK` only (`__preview__/smoke.mjs:2138-2143`). The gate reaches the new pill ONLY if a smoke
assertion is added beside those.

## 5 — Contrast: reuse an already-checked token pair

`CONTRAST_PAIRS` (`__css_check.mjs:428`) is a hand list of TOKEN pairs. `--warn-strong` on
`--warn-soft` over `--surface` is already an entry (`.dep-building`); a bare `--warn` foreground on
`--warn-soft` has NO entry and would ship unmeasured.

## 6 — `__app.test.mjs` region contention with the boundary slice

Centrepiece home: 12264-12700 (G-04 notif). Boundary slice (cch-w30-s5 crash envelope) home:
13488-13584 (file tail; file is 13584 lines). They do NOT overlap. The single real collision point
is the `scaffy:zone console-tests` HEAD anchor at `__app.test.mjs:83-89`, which instructs BOTH
slices to append new test groups at the same place.
