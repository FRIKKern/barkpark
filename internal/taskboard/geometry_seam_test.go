package taskboard

// geometry_seam_test.go pins the reading-frame HEIGHT reservations and the
// reading WIDTH floor against silent -2 / off-by-N drift. Three seams the paint
// (renderDocPane / composeAt) already owns, now measured from the resolver side:
//
//   - rightPaneStopAt gives the borderless document the full pane height
//     (avail := inner, compose.go).
//   - scrollPreview clamps the wheel to len(body) - inner, matching paint.
//   - readingWidth re-floors its post-gutter width at 20 to mirror composeAt
//     (program.go / compose.go:234-237). Without the floor the scroll-clamp
//     measure under-counts the true paint at tiny widths.
//
// Each test hand-computes the CORRECT reservation independently of the function
// under test, so a mutation in the resolver diverges from the test's own math.

import "testing"

// TestReadingWidthReflooredMatchesComposeAt pins measure==paint for the narrow
// reading column across m.width 19..24 — the band where the pre-fix readingWidth
// (post-gutter width, no re-floor) lagged composeAt's docLayout by 3/3/2/1/0/0.
// composeAt floors the post-gutter width at 20 before docLayout; readingWidth now
// mirrors that, so the gap table is all zeros. Computed against docLayout — the
// ONE reading-column seam (compose.go:192) — not a hard-coded table, so a
// reading-width change re-derives both sides together.
func TestReadingWidthReflooredMatchesComposeAt(t *testing.T) {
	for w := 19; w <= 24; w++ {
		m := composeFixture()
		m.width, m.height, m.wide = w, 44, false // narrow: readingWidth skips the wide split

		// The width composeAt actually paints the reading body at: Compose floors
		// m.width at 20, spends its outer gutter, then composeAt re-floors the
		// remainder at 20 (compose.go:234-237) before docLayout.
		pw := m.width
		if pw < 20 {
			pw = 20
		}
		gl, gr := 1, 3
		if pw < 56 {
			gl, gr = 1, 2
		}
		pw = pw - gl - gr
		if pw < 20 {
			pw = 20 // composeAt's re-floor — the step readingWidth used to omit
		}
		wantW, _ := docLayout(pw)

		if got := m.readingWidth(); got != wantW {
			t.Fatalf("m.width=%d: readingWidth()=%d, composeAt paints at %d (gap %d, want 0)",
				w, got, wantW, wantW-got)
		}
	}
}

// TestRightPaneStopAtUsesFullBorderlessHeight pins avail := inner in
// rightPaneStopAt. The fixture overflows the reading window and
// free-scrolls to the bottom, so the window top is clamped to len(body) - avail —
// a value that shifts by one for every one-row change in avail. The expected stop
// for each pane row is recomputed here with the CORRECT avail (inner - 1); a -2
// mutation in the resolver windows one line off and diverges on every content row.
func TestRightPaneStopAtUsesFullBorderlessHeight(t *testing.T) {
	m := composeFixture()
	m.width, m.height, m.wide = 120, 16, true // short pane ⇒ the reading body overflows
	(&m).pushFrame(Frame{Kind: FrameTask, Ref: composeSubjectID, Title: "Wire the SSE live bridge"})
	m.stack[len(m.stack)-1].Scroll = 1 << 20 // free-scroll clamped to the bottom (avail-sensitive)

	now := m.now()
	_, innerW, inner := m.wideGeom()
	top := m.topFrame()

	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	docW, _ := docLayout(rightW)
	body, stops := m.frameContent(top, docW, now)
	if len(body) <= inner {
		t.Fatalf("fixture body (%d lines) must overflow the window (%d) so the reservation is avail-sensitive", len(body), inner)
	}
	if len(stops) == 0 {
		t.Fatal("fixture frame has no rail stops to resolve — cannot prove the mapping")
	}

	// The borderless document gets the pane's full height.
	paintAvail := inner
	expect := func(pl int) int {
		row := docBodyRow(pl)
		if row < 0 {
			return -1
		}
		wtop := readingWindowTop(len(body), stops, top.Cursor, top.Scroll, paintAvail)
		if wtop > 0 && row == 0 {
			return -1 // ↑ more-above
		}
		if len(body)-(wtop+paintAvail) > 0 && row == paintAvail-1 {
			return -1 // ↓ more-below
		}
		bodyLine := wtop + row
		for i, s := range stops {
			if s.Line == bodyLine {
				return i
			}
		}
		return -1
	}

	sawStop := false
	for pl := 0; pl < inner; pl++ {
		got := m.rightPaneStopAt(pl, innerW, inner, now)
		if want := expect(pl); got != want {
			t.Fatalf("rightPaneStopAt(pl=%d)=%d, want %d — borderless pane height drifted from paint (avail must be inner=%d)",
				pl, got, want, paintAvail)
		}
		if expect(pl) >= 0 {
			sawStop = true
		}
	}
	if !sawStop {
		t.Fatal("no pane row resolved to a stop — the fixture cannot witness the reservation")
	}
}

// TestScrollPreviewClampsToPaintedWindow pins the maxTop := len(body) - inner
// clamp in scrollPreview. A huge wheel delta must land exactly at
// the last window top the borderless paint can show. len(body) is recomputed here the same way scrollPreview does;
// a -2 mutation lets the offset settle one line past the paint (a stuck ↓ marker).
func TestScrollPreviewClampsToPaintedWindow(t *testing.T) {
	m := composeFixture()
	m.width, m.height, m.wide = 120, 16, true // depth-0 preview, short pane ⇒ overflow

	now := m.now()
	_, innerW, inner := m.wideGeom()
	subj, ok := m.taskByID(composeSubjectID)
	if !ok {
		t.Fatal("fixture is missing the subject task")
	}

	rightW := innerW - m.boardPaneCols(innerW) - paneGutter2
	if rightW < minReadingWidth {
		rightW = minReadingWidth
	}
	docW, _ := docLayout(rightW)
	body, _ := RenderTaskDetail(m.previewDetail(subj), ChildrenOf(m.tasks, subj.DocID), -1, docW, now)

	wantMax := len(body) - inner
	if wantMax < 1 {
		t.Fatalf("preview body (%d lines) must overflow the window (%d) to witness the clamp", len(body), inner)
	}

	(&m).scrollPreview(subj, 1<<20, innerW, inner, now)
	if m.previewScroll != wantMax {
		t.Fatalf("scrollPreview clamped to %d, want %d (len(body) %d − window height %d)",
			m.previewScroll, wantMax, len(body), inner)
	}
}
