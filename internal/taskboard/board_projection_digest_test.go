package taskboard

import (
	"encoding/json"
	"testing"
	"time"
)

// THE CONSUMER HALF OF task-9289217dc43ad78f.
//
// `?view=board` deletes `content`, and this package reads `content` on the ROW
// path for every row in the list: decodeAcceptanceCriteria feeds criteriaLadder
// (one rung per criterion, off each item's own Met/Missed) and contentMap feeds
// ScoreCompleteness. A bare subtraction therefore collapsed every ladder and
// silently LOWERED every completeness badge — not blanked it, which is worse,
// because a lower score looks like a real one.
//
// The server now sends `content_digest` in content's place. These tests are the
// consumer's side of that contract, and each one carries its own control: the
// SAME row without the digest, which is what the projection used to send.
//
// The Elixir half — an assertion that the producer still emits every field
// decoded here — lives in api/test/barkpark_web/contract/tasks_board_view_test.exs.

// fullRow is a worked row as the DEFAULT view sends it: two criteria, the first
// sealed, the second carrying an honest miss, plus the prose the board never
// renders but does score off.
const fullRow = `{
  "doc_id": "task-full", "title": "a worked row", "parent_id": "phase-1",
  "priority": "P1", "dependency_count": 0,
  "criteria_progress": {"met": 1, "total": 2},
  "content": {
    "description": "why this row exists, at length.",
    "design_doc": "/papers/some-design",
    "dependencies": ["task-blocker"],
    "acceptance_criteria": [
      {"criterion": "the first", "met": true, "evidence": "PR #1"},
      {"criterion": "the second", "met": false,
       "attempts": [{"note": "STILL A MISS", "worker": "w"}]}
    ]
  }
}`

// boardRow is the SAME row as `?view=board` sends it: no content, one digest.
const boardRow = `{
  "doc_id": "task-full", "title": "a worked row", "parent_id": "phase-1",
  "priority": "P1", "dependency_count": 0,
  "criteria_progress": {"met": 1, "total": 2},
  "content_digest": {
    "criteria_marks": "ma",
    "has_description": true,
    "has_dependencies": true,
    "has_paper": true
  }
}`

// boardRowNoDigest is what the projection sent BEFORE this change — the control.
const boardRowNoDigest = `{
  "doc_id": "task-full", "title": "a worked row", "parent_id": "phase-1",
  "priority": "P1", "dependency_count": 0,
  "criteria_progress": {"met": 1, "total": 2}
}`

func decodeRow(t *testing.T, body string) Task {
	t.Helper()
	var w taskWire
	if err := json.Unmarshal([]byte(body), &w); err != nil {
		t.Fatalf("decoding the row failed: %v", err)
	}
	return w.toTask()
}

func TestTheBoardProjectionRendersTheSameLadderAsTheFullView(t *testing.T) {
	full := decodeRow(t, fullRow)
	board := decodeRow(t, boardRow)

	wantPlain, _ := criteriaLadder(full, time.Now(), 0)
	if wantPlain == "" {
		t.Fatal("the FULL row drew no ladder — the fixture, not the projection, is broken")
	}
	gotPlain, _ := criteriaLadder(board, time.Now(), 0)
	if gotPlain != wantPlain {
		t.Errorf("board-projection ladder = %q, want %q (the same row under ?view=board must draw the same rungs)", gotPlain, wantPlain)
	}
	if len(board.CriteriaItems) != len(full.CriteriaItems) {
		t.Errorf("board-projection rungs = %d, want %d", len(board.CriteriaItems), len(full.CriteriaItems))
	}
	if !board.CriteriaItems[0].Met {
		t.Error(`mark "m" did not decode as a met rung`)
	}
	if !board.CriteriaItems[1].Missed() {
		t.Error(`mark "a" did not decode as an honest miss`)
	}
}

// THE CONTROL: without the digest the ladder is gone. If this ever passes with
// a rendered ladder, the test above proves nothing.
func TestWithoutTheDigestTheBoardProjectionHasNoLadder(t *testing.T) {
	bare := decodeRow(t, boardRowNoDigest)
	if p, _ := criteriaLadder(bare, time.Now(), 0); p != "" {
		t.Errorf("a content-less, digest-less row drew the ladder %q — this control can no longer see the defect it guards", p)
	}
	if len(bare.CriteriaItems) != 0 {
		t.Errorf("a content-less, digest-less row decoded %d criteria items, want 0", len(bare.CriteriaItems))
	}
}

func TestTheBoardProjectionScoresTheSameCompletenessAsTheFullView(t *testing.T) {
	full := decodeRow(t, fullRow)
	board := decodeRow(t, boardRow)
	bare := decodeRow(t, boardRowNoDigest)

	if full.Completeness.Score != board.Completeness.Score {
		t.Errorf("board-projection completeness = %d/%d (gaps %v), want %d/%d (gaps %v) — the same row must score the same under ?view=board",
			board.Completeness.Score, board.Completeness.Total, board.Completeness.Gaps,
			full.Completeness.Score, full.Completeness.Total, full.Completeness.Gaps)
	}

	// THE CONTROL, and the defect this row was filed for: without the digest
	// the badge does not blank, it drops to a LOWER score that reads as real.
	if bare.Completeness.Score >= full.Completeness.Score {
		t.Fatalf("a content-less, digest-less row scored %d, not below the full view's %d — this control can no longer see the defect it guards",
			bare.Completeness.Score, full.Completeness.Score)
	}
	for _, want := range []string{"description", "criteria", "deps", "paper"} {
		if !hasGap(bare.Completeness.Gaps, want) {
			t.Errorf("the digest-less control was expected to LOSE the %q rubric point; gaps = %v", want, bare.Completeness.Gaps)
		}
	}
}

func hasGap(gaps []string, name string) bool {
	for _, g := range gaps {
		if g == name {
			return true
		}
	}
	return false
}

func TestAnUnknownMarkReadsAsAnUntouchedRung(t *testing.T) {
	// A newer server's character must never read as a seal or a miss.
	items := criteriaItemsFromMarks("mzo")
	if len(items) != 3 {
		t.Fatalf("marks %q decoded %d rungs, want 3", "mzo", len(items))
	}
	if !items[0].Met {
		t.Error(`"m" must be met`)
	}
	if items[1].Met || items[1].Missed() {
		t.Errorf(`unknown mark "z" decoded as met=%v missed=%v, want an untouched rung`, items[1].Met, items[1].Missed())
	}
	if items[2].Met || items[2].Missed() {
		t.Error(`"o" must be an untouched rung`)
	}
}

func TestAMalformedDigestDegradesAndNeverFailsTheRow(t *testing.T) {
	for name, body := range map[string]string{
		"a scalar digest": `{"doc_id":"t","title":"x","content_digest":7}`,
		"a list digest":   `{"doc_id":"t","title":"x","content_digest":[1,2]}`,
		"a null digest":   `{"doc_id":"t","title":"x","content_digest":null}`,
		"marks not a string": `{"doc_id":"t","title":"x",
			"content_digest":{"criteria_marks":42,"has_description":true}}`,
	} {
		var w taskWire
		if err := json.Unmarshal([]byte(body), &w); err != nil {
			t.Fatalf("%s: the row itself failed to decode (%v) — one odd digest must never fail the whole list decode", name, err)
		}
		task := w.toTask()
		if task.Title != "x" {
			t.Errorf("%s: the row lost its title", name)
		}
		if len(task.CriteriaItems) != 0 {
			t.Errorf("%s: a malformed digest invented %d rungs", name, len(task.CriteriaItems))
		}
	}
}

// The digest is ADDITIVE: where `content` is present it decides alone, so the
// default view decodes exactly as it did before this change.
func TestTheFullViewIgnoresADigestThatDisagreesWithTheContent(t *testing.T) {
	const both = `{
	  "doc_id": "task-full", "title": "a worked row", "parent_id": "phase-1",
	  "priority": "P1",
	  "content": {"description": "prose", "acceptance_criteria": [
	    {"criterion": "the first", "met": true, "evidence": "PR #1"}]},
	  "content_digest": {"criteria_marks": "ooooo", "has_description": false}
	}`
	task := decodeRow(t, both)
	if len(task.CriteriaItems) != 1 {
		t.Fatalf("the full view decoded %d rungs, want the 1 in content (the digest must not override it)", len(task.CriteriaItems))
	}
	if !task.CriteriaItems[0].Met || task.CriteriaItems[0].Criterion != "the first" {
		t.Error("the full view's rung came from the digest, not from content")
	}
	if hasGap(task.Completeness.Gaps, "description") {
		t.Error("a digest saying has_description:false removed a point content had earned — the digest must only ever add")
	}
}
