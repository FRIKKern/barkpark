# watch-drain-and-trend-source — re-derivation recipes (2026-08-09, wave 29 verify)

Every row below is a command, not a sentence. Run it; the population moves hourly.

## 1. Re-derive the stale-verdict population AT PRINT TIME

```sh
git show origin/main:scripts/stale-verdict-watch.sh > /tmp/svw.sh
git show origin/main:.github/required-checks.json > /tmp/rc.json
bash /tmp/svw.sh --repo FRIKKern/barkpark --spec /tmp/rc.json; echo "EXIT=$?"
```

Reading at 2026-08-09, origin/main `c2de1e51cd029d3f47717eec6c53a81b55970364`:

```
POPULATION, re-derived at run time (never baked):
  36 open · 25 CONFLICTING · 11 MERGEABLE · 0 UNKNOWN after re-polling
RED — 23 CONFLICTING pull request(s) assert a green required verdict main has moved past.
EXIT=1
```

Trajectory of the same number: 20 @ 08:58Z → 23 @ 11:41Z → 23 @ this run (open fell 38→36).
The reported count is NOT the population: 23 reported of 25 CONFLICTING of 36 open. Quote all three
or the number is unreadable.

## 2. The rc=2 laundering path (the watch CAN still lie green)

```sh
git show origin/main:.github/workflows/stale-verdict-watch.yml | grep -n '2) echo'
```

`2) echo "::warning::rows were still mergeable=UNKNOWN after re-polling…"; exit 0`

A read that classified NOTHING exits 0. Run 31311358759 concluded `success` on that path.

## 3. Do the three D493 closes lose anything? (diff added symbols vs origin/main — never trust the sentence)

```sh
for n in 11007 11008 11174; do
  H=$(gh pr view $n --json headRefOid --jq .headRefOid)
  for f in $(gh api repos/FRIKKern/barkpark/pulls/$n/files --jq '.[].filename'); do
    gh api "repos/FRIKKern/barkpark/contents/$f?ref=$H" --jq .content | base64 -d > /tmp/head.f
    git cat-file -e origin/main:"$f" 2>/dev/null && git show origin/main:"$f" > /tmp/main.f || continue
    diff /tmp/main.f /tmp/head.f | grep '^>' \
      | grep -oE '(func Test[A-Za-z0-9_]+|test "[^"]+")' | sort -u \
      | while IFS= read -r s; do git grep -qF -- "$s" origin/main || echo "ABSENT [$f]: $s"; done
  done
done
```

TWO TRAPS this recipe exists to defeat, both of which bit the first pass:

- **A length-capped title regex under-reports.** `test "[^"]{10,70}"` silently dropped
  #11174's 97-char empty-fleet title. Use `[^"]+`, never a cap.
- **grep-exact reads a RENAME as an absence.** Every one of the 5 ABSENT hits below is a rename
  or a documented deletion, not a loss. Resolve each by hand before quoting it.

Resolution of all 5, each verified against origin/main:

| PR | ABSENT symbol | verdict |
|---|---|---|
| 11007 | `func TestPlatformDeliveriesPendingKeySetDeltaIsExactlyTheThreeQueuedColumns` | **deliberately deleted** — main `internal/cli/cloud_deliveries_cmd_test.go:729-741` names it and explains: its prediction landed with #10942, so it became a permanently-satisfied copy. Replaced by `TestPlatformDeliveriesTheQueueSplitIsLiveAndSitsBesideTheTotal`. NO LOSS. |
| 11008 | `test "the index in the DATABASE names all three columns"` | **renamed + strengthened** on main as `…all three key columns` (`platform_delivery_test.exs:331`), which additionally asserts `UNIQUE` and regexes the btree column list. NO LOSS. |
| 11174 | `test "a send that supplied no reading says so — …clean fleet"` | renamed on main `:492` (`…clean team`). NO LOSS. |
| 11174 | `test "an unreadable ledger renders UNMEASURED with the failure's own words"` | renamed on main `:531` (`…and the digest still goes out`); body still asserts the reason string. NO LOSS. |
| 11174 | `test "an empty fleet still reports deploy health — sites deploy even when no instance is registered"` | main has `:317` empty-fleet-renders and `:651` owns-no-sites. **The PR's distinct case — instances empty WHILE sites exist — is the one not obviously covered.** Only genuinely-open question of the three closes. |

## 4. #11169 is NOT a close — it adds content main lacks

```sh
gh api repos/FRIKKern/barkpark/pulls/11169/files --jq '.[].filename' | wc -l   # => 1
H=$(gh pr view 11169 --json headRefOid --jq .headRefOid)
gh api "repos/FRIKKern/barkpark/contents/cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs?ref=$H" --jq .content | base64 -d > /tmp/h.exs
git show origin/main:cloud/test/barkpark_cloud/reader_less_instrument_census_test.exs > /tmp/m.exs
diff /tmp/m.exs /tmp/h.exs | grep '^>' | grep -E 'test "|defp |@[a-z_]+ '
```

Conflicts in EXACTLY ONE file (confirmed: the `--jq` above prints 1). 907 lines on main → 1144 on head.
Adds `@landed_prs`, `@id_shape`, `@id_citation`, `@citation`, `@verdicts`, `@verdict_window`,
`defp window_after`, `defp trim_to_valid`, and four guards including
`test "every task id in this file is a FULL slug"` and
`test "no id or PR number is followed by a verdict"`. Rebase; do not close.

NOTE the zsh trap: an unquoted URL containing `?` is glob-eaten —
`(eval):6: no matches found: repos/…?ref=…`. Always quote the `gh api` path.

## 5. Where a trend would read its prior value

```sh
git show origin/main:.github/workflows/stale-verdict-watch.yml | grep -nE 'permissions|actions:|artifact|cache'
# => 76 permissions: / 77 contents: read / 80 pull-requests: read / (checks: read)
#    NO actions:, NO artifact, NO cache
git show origin/main:.github/workflows/absent-context-census.yml | grep -n 'actions: read'   # => 76
git show origin/main:.github/workflows/crown-reconcile.yml      | grep -n 'actions: read'   # => 81
gh api 'repos/FRIKKern/barkpark/actions/workflows/stale-verdict-watch.yml/runs?per_page=100' \
  --jq '.workflow_runs[]|.event' | sort | uniq -c
gh api 'repos/FRIKKern/barkpark/actions/workflows/stale-verdict-watch.yml/runs?per_page=1' --jq .total_count
```

Reading now: **19 runs, oldest 2026-08-09T09:25:22Z** — 15 push · 2 schedule · 2 pull_request;
11 failure · 5 cancelled · 3 success. The cron HAS fired (2 schedule runs) — do not repeat the
first-pass error of inferring "never scheduled" from `gh run list --limit 12`, which shows only
the newest page and happened to be all-push.

**5 of 19 runs (26%) concluded `cancelled`** — neither red nor green — clustered in the 11:34:38–11:34:58
five-PR merge burst. `concurrency.cancel-in-progress` is `${{ github.ref != 'refs/heads/main' }}` = false
on main, so runs QUEUE; GitHub cancels the older PENDING run when a newer one joins a queue of one.
A merge burst is exactly when staleness changes, and that is when the watch is quietest.

The store, ranked by what the tree already licenses:

1. **`actions: read` + read the prior run's own log** — two in-repo precedents (above), no new secret,
   no new file, and the store is already populated (19 runs). Cost: log retention is finite, and a
   first-ever run has no prior — which must print `no prior reading` with its denominator, not a blank.
2. `actions/cache` — 10 workflows already use artifacts/cache (`ci.yml`, `cloud.yml`, `elixir.yml`, …),
   but a cache is best-effort by contract and a silent miss reads as "no change".
3. `upload-artifact` + cross-run `download-artifact` — needs `actions: read` ANYWAY, so it is option 1
   plus a moving part.

Whichever is chosen, D479 (cross-cutting law) already requires the trend to print its last-write
timestamp and denominator. A trend with no prior value must say so; it must never render as 0.
