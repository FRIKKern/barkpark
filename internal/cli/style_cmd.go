package cli

import (
	"io"
	"strings"

	"github.com/FRIKKern/barkpark/internal/semrole"
	"github.com/FRIKKern/barkpark/internal/taskboard"

	"github.com/charmbracelet/lipgloss"
)

// runStyle is the `bp style` built-in: a one-shot, static render of Barkpark's
// CLI/TUI design tokens — the semantic status palette, the lifecycle glyphs, the
// priority severity ramp, and the spinner frames. It is the terminal peer of the
// SPA/Studio/web style guides and the W1.4 golden scaffolds
// (internal/taskboard/styleguide_golden_test.go, internal/pdrender/…): a human
// can run it to SEE what a status role, a lifecycle glyph or a priority tone
// looks like on THIS terminal.
//
// It is a PURE local built-in: no network, no manifest. Every colour and glyph
// is read live from internal/semrole (RoleColor/LifecycleColor) off the
// generated design-token artifact (tokens_gen.go) and taskboard.GenLifecycle /
// GenBrailleFrames — nothing is hand-copied, so re-emitting design/tokens.json
// moves the output (and the golden). This is what makes AC4 (canonical glyph set,
// no lookalikes) true BY CONSTRUCTION rather than by review.
//
// args is everything after the `style` noun (rest[1:] in Execute) — `bp style`
// takes no sub-noun; a stray argument is a clean usage error.
func runStyle(out *writer, g globals, args []string) int {
	if g.help {
		usageStyle(out, true)
		return exitOK
	}
	if len(args) > 0 {
		return usageErrf(out, func() { usageStyle(out, false) },
			"bp style takes no arguments (got %q)", args[0])
	}

	// Colour off (NO_COLOR, --no-color, or a pipe) ⇒ the ASCII fallback mode:
	// ASCIIGlyph glyphs (no tofu on a dumb terminal) and no SGR. Colour on ⇒ the
	// unicode glyphs painted through lipgloss's auto-detected profile. The two
	// modes are exactly the two committed golden fixtures.
	mode := styleColor
	if !out.color {
		mode = styleNoColor
	}
	io.WriteString(out.stdout, renderStyleSheet(mode))
	io.WriteString(out.stdout, renderThemeSlate(mode))
	return exitOK
}

// styleMode selects the glyph set + whether colour is emitted for the style
// sheet. It is the single knob that distinguishes the two golden fixtures.
type styleMode int

const (
	// styleColor renders unicode glyphs painted with each token's adaptive tone
	// through the active lipgloss colour profile (truecolor on a capable tty).
	styleColor styleMode = iota
	// styleNoColor renders the ASCIIGlyph fallback with no SGR — the tofu-free,
	// colour-free surface proven by the nocolor golden (AC3).
	styleNoColor
)

// priorityRamp maps a task priority (0=highest … 4=lowest) to a semantic role.
// P0/P1 are urgent → danger; P2 → warn; P3/P4 carry no urgency → "dim", a chrome
// tone (there is no emitted design token for it yet — tracked by the
// au-w4-cli-chrome-tokens follow-up), rendered with lipgloss Faint (SGR only, no
// hex, so the literal-check ratchet stays satisfied by construction).
var priorityRamp = []struct {
	label string
	role  string // "danger" | "warn" | "dim"
}{
	{"P0", "danger"},
	{"P1", "danger"},
	{"P2", "warn"},
	{"P3", "dim"},
	{"P4", "dim"},
}

// renderStyleSheet is the deterministic, side-effect-free render that the golden
// gate freezes. Given a mode it returns the full style sheet as a string; the
// actual SGR bytes for coloured glyphs depend on the ambient lipgloss colour
// profile (the golden test pins it: TrueColor+dark for styleColor, Ascii for
// styleNoColor), so this function itself hardcodes no profile.
func renderStyleSheet(mode styleMode) string {
	ascii := mode == styleNoColor
	var b strings.Builder

	b.WriteString("Barkpark - CLI/TUI style tokens\n")
	b.WriteString("rendered from internal/semrole + generated design tokens (tokens_gen.go)\n\n")

	// 1. Status palette — the four semantic roles, painted with semrole.RoleColor
	//    (the SPA's --ok/--info/--warn/--danger). In ASCII mode there is no colour
	//    to show, so the swatch is a plain marker and only the name carries meaning.
	b.WriteString("Status roles\n")
	for _, role := range semrole.Roles() {
		swatch := "##"
		if !ascii {
			swatch = "██" // ██ full-block colour chip (unicode mode only)
			if color, ok := semrole.RoleColor(role); ok {
				swatch = lipgloss.NewStyle().Foreground(color).Render(swatch)
			}
		}
		b.WriteString("  " + swatch + "  " + role + "\n")
	}
	b.WriteString("\n")

	// 2. Lifecycle glyphs — taskboard.GenLifecycle in canonical GenLifecycleOrder,
	//    each glyph painted with its semrole.LifecycleColor hue. ASCII mode uses
	//    the token's ASCIIGlyph (AC3: no tofu). Glyphs come straight from the same
	//    generated table board_theme_parity pins ⇒ AC4 by construction.
	b.WriteString("Lifecycle glyphs\n")
	for _, state := range taskboard.GenLifecycleOrder {
		tok := taskboard.GenLifecycle[state]
		glyph := tok.Glyph
		if ascii {
			glyph = tok.ASCIIGlyph
		} else if color, ok := semrole.LifecycleColor(state); ok {
			glyph = lipgloss.NewStyle().Foreground(color).Render(glyph)
		}
		role := tok.Role
		if role == "" {
			role = "-"
		}
		b.WriteString("  " + glyph + "  " + padRight(state, 12) + " " + role + "\n")
	}
	b.WriteString("\n")

	// 3. Priority severity — P0/P1 danger, P2 warn, P3/P4 dim (chrome Faint).
	b.WriteString("Priority severity\n")
	for _, pr := range priorityRamp {
		label := pr.label
		if !ascii {
			if pr.role == "dim" {
				label = lipgloss.NewStyle().Faint(true).Render(label)
			} else if color, ok := semrole.RoleColor(pr.role); ok {
				label = lipgloss.NewStyle().Foreground(color).Render(label)
			}
		}
		b.WriteString("  " + label + "  " + pr.role + "\n")
	}
	b.WriteString("\n")

	// 4. Spinner — the braille progress frames (taskboard.GenBrailleFrames). Braille
	//    is inherently unicode; ASCII mode has no generated braille twin, so it
	//    falls back to the in_progress lifecycle ASCIIGlyph (the token set's own
	//    reduced surface) rather than inventing an ASCII spinner (AC3/AC4).
	b.WriteString("Spinner\n")
	if ascii {
		b.WriteString("  still:  " + taskboard.GenLifecycle["in_progress"].ASCIIGlyph +
			"   (animated braille frames need a unicode terminal)\n")
	} else {
		b.WriteString("  frames: " + strings.Join(taskboard.GenBrailleFrames[:], " ") + "\n")
		b.WriteString("  still:  " + taskboard.GenBrailleStill + "\n")
	}

	return b.String()
}

// themeChromeRoles are the CLI/TUI chrome slots the theme slate previews per
// theme — the accent + the wizard/TUI selection pair (the last blue holdouts
// D19 retinted to derive natively from primary). Kept a fixed vocabulary (not
// the whole chrome map) so the slate reads as a focused "what moves when the
// theme identity changes" strip rather than a token dump.
var themeChromeRoles = []string{"chrome-accent", "chrome-selection-fg", "chrome-selection-bg"}

// renderThemeSlate is the THEME dimension of `bp style`: for every registered
// theme (semrole.Themes()) it renders one slate — the four status roles, the
// lifecycle glyphs, and the chrome accent/selection strip — each painted through
// the THEME-parameterized accessors (RoleColorFor / LifecycleColorFor /
// ChromeColorFor). It loops semrole.Themes() at render time, so when ts-w5c
// lands ember + fjord the slate grows 1 block → 3 with ZERO code edits here
// (the "adding theme N+1 touches exactly one new file" invariant, made visible
// on the terminal). With only evergreen registered it renders one block whose
// tones are byte-identical to the default-theme rows above — the showroom's
// terminal peer.
//
// Like renderStyleSheet it hardcodes no colour profile: the SGR bytes for a
// coloured swatch depend on the ambient lipgloss profile (the golden pins it).
func renderThemeSlate(mode styleMode) string {
	ascii := mode == styleNoColor
	var b strings.Builder

	b.WriteString("\nThemes — per-theme slate (theme identity × the status / lifecycle / chrome roles)\n")
	b.WriteString("rendered from semrole.Themes() via the theme-keyed *For accessors — grows when a theme lands\n")

	for _, theme := range semrole.Themes() {
		b.WriteString("\n" + theme + "\n")

		// Status roles — RoleColorFor(theme, role).
		b.WriteString("  status:   ")
		for i, role := range semrole.Roles() {
			if i > 0 {
				b.WriteString("  ")
			}
			swatch := "##"
			if !ascii {
				swatch = "██"
				if color, ok := semrole.RoleColorFor(theme, role); ok {
					swatch = lipgloss.NewStyle().Foreground(color).Render(swatch)
				}
			}
			b.WriteString(swatch + " " + role)
		}
		b.WriteString("\n")

		// Lifecycle glyphs — LifecycleColorFor(theme, state), canonical order.
		b.WriteString("  glyphs:   ")
		for i, state := range taskboard.GenLifecycleOrder {
			if i > 0 {
				b.WriteString("  ")
			}
			tok := taskboard.GenLifecycle[state]
			glyph := tok.Glyph
			if ascii {
				glyph = tok.ASCIIGlyph
			} else if color, ok := semrole.LifecycleColorFor(theme, state); ok {
				glyph = lipgloss.NewStyle().Foreground(color).Render(glyph)
			}
			b.WriteString(glyph + " " + state)
		}
		b.WriteString("\n")

		// Chrome accent / selection — ChromeColorFor(theme, role).
		b.WriteString("  chrome:   ")
		for i, role := range themeChromeRoles {
			if i > 0 {
				b.WriteString("  ")
			}
			swatch := "##"
			if !ascii {
				swatch = "██"
				if color, ok := semrole.ChromeColorFor(theme, role); ok {
					swatch = lipgloss.NewStyle().Foreground(color).Render(swatch)
				}
			}
			b.WriteString(swatch + " " + role)
		}
		b.WriteString("\n")
	}

	return b.String()
}

// padRight left-justifies s to width n with spaces (n measured in runes, which is
// exact here: the lifecycle state keys are ASCII). Kept local so the render owns
// no fmt width verbs that could mis-count a coloured glyph's escape bytes.
func padRight(s string, n int) string {
	if len(s) >= n {
		return s
	}
	return s + strings.Repeat(" ", n-len(s))
}

// usageStyle prints the `bp style` help. toStdout routes to stdout for an explicit
// -h (exit 0) vs stderr for a usage error (exit 2), matching usageMake.
func usageStyle(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp style")
	p("  render Barkpark's CLI/TUI design tokens — status roles, lifecycle glyphs,")
	p("  priority severity and spinner frames — sourced live from the design tokens.")
	p("")
	p("  Honours NO_COLOR / --no-color / a pipe: falls back to ASCII glyphs, no colour.")
}
