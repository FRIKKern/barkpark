# The population of reference literals a PR can move in the same commit it is judged by

Task: `pds-bl-w49-budget-literal-moved-by-its-own-pr` (criteria c0 + c3).
Measured on `origin/main` @ `f707ef829` (2026-09-11). Read-only; no gate was built here.

## The predicate

A row belongs to this population when ALL THREE hold:

1. It is a **tracked file in this repo** (so a PR can edit it in the same commit it is judged by).
2. Its **contents ARE the reference value** — a numeric cap, budget, floor, count or
   grandfather-set — not code that computes one.
3. A **check reads it as its reference value**: the consumer is named below with
   `file:line`, and that consumer is reached from a workflow step (also named).

A threshold hard-coded inside a test or a scanner is a DIFFERENT, larger population and is
not enumerated here (see "What this list does NOT cover").

## How the count was produced

```sh
# candidate set: tracked files whose BASENAME declares them a reference-value file
git ls-files | grep -E '(\.size-limit\.json$|baseline[^/]*\.(txt|json|ex|exs)$|\.baseline$|\.sobelow-skips$|budget[^/]*\.(json|txt|tsv|csv)$|thresholds?\.(json|txt)$)' \
  | grep -vE '^(\.omx|\.demo-content|\.codex|docs/|tooling/grip/ledger/|apps/)'
# -> 27 candidates

# plus the dot-file rosters the basename filter misses
git ls-files | grep -E '(\.silencer-counts|\.go-format-drift-ceiling|status-manifest\.json)$'

# reader proof, per candidate (run for each basename):
git grep -n -- "<basename>" -- .github scripts api/scripts tooling cloud/priv/static js
```

Of the 27 name-shaped candidates, **11 were dropped** as test fixtures with no CI reference
role (`valueref-baseline-match.json` x3, `endpoints_catalog_baseline.ex`,
`reader_query_baseline_test.exs`, `sobelow-baseline-fingerprint.exs`,
`20260626184735_baseline.exs`, `cssom-floor/heads.baseline`, `cssom-multiset/heads.baseline`,
`styleguide-roster/heads.baseline`, `scripts/taskboard-drive/evidence*/baseline-wide.txt`).
Three rosters were ADDED that the basename filter misses. **Final population: 18.**

## The population (18)

| # | Path | The literal(s) | Consumer (file:line) | Reached from | Same-PR move detected? |
|---|---|---|---|---|---|
| 1 | `js/packages/react/.size-limit.json` | `1.3 KB`, `24.66 KB`, `23.65 KB`, `2 KB`, `1.4 KB`, `20.73 KB` (lines 6,12,18,24,34,40) | `size-limit` via `js/packages/react/package.json:79` | `.github/workflows/js-tests.yml:241` (`pnpm exec turbo run size`) | **NO** |
| 2 | `js/packages/core/.size-limit.json` | `17.25 KB`, `18 KB` | `size-limit` via `js/packages/core/package.json:45` | js-tests.yml:241 | **NO** |
| 3 | `js/packages/nextjs/.size-limit.json` | `20 KB`, `15 KB`, `2 KB`, `2 KB`, `1 KB` | `size-limit` via `js/packages/nextjs/package.json:125` | js-tests.yml:241 | **NO** |
| 4 | `js/packages/codegen/.size-limit.json` | `15 KB` | `size-limit` via `js/packages/codegen/package.json:45` | js-tests.yml:241 | **NO** |
| 5 | `.github/hex-audit-baseline.txt` | grandfathered advisory ID set | `scripts/hex-audit-oracle.sh:275-279` | `.github/workflows/security.yml:823` | **NO** |
| 6 | `api/.sobelow-skips` | 36 skipped-finding entries | Sobelow regression gate | `.github/workflows/security.yml`; count ratcheted by `scripts/silencer-growth-ratchet.sh` | **PARTIAL** (count only, advisory job) |
| 7 | `scripts/tenant-scope-baseline.txt` | 44 grandfathered fail-open reads | `scripts/tenant-scope-check.sh --baseline` | doc-gates.yml; count ratcheted | **PARTIAL** (count only, advisory job) |
| 8 | `design/status-manifest.json` | 45 lines | `scripts/status-manifest-check.sh` | `.github/workflows/doc-gates.yml:871` | **PARTIAL** (count only, advisory job) |
| 9 | `scripts/.silencer-counts` | `tenant-scope-baseline 44`, `sobelow-skips 36`, `status-manifest 45`, `lit-allow-go 3`, `lit-allow-web 0`, `lit-allow-api 8` | `scripts/silencer-growth-ratchet.sh:132` | `.github/workflows/doc-gates.yml:1346` | **NO** — this is the ratchet's OWN roster; nothing ratchets it |
| 10 | `.go-format-drift-ceiling` | the grandfathered gofmt-dirty path set (currently EMPTY) | `scripts/go-format-drift-ceiling.sh` | `.github/workflows/go-format.yml:137` (**blocking job**) | **NO** — adding a path in the same PR silences the same PR |
| 11 | `scripts/pipefail-sigpipe-baseline.txt` | grandfathered `pipefail`+SIGPIPE sites | `scripts/pipefail-sigpipe-scan.sh --baseline` | `.github/workflows/pipefail-sigpipe-scan.yml:119` | **NO** |
| 12 | `scripts/stale-verdict-watch.baseline` | pinned conflicting-verdict PR set | `scripts/stale-verdict-watch.sh:233` (`DEFAULT_BASELINE`) | `.github/workflows/stale-verdict-watch.yml` | **NO** |
| 13 | `tooling/concept-map/boundary-baseline.json` | the accepted cross-boundary edge set | `tooling/concept-map/ci-boundary.mjs:60` (`BASELINE_PATH`) | `.github/workflows/architecture.yml` | **NO** — and `ci-boundary.mjs:359` says so in its own words: *"writing to boundary-baseline.json is exactly the move this gate must never make to go green"* |
| 14 | `tooling/doc-truth/fixtures/lineref-baseline.json` | never-worse floor, 542 | `tooling/doc-truth/lineref-sweep.mjs:45` (`BASELINE`) | `.github/workflows/doc-gates.yml:1067` | **NO** — mitigated only by a path trigger (`doc-gates.yml:44` exists so a PR cannot *"rewrite lineref-baseline.json without this gate ever running"*); the gate still reads the NEW value |
| 15 | `cloud/priv/static/__preview__/cssom-heads.baseline` | `1345` (authored-head floor) | `cloud/priv/static/__preview__/cssom-parity.mjs:192` | `.github/workflows/console-harness.yml:1776` (**Console gate** — required) | **NO** |
| 16 | `cloud/priv/static/__preview__/cssom-heads-styleguide.baseline` | `84` | `cssom-parity.mjs:294` | console-harness.yml | **NO** |
| 17 | `api/test/search_golden/baseline.json` | golden search scores | `mix search.eval --baseline` (`api/lib/mix/tasks/search.eval.ex:8`) | **no CI step found** — and `--write-baseline` (line 9) rewrites it in one command | **NO** |
| 18 | `internal/apiclient/testdata/doc_decode_baseline.txt` | tolerant-decode baseline | `internal/apiclient/doc_tolerant_decode_test.go:161` | `.github/workflows/go-tests.yml` | **NO** |

**Tally: 14 of 18 are fully blind to a same-PR move. 3 are partially covered (count-only,
via the silencer ratchet, on an advisory job). 1 — `scripts/.silencer-counts` — IS the
partial coverage and has no guard above it.**

### Second-order finding: none of these gates is merge-blocking

The required set on `main` is exactly four contexts:

```sh
python3 -c "import json;d=json.load(open('.github/required-checks.json'));print([c['context'] for c in d['protection']['required_status_checks']['checks']])"
# ['Cloud gate', 'Console gate', 'Elixir gate', 'PR references an active task']
```

`js-tests.yml` (rows 1-4), `security.yml` (5-6), `doc-gates.yml` (7-9, 14),
`go-format.yml` (10), `pipefail-sigpipe-scan.yml` (11), `stale-verdict-watch.yml` (12),
`architecture.yml` (13), `go-tests.yml` (18) are none of them. Only rows 15-16 ride a
required context (Console gate). So for 16 of 18 rows, moving the literal is not even the
cheapest way to go green — ignoring the red is.

### What this list does NOT cover

Thresholds hard-coded **inside source** — census floors in `api/test/**/*_census_test.exs`,
ratchet counts in `*_ratchet_test.exs`, inline `lit-allow` waivers. Those are the same defect
shape but are not files-whose-contents-are-a-threshold, and enumerating them needs a
different predicate (a parse, not a path filter). Also excluded: `.omx/state/**`,
`.demo-content/**`, `.codex/**`, `docs/**` and `tooling/grip/ledger/**` — none is read by a
check as a reference value.

## The #9601 instance (criterion c3)

`git show c3b0421cb --stat`:

```
c3b0421cb3b8be5c63ced8a4ff8577a512b7b39c
Frikk Jarl
Wed Aug 5 21:52:21 2026 +0200
fix(react): a failed reference fetch is no longer a missing document (#9601)

 .../react-reference-error-not-notfound.md          |  43 +++
 js/packages/react/.size-limit.json                 |   4 +-
 js/packages/react/src/Reference.tsx                | 126 +++++++--
 js/packages/react/src/index.ts                     |   3 +
 js/packages/react/tests/Reference.errors.test.tsx  | 311 +++++++++++++++++++++
 js/packages/react/tests/Reference.test.tsx         |   4 +-
 6 files changed, 465 insertions(+), 26 deletions(-)
```

The hunk, verbatim (`git show c3b0421cb -- js/packages/react/.size-limit.json`):

```diff
diff --git a/js/packages/react/.size-limit.json b/js/packages/react/.size-limit.json
index 38e65366e..b8ea513de 100644
--- a/js/packages/react/.size-limit.json
+++ b/js/packages/react/.size-limit.json
@@ -7,9 +7,9 @@
   "gzip": true
  },
  {
-  "name": "PortableDoc renderer — client entry (dist/index.mjs)",
+  "name": "PortableDoc renderer — client entry (dist/index.mjs) — 22.5 KB + 250 B for BarkparkReference error discrimination (measured 22.7 KB, +0.98%, under the 2% regression bar)",
   "path": "dist/index.mjs",
-  "limit": "22.5 KB",
+  "limit": "22.75 KB",
   "gzip": true
  },
```

Criterion 6 of `pds-w48-react-reference-error-collapse` (index 5, `met: false`,
`evidence: ""`) reads:

> THE BUNDLE BUDGET HOLDS: `pnpm --filter @barkpark/react size` passes against
> .size-limit.json's **22.5 KB** gzip cap on dist/index.mjs after adding the boundary.
> Evidence quotes the measured size and the cap.

The PR whose merge would have satisfied that criterion is the same commit that moved the
cap the criterion names. There is no revision of the repo at which the criterion can be
stamped as written: before `c3b0421cb` the fix is absent, and from `c3b0421cb` onward the
`22.5 KB` cap is gone. **The criterion is unstampable, and the check it names measured
nothing at merge time — the reference value moved with the subject.**

The honest half: the move IS recorded, inside the entry's `name` string, with the
measurement and the justification. What the `name` string cannot do is reach the criterion
that cited the old number, or any diff-aware reader.

### The disagreement is WIDER today, not resolved

```sh
grep -n 'limit' js/packages/react/.size-limit.json   # on f707ef829
#  12:  "limit": "24.66 KB",
```

Criterion 6 cites **22.5 KB**. The cap on `main` today is **24.66 KB** — moved a second
time, by a 2026-09-08 "nested-reader rebase" whose own `name` string records
`24565 B -> 24631 B`. The gap between the criterion literal and the live cap is now
**2.16 KB**, and the cap has moved twice since the criterion was written without either
move being visible to it.

## Handoff to the guard (c1/c2, gates lane)

Rows 1-5, 9-18 need the guard. Rows 6-8 already have count-only coverage via
`scripts/silencer-growth-ratchet.sh` + `scripts/.silencer-counts` — **that script is the
working prior art for the guard's shape** (shrink-only roster, REFUSE on a missing target,
exit 2 for "cannot compare", self-test arms A-H). Two gaps to close rather than reinvent:
its roster is itself unguarded (row 9), and it runs on an advisory job.
