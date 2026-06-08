package main

import (
	"math"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// A4-portrait reading column for the TUI paper viewer.
//
// pdrender is width-agnostic — it renders a block tree to whatever column count
// the caller hands it. Left to its own devices the caller passed the FULL pane
// width, so on a wide terminal a paper's prose sprawled edge to edge. These
// constants let buildPaperContent cap the render to a column proportioned like an
// A4 page (210mm × 297mm portrait) and CENTER it in the pane — the cap + centering
// live entirely in this caller; pdrender never learns about page geometry.
const (
	// paperCellAspect is the terminal cell height-to-width ratio. A monospace cell
	// is roughly twice as tall as it is wide, so to make a column LOOK like A4
	// portrait we multiply the visible row count by this before applying the page
	// ratio. cellH/cellW ≈ 2.0.
	paperCellAspect = 2.0
	// a4PortraitWHRatio is A4 portrait's width-over-height ratio (210/297).
	a4PortraitWHRatio = 210.0 / 297.0
	// minPaperWidth is the readable FLOOR for the A4 column: a short terminal would
	// otherwise compute an unreadably narrow column. The A4 ratio is honored ABOVE
	// this floor; paneW is the only upper cap.
	minPaperWidth = 48
)

// a4PaperWidth returns the A4-portrait column width to render the paper at, given
// the visible row count and the available pane content width.
//
//	a4Cols = round(visibleRows · paperCellAspect · a4PortraitWHRatio)  (≈ rows·1.414)
//
// then clamped to [minPaperWidth, paneW]. The cap at paneW means a terminal
// narrower than the A4 width simply uses the whole pane (and the caller pads 0 —
// no centering). There is deliberately NO low hard max above the floor, so a tall
// terminal keeps the true A4 proportion rather than being pinned to some arbitrary
// "max reading width".
func a4PaperWidth(visibleRows, paneW int) int {
	if paneW < 1 {
		paneW = 1
	}
	a4Cols := int(math.Round(float64(visibleRows) * paperCellAspect * a4PortraitWHRatio))
	w := a4Cols
	if w < minPaperWidth {
		w = minPaperWidth
	}
	if w > paneW {
		w = paneW
	}
	if w < 1 {
		w = 1
	}
	return w
}

// termenv profile constants, aliased so detectPaperProfile reads against named
// values rather than the raw iota order (TrueColor=0, ANSI256=1, ANSI=2, Ascii=3).
// lipgloss.ColorProfile() returns a termenv.Profile.
const (
	termenvTrueColor = termenv.TrueColor
	termenvANSI256   = termenv.ANSI256
	termenvANSI      = termenv.ANSI
	termenvAscii     = termenv.Ascii
)

// paper.go wires the pdrender portable-doc renderer into the TUI. pdrender stays
// import-clean (it never imports package main or apiclient); this file is the
// adapter — it builds a pdrender.Theme from the styles.go palette, detects the
// terminal color profile once, and renders a selected paper's block tree through
// the SAME registry + theme the rest of the TUI uses.
//
// A paper is READ-ONLY in the TUI (the documented v1 constraint): the field-form
// editor never touches it. It renders as a real document; edits happen in Studio.

// barkparkPaperTheme builds a pdrender.Theme from the styles.go palette so a
// paper renders in the TUI's own colors — blue accent, zinc-grey body, the same
// dividers/labels/publish-button idiom the field editor uses. The chroma syntax
// style is chosen by terminal background (monokai on dark, github on light).
//
// pdrender already ships DarkTheme/LightTheme that mirror this palette; this
// builder exists so the mapping is EXPLICIT and sourced from styles.go vars
// (highlight, dimText, the dot colors, editorLabelStyle, publishBtnStyle) rather
// than pdrender's private copies — if styles.go shifts, the paper follows.
func barkparkPaperTheme() pdrender.Theme {
	dark := lipgloss.HasDarkBackground()

	body := normalItemStyle   // zinc-grey body text
	dim := dimStyle           // muted — captions, byline, link suffix
	rule := dividerStyle      // hairline rules
	label := editorLabelStyle // bold muted field label
	accent := highlight       // blue accent → headings/links/accent

	t := pdrender.Theme{
		Body:   body,
		Dim:    dim,
		Accent: accent,
		Rule:   rule,
		InlineCode: lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#be123c", Dark: "#fda4af"}).
			Background(lipgloss.AdaptiveColor{Light: "#f4f4f5", Dark: "#27272a"}),
		Link: lipgloss.NewStyle().
			Foreground(accent).
			Underline(true),
		Eyebrow: lipgloss.NewStyle().
			Foreground(accent).
			Bold(true),
		Byline:    dim,                                                  // dimStyle → byline
		Pullquote: lipgloss.NewStyle().Foreground(dimText).Italic(true), // dimStyle muted → pullquote
		Caption:   lipgloss.NewStyle().Foreground(dimText).Italic(true), // dimStyle → caption
	}

	// Headings — terminals have no font sizes, so level encodes as weight/accent.
	// L1: headerStyle (bold ink, underlined by the renderer), L2: bold accent,
	// L3: bold dim. headerStyle carries Padding(0,1); strip it so a heading line
	// lays out flush with body text inside the viewport.
	heading0 := headerStyle.Padding(0, 0) // headerStyle → L1 (bold ink)
	t.Heading[0] = heading0
	t.Heading[1] = lipgloss.NewStyle().Bold(true).Foreground(accent)  // highlight → L2
	t.Heading[2] = lipgloss.NewStyle().Bold(true).Foreground(dimText) // dim → L3

	// Code block: a left accent bar (mirrors doc.css's 3px border) + a chroma
	// style picked by background.
	t.CodeBar = lipgloss.NewStyle().Foreground(accent)
	if dark {
		t.ChromaStyle = "monokai"
	} else {
		t.ChromaStyle = "github"
	}

	// Action buttons: primary reuses the publishBtnStyle idiom (filled accent bg,
	// white fg, bold); secondary is an accent-outline box.
	t.ActionPrimary = publishBtnStyle
	t.ActionSecondary = lipgloss.NewStyle().
		Foreground(accent).
		Border(lipgloss.NormalBorder()).
		BorderForeground(accent).
		Bold(true)

	// Field label → editorLabelStyle (bold muted).
	t.FieldLabel = label

	// Ingress: brighter ink standfirst with a left accent bar; pullquote bar uses
	// the same accent (the terminal substitutes a bar for the larger font size).
	t.Ingress = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"})
	t.IngressBar = lipgloss.NewStyle().Foreground(accent)
	t.PullquoteBar = lipgloss.NewStyle().Foreground(accent)

	// Callout tones → the TUI's adaptive dot colors: info=blue, success=green,
	// warning=amber, danger=red, neutral=grey. bar + body share the tone color.
	t.Callout = func(tone string) (bar, bodyStyle lipgloss.Style) {
		var c lipgloss.TerminalColor
		switch tone {
		case "success":
			c = greenDot
		case "warning":
			c = amberDot
		case "danger":
			c = lipgloss.AdaptiveColor{Light: "#b91c1c", Dark: "#f87171"}
		case "neutral":
			c = dimText
		default: // info + unknown
			c = blueDot
		}
		bar = lipgloss.NewStyle().Foreground(c)
		bodyStyle = lipgloss.NewStyle().Foreground(c)
		return bar, bodyStyle
	}

	return t
}

// detectPaperProfile maps the terminal's color profile to a pdrender.Profile.
//
// It defaults to a SAFE ANSI256: TrueColor is only selected when termenv is
// certain the terminal supports 24-bit color, because emitting truecolor escapes
// into a Bubble Tea viewport that re-styles its own frame can bleed ANSI. ANSI256
// renders the blue/grey/dot palette faithfully without that risk. A genuinely
// color-less terminal (Ascii) still degrades to NoColor.
func detectPaperProfile() pdrender.Profile {
	switch lipgloss.ColorProfile() {
	case termenvAscii:
		return pdrender.NoColor
	case termenvANSI:
		return pdrender.ANSI16
	case termenvANSI256:
		return pdrender.ANSI256
	case termenvTrueColor:
		return pdrender.TrueColor
	default: // anything unrecognised → the safe ANSI256 floor
		return pdrender.ANSI256
	}
}

// isPaper reports whether a document is a paper that actually carries a
// renderable block tree. A paper with no blocks (a stub) returns false so the
// caller falls back to the existing field-form / empty view instead of rendering
// an empty document.
func isPaper(doc *Doc) bool {
	return doc != nil && doc.Type == "paper" && len(doc.PaperBlocks()) > 0
}

// buildPaperContent renders the selected paper's block tree to width-fitted ANSI
// lines through the shared registry + theme, capped to an A4-portrait column and
// centered within the pane. The viewport handles scrolling and clipping, exactly
// as it does for the field-form editor.
//
//	paneW (the width arg) is the full pane content width the editor/preview gives us.
//	visibleRows is the paper viewport's interior height — every paper render path
//	(viewport content, preview column, pre-vpReady fallback) sizes that interior to
//	m.paneHeight(), so that single value is the visible-row count A4 is derived from.
//
// The render happens at paperWidth ≤ paneW (NOT paneW); when paperWidth < paneW the
// rendered column is centered by prefixing leftPad spaces to every line. When the
// terminal is too narrow for the A4 width, paperWidth == paneW and leftPad == 0 — the
// unchanged full-width behaviour. Because leftPad + paperWidth ≤ paneW, no centered
// line can exceed paneW (the View() clampBlock backstop still applies regardless).
func (m model) buildPaperContent(width int) string {
	if m.paperRegistry == nil || len(m.selectedPaperBlocks) == 0 {
		return ""
	}
	paneW := width
	visibleRows := m.paneHeight() // viewport / preview interior height — the A4 height term
	paperWidth := a4PaperWidth(visibleRows, paneW)

	ctx := pdrender.RenderCtx{
		Width:       paperWidth,
		Theme:       m.paperTheme,
		Profile:     m.paperProfile,
		RefResolver: m.resolvePaperRef,
	}
	rendered := m.paperRegistry.RenderDoc(m.selectedPaperBlocks, ctx)

	// Center the A4 column in the pane. When paperWidth == paneW (narrow terminal),
	// leftPad is 0 and the content is returned unchanged at full width.
	leftPad := (paneW - paperWidth) / 2
	if leftPad < 0 {
		leftPad = 0
	}
	if leftPad == 0 {
		return rendered
	}
	return centerPaperLines(rendered, leftPad)
}

// centerPaperLines prefixes leftPad spaces to EVERY rendered line — a local mirror
// of tui.go's indentLines, kept here so the paper render path is self-contained and
// reads against the A4 centering intent (indentLines exists for the field-form box
// idiom). The padding is plain leading spaces, which never disturb the ANSI styling
// of the rendered content that follows.
func centerPaperLines(s string, leftPad int) string {
	pad := strings.Repeat(" ", leftPad)
	parts := strings.Split(s, "\n")
	for i, p := range parts {
		parts[i] = pad + p
	}
	return strings.Join(parts, "\n")
}

// resolvePaperRef is the RefResolver seam: given a referenced doc id, it returns
// that doc's title from whatever the datastore already has loaded, falling back
// to the raw id when the referenced doc isn't in memory (no blocking fetch — the
// renderer stays synchronous).
func (m model) resolvePaperRef(id, _ string) string {
	if m.ds == nil || id == "" {
		return id
	}
	// Scan the loaded schemas' types for a doc with this id. The datastore caches
	// per-type query results; a miss just returns the id, which is a valid display.
	for i := range schemas {
		for _, d := range m.ds.Query(schemas[i].Name, "") {
			if d.ID == id && d.Title != "" {
				return d.Title
			}
		}
	}
	return id
}
