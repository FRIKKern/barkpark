<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-13 | budget: 2000tok -->
# Restart Verify 13 — connected Studio responsive geometry

Assignment `restart-verify-13` tested authenticated connected Studio geometry for four frozen Papers at desktop, two phone widths, and an explicit 200%-equivalent reflow viewport. Verdict: **refuted; 4/16 strict cells pass**.

Desktop passes 4/4. The 390px, 320px, and reflow modes each pass 0/4 because every narrow/reflow header overlaps the Paper title with Open or Share. At 390px the topbar contains only 10/15 rendered controls and scrolls to 617px; at 320px it contains 8/15 and also scrolls to 617px. The reflow-equivalent topbar contains 15/15 within 640px, but its header overlap remains. Initial primary actions are fully visible in 8/16 cells; all required Open, Share, and editor targets occur in tab order in 16/16, while focused targets become visibly onscreen in 13/16.

| Mode | Strict pass | Topbar controls contained | Header non-overlap |
|---|---:|---:|---:|
| 1440×900 | 4/4 | 15/15 | 4/4 |
| 390×844 | 0/4 | 10/15 | 0/4 |
| 320×568 | 0/4 | 8/15 | 0/4 |
| 200%-equivalent reflow | 0/4 | 15/15 | 0/4 |

Authenticated LiveView connected in 16/16 cells. Frozen canvas content matched in 16/16 cells across all 815 expected blocks. The live semantic hashes agree with the prior source proof for CCH28, CCH29, PDS44, and PDS45. Sixteen `/live/websocket` connections sent only join, width-bucket, and preview-refresh events. Mutating HTTP requests and Paper save/publish/delete/share events were zero.

Tables are **bounded in 184/184 table/mode cells**. The initial harness incorrectly required `overflow-x:auto` even when a table had already reflowed to fit. Raw table and editor-wrapper rectangles disprove the original 0/184 predicate; this ledger and payload use the corrected result. The responsive defect is header/topbar control geometry, not table containment.

Direct observations include browser rectangles, screenshots, focus order, connected state, canvas hashes, and network events. Operability is inferred from visibility, non-overlap, focusability, and containment because controls were deliberately not activated. The 200% cell uses 1280×900 physical geometry represented as 640×450 CSS pixels at DPR2; Chrome's UI zoom control was not invoked. Touch, assistive technology, Safari, and Firefox remain untested.

Raw metrics are `/private/tmp/restart-verify-13.MTEbXU/metrics.json`, SHA-256 `b9a37b002c0fdb6a6fdf89c0896ad1e145fdd23890b43112136129f309dc98a0`; canonical metrics SHA-256 is `745c32b0c43cf87d9c9a28b5cee7d90c883036c991d18718a0b28ef542ad6881`. Sixteen screenshots accompany the metrics. The original `results[].pass`, original table gate, and original full-rectangle editor-visibility gate are superseded by the corrected raw-rectangle derivation.

## Cycle payload

```json
{"assignment_id":"restart-verify-13","cycle_assignment_uuid":"553b1159-9bc3-4552-8aad-2a9e8c8af35b","verdict":"refuted","threshold":"16/16","strict_pass":"4/16","by_mode":{"desktop1440":"4/4","phone390":"0/4","phone320":"0/4","reflow200":"0/4"},"authenticated_connected":"16/16","live_block_cells":"16/16","blocks":"815/815","tables_bounded":"184/184","initial_primary_controls_visible":"8/16","header_non_overlap":"4/16","keyboard_targets_in_order":"16/16","keyboard_focused_visible":"13/16","topbar_controls":{"desktop":"15/15","phone390":"10/15","phone320":"8/15","reflow200":"15/15"},"screenshots":16,"mutations":0,"metrics_sha256":"b9a37b002c0fdb6a6fdf89c0896ad1e145fdd23890b43112136129f309dc98a0"}
```
