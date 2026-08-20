# Re-derivation recipe — cch w54 verify [quota-reason-second-promise]

Ground: origin/main @ `5b68852f46b75047908c1947280af1bf3f72e529` (2026-08-08).
Fresh tree (never the primary checkout):

```sh
SP=$(mktemp -d) && git archive 5b68852f4 | tar -x -C $SP && cd $SP
node cloud/priv/static/__app.test.mjs   # baseline: 1013 pass / 0 fail
```

## R1 — the quota producer gets the billing promise verbatim

Harness `qh.mjs` (node:vm over the shipped IIFE, same sandbox as
`__app.test.mjs`), driving the real helpers with an **active, fully paid**
subscription and `suspended_reason: "quota_exceeded"`:

```js
const QUOTA = { id:7, name:"acme-quota", host:"1.2.3.4",
                suspended:true, suspended_reason:"quota_exceeded" };
const SUB_ACTIVE = { plan:"supporter", status:"active",
                     current_period_end:"2026-09-01T00:00:00Z" };
hooks.lifecyclePillState(QUOTA)                      // → "stopped"
hooks.overviewInstancesHtml([QUOTA], null, SUB_ACTIVE)
```

Renders, verbatim:

```
<div class="suspended-card-title">Suspended September 1 — payment failed</div>
<p class="suspended-card-body">The server is stopped, not destroyed. Everything comes back exactly as it was the moment payment succeeds.</p>
```

Three lies in one card on a team that owes nothing: "payment failed",
"payment succeeds", and "September 1" (a FUTURE renewal date rendered as the
past-tense suspension day — `suspended_at` is never serialized;
`router.ex:9116-9117` sends `suspended` + `suspended_reason` only, so
`dunningDates(sub)` substitutes `current_period_end`).

Mechanism: `suspendedCardBannerHtml(sub)` (app.js:6429) takes ONLY the
subscription; the gate at app.js:6299 is `opts.sub && bp.suspended` — reason-
blind and status-blind. Producer: `Billing.reconcile_plan_limit/1`
(billing.ex:285-321, reason `quota_exceeded`) fires on plan DOWNGRADE/overflow,
never on a payment event.

## R2 — which bytes are editable (the merged-pin question)

Arm A — delete/replace the sentence:

```sh
# in the fresh tree, swap the <p class="suspended-card-body"> text, then:
node cloud/priv/static/__app.test.mjs | grep -E '^not ok|^# (pass|fail)'
# not ok 743, not ok 747, not ok 1010  → 1010 pass / 3 fail
```

THREE merged pins, not one: `__app.test.mjs:12779` (743),
`__app.test.mjs:12830` (747), `__app.test.mjs:19026` inside cch-w50-s3 (1010).

Arm B — keep the bytes, make the banner reason-aware
(`suspendedCardBannerHtml(sub, bp)` + `quota_exceeded` early-return; call site
app.js:6299 passes `bp`):

```sh
node cloud/priv/static/__app.test.mjs | grep -E '^# (pass|fail)'
# 1013 pass / 0 fail
```

All three pins exercise `status:"past_due"` boxes with NO `suspended_reason`,
so the reason branch is invisible to them. **Arm B is the editable path.**

## R3 — the pin's own rationale refutes itself

`__app.test.mjs:19022-19026` keeps the sentence because past_due restore is
backed "with no plan change and so no ceiling to clip it" — reasoning about ONE
producer. The same file, 30 lines up, names the ceiling
(`Billing.reconcile_plan_limit/1`) that clips the OTHER producer. The pin's
justification is the argument against the sentence, applied to a producer the
pin never considered. Hence the register's key must be **(state, reason)**.

Bonus: `statusOf` (app.js:5779) leaks the raw snake_case `quota_exceeded` into
the user-facing pill detail — no `humanize` is applied
(`/humanize\([^)]*suspended_reason/` → false).
