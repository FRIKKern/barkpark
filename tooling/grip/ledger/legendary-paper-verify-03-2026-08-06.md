<!-- doc-tier: cold | canonical-for: legendary-paper-verify-03-evidence | budget: 1400tok -->
# Verify 03 — quality-gate table-header vocabulary

Verdict: `proven`, with a scope correction. `scripts/paper_quality.py` falsely classifies accepted `header` arrays as missing because it examines only `head`. This creates 35 false table failures and suppresses 213 visible header words. Eleven PDS tables are genuinely headerless, so correcting the instrument must not clear the whole cohort.

| Paper | Tables | accepted `header` | truly headerless | scorer says missing |
| --- | ---: | ---: | ---: | ---: |
| Cloud Console wave 29 | 11 | 11 | 0 | 11 |
| Cloud Console wave 28 | 18 | 18 | 0 | 18 |
| PDS wave 45 | 12 | 3 | 9 | 12 |
| PDS wave 44 | 5 | 3 | 2 | 5 |
| Total | 46 | 35 | 11 | 46 |

- A dual-vocabulary metric changes missing counts from `11→0`, `18→0`, `12→9`, and `5→2` respectively.
- In-memory `header→head` normalization preserved every header payload semantic hash.
- Visible-word counts rise by 65/103/21/24 words after resolving `header`: 213 total words currently omitted from the scorer.
- Isolated probes prove: head-only passes; header-only is a current false positive; equal dual fields pass; conflicting dual fields require a conflict diagnostic; empty-head falls back to header; genuine absence remains missing.
- Python `TEXT_KEYS` and the table failure read only `head`. Server `epic_quality.ex` duplicates the bug, so it is not an independent oracle. `block_ops.ex`, Compose, and the writer accept nonempty `head` first and then `header`, with additional boolean/row/columns compatibility.
- Existing Python tests pass 12/12 but contain no `header` case.

The safe contract is one shared resolver: prefer nonempty `head`, otherwise accept supported `header`; count resolved header text; diagnose unequal dual fields as `table_header_conflict`; retain boolean, row-marked, and columns-derived compatibility; add fixtures for every branch. The corrected cohort must still report exactly 11 genuinely headerless tables. Elixir tests were inspected but not run in this read-only assignment. Checked all four pinned Papers, Python/server quality code, BlockOps, writer, Compose/Walk, tests, Survey ledgers, and the frozen plan. No mutation occurred.
