<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-17 | budget: 2000tok -->
# Restart Verify 17 — TUI Paper keys, help, and progress

Assignment `restart-verify-17` tested Paper navigation reducers, boundary clamps, help truth, and visible progress across the four frozen Papers. Verdict: **refuted; reducer behavior passes, but help and progress do not describe it truthfully**.

All four Papers matched their exact revisions and block counts, totaling 815/815 blocks. The deterministic reducer probe passes 48/48 action assertions and 48/48 boundary clamps. Internal progress math returns exact top `0` in 4/4 Papers and bottom `1` in 4/4. Four real Bubble Tea 80×24 PTY runs complete and each is byte-identical on repeat. `go test ./cmd/barkpark` and every existing `TestHelp*` test pass.

Visible progress is absent in 0/8 required top/bottom frames. No production code under `cmd/barkpark` consumes `ScrollPercent`, `AtBottom`, `AtTop`, `TotalLineCount`, or `VisibleLineCount`. The viewport computes truthful internal state, but the Paper reader never renders it.

The Paper help bar covers only 4/7 required key families; the full Paper help section covers 3/7. Both omit Space for full-page movement, `?` for help, and Back aliases (`h`, left, Shift-Tab, Backspace), even though `tui_update.go` binds those actions. Existing help tests pin only generic Paper/Studio copy and therefore do not cover the omissions.

| Contract arm | Observed |
|---|---:|
| Reducer actions | 48/48 pass |
| Boundary clamps | 48/48 pass |
| Internal top/bottom math | 8/8 exact |
| Repeated 80×24 PTY | 4/4 deterministic |
| Visible top/bottom progress | 0/8 |
| Help bar families | 4/7 |
| Full help families | 3/7 |

The PTY harness directly injected the exact frozen Papers because production discovery/open is separately refuted by Verify15. That boundary cannot rescue missing help or progress because both defects are directly observed in production source and rendered frames. Installed build `f59aaf717` and worktree `94d42bde` have zero relevant file differences.

Evidence is `/private/tmp/bp-restart-verify-17.odnu8B/evidence/result.json`, SHA-256 `19cb07cc379dca286f8f23070ca8ed2214acc0940525c6b79574f33d78b881e9`. Tracked repository, Barkpark, production, and credential mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-17","assignment_uuid":"171f1b57-ad2c-4f85-a1f4-13067c143e88","verdict":"refuted","blocks_exact":"815/815","actions":"48/48","boundary_clamps":"48/48","internal_progress":{"top":"4/4=0","bottom":"4/4=1"},"pty_deterministic":"4/4","visible_progress":"0/8","help_bar_families":"4/7","help_section_families":"3/7","omitted_keys":["Space","?","Back aliases"],"go_tests":"pass","mutations":0,"evidence_sha256":"19cb07cc379dca286f8f23070ca8ed2214acc0940525c6b79574f33d78b881e9"}
```
