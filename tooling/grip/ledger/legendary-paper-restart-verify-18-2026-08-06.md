<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-18 | budget: 2100tok -->
# Restart Verify 18 — TUI click, focus, wheel, hover, and mouse toggle

Assignment `restart-verify-18` compared click and Enter activation, pane-focused wheel behavior, hover, and `M` mouse release/rearm across all four frozen Papers. Verdict: **refuted; click and Enter reach the same target but do not preserve the same parent state**.

Both activation paths reach the same target in 4/4 cases. After returning, however, click restores the parent Paper 19 lines above Enter in every case:

| Paper | Click-restored scroll | Enter-restored scroll | Delta |
|---|---:|---:|---:|
| CCH28 | 2836 | 2855 | -19 |
| CCH29 | 1726 | 1745 | -19 |
| PDS44 | 1512 | 1531 | -19 |
| PDS45 | 1806 | 1825 | -19 |

The code path is direct. Click activation calls `setTopCursor`, which invokes `followStop`, before descending. Enter descends directly and preserves the covered Paper's free-scroll. Escape therefore returns to different Paper positions. The first equality probe was discarded because the disposable harness accidentally shared Go slice backing storage; the corrected independent branches reproduce the four failures.

Other contract arms pass. Right-pane wheel changes Paper scroll by one and board scroll by zero in 4/4; left-pane wheel changes board by one and Paper by zero in 4/4. Focus transfer and zero cross-pane movement pass 8/8 each. Hover causes zero navigation or activation in 4/4, though it intentionally changes visual hover state and is not byte-inert. Mouse release, stale-timer rejection, released-mode click/wheel rejection, and clean rearm pass 20/20. A live 120×24 PTY proves actual terminal mouse enable, `M` disable, and rearm sequences.

Existing mouse/hover tests yield 41/41 passing assertion lines and targeted race checks pass 7/7. They omit the already-selected, free-scrolled parent-restoration case. Help also drifts: it says the first click selects and second activates, while the reducer activates on one press.

The four-Paper relation rail was deterministic synthetic data over the exact frozen 815-block payload because live task-to-Paper discoverability is independently refuted by Verify15. The real parser/terminal was exercised in live PTY, but the four exact Paper routes were not. This is an explicit boundary, not a passing substitution.

Evidence root is `/private/tmp/bp-v18.TwjkXt`; verdict SHA-256 is `0a2fe7a77ba70f9104bac7ed6c0da2aba5854f0f8aee2739cefd0ca7e4daa81e`. Repository, Barkpark, production, and credential mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-18","assignment_uuid":"1f919c24-bf7e-4cb9-8983-9b63a40af76d","verdict":"refuted","same_target":"4/4","exact_navigation_state":"0/4","parent_scroll_delta":-19,"focused_wheel":{"paper_owned":"4/4","board_owned":"4/4","focus_transfer":"8/8","cross_pane_zero":"8/8"},"hover":{"navigation_activation_inert":"4/4","byte_inert":"0/4"},"mouse_toggle":"20/20","existing_suite":"41/41","targeted_race":"7/7","help_click_contract":"drift","mutations":0,"verdict_sha256":"0a2fe7a77ba70f9104bac7ed6c0da2aba5854f0f8aee2739cefd0ca7e4daa81e"}
```
