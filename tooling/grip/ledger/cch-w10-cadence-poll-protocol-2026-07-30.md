# cch-w10 — cadence / pending-slot eviction, and the 1dd553b09 Cloud gate attribution

Re-derivation recipes. Every claim below is reproducible with the command beside it.
Verified 2026-07-30 against `origin/main = dc17c949e`.

## 1. The pending-slot eviction model — CONFIRMED

```bash
for s in 5ddae0dc2 8eef73697 23313e9a5 b71251763 02767b096 1dd553b09 dc17c949e; do
  echo "== $s"
  for wf in console-harness.yml cloud.yml elixir.yml; do
    gh api "repos/FRIKKern/barkpark/actions/workflows/$wf/runs?branch=main&per_page=50" \
      -q ".workflow_runs[]|select(.head_sha|startswith(\"$s\"))|\"  $wf id=\(.id) \(.status)/\(.conclusion) created=\(.created_at) updated=\(.updated_at)\""
  done
done
```

Every cancel timestamp equals (±1-2s) the NEXT run's creation timestamp, per workflow:

| workflow | evicted head | cancelled at | next head created |
|---|---|---|---|
| console-harness | 8eef73697 | 19:25:11 | 23313e9a5 @ 19:25:10 |
| console-harness | 23313e9a5 | 19:25:17 | b71251763 @ 19:25:15 |
| console-harness | b71251763 | 19:25:24 | 02767b096 @ 19:25:23 |
| console-harness | 02767b096 | 19:25:34 | 1dd553b09 @ 19:25:33 |

`cancel-in-progress` is FALSE on main (`github.ref != 'refs/heads/main'`), so this is
not cancel-in-progress. It is the queue: one in-progress + ONE pending; a new arrival
evicts the pending one. cloud.yml's own committed comment already says it —
"Queued main runs collapse to one." A burst measures FIRST and LAST, nothing between.

Verify the group + polarity:
```bash
git show origin/main:.github/workflows/cloud.yml | grep -nA5 '^concurrency:'
```

## 2. A cancelled run emits NO check run at all — CONFIRMED

```bash
for s in b71251763 02767b096 23313e9a5; do echo "== $s"; \
  gh api repos/FRIKKern/barkpark/commits/$s/check-runs --paginate \
  -q '.check_runs[]|select(.name|test("^(Console|Cloud|Elixir) gate$"))|"  \(.name)=\(.conclusion)"'; done
```
Output is empty for all three. Not `cancelled` — ABSENT. `if: always()` cannot rescue
a run that never reached the job graph.

## 3. Spacing floors (completion, not queue), measured

| workflow | fastest | slowest observed |
|---|---|---|
| console-harness | 53s (dc17c949e) | 98s (1dd553b09) |
| cloud | 118s (8eef73697) | 202s (1dd553b09) |
| elixir | 9m31s (dc17c949e) | 16m29s (1dd553b09) |

## 4. The poll protocol that makes a second qualifying head DETERMINISTIC

A sleep is wrong — the floor moved 53s→98s inside one burst. Poll.

```bash
# (0) quiesce BOTH groups on main before merging anything
until [ "$(gh api 'repos/FRIKKern/barkpark/actions/runs?branch=main&per_page=100' \
  -q '[.workflow_runs[]|select(.status!="completed")|select(.path|test("workflows/(console-harness|cloud)\\.yml$"))]|length')" = 0 ]; do sleep 15; done

# (1) merge EXACTLY ONE PR, then pin the head it produced
SHA=$(gh api repos/FRIKKern/barkpark/commits/main -q .sha)

# (2) assert the runs EXIST for that sha — this is the query that separates
#     "not yet" from "paths-filtered" from "shim defect". Absence alone cannot.
until [ "$(gh api "repos/FRIKKern/barkpark/actions/runs?branch=main&per_page=100" \
  -q "[.workflow_runs[]|select(.head_sha==\"$SHA\")|select(.path|test(\"workflows/(console-harness|cloud)\\\\.yml\$\"))]|length")" -ge 2 ]; do sleep 10; done

# (3) wait for BOTH named check runs to COMPLETE on that sha
until [ "$(gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs" \
  -q '[.check_runs[]|select(.name=="Console gate" or .name=="Cloud gate")|select(.status=="completed")]|length')" = 2 ]; do sleep 20; done

gh api "repos/FRIKKern/barkpark/commits/$SHA/check-runs" \
  -q '.check_runs[]|select(.name=="Console gate" or .name=="Cloud gate")|"\(.name) \(.conclusion)"'

# (4) ONLY NOW merge the next PR.
```

Cost: ~200s of wall clock per merge (cloud is the slow leg). Do NOT poll Elixir gate
for this sample — it is not part of the two-gate precondition and costs 9-16 min/merge.

All four queries were executed live at `dc17c949e`; step (0) returned `0`, step (2)
returned `2` (`cloud.yml completed/success`, `console-harness.yml completed/success`),
step (3) returned `2`.

## 5. The 1dd553b09 Cloud gate FAILURE — TRUE POSITIVE, read not inferred

```bash
gh api repos/FRIKKern/barkpark/actions/jobs/90980607573/logs | sed -n '1120,1250p'
```
`1) test the GET census matches the committed baseline
(BarkparkCloud.Web.RouterHeadFenceCensusTest)` —
`total 62 -> 64`, `agent_or_worker 5 -> 7`. `2560 tests, 1 failure`, exit code 2.

Attribution, read from the tree rather than from a commit subject:
```bash
git show --stat --oneline f8bc8f341 | head        # PR #8182 — +74 lines in cloud/.../router.ex
git show f8bc8f341 -- cloud/lib/barkpark_cloud/web/router.ex | grep -E '^\+ *get '
# -> get "/v1/builder/sites/:id/env"   and   get "/v1/agent/sites/:id/env"
git show dc17c949e -- cloud/test/barkpark_cloud/web/router_head_fence_census_test.exs
# -> @baseline_total 62 -> 64, @baseline_machine 5 -> 7
```
Exactly the two agent/worker GET routes the census counted. NOT a gate defect, NOT a
flake: a real regression that had been red on main since #8182 and that nothing
surfaced, because the cloud suite was advisory until #8202. The Cloud gate shim caught
a live escape on its FIRST rendering head. The shim is registrable.

## 6. THE STRUCTURAL FINDING: "touches neither path set" cannot be measured on main

```bash
git show origin/main:.github/workflows/cloud.yml | sed -n '76,90p'
git show origin/main:.github/workflows/console-harness.yml | grep -n -A4 'is not a pull_request'
```
Both dispatchers:
```
if [ "$event" != "pull_request" ]; then
  echo "event '$event' is not a pull_request — the path set is true."
  echo "cloud=true" >> "$GITHUB_OUTPUT"; exit 0
fi
```
On push-to-main the verdict is `true` BY FIAT. Every main head is a full-suite head.
The false branch is unreachable on main, so no number of main heads can ever produce
the required "touches neither path set" sample. That shape lives on PR heads.

And it EXISTS there, in abundance:
```bash
gh api "repos/FRIKKern/barkpark/actions/runs/30579740954/jobs" -q '.jobs[]|"\(.name) \(.conclusion)"'
gh api "repos/FRIKKern/barkpark/actions/runs/30579740632/jobs" -q '.jobs[]|"\(.name) \(.conclusion)"'
gh api repos/FRIKKern/barkpark/commits/6f8c66098/check-runs --paginate \
  -q '.check_runs[]|select(.name|test("^(Console|Cloud|Elixir) gate$"))|"\(.name) \(.conclusion)"' | sort -u
gh api "repos/FRIKKern/barkpark/actions/jobs/90996722649/logs" | grep -E 'changed files:|verdict: cloud='
```
Head `6f8c66098` changed `docs/cli/HANDBOOK.md`, `internal/cli/export_cmd.go`,
`internal/cli/export_cmd_test.go` → `verdict: cloud=false`, `verdict: console=false`,
both suites `skipped`, and **Console gate = success, Cloud gate = success, Elixir gate
= success**. Head `524e5aeca` is the same shape. Two independent qualifying heads of
the exact required shape, both post-shim, both green.

Conclusion for half one: the precondition is SATISFIED on the surface that required
contexts actually gate (PR heads). It is UNSATISFIABLE, forever, on the surface the
wave-9 wording named (main heads). Re-state the precondition over PR heads, or the
wave will wait on evidence that cannot exist.
