<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client in `cmd/barkpark/`: `main.go` → `tui.go` → `store.go`/`schema.go` (`internal/apiclient/`) → `structure.go` desk.

Editing (D12): v1 scalar/ref/array inline; v2 read-only. → docs/contracts/schema-v2.md; keymap → cheatsheets/tui.md. Desk task `c`/`x` via `/v1/tasks/:id/{claim,close}`.

## Papers / Bulldocs
- `cmd/barkpark/paper.go` — viewer; blocks via `internal/pdrender` (`Decode`→`DefaultRegistry(theme)`→`Render`); `bp paper` shares it.
- **Parity rule:** new block type ships in all three renderers — `render_html/2`, `.bp-paper-surface` CSS (root.html.heex), pdrender. Doctrine → docs/contracts/tui-render-doctrine.md
- **Go pin: `go.mod` `go 1.25.0`** (#726); don't bump.

## `bp tasks` — live portrait task board
Pane `internal/taskboard`, zero-config, SSE-live. NAV (D11): `enter` descends board→task→paper→children…, `esc` ascends. Adaptive two-pane ≥110c. ACTS `c`/`x`/`o`. Entry `cli.go` `case "tasks"`→`taskboard.Run`. `board.go` `BuildBoard`, `render.go` `Render`, `spine.go` `spineRows`=one paint+cursor source, `compose.go` `Compose`=`View()`. **Frontier** `frontier.go` `areasOf`: docs/contracts/dispatch-areas.md. `bp tasks` (pane) ≠ `bp task …` (verbs).

## `bp chat` — native terminal chat client
Pane `internal/chat`, second surface of One Chat Two Surfaces (/papers/barkpark-chat-tui). Launch=sessions picker (list/resume/new). Entry `cli.go` `case "chat"`→`chat.Run`. Reducer `reduce.go` `Reduce`: D8 settle at `result` frame, D9 live-tail carve-out, D11 interrupt (`aborted_streaming` non-error, 8s wedge), D12 ⧗ queued badge. `render.go` `renderAssistantDoc`=one `pdrender` RenderDoc/message (D10 Figure reset). D14: PATCH draft/mode/model/effort on leave, re-GET on resume. Keys: enter send, esc interrupt, ctrl+b back, ctrl+c quit.

## Code anchors
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- internal/cli/tasks_board_cmd.go — func runTasksBoard
- internal/cli/chat_cmd.go — func runChat
- internal/chat/reduce.go — func Reduce
- internal/chat/render.go — func renderAssistantDoc
- internal/taskboard/board.go — func BuildBoard
- internal/taskboard/frontier.go — func areasOf
- api/lib/barkpark/portable_doc/render.ex — def render_html
