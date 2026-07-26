<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client `cmd/barkpark/`: `main.go` → `tui.go` → `store.go`/`schema.go` (`internal/apiclient/`) → `structure.go` desk.

Editing (D12): v1 scalar/ref/array inline; v2 read-only → docs/contracts/schema-v2.md; keymap → cheatsheets/tui.md. Desk task `c`/`x` via `/v1/tasks/:id/{claim,close}`.

## Papers / Bulldocs
- Viewer `paper.go`; blocks via `internal/pdrender` (`Decode`→`DefaultRegistry(theme)`→`Render`); `bp paper` shares it.
- **Parity:** new blocks ship in HTML, CSS + pdrender. Doctrine → docs/contracts/tui-render-doctrine.md
- **Go:** `go.mod` pins 1.25.0 (#726); don't bump.

## `bp tasks` — live portrait task board
Pane `internal/taskboard`, zero-config, SSE-live. NAV (D11): `enter` descends board→task→paper→children…, `esc` ascends. Adaptive two-pane ≥110c. ACTS `c`/`x`/`o`. Entry `cli.go` `case "tasks"`→`taskboard.Run`. `render.go` `Render`, `spine.go` `spineRows`=one paint+cursor source, `compose.go` `Compose`=`View()`. **Frontier** `areasOf`: docs/contracts/dispatch-areas.md. `bp tasks` (pane) ≠ `bp task …` (verbs).

## `bp chat` — native terminal chat client
Pane `internal/chat`, 2nd surface of One Chat Two Surfaces (/papers/barkpark-chat-tui). Launch=picker. Entry `cli.go` `case "chat"`→`chat.Run`. `reduce.go` `Reduce`: D8 settle at `result`, D9 live-tail carve-out, D11 interrupt (`aborted_streaming` non-error, 8s wedge), D12 ⧗ queued. `render.go` `renderAssistantDoc`=one `pdrender` RenderDoc/message (D10 Figure reset). D14: PATCH draft/mode/model/effort on leave, re-GET on resume. Keys: enter send, esc interrupt, ctrl+b back, `?`=full map. Shelf (D28): `a` archives, `s` opens it, `enter`/`u` restores; scripts `bp chat unarchive <id>`, `ls --archived`.

## Code anchors
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- scripts/pdrender-dump.sh — offline fixture render; width defaults to 80
- internal/cli/tasks_board_cmd.go — func runTasksBoard
- internal/cli/chat_cmd.go — func runChat
- internal/chat/reduce.go — func Reduce
- internal/chat/render.go — func renderAssistantDoc
- internal/taskboard/board.go — func BuildBoard
- internal/taskboard/frontier.go — func areasOf
- api/lib/barkpark/portable_doc/render.ex — def render_html
