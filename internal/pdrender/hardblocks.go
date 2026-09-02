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
// a header naming the detected Mermaid kind, the complete wrapped source, and a
// caption noting the limit. The article-mode `<pre class="mermaid">`
// browser render has no full terminal analogue, so the box is the honest
// complete-source ceiling for kinds the native renderer cannot draw.
//
// The SEAM is now realized for the kinds we can draw well: a native, dependency-
// free layout engine turns `flowchart`/`graph` source into ranked boxes + a
// box-drawing connector bus (mermaid.go + mermaidflow.go), and `sequenceDiagram`
// source into a lifeline ladder on the shared Flex solver (mermaidseq.go) — both
// responsive and always rectangular. Kinds we don't yet draw (and any diagram too
// narrow to fit cleanly) keep the honest folded-source box below: a reader never
// sees a half-drawn diagram.
type diagramRenderer struct{}

func (diagramRenderer) Render(b Block, ctx RenderCtx) []string {
	// EMPTY-CHROME INVARIANT (blank.go): a diagram with NEITHER a source NOR a
	// caption renders nothing — not the "◇ Mermaid diagram (diagram)" box with a
	// lone "(view in Studio)" line, which reads as a broken figure and mirrors
	// the 328-byte silent card the web reader stopped emitting in #14991.
	// EITHER field alone still renders.
	if blankDiagram(b.Attrs) {
		return nil
	}

	source := attrStr(b.Attrs, "source")
	caption := sanitizeText(attrStr(b.Attrs, "caption"))
	kind := mermaidKind(source)

	// Drawable kinds render as real terminal art with a Figure caption beneath.
	// renderFlowchart/renderSequence return nil when they can't draw cleanly at
	// this width, so control falls through to the folded box below.
	if doc := parseMermaid(source); doc.kind != "" {
		var art []string
		switch doc.kind {
		case "flowchart":
			// Scenario heuristics (mermaidheur.go): measure the graph, choose the
			// strategy — LR box-art (declared, or a chain auto-oriented sideways),
			// the TD bus, or the indented tree view for graphs the boxes would
			// crush or mislead. Direction stays a responsive flex-direction.
			art = renderFlowchartAuto(doc.graph, ctx)
		case "sequence":
			art = renderSequence(doc.seq, ctx)
		}
		if len(art) > 0 {
			return append(art, diagramCaption(caption, ctx)...)
		}
	}

	inner := innerWidth(ctx)

	var sb strings.Builder
	sb.WriteString(ctx.Theme.FieldLabel.Render("◇ Mermaid diagram (" + sanitizeText(kind) + ")"))

	// Folded source: preserve every authored token. A narrow terminal may add
	// continuation rows, but it must not replace source with renderer ellipsis.
	for _, line := range strings.Split(strings.TrimRight(source, "\n"), "\n") {
		wrapped := hardBoundDisplayLines(
			[]string{ctx.Theme.Dim.Render(sanitizeCodeText(line))},
			inner,
		)
		for _, continuation := range wrapped {
			sb.WriteString("\n")
			sb.WriteString(continuation)
		}
	}

	// Caption: the author's text (an author-typed "Figure N." lead emphasised,
	// never one we invent) plus the limit, so the box isn't mistaken for a render
	// bug. With no caption the limit note stands alone.
	capLine := figureCaption(caption, ctx)
	studio := ctx.Theme.Caption.Render("(view in Studio)")
	if capLine == "" {
		capLine = studio
	} else {
		capLine += ctx.Theme.Caption.Render(" ") + studio
	}
	sb.WriteString("\n")
	sb.WriteString(strings.Join(wrapLines(capLine, inner), "\n"))

	return boxLines(sb.String(), ctx)
}

// diagramCaption is the caption line beneath a drawn diagram: the AUTHOR'S
// caption, with an author-typed "Figure N." lead emphasised the way the web
// reader does — pdrender numbers nothing (figureCaption). No caption → no line.
// A drawn diagram needs no "view in Studio" suffix (it IS the render), unlike
// the folded fallback box which states its ceiling.
func diagramCaption(caption string, ctx RenderCtx) []string {
	styled := figureCaption(caption, ctx)
	if styled == "" {
		return nil
	}
	return hardBoundDisplayLines(
		wrapLines(styled, clampWidth(ctx.Width)),
		ctx.Width,
	)
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
//
//	asciicast: {src, caption?, poster?}
//
//	- poster carries no TUI-visible effect. It is an asciinema-player option
//	  (an npt timestamp naming the frame the WEB player rests on before play);
//	  with no player here there is no resting frame to choose. Same ruling as
//	  video.go's poster — a browser-only affordance, deliberately inert.
type asciicastRenderer struct{}

func (asciicastRenderer) Render(b Block, ctx RenderCtx) []string {
	// EMPTY-CHROME INVARIANT (blank.go): a recording with NEITHER a cast URL NOR
	// a caption renders nothing — not a bordered "▶ Asciicast · open in browser"
	// mount with no cast behind it (the web twin of that mount carried
	// data-cast-src="#" and the player tried to FETCH it; #14991). `poster`,
	// `rows`, `cols` and `duration` are player options, so a meta-only block is
	// still blank even though asciicastMeta could spell a suffix out of it.
	if blankAsciicast(b.Attrs) {
		return nil
	}

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
	src := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "src")))
	alt := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "alt")))

	// The real picture, when the terminal + caller allow it: a TrueColor
	// profile and a wired ImageResolver paint a half-block mosaic
	// (imagemosaic.go); every miss below falls through to the honest box.
	if src != "" && ctx.ImageResolver != nil && ctx.Profile == TrueColor {
		if raw := ctx.ImageResolver(src); raw != nil {
			if lines, ok := renderImageMosaic(raw, alt, src, ctx); ok {
				w := clampWidth(ctx.Width)
				for i := range lines {
					lines[i] = padRight(lines[i], w)
				}
				return lines
			}
		}
	}

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
