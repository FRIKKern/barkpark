# Orphan shell harnesses — run-all against origin/main (deploy-reliability wave 30)

Ground: origin/main = `02475d0ecaf41f8fcd464c543a07e1825defc090`, run 2026-08-09.
Host: darwin 24.5.0 (no `timeout(1)` on PATH — drop it from any recipe copied here).

## Re-derive the harness inventory and the executed set

```sh
git ls-tree -r --name-only origin/main \
  | grep -E '(test\.sh|_test\.sh|selftest\.sh|-test\.sh)$' | sort        # 32 harnesses
T=$(mktemp -d); git archive origin/main .github | tar -x -C $T
grep -rnE 'bash +[A-Za-z0-9_./-]*(test\.sh|_test\.sh|selftest\.sh|-test\.sh)' \
  $T/.github/workflows | sed "s|$T/||"                                   # 16 distinct executed
```

Orphans = 32 − 16 = **16**. Mentions in a workflow are NOT execution:
`scripts/console-path-escape-check.test.sh` appears 4× in workflow COMMENTS
and is executed nowhere.

## Run them all against a clean archive (never the primary checkout)

```sh
T=$(mktemp -d); git archive origin/main | tar -x -C $T; cd $T; git init -q .
for h in scripts/seal-run.test.sh scripts/pds-ledger-census_test.sh \
         scripts/pds-record-parity.test.sh scripts/pds-scratch-target_test.sh \
         scripts/file-ci-failure-issue.test.sh scripts/registration-sample.test.sh \
         scripts/install-cli.test.sh scripts/fetch-prebuilt.test.sh \
         deploy/site-runtime-install_test.sh tooling/task-obsession/reland_check.test.sh \
         scripts/barkpark-boot-selftest.sh scripts/audit-paper-readers-test.sh \
         tooling/fleet/fleet-run-verdict-test.sh \
         scripts/cloud-path-escape-check.test.sh scripts/elixir-path-escape-check.test.sh \
         scripts/console-path-escape-check.test.sh; do
  echo "=== $h"; bash "$h" >/tmp/h.out 2>&1; echo "RC=$?"; tail -3 /tmp/h.out
done
```

Result 2026-08-09: 15 PASS, **1 FAIL** (`scripts/registration-sample.test.sh`,
`pass 40 fail 3`), 0 unrunnable-in-principle.

`scripts/barkpark-boot-selftest.sh` exits 2 on a bare archive (its differential
half needs the blob `0bff57e4f500e9c9fc99424fa2635ca9988be725:bin/barkpark`).
That is an honest refusal, not a pass, and it clears with one object:

```sh
git -C $T remote add origin /Volumes/SATECHI/github/barkpark
git -C $T fetch -q --depth=1 origin 0bff57e4f500e9c9fc99424fa2635ca9988be725
bash $T/scripts/barkpark-boot-selftest.sh      # -> RC=0
```

## Pin the registration-sample red to the commit that caused it

```sh
P=$(mktemp -d); git archive 0e94b99fe^ | tar -x -C $P
cd $P && bash scripts/registration-sample.test.sh | tail -2   # pass 43  fail 0
```

`0e94b99fe` (PR #11082, merged 2026-08-09T02:18:52Z) added the line
`internal/**` to CLOUD_PATHS in `scripts/cloud-path-escape-check.sh`
(`git show origin/main:scripts/cloud-path-escape-check.sh | sed -n 219p`).
The harness fixture `internal/tui/x.go` was authored as NEITHER-shape
(`scripts/registration-sample.test.sh`, `make_control`), so three
`of which NEITHER` assertions (lines 156, 181, 237) now read one lower than
they expect. The sampler is right; the harness's expectations are stale.

## Required contexts (live, not the workflow's own comment)

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '.required_status_checks.contexts'
# ["Elixir gate","PR references an active task","Cloud gate","Console gate"]
```

`shell-harnesses.yml` publishes none of those four job names — wiring a harness
into it makes it RUN, never BLOCK.

## seal-run

`bash scripts/seal-run.test.sh` → `seal-run.test.sh: 73 passed, 0 failed`, RC=0,
in a historyless `git init` archive. It needs a full WORKING TREE, not full git
history: lines 411-416 read `$ROOT/.github/workflows/cloud.yml` and the real
predicate script, and it builds its own shallow fixture from a `file://` clone.
`actions/checkout@v4` defaults suffice; `fetch-depth: 0` is not required.
