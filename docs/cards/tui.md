<!-- doc-tier: agent | canonical-for: go-tui | budget: 350tok -->
# Go TUI

Terminal Studio client at repo root. File map: `main.go` entry → `tui.go` Bubble Tea panes + editor → `store.go` HTTP + SSE client → `schema.go` schema load → `structure.go` nav tree from schemas → `styles.go` Lip Gloss.

Constraint (D12): documents whose schema uses v2 field types (composite / arrayOf / codelist / localizedText) render as **JSON dumps** — the TUI editor skips them; Studio is the editing surface. Declared v1 constraint, not a bug. → docs/contracts/schema-v2.md.

## Papers / Bulldocs in the TUI
- `paper.go` is the TUI paper viewer (`buildPaperContent`, A4-portrait max-width column); it renders Bulldocs portable-doc blocks via `internal/pdrender` (`Decode` → `DefaultRegistry(theme)` → per-block `Render`). `bp paper` (internal/cli/paper_cmd.go) uses the same package.
- **Parity rule:** a new block type must land in all three renderers — `Barkpark.PortableDoc.Render.render_html/2` (server HTML), the paper-surface CSS in `api/lib/barkpark_web/layouts/root.html.heex` (`.bp-paper-surface`), and pdrender (terminal). Don't ship one without the others.
- **HARD pin: `go.mod` stays `go 1.24.2`** — chroma is pinned v2.20.0, and the prod post-merge hook builds the Go TUI on the server. Do not bump.

Editing: v1 fields inline; `ctrl+s` save · `ctrl+p` publish (drafts) · `n` new doc (list panes).

## Code anchors
- tui.go — func Update, func buildEditorContent
- paper.go — func buildPaperContent, func isPaper
- internal/pdrender/pdrender.go — func DefaultRegistry
- internal/pdrender/decode.go — func Decode
- api/lib/barkpark/portable_doc/render.ex — def render_html
