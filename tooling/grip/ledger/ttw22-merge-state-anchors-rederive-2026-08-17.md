<!-- doc-tier: cold | canonical-for: ttw22-merge-state-anchors | budget: 800tok -->
# Wave-22 merge-state + anchor re-derivation (vf-merge-state-anchors)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Snapshot: origin/main = `c37a29244702f103245a173bfe255e51adb5259f` (fetched 2026-08-17).

## Merge state — NONE merged
```
for p in 11939 11940 11941 11867 11924; do gh api repos/{owner}/{repo}/pulls/$p --jq '"\(.number) \(.state) merged=\(.merged_at)"'; done
```
All five OPEN, merged=null, base=main, mergeable=true. Base SHAs stale vs c37a292:
11939/11940=9151154f9, 11941=b6465c0f5, 11867=a9d29985d, 11924=94b12757a.

## The two 503-blocked manifests (exact)
```
gh api repos/{owner}/{repo}/pulls/11940/files --jq '.[].filename'
```
`internal/taskboard/compose.go`, `internal/taskboard/overflow_click_test.go` — 2 files, one non-test. File-disjoint from #11939 (fetch/detail_data/render) and #11941 (scripts/). Disjointness claim HOLDS.
```
gh api repos/{owner}/{repo}/pulls/11867/files --jq '.[].filename'
```
charter + `ttw20-anchor-currency-rederive`, `ttw20-drafts-claim-lifecycle`, `ttw20-fetch-path-map-and-now-denominator-drift` (3 ttw20 rows).
#11924 files: charter + `ttw21-d115-union-seam-contract`, `ttw21-vf-prime-route-and-failure-modes` (2 ttw21 rows, NO ttw20 rows). UNION HAZARD CONFIRMED — closing #11867 as superseded loses the 3 W20 ledger rows.

## Anchors on CURRENT origin/main (all pre-merge state)
```
git show origin/main:internal/taskboard/fetch.go | grep -n 'in_progress\|mergeInflight'
```
No union helper — only wire-struct `lifecycle_status` at :300. #11939 not landed.
```
git show origin/main:internal/taskboard/cache.go | grep -n 'func cacheKey'
```
:40 `func cacheKey(server, workspace, project string) string` — Dataset absent. Confirmed.
```
git show origin/main:scripts/taskboard-drive/drive.sh | grep -c DRIVE_MODE   # -> 0
git show origin/main:scripts/taskboard-drive/fixture/main.go                 # -> does not exist
git show origin/main:internal/taskboard/detail_data.go | grep -n FetchSnapshotFull  # -> :63
```
compose.go overflow markers currently no-op: :803 "chrome, an overflow marker, or a display-only line".

## Charter stranded — origin ends at Wave 19
`git show origin/main:...charter.md` = 2525 lines, last block Wave 19 REVIEWED (:2475), footer :2473 "Next D-number: D114". D114-D123 absent (only unrelated felix "D114" at :2273). Stranded-charter CONFIRMED.

## #11927 remains an ISSUE, no PR
`gh api .../issues/11927` -> pull_request=NONE; no open PR references it. Spec §0 glyph fix must be authored.
