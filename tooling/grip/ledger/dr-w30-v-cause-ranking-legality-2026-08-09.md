# dr-w30 VERIFY — cause-ranking legality: re-derivation recipes (2026-08-09)

Verifier: cause-ranking-legality. Ground: origin/main `02475d0ec`; cloud-db-1 at
`2026-08-09 14:05:45+00`; live census read at ~14:30Z. No repo edits outside this file.

## R1 — the STORED column population (fleet-wide, every row)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -Atc \"select coalesce(deferral_cause,'\''NULL'\''),count(*) from deployments group by 1 order by 2 desc; select min(inserted_at)::text from deployments where deferral_cause is not null;\""'
```

Answer 2026-08-09: `NULL|31374`, `BOX_AT_CAPACITY_DEFERRED|1388`; first write
`2026-08-07 10:12:35.033826`. ONE non-NULL value fleet-wide. D381 holds.

## R2 — the DERIVED classifier's deferral arms, split at the writer's landing

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -Atc \"select case when failure_reason like '\''%(HTTP 409)%box_at_capacity%'\'' then '\''AT_CAPACITY'\'' when failure_reason like '\''%(HTTP 409)%already_running%'\'' then '\''BUSY'\'' else '\''OTHER'\'' end, inserted_at >= timestamp '\''2026-08-07 10:12:35'\'' as post_writer, count(*) from deployments where status='\''deferred'\'' group by 1,2 order by 3 desc;\""'
```

Answer: post-writer `AT_CAPACITY 1388` (column 1388/1388 populated, zero disagreement);
pre-writer `AT_CAPACITY 1120`, `BUSY 698`. **The busy arm has produced ZERO rows since the
writer landed** — the column's single-arm shape is an EMPTY ARM, not a writer bug.

## R3 — the D3-legal ranking, live, from the derived classifier

```sh
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
curl -s -H "Authorization: Bearer $TOK" "https://api.barkpark.cloud/v1/deploy-ledger/census?from=2026-08-05T21:13:50Z&to=2026-08-09T14:30:00Z" | python3 -m json.tool
```

Window starts AT the settle boundary, so nothing is refused: `volume 5874`,
`failure_rate 17.79% (1045/5874, refused:false)`; classes BOX_500 301 / DOC_ID_EMPTY 265 /
BOX_DEPLOY_DISABLED_503 219 / BUILD_FAILED 192 / tail<30; deferred BOX_AT_CAPACITY 2509
(42.71%) + BOX_BUSY 698 (11.88%), both `refused:false`.

`/v1/operator/deploy-ledger/census` answers **403 forbidden platform_operator** to this PAT;
the team-scoped twin answers 200. Use the team route.

## R4 — the two surveyors reconciled (denominator sweep)

```sh
for w in 2026-08-02T00:00:00Z 2026-08-03T00:00:00Z 2026-08-05T21:13:50Z; do
  curl -s -H "Authorization: Bearer $TOK" "https://api.barkpark.cloud/v1/deploy-ledger/census?from=$w&to=2026-08-09T14:30:00Z" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print('$w',d['volume'],[(x['class'],x['count'],x['share']['pct']) for x in d['deferred']])"; done
```

The COUNTS 2509 / 698 are window-invariant across every window tested; only the volume
denominator moves (10034 → 25.0%/6.96%; 7992 → 31.39%/8.73%; 5874 → 42.71%/11.88%). The
reported 28.67%/8.01% pins a volume of ≈8752, i.e. a start instant around 2026-08-02T18Z.

## R5 — which code path each number came from

- Stored column: written ONLY by `cloud/lib/barkpark_cloud/sites/deploy.ex:1265,1345`
  (`deferral_cause/2` → `DeployLedger.classify/1`). Read by exactly ONE surface:
  `router.ex:11489` → `internal/cli/cloud_site_cmd.go:2384` — a PER-ROW field, never aggregated.
- Derived: `DeployLedger.census/3` (`deploy_ledger.ex:882-907`) groups by
  `(site_id, stage, status, failure_reason)` and maps `classify(g)`. It **never selects
  `deferral_cause`**. Every rate/ranking surface is therefore 100% derived.

`grep -n "deferral_cause" $(git rev-parse --show-toplevel)` on `origin/main` re-derives the reader set.

## R6 — `bp cloud deployments` from the primary checkout

`make cli-build && ./barkpark cloud deployments` → `bp: unknown cloud command "deployments"`.
Cause: the primary checkout is **444 commits behind origin/main** (`git rev-list --count HEAD..origin/main`).
The verb IS registered on origin/main at `internal/cli/hetzner_cmd.go:123`. The MUST-RUN
command in the wave direction is unrunnable from this checkout without a worktree.
