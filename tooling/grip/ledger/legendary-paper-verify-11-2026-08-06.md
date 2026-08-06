<!-- doc-tier: cold | canonical-for: legendary-paper-verify-11-evidence | budget: 1900tok -->
# Verify 11 — real `bp tasks` split-pane geometry, focus, and Paper reachability

Verdict: `refuted`, with an all-four reachability gap. Current `bp tasks` has no 50-column collapse discontinuity: widths 80, 60, and 50 all use the same intentional narrow full-frame mode. Wide mode has a working draggable, persistent one-third details pane and focus-local scrolling. None of the four pinned Papers is navigable in the real board because hydration ignores their `content.wave_paper` references.

| Terminal width | Initial capture SHA-256 | Detail capture SHA-256 | Mode |
| ---: | --- | --- | --- |
| 80 | `ce69f707ad990d08f0d54c7b9e6753da21cb6a51100bf8b2c63c4672f0a341b4` | `86e41002b0b2f709aba7a621c71b68d2a4f7dff0d66be682a0ad74dd46797f16` | narrow full-frame |
| 60 | `3129db9a53a010bd77e6fbe364ac4772007984cc311f171e98b74e0738f8254c` | `1c566a58a1cf1958a31f8f4c79809f3e50960b27cb76e7375d9166b361f584a4` | narrow full-frame |
| 50 | `78d4a1e4bb45898badfe9b1a30f9d3d46044adc59fe5255b9ce3d29df8e7fd93` | `0a51d263da126b5cba135172d31f986fd8a670acdd32fb693fa10c7d522e208c` | narrow full-frame |

- Dynamic 80→60→50 resizing stays narrow. Wide mode enters at 110 and exits below 106; earlier 50-column discontinuity evidence came from standalone Studio layout, not this board.
- At width 120, usable inner width is 116: board 75, divider at index 76, details 39—the requested one-third default.
- Dragging moves the divider 76→61; held state changes to `↔↔`; release stores ratio `0.46551724137931033`; a fresh launch restores index 61. The installed preference `0.5555555555555556` likewise reopens at board 50/details 64.
- Wheel over the right pane scrolls only the preview; subsequent `j` continues there. Left-pane wheel moves the board cursor and resulting preview. Narrow detail wheel produces the explicit `↑ more above` state.
- One click and Enter share the same activation reducer. Single-click and Enter detail captures have the same hash.
- The targeted taskboard suite passes and directly covers hysteresis, one-third default, drag persistence/style, focus-local wheel behavior, click/Enter equivalence, and mouse-motion coalescing.

Current help is false: it says first click selects/second activates and columns are not draggable. Actual PTY and code prove one-click activation and a draggable divider; the help test merely freezes the stale wording.

The live 1,000-task snapshot has `wave_paper` references to the four pins 23/7/10/11 times, but zero `design_doc` or `papers[]` references. Fetch hydration and `PaperRefs` derive only from `design_doc`/`papers`, so none can open in real `bp tasks`. Direct render at actual board-effective widths is therefore counterfactual:

| Paper | 72 cells | 54 cells | 45 cells |
| --- | ---: | ---: | ---: |
| Cloud Console wave 29 | 1,583 | 2,172 | 2,696 |
| PDS wave 45 | 1,679 | 2,269 | 2,813 |
| Cloud Console wave 28 | 2,589 | 3,596 | 4,436 |
| PDS wave 44 | 1,411 | 1,876 | 2,272 |

The full Paper claim requires hydration of `wave_paper` into `PaperRefs` or deliberate `papers[]` linkage, then a rerun. Hover rest/hover/grabbed styling is proven in tests; plain tmux text preserves only the grabbed glyph, not opacity. Evidence is sealed under `/private/tmp/verify11-evidence.Fw4J7T`. No repository, task, or Paper mutation occurred.
