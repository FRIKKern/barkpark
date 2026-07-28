# Re-derivation: the required-checks cardinality floor (honest-gates wave 5 verify, [floor-mutation-proof])

Measured 2026-07-28 on `origin/main` @ `ab396959c`, live GitHub check-run feeds.

## Both harnesses are green today — neither pins a two-name outcome

```sh
bash scripts/required-checks-verify.sh --selftest > /tmp/st.out 2>&1; echo "SELFTEST=$?"
# -> SELFTEST=0   ("SELFTEST OK — every clause can both pass and fail", 16/16)
bash scripts/required-checks.test.sh > /tmp/testsh.out 2>&1; echo "TESTSH=$?"
# -> TESTSH=0     ("required-checks: 55 passed, 0 failed")
```

NOTE: `echo $?` after a pipe reads the LAST command's status. Redirect, then echo.

`required-checks.test.sh:10` claims "hermetic, no network" — false. §10 and §11 run
outside `live_stage` and hit the network:

```sh
grep -n 'gh api\|hermetic, no network' scripts/required-checks.test.sh   # :10 claim, :498 gh api
sed -n '608p' scripts/required-checks.test.sh                            # [ "$LIVE" -eq 1 ] && live_stage  (live_stage starts :535)
```

`required-checks.test.sh:485` labels the selftest "(12 mutation clauses)"; it runs 16.

## The only cardinality assertions that exist

```sh
grep -n 'length\|-lt 2\|min-checks\|expect' scripts/required-checks-generate.sh scripts/required-checks-verify.sh
# verify:74   .protection.required_status_checks.checks | length > 0   <-- ONE name passes
# generate:396  [ "${#SHAS[@]}" -lt 2 ]   <-- a SHA-count floor, not a CHECK-count floor
grep -n '^\s*--[a-z-]*)' scripts/required-checks-generate.sh   # 11 flags; no --expect / --min-checks
grep -n 'Aggregate gate' scripts/required-checks.test.sh
# :257  asserts the emitted spec == ["Aggregate gate"]  <-- test.sh pins a ONE-name outcome, on fixtures
```

## The poison is reachable and silent

```sh
./scripts/required-checks-generate.sh \
  --sha 2053319d3e4bd5618dfc79d0bc6f013d9755a408 \
  --sha cc38bd37bafa3c562ecf50af3a0a34d55ff3fda1 --out /tmp/clean.json
jq -c '.protection.required_status_checks.checks' /tmp/clean.json
# -> [{"context":"Elixir gate","app_id":15368},{"context":"PR references an active task","app_id":15368}]

./scripts/required-checks-generate.sh \
  --sha 2053319d3e4bd5618dfc79d0bc6f013d9755a408 \
  --sha cc38bd37bafa3c562ecf50af3a0a34d55ff3fda1 \
  --sha 7f8ced21cc00f25072bef63d20e6d5f97be5ad3d --out /tmp/poisoned.json; echo "GEN_EXIT=$?"
# -> GEN_EXIT=0
jq -c '.protection.required_status_checks.checks' /tmp/poisoned.json
# -> [{"context":"PR references an active task","app_id":15368}]
```

`Elixir gate` is not recorded in `.exclusions` — it vanishes through the strict
intersection. The whole stderr is one line: `wrote /tmp/poisoned.json (1 required
context(s))`. `--explain` does NOT name the loss either — it prints `ACCEPT Elixir
gate` on 2 of the 3 shas and never says the intersection dropped it:

```sh
./scripts/required-checks-generate.sh --sha 2053319… --sha cc38bd37… --sha 7f8ced21… --explain --out /tmp/p2.json 2>&1 | grep -i 'elixir gate'
# -> two ACCEPT rows, no drop row
```

## The one-name spec is green END TO END

```sh
# spec1.json = poisoned.json with enforced=true; rb1/runs1 = honest fixtures for ONE name
bash scripts/required-checks-verify.sh --spec /tmp/floorproof/spec1.json \
  --readback /tmp/floorproof/rb1.json --runs /tmp/floorproof/runs1.json --sha probe
# -> "ok  required_status_checks.checks match on context AND app_id (1 context(s))"
# -> "OK: live protection, the committed spec and the rendered check names all agree."  exit 0
bash scripts/required-checks-verify.sh --spec … --deadlock
# -> "ok  every required context appears in the 2 name(s) rendered on probe"  exit 0
```

## The superset floor discriminates; a bare count floor does not

Candidate floor (`/tmp/floorproof/floor.sh`): every `{context, app_id}` in the
COMMITTED spec must be present in the candidate.

```sh
bash floor.sh .github/required-checks.json /tmp/clean.json     # FLOOR OK (superset of 2)          exit 0
bash floor.sh .github/required-checks.json /tmp/poisoned.json  # FLOOR REFUSED  lost: Elixir gate  exit 1
# swap specimen: 2 names, 'Elixir gate' -> 'Boundary gate (advisory)'
#   count floor (>=2): PASS (n=2)          <-- misses it
#   superset floor:    REFUSED lost: Elixir gate
# app_id downgrade: {"context":"Elixir gate","app_id":null}
#   superset floor:    REFUSED lost: Elixir gate
```

## Why the floor cannot live unconditionally inside the generator

`required-checks.test.sh:257` asserts the emitted spec is EXACTLY
`["Aggregate gate"]` from synthetic fixtures. An unconditional superset check
inside the generator refuses that:

```sh
bash floor.sh .github/required-checks.json /tmp/floorproof/synth.json
# -> FLOOR REFUSED: lost: Elixir gate / lost: PR references an active task   exit 1
```

So the floor's home is an EXTERNAL committed script (no `--fixture-dir`/`--workflows`
mode to reason about), invoked by the regen step and pinned by `required-checks.test.sh`.
