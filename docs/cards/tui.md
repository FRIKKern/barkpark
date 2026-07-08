<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client in `cmd/barkpark/`: `main.go` → `tui.go` → `store.go`/`schema.go` (`internal/apiclient/`) → `structure.go` desk.

Editing (D12): v1 scalar/ref/array inline; v2 read-only. → docs/contracts/schema-v2.md; keymap → cheatsheets/tui.md.
Desk task `c`/`x` via `/v1/tasks/:id/{claim,close}`.

## Papers / Bulldocs in the TUI
- `cmd/barkpark/paper.go` — viewer; blocks via `internal/pdrender` (`Decode`→`DefaultRegistry(theme)`→`Render`); `bp paper` shares it.
- **Parity rule:** a new block type ships in all three renderers — `render_html/2` (server HTML), `.bp-paper-surface` CSS (root.html.heex), pdrender (terminal).
- **Go pin: `go.mod` `go 1.25.0`** (#726); chroma v2.20.0. Prod builds TUI server-side; don't bump casually.

## `bp tasks` — live portrait task board
Pane `internal/taskboard`, zero-config, SSE-live. NAV (D11): `enter` descends board→task→paper→tasks→children…, `esc` ascends+breadcrumb. Adaptive: two-pane ≥110c else full-frame (±4 hyst). ACTS `c`/`x`/`o` follow reader. Entry `cli.go` `case "tasks"`→`taskboard.Run`.
- `board.go` `BuildBoard` — NOW=in_progress+live-worker only; terminal >24h→`+N done`; clusters, twins.
- `render.go` `func Render` painter (D36–44: momentum bar, rollups, rows, ↳ nesting, spinner; vocab `theme.go`/`spinner.go`). `spine.go` `spineRows`=one paint+cursor source. `compose.go` `Compose`=`View()`.
- `detail_render.go` `RenderTaskDetail`, `paper.go` `RenderPaperFrame`; `detail_data.go` `FetchSnapshotFull`/`ChildrenOf`. `live.go` SSE→refetch · `actions.go` epoch-CAS · `repoctx.go` git.
- **Frontier** `frontier.go` `areasOf` — CLOSED `area:` vocab + `~`phase-band derivation (11 targets+table): docs/contracts/dispatch-areas.md.

Gate `go test ./internal/taskboard/...` (`-tags liveprobe`). `bp tasks` (pane) ≠ `bp task …` (verbs). → docs/setup/TASK-SYSTEM.md.

## Code anchors
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- internal/cli/tasks_board_cmd.go — func runTasksBoard
- internal/taskboard/board.go — func BuildBoard
- internal/taskboard/render.go — func Render
- internal/taskboard/frontier.go — func areasOf, func phaseBandSlug
- api/lib/barkpark/portable_doc/render.ex — def render_html
