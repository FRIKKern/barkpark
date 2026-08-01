# Re-derivation recipes — foreign reds (CCH W19 verify, 2026-08-01)

Three report-only items. None is adoptable by wave 19. All recipes below were
run against `origin/main` = `29cb76e60a189d10ce7dbbbf16bc71b12e1807e4`.

## R1 — the Cloud gate red IS a cross-test `capture_log` race (mechanism proof)

The CI failure's own output names both sides:

```bash
gh run view --job 91391165466 --log | cut -d$'\t' -f2- | sed -n '1160,1170p'
```
Expect `assert log == ""` at `test/barkpark_cloud/push/fanout_result_test.exs:46`
with `left:` carrying the template-freshness warning — an assertion in
`BarkparkCloud.Push.FanoutResultTest` capturing a log emitted by
`BarkparkCloud.Sites.TemplateFreshnessWorker`.

Both files are `async: true`:

```bash
git show origin/main:cloud/test/barkpark_cloud/push/fanout_result_test.exs | sed -n '19,21p'
git show origin/main:cloud/test/barkpark_cloud/sites/template_freshness_worker_test.exs | sed -n '20p'
```

Deterministic proof that `capture_log` is process-global (does NOT need the
scheduler to cooperate). Write `cap.exs` OUTSIDE the repo, then:

```elixir
# cap.exs
require Logger
ExUnit.start(autorun: false)
import ExUnit.CaptureLog
log = capture_log(fn ->
  Task.await(Task.async(fn -> Logger.warning("FOREIGN-EMITTER-FROM-ANOTHER-TEST") end))
  Process.sleep(50)
end)
IO.puts("CAPTURED_BY_FOREIGN_PROCESS=#{inspect(log =~ "FOREIGN-EMITTER-FROM-ANOTHER-TEST")}")
```
```bash
cd cloud && CC=clang MIX_ENV=test mix run --no-start /abs/path/cap.exs
# CAPTURED_BY_FOREIGN_PROCESS=true
```

## R2 — the SCHEDULE half does not reproduce on demand (state this honestly)

```bash
cd cloud
CC=clang mix test test/barkpark_cloud/push/fanout_result_test.exs              # alone
for i in $(seq 1 12); do CC=clang mix test --max-cases 8 \
  test/barkpark_cloud/push/fanout_result_test.exs \
  test/barkpark_cloud/sites/template_freshness_worker_test.exs; done           # pair
for i in 1 2 3; do CC=clang mix test --max-cases 8; done                       # full suite
```
Observed 2026-08-01: 0 failures in 1 + 12 + 3 runs; the full suite reports
`2641 tests, 0 failures`, the same test count CI ran. Base rate on main is
1 failure in 29 completed `cloud.yml` runs (~3.4%), so three full-suite
attempts have only a ~10% chance of tripping it. NOT REFUTED — UNREPRODUCED.

```bash
gh run list --workflow=cloud.yml --branch main --limit 40 \
  --json conclusion --jq '[.[].conclusion]|group_by(.)|map({(.[0]):length})|add'
# {"cancelled":11,"failure":1,"success":28}
```

**Setup gotcha:** a stale local checkout will run the WRONG code. On 2026-08-01
the primary checkout was 283 commits behind and its
`template_freshness_worker_test.exs` was missing 135 lines. Build a detached
worktree at `origin/main` in scratchpad, copy `cloud/deps` + `cloud/_build` in,
and `MIX_ENV=test mix compile` before believing any local green.

## R3 — count Sobelow from the DECIDING command's own step, never the job log

```bash
gh run view --job 91391321816 --log > /tmp/sob.log
grep -c 'File:' /tmp/sob.log                    # 127  <-- WRONG, four scans pooled
cut -d$'\t' -f2- /tmp/sob.log | grep -n '\[group\]'   # find step boundaries
sed -n '1352,1604p' /tmp/sob.log | grep -c 'File:'    # 24  <-- the deciding scan
```
The deciding step is `Run mix sobelow --skip --exit Low`; it ends
`##[error]Process completed with exit code 1`. The other 103 `File:` lines come
from `sobelow-baseline-reconcile.sh` (78) and `sobelow-fresh-finding-guard.sh` (25).

24 findings = 3 High-Confidence `Config.CSRF` (all `lib/barkpark_web/router.ex`,
pipelines `media_mutate`:604, `user_auth`:545, `session_token_root`:521) + 21 Low.
The job FAILED while its rollup `Security gate` (job 91391503209) reported
`success` — rollup blindness, again.

## R4 — the PDS `elixir.yml` coordination constraint is a PHANTOM

Diff each branch against ITS MERGE-BASE, never against `origin/main` directly —
a plain `git diff origin/main..<branch>` on a branch that is merely BEHIND
manufactures 19 false hits (one-sided diff read).

```bash
for r in $(git ls-remote --heads origin 'pds*' 'epic-charter/pds*' 'loop-epic/pds*' \
             'charter/pds*' 'docs/pds*' 'lead/pds*' | awk '{print $2}'); do
  b=${r#refs/heads/}; mb=$(git merge-base origin/main origin/$b) || continue
  n=$(git diff --name-only $mb origin/$b -- .github/workflows/elixir.yml | wc -l)
  [ "$n" != 0 ] && echo "CHANGED-BY-BRANCH: $b"
done
gh pr list --state open --limit 100 --json number,files \
  --jq '.[]|select((.files//[])[].path==".github/workflows/elixir.yml")|.number'
```
Both print nothing. 0 of 25 PDS-named branches, 0 of 9 open PRs. There is
nothing to sequence around; drop "land it last" from the wave's constraints.
