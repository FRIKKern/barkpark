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

	// name holds the light/dark MODE ("light"/"dark") — the legacy field (also
	// used by isZero and imagemosaic's ground pick, both keyed on mode). themeID
	// holds the theme IDENTITY (ts-w4c) — orthogonal to mode: it selects which
	// emitted skin buildTheme resolved its palette from (only "evergreen" today).
	// Both feed code.go's memo key so two themes at the same mode never collide.
	name    string
	themeID string
}

// isZero reports whether the Theme is the zero value (no mode set) — used by
// RenderDoc to fall back to the registry's theme when the caller passed an
// empty ctx.Theme. buildTheme always sets a non-empty mode, so a built Theme is
// never zero regardless of its themeID.
func (t Theme) isZero() bool { return t.name == "" }

// markStyle returns a one-off emphasis style for strong/em recursion.
func (t Theme) markStyle(kind string) lipgloss.Style {
	switch kind {
	case "bold":
		return t.Body.Bold(true)
	case "italic":
		return t.Body.Italic(true)
	case "underline":
		return t.Body.Underline(true)
	case "strike", "s", "strikethrough":
		return t.Body.Strikethrough(true)
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

// pdBtnFg is the one chrome value with no emitted twin: the contrasting fg on the
// filled primary action. Every other palette colour is RESOLVED per theme id via
// Resolve(theme) inside buildTheme (tokens_gen.go's genPalette) so a theme change
// moves pdrender's chrome with every other surface. pdrender may import only
// lipgloss+x/ansi+stdlib — it can NEVER reach internal/semrole — so its palette is
// re-emitted into its OWN package (Palette) as byte-identical siblings.
//
// DECOY GUARD: the chrome ink/dim tones are NOT the reading family. pal.ChromeInk/
// ChromeDim resolve to GenChromeInk/GenChromeDim (cliChrome zinc), NOT GenInk/
// GenDim (the warmer color.text/muted-text reading set) — threading those would
// silently retint. pal.ReadingMuted IS GenDim on purpose (its #71717a/#a1a1aa
// editor-label value is exactly the reading muted-text tone).
var pdBtnFg = lipgloss.AdaptiveColor{Light: "#ffffff", Dark: "#ffffff"} // lit-allow: contrasting fg on the filled primary action; no generated twin (au-w4-cli-chrome-tokens)

// buildTheme constructs a Theme for a theme identity + light/dark mode. themeID
// selects the emitted skin (Resolve(themeID) → the theme's Palette; unknown/empty
// → evergreen); mode ("light"/"dark") picks the per-mode ChromaStyle and is the
// only place the light/dark switch is made at build time — every colour is an
// AdaptiveColor lipgloss resolves against the terminal background at render, so a
// single builder serves both modes of a theme.
func buildTheme(themeID, mode string) Theme {
	if mode == "" {
		mode = "dark"
	}
	pal := Resolve(themeID)
	body := lipgloss.NewStyle().Foreground(pal.ChromeTextSecondary)
	dim := lipgloss.NewStyle().Foreground(pal.ChromeDim)

	t := Theme{
		name:    mode,
		themeID: themeID,
		Body:    body,
		Dim:     dim,
		Accent:  pal.ChromeAccent,
		Rule:    lipgloss.NewStyle().Foreground(pal.Rule),
		InlineCode: lipgloss.NewStyle().
			Foreground(pal.CodeFg).
			Background(pal.CodeBg),
		Link: lipgloss.NewStyle().
			Foreground(pal.ChromeAccent).
			Underline(true),
		Eyebrow: lipgloss.NewStyle().
			Foreground(pal.ChromeAccent).
			Bold(true),
		Byline:    dim,
		Pullquote: lipgloss.NewStyle().Foreground(pal.ChromeDim).Italic(true),
		Caption:   lipgloss.NewStyle().Foreground(pal.ChromeDim).Italic(true),
	}

	// ── M1 styles ───────────────────────────────────────────────────────────
	// Code chrome: a terracotta left bar (mirrors doc.css code's 3px accent
	// border). ChromaStyle picks a built-in chroma style by light/dark — the one
	// non-adaptive choice, made here at build time.
	t.CodeBar = lipgloss.NewStyle().Foreground(pal.ReadingAccent)
	if mode == "light" {
		t.ChromaStyle = "github"
	} else {
		t.ChromaStyle = "monokai"
	}

	// Action buttons: primary fills the accent bg with a contrasting fg (the
	// publishBtnStyle idiom); secondary is an accent-outline box.
	t.ActionPrimary = lipgloss.NewStyle().
		Foreground(pdBtnFg).
		Background(pal.ChromeAccent).
		Bold(true)
	t.ActionSecondary = lipgloss.NewStyle().
		Foreground(pal.ChromeAccent).
		Border(lipgloss.NormalBorder()).
		BorderForeground(pal.ChromeAccent).
		Bold(true)

	// Field label: muted bold (mirrors styles.go editorLabelStyle).
	t.FieldLabel = lipgloss.NewStyle().Foreground(pal.ReadingMuted).Bold(true)

	// Ingress: brighter ink (NOT dimmed) so it reads as a standfirst; a left
	// accent bar substitutes for the larger font size. Pullquote bar is
	// terracotta (doc.css's 3px left-border).
	t.Ingress = lipgloss.NewStyle().Foreground(pal.ChromeInk)
	t.IngressBar = lipgloss.NewStyle().Foreground(pal.ChromeAccent)
	t.PullquoteBar = lipgloss.NewStyle().Foreground(pal.ReadingAccent)

	// Headings — terminals have no font sizes, so level is encoded as
	// weight/case/rule (per the spec): L1 bold ink (rule added by the renderer
	// as an underline), L2 bold accent, L3 bold dim.
	t.Heading[0] = lipgloss.NewStyle().Bold(true).Foreground(pal.ChromeInk)
	t.Heading[1] = lipgloss.NewStyle().Bold(true).Foreground(pal.ChromeAccent)
	t.Heading[2] = lipgloss.NewStyle().Bold(true).Foreground(pal.ChromeDim)

	t.Callout = func(tone string) (bar, bodyStyle lipgloss.Style) {
		var c lipgloss.TerminalColor
		switch tone {
		case "success":
			c = pal.ToneOK
		case "warning":
			c = pal.ToneWarn
		case "danger":
			c = pal.ToneDanger
		case "neutral":
			c = pal.ToneNeutral
		default: // info + unknown
			c = pal.ToneInfo
		}
		bar = lipgloss.NewStyle().Foreground(c)
		bodyStyle = lipgloss.NewStyle().Foreground(c)
		return bar, bodyStyle
	}

	return t
}

// ThemeFor builds a Theme for a theme IDENTITY + light/dark MODE — the seam a
// resolved theme id flows through (from BP_THEME/config on the CLI, or the JS arg
// in the WASM reader). DarkTheme/LightTheme are the two mode presets on the
// default (evergreen) theme; ThemeFor generalises them to any emitted skin.
func ThemeFor(themeID, mode string) Theme { return buildTheme(themeID, mode) }

// ruleColor extracts the foreground color the Rule style carries, for renderers
// (e.g. figure's card border) that need the raw color rather than the style.
func ruleColor(t Theme) lipgloss.TerminalColor {
	if c := t.Rule.GetForeground(); c != nil {
		return c
	}
	return Resolve(t.themeID).Rule
}

// DarkTheme is the default (evergreen) preset for dark terminals.
func DarkTheme() Theme { return buildTheme(DefaultTheme, "dark") }

// LightTheme is the default (evergreen) preset for light terminals. The palette is
// the same AdaptiveColor set; lipgloss resolves each color against the light
// background.
func LightTheme() Theme { return buildTheme(DefaultTheme, "light") }
