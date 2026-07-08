package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── grid / ladder widgets: notes / pipeline / cards / status-legend ──────────
//
// These four blocks are the terminal counterparts of the PortableDoc grid
// widgets the web/Studio reader draws. Before this file they fell through to the
// "unknown block" fallback box in the TUI/CLI while the web reader rendered them
// fully — a cross-surface divergence this closes (pdrender-block-parity).
//
// A terminal has no reliable responsive grid, so — exactly like the reader
// COLLAPSES grid→stack on a narrow surface — every one of these STACKS
// vertically. notes/pipeline reuse the singular note/stage renderers on a
// synthesized child Block; cards draws its own tone-tinted box; status-legend
// inlines a fixed 6-rung ladder mirroring design/status-manifest.json.
//
// Import discipline holds: only lipgloss + the stdlib, styles come from the
// injected Theme, every document-controlled string passes through sanitizeText
// before display, and each renderer degrades (never panics) on empty attrs, an
// empty item/node, or a sub-MinWidth column.

// itemMaps normalizes a JSON array field (items / nodes) to a []map[string]any,
// dropping any non-object element. Missing/wrong-typed → nil.
func itemMaps(m map[string]any, key string) []map[string]any {
	raw := attrSlice(m, key)
	if raw == nil {
		return nil
	}
	out := make([]map[string]any, 0, len(raw))
	for _, el := range raw {
		if obj, ok := el.(map[string]any); ok {
			out = append(out, obj)
		}
	}
	return out
}

// ── notes ────────────────────────────────────────────────────────────────────
// {items: [{label, lead, text}]}. A vertical list of note "definition rows":
// each item is fed to the singular noteRenderer as a synthesized `note` Block,
// and the rows stack with a blank line between them (the RenderDoc rhythm).
// Rows that render nothing (all-empty item) are dropped so the rhythm never
// doubles; no non-empty item → one blank line.
type notesRenderer struct{}

func (notesRenderer) Render(b Block, ctx RenderCtx) []string {
	items := itemMaps(b.Attrs, "items")
	if len(items) == 0 {
		return []string{""}
	}

	groups := make([][]string, 0, len(items))
	for _, item := range items {
		lines := noteRenderer{}.Render(Block{Type: "note", Attrs: item}, ctx)
		if isBlankGroup(lines) {
			continue
		}
		groups = append(groups, lines)
	}
	if len(groups) == 0 {
		return []string{""}
	}

	out := make([]string, 0)
	for i, g := range groups {
		if i > 0 {
			out = append(out, "") // rhythm between stacked rows
		}
		out = append(out, g...)
	}
	return out
}

// ── pipeline ───────────────────────────────────────────────────────────────────
// {nodes: [{kind, title, detail, files, source}]}. A vertical stack of stage
// cells: each node is fed to the singular stageRenderer as a synthesized `stage`
// Block, and a dim `↓` connector line sits between consecutive nodes (echoing
// the reader's `→` arrows). No connector after the last node. Nodes that render
// nothing are dropped so a connector never dangles; no non-empty node → one
// blank line.
type pipelineRenderer struct{}

func (pipelineRenderer) Render(b Block, ctx RenderCtx) []string {
	nodes := itemMaps(b.Attrs, "nodes")
	if len(nodes) == 0 {
		return []string{""}
	}

	groups := make([][]string, 0, len(nodes))
	for _, node := range nodes {
		lines := stageRenderer{}.Render(Block{Type: "stage", Attrs: node}, ctx)
		if isBlankGroup(lines) {
			continue
		}
		groups = append(groups, lines)
	}
	if len(groups) == 0 {
		return []string{""}
	}

	connector := ctx.Theme.Dim.Render("↓")
	out := make([]string, 0)
	for i, g := range groups {
		if i > 0 {
			out = append(out, connector) // dim link between nodes
		}
		out = append(out, g...)
	}
	return out
}

// ── cards ──────────────────────────────────────────────────────────────────────
// {items: [{title, text, tone}]}, tone ∈ info|ok|warn|danger. Unlike the
// singular `card` (which recurses element slots), these items are FLAT scalars
// with a meaningful tone, so each renders as its OWN rounded box: a bold title +
// wrapped text body, the border tinted by the tone. Boxes stack vertically (the
// terminal has no responsive grid). The box borrows figure/card's construction
// idiom (RoundedBorder, Padding(0,1), chrome=4, flat-degrade below MinWidth) but
// NOT the slot recursion. Empty item → dropped; no non-empty item → one blank
// line.
type cardsRenderer struct{}

func (cardsRenderer) Render(b Block, ctx RenderCtx) []string {
	items := itemMaps(b.Attrs, "items")
	if len(items) == 0 {
		return []string{""}
	}

	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome
	flat := inner < MinWidth
	childWidth := inner
	if flat {
		childWidth = ctx.Width
	}
	childWidth = clampWidth(childWidth)

	groups := make([][]string, 0, len(items))
	for _, item := range items {
		title := sanitizeText(strings.TrimSpace(attrStr(item, "title")))
		text := sanitizeText(strings.TrimSpace(attrStr(item, "text")))
		if title == "" && text == "" {
			continue
		}

		var lines []string
		if title != "" {
			lines = append(lines, wrapLines(ctx.Theme.Body.Bold(true).Render(title), childWidth)...)
		}
		if text != "" {
			lines = append(lines, wrapLines(ctx.Theme.Body.Render(text), childWidth)...)
		}

		if flat {
			groups = append(groups, lines)
			continue
		}

		body := lipgloss.JoinVertical(lipgloss.Left, lines...)
		box := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(cardToneColor(ctx.Theme, attrStr(item, "tone"))).
			Padding(0, 1).
			Width(clampWidth(inner)).
			Render(body)
		groups = append(groups, strings.Split(box, "\n"))
	}
	if len(groups) == 0 {
		return []string{""}
	}

	out := make([]string, 0)
	for i, g := range groups {
		if i > 0 {
			out = append(out, "") // rhythm between stacked boxes
		}
		out = append(out, g...)
	}
	return out
}

// cardToneColor maps a card item's flat tone (info|ok|warn|danger) onto the
// Callout tone seam and returns the bar style's foreground for the box border.
// ok→success, warn→warning, danger→danger, info→info, missing/other→neutral.
func cardToneColor(t Theme, tone string) lipgloss.TerminalColor {
	var key string
	switch strings.TrimSpace(strings.ToLower(tone)) {
	case "ok":
		key = "success"
	case "warn":
		key = "warning"
	case "danger":
		key = "danger"
	case "info":
		key = "info"
	default:
		key = "neutral"
	}
	bar, _ := t.Callout(key)
	if c := bar.GetForeground(); c != nil {
		return c
	}
	return ruleColor(t)
}

// ── status-legend ────────────────────────────────────────────────────────────
// Ignores block attrs — renders a FIXED 6-rung status ladder (the "white
// ladder"). Each row is `glyph  name  — meaning`, the glyph colored by its role
// via the theme tone seam, the name in Body, the meaning in Dim. The rungs stack
// one per line, matching the reader.
type statusLegendRenderer struct{}

// statusRung is one line of the ladder. name/meaning are code-controlled
// literals; the glyph is derived from the shared roleGlyph source and the color
// comes from the injected Theme at render time.
type statusRung struct {
	name    string
	meaning string
}

// roleGlyph is the SINGLE source of the role→glyph mapping shared by the status
// legend AND the task-* widgets (task-list/detail/board/roadmap) — mirrors
// design/status-manifest.json — keep in sync. `progress` has no static glyph in
// the manifest (spinner: true, a Braille frame the reader CSS-animates); a
// static terminal render can't animate, so it shows one steady frame (⠋).
// pdrender must NOT import internal/semrole or internal/taskboard (the
// go-list-deps invariant in render_test.go), so the vocabulary is inlined here.
var roleGlyph = map[string]string{
	"open":     "○",
	"ready":    "○",
	"progress": "⠋",
	"blocked":  "!",
	"done":     "✓",
	"cancel":   "✕",
}

// statusLadder is the ordered set of ladder rungs (the "white ladder"). Each
// rung's glyph is looked up from roleGlyph at render time — ONE place defines
// role→glyph, so a manifest drift can't leave the legend and the task widgets
// disagreeing.
var statusLadder = []statusRung{
	{name: "open", meaning: "backlog — not ready yet"},
	{name: "ready", meaning: "unchecked — claim it now"},
	{name: "progress", meaning: "in progress"},
	{name: "blocked", meaning: "something is required first"},
	{name: "done", meaning: "complete"},
	{name: "cancel", meaning: "abandoned or superseded"},
}

func (statusLegendRenderer) Render(_ Block, ctx RenderCtx) []string {
	out := make([]string, 0, len(statusLadder))
	for _, r := range statusLadder {
		glyph := statusGlyphStyle(ctx.Theme, r.name).Render(glyphForRole(r.name))
		name := ctx.Theme.Body.Render(r.name)
		meaning := ctx.Theme.Dim.Render("— " + r.meaning)
		out = append(out, glyph+"  "+name+"  "+meaning)
	}
	return out
}

// roleForStatus maps a stored lifecycle status onto its ladder role, inlining
// design/status-manifest.json's `statuses` map (pdrender may not import the
// Elixir StatusVocab / internal/semrole). Unknown/empty → the default "open".
func roleForStatus(status string) string {
	switch status {
	case "open":
		return "open"
	case "ready":
		return "ready"
	case "in_progress":
		return "progress"
	case "blocked":
		return "blocked"
	case "done", "closed":
		return "done"
	case "cancelled":
		return "cancel"
	default:
		return "open"
	}
}

// glyphForRole returns the static glyph for a ladder role (unknown role → ○).
func glyphForRole(role string) string {
	if g, ok := roleGlyph[role]; ok {
		return g
	}
	return "○"
}

// glyphForStatus is the row-level convenience the task widgets use: a stored
// status → its role → the themed, colored glyph string. Composes roleForStatus,
// glyphForRole, and the existing statusGlyphStyle color seam.
func glyphForStatus(t Theme, status string) string {
	role := roleForStatus(status)
	return statusGlyphStyle(t, role).Render(glyphForRole(role))
}

// statusGlyphStyle maps a rung's role onto the glyph color: progress→info,
// done→success, blocked→warning (all via the Callout bar style), cancel/open→Dim,
// ready→Body — matching the reader's tone assignment.
func statusGlyphStyle(t Theme, role string) lipgloss.Style {
	switch role {
	case "progress":
		bar, _ := t.Callout("info")
		return bar
	case "done":
		bar, _ := t.Callout("success")
		return bar
	case "blocked":
		bar, _ := t.Callout("warning")
		return bar
	case "ready":
		return t.Body
	default: // open + cancel
		return t.Dim
	}
}

// isBlankGroup reports whether a rendered line group carries no visible content
// (empty, or the single blank line a degraded leaf renderer returns) — so
// notes/pipeline can drop it before joining with rhythm/connector lines.
func isBlankGroup(lines []string) bool {
	for _, l := range lines {
		if strings.TrimSpace(l) != "" {
			return false
		}
	}
	return true
}
