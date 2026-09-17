# taskboard-drive report

- date: 2026-09-17T03:17:48Z
- mode: hermetic
- tmux: tmux 3.4
- host: Darwin arm64

- PASS — hermetic fixture serving the live-pinned surface on 127.0.0.1:4839
- PASS — wide session geometry is 130x40 detached
- PASS — narrow session geometry is 70x24 detached
- PASS — wide board painted task rows (configured server reachable)
- PASS — hermetic header pins the literal '● live' glyph (welcome frame upgraded polling->live; CONN mask dropped)
  - wide header located on line 2
- PASS — G9 wide spine OVERFLOWS at 130x40: counted '↓ 7 more below' painted on board line 36
- PASS — G9 no counted '↑ N more above' at boot (window pinned at top=0 — the markers track the window, they are not unconditional chrome)
  - G10 calibrated one keyboard step: "Harbor lights epic" -j-> "Dredge the north channel" -k-> "Harbor lights epic"
- PASS — G10 click on the counted ↓ overflow marker (line 36) stepped the cursor EXACTLY one row: "Harbor lights epic" -> "Dredge the north channel", the same task one `j` selects (D119 wideBoardMarkerAt -> moveCursor)
  - G9 walked 25 rows down from the top before the window first slid
- PASS — G9 both counted markers paint once the window has scrolled off the top (↑ line 3, ↓ line 36)
- PASS — G10b click on the counted ↑ overflow marker (line 3) stepped the cursor EXACTLY one row BACK: "Rebush the treble clapper" -> "Shim the oak bell frame", the same task one `k` selects
- PASS — G10 board restored to its boot cursor row ("Harbor lights epic") — the asserts that follow see the baseline board
- PASS — header ↔ divider affordance located at col 84
- **FAIL** — G7 divider hover bounds: responding cols {84 85 86} (want exactly 2)
- PASS — G5 hover accent paints on gutter hover and restores exactly when the pointer leaves (styled header row diff)
- PASS — G4 leaf descended on FIRST click: divider form flipped board->reader (↔ col 84 -> 85)
- PASS — esc after descend: board footer still present (ascended cleanly)
- PASS — G6 drag-in-progress paints the ↔↔ grabbed affordance
- PASS — G6 divider followed the drag: ↔ col 84 -> 74 (target 74)
- PASS — G6 drag release rewrote taskboard-preferences.json (none -> "details_pane_ratio":0.4126984126984127)
- PASS — G6 dragged split PERSISTED across kill+relaunch (↔ col 74 ~ 74)
- PASS — narrow board footer sheds the M note (shed-ladder design, <102-col inner)
- PASS — narrow first-click descend reached the reading frame (footer shows the M mouse note)
- PASS — narrow esc ascended back to the board
- PASS — hermetic '● live' still pinned at run end (held-open stream survived the G6 relaunch; no polling fallback)

## totals

- pass: 23
- fail: 1
