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
