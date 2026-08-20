# cssom-heads.baseline — what the resolver actually does (W19 verify, 2026-08-01)

Base: `origin/main` @ `29cb76e60a189d10ce7dbbbf16bc71b12e1807e4`.
Scratch export (never the checkout — the baseline file is written to):

```sh
S=$(mktemp -d); git archive origin/main | tar -x -C $S
shasum -a 256 $S/cloud/priv/static/app.css      # fc609a38467c… == git show origin/main:…/app.css
grep -nE '^[0-9]+$' $S/cloud/priv/static/__preview__/cssom-heads.baseline   # 287:1256  (exactly ONE)
```

## 1. The D158 sentinel — the tool NAMES 1256

```sh
perl -i -pe 's/^1256$/1/ if $. == 287' $S/cloud/priv/static/__preview__/cssom-heads.baseline
(cd $S && node cloud/priv/static/__preview__/cssom-parity.mjs); echo rc=$?
```

```
   authored rule heads   1256 (baseline 1 ← ABOVE)
   CSSOM style rules     1256
   flattened selectors   1221 authored / 1221 CSSOM
   MISSES                0
!! BASELINE MISMATCH: 1256 authored rule heads, sidecar baseline is 1 (+1255).
   through a reviewed diff. Bump the sidecar to 1256 IN THE SAME COMMIT as the
PARITY FAIL — baseline mismatch with 0 misses · 1.8s wall
rc=1
```

Restored → `authored rule heads 1256 (baseline 1256)`, `PARITY PASS`, rc=0.
Note `flattened selectors 1221/1221` — a number NO prose entry in the sidecar carries;
holders that quote only heads are quoting half the run.

## 2. Two integers resolve to the FIRST, and the pass is SILENT

`parseBaseline` (cssom-parity.mjs:223-229) returns on the first non-`#` line.
Driven end to end through the supported `HEADS_BASELINE=` override:

| sidecar shape | bare-int lines | rc | what it printed |
|---|---|---|---|
| `1256` then `9999` | 2 | **0** | `authored rule heads 1256 (baseline 1256)` · `PARITY PASS` — the tail 9999 is INVISIBLE, no warning |
| `9999` then `1256` | 2 | 1 | `(baseline 9999 ← BELOW)` · `BASELINE MISMATCH … sidecar baseline is 9999 (−8743)` |
| prose only | 0 | 2 | `GUARD (exit 2): baseline sidecar … carries no parseable count.` |
| `<<<<<<< HEAD/1256/=======/1259/>>>>>>>` | 2 | 2 | same GUARD — markers are a non-integer first line |

```sh
printf '# a\n1256\n# b\n9999\n' > $S/probe.baseline
(cd $S && HEADS_BASELINE=$S/probe.baseline node cloud/priv/static/__preview__/cssom-parity.mjs); echo rc=$?
```

**Reading**: ZERO integers and CONFLICT MARKERS are LOUD (exit 2 → the CI wrapper at
`console-harness.yml:363-380` re-raises as exit 1, and `Console gate`'s `decide` line
:637 carries `cssom-parity`). TWO integers with the correct one FIRST is the only
silent shape — and it is exactly the shape a human tail-reader misreads, because every
entry in this file appends prose and the payload sits at the END (line 287 of 287).

## 3. The two-integer shape has never existed in any reachable state

```sh
git log --format=%H origin/main -- cloud/priv/static/__preview__/cssom-heads.baseline   # 18 commits, all ints=1
for r in $(git for-each-ref --format='%(refname)' refs/remotes/origin); do \
  git show "${r}":cloud/priv/static/__preview__/cssom-heads.baseline 2>/dev/null | grep -cE '^[0-9]+$'; done | sort -u
# → refs_with_file=448  anomalies=0
```
(zsh trap: `"$c:path"` eats the `c` — use `"${c}":"$path"`.)

110 local worktrees: all `ints=1`. So "the resolver left TWO on one merge and ZERO on
another" is a HAZARD, not a landed defect — no artifact of it survives anywhere.

## 4. Nothing guards the invariant, and it cannot be unit-tested

`grep -rln parseBaseline` outside worktrees → `cssom-parity.mjs` and the charter (D158)
ONLY. `cssom-parity.mjs` has no `export` at all (`grep -n '^export\|module.exports'` →
empty), so `parseBaseline` is unreachable from a test — same shape as
`citationScanFiles()`. No job, test or script asserts
`grep -cE '^[0-9]+$' cssom-heads.baseline == 1`. That one-line assertion is the whole
fix, and it is mutation-provable with the table in §2.
