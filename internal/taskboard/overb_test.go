package taskboard

import (
	"testing"
)

// TestWideFooterVerbClickOpensStudio proves the wide board footer's o verb, when
// the split is wide enough to keep it, routes a click through clickFooterVerb →
// openTask and launches the Studio deep link for the task under the cursor
// (charter D111 / D117b). The 80-col default sheds o (boardW=49 keeps only c,x),
// so the fixture is widened to 100 cols FIRST — boardW=62 there keeps o.
//
// It can fail: the skip-o mutation in the handleWideMouse footer-verb early-out
// (compose.go:644-648) makes the o click fall through to pane handling, opening
// no URL — the captured URL stays empty and this test reds.
func TestWideFooterVerbClickOpensStudio(t *testing.T) {
	m := wideMouseModel(activeOrphans(readyTask("r1")))
	m.width, m.height = 100, 24 // widen so the board footer keeps the o verb
	m.cfg.BaseURL = "https://guerrilla"

	var captured string
	saved := openURL
	openURL = func(u string) error {
		captured = u
		return nil
	}
	t.Cleanup(func() { openURL = saved })

	click, ok := wideClickVerb(m, 'o')
	if !ok {
		t.Fatal("wide open verb span not emitted at width 100 (o should survive boardW=62)")
	}

	m, _ = step(t, m, click)

	want := StudioTaskURL(m.cfg.BaseURL, "r1")
	if want == "" {
		t.Fatal("fixture built no Studio URL — check BaseURL/docID")
	}
	if captured != want {
		t.Fatalf("wide o click opened %q, want %q", captured, want)
	}
}
