# pds-w47 — drifted-head second look: re-derivation recipes

Verifier lane `drifted-head-second-look`, wave 47. Ground: clean `git archive origin/main`
export at **49345a98c1dbd9c768f3312185be0f5483878241** (never the primary checkout).

All commands assume `R=/Volumes/SATECHI/github/barkpark` and a scratch dir `S`.

## R1 — the export and the file universe

    R=/Volumes/SATECHI/github/barkpark
    S=$(mktemp -d); cd "$S" && git -C "$R" archive origin/main | tar -x
    git -C "$R" ls-tree -r --name-only origin/main > "$S/mainfiles.txt"
    wc -l "$S/mainfiles.txt"          # 8639
    git -C "$R" rev-parse origin/main # 49345a98c1dbd9c768f3312185be0f5483878241

## R2 — the open-PDS denominator (transitive parent_id closure, MIXED-KEYED)

    bp task ls --all -o json > "$S/all.json"    # 5075 docs, ~44 MB
    # closure from task-2ac1f95237c4a8e5 following parent_id by BOTH uuid and doc_id
    # (rows point at a parent uuid OR at its slug — indexing on one key alone
    #  silently truncates the tree; this is why 344/354/374/379/405 all circulate)
    # => closure 660, lifecycle_status==open 380

## R3 — path-token drift oracle, v1 (naive) vs v2 (three mechanical rules)

v1 regex `((?:[\w.@~-]+/)*[\w.@-]+\.(ex|exs|heex|go|js|mjs|ts|tsx|sh|py|json|yml|yaml|md|sql|...))(?::(\d+))?`
scored, over the 380 open rows: ANCHORED 179 / DRIFTED? 120 / UNANCHORED 81.

v2 adds exactly three rules and nothing else:

- **R3a** `(?![\w])` after the extension. Python alternation is first-match, so
  `ex|exs` bites `stamp_test.exs` down to `stamp_test.ex`, and `ts` bites
  `pds-w25-board-manifest-2026-07-30.tsv` down to `.ts`. Pure regex bug; it was
  manufacturing drift on files that are present.
- **R3b** `.ex` <-> `.exs` retry after basename/suffix lookup fails.
- **R3c** a basename matching `^[A-Z][A-Za-z0-9]*\.exs?$` is an Elixir MODULE NAME
  in prose (`WorkspaceBundle.ex`), never a path.

v2 scores: **ANCHORED 256 / DRIFTED? 42 / UNANCHORED 82**. Three mechanical rules
delete 78 of 120 drift claims (65%) without looking at the tree once.

## R4 — age gradient (the lane's question)

Bucketed by the wave number in `doc_id`, DRIFTED? share under v2:

| band | n | DRIFTED? | share |
|---|---|---|---|
| w<=33 | 76 | 8 | 10.5% |
| w34-40 | 34 | 12 | 35.3% |
| w41-46 | 53 | 7 | 13.2% |
| unnumbered (`pds-bl-*`, `pds-backlog-*`) | 217 | 15 | 6.9% |

There is **no age gradient**. The peak is the MIDDLE band; the oldest band is the
cleanest. Whatever the residue is, it is not decay.

## R5 — hand-adjudication of the 42 surviving DRIFTED? rows

43 unique MISS strings. Dominated by extractor artifacts:
`census.exs` x40 (in-document abbreviation), `bisect.py` x13, `c.sh` x5,
`_test.go`/`_test.sh`/`_test.exs` (suffix fragments), `NextResponse.json`
(a JS METHOD CALL, not a path), `UserConfigDir/hcloud/cli.toml` (external FS),
`...github_webhook_controller.ex` / `lib/.../sheet_grid/ops.ex` (ellided paths),
`*_GONE.exs` (a row asserting absence). Filtering those leaves **11 of 380 rows**;
hand-reading all 11 yields **zero** true "the row is stale because its file is gone":

    # negative assertion — the ABSENCE is the finding, the oracle inverts it
    grep -n "there is no scripts/pds-live-lib.sh" -r "$S"   # pds-bl-live-runners-duplicated
    # runtime-generated corpus, never in the tree
    grep -rn "fixture_live.ex" "$S/api/lib/barkpark/filler/" # written by write_corpus!/3
    # prospective (the row PROPOSES creating it)
    grep -c "docs/api/error-codes.md" "$S/mainfiles.txt"     # 0, by design
    # prefix slip, file present under __
    grep -n "sheet-grid/__hook.test.mjs" "$S/mainfiles.txt"

The single genuinely-unresolvable cite:

    grep -i scim "$S/mainfiles.txt"   # no scim_discovery_controller_test.exs anywhere

…and it is a supporting cite inside `pds-w40-scim-groups-list-members`, not the defect.

## R6 — content-aware pass (20 rows citing a specific file:line)

    git -C "$R" show origin/main:<path> | sed -n '<line>p'

15 of 20 cited lines still carry the claimed construct (exact, or within +-2 lines).
Five mismatch. Re-derive each:

    git -C "$R" show origin/main:api/lib/barkpark/content/writer.ex | grep -n 'select:'
    #   row cites writer.ex:1063 as a POST-READ site; :1063 is Projection.project(,
    #   the only select: is :1215 — and it IS inside Repo.update_all. LINE moved, row live.

    git -C "$R" show origin/main:api/lib/barkpark/content/authoring_wall.ex | grep -n 'Warnings.put'
    #   row says FOUR Warnings.put sites in all of api/lib (authoring_wall :197/:246/:277,
    #   mutations.ex:653, bulldocs_ingest_controller.ex:226). Actual: :224/:280/:305, and
    git -C "$R" grep -c 'Warnings.put' origin/main -- api/lib | awk -F: '{s+=$NF} END{print s}'
    #   SEVEN repo-wide. The structural QUANTITY the row rests on is stale.

    git -C "$R" show origin/main:.claude/workflows/bp-pds-charter.md | grep -n '79 → 80 checks'
    #   row cites charter:5515; the string is at :7765. The row about stale citations
    #   carries a stale citation. Substance intact.

    git -C "$R" show origin/main:api/lib/barkpark/tasks/stage.ex | grep -n 'forbidden_rerun_shapes'
    #   row cites stage.ex:113 for the -C loop; :113 is @doc prose, the attribute is :248
    #   and the match site is :581. LINE moved, mechanism intact.

    git -C "$R" show origin/main:internal/manifest/url.go | sed -n '36,54p'
    #   row: "the ScopedMirror prepend in url.go:39 is dead code (never set true)".
    #   :39 is a comment; the prepend is :52-54 and its gate is now
    #   `isScopedTier(cmd.AuthTier) || ctx.ScopedMirror` — REACHABLE without the mirror.
    git -C "$R" show origin/main:internal/manifest/url_scopetier_test.go | sed -n '19,21p'
    #   "revert url.go to the old `ctx.ScopedMirror &&` gate and this row [trips]"
    #   => the code changed under the row. THE ONE TRUE CONTENT DRIFT in 20.

## R7 — the oracle is blind to the case that motivated the wave

    git -C "$R" show origin/main:api/lib/barkpark/search/intelligence.ex | sed -n '118,133p'
    git -C "$R" show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | sed -n '333,350p'

`record_interaction/4` returns `{:ok, id} | {:skipped, reason}`; the controller maps
`:recording_disabled` to an honest 200 `recorded:false` and every other skip to
422/500 with `ok:false`. The defect `pds-w33-bl-catchall-success-clauses` names is
REPAIRED. Both oracles score that row **ANCHORED** — its cited line
`github_webhook_controller.ex:87` still reads
`_other -> conn |> put_status(:accepted) |> json(%{ok: true, ignored: "event"})`
verbatim, because that line is the row's DECLARED-HONEST CONTROL, not its defect.
No path oracle and no line-content oracle can see this repair.
