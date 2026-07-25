package taskboard

// mouse_test.go — the clickable footer verbs + mouse-mode etiquette (charter
// D96). Three proof obligations: (1) the footer verb SPANS align with the
// painted verb tokens and track the shed/truncate ladder (a clipped verb loses
// its span); (2) a verb CLICK dispatches the exact same reducer as its key —
// claim/studio straight through, close through the existing two-step guard as
// two clicks; (3) the M toggle flips mouse reporting with the right bubbletea
// commands, clears hover, and the footer reflects the mode. The etiquette
// footnote's presence/shed-first behavior is asserted alongside (1).

import (
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/semrole"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// footerCols slices a footer line by DISPLAY column [start,end). The board
// footer is ASCII plus the 1-cell "·" leader, so every rune is one column wide
// and a rune-index slice is a column slice — exactly the space the spans live in.
func footerCols(line string, start, end int) string {
	r := []rune(line)
	if start < 0 || start > len(r) {
		return ""
	}
	if end > len(r) {
		end = len(r)
	}
	return string(r[start:end])
}

// TestFooterVerbSpansAlignWithPaintedVerbs walks the shed/truncate ladder and
// proves each returned span covers EXACTLY its painted verb token, and that a
// verb the width clips loses its span (charter D96 criterion 1). It also pins the
// etiquette footnote: present at generous width, gone once the width tightens.
func TestFooterVerbSpansAlignWithPaintedVerbs(t *testing.T) {
	want := map[rune]string{'c': "c claim", 'x': "x close", 'o': "o studio"}

	cases := []struct {
		name         string
		width        int
		wantVerbs    []rune // spans expected, in order
		wantNav      string // the nav hint the ladder chose
		wantFootnote string // "full", "short" or "none"
	}{
		// Full ladder + footnote (a >=98-col inner pane).
		{"full+footnote", 100, []rune{'c', 'x', 'o'}, "jk move", "full"},
		// The footnote compresses first — the short M-toggle form rides along at
		// every canonical portrait width, verbs + long nav still paint.
		{"short-footnote", 80, []rune{'c', 'x', 'o'}, "jk move", "short"},
		// The footnote sheds entirely before any verb hint.
		{"no-footnote", 70, []rune{'c', 'x', 'o'}, "jk move", "none"},
		// Nav word "move" sheds next — every verb still clickable at the 60 floor.
		{"jk-short", 60, []rune{'c', 'x', 'o'}, "jk", "none"},
		// Sub-60 truncation: "c claim" still lands fully inside 40 cols (ends at
		// col 36) so it keeps its span, but "x close" (start 39) and "o studio" run
		// past the cut and lose theirs — the clipped verbs are not clickable.
		{"truncated", 40, []rune{'c'}, "jk", "none"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			segs, spans := buildBoardFooter(tc.width, false)
			line := footerJoin(segs)

			// The chosen nav hint.
			if !strings.HasPrefix(line, tc.wantNav+" ") && line != tc.wantNav {
				t.Errorf("nav hint: line %q does not start with %q", line, tc.wantNav)
			}
			// Footnote form: the full note contains the short one, so classify by
			// the selection-bypass wording first.
			gotFootnote := "none"
			if strings.Contains(line, "opt/shift-click selects") {
				gotFootnote = "full"
			} else if strings.Contains(line, "M mouse") {
				gotFootnote = "short"
			}
			if gotFootnote != tc.wantFootnote {
				t.Errorf("footnote form=%q, want %q (line %q)", gotFootnote, tc.wantFootnote, line)
			}

			// Every returned span covers exactly its verb token, and lands inside
			// the paintable width.
			gotVerbs := make([]rune, 0, len(spans))
			for _, s := range spans {
				gotVerbs = append(gotVerbs, s.verb)
				if got := footerCols(line, s.start, s.end); got != want[s.verb] {
					t.Errorf("span for %q covers %q, want %q", string(s.verb), got, want[s.verb])
				}
				if s.end > tc.width {
					t.Errorf("span for %q ends at %d, past width %d (a clipped verb must lose its span)", string(s.verb), s.end, tc.width)
				}
			}
			if !reflect.DeepEqual(gotVerbs, tc.wantVerbs) {
				t.Errorf("verb spans = %v, want %v", string(gotVerbs), string(tc.wantVerbs))
			}
		})
	}
}

// TestFooterEtiquetteShedsBeforeVerbs proves the shed ORDER: under width
// pressure the footnote yields before any verb hint — first compressing to the
// short M-toggle form, then shedding entirely — so the verbs always survive it
// (charter D96 criterion 4). The short form must be present across the whole
// 72–97 inner-width range: Compose insets 4, so this is what keeps the M toggle
// discoverable at the epic's entire 60–100-col portrait vision (the full
// 98-col note would need a >=102-col terminal).
func TestFooterEtiquetteShedsBeforeVerbs(t *testing.T) {
	for inner := 72; inner <= 97; inner++ {
		line := ansi.Strip(renderFooter(UIState{}, inner))
		for _, verb := range []string{"c claim", "x close", "o studio"} {
			if !strings.Contains(line, verb) {
				t.Errorf("inner %d: verb %q shed before the footnote (line %q)", inner, verb, line)
			}
		}
		if strings.Contains(line, "opt/shift-click") {
			t.Errorf("inner %d: full footnote did not compress: %q", inner, line)
		}
		if !strings.Contains(line, "M mouse") {
			t.Errorf("inner %d: short footnote missing — the M toggle is undiscoverable: %q", inner, line)
		}
	}
	// Below the short form's 72-col line the footnote sheds entirely; the verbs
	// still paint.
	line := ansi.Strip(renderFooter(UIState{}, 71))
	for _, verb := range []string{"c claim", "x close", "o studio"} {
		if !strings.Contains(line, verb) {
			t.Errorf("inner 71: verb %q shed with the footnote (line %q)", verb, line)
		}
	}
	if strings.Contains(line, "M mouse") {
		t.Errorf("inner 71: footnote did not shed below its floor: %q", line)
	}
}

// TestReadingFooterEtiquetteCompresses proves the reading footer rides the same
// footnote ladder: full note when generous, the short M-toggle form at the
// canonical portrait widths (compose inner 56/76/96), shed only when even the
// short form cannot fit.
func TestReadingFooterEtiquetteCompresses(t *testing.T) {
	full := ansi.Strip(readingFooter(UIState{}, 96))
	if !strings.Contains(full, "opt/shift-click selects") {
		t.Errorf("inner 96: reading footer missing the full etiquette: %q", full)
	}
	for _, inner := range []int{56, 76} {
		line := ansi.Strip(readingFooter(UIState{}, inner))
		if strings.Contains(line, "opt/shift-click") {
			t.Errorf("inner %d: full footnote did not compress: %q", inner, line)
		}
		if !strings.Contains(line, "M mouse") {
			t.Errorf("inner %d: short footnote missing from the reading footer: %q", inner, line)
		}
		if !strings.Contains(line, "esc back") {
			t.Errorf("inner %d: nav hint shed before the footnote: %q", inner, line)
		}
	}
	if line := ansi.Strip(readingFooter(UIState{}, 55)); strings.Contains(line, "M mouse") {
		t.Errorf("inner 55: footnote did not shed below its floor: %q", line)
	}
}

// TestFooterReflectsReleasedMode proves the released mode note replaces the
// captured-mode etiquette in the footer (charter D96: the footer reflects the
// mode). The reading footer omits verbs but still teaches the toggle.
func TestFooterReflectsReleasedMode(t *testing.T) {
	on := ansi.Strip(renderFooter(UIState{MouseReleased: false}, 100))
	off := ansi.Strip(renderFooter(UIState{MouseReleased: true}, 100))
	if !strings.Contains(on, "opt/shift-click selects") {
		t.Errorf("captured-mode footer missing the selection etiquette: %q", on)
	}
	if !strings.Contains(off, "mouse off") {
		t.Errorf("released-mode footer missing the mode note: %q", off)
	}
	if strings.Contains(off, "opt/shift-click") {
		t.Errorf("released-mode footer still claims a click bypass: %q", off)
	}
}

// clickVerb builds a left-press MouseMsg on the given board verb by resolving its
// span from the same geometry footerVerbAt uses, then clicking its midpoint.
func clickVerb(m Model, verb rune) tea.MouseMsg {
	gl := 1 // width>=56 in these fixtures
	inner := m.width - gl - 3
	_, spans := buildBoardFooter(inner, m.ui.MouseReleased)
	x := gl // fallback
	for _, s := range spans {
		if s.verb == verb {
			x = gl + (s.start+s.end)/2
		}
	}
	return tea.MouseMsg{X: x, Y: m.height - 1, Action: tea.MouseActionPress, Button: tea.MouseButtonLeft}
}

// mouseModel is an act-verb fixture sized so the footer paints full width (all
// three verb spans present) with the cursor on the loose task.
func mouseModel(b Board) Model {
	m := testModel(b)
	m.width, m.height = 80, 24
	m.ui.Cursor = 1 // the loose task (row 0 is the bucket header)
	return m
}

// TestFooterVerbClickClaimsLikeKey proves a click on the claim verb fires the
// SAME claim command as pressing c (charter D96 criterion 2).
func TestFooterVerbClickClaimsLikeKey(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := mouseModel(activeOrphans(readyTask("r1")))

	var gotDoc, gotWorker string
	m.doClaim = func(_ *apiclient.Client, docID, worker string) ActionResult {
		gotDoc, gotWorker = docID, worker
		return ActionResult{OK: true, Message: "claimed as opus-9 · epoch 1"}
	}

	m, cmd := step(t, m, clickVerb(m, 'c'))
	if cmd == nil {
		t.Fatal("clicking the claim verb fired no command")
	}
	if _, ok := cmd().(actionResultMsg); !ok {
		t.Fatal("claim click did not produce an actionResultMsg")
	}
	if gotDoc != "r1" || gotWorker != "opus-9" {
		t.Fatalf("DoClaim got (%q,%q), want (r1,opus-9)", gotDoc, gotWorker)
	}
}

// TestFooterVerbClickCloseTwoStep proves close via clicks walks the EXISTING
// pendingClose two-step: first click arms + prompts, second click on the same
// affordance fires with the observed CAS epoch; a non-verb click disarms
// (charter D96 criterion 2).
func TestFooterVerbClickCloseTwoStep(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "opus-9")
	m := mouseModel(activeOrphans(claimedTask("c1", 7)))

	var gotDoc, gotWorker string
	var gotEpoch int
	m.doClose = func(_ *apiclient.Client, docID, worker string, epoch int) ActionResult {
		gotDoc, gotWorker, gotEpoch = docID, worker, epoch
		return ActionResult{OK: true, Message: "closed · epoch 7"}
	}

	// First click on the close verb ARMS (no command, prompt shown).
	m, cmd := step(t, m, clickVerb(m, 'x'))
	if cmd != nil {
		t.Fatal("first close click fired a close (should only arm)")
	}
	if m.pendingClose != "c1" {
		t.Fatalf("pendingClose = %q after first click, want c1", m.pendingClose)
	}
	if !strings.Contains(m.ui.Strip.Message, "press x again") {
		t.Fatalf("first-click strip = %q, want the confirm prompt", m.ui.Strip.Message)
	}

	// Second click on the SAME verb fires with the observed epoch.
	m, cmd = step(t, m, clickVerb(m, 'x'))
	if cmd == nil {
		t.Fatal("second close click did not fire the close")
	}
	if _, ok := cmd().(actionResultMsg); !ok {
		t.Fatal("close click did not produce an actionResultMsg")
	}
	if gotDoc != "c1" || gotWorker != "opus-9" || gotEpoch != 7 {
		t.Fatalf("DoClose got (%q,%q,%d), want (c1,opus-9,7)", gotDoc, gotWorker, gotEpoch)
	}
	if m.pendingClose != "" {
		t.Fatal("pendingClose not cleared after firing")
	}
}

// TestFooterCloseClickDisarmedByOtherClick proves ANY other click disarms a
// pending close (charter D96): arm on x, then click the claim verb — the close
// guard clears instead of firing.
func TestFooterCloseClickDisarmedByOtherClick(t *testing.T) {
	m := mouseModel(activeOrphans(claimedTask("c1", 7)))
	m.doClose = func(_ *apiclient.Client, _, _ string, _ int) ActionResult {
		t.Fatal("close fired after the guard should have been disarmed")
		return ActionResult{}
	}
	m, _ = step(t, m, clickVerb(m, 'x')) // arm
	if m.pendingClose != "c1" {
		t.Fatalf("arm failed: pendingClose = %q", m.pendingClose)
	}
	m, _ = step(t, m, clickVerb(m, 'o')) // studio click — disarms
	if m.pendingClose != "" {
		t.Fatal("a non-close verb click did not disarm the close guard")
	}
}

// TestFooterClickOffVerbsDisarms proves a left click that misses every verb span
// (empty footer region) disarms a pending close and clears the strip.
func TestFooterClickOffVerbsDisarms(t *testing.T) {
	m := mouseModel(activeOrphans(claimedTask("c1", 7)))
	m, _ = step(t, m, clickVerb(m, 'x')) // arm
	if m.pendingClose != "c1" {
		t.Fatalf("arm failed: pendingClose = %q", m.pendingClose)
	}
	off := tea.MouseMsg{X: 0, Y: m.height - 1, Action: tea.MouseActionPress, Button: tea.MouseButtonLeft}
	m, _ = step(t, m, off)
	if m.pendingClose != "" {
		t.Fatal("a click off the verbs did not disarm the close guard")
	}
}

// TestMouseHoverTintsAndClears proves motion over a verb sets the hover state and
// leaving clears it, and that the hovered token carries a background tint the
// un-hovered footer does not (charter D96). Color is forced so the tint is
// observable in bytes; the visible TEXT is unchanged (tint, not relabel).
func TestMouseHoverTintsAndClears(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	m := mouseModel(activeOrphans(readyTask("r1")))
	gl := 1
	inner := m.width - gl - 3
	segs, spans := buildBoardFooter(inner, false)
	var cx int
	for _, s := range spans {
		if s.verb == 'c' {
			cx = gl + s.start
		}
	}
	var cText string
	for _, s := range segs {
		if s.verb == 'c' {
			cText = s.text
		}
	}

	plain := renderFooter(m.ui, inner) // hover 0

	m, cmd := step(t, m, tea.MouseMsg{X: cx, Y: m.height - 1, Action: tea.MouseActionMotion})
	if cmd == nil || m.ui.HoverFooterVerb != 0 || m.hoverPendingVerb != 'c' {
		t.Fatalf("footer hover was not debounced: visible=%q pending=%q", string(m.ui.HoverFooterVerb), string(m.hoverPendingVerb))
	}
	m, _ = step(t, m, hoverDebounceMsg{gen: m.hoverGen})
	if m.ui.HoverFooterVerb != 'c' {
		t.Fatalf("hover over claim = %q, want 'c'", string(m.ui.HoverFooterVerb))
	}
	styled := renderFooter(m.ui, inner)
	if styled == plain {
		t.Error("hovered footer carries no tint (byte-identical to the un-hovered footer)")
	}
	if ansi.Strip(styled) != ansi.Strip(plain) {
		t.Errorf("hover changed the visible TEXT (should only tint):\n hovered=%q\n plain  =%q", ansi.Strip(styled), ansi.Strip(plain))
	}

	// The tint is pinned to the D94 verb-affordance TOKEN: chrome-selection-bg
	// behind title ink — never a foreground token repurposed as a background
	// (chrome-text-secondary under chrome-ink is ~1.8:1, illegible). Building the
	// expectation from the semrole token (not from verbHoverStyle) keeps this a
	// real pin: re-pointing the style off the token reds this line.
	selBg, ok := semrole.ChromeColorFor(DefaultTheme, "chrome-selection-bg")
	if !ok {
		t.Fatal("semrole lost the chrome-selection-bg role")
	}
	want := lipgloss.NewStyle().Foreground(titleColor).Background(selBg).Render(cText)
	if !strings.Contains(styled, want) {
		t.Errorf("hovered verb is not painted title-ink-on-chrome-selection-bg (charter D94):\n want token %q\n in footer  %q", want, styled)
	}

	// Motion off the verbs clears the hover.
	m, _ = step(t, m, tea.MouseMsg{X: 0, Y: m.height - 1, Action: tea.MouseActionMotion})
	if m.ui.HoverFooterVerb != 0 {
		t.Fatalf("hover not cleared off the verbs: %q", string(m.ui.HoverFooterVerb))
	}
}

// TestMToggleReleasesAndReArmsMouse proves M flips mouse reporting with the right
// bubbletea commands, clears hover on release, and the footer reflects the mode
// (charter D96 criterion 3).
func TestMToggleReleasesAndReArmsMouse(t *testing.T) {
	m := mouseModel(activeOrphans(readyTask("r1")))
	m.ui.HoverFooterVerb = 'c' // pretend the pointer was over claim

	// First M releases: DisableMouse command, mode flipped, hover cleared.
	m, cmd := step(t, m, runes("M"))
	if !m.ui.MouseReleased {
		t.Fatal("M did not release the mouse")
	}
	if m.ui.HoverFooterVerb != 0 {
		t.Fatal("releasing the mouse did not clear the hover")
	}
	if cmd == nil || !reflect.DeepEqual(cmd(), tea.DisableMouse()) {
		t.Fatal("M did not return tea.DisableMouse")
	}

	// While released, a stray mouse event is inert (no hover, no dispatch).
	m, cmd = step(t, m, clickVerb(m, 'c'))
	if cmd != nil || m.ui.HoverFooterVerb != 0 {
		t.Fatal("a click while released must be a no-op")
	}

	// Second M re-arms: EnableMouseAllMotion command, mode restored.
	m, cmd = step(t, m, runes("M"))
	if m.ui.MouseReleased {
		t.Fatal("second M did not re-arm the mouse")
	}
	if cmd == nil || !reflect.DeepEqual(cmd(), tea.EnableMouseAllMotion()) {
		t.Fatal("second M did not return tea.EnableMouseAllMotion")
	}
}

// TestFooterVerbAtDegradesHonestly proves the hit test returns no target where
// there is no clickable footer: wide mode, a pushed reading frame, and any row
// that is not the footer line.
func TestFooterVerbAtDegradesHonestly(t *testing.T) {
	m := mouseModel(activeOrphans(readyTask("r1")))
	click := clickVerb(m, 'c')

	// A row that is not the footer never hits.
	if _, ok := m.footerVerbAt(click.X, 0); ok {
		t.Error("a non-footer row hit a verb")
	}
	// Wide mode exposes no board footer targets this wave.
	wm := m
	wm.wide = true
	if _, ok := wm.footerVerbAt(click.X, click.Y); ok {
		t.Error("wide mode exposed a footer verb target")
	}
	// A pushed reading frame's footer omits the verbs.
	rm := m
	(&rm).pushFrame(Frame{Kind: FrameTask, Ref: "r1", Title: "r1"})
	if _, ok := rm.footerVerbAt(click.X, click.Y); ok {
		t.Error("a reading frame exposed a board footer verb target")
	}
}
