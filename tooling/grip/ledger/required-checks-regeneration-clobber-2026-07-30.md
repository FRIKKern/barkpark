# Re-derivation recipes — required-checks regeneration clobber + cp-ops poisoning (wave 9, 2026-07-30)

All commands are read-only. They run against `origin/main` bytes, never the (82-commit-stale) worktree.

## 0. Build the sandbox (the worktree cannot be trusted; `scripts/required-checks-floor.sh` is absent from it)

```sh
R=/tmp/rcroot; rm -rf $R; mkdir -p $R/scripts $R/.github/workflows
cd /Volumes/SATECHI/github/barkpark
git show origin/main:scripts/required-checks-generate.sh > $R/scripts/required-checks-generate.sh
git show origin/main:scripts/required-checks-floor.sh    > $R/scripts/required-checks-floor.sh
git show origin/main:.github/required-checks.json        > $R/committed.json
git ls-tree --name-only origin/main .github/workflows/ | while read f; do git show origin/main:$f > $R/$f; done
git -C $R init -q .; git -C $R remote add origin /Volumes/SATECHI/github/barkpark
git -C $R fetch -q --depth 1 origin main && git -C $R update-ref refs/remotes/origin/main FETCH_HEAD
```

Note: the brief's `bash /tmp/gen.sh` form CANNOT work — the generator derives
`REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"`, so a copy in `/tmp` looks for `/.github/workflows`
and dies `FAIL: the workflow index is empty`.

## 1. Two main heads are NOT a legal sample (fails closed)

```sh
bash $R/scripts/required-checks-generate.sh \
  --sha $(gh api repos/FRIKKern/barkpark/commits/main --jq .sha) \
  --sha $(gh api repos/FRIKKern/barkpark/commits/main --jq '.parents[0].sha') \
  --out $R/x.json --explain
# → FAIL: selection produced ZERO contexts — refusing to emit a spec that protects nothing
```

## 2. The clobber (PR-head sample, the spec's own documented shas)

```sh
bash $R/scripts/required-checks-generate.sh \
  --sha 08437ad141e2f401da4920921de4001e4e4a5cac \
  --sha ecfd2890b41713e4cecf31302d143e7194cab0dc \
  --out $R/cand.json --explain
diff <(python3 -m json.tool $R/committed.json) <(python3 -m json.tool $R/cand.json)
# _readme 9 → 5, enforced true → false, contexts 2 → 6
```

## 3. The floor is blind to both

```sh
jq '._readme=["gone"] | .enforced=false' $R/committed.json > $R/blind.json
bash $R/scripts/required-checks-floor.sh $R/blind.json    # → FLOOR OK, exit 0
grep -c '_readme\|enforced' $R/scripts/required-checks-floor.sh   # → 0
```

## 4. cp-ops.yml poisons the whole workflow index (mutation proof)

```sh
mkdir -p $R/wf_nocpops && cp $R/.github/workflows/*.yml $R/wf_nocpops/ && rm $R/wf_nocpops/cp-ops.yml
bash $R/scripts/required-checks-generate.sh --workflows $R/wf_nocpops \
  --sha 08437ad141e2f401da4920921de4001e4e4a5cac \
  --sha ecfd2890b41713e4cecf31302d143e7194cab0dc --out $R/cand_clean.json --explain
# → 2 contexts, provenance correct (elixir.yml / pr-task-gate.yml), S2/S3/S4 exclusions restored
grep -ln 'name: \${{' $R/.github/workflows/*.yml   # → cp-ops.yml only
git log origin/main --diff-filter=A --format='%h %ad %s' --date=short -- .github/workflows/cp-ops.yml
```

## 5. The M3 diff shape that preserves the prose (proven)

```sh
jq -s '
  .[0] as $c | .[1] as $g | $c
  | .generated_from_shas = $g.generated_from_shas
  | .protection.required_status_checks.checks = $g.protection.required_status_checks.checks
  | .exclusions = ( ($g.exclusions + $c.exclusions) | group_by(.context) | map(.[0]) )
' $R/committed.json $R/cand_clean.json > $R/merged.json
bash $R/scripts/required-checks-floor.sh $R/merged.json   # → FLOOR OK ... identical on context AND app_id
```
