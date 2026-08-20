# Re-derivation recipe — fleet build admission gate: fail-open incidence and queue exercise (wave 21)

Taken 2026-08-08T03:0x–03:2xZ on guerrilla (157.180.90.121). Journal retention on the box begins
2026-07-29T16:49:38Z (3.7G archived+active), so a "10 day" window is fully covered by real data.

## 1. Deployed script == origin/main (the ancestor rule applied to deploy scripts)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'sha256sum /opt/barkpark/deploy/lib/site-deploy-common.sh'
    git show origin/main:deploy/lib/site-deploy-common.sh | shasum -a 256

Both: `525f2ba9d0244bcdfe2d63fadba2c5732aed6c7160fa7b97e721674befe02825`.
Box `git -C /opt/barkpark rev-parse HEAD` = `2673eb009f67e81f06e247e5a1504a83de699d97`.

## 2. Fail-open incidence — THREE branches, FULL journal

    ssh … 'journalctl --no-pager -g "admission gate is OPEN" --output=short-iso | head -3
            journalctl --no-pager -g "fleet build lock falls back to" --output=short-iso | head -3
            journalctl --no-pager -g "no flock" --output=short-iso | head -3'

All three: `-- No entries --`. n = 0.

Preconditions that make the branches unreachable today:
`which flock` → `/usr/bin/flock` (util-linux 2.39.3); `/var/lock` is `drwxrwxrwt`;
`/var/lock/barkpark-site-build.lock` exists, `-rw-r--r-- root root 0`.

## 3. 900s wait budget — never lapsed

    ssh … 'journalctl --no-pager -g "FLEET BUILD SLOT" --output=short-iso | head -3'

`-- No entries --`. n = 0 over the full journal. (This is the caller-side refusal detail at
`deploy/site-deploy.sh:2274` / `deploy/site-deploy-node.sh:1763`, emitted before `exit 15`.)

## 4. The queue IS exercised, heavily, and always drained

    ssh … 'journalctl --since "7 days ago" --no-pager -g "fleet build slot acquired" | wc -l'          # 5728
    ssh … 'journalctl --since "7 days ago" --no-pager -g "only build slot is busy" | wc -l'            # 4529
    ssh … 'journalctl --since "7 days ago" --no-pager -g "acquired after queueing" | wc -l'            # 4525

Wait distribution, paired by `bash[PID]` between the "busy" line and its "acquired after queueing" line:

    ssh … 'journalctl --since "7 days ago" --no-pager -g "build slot is busy|acquired after queueing" \
      --output=short-unix | awk "{ ts=\$1; pid=\$0; sub(/.*bash\[/,\"\",pid); sub(/\].*/,\"\",pid);
      if (\$0 ~ /is busy/) start[pid]=ts; else if (pid in start) { d=ts-start[pid];
      if (d>max) max=d; n++; sum+=d; delete start[pid] } }
      END { printf \"pairs=%d max_wait_s=%.0f mean_s=%.1f\n\", n, max, sum/n }"'

→ `pairs=4525 max_wait_s=319 max_pid=3472040 mean_s=94.8`. Peak observed wait is 35% of the 900s budget.

## 5. The >=2-concurrency regime is dead (corroborates the digest)

    ssh … 'journalctl --since "7 days ago" --no-pager -g "only build slot is busy" --output=short-iso | cut -c1-10 | sort | uniq -c'

    930 2026-08-01 / 1053 2026-08-02 / 575 2026-08-03 / 309 2026-08-04 / 439 2026-08-05 / 1219 2026-08-06

No rows on 2026-08-07 or 2026-08-08; last queue event `2026-08-06T22:20:49+00:00`, while acquisitions
continue (572 on 08-07, 55 on 08-08 by 03:1xZ). Contention stopped, deploys did not.

## 6. The structural silence (why the slice is about reporting, not about the cap)

`build_gate_acquire` reports every fail-open branch with `log` (`site-deploy-common.sh:36`,
plain `[site-deploy HH:MM:SS] WARN: …` on stdout), never with `emit` (`:55`, the `BPSTAGE` protocol
the control plane parses — `cloud/lib/barkpark_cloud/sites/deploy.ex:1863`). Repo-wide, the only
consumer of the string `admission gate is OPEN` outside the library is `deploy/site-deploy.sh:1936`,
a `--self-test` assertion. That self-test does have a CI caller (`deploy-harnesses.yml:66`), but that
workflow is `pull_request`-only, path-filtered to `deploy/**`, and is not a required context — so it
proves the WARN can be printed and can block nothing at deploy time.
