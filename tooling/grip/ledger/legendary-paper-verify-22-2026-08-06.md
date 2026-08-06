<!-- doc-tier: cold | canonical-for: legendary-paper-verify-22-evidence | budget: 1800tok -->
# Verify 22 — meaningful reading load after spacer exclusion

Verdict: `proven`. All four pinned Papers exceed the three declared primary limits after every exact-empty top-level paragraph is excluded. Empty spacers amplify raw structure but do not cause the overload verdict.

| Paper | Spacers excluded | Words / 5,000 | Meaningful blocks / 80 | Headings / 16 |
| --- | ---: | ---: | ---: | ---: |
| Cloud Console wave 29 | 139 | 10,365 | 113 | 37 |
| PDS wave 45 | 124 | 10,147 | 103 | 33 |
| Cloud Console wave 28 | 103 | 14,400 | 134 | 43 |
| PDS wave 44 | 15 | 9,517 | 84 | 32 |

The narrowest block margin is PDS wave 44, which still has 84 meaningful blocks after all 15 inert spacers are excluded. Re-running `scripts/paper_quality.py` on each transformed input retains `primary_reading_load_exceeded`, `top_level_block_overload`, and `top_level_heading_overload` for every Paper.

Local density is also independently excessive. Longest paragraphs are 149/174/225/175 words against 140; longest list items are 102/108/71/107 against 80; longest table cells are 67/59/114/45 against 60. Every Paper breaks at least one local-density threshold.

Reader evidence corroborates the source metrics. Representative NoColor CLI renders remain 1,440, 1,537, 2,357, and 1,305 lines. Public, Studio where connected, TUI80, and email evidence measures tens to more than 100 screens. Public and TUI surveys found exact-empty paragraphs contributed no visible height or were suppressed, so those lengths reflect meaningful content rather than spacer geometry.

The `table_missing_header` result is excluded from this verdict because the scorer reads only `head`, while these sources use accepted canonical `header`; Verify 03 already proved that instrumentation defect. A mistaken `slug@revision` lookup was also discarded because the CLI treats it as a literal ID. Correct fresh fetches matched all four expected revisions and earlier captures after canonicalization.

Fresh browser rendering of transformed artifacts was outside this assignment, and Studio geometry for Cloud Console wave 28 remains unproven because LiveView did not connect. Neither gap affects the numerical claim. No repository or Barkpark state was mutated; `git status` and `git diff --check` were clean at `6a32db719b6427b490884053763aba63b36f1d7a`.
