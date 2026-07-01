<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client in `cmd/barkpark/`. Files: `main.go` → `tui.go` → `store.go`/`schema.go` (shim HTTP/SSE `internal/apiclient/`) → `structure.go` desk (`/v1/structure/:dataset`) → `styles.go`.

Constraint (D12): docs whose schema uses v2 field types (composite/arrayOf) render as **JSON dumps** — the editor skips them; Studio is the editing surface. → docs/contracts/schema-v2.md.

## Papers / Bulldocs in the TUI
- `cmd/barkpark/paper.go` — TUI paper viewer (`buildPaperContent`, reading col max 100 chars); renders blocks via `internal/pdrender` (`Decode` → `DefaultRegistry(theme)` → per-block `Render`); `bp paper` (internal/cli) shares it.
- `"sheet"` embeds → PdSheet (internal/pdrender/sheet.go): adapter lifts snapshot head/rows; merges render anchor-value only, styles + px col_widths drop (auto-size).
- **Parity rule:** a new block type must land in all three renderers — `Render.render_html/2` (server HTML), `.bp-paper-surface` CSS in root.html.heex, and pdrender (terminal). Don't ship one without the others.
- **HARD pin: `go.mod` stays `go 1.24.2`** — chroma pinned v2.20.0; the prod hook builds the TUI on the server. Do not bump.

Editing: v1 fields inline (ref picker; image URL keeps assetId if unchanged; text/richText/string-arrays: textarea — enter=newline ctrl+s=commit; arrays/numbers/bools save TYPED; datetime/number/pattern validate, required shows *; blocks richText read-only); `/` search; `ctrl+s` save · `ctrl+p` publish · `U` unpub · `d` diff · `H` history (enter diffs; no restore) · `R`×2 discard (twin-guarded) · `n` new · `y` dup · `D`×2 delete (ctrl+d = paper half-page). Bulk: `space` marks rows; `ctrl+p`/`U` act on marked. `?` key overlay.
Scope: `s` selector (`n` creates ws/proj, server slugs+seeds; `m` manual).
Task lists (`type:task`): `c` claim / `x` close via flat `/v1/tasks/:id/{claim,close}`; worker id `BARKPARK_WORKER_ID`, default `tui-<hostname>`; close echoes `claim.epoch`.

## Code anchors
- cmd/barkpark/tui-update.go — func Update
- cmd/barkpark/tui-render.go — func buildEditorContent
- cmd/barkpark/paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- internal/pdrender/decode.go — func Decode
- api/lib/barkpark/portable_doc/render.ex — def render_html
