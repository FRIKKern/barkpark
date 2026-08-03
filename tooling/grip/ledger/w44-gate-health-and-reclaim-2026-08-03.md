# Re-derivation recipes — w44 gate-health-and-reclaim (verify, 2026-08-03)

Five PRs: #9312 (charter), #9332, #9333, #9334, #9335. All figures below were
taken from the CHECK-RUNS feed, never the workflow-runs rollup.

## R1 — the four slice claims (never copy an epoch; read immediately before acting)

```bash
for t in pds-w43-caps-readonly-share-write-bypass \
         pds-w43-two-more-doors-census-record-parity \
         pds-w43-ledger-lapse-expiry-arm \
         pds-w43-sheetgrid-read-mode-hook; do
  bp task get $t -o json | python3 -c "import json,sys;d=json.load(sys.stdin);d=d.get('doc') or d;print(d['doc_id'],d['lifecycle_status'],json.dumps(d['claim']))"
done
```
2026-08-03T10:30Z state: all four `in_progress`, worker `loop-lead`, epochs
7 / 7 / 7 / **8** (the sheetgrid row is the 8). A copy-pasted 7 is refused on #9335.

## R2 — check-runs per head SHA, with BOTH timestamps (a 0 s shim is visible)

```bash
for s in 64c8b600cca758f764196b80896cfa262de36e55 \
         5d905c359f128e88680645fa790189aeaa012a2e \
         e2b0bf40d48ec5209f42393684073b52c986fe95 \
         2457b4ad15b91139a8bcfa3016d6d81cd1848be7; do
  echo "== $s"
  gh api "repos/:owner/:repo/commits/$s/check-runs?per_page=100" \
    -q '.check_runs[]|"\(.name) | \(.conclusion) | \(.started_at) | \(.completed_at)"'
done
```
A REAL Test execution spans ~10-12 min and carries the EXPANDED matrix suffix
`(Elixir 1.18.1 / OTP 27.0)`. A SHIM carries the literal, unexpanded
`Test (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})`, conclusion
`skipped`, started_at == completed_at. #9334 (e2b0bf40) is the shim.

## R3 — a RE-RUN clears the sticky pr-task-gate verdict (no push needed)

```bash
for id in $(gh api "repos/:owner/:repo/actions/runs?head_sha=64c8b600cca758f764196b80896cfa262de36e55&per_page=100" \
             -q '.workflow_runs[]|select(.name=="pr-task-gate")|.id'); do
  gh api "repos/:owner/:repo/actions/runs/$id/attempts/1" -q '"attempt1: \(.conclusion) \(.updated_at)"'
  gh api "repos/:owner/:repo/actions/runs/$id/attempts/2" -q '"attempt2: \(.conclusion) \(.updated_at)"'
done
```
Same head SHA, attempt1 `failure` 10:11:20Z, attempt2 `success` 10:30:33Z, after
the re-claim at 10:30:07Z. The gate re-reads the LIVE ledger at run time.

## R4 — why #9312 is BLOCKED, and the exact remedy

```bash
gh pr view 9312 --json body -q .body | grep '^Task:'
bp task get task-2ac1f95237c4a8e5 -o json | python3 -c "import json,sys;d=json.load(sys.stdin);d=d.get('doc') or d;print(d['lifecycle_status'],json.dumps(d['claim']))"
sed -n '20,32p' scripts/pr-task-gate.sh   # the three PASS shapes
```
`open`, `worker: null`, `expired_at 2026-08-02T17:00:00Z`; PR created
2026-08-02T19:05Z → `open_lead < 0` → REFUSE. Re-claiming the task makes it
`in_progress` with a `claim.worker` (PASS shape 1); then re-run the check (R3).

## R5 — the two reds that are NOT the branches' fault (inherited from main)

```bash
gh api "repos/:owner/:repo/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
  -q '.check_runs[]|select(.conclusion=="failure")|.name'
node api/assets/sheet-grid/__palette.test.mjs >/dev/null 2>&1; echo "rc=$?"
```
main itself is red on `Sobelow static analysis …` and
`Required-check spec drift (advisory)`. The palette assertion
(`dark --sheet-ref-0 (#5b9dff) contrast 2.72:1 < 4.5:1`) reproduces at rc=1 on
main content — #9335 touches neither `__palette.test.mjs` nor `root.html.heex`.
NOTE the rc trap: `node … | tail` prints rc=0 for a failing node. Redirect, then `$?`.

## R6 — #9335's ONE genuine red (its own design change, un-updated test)

```bash
gh run view 30804544973 --log-failed | grep -nE "refute view_html|tests, .* failure"
git show origin/main:api/test/barkpark_web/live/sheets_grid_proof_test.exs | sed -n '285p;324p'
git diff origin/main...origin/loop-epic/the-write-denied-member-s-selection-stop-4 \
  -- api/lib/barkpark_web/live/studio/sheet_grid.ex | grep -E '^[+-].*phx-hook'
```
`27 doctests, 13420 tests, 1 failure`. The failure is line 324's
`refute view_html =~ ~s(phx-hook="SheetGrid")` inside the test DECLARED at 285
(ExUnit anchors the declaration line — 285 and 324 are the same failure, not two).
The branch flips `phx-hook={if @editable…}` → `{if @hookable…}` and never updates
that refute. The sibling `data-fns` / `sheet-fns-list` refutes must SURVIVE — the
branch's own moduledoc says those stay `@editable`-gated on purpose.
