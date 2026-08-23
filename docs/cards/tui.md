<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client `cmd/barkpark/`: `main.go`→`tui.go`→`store.go`/`schema.go` (`internal/apiclient/`)→`structure.go` desk.

Editing (D12): v1 scalar/ref/array inline; v2 read-only→docs/contracts/schema-v2.md; keymap→cheatsheets/tui.md.

## Papers / Bulldocs
- Viewer `paper.go`; blocks via `internal/pdrender` (`Decode`→`DefaultRegistry(theme)`→`Render`); `bp paper` shares it.
- **Parity:** new blocks ship in HTML, CSS + pdrender. Doctrine → docs/contracts/tui-render-doctrine.md
- **Go:** `go.mod` pins 1.25.0 (#726); don't bump.

## `bp tasks` — live portrait task board
Pane `internal/taskboard`, zero-config, SSE-live. NAV (D11): `enter` descends board→task→paper→children…, `esc` ascends. **Mouse first-class**: wheel scrolls, click selects+activates, hover previews, `M` toggles reporting. Split = **draggable divider**, persisted `DetailsPaneRatio` in `taskboard-preferences.json`. Tasks open in a borderless, centered 80-col reading measure; breadcrumb retired. ACTS `c`/`x`/`o`. Entry `cli.go` `case "tasks"`→`taskboard.Run`; `spine.go` `spineRows`=sole paint+cursor producer, `compose.go` `Compose`=`View()`. `bp tasks`≠`bp task …`.

## `bp chat` — native terminal chat client
Pane `internal/chat`. Launch=picker. Entry `cli.go` `case "chat"`→`chat.Run`. `reduce.go` `Reduce` settles at `result`, live-tails, handles interrupt (`aborted_streaming` non-error, 8s wedge) + ⧗ queued. `render.go` `renderAssistantDoc`=one `pdrender` RenderDoc/message. PATCH state on leave, re-GET on resume. Keys→cheatsheets/tui.md. Shelf: `a` archives, `s` opens, `enter`/`u` restores; `bp chat unarchive <id>`, `ls --archived`.

## Code anchors
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- scripts/pdrender-dump.sh — offline fixture render; width defaults to 80
- internal/cli/tasks_board_cmd.go — func runTasksBoard
- internal/cli/chat_cmd.go — func runChat
- internal/chat/reduce.go — func Reduce
- internal/chat/render.go — func renderAssistantDoc
- internal/taskboard/board.go — func BuildBoard
- internal/taskboard/spine.go — func spineRows
- internal/taskboard/frontier.go — func areasOf
- api/lib/barkpark/portable_doc/render.ex — def render_html
