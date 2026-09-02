package chat

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// help.go — the `?` key-reference overlay (charter D66). The chat surface has no
// persistent help BAR (its footer already carries a live, contextual hint line),
// so `?` is the ONE place the FULL key vocabulary is discoverable: the picker
// grammar, the conversation grammar (contextual Esc, the pending-card answer
// keys, scroll family), the below-composer workflow panel's sub-grammar, and the
// universal quit. Re-implemented from cmd/barkpark/help.go (that overlay lives in
// package main and cannot be imported) with chat's OWN curated sections.
//
// `?` opens from the picker always, and from the conversation ONLY when the
// composer is empty (a `?` typed into a draft is text, not a command — keys.go
// intercepts before the KeyRunes catch-all). While open, key dispatch routes to
// handleHelpKey alone (model.go's handleKey guard) so the overlay owns esc/q/?
// (close) and j/k + g/G (scroll); closing touches nothing else, so the exact
// prior screen/focus/scroll/panel state is restored. The overlay REPLACES the
// frame for its paint (View branch), the same body-replace cmd/barkpark uses.

// helpChrome is the fixed overlay chrome the windowed body must budget around,
// counted against the FULL frame height View hands renderHelpOverlay (chat's
// overlay replaces the whole frame — unlike cmd/barkpark, whose -8 is spent
// against a paneHeight that already excludes the surrounding toolbar/helpbar):
// header + divider + blank above (3), the overflow indicator's worst case (1),
// blank + close-hint below (2), modal border (2) + vertical padding (2) = 10.
// One row under budgets the frame and bubbletea clips the modal's top border
// off-screen (the renderer drops overflow lines from the TOP) — the fits-frame
// test guards this. helpMaxScroll and renderHelpOverlay derive their row window
// from the same constant in lockstep, so the scroll handler's clamp and the
// render window can never disagree (the over-clamp bug the never-overclamp test
// guards).
const helpChrome = 10

// helpSection is one titled group of key rows in the overlay. Curated ON PURPOSE:
// each row documents INTENT ("esc  interrupt (mid-turn) · detach to herd (idle)"),
// not just the binding, so the overlay is the canonical map — keep it in sync
// when the grammar changes (keys_test.go spot-pins the load-bearing rows).
type helpSection struct {
	title string
	rows  [][2]string
}

// helpSections is chat's curated key reference — the FULL vocabulary the
// one-line footer can only ever advertise a slice of (charter D66). There is NO
// 'theme' key row: theme is a launch flag, not a binding, so it rides the single
// non-key reference line at the end (D66 ruling / charter D17).
var helpSections = []helpSection{
	{"Sessions (picker)", [][2]string{
		{"j / k · ↓ / ↑", "move down / up the herd"},
		{"g / home · G / end", "first / last session"},
		{"pgdn / pgup", "page down / up one window"},
		{"enter", "attach the row · new session (top row)"},
		{"n", "new session"},
		{"a", "archive the row (dismiss — it keeps running)"},
		{"s", "open the archived shelf"},
		{"r", "refresh the roster"},
		{"?", "toggle this help"},
		{"q", "quit"},
	}},
	{"Archived shelf (s)", [][2]string{
		{"enter / u", "restore the row to the herd (unarchive)"},
		{"j / k · ↓ / ↑", "move down / up the shelf"},
		{"g / G · pgdn / pgup", "ends · page"},
		{"esc / s", "back to the herd"},
		{"r", "re-read the shelf"},
		{"", "`bp chat unarchive <id>` does the same from a script"},
	}},
	{"Conversation", [][2]string{
		{"enter", "send the composer"},
		{"esc", "interrupt (mid-turn) · detach to herd (idle)"},
		{"ctrl+a / ctrl+r", "allow / deny the focused pending card"},
		{"tab", "cycle to the next pending card"},
		{"ctrl+f", "expand/collapse the settled turn folds"},
		{"ctrl+b", "back to the sessions herd"},
		{"ctrl+p", "flip Plan ⇄ Autopilot mode"},
		{"ctrl+u", "clear the composer"},
		{"backspace", "delete the last character"},
		{"↑ / ↓ · pgup / pgdn", "scroll · half page"},
		{"home / end", "top · bottom (re-follow the stream)"},
		{"mouse wheel", "scroll the transcript"},
		{"?", "toggle this help (empty composer)"},
	}},
	{"Workflow panel", [][2]string{
		{"↓", "focus the below-composer strip (following)"},
		{"enter", "expand phases · drill into the agent"},
		{"↑ / ↓", "select a phase / agent"},
		{"esc / ←", "collapse one level · back to composer"},
		{"", "typing always wins — a key composes first"},
	}},
	{"Anywhere", [][2]string{
		{"ctrl+c", "quit (persists the draft first)"},
	}},
}

// helpLines pre-renders the overlay rows once per open: an uppercase section
// heading, then each row as a fixed-width bold key + a dim intent string. A blank
// line separates sections. The window (renderHelpOverlay) slices this slice.
func helpLines() []string {
	keyStyle := lipgloss.NewStyle().Bold(true)
	var lines []string
	for i, sec := range helpSections {
		if i > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, titleStyle.Render(strings.ToUpper(sec.title)))
		for _, row := range sec.rows {
			key := fmt.Sprintf("%-20s", row[0])
			lines = append(lines, "  "+keyStyle.Render(key)+dimStyle.Render(row[1]))
		}
	}
	// One non-key reference line (charter D66): theme is a launch flag, never a
	// binding — stated, never rendered as a key row.
	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  bp chat --theme <name> — set the palette at launch"))
	return lines
}

// helpMaxScroll is the largest helpScroll that still moves the window. The render
// path clamps its top row to len-maxRows (a full trailing page), so the handler
// must stop at the same bound — otherwise down/j and G run helpScroll past it and
// the next maxRows-1 `k` presses look dead (the never-overclamp guard). height is
// the frame height renderHelpOverlay receives (View passes m.height), so the two
// derive maxRows identically.
func helpMaxScroll(height int) int {
	maxRows := max(height-helpChrome, 4)
	return max(len(helpLines())-maxRows, 0)
}

// handleHelpKey routes key input while the overlay is open (model.go's handleKey
// guard sends EVERY key here first). esc/q/? close; j/k + arrows scroll clamped
// to [0, helpMaxScroll]; g/G jump to the ends. Every other key is swallowed — the
// overlay owns the keyboard until it closes, and closing mutates nothing but the
// overlay's own two fields, so the prior view is restored untouched.
func (m Model) handleHelpKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q", "?":
		m.helpOpen = false
		m.helpScroll = 0
		return m, nil
	case "down", "j":
		if m.helpScroll < helpMaxScroll(m.height) {
			m.helpScroll++
		}
		return m, nil
	case "up", "k":
		if m.helpScroll > 0 {
			m.helpScroll--
		}
		return m, nil
	case "g", "home":
		m.helpScroll = 0
		return m, nil
	case "G", "end":
		m.helpScroll = helpMaxScroll(m.height)
		return m, nil
	}
	return m, nil
}

// renderHelpOverlay draws the key reference centred over the whole frame. The
// body is windowed to the terminal height with an honest "… N more" overflow
// indicator, and the close-hint line is ALWAYS the last row (never clipped by the
// window). The last page renders full — the top clamps to len-maxRows rather than
// shrinking one row at a time to a lone trailing line. Reuses render.go's shared
// styles (titleStyle/dimStyle/youStyle) so the overlay harmonizes with the rest
// of the chat surface.
func (m Model) renderHelpOverlay(width, height int) string {
	all := helpLines()
	maxRows := max(height-helpChrome, 4)

	lines := []string{
		youStyle.Render(" Keys"),
		dimStyle.Render(strings.Repeat("─", 40)),
		"",
	}

	start := min(m.helpScroll, helpMaxScroll(height))
	end := min(start+maxRows, len(all))
	lines = append(lines, all[start:end]...)
	if end < len(all) {
		lines = append(lines, dimStyle.Render(fmt.Sprintf("  … %d more (j/k)", len(all)-end)))
	}

	lines = append(lines, "")
	lines = append(lines, dimStyle.Render("  j/k scroll · g/G ends · ? or esc close"))

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	modal := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		Padding(1, 2).
		Render(body)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, modal)
}
