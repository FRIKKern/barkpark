# Task-TUI W19 — the feels-native verdict (2026-08-17)

Builder: ttw17-bl-live-tmux-drive (charter D110). The first honest per-gesture
judgment of the task board's mouse grammar against the lazygit bar, taken from
the COMMITTED harness `scripts/taskboard-drive/drive.sh` driving the real
binary in detached tmux 3.4 (130x40 wide + 70x24 narrow) against guerrilla.
Two consecutive full runs: 25 asserts pass, 0 fail, exit 0; the user's
pane-ratio prefs restored after each. Frame evidence per gesture (normalized
frames + located styled rows, before/after) is COMMITTED in
`scripts/taskboard-drive/evidence/` with `report.md` naming each delta — that
directory and this ledger row are the durable venues the merge carries.

## Per-gesture verdict vs the lazygit bar

| Gesture | Verdict | Why (one line) |
|---|---|---|
| Wheel up/down (64/65) | PASS | Moves the selection one row per step with the details pane following instantly; 3 down + 3 up returns exactly (evidence `g1-wheel-*.txt`) — precisely lazygit's sidebar wheel. |
| Click = select+activate | PASS | One click moves ▎ to the clicked row AND activates it in the same gesture (`g2-leaf-click-*.txt`); no select-then-click-again ceremony anywhere. |
| Leaf first-click descend | PASS | The FIRST click on a leaf opens its reading view — divider form flips board→reader (↔ col 50→51) and the pane heading shows the clicked task; no double-click needed. |
| Epic-root section toggle | PASS | Clicks drive the D51/D54 three-mode ladder: partial default → FULL list → collapsed → full (`g3-fold-*.txt`); a true toggle from any state. The "click folds/unfolds" shorthand in earlier rows was miscalibrated — from the partial default the first click EXPANDS; only a fully-expanded section collapses. |
| Hover accent (35) | PASS | Gutter │ + ↔ recolor the moment the pointer reaches the gutter and restore byte-exactly when it leaves (`g5-hover-header-*.txt`); lazygit has no hover at all — this exceeds the bar. |
| Divider drag + persistence | PASS | Press-on-gutter grabs (↔↔ bold accent), the split follows the motion live, release rewrites `details_pane_ratio` (0.6054→0.6825), and the dragged column survives kill+relaunch (`g6-*.txt`, `g6-prefs.txt`); lazygit needs keys for this. |
| Divider hover 2-col bounds | PASS | Behavior-probed: exactly cols {50,51} respond, neighbours 49/52 do not — the hit target equals the painted affordance, predictable. |
| M mouse toggle | PASS | Off → injected clicks are ignored (▎ pinned); on → the same click lands. Judged functionally: the footer note sheds below a 102-col inner board width by design and narrow READING footers do show "M mouse" (`n-narrow-reading.txt`). |
| Narrow (70x24) wheel/click/esc | PASS | Same grammar at phone-width: wheel moves ▎, first click descends to the reading frame, esc ascends. |
| Shift-click bypass | NOT SCORED | Cb=4 reaching the app acts as a plain click; the real bypass is terminal-native selection, structurally unprovable via send-keys (D110). |

## Defects found (all filed, none fixed blind in-wave)

- **`ttw19-bl-conn-state-flap`** (pre-filed at verify, REFERENCED not re-filed):
  observed again throughout these runs — the header flapped ✗ offline ↔ ● live
  across sessions while every API call succeeded. The harness normalizes the
  flap to `CONN` so evidence diffs stay honest.
- **`ttw19-bl-wide-focus-oneway`** (NEW, filed + published this drive): wide
  focus is one-way for the keyboard. `enterTask` sets `wideFocus=reader`
  (program.go:1228) and the ONLY board-focus assignment is the mouse board-pane
  press (compose.go:658). Keyboard-proven live: fresh board → `j` moves the
  cursor; Enter → Esc → `j` scrolls the PREVIEW forever after — the board
  cursor is unreachable without a mouse click. Lazygit's bar is unambiguous
  here: esc always returns you to list navigation. This is the one place the
  wide board currently fails feels-native.

## The bar, summed

Every shipped gesture in the D110 matrix passes against the real terminal —
the synthetic-only mouse claim is retired. The board misses lazygit-grade on
exactly one adjacent seam (keyboard focus return, filed above) plus the known
conn flap. Both are owned tasks under `task-tui-goal`.
