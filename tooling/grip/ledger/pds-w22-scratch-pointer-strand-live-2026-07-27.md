# Re-derivation recipe — scratch-pointer strand, RUN-PROVEN (PDS wave 22 verify)

Row: `pds-bl-scratch-pointer-concurrency` · script `scripts/pds-scratch-target.sh` @ origin/main 071d228d7
(worktree copy byte-identical: `git diff origin/main -- scripts/pds-scratch-target.sh` empty).

Cost: two WARM `up`s, 31.5s + 41.7s wall on a host with `api/_build/prod` present. Roots on
`/tmp`, ports auto-picked by `free_port()`. Both roots and both pointers removed afterwards.

## 1. Strand (defect 1 — one global pointer path) — REPRODUCED

```sh
cd /Volumes/SATECHI/github/barkpark
P=/tmp/pds-w22-strand.last
env PDS_SCRATCH_POINTER=$P BARKPARK_HOME=/tmp/pds.sA bash scripts/pds-scratch-target.sh up
cat $P                       # /private/tmp/pds.sA
env PDS_SCRATCH_POINTER=$P BARKPARK_HOME=/tmp/pds.sB bash scripts/pds-scratch-target.sh up
cat $P                       # /private/tmp/pds.sB   <-- silently repointed, no warning
for v in status env verify teardown; do
  env -u BARKPARK_HOME PDS_SCRATCH_POINTER=$P bash scripts/pds-scratch-target.sh $v
done                         # every read verb resolves to B
```

Observed 2026-07-27: A = http :21524 / pg :43814, B = http :22595 / pg :43068. After B's `up`,
`status` printed `root: /private/tmp/pds.sB`; A stayed `http=200` on :21524 with a live
`beam.smp 57303` and `postgres 55984 -D /private/tmp/pds.sA/pgdata`, reachable by NO verb.

Wrong-target teardown, and the second-order strand:

```sh
env -u BARKPARK_HOME PDS_SCRATCH_POINTER=$P bash scripts/pds-scratch-target.sh teardown
# removed /private/tmp/pds.sB ; cleared pointer ; "---- teardown: PASS" ; exit 0
# then: A(21524) http=200, B(22595) http=000, and every verb dies
#       "no scratch target known" — A is now unreachable by the harness entirely.
```

## 2. Defect 2 (`-P` / realpath asymmetry) — ALREADY FIXED, criterion 2 closable

```sh
printf '/private/tmp/pds.sA\n' > $P     # pointer as `up` writes it (canonical)
env PDS_SCRATCH_POINTER=$P BARKPARK_HOME=/tmp/pds.sA \
  bash scripts/pds-scratch-target.sh teardown   # unresolved /tmp alias
# "pds-scratch: cleared scratch pointer /tmp/pds-w22-strand.last" ; teardown: PASS
```

Fix anchors: `canonicalize_path()` at `scripts/pds-scratch-target.sh:213` (definition, TRAP 7 /
PDS-D107) called by `resolve_home` at `:259` and by teardown's pointer compare at `:650`.
Commits `09875840d` (fix) + `970c21527` (review fix: `canonicalize_path('/')` returned empty and
bypassed the `rm -rf` interlock), merged as `c222a8739` / PR #4687, task
`pds-w6-scratch-pointer-canonicalize`.

## 3. Guards that must keep firing (row criterion 3) — both re-fired

- port-release assert: `pds-scratch: port 22595 released` / `port 43068 released` in the run above.
- truncated-`scratch.env` refusal (no boot needed):

```sh
mkdir -p /tmp/pds.sTrunc && : > /tmp/pds.sTrunc/scratch.env
env -u BARKPARK_HOME PDS_SCRATCH_POINTER=/dev/null BARKPARK_HOME=/tmp/pds.sTrunc \
  bash scripts/pds-scratch-target.sh teardown   # exit 1, "refusing to tear down ... does not name both ports"
rm -rf /tmp/pds.sTrunc
```
