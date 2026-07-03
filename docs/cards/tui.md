<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client in `cmd/barkpark/`: `main.go` → `tui.go` → `store.go`/`schema.go` (`internal/apiclient/`) → `structure.go` desk.

Editing (D12): v1 scalar/ref/array fields edit inline; v2 types + blocks + papers are read-only (Studio edits them). → docs/contracts/schema-v2.md; keymap → cheatsheets/tui.md.
Task `c` claim / `x` close via `/v1/tasks/:id/{claim,close}`; worker id `BARKPARK_WORKER_ID` else `tui-<hostname>`, close echoes `claim.epoch`.

## Papers / Bulldocs in the TUI
- `cmd/barkpark/paper.go` — paper viewer; blocks via `internal/pdrender` (`Decode` → `DefaultRegistry(theme)` → `Render`); `bp paper` shares it.
- **Parity rule:** a new block type ships in all three renderers — `render_html/2` (server HTML), `.bp-paper-surface` CSS (root.html.heex), pdrender (terminal).
- **Go pin: `go.mod` is `go 1.25.0`** (#726); chroma v2.20.0. Prod post-merge builds the TUI server-side; don't bump casually.

## `bp tasks` — live portrait task board
Interactive pane (`internal/taskboard`), zero-config, SSE-live. ACTS via `c`/`x`/`o`/`t` (claim/close/Studio/apply-tag) → a role strip. Entry `cli.go` `case "tasks"` → `tasks_board_cmd.go` → `taskboard.Run`. Packages:
- `board.go` — `BuildBoard`; NOW = in_progress + live worker only, terminal >24h → `+N done`. CLUSTERS group unkeyed tasks by label; `Stale` = cold non-terminal rows; twins mark near-dup titles (`TwinTitle` = partner name).
- `render.go`/`chips.go` — pure frame + act strip; identity-hue chips (section tag suppressed), `~` cluster cue, `N stale` + age tokens, twin `⧉`.
- `live.go` — SSE dirty-bit → debounced refetch; first paint from a cached snapshot.
- `actions.go` — `c`/`x` (epoch-CAS) + Studio URL. `repoctx.go` — git correlation → `↳ git` badge + boost (advisory).

Gate `go test ./internal/taskboard/...` (`-tags liveprobe` = live probe, never CI). `bp tasks` (pane) ≠ `bp task …` (verbs). → docs/setup/TASK-SYSTEM.md.

## Code anchors
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- internal/cli/tasks_board_cmd.go — func runTasksBoard
- internal/taskboard/board.go — func BuildBoard
- internal/taskboard/render.go — func Render
- api/lib/barkpark/portable_doc/render.ex — def render_html
