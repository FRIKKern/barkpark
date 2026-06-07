package pdrender

import "github.com/charmbracelet/lipgloss"

// Theme is the injected palette + pre-built lipgloss styles. pdrender does NOT
// import styles.go (that would couple it to package main); instead the caller
// builds a Theme and injects it. DarkTheme/LightTheme are pdrender-owned
// defaults that MIRROR styles.go's zinc-grey + blue-accent palette without
// importing it — keeping the extraction seam clean.
type Theme struct {
	// Headings by level (index 0 = level 1, … index 2 = level 3).
	Heading [3]lipgloss.Style

	Body       lipgloss.Style // default body text
	Dim        lipgloss.Style // muted — captions, byline, link suffixes
	Accent     lipgloss.TerminalColor
	Rule       lipgloss.Style // section / divider hairlines
	InlineCode lipgloss.Style // inline code chip (subtle bg)
	Link       lipgloss.Style // link text (underline + accent)
	Eyebrow    lipgloss.Style
	Byline     lipgloss.Style
	Pullquote  lipgloss.Style
	Caption    lipgloss.Style

	// Callout maps a tone string (info/success/warning/danger/neutral) to a
	// left-bar style and a body style.
	Callout func(tone string) (bar, body lipgloss.Style)

	// ── M1 additions ────────────────────────────────────────────────────────
	// CodeBar styles the left accent bar of a `code` block; ChromaStyle is the
	// chroma style-registry name picked by light/dark (the one piece of the
	// palette chroma doesn't resolve adaptively).
	CodeBar     lipgloss.Style
	ChromaStyle string

	// Action button styles: primary = filled accent bg + contrasting fg (the
	// publishBtnStyle idiom); secondary = accent-outline box.
	ActionPrimary   lipgloss.Style
	ActionSecondary lipgloss.Style

	// FieldLabel is the bold label line atop every field-* leaf box.
	FieldLabel lipgloss.Style

	// Ingress / Pullquote left-accent bars (the standfirst / quote cue a
	// terminal substitutes for font size).
	Ingress      lipgloss.Style
	IngressBar   lipgloss.Style
	PullquoteBar lipgloss.Style

	// name distinguishes the two built-in presets (also used by isZero).
	name string
}

// isZero reports whether the Theme is the zero value (no name set) — used by
// RenderDoc to fall back to the registry's theme when the caller passed an
// empty ctx.Theme.
func (t Theme) isZero() bool { return t.name == "" }

// markStyle returns a one-off emphasis style for strong/em recursion.
func (t Theme) markStyle(kind string) lipgloss.Style {
	switch kind {
	case "bold":
		return t.Body.Bold(true)
	case "italic":
		return t.Body.Italic(true)
	default:
		return t.Body
	}
}

// inlineCodeWith merges the emphasis flags accumulated from marks onto the
// inline-code chip so e.g. **`code`** is both bold and chipped.
func (t Theme) inlineCodeWith(emphasis lipgloss.Style) lipgloss.Style {
	s := t.InlineCode
	if emphasis.GetBold() {
		s = s.Bold(true)
	}
	if emphasis.GetItalic() {
		s = s.Italic(true)
	}
	if emphasis.GetUnderline() {
		s = s.Underline(true)
	}
	if emphasis.GetStrikethrough() {
		s = s.Strikethrough(true)
	}
	return s
}

// Palette colors mirror styles.go (AdaptiveColor zinc-grey + blue accent) but
// are declared here so pdrender owns its defaults.
var (
	pdAccent = lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#60a5fa"} // styles.go highlight
	pdInk    = lipgloss.AdaptiveColor{Light: "#18181b", Dark: "#e4e4e7"}
	pdBody   = lipgloss.AdaptiveColor{Light: "#3f3f46", Dark: "#a1a1aa"}
	pdDim    = lipgloss.AdaptiveColor{Light: "#a1a1aa", Dark: "#52525b"} // styles.go dimText
	pdRule   = lipgloss.AdaptiveColor{Light: "#e4e4e7", Dark: "#27272a"} // styles.go dividerStyle
	pdCodeBg = lipgloss.AdaptiveColor{Light: "#f4f4f5", Dark: "#27272a"}
	pdCodeFg = lipgloss.AdaptiveColor{Light: "#be123c", Dark: "#fda4af"}
	pdLabel  = lipgloss.AdaptiveColor{Light: "#71717a", Dark: "#a1a1aa"} // styles.go editorLabelStyle
	pdTerra  = lipgloss.AdaptiveColor{Light: "#a23925", Dark: "#d98a6a"} // doc.css terracotta (pullquote bar)
	pdBtnFg  = lipgloss.AdaptiveColor{Light: "#ffffff", Dark: "#ffffff"} // contrasting fg on the filled primary action
	toneInfo = lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#60a5fa"}
	toneOK   = lipgloss.AdaptiveColor{Light: "#047857", Dark: "#34d399"} // styles.go greenDot-ish
	toneWarn = lipgloss.AdaptiveColor{Light: "#92400e", Dark: "#fbbf24"} // styles.go amberDot-ish
	toneDang = lipgloss.AdaptiveColor{Light: "#b91c1c", Dark: "#f87171"}
	toneNeut = lipgloss.AdaptiveColor{Light: "#374151", Dark: "#9ca3af"}
)

// buildTheme constructs a Theme from the shared adaptive palette. Both presets
// share the palette (AdaptiveColor resolves against the detected terminal
// background automatically) and differ only by name — the light/dark split is
// handled per-color by lipgloss, so a single builder serves both.
func buildTheme(name string) Theme {
	body := lipgloss.NewStyle().Foreground(pdBody)
	dim := lipgloss.NewStyle().Foreground(pdDim)

	t := Theme{
		name:   name,
		Body:   body,
		Dim:    dim,
		Accent: pdAccent,
		Rule:   lipgloss.NewStyle().Foreground(pdRule),
		InlineCode: lipgloss.NewStyle().
			Foreground(pdCodeFg).
			Background(pdCodeBg),
		Link: lipgloss.NewStyle().
			Foreground(pdAccent).
			Underline(true),
		Eyebrow: lipgloss.NewStyle().
			Foreground(pdAccent).
			Bold(true),
		Byline:    dim,
		Pullquote: lipgloss.NewStyle().Foreground(pdDim).Italic(true),
		Caption:   lipgloss.NewStyle().Foreground(pdDim).Italic(true),
	}

	// ── M1 styles ───────────────────────────────────────────────────────────
	// Code chrome: a terracotta left bar (mirrors doc.css code's 3px accent
	// border). ChromaStyle picks a built-in chroma style by light/dark — the one
	// non-adaptive choice, made here at build time.
	t.CodeBar = lipgloss.NewStyle().Foreground(pdTerra)
	if name == "light" {
		t.ChromaStyle = "github"
	} else {
		t.ChromaStyle = "monokai"
	}

	// Action buttons: primary fills the accent bg with a contrasting fg (the
	// publishBtnStyle idiom); secondary is an accent-outline box.
	t.ActionPrimary = lipgloss.NewStyle().
		Foreground(pdBtnFg).
		Background(pdAccent).
		Bold(true)
	t.ActionSecondary = lipgloss.NewStyle().
		Foreground(pdAccent).
		Border(lipgloss.NormalBorder()).
		BorderForeground(pdAccent).
		Bold(true)

	// Field label: muted bold (mirrors styles.go editorLabelStyle).
	t.FieldLabel = lipgloss.NewStyle().Foreground(pdLabel).Bold(true)

	// Ingress: brighter ink (NOT dimmed) so it reads as a standfirst; a left
	// accent bar substitutes for the larger font size. Pullquote bar is
	// terracotta (doc.css's 3px left-border).
	t.Ingress = lipgloss.NewStyle().Foreground(pdInk)
	t.IngressBar = lipgloss.NewStyle().Foreground(pdAccent)
	t.PullquoteBar = lipgloss.NewStyle().Foreground(pdTerra)

	// Headings — terminals have no font sizes, so level is encoded as
	// weight/case/rule (per the spec): L1 bold ink (rule added by the renderer
	// as an underline), L2 bold accent, L3 bold dim.
	t.Heading[0] = lipgloss.NewStyle().Bold(true).Foreground(pdInk)
	t.Heading[1] = lipgloss.NewStyle().Bold(true).Foreground(pdAccent)
	t.Heading[2] = lipgloss.NewStyle().Bold(true).Foreground(pdDim)

	t.Callout = func(tone string) (bar, bodyStyle lipgloss.Style) {
		var c lipgloss.TerminalColor
		switch tone {
		case "success":
			c = toneOK
		case "warning":
			c = toneWarn
		case "danger":
			c = toneDang
		case "neutral":
			c = toneNeut
		default: // info + unknown
			c = toneInfo
		}
		bar = lipgloss.NewStyle().Foreground(c)
		bodyStyle = lipgloss.NewStyle().Foreground(c)
		return bar, bodyStyle
	}

	return t
}

// ruleColor extracts the foreground color the Rule style carries, for renderers
// (e.g. figure's card border) that need the raw color rather than the style.
func ruleColor(t Theme) lipgloss.TerminalColor {
	if c := t.Rule.GetForeground(); c != nil {
		return c
	}
	return pdRule
}

// DarkTheme is the default preset for dark terminals.
func DarkTheme() Theme { return buildTheme("dark") }

// LightTheme is the default preset for light terminals. The palette is the same
// AdaptiveColor set; lipgloss resolves each color against the light background.
func LightTheme() Theme { return buildTheme("light") }
