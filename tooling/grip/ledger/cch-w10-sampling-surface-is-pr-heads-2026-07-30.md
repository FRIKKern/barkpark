# cch-w10 — the registration sample has always been taken on PR HEADS, not main heads

Re-derivation, 2026-07-30, against `origin/main = dc17c949e`.

## The generator's own sample is two PR heads

```bash
git show origin/main:.github/required-checks.json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['generated_from_shas'])"
# ['08437ad141e2f401da4920921de4001e4e4a5cac', 'ecfd2890b41713e4cecf31302d143e7194cab0dc']

for s in 08437ad141e2f401da4920921de4001e4e4a5cac ecfd2890b41713e4cecf31302d143e7194cab0dc; do
  git merge-base --is-ancestor $s origin/main && echo "$s ancestor" || echo "$s NOT an ancestor"
done
# both: NOT an ancestor
```

The file that registers `Elixir gate` today was generated from two shas neither of
which is on main. Sampling PR heads is not a workaround; it is the shipped practice.

## The generator accepts arbitrary shas and PREFERS a docs-only PR

```bash
git show origin/main:scripts/required-checks-generate.sh | sed -n '38,40p'
#   R2 SAMPLE   … "the cheapest PR to sample (a docs-only one) is the most poisoned."
git show origin/main:scripts/required-checks-generate.sh | grep -n -- '--sha)\|--main-sha)'
# 410:      --sha) SHAS+=("$2"); shift 2 ;;
# 411:      --main-sha) MAIN_SHAS="…"
```
`--sha` is the primary seam and takes any sha. `--main-sha` is a convenience.

## The `_readme` sampling rule never says "main"

```bash
git show origin/main:.github/required-checks.json | python3 -c "import json,sys;print(json.load(sys.stdin)['_readme'][2])"
```
> "Sample at least TWO heads that are POST-SHIM and DISPATCHER-SUCCEEDED … Sample ONE
> head that EXERCISES the Elixir matrix and ONE that SKIPS it."

Post-shim + dispatcher-succeeded + one matrix-exercised + one matrix-skipped. No
"main" anywhere. Wave 9's "post-shim MAIN heads" restatement is a tightening the
artifact does not ask for — and, per the cadence ledger, a tightening that is
unsatisfiable, because both dispatchers hard-code `path set is true` on push events.

## Two digest corrections

* `scripts/required-checks-floor.sh` **EXISTS** on `origin/main`
  (`git show origin/main:scripts/required-checks-floor.sh >/dev/null && echo EXISTS`
  → `EXISTS`). It is not a survey-brief phantom.
* `scripts/registration-sample.sh` does **NOT** exist
  (`git show origin/main:scripts/registration-sample.sh` → fatal). The strategic
  direction describes it as if it were live; it is unbuilt.

## Currently registered contexts

```bash
git show origin/main:.github/required-checks.json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['protection']['required_status_checks']['checks'])"
# [{'context': 'Elixir gate', 'app_id': 15368}, {'context': 'PR references an active task', 'app_id': 15368}]
```
Two. `Console gate` and `Cloud gate` are absent, as wave 9 left them.
