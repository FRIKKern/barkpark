package main

import (
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

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
// lines through the shared registry + theme. The viewport handles scrolling and
// clipping, exactly as it does for the field-form editor.
func (m model) buildPaperContent(width int) string {
	if m.paperRegistry == nil || len(m.selectedPaperBlocks) == 0 {
		return ""
	}
	ctx := pdrender.RenderCtx{
		Width:       width,
		Theme:       m.paperTheme,
		Profile:     m.paperProfile,
		RefResolver: m.resolvePaperRef,
	}
	return m.paperRegistry.RenderDoc(m.selectedPaperBlocks, ctx)
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
