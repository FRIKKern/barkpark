# taskboard-drive report

- date: 2026-08-17T12:49:28Z
- tmux: tmux 3.4
- host: Darwin arm64

- PASS — wide session geometry is 130x40 detached
- PASS — narrow session geometry is 70x24 detached
- PASS — wide board painted task rows (configured server reachable)
  - wide header located on line 2
- PASS — header ↔ divider affordance located at col 50
- PASS — G7 divider hover bounds: exactly 2 contiguous cols respond (50 51); neighbours 49 and 52 do not
- PASS — G5 hover accent paints on gutter hover and restores exactly when the pointer leaves (styled header row diff)
- PASS — G1 wheel down x3 moved ▎ selection: line 3 -> 8
- PASS — G1 wheel up x3 returned ▎ selection to line 3
- PASS — G2 click selected the clicked leaf row (▎ moved to line 4) in ONE gesture
- PASS — G4 leaf descended on FIRST click: divider form flipped board->reader (↔ col 50 -> 51)
- PASS — G4 reading pane heading (right of the gutter) shows the clicked task ("The live tmu")
- PASS — esc after descend: board footer still present (ascended cleanly)
- PASS — G3 click on the epic root toggled its section (partial -> full: board-side region changed)
- PASS — G3 second click COLLAPSED the root to its header (row 4 lost its ├─ child)
- PASS — G3 third click EXPANDED the section again (├─ child back on row 4)
- PASS — G6 drag-in-progress paints the ↔↔ grabbed affordance
- PASS — G6 divider followed the drag: ↔ col 50 -> 40 (target 40)
- PASS — G6 drag release rewrote taskboard-preferences.json ("details_pane_ratio":0.6054054054054054 -> "details_pane_ratio":0.6825396825396826)
- PASS — G6 dragged split PERSISTED across kill+relaunch (↔ col 40 ~ 40)
- PASS — G8 with mouse released (M), a click is ignored (▎ stayed on line 3)
- PASS — G8 after M re-enable, the same click lands (▎ moved to line 4)
- PASS — narrow wheel moved ▎ selection (3 -> 6)
- PASS — narrow board footer sheds the M note (shed-ladder design, <102-col inner)
- PASS — narrow first-click descend reached the reading frame (footer shows the M mouse note)
- PASS — narrow esc ascended back to the board

## totals

- pass: 25
- fail: 0
