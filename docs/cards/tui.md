<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client in `cmd/barkpark/`. Files: `main.go` → `tui.go` → `store.go`/`schema.go` (HTTP/SSE `internal/apiclient/`) → `structure.go` desk.

Editing (D12): v1 scalar/ref/array fields edit inline; v2 types + blocks + papers are read-only — Studio edits them. → docs/contracts/schema-v2.md; keymap → docs/cheatsheets/tui.md.
Task `type:task` `c` claim / `x` close via flat `/v1/tasks/:id/{claim,close}`; worker id `BARKPARK_WORKER_ID` else `tui-<hostname>`, close echoes `claim.epoch`.

## Papers / Bulldocs in the TUI
- `cmd/barkpark/paper.go` — TUI paper viewer (`buildPaperContent`, col max 100); blocks via `internal/pdrender` (`Decode` → `DefaultRegistry(theme)` → `Render`); `bp paper` shares it.
- **Parity rule:** a new block type lands in all three renderers — `render_html/2` (server HTML), `.bp-paper-surface` CSS (root.html.heex), pdrender (terminal). Ship all three.
- **Go pin: `go.mod` is `go 1.25.0`** (#726); chroma v2.20.0. The prod post-merge hook builds the TUI on the server — don't bump casually.

## `bp tasks` — live portrait task board
Interactive pane (`internal/taskboard`), zero-config, SSE-live. It ACTS: `c`/`x`/`o` → a role-colored strip above the footer (`o` keeps the Studio URL's doc-id tail). Entry: `internal/cli/cli.go` `case "tasks"` → `tasks_board_cmd.go` → `taskboard.Run`. Packages:
- `board.go` — `BuildBoard` policy; NOW = in_progress + live worker only (closed rows keep their worker), terminal >24h → `+N done`.
- `render.go` — pure `(Board,UIState,w,h,now)→string` frame + act strip.
- `live.go` — SSE dirty-bit → debounced refetch; events never carry truth.
- `actions.go` — `c` claim / `x` close (epoch-CAS) + Studio URL.
- `repoctx.go` — git correlation → `↳ git` badge + rank boost (advisory).

Gate `go test ./internal/taskboard/...` (`-tags liveprobe` = live wire probe). `bp tasks` (pane) ≠ `bp task …` (manifest verbs). → docs/setup/TASK-SYSTEM.md.

## Code anchors
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- internal/cli/tasks_board_cmd.go — func runTasksBoard
- internal/taskboard/board.go — func BuildBoard
- internal/taskboard/render.go — func Render
- api/lib/barkpark/portable_doc/render.ex — def render_html
