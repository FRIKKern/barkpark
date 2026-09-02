<!-- doc-tier: cold | canonical-for: hgw3-task-gate-honesty-replay-rederivation | budget: 3000tok -->

# Re-derivation recipe — "N of the last M pr-task-gate reds were lapsed claims"

> HISTORICAL RECORD (2026-07-28) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

The claim appears verbatim in THREE places on origin/main as "11 of the gate's last 15 reds":
`scripts/pr-task-gate.sh:297`, `scripts/pr-task-gate.test.sh:80`, `docs/ops/merge-gates.md:60`.
It is **not** re-derivable from GitHub log text (the log only carries the pre-#6413 message
"is still 'open' — claim it before opening the PR", which cannot distinguish *never claimed*
from *reaped*), and it is **not** re-derivable from the task document either: `Claim.claim/…`
at `api/lib/barkpark/tasks/claim.ex:297-303` builds `new_claim` as a FRESH map, so any later
re-claim erases `previous_worker` and `expired_at`.

The only source that survives is the authenticated task-events feed.

## Recipe

1. Sample the reds and their task ids (the FAIL line is a script emission, not echoed source):

```bash
gh run list --workflow pr-task-gate.yml --limit 100 \
  --json databaseId,conclusion,headSha,createdAt \
  -q '.[]|select(.conclusion=="failure")|[.databaseId,.headSha,.createdAt]|@tsv'
# then, per run id:
gh run view <id> --log | grep -a -oE "pr-task-gate: (FAIL|UNCHECKED|PASS): .*" | head -1
```

2. Page the task-events feed (ascending keyset on `since`, `limit` clamped to 500, params
   other than `since`/`limit` are SILENTLY IGNORED — charter D23 already records this):

```bash
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -s -H "Authorization: Bearer $TOK" \
  "https://guerrilla.barkpark.cloud/v1/tasks/events?since=110000&limit=500"
# follow .cursor while .has_more; retry 500s (guerrilla returns transient 500s under load)
```

3. For each `(red_time, task_id)`, take the last event in
   `{task.claimed, task.closed, task.lease_expired, task.released}` for that `doc_id`
   (strip the `drafts.` prefix) at or before `red_time`, and decide:

| last event before the red | post-#6413 verdict |
|---|---|
| `task.claimed` | PASS (in_progress) |
| `task.closed` | PASS (done) |
| `task.lease_expired`, age ≤ 21600s | PASS via the D23 grace |
| `task.lease_expired`, age > 21600s | FAIL, beyond grace |
| `task.released` | FAIL, released |
| none | FAIL, never claimed |

## Result on 2026-07-28 (window 2026-07-26T18:55Z → 2026-07-27T22:36Z, 16 open-reds)

13 PASS via the D23 grace, 3 still FAIL: `auth-totp-tests-are-time-boundary-flaky` and
`truth-grip-epic` (genuinely never claimed at red time — first `task.claimed` is AFTER the red),
and `search-template-epic-goal` (reaped 22430s before the red, 830s beyond the 21600s grace).

So the shipped statement is **directionally corroborated at 13/16 (81%)** rather than 11/15 (73%),
on a different and larger sample. The prose should say "re-derived at 13 of 16 on 2026-07-28,
see this recipe" rather than quoting an undated 11/15 whose sample nobody can reconstruct.
