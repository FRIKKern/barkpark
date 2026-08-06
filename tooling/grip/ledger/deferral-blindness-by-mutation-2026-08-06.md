# Deferral blindness, proved by mutation — 2026-08-06

Verifier row for the deploy-reliability wave (`deferral-blindness-by-mutation`).
Everything below is re-derivable; no repo file outside this ledger was touched.

## Rig (the local `cloud/` checkout is BEHIND origin/main — `deploy_ledger.ex` does not exist here)

```sh
D=/tmp/dbm; rm -rf $D; mkdir -p $D
git archive origin/main | tar -x -C $D
W=<any worktree already carrying cloud/deps + cloud/_build>   # e.g. /private/tmp/w33-baseline
cp -R $W/cloud/deps $D/cloud/deps; cp -R $W/cloud/_build $D/cloud/_build
cd $D/cloud && MIX_ENV=test CC=clang mix test test/barkpark_cloud/deploy_ledger_test.exs
```

Baseline on origin/main: `28 tests, 0 failures`.

## Proof 1 — `classify/1` is reason-blind for deferrals (mutation)

Add a probe test asserting three NOVEL deferral reasons (`box_at_capacity`,
the requeue-broken text, pure nonsense) and `nil` all answer `BOX_BUSY_DEFERRED`.
It PASSES, i.e. `UNCLASSIFIED` is structurally unreachable for `status: "deferred"`.

```sh
cd $D/cloud && MIX_ENV=test CC=clang mix test test/barkpark_cloud/deferral_blindness_probe_test.exs
# 4 tests, 0 failures
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '180,188p'
```

## Proof 2 — end-to-end capacity slander (mutation of the existing 6-round test)

In `cloud/test/barkpark_cloud/sites_deploy_test.exs`, change the programmed 409
body's `code` to `box_at_capacity` / message `box at capacity: 1 build already running`,
keep the 6-round loop, and print `last.failure_reason`:

```sh
cd $D/cloud && MIX_ENV=test CC=clang mix test test/barkpark_cloud/sites_deploy_test.exs
# PROBE-CAPACITY-TERMINAL: the instance refused the deploy (HTTP 409): box_at_capacity —
#   box at capacity: 1 build already running — and it has now refused 6 rebuilds in a row
#   for this site, so the instance is not busy but stuck; check its deploy runner
# PROBE-CAPACITY-CLASSES: ["BOX_BUSY_DEFERRED"]
# 59 tests, 0 failures
```

## Proof 3 — the requeue-failure path is untested and un-statused

```sh
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1223,1232p'  # no status: key
git grep -n "could NOT be re-queued\|deferral_requeue_failed" origin/main -- cloud/test   # zero hits
git grep -n "Deploy.run(" origin/main -- cloud/lib      # only the supervised Task at deploy.ex:1900
```

The `{:error, {:deferral_requeue_failed, _}}` return is produced inside a
`Task.Supervisor.start_child/2` closure, so nothing consumes it in production —
there is no Oban job to retry, contrary to the comment at `deploy.ex:1210-1218`.
