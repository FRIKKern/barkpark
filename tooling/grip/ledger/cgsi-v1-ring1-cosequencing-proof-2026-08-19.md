# cgsi-v1 — Ring 1 co-sequencing: the hermetic suite scans the REAL workflow tree

Fence: `.github/workflows/**` + `scripts/**`. Worktree: detached off `origin/main` @ `bf499f54b6`.
Nothing committed by this row; every mutation lived in an isolated worktree and was removed.

## Q1 — does `required-checks.test.sh --hermetic` assert verify's prose clauses against the REAL tree?

YES. Baseline vs planted, same worktree, same commit:

```sh
WT=<scratchpad>/wt-v1-cosequencing
git worktree add --detach "$WT" origin/main

# baseline
cd "$WT" && bash scripts/required-checks.test.sh --hermetic
#   required-checks: 177 passed, 0 failed (hermetic — the API stage was skipped)   rc=0

# plant a disclaimer about a REQUIRED context into the REAL workflow dir
cat > "$WT/.github/workflows/zzz-v1-probe.yml" <<'YML'
name: V1 Probe
on: [pull_request]
jobs:
  probe:
    # PROBE: `Elixir gate` is ADVISORY here and does not block a merge.
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YML
cd "$WT" && bash scripts/required-checks.test.sh --hermetic
#   required-checks: 173 passed, 4 failed   rc=1
#   §6(a) "the pre-flip case broke (exit 1)", §6(d), §7 "a converged read-back did not verify",
#   §9 "verify --selftest is red"
rm -f "$WT/.github/workflows/zzz-v1-probe.yml"
```

Mechanism: `required-checks-verify.sh:69` sets `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` and
`:86` `WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"`. The suite drives `$VERIFY` at lines
812/818/859/880/885/890/896/928/948/958/1062 WITHOUT `--workflows`, so every one of those runs the
prose clause over the checked-out PR tree. Only §6(d) (line 979) passes it explicitly.

VERDICT: the inverse-prose clause and the doc-gates.yml honest-renaming MUST CO-MERGE in one commit.

## Q2 — the probes-17/18 fixture idiom

Right template, verbatim shape at `required-checks-verify.sh:817-833`: `mkdir -p "$tmp/wf"`,
one heredoc'd `fixture.yml`, `probe … --workflows "$tmp/wf"`, plus the MIRROR probe that goes
green once the spec no longer names the context. Probes 19-21 should copy it exactly, with the
spec-side mutation reading `.exclusions` instead of `.protection.required_status_checks.checks`.

## Q3 — is a disarm mutation provable inside verify's own `--selftest`? NO.

`required-checks-verify.sh:709`:

```sh
out="$(bash "$REPO_ROOT/scripts/required-checks-verify.sh" "$@" 2>&1)" || rc=$?
```

`probe()` re-execs the COMMITTED path, never `$0`. So copy-and-mutate → run the copy's `--selftest`
is VACUOUS — reproduced:

```sh
M="$WT/scripts/zzz-dis.sh"
sed "s|^PROSE_DISCLAIMERS='.*'|PROSE_DISCLAIMERS='ZZZNEVERMATCHZZZ'|" \
  "$WT/scripts/required-checks-verify.sh" > "$M"
cd "$WT" && bash "$M" --selftest       # rc=0, "17/18 … (exit 1)  ok", "SELFTEST OK"
```

(Placing the mutant OUTSIDE the repo instead yields exit 127 on every probe — `REPO_ROOT` then
points at the temp dir; §6(d)'s comment already names this trap.)

WORKING disarm template — invoke the mutant DIRECTLY with explicit args, mutant inside `scripts/`:

```sh
bash "$M" --spec "$T/spec.json" --readback "$T/rb.json" --runs "$T/runs.json" \
          --sha probe --workflows "$T/wf"
# armed original: rc=1, "FAIL: a workflow describes a REQUIRED context as advisory / non-blocking."
# disarmed copy : rc=0, "ok  no workflow calls any of the 2 required context(s) advisory"
```

So the mutation proof for probes 19-21 belongs in `required-checks.test.sh` (§6(d) idiom),
NOT inside verify's own selftest.

## Cleanup

`git -C "$WT" status --porcelain` → 0 after every experiment. Primary checkout never touched
(`git status --porcelain | grep -i 'zzz-v1\|wt-v1'` → no matches).
