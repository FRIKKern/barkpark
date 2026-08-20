<!-- doc-tier: cold | canonical-for: cch-w69-live-queue-and-baseline | budget: 3000tok -->

# cch wave 69 — live queue + main baseline: re-derivation recipes (2026-08-17)

Verifier assignment `[live-queue-and-baseline]`, cloud-console-hardening wave 69. Every row is a command
plus what it printed at ~10:00–10:12Z on 2026-08-17. Main moves fast (four merges inside twelve minutes
during this verification), so re-derive rather than quote these numbers forward.

## 1. #11706 is MERGED

    gh pr view 11706 --json state,mergedAt,mergeCommit

`{"mergeCommit":{"oid":"05a98dd2cadd10b649c3bc17cf75145a7571f80f"},"mergedAt":"2026-08-17T10:00:27Z","state":"MERGED"}`.
Merge SHA `05a98dd2cadd10b649c3bc17cf75145a7571f80f`. The round-2 gate on #11706 is therefore discharged;
#11711 merged earlier at 09:56 (`840effe8acd9a411d081f8f5a0b9694a3b477a2d`).

## 2. Main's red set, latest-per-name

    gh api "repos/FRIKKern/barkpark/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
      -q '.check_runs[]|[.name,.status,(.conclusion//"-"),.started_at]|@tsv' \
      | sort -k1,1 -k4,4r | awk -F'\t' '!seen[$1]++'

On `05a98dd2` (#11706's own merge): `Crown reconcile` failure 10:06:12Z, `Doc budgets + anchors` failure
10:08:58Z. On the previous fully-settled tip `840effe8` (#11711): those two plus `Stale verdict watch`
failure and `bin/barkpark up/stop differential selftest` failure. NONE is in the required set —
`.github/required-checks.json` requires exactly four contexts (Cloud gate, Console gate, Elixir gate,
PR references an active task) and lists `Doc budgets + anchors` under `exclusions` ("S4 PATHS-FILTERED").
The boot selftest red is FOREIGN and path-triggered (`bin/barkpark`/`scripts/` paths): its message is
`FAIL: fx_stop_clean_slate_says_so ALSO passes against the pre-fix reference — it does not discriminate,
so it proves nothing`, already failing on `50f0de0e` at 08:33Z, i.e. it predates #11723.

## 3. The audit-actions deploy break bites EVERY merge — proven, not predicted

    gh run view 32017688986 --json jobs -q '.jobs[]|[.name,.status,(.conclusion//"-")]|@tsv'
    gh run view --job 95351816763 --log | grep -iE "could not read file|BUILD FAILED"

`control-plane completed failure` on `840effe8` — #11711's merge, which touches only `internal/` — with
`** (File.Error) could not read file "/design/audit-actions.json": no such file or directory` at
`lib/barkpark_cloud/accounts/audit_event.ex:84`, `[cp-deploy 10:08:41] BUILD FAILED`, exit 13. Identical
bytes to #11723's own failure at 09:36:28Z (run 32015965513).

MECHANISM, read on origin/main, that makes recurrence structural rather than accidental:
`.github/workflows/deploy.yml:63` anchors the path filter to `gh run list --workflow=deploy.yml
--branch=main --status=success --limit=1 --jq '.[0].headSha'` — the last SUCCESSFUL deploy. Since
#11723's deploy failed, that base is pinned at `cc9be0d6`, so every later run diffs a range that still
contains `cloud/**` + `design/audit-actions.json`, sets `cp=true`, and rebuilds the same broken image.
Build context: `cloud/docker-compose.yml:23` is `build: .` (context = `cloud/`) and `cloud/Dockerfile`
COPYs only `mix.exs mix.lock config lib priv` — `design/` can never enter the image, so
`Path.expand("../../../../design/audit-actions.json", __DIR__)` resolves to `/design/...` in-container.

Nothing open fixes it: iterating all 60 open PRs' file lists for `audit_event.ex`,
`cloud/Dockerfile`, `design/audit-actions.json`, `cloud/docker-compose.yml` returns zero PRs.
`bp search query "audit-actions manifest docker build context"` returns no task for it either.

Second-order fact for Law 0 and for anyone reading deploy colour: `05a98dd2`'s deploy run (32018045953)
concluded **cancelled** — `concurrency: deploy-production` coalesces, so #11706 was never even attempted
on the box.

## 4. Stale-verdict watch — 15 rows, and #10086 is gone

    bash scripts/stale-verdict-watch.sh   # exit 1

Header: `39 open · 17 CONFLICTING · 22 MERGEABLE · 0 UNKNOWN after re-polling`, then
`RED — 15 CONFLICTING pull request(s) assert a green required verdict main has moved past.`
Rows: #6028 #6057 #6086 #10054 #10085 #10129 #10173 #10256 #10404 #10407 #10496 #10522 #10523 #10720 #10811.
`#10086` is absent — `gh pr view 10086 --json state` says `CLOSED` (it is #11711's original, closed as
superseded). D830 recorded 19 rows; the population is 15 now.
`#10766` is OPEN/CONFLICTING but renders no green required verdict, so it is not a row and reconciling it
clears nothing here.
cch owns FIVE rows (#10054 #10085 #10256 #10404 #10523); four are deploy-reliability charters
(#10173 #10407 #10496 #10522); six are foreign (#6028 #6057 #6086 #10129 #10720 #10811). A union-reconcile
of the four cch CHARTER PRs leaves 11 rows standing — the verdict stays RED.

## 5. Doc-gate red: same pair, and #11715 exactly heals it

    gh run view --job 95351629320 --log | grep "FAIL:"

`FAIL: canonical-for 'none' has more than one owner:
./tooling/grip/ledger/build-concurrency-collapse-is-a-fix-w21-2026-08-08.md
./tooling/grip/ledger/graph-draft-leak-payload-verdict-2026-08-17.md`

    git grep -l "canonical-for: none" origin/main

returns exactly those two files — so the pair IS the whole population, and `gh pr diff 11715` renames
both keys (`build-concurrency-collapse-w21`, `graph-draft-leak-payload-verdict`). #11715 is
OPEN/MERGEABLE and also touches the crown double-run prose, i.e. it addresses two of main's four reds.
A wave-69 doc-gate slice would be a duplicate. NOTE for any ledger author: a new row keyed
`canonical-for: none` re-opens this red by construction.
