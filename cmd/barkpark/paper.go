package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// Width-driven reading column for the TUI paper viewer.
//
// pdrender is width-agnostic — it renders a block tree to whatever column count
// the caller hands it. Left to its own devices the caller passed the FULL pane
// width, so on a wide terminal a paper's prose sprawled edge to edge. The cap
// below lets buildPaperContent render to a comfortable measure and CENTER it in
// the pane — the cap + centering live entirely in this caller; pdrender never
// learns about page geometry. The column responds to terminal WIDTH only; the
// terminal HEIGHT has no effect on it.
const (
	// maxPaperWidth is the readable maximum measure (a standard max-width
	// container). The render column grows with the pane up to this cap, then the
	// side margins grow instead of the text. Tunable: lower it for a tighter
	// page, raise it for a wider one.
	maxPaperWidth = 100
)

// paperColumnWidth returns the column width to render the paper at, given the
// available pane content width.
//
//	paperWidth = min(paneW, maxPaperWidth)
//
// A pane narrower than (or equal to) the cap uses its full width — the caller
// then pads 0 and the paper fills the pane. Only a pane WIDER than the cap is
// pinned to maxPaperWidth, leaving the caller centered side margins. The terminal
// height never enters this computation.
func paperColumnWidth(paneW int) int {
	if paneW < 1 {
		paneW = 1
	}
	w := paneW
	if w > maxPaperWidth {
		w = maxPaperWidth
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
			Foreground(pdrender.GenCodeFg). // code-block fg
			Background(pdrender.GenCodeBg), // code-block bg
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
	t.Ingress = lipgloss.NewStyle().Foreground(pdrender.GenInk) // ingress ink → GenInk
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
			c = roleColor("danger") // danger role via semrole (design/tokens.json status.danger)
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
// lines through the shared registry + theme, capped to a max-width reading column
// and centered within the pane. The viewport handles scrolling and clipping,
// exactly as it does for the field-form editor.
//
//	paneW (the width arg) is the full pane content width the editor/preview gives us.
//	The column is derived from paneW ALONE — paperWidth = min(paneW, maxPaperWidth).
//	Terminal HEIGHT plays no part; widening the terminal grows the column up to the
//	cap, then the side margins grow instead.
//
// The render happens at paperWidth ≤ paneW (NOT paneW); when paperWidth < paneW the
// rendered column is centered by prefixing leftPad spaces to every line. When the
// terminal is no wider than the cap, paperWidth == paneW and leftPad == 0 — the
// full-width behaviour. Because leftPad + paperWidth ≤ paneW, no centered line can
// exceed paneW (the View() clampBlock backstop still applies regardless).
func (m model) buildPaperContent(width int) string {
	if m.paperRegistry == nil || len(m.selectedPaperBlocks) == 0 {
		return ""
	}
	paneW := width
	paperWidth := paperColumnWidth(paneW)

	// readFailed is the paper pane's twin of Pane.ReadFailed / model.docReadFailed:
	// the three resolvers below read through the store, and a refused or
	// unreachable read yields the SAME miss an absent document does — the plain
	// wikilink, the raw id, the pinned fallback. The inline degrade is CORRECT
	// and stays (an inline resolver has no business turning a sentence into an
	// error message, and it cannot block on a fetch to learn more); what the
	// pane owes the reader is the fact that the render is INCOMPLETE. Each
	// resolver sets this only when its lookup actually MISSED *and* the read
	// behind that miss failed — a reference that resolved never cries wolf.
	var readFailed bool
	ctx := pdrender.RenderCtx{
		Width:         paperWidth,
		Theme:         m.paperTheme,
		Profile:       m.paperProfile,
		RefResolver:   m.paperRefResolver(&readFailed),
		TaskResolver:  m.taskChipResolver(&readFailed),
		ValueResolver: m.paperValueResolver(&readFailed),
	}
	rendered := m.paperRegistry.RenderDoc(m.selectedPaperBlocks, ctx)

	// Center the reading column in the pane. When paperWidth == paneW (pane no
	// wider than the cap), leftPad is 0 and the content is returned unchanged at
	// full width.
	leftPad := (paneW - paperWidth) / 2
	if leftPad < 0 {
		leftPad = 0
	}
	if leftPad > 0 {
		rendered = centerPaperLines(rendered, leftPad)
	}
	// The notice sits at the PANE's left edge, above the reading column — it is
	// pane chrome, not part of the document, so it is added after centering.
	if readFailed {
		rendered = strings.Join(paperReadFailedNotice(), "\n") + "\n" + rendered
	}
	return rendered
}

// paperReadFailedNotice is the paper pane's member of the shared read-failure
// vocabulary — the same ✕ glyph, dim styling and "the server refused or is
// unreachable" second line that failedDocListInterior and renderReadFailedState
// use, so the TUI speaks about a failed read with ONE voice. It says
// "referenced documents", not "documents": the paper itself rendered, only its
// references did not resolve. Like its siblings it advertises no key — the TUI
// binds no refresh.
func paperReadFailedNotice() []string {
	return []string{
		dimStyle.Render("   ✕ Couldn't load referenced documents"),
		dimStyle.Render("   the server refused or is unreachable"),
		"",
	}
}

// centerPaperLines prefixes leftPad spaces to EVERY rendered line — a local mirror
// of tui.go's indentLines, kept here so the paper render path is self-contained and
// reads against the reading-column centering intent (indentLines exists for the
// field-form box idiom). The padding is plain leading spaces, which never disturb
// the ANSI styling of the rendered content that follows.
func centerPaperLines(s string, leftPad int) string {
	pad := strings.Repeat(" ", leftPad)
	parts := strings.Split(s, "\n")
	for i, p := range parts {
		parts[i] = pad + p
	}
	return strings.Join(parts, "\n")
}

// taskChipResolver returns a per-render memoised TaskResolver (lvw-t7): the
// FIRST task-chip lookup in a render pass loads the task list once through the
// datastore (the same single-query cost paperRefResolver pays per type) and
// keys chips by task id in BOTH the `drafts.` and published spellings. The TUI
// stays conservative: it resolves ID-PINNED wikilinks only (no title keys —
// without the paper corpus in hand a title key could shadow a paper link;
// a typed-by-title task link degrades to the plain link, which is the allowed
// fallback, never wrong). A nil datastore / fetch miss yields nil → the plain
// wikilink degrade.
//
// QueryResult, not Query: a refused or unreachable task read returns the same
// zero docs an empty task list does, and the degrade would then spell "no such
// task" over "we were not allowed to look". The degrade still happens — it is
// the right inline behaviour — but a miss BEHIND a failed read reports through
// readFailed so buildPaperContent can say the render is incomplete.
func (m model) taskChipResolver(readFailed *bool) func(id string) *pdrender.TaskChip {
	var chips map[string]*pdrender.TaskChip
	var loadFailed bool
	return func(id string) *pdrender.TaskChip {
		if m.ds == nil || id == "" {
			return nil
		}
		if chips == nil {
			chips = map[string]*pdrender.TaskChip{}
			docs, outcome := m.ds.QueryResult("task", "")
			loadFailed = outcome.Failed()
			for _, d := range docs {
				if d.ID == "" {
					continue
				}
				chip := taskChipFromDoc(d)
				pub := strings.TrimPrefix(d.ID, "drafts.")
				chips[pub] = chip
				chips["drafts."+pub] = chip
			}
		}
		chip := chips[id]
		if chip == nil && loadFailed && readFailed != nil {
			*readFailed = true
		}
		return chip
	}
}

// taskChipFromDoc maps a task apiclient.Doc into a pdrender.TaskChip. The v1
// envelope flattens content fields to the top level, so lifecycle_status /
// priority / acceptance_criteria ride in Doc.Extra as raw JSON. Garbage-
// tolerant per the wire §4 contract: non-string status drops, non-integral
// priority drops (0 is valid — the HIGHEST), and criteria count entries whose
// `met` is EXACTLY true; absent/empty lists leave CriteriaTotal 0 so the
// renderer omits the m/n segment (never "0/0").
//
// TODO(lvw-t6): align the inline {met,total} count with fable-w3's shared
// criteria helper once lvw-t6 merges.
func taskChipFromDoc(d Doc) *pdrender.TaskChip {
	chip := &pdrender.TaskChip{Title: d.Title}
	if raw, ok := d.Extra["lifecycle_status"]; ok {
		var s string
		if json.Unmarshal(raw, &s) == nil {
			chip.Status = s
		}
	}
	if raw, ok := d.Extra["priority"]; ok {
		var p float64
		if json.Unmarshal(raw, &p) == nil && p == float64(int(p)) && p >= 0 {
			chip.Priority = int(p)
			chip.HasPriority = true
		}
	}
	if raw, ok := d.Extra["acceptance_criteria"]; ok {
		var list []map[string]any
		if json.Unmarshal(raw, &list) == nil && len(list) > 0 {
			chip.CriteriaTotal = len(list)
			for _, e := range list {
				if met, ok := e["met"].(bool); ok && met {
					chip.CriteriaMet++
				}
			}
		}
	}
	return chip
}

// paperValueResolver is the inline live-value seam (lvw-t1, wire §3/§5) for the
// TUI paper pane: resolve a valueref's (target, field) from whatever the
// datastore already has loaded — CACHE-ONLY and non-blocking (wire §10: the
// TUI value is stale until the datastore refreshes; never a blocking fetch
// inside a render pass, exactly like paperRefResolver). The FIRST lookup in a
// render pass builds one id→doc map across the loaded types (memoised — never
// a scan per node); the published spelling is preferred over its `drafts.`
// twin (D3). "" = miss → pdrender shows the node's pinned fallback.
//
// QueryResult, not Query: a type the store refuses contributes zero docs to the
// map, exactly as an empty type does, and the valueref then shows its pinned
// fallback as though the live value were merely absent. The fallback still
// shows — that is the wire §3 contract — but a miss behind a failed read
// reports through readFailed so the pane can flag the incomplete render.
func (m model) paperValueResolver(readFailed *bool) func(target, field string) string {
	var docs map[string]Doc
	var loadFailed bool
	return func(target, field string) string {
		target = strings.TrimSpace(target)
		field = strings.TrimSpace(field)
		// Wire §3: a single top-level field name — no dot-paths. Malformed →
		// unresolved → fallback.
		if m.ds == nil || target == "" || field == "" || strings.Contains(field, ".") {
			return ""
		}
		if docs == nil {
			docs = map[string]Doc{}
			for i := range schemas {
				page, outcome := m.ds.QueryResult(schemas[i].Name, "")
				if outcome.Failed() {
					loadFailed = true
				}
				for _, d := range page {
					if d.ID != "" {
						if _, taken := docs[d.ID]; !taken {
							docs[d.ID] = d
						}
					}
				}
			}
		}
		pub := strings.TrimPrefix(target, "drafts.")
		d, ok := docs[pub]
		if !ok {
			d, ok = docs["drafts."+pub]
		}
		if !ok {
			if loadFailed && readFailed != nil {
				*readFailed = true
			}
			return ""
		}
		return paperValueScalar(d, field)
	}
}

// paperValueScalar renders one top-level field of a datastore doc for valueref
// display. Only scalars resolve (string / number / bool — the shared
// three-surface rule); an empty string counts as UNRESOLVED, and maps/lists
// never stringify, so a FieldCipher `_bpenc` envelope or nested object
// degrades to the fallback. `title` reads the typed Doc field (the v1 envelope
// hoists it out of Extra).
func paperValueScalar(d Doc, field string) string {
	if field == "title" {
		return strings.TrimSpace(d.Title)
	}
	raw, ok := d.Extra[field]
	if !ok {
		return ""
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case float64:
		if t == float64(int64(t)) {
			return fmt.Sprintf("%d", int64(t))
		}
		return fmt.Sprintf("%g", t)
	case bool:
		return fmt.Sprintf("%t", t)
	default:
		return ""
	}
}

// paperRefResolver builds the RefResolver seam: given a referenced doc id it
// returns that doc's title from the loaded types, falling back to the raw id
// when the referenced doc isn't found (no blocking fetch — the renderer stays
// synchronous). The raw id is a valid display and stays the degrade.
//
// QueryResult, not Query: a refused type reads as an empty type, so a
// reference the reader is simply not allowed to resolve renders exactly like a
// reference to a document that does not exist. The scan therefore remembers
// whether any type's read FAILED and reports through readFailed only when the
// id was not found anyway — a reference resolved from a readable type never
// raises the notice, even when some other type in the scan was refused.
func (m model) paperRefResolver(readFailed *bool) func(id, refType string) string {
	return func(id, _ string) string {
		if m.ds == nil || id == "" {
			return id
		}
		var loadFailed bool
		for i := range schemas {
			page, outcome := m.ds.QueryResult(schemas[i].Name, "")
			if outcome.Failed() {
				loadFailed = true
			}
			for _, d := range page {
				if d.ID == id && d.Title != "" {
					return d.Title
				}
			}
		}
		if loadFailed && readFailed != nil {
			*readFailed = true
		}
		return id
	}
}
