package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	ltable "github.com/charmbracelet/lipgloss/table"
)

// ── api-endpoint (B075) ──────────────────────────────────────────────────
// Endpoint doc card: mirrors compose_block(api-endpoint) (compose.ex) — a
// method badge + path line, then a params table (name/in/type/required).
// dev & code, cost STATIC. Empty method+path is the honest empty state (no
// phantom heading for a block with nothing to say); an empty params list
// renders just the method/path line, no zero-row table.
type apiEndpointRenderer struct{}

func (apiEndpointRenderer) Render(b Block, ctx RenderCtx) []string {
	method := strings.ToUpper(sanitizeText(attrStr(b.Attrs, "method")))
	path := sanitizeText(attrStr(b.Attrs, "path"))
	if method == "" && path == "" {
		return nil
	}

	w := clampWidth(ctx.Width)
	head := strings.TrimSpace(ctx.Theme.ActionPrimary.Render(" "+method+" ") + " " + ctx.Theme.InlineCode.Render(path))
	out := []string{truncateANSI(head, w)}

	params := itemMaps(b.Attrs, "params")
	if len(params) == 0 {
		return out
	}
	out = append(out, "")
	out = append(out, renderApiEndpointParams(params, ctx)...)
	return out
}

// renderApiEndpointParams lays the block's `params` as a bordered table —
// the same ltable vocabulary as the `table` block's renderer (richblocks.go).
func renderApiEndpointParams(params []map[string]any, ctx RenderCtx) []string {
	t := ltable.New().
		Width(clampWidth(ctx.Width)).
		Wrap(true).
		Border(lipgloss.NormalBorder()).
		BorderStyle(ctx.Theme.Rule).
		Headers("NAME", "IN", "TYPE", "REQUIRED")

	for _, p := range params {
		t.Row(
			sanitizeText(attrStr(p, "name")),
			sanitizeText(attrStr(p, "in")),
			sanitizeText(attrStr(p, "type")),
			yesNo(p["required"]),
		)
	}

	headerStyle := ctx.Theme.Dim.Bold(true)
	bodyStyle := ctx.Theme.Body
	t.StyleFunc(func(row, col int) lipgloss.Style {
		if row == ltable.HeaderRow {
			return headerStyle.Padding(0, 1)
		}
		return bodyStyle.Padding(0, 1)
	})
	return strings.Split(t.Render(), "\n")
}
