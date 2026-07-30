# Re-derivation recipes — required-checks selftest + floor vs a 4-context spec (CCH wave 9 verify, 2026-07-30)

All of this must be run against a TRUE `origin/main` tree. The primary checkout at
`/Volumes/SATECHI/github/barkpark` is on a foreign lineage (`a31faa52d`, NOT an
ancestor of `origin/main` `08d4c869a`) and does **not** contain
`scripts/required-checks-floor.sh`. The scripts derive `REPO_ROOT` from
`dirname($0)/..`, so `git show origin/main:… > /tmp/x.sh && bash /tmp/x.sh` resolves
`REPO_ROOT=/` and every clause dies at exit 127 — a vacuous "all fail" that means
nothing.

## R0 — a clean origin/main scratch tree (prerequisite for everything below)

```bash
SP=/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/scratchpad
rm -rf $SP/rcmain
git clone -q -s -n /Volumes/SATECHI/github/barkpark $SP/rcmain
cd $SP/rcmain
git fetch -q --force /Volumes/SATECHI/github/barkpark \
  +refs/remotes/origin/main:refs/remotes/origin/main
git checkout -q --detach origin/main
git rev-parse HEAD          # must equal origin/main in the source repo
```

## R1 — verify --selftest (16 clauses) and the full toolchain harness

```bash
cd $SP/rcmain
bash scripts/required-checks-verify.sh --selftest; echo EXIT=$?   # 16/16 ok, EXIT=0
bash scripts/required-checks.test.sh;             echo EXIT=$?   # 68 passed 0 failed, EXIT=0
```
`required-checks.test.sh` needs `gh` auth (sections 10/11 read live protection).

## R2 — the floor against a 4-context candidate (Console gate + Cloud gate)

```bash
cd $SP/rcmain
git show origin/main:.github/required-checks.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['protection']['required_status_checks']['checks']
c+=[{'context':'Console gate','app_id':15368},{'context':'Cloud gate','app_id':15368}]
json.dump(d,open('/tmp/grow.json','w'),indent=2)"
bash scripts/required-checks-floor.sh /tmp/grow.json;                     echo EXIT=$?  # 2, ADDED x2
bash scripts/required-checks-floor.sh --acknowledge-growth /tmp/grow.json; echo EXIT=$?  # 0
```

## R3 — a DROP is not acknowledgeable (exit 1 both ways)

```bash
git show origin/main:.github/required-checks.json | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d['protection']['required_status_checks']
r['checks']=[x for x in r['checks'] if x['context']!='Elixir gate']+[
  {'context':'Console gate','app_id':15368},{'context':'Cloud gate','app_id':15368},
  {'context':'Extra gate','app_id':15368}]
json.dump(d,open('/tmp/drop.json','w'),indent=2)"
bash scripts/required-checks-floor.sh /tmp/drop.json;                      echo EXIT=$?  # 1 LOST Elixir gate
bash scripts/required-checks-floor.sh --acknowledge-growth /tmp/drop.json; echo EXIT=$?  # 1 — still 1
```

## R4 — THE M3 SELF-RED, and the split between its two causes

```bash
cd $SP/rcmain
cp /tmp/grow.json .github/required-checks.json
bash scripts/required-checks.test.sh 2>&1 | grep -E 'FAIL|passed,'   # 63 passed, 5 failed
git checkout -- .github/required-checks.json
```
Five failures, in two classes:

* **OFFLINE, unfixable by ordering** — sections 6 and 7 derive the spec side from
  the committed file (`jq '.enforced = true' "$SPEC"`) but pair it with heredoc
  `--readback` / `--runs` fixtures that hardcode exactly `Elixir gate` and
  `PR references an active task` (test lines 385-386, 400-401, 444-445, 456-458).
  Reproduce with no network at all:

  ```bash
  bash scripts/required-checks-verify.sh --spec /tmp/grow.json \
    --readback /tmp/iso/rb.json --runs /tmp/iso/runs.json --sha probe; echo EXIT=$?  # 1
  bash scripts/required-checks-verify.sh --spec .github/required-checks.json \
    --readback /tmp/iso/rb.json --runs /tmp/iso/runs.json --sha probe; echo EXIT=$?  # 0
  ```
  M3 must widen those three fixtures in the SAME diff.

* **LIVE, fixed by ordering** — section 11's `bash "$VERIFY"` (full mode, no
  `--spec`) diffs the committed spec against live protection:

  ```bash
  bash scripts/required-checks-verify.sh --spec /tmp/grow.json; echo EXIT=$?  # 1: DRIFT + DEADLOCK
  ```
  Green only once `required-checks-apply.sh --confirm` has actually put the
  4 contexts on the branch. Apply BEFORE the harness runs on the PR.

## R5 — verify --selftest is spec-independent (it does NOT invert)

```bash
cp /tmp/grow.json .github/required-checks.json
bash scripts/required-checks-verify.sh --selftest | tail -2; echo EXIT=$?  # 16/16, EXIT=0
git checkout -- .github/required-checks.json
```

## R6 — the generator would clobber `_readme` and `enforced`

```bash
git show origin/main:scripts/required-checks-generate.sh | sed -n '556,566p'
git show origin/main:.github/required-checks.json | jq '._readme|length, .enforced'
```
Generator emits a 5-entry `_readme` and `enforced: false`; committed file carries
9 entries and `true`. M3 must MERGE the checks array, never overwrite the file.

## R7 — nothing in CI calls the floor

```bash
grep -rn "required-checks-floor" .github/    # no hits outside the spec's own prose
```
Only `required-checks.test.sh` (advisory job, `continue-on-error: true` in
`required-checks-drift.yml`) and hand invocation reach it.
