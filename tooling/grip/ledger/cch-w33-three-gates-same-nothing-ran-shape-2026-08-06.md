# cch-w33 — Cloud gate / Console gate / Elixir gate carry the IDENTICAL "concluded success having run nothing" shape

Re-derivation recipes. All commands run from the primary checkout; nothing here mutates anything.

## 1. The required set is FOUR, and three of them are skip-shim aggregators

```
gh api repos/:owner/:repo/branches/main/protection/required_status_checks -q '.contexts[]'
# Elixir gate / PR references an active task / Cloud gate / Console gate
```

## 2. An api-only merged PR (#9529, head 48d960092a65e094de6d0c7fea7f65dd9b322c2a)

```
gh pr list --state merged --limit 60 --json number,files \
  -q '.[]|select([.files[].path]|all(startswith("api/")))|.number' | head -3
gh api "repos/:owner/:repo/commits/48d960092a65e094de6d0c7fea7f65dd9b322c2a/check-runs?per_page=100" \
  -q '.check_runs[]|"\(.name) | \(.conclusion) | ann=\(.output.annotations_count) | title=\(.output.title) | summary=\(.output.summary)"' | sort
```

Decisive rows: `Cloud gate | success | ann=0 | title=null | summary=null` with
`Cloud control-plane (compile + format)` and `(test)` both `skipped`; `Console gate | success |
ann=0 | title=null | summary=null` with `Console client unit harness`, `CSSOM parity`,
`Billing tier floor`, `Overflow guard` all `skipped`.

## 3. The mirror: a cloud-only PR (#9656) greens Elixir gate having run nothing

```
gh api "repos/:owner/:repo/commits/6fce7655e43453d3383a9566186a051d29ecb151/check-runs?per_page=100" \
  -q '.check_runs[]|select(.name|test("Elixir|Test \\(|Prod compile"))|"\(.name) | \(.conclusion) | ann=\(.output.annotations_count) | summary=\(.output.summary)"'
```

## 4. A docs-only PR (#9637) greens ALL FOUR aggregators on nothing

```
gh api "repos/:owner/:repo/commits/7bfeb28da09dd7cac1166133fb6bc638279c777f/check-runs?per_page=100" \
  -q '.check_runs[]|"\(.name) | \(.conclusion) | ann=\(.output.annotations_count) | summary=\(.output.summary)"' | sort
```

`Cloud gate`, `Console gate`, `Elixir gate`, `Security gate` — all `success`, all `ann=0`,
all `summary=null`, with every substantive job `skipped`.

## 5. The gate log says it, the check run does not

```
gh run view 30915142381 --log | grep -E "ok      |Cloud gate:"
gh run view 30915137498 --log | grep -E "ok      |Console gate:"
```

Both print `ok  <job>: skipped — dispatcher said this path set was not touched (gate='false')`
and the closing `… every upstream job either succeeded or was legitimately not dispatched.` —
to the JOB LOG only.

## 6. No gate writes a step summary, and none emits an authored annotation

```
for f in elixir cloud console-harness security; do
  echo "$f: $(git show origin/main:.github/workflows/$f.yml | grep -c GITHUB_STEP_SUMMARY) step-summary, \
$(git show origin/main:.github/workflows/$f.yml | grep -c '::notice') ::notice"
done
```

All four: `0 step-summary, 0 ::notice`. The `ann=1` seen on the path-escape ratchets is NOT authored —
it is the runner's Node-20 deprecation warning:

```
gh api "repos/:owner/:repo/check-runs/$(gh api "repos/:owner/:repo/commits/48d960092a65e094de6d0c7fea7f65dd9b322c2a/check-runs?per_page=100" -q '.check_runs[]|select(.name=="Cloud path-escape ratchet")|.id')/annotations" -q '.[]|"\(.annotation_level) | \(.message)"'
```

## 7. THE FIX SEAM IS ALREADY PROVEN — on the red path only

The gates' `::error::` line DOES reach the checks tab as an annotation:

```
gh run list --workflow=elixir.yml --status=failure --limit 5 --json databaseId,headSha -q '.[]|"\(.databaseId) \(.headSha)"'
gh api "repos/:owner/:repo/commits/8e5e84ede0ff9e57de01a58f484dd66b9397ad43/check-runs?per_page=100" -q '.check_runs[]|select(.name=="Elixir gate")|"\(.conclusion) ann=\(.output.annotations_count) id=\(.id)"'
gh api "repos/:owner/:repo/check-runs/92439730757/annotations" -q '.[]|"\(.annotation_level) | \(.message)"'
# failure | Elixir gate: at least one upstream job is not in the allow-set … RED on purpose.
```

So a symmetric `::notice::` on the green path is a one-line-per-gate change with a working precedent
in the same script. No new mechanism is required.

## 8. Fence arithmetic for the numbered ADD

```
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/cch.md
grep -n "workflows/" /tmp/cch.md          # grants at :133 (console-harness.yml), :193-197 (Wave-11 list)
grep -n "elixir.yml" /tmp/cch.md          # ONLY D-row prose (D89/D99/D100/D116/D119/D130/D137/D138) — zero grants
git log origin/main --oneline -3 -- .github/workflows/elixir.yml
gh pr view 8251 --json files -q '.files[].path'
```

`#8251` (`cch-w10-dispatcher-hardening`, this epic) already merged edits to `elixir.yml`,
`scripts/elixir-path-escape-check.test.sh` and `scripts/cloud-path-escape-check.test.sh` — none of
which the Wave-11 reconciliation names. The fence is stale in exactly the D126 way, a second time.

## 9. Security gate calls itself required, and is not

```
git show origin/main:.github/workflows/security.yml | grep -n "This is the required context"
gh api repos/:owner/:repo/branches/main/protection/required_status_checks -q '.contexts[]' | grep -c '^Security gate$'   # 0
```
