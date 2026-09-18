package pdrender

// stat_verdict_test.go — the third render engine learns the verdict vocabulary.
//
// data_viz.ex stat_html/1 and js/packages/react/src/blocks/dataviz.ts both stamp
// .bp-stat__v--loss / --peace on a stat's DIGITS. pdrender read no `verdict` key
// at all, so the terminal printed a judgement in plain body tone. These tests are
// the two arms of that fix:
//
//	RED arm    — TestStatVerdictInkGolden pins the actual escaped bytes of a
//	             loss / peace value. Delete the verdictInk() call in statCell (or
//	             the Theme.Verdict wiring) and the SGR in those rows collapses to
//	             the plain body ink, so the golden diverges.
//	QUIET arm  — TestStatVerdictOffVocabularyIsByteIdentical proves an absent,
//	             empty, or off-vocabulary verdict renders BYTE-FOR-BYTE as a stat
//	             with no `verdict` key at all, across all three colour profiles
//	             and both stat/stats. Nothing authored before the vocabulary moves.

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// pinTrueColorDark makes AdaptiveColor resolution deterministic for a byte
// golden: 24-bit profile + a dark background, both restored on cleanup.
func pinTrueColorDark(t *testing.T) {
	t.Helper()
	savedProfile, savedDark := lipgloss.ColorProfile(), lipgloss.HasDarkBackground()
	lipgloss.SetColorProfile(lipglossProfileFor(TrueColor))
	lipgloss.SetHasDarkBackground(true)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(savedProfile)
		lipgloss.SetHasDarkBackground(savedDark)
	})
}

// escSeq makes the ANSI escapes readable (and diffable) inside a text golden.
func escSeq(s string) string { return strings.ReplaceAll(s, "\x1b", `\e`) }

// TestStatVerdictInkGolden is the RED arm: the escaped bytes of the value row for
// every verdict case, in BOTH stat modes. The loss and peace rows carry a
// different SGR from the plain rows — that difference IS the fix, and removing
// the branch erases it.
func TestStatVerdictInkGolden(t *testing.T) {
	pinTrueColorDark(t)
	ctx := RenderCtx{Width: 32, Theme: DarkTheme(), Profile: TrueColor}

	var b strings.Builder
	b.WriteString("pdrender stat verdict ink (TrueColor, dark bg, width 32)\n")
	for _, mode := range []struct {
		name  string
		attrs map[string]any
	}{
		{"big-number", map[string]any{"value": "73%", "label": "Margin"}},
		{"bullet-bar", map[string]any{"value": "73", "max": 100.0, "label": "Margin"}},
	} {
		b.WriteString("\n" + mode.name + "\n")
		for _, verdict := range []string{"<absent>", "", "loss", "peace", "LOSS", "danger"} {
			m := map[string]any{}
			for k, v := range mode.attrs {
				m[k] = v
			}
			if verdict != "<absent>" {
				m["verdict"] = verdict
			}
			row := statCell(m, ctx)[0]
			b.WriteString(fmt.Sprintf("%-10s %s\n", verdict, escSeq(row)))
		}
	}

	path := filepath.Join("testdata", "stat_verdict_ink.txt")
	got := b.String()
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden (run with -update): %v", err)
	}
	if got != string(want) {
		t.Errorf("stat verdict ink diverged from %s\n--- got ---\n%s\n--- want ---\n%s", path, got, want)
	}
}

// TestStatVerdictTonesAreDistinguishable is the golden's companion assertion: a
// golden alone cannot say WHAT changed, only that bytes moved. This names the
// property — loss, peace and the plain body tone are three DIFFERENT inks, while
// the visible text is identical in all three (only the ink moves, never the
// digits) — so a future edit that merely reshuffles bytes cannot pass for it.
func TestStatVerdictTonesAreDistinguishable(t *testing.T) {
	pinTrueColorDark(t)
	ctx := RenderCtx{Width: 32, Theme: DarkTheme(), Profile: TrueColor}

	row := func(verdict string) string {
		m := map[string]any{"value": "73%", "label": "Margin"}
		if verdict != "" {
			m["verdict"] = verdict
		}
		return statCell(m, ctx)[0]
	}
	plain, loss, peace := row(""), row("loss"), row("peace")

	if loss == plain {
		t.Errorf("loss renders in the plain body tone: %q", escSeq(loss))
	}
	if peace == plain {
		t.Errorf("peace renders in the plain body tone: %q", escSeq(peace))
	}
	if loss == peace {
		t.Errorf("loss and peace are indistinguishable: %q", escSeq(loss))
	}
	for name, got := range map[string]string{"loss": loss, "peace": peace} {
		if ansi.Strip(got) != ansi.Strip(plain) {
			t.Errorf("%s moved the visible text: %q, want %q", name, ansi.Strip(got), ansi.Strip(plain))
		}
	}

	// The ink comes from the Theme, not from a literal in stat.go: the same words
	// on a different skin must paint different bytes.
	other := RenderCtx{Width: 32, Theme: ThemeFor("charple", "dark"), Profile: TrueColor}
	otherLoss := statCell(map[string]any{"value": "73%", "label": "Margin", "verdict": "loss"}, other)[0]
	if otherLoss == loss {
		t.Errorf("verdict ink did not follow the theme: charple loss == evergreen loss (%q)", escSeq(loss))
	}
}

// TestStatVerdictNilThemeHookIsSafe: a Theme built by a caller that predates the
// Verdict field (nil hook) must render, not panic, and must keep the page voice.
func TestStatVerdictNilThemeHookIsSafe(t *testing.T) {
	th := DarkTheme()
	th.Verdict = nil
	ctx := RenderCtx{Width: 32, Theme: th, Profile: NoColor}
	withVerdict := statCell(map[string]any{"value": "73%", "verdict": "loss"}, ctx)
	without := statCell(map[string]any{"value": "73%"}, ctx)
	if !reflect.DeepEqual(withVerdict, without) {
		t.Errorf("nil Verdict hook changed bytes: %q != %q", withVerdict, without)
	}
}

// TestStatVerdictOffVocabularyIsByteIdentical is the QUIET arm: absent, empty,
// blank and off-vocabulary verdicts are byte-identical to no key at all, in every
// colour profile and in both the singular stat and a stats-grid cell.
func TestStatVerdictOffVocabularyIsByteIdentical(t *testing.T) {
	saved := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(saved) })

	for _, profile := range []Profile{NoColor, ANSI256, TrueColor} {
		lipgloss.SetColorProfile(lipglossProfileFor(profile))
		ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: profile}
		registry := DefaultRegistry(ctx.Theme)

		for _, typ := range []string{"stat", "stats"} {
			build := func(extra map[string]any) Block {
				cell := map[string]any{"value": "73", "denom": "118", "label": "Margin", "spark": []any{1, 4, 8}}
				for k, v := range extra {
					cell[k] = v
				}
				if typ == "stats" {
					return Block{Type: typ, Attrs: map[string]any{"items": []any{cell, map[string]any{"value": "2"}}}}
				}
				return Block{Type: typ, Attrs: cell}
			}
			base := registry.Render(build(nil), ctx)

			for _, quiet := range []any{"", "  ", "Loss", "PEACE", "won", "danger", "success", 7, nil, true} {
				got := registry.Render(build(map[string]any{"verdict": quiet}), ctx)
				if !reflect.DeepEqual(got, base) {
					t.Errorf("%s/%s verdict %#v changed bytes: %q != %q",
						typ, profileName(profile), quiet, got, base)
				}
			}

			// Control: the IN-vocabulary words must NOT be quiet under a colour
			// profile — otherwise the loop above would pass on a renderer that
			// ignores `verdict` entirely.
			if profile != NoColor {
				for _, loud := range []string{"loss", "peace"} {
					if got := registry.Render(build(map[string]any{"verdict": loud}), ctx); reflect.DeepEqual(got, base) {
						t.Errorf("%s/%s verdict %q was silently ignored", typ, profileName(profile), loud)
					}
				}
			}
		}
	}
}
