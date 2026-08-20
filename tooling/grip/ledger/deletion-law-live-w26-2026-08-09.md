# deletion-law-live — re-derivation recipes (wave 26 verify, 2026-08-09)

Ground: `origin/main` @ `0239dd4ee662dd30c4d8da0c6b9a149638224b1d`.
NOTE: the primary checkout was at `0789ab90a`, **717 commits behind origin/main**
(`git rev-list --count --left-right origin/main...HEAD` -> `717	49`), so every
recipe below reads `origin/main` explicitly or runs inside the `w26seal`
worktree pinned at `0239dd4ee`. A recipe run in the primary checkout reads a
different tree and is not a claim about main.

## R1 — rider 1 re-derived: OPEN + not CONFLICTING + checks on the CURRENT head

    gh pr view 10811 --json number,state,mergeable,mergeStateStatus,headRefOid
    gh pr view 11007 --json number,state,mergeable,mergeStateStatus,headRefOid
    gh pr view 11008 --json number,state,mergeable,mergeStateStatus,headRefOid

All three: `state=OPEN`, `mergeable=CONFLICTING`, `mergeStateStatus=DIRTY`.

    gh api "repos/FRIKKern/barkpark/commits/<headRefOid>/check-runs?per_page=100" \
      -q '[.check_runs[]|.conclusion]|group_by(.)|map({(.[0]//"null"):length})|add'
    gh api "repos/FRIKKern/barkpark/commits/<headRefOid>/check-runs?per_page=100" \
      -q '[.check_runs[].completed_at]|sort|last'

  * bd102bb3 (#10811): 36 runs, `{"skipped":11,"success":25}`, last 2026-08-08T11:42:08Z
  * 58a49c46 (#11007): 36 runs, `{"skipped":7,"success":29}`,  last 2026-08-08T16:39:37Z
  * 2a3e1241 (#11008): 32 runs, `{"skipped":7,"success":25}`,  last 2026-08-08T16:40:46Z

Clause 2 ("ran against the CURRENT head sha") is SATISFIED by all three — the
runs are attached to the live head. Only clause 1 fails them. The green is
frozen against a base that no longer exists (the lead's merge burst is
23:46–23:48Z 2026-08-08, hours after the newest run above), and nothing
re-dispatches. Rider 1 needs a THIRD clause about the BASE, not the head.

## R2 — the three unstayed instruments have zero readers, anywhere

    git grep -rn 'publish_clock\|build_slots\|runner_queue_len\|publishClock\|buildSlots\|runnerQueueLen\|PublishClock\|BuildSlots\|RunnerQueueLen' \
      origin/main -- internal/ js/ web/ cloud/priv/    # EMPTY
    git grep -rn '<same alternation>' \
      origin/main -- apps/ sdk/ packages/ docs-site/ connectors/ templates/ scaffy/ cmd/ scripts/ design/   # EMPTY
    git grep -n '<same alternation>' origin/main -- api/    # hits: controller + router comment + 2 test files ONLY

Grep-technique control (proves the zero is real, not a pattern artifact) — the
SIBLING route on the same pipeline DOES have a Go consumer:

    git grep -rn 'instance/request-stats' origin/main -- internal/
    # internal/agent/report.go:639: const requestStatsPath = "/v1/instance/request-stats"

    git grep -rn 'instance/site-deploy' origin/main
    # router.ex:1643 (the route), its own test, deploy_runner.ex comment, charter, one ledger row. ZERO consumers.

## R3 — census.Raw: is verbatim passthrough a reader?

    git show origin/main:internal/cloudclient/client.go | sed -n '2258,2263p'   # census.Raw = body
    git show origin/main:internal/cli/cloud_deploy_census_cmd.go | sed -n '219,228p'
    git grep -rn 'coalesc' origin/main -- internal/    # ZERO hits on 'coalesced_attempts'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '890,895p'  # :893 emits it

## R4 — the census is GREEN on main today (so a deletion is visible to it)

    git worktree add <scratch>/w26seal 0239dd4ee
    ln -s <primary>/cloud/deps <scratch>/w26seal/cloud/deps     # mix.lock/mix.exs identical to HEAD
    cd <scratch>/w26seal/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/payload_key_set_census_test.exs
    # => 13 tests, 0 failures  (8.5s)
