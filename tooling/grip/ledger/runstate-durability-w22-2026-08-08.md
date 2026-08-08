# Run-state durability — is `/opt/barkpark/.bp-site-deploy-runs` being wiped? (w22, 2026-08-08)

**VERDICT: NO. Nothing wipes it. The "~40-hour rotating corpus" is FEATURE AGE, not rotation.**
The corpus floor is the deploy of #9727 (`feat(sites): the build log is keyed on the deployment`,
2026-08-06 13:31:45 +0200 = 11:31:45 UTC). The oldest record on disk is a tombstone written
2026-08-06T11:38:03Z — six minutes later, on the first retention sweep of the freshly deployed code.
Terminal records are pruned by COUNT ONLY (`@default_max_terminal_records 10_000`), never by age.
**Leg 1's sha recorder CAN be sited here.**

## Re-derivation

Count, floor, and the wipe search (the assigned MUST-RUN, corrected — `barkpark.service` does not
exist on this box; it is blue/green `barkpark-slot@{blue,green}`):

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'D=/opt/barkpark/.bp-site-deploy-runs;
  ls $D/*.terminal.json | wc -l;
  ls -lt --time-style=full-iso $D/*.terminal.json | head -2;
  ls -lt --time-style=full-iso $D/*.terminal.json | tail -2;
  stat -c "%w %y %n" $D;
  grep -rn bp-site-deploy-runs /opt/barkpark/.githooks/ /etc/systemd/system/ /etc/cron* /etc/tmpfiles.d 2>/dev/null'
```

Feature-age proof (the floor is a merge, not a deletion):

```
git log --format='%h %ad %s' --date=iso -S'terminal.json' origin/main -- api/lib/barkpark/sites/deploy_runner.ex | tail -1
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cat /opt/barkpark/.bp-site-deploy-runs/perfect-demo-2.terminal.json'
```

Retention law (count-only for records; age/count/bytes for logs):

```
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '240,248p;2556,2578p'
```

## The five facts that close it

| # | Fact | Why it kills the wipe hypothesis |
|---|---|---|
| 1 | 1,056 records against a 10,000 cap | the count cap has **never bound**; nothing was dropped for capacity |
| 2 | `prune_terminal_records/2` is count-only — no age term | records cannot expire by time; only a foreign deleter could shorten history |
| 3 | `*.log` files reach back to **2026-08-04 20:41**, older than the oldest *record* | a directory wipe would have taken the logs too |
| 4 | Dir birth `2026-07-17 04:10:59` — never recreated | the container of the corpus predates the corpus by 20 days |
| 5 | Zero references to the dir in `.githooks/`, `/etc/systemd/system/`, crontabs, tmpfiles.d; zero `git clean -fdx` in `.githooks`/`Makefile`/`deploy/`/`scripts/` on origin/main | there is no code path that removes it |

## Runway (the number leg 1 should plan against)

1,056 records over 2026-08-06T11:38:03Z → 2026-08-08T08:28:24Z = **44.84 h ⇒ 23.6 records/h**.
10,000 / 23.6 = **424 h ≈ 17.7 days** of retained deploy history at the current rate — the charter's
"~16 days" projection was right; its "~40-hour rotating" observation was a misread of feature age.

## A VACUOUS NEGATIVE the assignment would have shipped

`journalctl -u barkpark -g "unit re-attach skipped"` returns `-- No entries --` — but so does
`journalctl -u barkpark` **for every string**: the unit is `barkpark-slot@blue`, and `barkpark.service`
has **1 line / 0 entries** on this box. The honest re-run pins the unit *and* carries a positive control:

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 '
  journalctl -u barkpark-slot@blue -u barkpark-slot@green --since "2026-08-01" -g "re-attach skipped" --no-pager -o short-iso | head -5
  journalctl -u barkpark-slot@blue --since "2026-08-08 06:00" -g "site-deploy" --no-pager -o short-iso | tail -3'
```

Rescue: `-- No entries --`. Control: three `GET /v1/admin/site-deploy` lines. The rescue at
`deploy_runner.ex:1275` has never fired inside the journal window — and the window is **only
~10 days** (`journalctl --disk-usage` = 3.6 G; oldest entry 2026-07-29T21:11:34+00:00; one slot emits
25,510 lines in 2.5 h), which is itself the reason a durable recorder must not be sited in journald.
