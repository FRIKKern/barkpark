package pdrender

import (
	"strings"
	"unicode"

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
// {items: [{label, lead, text}]}. A list of note "definition rows": each item is
// fed to the singular noteRenderer as a synthesized `note` Block. By default the
// rows STACK with a blank line between them (the RenderDoc rhythm). A block that
// opts INTO the grid (layout:{mode:"grid"}, gridOptIn) lays the rows SIDE-BY-SIDE
// when the surface is wide enough — the shared Flex solver owns the divide and the
// degrade verdict, so a narrow surface (or a note wider than its cell) falls back
// to the byte-identical vertical stack. Rows that render nothing (all-empty item)
// are dropped so the rhythm never doubles; no non-empty item → one blank line.
type notesRenderer struct{}

func (notesRenderer) Render(b Block, ctx RenderCtx) []string {
	items := itemMaps(b.Attrs, "items")
	if len(items) == 0 {
		return []string{""}
	}

	// Full-width pass: render each item as a synthesized note; drop blank rows.
	// This IS the verbatim stack body (rhythm-joined below) AND the source the
	// horizontal path re-renders at cellW — kept alongside so the two agree on N.
	kept := make([]map[string]any, 0, len(items))
	groups := make([][]string, 0, len(items))
	for _, item := range items {
		lines := noteRenderer{}.Render(Block{Type: "note", Attrs: item}, ctx)
		if isBlankGroup(lines) {
			continue
		}
		kept = append(kept, item)
		groups = append(groups, lines)
	}
	if len(groups) == 0 {
		return []string{""}
	}

	// Horizontal path (opt-in via layout:{mode:"grid"}): the shared Flex solver
	// resolves per-cell width and the side-by-side verdict (Measure owns the
	// (W-(N-1)*gutter)/N divide). Re-render each note at cellW so its prose wraps
	// right, then Arrange side-by-side. Falls through to the verbatim stack when
	// narrow (Measure says stack) or a note's min-content overflows its cell (Fits).
	if gridOptIn(b) {
		n := len(groups)
		if cellW, sideBySide := DefaultFlex.Measure(clampWidth(ctx.Width), n); sideBySide {
			cellCtx := ctx.Deeper().WithWidth(cellW)
			nodes := make([]Node, n)
			for i, item := range kept {
				nodes[i] = Node{Lines: noteRenderer{}.Render(Block{Type: "note", Attrs: item}, cellCtx), Width: cellW, Span: 1}
			}
			if DefaultFlex.Fits(nodes) {
				return DefaultFlex.Arrange(nodes)
			}
		}
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
// {nodes: [{kind, title, detail, files, source}]}. Each node is fed to the
// singular stageRenderer as a synthesized `stage` Block. By default the stages
// STACK vertically with a dim `↓` connector line between consecutive nodes. A
// block that opts INTO the grid (layout:{mode:"grid"}, gridOptIn) lays the stages
// LEFT-TO-RIGHT joined by dim `→` separator COLUMNS — the reader's arrow flow —
// when the surface is wide enough. The arrows are their OWN Flex tracks (2N-1
// total: N stages + N-1 arrows), so the shared solver owns ALL the width math (one
// Measure over 2N-1 uniform tracks) — no bespoke arrow-width arithmetic. Falls
// back to the verbatim ↓ stack when narrow (Measure says stack) or a stage's
// min-content overflows its cell (Fits). No connector after the last node; nodes
// that render nothing are dropped so a connector never dangles; none → one blank line.
type pipelineRenderer struct{}

func (pipelineRenderer) Render(b Block, ctx RenderCtx) []string {
	nodes := itemMaps(b.Attrs, "nodes")
	if len(nodes) == 0 {
		return []string{""}
	}

	kept := make([]map[string]any, 0, len(nodes))
	groups := make([][]string, 0, len(nodes))
	for _, node := range nodes {
		lines := stageRenderer{}.Render(Block{Type: "stage", Attrs: node}, ctx)
		if isBlankGroup(lines) {
			continue
		}
		kept = append(kept, node)
		groups = append(groups, lines)
	}
	if len(groups) == 0 {
		return []string{""}
	}

	// Horizontal path (opt-in via layout:{mode:"grid"}): 2N-1 uniform Flex tracks
	// (stage, arrow, stage, …). One Measure sizes every track; the arrow tracks are
	// dim `→` separator columns. Re-render each stage at cellW, then Arrange.
	if gridOptIn(b) {
		nStage := len(groups)
		tracks := 2*nStage - 1
		if cellW, sideBySide := DefaultFlex.Measure(clampWidth(ctx.Width), tracks); sideBySide {
			cellCtx := ctx.Deeper().WithWidth(cellW)
			arrow := ctx.Theme.Dim.Render("→")
			seq := make([]Node, 0, tracks)
			for i, node := range kept {
				if i > 0 {
					seq = append(seq, Node{Lines: []string{arrow}, Width: cellW, Span: 1})
				}
				seq = append(seq, Node{Lines: stageRenderer{}.Render(Block{Type: "stage", Attrs: node}, cellCtx), Width: cellW, Span: 1})
			}
			if DefaultFlex.Fits(seq) {
				return DefaultFlex.Arrange(seq)
			}
		}
	}

	// Linear flow path (opt-in via layout:{mode:"flow"}, flowOptIn): the kept nodes
	// become a rect-box CHAIN over the mermaidflow engine — ──▶ boxes left-to-right,
	// degrading to the TD ▼ stack when they can't fit. Extend-not-fork: the mmGraph
	// is built directly (never re-parsed from synthesized text). Falls through to the
	// legacy ↓ stack only for the empty case (nil).
	if flowOptIn(b) {
		if art := pipelineFlow(kept, ctx); art != nil {
			return art
		}
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
// wrapped text body, the border tinted by the tone. By default the boxes STACK
// vertically; a block that opts INTO the grid (layout:{mode:"grid"}, gridOptIn)
// lays them SIDE-BY-SIDE as equal cells when the surface is wide enough — the
// shared Flex solver owns the divide + degrade verdict, so a narrow surface (or an
// over-wide card) falls back to the byte-identical stack. The box borrows
// figure/card's construction idiom (RoundedBorder, Padding(0,1), chrome=4,
// flat-degrade below MinWidth) but NOT the slot recursion. Empty item → dropped;
// no non-empty item → one blank line.
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

	// Full-width pass: build each item's box (the verbatim stack body AND the count
	// the horizontal path re-sizes); drop all-empty items so N is honest.
	kept := make([]map[string]any, 0, len(items))
	groups := make([][]string, 0, len(items))
	for _, item := range items {
		box, ok := cardBox(ctx.Theme, item, childWidth, clampWidth(inner), flat)
		if !ok {
			continue
		}
		kept = append(kept, item)
		groups = append(groups, box)
	}
	if len(groups) == 0 {
		return []string{""}
	}

	// Horizontal path (opt-in via layout:{mode:"grid"}): the shared Flex solver
	// sizes each box to an equal cell (Measure owns the divide + verdict). Rebuild
	// each box at the cell's inner width (cellW-chrome) and Arrange side-by-side.
	// Falls through to the stack when narrow, when a cell can't hold the bordered
	// box (inner below MinWidth), or when a card's min-content overflows (Fits).
	if gridOptIn(b) {
		n := len(groups)
		if cellW, sideBySide := DefaultFlex.Measure(clampWidth(ctx.Width), n); sideBySide {
			if cellInner := cellW - chrome; cellInner >= MinWidth {
				nodes := make([]Node, n)
				for i, item := range kept {
					// Never the flat degrade in a cell: the cell holds the bordered box.
					box, _ := cardBox(ctx.Theme, item, cellInner, cellInner, false)
					nodes[i] = Node{Lines: box, Width: cellW, Span: 1}
				}
				if DefaultFlex.Fits(nodes) {
					return DefaultFlex.Arrange(nodes)
				}
			}
		}
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

// cardBox builds ONE `cards` item box: a bold title + wrapped text body, the
// rounded border tinted by the item's tone. `wrapWidth` wraps the title/body;
// `boxInner` is the border box's inner Width; `flat` drops the border (the narrow
// degrade), returning the bare lines. ok=false for an all-empty item (dropped by
// the caller). The full-width caller passes the pre-flat-resolved widths, so its
// output is byte-identical to before this helper was lifted out.
func cardBox(theme Theme, item map[string]any, wrapWidth, boxInner int, flat bool) (lines []string, ok bool) {
	title := sanitizeText(strings.TrimSpace(attrStr(item, "title")))
	text := sanitizeText(strings.TrimSpace(attrStr(item, "text")))
	if title == "" && text == "" {
		return nil, false
	}
	if title != "" {
		lines = append(lines, wrapLines(theme.Body.Bold(true).Render(title), wrapWidth)...)
	}
	if text != "" {
		lines = append(lines, wrapLines(theme.Body.Render(text), wrapWidth)...)
	}
	if flat {
		return lines, true
	}
	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cardToneColor(theme, attrStr(item, "tone"))).
		Padding(0, 1).
		Width(clampWidth(boxInner)).
		Render(body)
	return strings.Split(box, "\n"), true
}

// gridOptIn reports whether a grid widget (notes/pipeline/cards) opts INTO the
// side-by-side horizontal layout via a `layout:{mode:"grid"}` object — the SAME
// predicate the section grid uses (compose.ex grid_layout/1; blocks.go section).
// ABSENT / any other layout shape → false, so the legacy corpus (which carries no
// layout) keeps its verbatim vertical stack, byte-identical to before.
func gridOptIn(b Block) bool {
	layout, ok := b.Attrs["layout"].(map[string]any)
	return ok && attrStr(layout, "mode") == "grid"
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

// roleGlyph is the SINGLE source of the role→glyph mapping shared by the status
// legend AND the task-* widgets (task-list/detail/board/roadmap) — mirrors
// design/status-manifest.json — keep in sync. `progress` has no static glyph in
// the manifest (spinner: true, a Braille frame the reader CSS-animates); a
// static terminal render can't animate, so it shows one steady frame (⠋).
// pdrender must NOT import internal/semrole or internal/taskboard (the
// go-list-deps invariant in render_test.go), so the vocabulary is inlined here.
var roleGlyph = map[string]string{
	"open":        "○",
	"ready":       "○",
	"progress":    "⠋",
	"blocked":     "!",
	"done":        "✓",
	"cancel":      "✕",
	"considering": "◌", // dotted circle — a candidate being weighed (dim)
	"researching": "◎", // bullseye — under active investigation (violet on colour surfaces)
}

// roleLabel is the SINGLE source of the role→canonical (lowercase) display label,
// mirroring design/status-manifest.json's `roles[].label` — the legend prints
// this, the board sentence-cases it (boardLabel). Byte-checked against the
// manifest by scripts/status-manifest-check.sh Part 4 (like roleGlyph in Part 3).
var roleLabel = map[string]string{
	"open":        "open",
	"ready":       "ready",
	"progress":    "in progress",
	"blocked":     "blocked",
	"done":        "done",
	"cancel":      "cancelled",
	"considering": "considering",
	"researching": "researching",
}

// roleMeaning mirrors design/status-manifest.json's `roles[].meaning` — the
// one-line legend gloss. Byte-checked against the manifest by Part 4.
var roleMeaning = map[string]string{
	"open":        "backlog — not ready yet",
	"ready":       "unchecked — claim it now",
	"progress":    "being worked right now",
	"blocked":     "something is required first",
	"done":        "complete",
	"cancel":      "abandoned or superseded",
	"considering": "a candidate being weighed",
	"researching": "under active investigation",
}

// statusLadder is the ordered set of ladder role slugs (the "white ladder"). Each
// rung's glyph/label/meaning is looked up from the shared maps at render time —
// ONE place defines each, so a manifest drift can't leave the legend and the task
// widgets disagreeing. The two thought states (considering/researching) sit at the
// BOTTOM of the ladder (charter D9 — the brightness ladder extends downward,
// dimmer than open-backlog) so a reader sees the full arc from first thought to done.
var statusLadder = []string{"open", "ready", "progress", "blocked", "done", "cancel", "considering", "researching"}

// labelForRole returns the canonical lowercase display label (unknown → the slug).
func labelForRole(role string) string {
	if l, ok := roleLabel[role]; ok {
		return l
	}
	return role
}

// capitalizeFirst sentence-cases a label (first rune upper, rest unchanged):
// "in progress" → "In progress", "cancelled" → "Cancelled".
func capitalizeFirst(s string) string {
	if s == "" {
		return s
	}
	r := []rune(s)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}

func (statusLegendRenderer) Render(_ Block, ctx RenderCtx) []string {
	out := make([]string, 0, len(statusLadder))
	for _, role := range statusLadder {
		glyph := statusGlyphStyle(ctx.Theme, role).Render(glyphForRole(role))
		name := ctx.Theme.Body.Render(labelForRole(role))
		meaning := ctx.Theme.Dim.Render("— " + roleMeaning[role])
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
	case "considering":
		return "considering"
	case "researching":
		return "researching"
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
