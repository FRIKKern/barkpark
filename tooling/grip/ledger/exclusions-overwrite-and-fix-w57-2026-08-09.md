# Re-derivation recipes — the `.exclusions` overwrite, its two-line fix, and the "35" figure (wave 57)

Baseline: `origin/main` = `0239dd4ee662dd30c4d8da0c6b9a149638224b1d`.
All commands assume cwd = repo root and `git fetch origin main` has run.
Nothing below reads the working tree: every input is extracted from `origin/main`.

## R0 — build the isolated synthetic root

```sh
R=$(mktemp -d); mkdir -p "$R/scripts" "$R/.github/workflows"
git show origin/main:scripts/required-checks-generate.sh > "$R/scripts/required-checks-generate.sh"
git show origin/main:.github/required-checks.json      > "$R/.github/required-checks.json"
for f in $(git ls-tree --name-only origin/main .github/workflows/); do git show "origin/main:$f" > "$R/$f"; done
mkdir -p "$R/scripts/fixtures/registration-flip"
for f in $(git ls-tree --name-only origin/main scripts/fixtures/registration-flip/); do git show "origin/main:$f" > "$R/$f"; done
GENARGS=(--workflows "$R/.github/workflows" --fixture-dir "$R/scripts/fixtures/registration-flip"
         --merge-base "$R/.github/required-checks.json" --sha e34031104 --sha f69cfb1f6
         --expect-unrendered "Elixir gate" --expect-unrendered "PR references an active task")
```

The fixture pair is the repo's OWN frozen sample (`scripts/fixtures/registration-flip`),
the one `scripts/required-checks.test.sh` §14 uses. No network, no `gh`.

## R1 — the overwrite, reproduced: 25 exclusion rows in, 18 out, exit 0, ZERO stderr

```sh
jq '.exclusions|length' "$R/.github/required-checks.json"          # -> 25
bash "$R/scripts/required-checks-generate.sh" "${GENARGS[@]}" --out "$R/out-baseline.json" 2>"$R/err.txt"
echo "exit=$?  stderr_bytes=$(wc -c < "$R/err.txt")"               # -> exit=0  stderr_bytes=0
jq '.exclusions|length' "$R/out-baseline.json"                     # -> 18
comm -23 <(jq -r '.exclusions[].context' "$R/.github/required-checks.json"|sort) \
         <(jq -r '.exclusions[].context' "$R/out-baseline.json"|sort)
```

The seven lost rows:

```
Dispatch (changed-path sets)
Elixir path-escape ratchet
Format (mix format --check-formatted, advisory) (27.0, 1.18.1)
gofmt drift ceiling (blocking)
Prod compile gate (Elixir 1.18.1 / OTP 27.0)
Test (Elixir 1.18.1 / OTP 27.0)
Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)
```

The run reports `wrote … (4 required context(s); 2 from this sample, the rest carried
by the merge)`. It names the merge that carried the CHECKS and says nothing at all about
the seven exclusion rows it dropped. `git show origin/main:scripts/required-checks-generate.sh
| grep -n 'lost\|LOSS'` returns nine hits, every one inside the S1-LOSS block, which keys
solely on `committed_required` — the check list. No refusal in the file keys on exclusions.

## R2 — the two-line base-first union: 25 in, 25 out, gofmt row survives

The single edited line is `:920` in `scripts/required-checks-generate.sh`:

```
-        exclusions: $exclusions
+        exclusions: (((($b.exclusions) // []) + $exclusions) | unique_by(.context))
```

```sh
sed 's|^        exclusions: \$exclusions$|        exclusions: (((($b.exclusions) // []) + $exclusions) | unique_by(.context))|' \
  "$R/scripts/required-checks-generate.sh" > "$R/scripts/gen-fixed.sh"   # verify with: grep -n 'exclusions: ((' "$R/scripts/gen-fixed.sh"
bash "$R/scripts/gen-fixed.sh" "${GENARGS[@]}" --out "$R/out-fixed.json"
jq '.exclusions|length' "$R/out-fixed.json"                                            # -> 25
jq -r '.exclusions[]|select(.context=="gofmt drift ceiling (blocking)")|.context' "$R/out-fixed.json"
                                                                                       # -> gofmt drift ceiling (blocking)
```

## R3 — REVERT: the same run on the unmodified generator loses it again

```sh
bash "$R/scripts/required-checks-generate.sh" "${GENARGS[@]}" --out "$R/out-revert.json"
jq '.exclusions|length' "$R/out-revert.json"                                           # -> 18
jq '[.exclusions[]|select(.context=="gofmt drift ceiling (blocking)")]|length' "$R/out-revert.json"
                                                                                       # -> 0
```

## R4 — base-first DOES buy immortality and staleness (the design question, measured)

Plant a stale reason on a real row and a ghost row no workflow publishes, then regenerate
with the FIXED generator:

```sh
jq '.exclusions |= (map(if .context=="gofmt drift ceiling (blocking)"
                        then .reason="S9 STALE REASON PLANTED BY PROBE" else . end)
                    + [{context:"Ghost gate that no workflow publishes",
                        reason:"S4 PATHS-FILTERED: planted, no such job exists"}])' \
  "$R/.github/required-checks.json" > "$R/base-stale.json"
bash "$R/scripts/gen-fixed.sh" --workflows "$R/.github/workflows" \
  --fixture-dir "$R/scripts/fixtures/registration-flip" --merge-base "$R/base-stale.json" \
  --sha e34031104 --sha f69cfb1f6 \
  --expect-unrendered "Elixir gate" --expect-unrendered "PR references an active task" \
  --out "$R/out-stale.json"
jq -r '.exclusions[]|select(.context=="gofmt drift ceiling (blocking)")|.reason' "$R/out-stale.json"
                                                     # -> S9 STALE REASON PLANTED BY PROBE
jq -r '.exclusions[]|select(.context|startswith("Ghost"))|.context' "$R/out-stale.json"
                                                     # -> Ghost gate that no workflow publishes
jq '.exclusions|length' "$R/out-stale.json"          # -> 26
```

`unique_by` keeps the FIRST occurrence, and base is first — so the base's `reason` wins
over a freshly derived one. A row whose stage changes (S4 -> S2, or S5 -> promoted) keeps
its old reason forever, and a row for a job that no longer exists never leaves.

## R5 — neither the overwrite NOR the fix is detectable by the repo's own harness

```sh
D=$(mktemp -d); git archive origin/main | tar -x -C "$D"
bash "$D/scripts/required-checks.test.sh" --hermetic 2>&1 | tail -1
#   required-checks: 166 passed, 0 failed (hermetic — the API stage was skipped)
python3 - "$D" <<'PY'
import sys; p=sys.argv[1]+"/scripts/required-checks-generate.sh"; s=open(p).read()
old="        exclusions: $exclusions\n"
new="        exclusions: (((($b.exclusions) // []) + $exclusions) | unique_by(.context))\n"
assert s.count(old)==1; open(p,"w").write(s.replace(old,new))
PY
bash "$D/scripts/required-checks.test.sh" --hermetic 2>&1 | tail -1
#   required-checks: 166 passed, 0 failed (hermetic — the API stage was skipped)
```

Identical verdict both ways. The fix is landable — it breaks nothing — and it arrives
UNGUARDED: nothing in 166 assertions can tell the fixed generator from the lossy one, so
a later revert is as silent as the loss it repairs.

## R6 — the "35 blocking-shaped names" figure IS derivable, and is 34 today

The recipe is the one published in
`tooling/grip/ledger/required-checks-residue-census-w56-2026-08-08.md` §R1, run verbatim
(needs `python3` + `pyyaml`). Output is `<jobs> <residue> <pr-renderable> <blocking>`:

```sh
for SHA in b97663730 085cc8719^ 085cc8719 0239dd4ee; do
  D=$(mktemp -d); git archive "$SHA" | tar -x -C "$D"
  printf '%s: ' "$SHA"; python3 /path/to/w56-R1-census.py "$D" | head -1; rm -rf "$D"
done
```

```
b97663730 : 85 55 40 35     <- the ledger's stated baseline; reproduces EXACTLY
085cc8719^: 85 55 40 35
085cc8719 : 85 54 39 34
0239dd4ee : 85 54 39 34     <- origin/main today
```

The one name that left the residue set:

```sh
comm -23 <(census b97663730|tail -n +2|sort) <(census 0239dd4ee|tail -n +2|sort)
#   go-format.yml | gofmt drift ceiling (blocking)
```

THE FIGURE WAS FALSE IN THE COMMIT THAT WROTE IT. `085cc8719` is the commit whose
`.github/required-checks.json` exclusion reason ends "…35 such names exist today", and it
is the same commit that added the `gofmt drift ceiling (blocking)` exclusion row, which
subtracts that name from the residue set. Before it: 35. After it: 34. The sentence
described the tree it was replacing, not the tree it shipped.

```sh
git log --oneline origin/main -S"gofmt drift ceiling" -- .github/required-checks.json
#   085cc8719 fix(ci): pr-task-gate stops concluding success having evaluated nothing (cch-w56-s4) (#11016)
git diff --stat 085cc8719 origin/main -- .github/workflows/ .github/required-checks.json
#   (empty — the 35->34 move is 085cc8719's own doing, not later drift)
```
