# Re-derivation recipes — DR wave 3 verify: gate-hole-or-job-done (2026-08-06)

Verifier assignment: is JOB 1 (fleet build cap) finished, or does the deployed
N=1 gate have a real hole?

## R1 — The gate exists on origin/main and wraps npm ci

    git show origin/main:deploy/lib/site-deploy-common.sh | sed -n '250,400p'
    git show origin/main:deploy/site-deploy-node.sh | sed -n '1600,1720p'
    git show origin/main:deploy/site-deploy.sh | grep -n 'build_gate_acquire\|build_gate_release\|npm ci'

Expect: BUILD_GATE_SLOTS=1, BUILD_GATE_WAIT_DEFAULT=900, acquire AFTER
`emit BUILD started`, release immediately AFTER `emit BUILD ok`. Both engines.

## R2 — The gate is HOLDING live on guerrilla (one npm, N queued)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl list-units "bp-site-build-*" --state=active --no-legend;
       ps -Ao pid,etime,rss,args | grep -Ea "npm ci|npm run build" | grep -av grep;
       for p in $(pgrep -f site-deploy); do echo "pid=$p fd7=$(readlink /proc/$p/fd/7 2>/dev/null || echo NONE)"; done;
       free -m'

Expect (measured 2026-08-06 08:55-09:00Z): 3-5 active units, EXACTLY ONE
`npm ci`, several procs holding fd7 on /run/lock/barkpark-site-build.lock
blocked in flock, Swap 2047/2047 used.

## R3 — Queue depth over time (the digest's "exactly one unit" was one sample)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for i in $(seq 10); do echo "$(date -u +%H:%M:%S) units=$(systemctl list-units "bp-site-build-*" --state=active --no-legend | wc -l) swap=$(free -m | awk "/Swap/{print \$3}")"; sleep 20; done'

## R4 — Per-unit stage evidence (EXACT unit name, never a glob)

    ssh … 'journalctl -u bp-site-build-<slug>-<build>-<ts>.service --no-pager -o cat -n 4'

Exact unit: 0.276s. The glob form is the 121s path from task-e05c4e4cea2282e5 —
do not use it.

## R5 — The gate-timeout reason is UNCLASSIFIED, terminal

    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | grep -n 'exit_label(15)'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '196,250p'
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '660,700p'

exit 15 -> "gave up waiting for the deploy lock (exit 15): <detail>"; no arm of
`DeployLedger.classify/2` matches that prefix -> "UNCLASSIFIED"; `poll/4`'s
`:failed -> fail(ctx, report.failure_reason)` makes it terminal. The D9
counted-deferral seam only fires on an HTTP 409 at START, which this never is
(the box already answered 202).
