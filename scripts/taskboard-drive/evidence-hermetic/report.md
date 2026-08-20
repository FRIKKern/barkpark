# taskboard-drive report

- date: 2026-08-17T17:53:54Z
- mode: hermetic
- tmux: tmux 3.4
- host: Darwin arm64

- PASS — hermetic fixture serving the live-pinned surface on 127.0.0.1:4799
- PASS — wide session geometry is 130x40 detached
- PASS — narrow session geometry is 70x24 detached
- PASS — wide board painted task rows (configured server reachable)
- PASS — hermetic header pins the literal '● live' glyph (welcome frame upgraded polling->live; CONN mask dropped)
  - wide header located on line 2
- PASS — header ↔ divider affordance located at col 84
- PASS — G7 divider hover bounds: exactly 2 contiguous cols respond (84 85); neighbours 83 and 86 do not
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

- pass: 18
- fail: 0
