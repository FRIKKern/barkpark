# Re-derivation — "blocking-shaped" defined, defended, and emitted (V1, 2026-08-19)

Baseline: `origin/main` = `bf499f54b63135b8ae078305b83f2b5b2c078877`.
Prior baseline: `b97663730` (2026-08-08, wave 56) printed `85 55 40 35`.

## R1 — the w56 recipe reproduces, and the number is now 59

```sh
cd <repo> && D=$(mktemp -d) && git archive origin/main | tar -x -C "$D" \
 && sed -n '/^python3 - "\$D"/,/^PY$/p' \
      tooling/grip/ledger/required-checks-residue-census-w56-2026-08-08.md \
    | sed '1d;$d' | python3 - "$D"
# -> 112 81 64 59   (was 85 55 40 35 eleven days earlier)
```
+27 job declarations, +25 residue in 11 days. Six workflows are NEW since the
baseline (`compose-smoke`, `crown-reconcile`, `main-gate-watch`,
`search-template-gates`, `stale-verdict-watch`, `windows-smoke`).

## R2 — w56's R2 has HEALED; do not re-quote it as live

```sh
git show origin/main:.github/required-checks.json | grep -c gofmt        # -> 2  (was 0)
git show origin/main:docs/ops/merge-gates.md | grep -ci 'gofmt\|drift ceiling'  # -> 3 (was 0)
```

## R3 — the literal reading of "blocking-shaped" is NOT what 59 measures

```sh
grep -rn 'name:.*(blocking)' "$D/.github/workflows/" | sed "s#$D/.github/workflows/##"
# -> 21 doc-gates.yml STEP names + security.yml:301 + go-format.yml:47 (2 JOB names)
```
Three JOB names contain "blocking" (`gofmt drift ceiling (blocking)`,
`Sobelow baseline does not swallow its own inline waivers (blocking)`,
`Dependency CVE audit (mix_audit over mix.lock, blocking)`) and ALL THREE carry an
exclusion row. A guard that joins blocking-NAMED jobs against `.exclusions` finds
ZERO today. doc-gates' 21 claims are STEP names inside ONE job
(`Doc budgets + anchors`, itself ledgered S4) and never render as check contexts —
structurally invisible to any job-granularity census.

## R4 — the defended definition and its subtraction ledger

Classifier: `/tmp/v2.py` (source reproduced below the fence in this wave's report).
BLOCKING-SHAPED := a job declaration under `.github/workflows/` that
(1) sits in a workflow triggering on `pull_request`;
(2) has no job-level `if:` statically false for a `pull_request` event;
(3) carries no job-level `continue-on-error`;
(4) does not self-ledger advisory posture in its own name
    (`advisory|report mode|gates nothing|never gates|non-blocking|informational|(skip)`);
(5) is outside required ∪ base-normalised exclusions ∪ transitive `needs:` of a required job;
and whose name contains no `${{ }}` (templated names are UNRESOLVABLE, reported, never
silently counted or dropped).

Subtraction ledger at bf499f54b (112 job declarations in):

| bucket | n |
|---|---|
| X1 not PR-renderable | 17 |
| X2 REQUIRED | 4 |
| X3 ledgered exclusion row | 23 |
| X4 transitive need of a required job | 4 |
| X5 job `continue-on-error` | 5 |
| X6 `if:` statically false on PR (renders SKIPPED, never red) | 5 |
| X7 self-ledgered advisory in its own name | 2 |
| U UNRESOLVABLE templated name | 1 |
| **BLOCKING-SHAPED** | **51** |

Mechanism split of the 51: paths-filtered 46 · runtime-conditional 3 ·
genuinely orphaned (renders on EVERY PR, red-capable, zero merge authority) **2**
(`compose-smoke.yml | Dispatch (compose-smoke paths)`, `pr-task-gate.yml | PR task gate self-test`).

## R5 — the classifier CAN LOSE (mutation, temp tree only)

```sh
cat > "$D/.github/workflows/zzz-planted.yml" <<'Y'
name: Planted
on:
  pull_request:
jobs:
  planted:
    name: Planted invariant gate (blocking)
    runs-on: ubuntu-latest
    steps: [{run: exit 0}]
Y
python3 /tmp/v2.py "$D" | grep -E 'DEFENDED|M3 genuinely'
# -> DEFENDED BLOCKING-SHAPED COUNT: 52
# -> M3 genuinely orphaned ... = 3
```

## R6 — the join is lossy in the OTHER direction too

```sh
# exclusion rows whose context matches no static job name today:
#   Prod compile gate (Elixir 1.18.1 / OTP 27.0)
#   Test (Elixir 1.18.1 / OTP 27.0)
```
Both are matrix-RENDERED names; the declarations are
`Test (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})` etc. A census guard that
does not expand `strategy.matrix` will mis-report 2 live ledger rows as orphaned.

## R7 — sensitivity: the definition, not the tree, moves the number

`/tmp/var.py` at bf499f54b:
`V1 w56 canonical 59 · V2 no needs-closure subtraction 63 · V3 no exclusion subtraction 83 ·
V4 coe ignored 64 · V5 any trigger 76 · V6 exact-context (no base()) 60 · V7 literal "blocking" 3`.
cchi-w57's own brief records naive re-derivations at 47/48/54/76 — V5 (76) is one of them.
