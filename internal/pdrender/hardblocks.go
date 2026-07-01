package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── M2 "hard" blocks — honest, labeled fallbacks ────────────────────────────
//
// These three blocks (diagram / asciicast / image) cannot be faithfully drawn
// in a static, scroll-safe terminal render: no terminal library draws a Mermaid
// graph the way a browser does, a `.cast` is a time-indexed stream that a static
// render collapses to nothing playable, and graphics protocols (sixel/kitty)
// paint at absolute cursor positions and SMEAR when a viewport scrolls (the
// charm-ecosystem report's sharp edge). So each renders a clearly-LABELED box
// that states its ceiling — never a fake of a capability it lacks. The labels
// are the whole point: a reader must not mistake the placeholder for a render
// bug. This mirrors render.ex's email-mode degradation (source-as-`<pre>` +
// caption, plain link) exactly.

// boxStyle is the shared chrome for the M2 placeholder boxes: a rounded border
// in the theme's rule color, one-cell horizontal padding, sized to width. It
// mirrors the figure card / fallback box idiom already used in the package.
func boxStyle(ctx RenderCtx) lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ruleColor(ctx.Theme)).
		Padding(0, 1).
		Width(clampWidth(ctx.Width - 2)) // 2 = the rounded border's two columns
}

// boxLines renders body (already a multi-line string) inside the placeholder box
// and splits to lines. Below MinWidth the box is dropped and the body renders
// flat at full width, matching the graceful-degradation discipline elsewhere.
func boxLines(body string, ctx RenderCtx) []string {
	const chrome = 4 // border (2) + padding (2)
	if ctx.Width-chrome < MinWidth {
		return wrapLines(body, ctx.Width)
	}
	return strings.Split(boxStyle(ctx).Render(body), "\n")
}

// innerWidth is the text width available inside the placeholder box (width minus
// the border + padding chrome), clamped to ≥1.
func innerWidth(ctx RenderCtx) int {
	const chrome = 4 // border (2) + padding (2)
	return clampWidth(ctx.Width - chrome)
}

// ── diagram (Mermaid) ───────────────────────────────────────────────────────
// Mirrors compose_block(diagram)'s EMAIL-mode degradation: a bordered box with
// a header naming the detected Mermaid kind, the folded source (dim, each line
// truncated to the inner width), and a "Figure N." caption noting the limit.
// The article-mode `<pre class="mermaid">` browser render has no terminal
// analogue — no library draws mermaid — so the box IS the honest ceiling.
//
// SEAM: a future `mermaid-ascii`-style dependency could replace the folded
// source with an actual ASCII rendering for the flowchart/graph kinds it
// supports (detect kind below, dispatch on it). We deliberately DON'T add that
// dep now — it would break the lipgloss/x-ansi/chroma/stdlib import discipline,
// and the labeled box is correct (if minimal) for every kind. The detected kind
// is already computed here so wiring such a dep later is a one-branch change.
type diagramRenderer struct{}

func (diagramRenderer) Render(b Block, ctx RenderCtx) []string {
	n := ctx.nextFigure()
	source := attrStr(b.Attrs, "source")
	caption := attrStr(b.Attrs, "caption")
	kind := mermaidKind(source)

	inner := innerWidth(ctx)

	var sb strings.Builder
	sb.WriteString(ctx.Theme.FieldLabel.Render("◇ Mermaid diagram (" + kind + ")"))

	// Folded source: each line dim + truncated so nothing overflows the box.
	for _, line := range strings.Split(strings.TrimRight(source, "\n"), "\n") {
		sb.WriteString("\n")
		sb.WriteString(ctx.Theme.Dim.Render(truncateANSI(line, inner)))
	}

	// "Figure N." caption — shares the document-global counter, like figure —
	// and states the limit so the box isn't mistaken for a render bug.
	cap := "Figure " + itoa(n) + "."
	if caption != "" {
		cap += " " + caption
	}
	cap += " (view in Studio)"
	sb.WriteString("\n")
	sb.WriteString(strings.Join(wrapLines(ctx.Theme.Caption.Render(cap), inner), "\n"))

	return boxLines(sb.String(), ctx)
}

// mermaidKind detects the diagram kind from the FIRST non-empty, non-directive
// source line: the leading keyword (flowchart / graph / sequenceDiagram / …).
// Mirrors the spec's "detect kind from first source line". Unknown / empty →
// "diagram" so the header always names something honest.
func mermaidKind(source string) string {
	for _, raw := range strings.Split(source, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		// Skip an init directive / front-matter fence so the real first
		// statement names the kind (e.g. `%%{init: …}%%` then `flowchart TD`).
		if strings.HasPrefix(line, "%%") || strings.HasPrefix(line, "---") {
			continue
		}
		// The kind is the first whitespace-delimited token (graph TD, flowchart
		// LR, sequenceDiagram, classDiagram, …). Strip a trailing colon/space.
		token := line
		if i := strings.IndexAny(line, " \t"); i >= 0 {
			token = line[:i]
		}
		token = strings.TrimRight(token, ":")
		if token != "" {
			return token
		}
	}
	return "diagram"
}

// ── asciicast ───────────────────────────────────────────────────────────────
// A bordered placeholder: "▶ Asciicast" plus a metadata suffix (duration · dims)
// when the block carries it, plus "· open in browser". The src becomes an OSC 8
// hyperlink when the profile supports it (≥ANSI256), else a dim " (src)" suffix
// so the URL is still reachable on a dumb terminal — the same gate the inline
// link + action CTA use. A `.cast` is a time-indexed stream; a static render
// makes ONE frame, so inline playback is the honest ceiling (mirrors render.ex's
// email-mode "Terminal recording" plain link).
type asciicastRenderer struct{}

func (asciicastRenderer) Render(b Block, ctx RenderCtx) []string {
	src := sanitizeURL(strings.TrimSpace(attrStr(b.Attrs, "src")))

	head := "▶ Asciicast"
	if meta := asciicastMeta(b.Attrs); meta != "" {
		head += " · " + meta
	}
	head += " · open in browser"

	styled := ctx.Theme.FieldLabel.Render(head)
	if src != "" {
		if ctx.Profile.supportsHyperlinks() {
			styled = "\x1b]8;;" + src + "\x1b\\" + styled + "\x1b]8;;\x1b\\"
		} else {
			styled += ctx.Theme.Dim.Render(" (" + src + ")")
		}
	}
	return boxLines(styled, ctx)
}

// asciicastMeta builds the "M:SS · COLSxROWS" suffix from whatever the block
// carries: a top-level duration/cols/rows, or an asciicast v2 cast `header`
// object ({"width":…, "height":…, "duration":…}). Returns "" when nothing is
// known (the suffix is then simply omitted).
func asciicastMeta(m map[string]any) string {
	dur := attrInt(m, "duration", -1)
	cols := attrInt(m, "cols", 0)
	rows := attrInt(m, "rows", 0)

	// asciicast v2 header object: width/height (and sometimes duration) live
	// under a nested "header" map.
	if hdr, ok := m["header"].(map[string]any); ok {
		if cols == 0 {
			cols = attrInt(hdr, "width", 0)
		}
		if rows == 0 {
			rows = attrInt(hdr, "height", 0)
		}
		if dur < 0 {
			dur = attrInt(hdr, "duration", -1)
		}
	}

	var parts []string
	if dur >= 0 {
		parts = append(parts, formatDuration(dur))
	}
	if cols > 0 && rows > 0 {
		parts = append(parts, itoa(cols)+"x"+itoa(rows))
	}
	return strings.Join(parts, " · ")
}

// formatDuration renders whole seconds as M:SS.
func formatDuration(secs int) string {
	if secs < 0 {
		secs = 0
	}
	m := secs / 60
	s := secs % 60
	ss := itoa(s)
	if s < 10 {
		ss = "0" + ss
	}
	return itoa(m) + ":" + ss
}

// ── image ───────────────────────────────────────────────────────────────────
// A bordered placeholder: "🖼 <alt or src> · <W>×<H> (view in Studio)". Real
// sixel/kitty graphics paint at absolute cursor positions and smear/detach when
// a scroll viewport moves them (the report's sharp edge), so inline graphics are
// deferred to a future full-screen expand — the placeholder is the scroll-safe
// path. Mirrors field-image's existing placeholder idiom + render.ex's PdImage
// (src/alt/width/height).
type imageRenderer struct{}

func (imageRenderer) Render(b Block, ctx RenderCtx) []string {
	src := strings.TrimSpace(attrStr(b.Attrs, "src"))
	alt := strings.TrimSpace(attrStr(b.Attrs, "alt"))

	desc := alt
	if desc == "" {
		desc = src
	}
	if desc == "" {
		desc = "No image"
	}

	head := "🖼 " + desc
	if dims := imageDims(b.Attrs); dims != "" {
		head += " · " + dims
	}
	head += " (view in Studio)"

	return boxLines(ctx.Theme.Body.Render(head), ctx)
}

// imageDims builds the "W×H" suffix from width/height when both are present
// (>0), else "".
func imageDims(m map[string]any) string {
	w := attrInt(m, "width", 0)
	h := attrInt(m, "height", 0)
	if w > 0 && h > 0 {
		return itoa(w) + "×" + itoa(h)
	}
	return ""
}
