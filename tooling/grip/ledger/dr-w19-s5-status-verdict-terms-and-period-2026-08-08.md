# dr-w19 s5 re-brief: verdict terms, period, and the true ladder price

2026-08-08. origin/main. Prod control plane `https://api.barkpark.cloud`;
DB host `178.105.92.191`, container `cloud-db-1`, db `barkpark_cloud_prod`.
Every row below re-derives from scratch.

---

## 1. The filed brief's two verdict terms do not exist anywhere in shipped code

    git grep -c 'settled_absorption\|hard_failure' origin/main -- cloud internal api   # rc=1, no output

The only `hard_failure` in the repo is `scripts/paper_quality.py` (paper linting,
unrelated):

    git grep -rn 'settled_absorption\|hard_failure' origin/main | head

## 2. What the census envelope ACTUALLY emits (code side)

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '870,900p'

Keys: window, volume, failed, live, in_flight, cancelled, residual,
failure_rate, live_rate, classes, deferred, not_attempted, sites, total_sites,
truncated, coalesced_attempts, completeness, boundaries, min_sample.

## 3. …and on the LIVE wire, through the door a non-operator can reach

Operator door is shut on an ordinary team credential; the team door is open:

    T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" \
      "https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-07T00:00:00Z&to=2026-08-08T00:00:00Z"   # 403 forbidden/platform_operator
    curl -s -H "Authorization: Bearer $T" \
      "https://api.barkpark.cloud/v1/deploy-ledger/census?from=2026-08-07T00:00:00Z&to=2026-08-08T00:00:00Z" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(d.keys()))"   # 200

`FleetDeployCensus` on main still calls the OPERATOR path
(`internal/cloudclient/client.go:2154`), i.e. the door that 403s — that is
exactly what #10518 re-points:

    git show origin/main:internal/cloudclient/client.go | sed -n '2145,2160p'

## 4. THE PERIOD: hourly is unmetered forever; DAILY is the only period that meters

Run `minsample.sql` (attempted = all rows minus `@not_attempted_classes`
`GITHUB_PUSH_UNBUILDABLE`; on this corpus that class has ZERO rows, so
attempted == all rows == 31,345):

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod" < minsample.sql

| period | buckets | >= min_sample 200 | pct metered | max | min |
|---|---|---|---|---|---|
| hour  | 432 | 6  | 1.39%  | 226 | 1 |
| 6h    | 78  | 60 | 76.92% | 965 | 1 |
| day   | 21  | 20 | 95.24% | 2766 | 169 |

Sanity: every bucketing sums to 31,345 == attempted_rows.

POST-CUT regime only (`inserted_at >= 2026-08-07 03:46:27`, the webhook
doc-type filter run): hourly **0 of 20** buckets reach 200, max hour = 100.
6h = 2 of 4. day = 1 of 1 (n=1106). Hourly is not merely rare — in the current
regime it is structurally unreachable.

## 5. Which shipping terms can actually carry a verdict (`liverate.sql`)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod" < liverate.sql

- **failure_rate is vacuous by RENAME, provably**: 2026-07-30 failed=2446 /
  deferred=0 / failure 88.43%; 2026-08-07 failed=18 / deferred=1371 /
  failure 0.94%. failed+deferred is roughly conserved. Do not fence on it.
- **live_rate ships and never refuses across the boundary (D229)** — but it does
  NOT admit a green floor today: 91.72–95.59% on 07-14..07-21 vs **27.43%**
  today. attempts-per-live went 1.09 → 3.65. It is the honest HEADLINE (the
  number that must come down) and a bad FENCE (any July-calibrated floor is
  permanently red — the same objection the brief levelled at raw absorption).
- **coalesced_attempts ships, meters, and reads ~ZERO**: over a post-counter
  window (2026-08-07T11:00Z..08-08T00:00Z) volume=621, `coalesced_attempts`
  `{value: 0, refused: false}`. DB side: of 658 rows since the counter began,
  exactly **1** row is non-zero, total 6 — against 1,371 deferrals that day.

## 6. The true price of a twelfth rung — 12 edit sites, not the brief's 7

    git grep -n 'attentionRankOrder\|attentionBucket\|ElevenRungs\|attentionVocabularyFixturePath' origin/main -- internal
    git grep -n '"strained"\|"filling"' origin/main -- internal/semrole

Production (4): `cloud_status_cmd.go` attentionStatus :92, attentionRankOrder
:248, attentionBucket :283; `internal/semrole/semrole.go` tone arm :111.
Tests (6): `cloud_status_cmd_test.go` TestAttentionStatusClassification :44,
TestAttentionBucket :117, TestAttentionLadderIsElevenRungs :135 (+ its NAME),
TestAttentionVocabularyMatchesFixture :385, TestRunCloudStatusJSON :474;
`internal/semrole/semrole_test.go:21` vocabulary list.
Fixtures (2): `cloud/priv/static/__fixtures__/attention_order.json` (11 states),
`internal/cli/testdata/attention_order_cases.json` (15 barkparks / 15 expected).

Criterion 8 as filed names only 4 tests + 2 fixtures + semrole.go. It MISSES
`semrole_test.go:21`, `attentionStatus` and `attentionBucket`.

## 7. No wire/payload change is needed for per-box attribution

`cloudclient.Barkpark` is 83 lines and contains ZERO deploy fields (confirmed):

    S=$(git show origin/main:internal/cloudclient/client.go | grep -n 'type Barkpark struct' | cut -d: -f1)
    git show origin/main:internal/cloudclient/client.go | awk -v s="$S" 'NR>=s && NR<=s+95' | grep -ic deploy   # 0
    git show origin/main:internal/cli/cloud_status_cmd.go | grep -ic deploy                                     # 0

But the brief's own ruled W1 fold needs none: census `sites[]` rows carry
`site_id` (live payload above) and `cloudclient.Site` carries `BarkparkID` at
`internal/cloudclient/client.go:1096`. The change is a Go render-row field, not
a payload change. Note census `sites[]` rows carry volume/live/failed/deferred/
failure_rate/top_class but NO per-site `live_rate` — compute it client-side.

## 8. Go DeployCensus drops 5 keys the server sends

`type DeployCensus struct` (`internal/cloudclient/client.go:1983`) decodes no
`coalesced_attempts`, `completeness`, `total_sites`, `truncated`, `boundaries`.

## 9. Cross-surface ladder drift is LIVE and unguarded

    git show origin/main:cloud/priv/static/app.js | sed -n '5662,5666p'      # 9 rungs
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -c attention_order   # 0
    git show origin/main:.github/workflows/go-tests.yml | grep -n cloud      # only line 3, a comment

Go = 11 rungs, fixture = 11 rungs, console `ATTENTION_RANK` = 9 (`strained` and
`filling` absent). `cloud/**` is NOT in go-tests.yml's paths, so a fixture-only
change runs zero Go tests.

## 10. Gate, green on this tree

    CC=clang go build ./...              # rc=0
    CC=clang go test ./internal/cli/...  # ok internal/cli 20.110s; ok .../cloud 0.927s; ok .../setup 2.932s
