# cch-w54-s5 anchor re-derivation — wave 57 verify (V5)

Baseline: `origin/main` @ `0239dd4ee662dd30c4d8da0c6b9a149638224b1d` (2026-08-09).
Every number below is re-derived; the row's brief carries THREE generations of
stale anchors (original brief, wave-56 correction @ b97663730, and now this).

## Re-derivation recipes

    cd /Volumes/SATECHI/github/barkpark

    # AFTER-GATE (criterion 1)
    git merge-base --is-ancestor 8317b8ce6 origin/main && echo AFTER_GATE_MET

    # app.js anchors
    git show origin/main:cloud/priv/static/app.js | grep -n \
      'function overviewDunningBannerHtml\|function dunningBannerHtml\|function dunningDates\|function billingPeriodLine\|DUNNING_GRACE_DAYS\|function fmtDay'
    git show origin/main:cloud/priv/static/app.js | grep -n 'dunningDates(\|fmtDay('
    git show origin/main:cloud/priv/static/app.js | grep -n \
      'Grace period ends\|function readOnlyPlanCardHtml\|function currentPlanCardHtml\|renderBillingCancel'

    # harness pins
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -n \
      'keep running until .+\|Your payment failed on .+\|Your card was declined on .+'
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -n \
      'Grace period ends\|dunningDates\|readOnlyPlanCardHtml'
    git show origin/main:cloud/priv/static/__preview__/smoke.mjs | grep -n \
      'billing-past-due\|overview-past-due'

    # billing.ex prose + mechanism
    git show origin/main:cloud/lib/barkpark_cloud/billing.ex | grep -n \
      'Oban substrate\|before its managed boxes are suspended\|default_grace_anchor\|put_new_lazy\|maybe_enforce\|@grace_days'
    git show origin/main:cloud/test/barkpark_cloud/billing_lifecycle_test.exs | grep -n \
      'billing_past_due\|current_period_end'

    # what entitlement actually gates (the honest replacement sentence)
    git grep -n 'entitled?' origin/main -- cloud/lib

    # the browser job's rendered cell (NOT a past-due cell)
    git show origin/main:.github/workflows/console-harness.yml | sed -n '761,772p'

## Corrected anchor table (brief value -> origin/main 0239dd4ee)

| anchor | brief (w56 correction) | origin/main | delta |
|---|---|---|---|
| `overviewDunningBannerHtml` | :6442 | **:6480** | +38 |
| its two date slots | — | **:6482, :6484** | new |
| `suspendedCardBannerHtml` dunningDates/fmtDay (OUT OF FENCE) | — | **:6527, :6528** | new |
| `dunningBannerHtml` | :14762-14766 | **:14837-14841** | +75 |
| `dunningDates` | :14743-14747 | **:14823-14826** | +80 |
| `DUNNING_GRACE_DAYS` | — | **:14822** | — |
| `fmtDay` | — | **:14828-14831** | — |
| `billingPeriodLine` | :14720-14722 | **:14786-14800**, past-due arm **:14794** | +74 |
| `currentPlanCardHtml` (owner twin) | :14779 | **:14853**, periodLine :14854 | +74 |
| `readOnlyPlanCardHtml` (non-owner twin) | :14530 | **:14593**, periodLine :14605 | +63 |
| w50-s3 cancel blurb fence line | :14526 | **:14661** (`renderBillingCancel` set-purpose) + **:14680** (modal sub) | pointer drifted TWICE |
| `__app.test.mjs` billingPeriodLine past-due pin | :3825/:3827 | test **:3828**, assertion **:3830** | +3 |
| `__app.test.mjs` dunningDates test | :12456 | **:12459-12468** | +3 |
| `__app.test.mjs` loose `.+` pin (billing banner) | :12469 | **:12472** | +3 |
| `__app.test.mjs` loose `.+` pin (overview banner) | :12866 | **:12873** | +7 |
| `__app.test.mjs` readOnlyPlanCardHtml test | — | **:14220-14260** (no past_due fixture) | new |
| `smoke.mjs` billing-past-due | :1365/:1366 | scenario **:1359**, date asserts **:1364-:1365** | -1 |
| `smoke.mjs` overview-past-due | :1533 | scenario **:1529**, lead assert **:1533** | ok |
| `billing.ex` Oban-substrate claim | :38-39 | **:39** (single line) | -1 |
| `billing.ex` "before its managed boxes are suspended" | :56-59 | **:57-58** | -1 |
| `billing.ex` mark_past_due @doc | :805-811 + :819-820 | **:804-812** + comment **:813-823** | shifted |
| `put_new_lazy` re-anchor | :829 | **:827** | -2 |
| `default_grace_anchor/0` | :774-776 | **:837-839** | +63 |
| `maybe_enforce/1` | :878-887 | **:883-892**, suspend at **:887** | +5 |
| `entitled?/1` | :1251 | **:1251** | ok |
| `application.ex` Oban supervision | :25 | **:25** | ok |
| `use Oban.Worker` under cloud/lib | 18 across 17 files | **17 files, 17 occurrences** | count corrected |

## Findings the table does not carry

* **Criterion 16's premise is FALSE on main.** Retracting the row's four in-fence
  date slots does NOT orphan `dunningDates` / `fmtDay` / `DUNNING_GRACE_DAYS`:
  `suspendedCardBannerHtml` (out of fence per D644) calls both at :6527/:6528.
  The deletion arm of criterion 16 would break a merged wave-54 surface.
* **Criterion 5's "two" undercounts.** Six call sites construct the unreachable
  `%{current_period_end: past}` attrs shape in `billing_lifecycle_test.exs`
  (:97, :135, :187, :256, :456, and the :483 test), not two.
* **Criterion 17's browser risk is overstated.** `console-harness.yml:770`
  renders `--cell billing-trial` at 901px — a trial sub, which renders no
  dunning banner and no past-due period line. No in-fence string reaches it.
* **The honest replacement sentence is derivable, not a taste call.**
  `Billing.entitled?/1` has exactly ONE lib call site outside billing.ex:
  `router.ex:8744` `entitled_or_trial_started?/1`, the go-live gate. Grace
  elapse therefore withholds NEW instance launches and nothing else — no stop,
  no delete, no bill change. That is D653's ISOLATION, measured.
