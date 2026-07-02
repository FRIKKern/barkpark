<!-- doc-tier: human | canonical-for: swarm-dwb-11-failure-matrix | budget: 2600tok -->
# dwb-11 — button-chain failure/idempotency matrix

Every cell is one of **PROVEN** (existing/new test named), **FIXED** (this branch), or
**ACCEPTED** (risk justified). Columns: double-submit · crash mid-step · instance/provider 5xx ·
control-plane restart. Money column noted where it differs.

## 1. Register (POST /v1/auth/register)

- Double-submit: PROVEN — citext unique on users.email → loser 409; whole signup
  (user+team+membership+trial+settings+token) is ONE transaction (`router_test.exs` register suite).
- Crash mid-step: PROVEN — same transaction; nothing half-lands.
- Money: no charge exists at signup (trial is gateway-free).

## 2. Launch (POST /v1/launch | /v1/go-live)

- Double-click, same name, paid team w/ quota headroom: PROVEN —
  `barkparks_team_slug_unique_idx` is the launch idempotency key → second submit 422, one row,
  one job (`router_test.exs "dwb-11: rapid double-submit of the SAME launch creates ONE box"`).
  Different-name double-launch is two INTENTS (quota-gated), not a duplicate — by design.
- Clean-URL race (two teams, same clean slug): PROVEN — `barkparks_url_unique_idx` decides;
  loser falls back to suffixed FQDN (`register_managed_barkpark`, registry tests).
- Quota race past the cond check: PROVEN — `register_barkpark` context guard → 403, never 500
  (`go_live_limit_test.exs`).
- Enqueue hiccup after row insert (201 stood, job insert failed): **FIXED** — this was a
  permanent dead end (`latest_provision_job` nil ≠ "failed" → Retry 409'd forever). Retry now
  also accepts a MANAGED, never-live (host nil), job-less row — the stranded-launch state —
  while self_hosted/byo rows and live boxes stay not_retryable. Tests
  `router_test.exs "dwb-11: stranded launch ... is retryable"`, `"self_hosted ... NOT retryable"`,
  `"LIVE managed box ... NOT retryable"`.

## 3. Trial entitlement (dwb-13 auto-start)

- Double-launch racing trial grant: PROVEN — `claim_trial_window` is one conditional UPDATE
  (`WHERE trial_started_at IS NULL`): exactly one winner ever
  (`billing_trial_test.exs "first launch grants + STAMPS"`, `"TORN-DOWN trial is NEVER re-granted"`).
- Trial auto-start racing checkout webhook: PROVEN/ACCEPTED —
  `subscriptions_one_live_per_team_idx` serializes the two inserts. Trial-wins → webhook (or its
  Stripe retry) UPGRADES the trial row in place (`"trial team's checkout UPGRADES the same live
  row"`); paid-wins → trial insert loses on the index, launch 402s once, next click is entitled.
  Residual: the ledger may be stamped for a team that never used the trial (forfeits a future
  free trial; never a charge). ACCEPTED — no money moves, self-corrects on the next request.
- Trial expiry teardown racing conversion: PROVEN — worker filters `plan == "trial"` only, and
  conversion cancels pending deprovisions (`trial_expiry_worker_test.exs "CONVERTED team's box is
  never torn down"`, `"conversion cancels any pending trial-deprovision job"`).

## 4. Provision queue (claim / succeed / fail)

- Concurrent worker claims: PROVEN — FOR UPDATE SKIP LOCKED
  (`provisioning_test.exs "race-safe: N concurrent claimers"`).
- Duplicate succeed (dropped response): PROVEN — idempotent 200, no re-upsert
  (`"IDEMPOTENT: a re-succeed ... NO double work"`).
- Succeed vs failed job / fail vs succeeded job: PROVEN — status-guarded 409 both directions;
  a straggler fail never un-suceeds a live box (`succeed_job`/`fail_job` suites).
- Split-brain succeed (job flips, barkpark upsert fails): PROVEN — one transaction, both or
  neither (`succeed_job` rollback test).
- Control-plane restart / worker crash mid-claim: PROVEN — stale-claim re-pend by lazy claim
  AND per-minute reaper, shared threshold + attempts cap
  (`stale_provision_job_reaper_test.exs`, claim_loop tests).
- **Retry double-click: FIXED** — route was gated on latest-job-failed only (check-then-insert →
  two pending jobs → TWO BILLED BOXES from one intent). Now: app-level active-job check +
  `provision_jobs_one_active_per_barkpark_kind_idx` (partial unique, pending|claimed, per kind) →
  loser gets 409 `already_provisioning`. Migration `20260702120000`; tests
  `provisioning_test.exs "one-active-job-per-barkpark idempotency (dwb-11)"` (index-level, bypassing
  the app check) + `router_test.exs "Retry that RACES an already-open provision"`.
  Terminal jobs stay outside the index → legitimate retry-after-failure PROVEN
  (`"legitimate retry AFTER a failure still enqueues"`).
- Retry on succeeded/mid-provision job: PROVEN — 409 `not_retryable` (`router_test.exs`).

## 5. Box create/bootstrap on the worker (Go)

- Any in-chain failure after create (dns/caddy/migrate/admin-token/health, incl. bootstrap):
  PROVEN — teardown-on-fail, zero orphans (`provision_test.go TestProvisionWithCleansUpOn*`,
  `bootstrap_wiring_test.go TestProvisionWithBootstrapFailureTearsDown`).
- Succeed-report fails (live box, control plane never told): PROVEN — retries then teardown;
  4xx = control plane gave up = teardown (`worker_test.go TestRunOnceSucceedReport*`).
- Delete itself fails (double failure): PROVEN — `barkpark-orphaned=true` label + startup/periodic
  `SweepOrphans` (`TestSweepWith_DeletesOnlyOrphans`, `warmpool_test.go` cleanup tests).
- **Worker CRASHES hard mid-provision (no teardown runs): FIXED** — the half-built box was
  unreachable by every recovery path (not orphan-labeled; DeprovisionByIP needs an IP the control
  plane never learned) → billed forever. Now the re-claimed attempt reaps it:
  `WarmPool.reapLeakedPredecessors` deletes any OTHER managed box carrying this fqdn label right
  after the new box is labeled (safe: fqdn is the globally-unique instance identity, freed only
  after a completed deprovision; the stale threshold guarantees the prior worker is dead).
  Delete-failure falls back to orphan-marking. Tests
  `warmpool_test.go TestProvisionOneShot_ReapsLeakedPredecessor`,
  `TestReapLeakedPredecessors_DeleteFailureMarksOrphaned`.
- Reaper re-run vs half-provisioned box (`PriorReadToken`/`PriorWebhookSecret`, #759): SETTLED —
  NOT mandatory. Every retry path (`fail`→Retry, reaper re-pend, stale re-claim) provisions a
  FRESH box (`oneShotServerName` = crypto-suffixed per attempt; `ProvisionWith` always creates);
  bootstrap never re-runs against a surviving instance in the provisioner chain. The Prior* seam
  stays for the library's converging re-run semantic (`bootstrap_test.go
  TestRunHalfBootstrappedConverges`, `TestRunWebhookUpsertsByName`) — wire it only if a same-box
  re-run path is ever introduced.

## 6. Webhook auto-reg (dwb-5)

- Re-run/duplicate: PROVEN — upsert-by-name on the instance, store-once secret
  (`bootstrap_test.go TestRunIsIdempotent`, `TestRunWebhookUpsertsByName`); webhook failure fails
  the bootstrap → teardown (cell 5). Webhook lives ON the box → dies with the box; control plane
  stores outputs only at /succeed, so nothing dangles control-plane-side. PROVEN by construction +
  `TestRunOnceForwardsBootstrapOnSucceed`.

## 7. Studio-link (dwb-7)

- Double-click: PROVEN — each click mints an independent single-use 60s ticket (no shared state);
  ticket consume race: exactly one winner (`api login_ticket_test.exs "N concurrent consumes of
  one ticket → exactly one winner"`); instance down → 502, retry = new click
  (`router_studio_link_test.exs`).

## 8. Deprovision (DELETE /v1/barkparks/:id)

- Double-remove: PROVEN + hardened — app check deduped to 202 before; the new partial index now
  closes the concurrent check-then-insert window too
  (`provisioning_test.exs "second deprovision enqueue ... is refused"`).
- Remove DURING provision: PROVEN — 409 `provisioning_in_progress` (host nil + active job)
  (`router_test.exs "non-live instance with a pending provision job → 409"`); template/bootstrap
  did not change this path (host is still nil until /succeed).
- IP reuse on stale deprovision: PROVEN — delete requires IP AND barkpark-fqdn label match; fails
  loudly on mismatch (`TestDeprovisionByIP_IPReuseMatchesByFQDNLabel`).
- Duplicate deprovision succeed: PROVEN — `{:ok, :already_gone}` idempotent
  (`succeed_deprovision_job` tests).

## 9. Warm-assign path (dwb-10, #763 — reference, merged after this branch forked)

Same guarantees re-proven there, not here: SKIP LOCKED warm claim
(`warm_pool_test.exs "race-safe: N concurrent claimers"`), idempotent register, stale claimed/
retiring sweep, teardown-on-assign-failure (`warmpool_assign_test.go
TestAssignWarm_HealthFailureTearsDownBoxAndDNS`), orphan sweep leaves warm boxes alone. The
one-active-job index from this branch applies unchanged (the assign path rides the same
provision_jobs queue). Re-audit cell-by-cell if warm-assign is switched on by default.
