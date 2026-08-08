# Re-derivation recipe — "a merge to main that never got a deploy run" (wave 20, verifier v3a)

Window pinned: `2026-07-09` .. `2026-08-08` (repo `barkpark`, branch `main`).

## 0. The trap this recipe exists to avoid

`gh api --paginate ".../deploy.yml/runs?branch=main&created=>=2026-07-09"` returns **exactly 1000**
rows and silently stops at `2026-07-14T21:10:01Z`. The Actions runs API caps *pagination* at 1000
per query, not per page. You must split the window and union.

```sh
gh api --paginate "repos/:owner/:repo/actions/workflows/deploy.yml/runs?branch=main&per_page=100&created=%3E%3D2026-07-09" \
  --jq '.workflow_runs[]|[.id,.head_sha,.conclusion,.created_at,.updated_at]|@tsv' > /tmp/v3a.tsv   # 1000 rows, truncated
gh api --paginate "repos/:owner/:repo/actions/workflows/deploy.yml/runs?branch=main&per_page=100&created=2026-07-09..2026-07-15" \
  --jq '.workflow_runs[]|[.id,.head_sha,.conclusion,.created_at,.updated_at]|@tsv' > /tmp/v3b.tsv   # 424 rows
cat /tmp/v3a.tsv /tmp/v3b.tsv | sort -u -t$'\t' -k1,1 > /tmp/v3all.tsv   # 1375 rows, continuous
```
Windows must OVERLAP (a starts 07-14T21:10Z, b ends 07-15T23:28Z) or the union has a hole you
cannot see.

## 1. The push oracle (the load-bearing trick)

You cannot ask GitHub "which pushes happened". You can ask a workflow that fires on EVERY push to
main with no `paths:` filter. Two exist:

* `.github/workflows/elixir.yml` — `on: push: branches: [main]`, no paths, unchanged since
  2026-04-28. Covers the whole window. **Use this one.**
* `.github/workflows/breakglass-watch.yml` — same shape but only exists since 2026-07-28.
  Good independent second opinion for the tail.

```sh
for w in 2026-07-09..2026-07-14 2026-07-15..2026-07-20 2026-07-21..2026-07-26 \
         2026-07-27..2026-08-01 2026-08-02..2026-08-08; do
  gh api --paginate "repos/:owner/:repo/actions/workflows/elixir.yml/runs?branch=main&event=push&per_page=100&created=$w" \
    --jq '.workflow_runs[]|[.head_sha,.created_at]|@tsv'
done > /tmp/v3elx.tsv        # 2266 rows == 517+590+401+422+336, so no window hit the 1000 cap
```
Always verify each sub-window's `.total_count` is < 1000 before trusting the union.

## 2. Path matching must use the filter AS OF THAT COMMIT, and push ranges, not commits

Two ways to get this wrong:

* **Era drift.** `deploy.yml`'s `on.push.paths` grew during the window:
  `02c28b7a880f` (07-14) added `connectors/**`, `fb1cc68f4f0f` (07-16) added `templates/**`,
  `96879b11cd36` (07-24) added `cmd/**`. Grading July commits with today's list manufactures
  ~26 fake "misses" (all templates/ and cmd/ merges that correctly did not deploy).
  Select the era with `git merge-base --is-ancestor <era-sha> <commit>`.
* **`git diff-tree -m --first-parent` DOES NOT honour `--first-parent`.** It emits the diff against
  *every* parent concatenated, so merge commits pick up files changed on the main side that were
  already deployed. Use `git log -m --first-parent --name-only` (or `git diff <sha>^1 <sha>`).

GitHub evaluates `paths` over the push's `before..after` range, not per commit. Reconstruct each
push range as "all first-parent commits from the previous oracle head (exclusive) to this oracle
head (inclusive)" and union their first-parent diffs.

## 3. The verdict, and how to re-derive it

| quantity | value |
|---|---|
| pushes to main (oracle) | 2264 on main first-parent (+2 rebased away) |
| path-matching pushes (before..after, era-local) | 1373 |
| of those, with NO deploy.yml run | **0** |
| deploy.yml runs whose head is not an oracle push head | 0 |
| model residue (deploy run my filter model calls non-matching) | 2 |

`merge-without-a-run` is REFUTED over 30 days. Independent confirmation on 2026-07-28..08-07 with
the breakglass oracle: 641 pushes, 394 path-matching, 394 deploy runs, 0 missing.

Cheap re-check when a per-sha doubt arises (authoritative, pagination-free):
```sh
gh api "repos/:owner/:repo/actions/workflows/deploy.yml/runs?head_sha=<sha>" --jq '.total_count'
gh api "repos/:owner/:repo/actions/runs?head_sha=<sha>&per_page=100" \
  | jq -r '.workflow_runs[]|[.name,.event,.head_branch,.conclusion]|@tsv'
```
A sha with `total_count 0` on deploy.yml AND zero rows on the second call was never a push head —
it rode inside a multi-commit push whose tip did run. 115 of the 128 naive-model misses are this.

## 4. Cancellations: eviction, not interruption

```sh
gh api --paginate "repos/:owner/:repo/actions/workflows/deploy.yml/runs?branch=main&per_page=100&created=%3E%3D2026-08-01" \
  --jq '.workflow_runs[]|[.id,.conclusion,.created_at,.run_started_at,.updated_at]|@tsv' > /tmp/v3rich.tsv
for id in $(awk -F'\t' '$2=="cancelled"{print $1}' /tmp/v3rich.tsv); do
  printf '%s %s\n' "$id" "$(gh api "repos/:owner/:repo/actions/runs/$id/jobs" --jq '.total_count')"
done
```
All 94 cancelled runs since 2026-08-01 report `jobs=0` — no job was ever created, so nothing was
interrupted mid-flight. Lifetime `updated_at - created_at`: cancelled p50 **8s** / p95 52s / max
192s versus success p50 322s. `concurrency.cancel-in-progress: false` keeps ONE pending slot per
group; a third arrival evicts the pending run. Do not read `cancelled` as "a deploy was killed".

Coverage check for the evicted heads (0 uncovered, p50 9.1 min, max 49.96 h — the July blackout):
see the python block in the wave-20 verifier transcript; the rule is "a later success whose head is
a descendant (lower index in `git log --first-parent`) and whose `updated_at` is after the
cancelled run's `created_at`".
