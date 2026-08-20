# Re-derivation recipes — envelope-node-reachability (wave 22 verify), 2026-08-08

Verifier lane: is `barkparks.git_commit` populated on the live guerrilla row, and
does guerrilla itself run the agent and beat? Every row below is a command that
re-derives the fact from scratch. `$T` = `cloud_token` from `~/.config/barkpark/config.json`.
Guerrilla barkpark id = `b2b81e69-c79c-4eff-b6d7-84507d15b925`.

## R1 — git_commit IS populated (not a served-but-null field)

```
curl -s -H "Authorization: Bearer $T" https://api.barkpark.cloud/v1/barkparks \
  | python3 -c "import json,sys;d=json.load(sys.stdin);g=[b for b in d['barkparks'] if b['slug']=='guerrilla'][0];print(g['git_commit'],g['last_seen_at'],g['agent_status'])"
```

Observed 2026-08-08T08:28Z: `2673eb009f67e81f06e247e5a1504a83de699d97 2026-08-08T08:27:59.117077Z online`.
5 of 6 rows carry a sha; only `muscle-1` is null (git_commit=None, last_seen_at=None — never beat).

## R2 — the served sha equals the box's CHECKOUT head, not the running BEAM

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git rev-parse HEAD; git status --porcelain | wc -l'
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl show barkpark-slot@blue -p ActiveEnterTimestamp'
```

Checkout HEAD == the served sha exactly. Source of truth: `internal/agent/report.go`
(`GitCommit` = `git rev-parse HEAD` in `--checkout`).

## R3 — `dirty_tree` is NOT on the row; it is on `/telemetry`, and it can never read false

```
curl -s -H "Authorization: Bearer $T" https://api.barkpark.cloud/v1/barkparks/<id>/telemetry \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['telemetry']['dirty_tree'])"
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git status --porcelain'
```

`true` — but all 9 entries are UNTRACKED (`??`), incl. `bp`, `sites/`, `.claude/worktrees/`.
`git status --porcelain` counts untracked, so the gauge is pinned true forever on this box.

## R4 — the memory EXISTS (14d) but the only reader reaches ~3h

```
curl -s -H "Authorization: Bearer $T" "https://api.barkpark.cloud/v1/barkparks/<id>/events?limit=5000" \
  | python3 -c "import json,sys;e=json.load(sys.stdin)['events'];print(len(e),min(x['inserted_at'] for x in e),max(x['inserted_at'] for x in e))"
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7993,8016p'   # parse_limit(..., 50, 200)
git show origin/main:cloud/lib/barkpark_cloud/workers/agent_retention_worker.ex | grep -n '@event_retention_days'
```

limit=5000 returns 200 rows (hard cap) = 3h06m; retention keeps 14 days of 60s beats
each carrying `git_commit` in the payload.

## R5 — guerrilla runs the agent and beats

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl status barkpark-agent --no-pager | head -12'
```

`active (running) since Sat 2026-08-08 02:40:51 UTC`, reporting to https://barkpark.cloud every 1m0s.

## R6 — the cloud router barkparks tests

```
cd <worktree within ~65 commits of origin/main>/cloud && CC=clang mix test test/barkpark_cloud/web/router_test.exs
```

173 tests, 0 failures. NOTE: the PRIMARY checkout `/Volumes/SATECHI/github/barkpark`
is 659 commits behind origin/main and its run reds 6/168 on a shared test DB that a
fresher worktree already migrated — staleness, not a main defect.
