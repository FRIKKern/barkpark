package pdrender

import (
	"strings"
	"testing"
)

// THE UNPLACED ROADMAP (task-e8e80abb16460f44). A live-query roadmap row carries
// title/status/priority and NO schedule field, so roadmapLeftWidth would clamp
// every lane to the same full-width bar: a confident, uniform, fabricated
// timeline. The Elixir twin (components.ex roadmap_html/1, #19533) renders an
// explicit cannot-place state instead; this is the Go terminal surface's half.

func liveQueryRoadmap(rows ...map[string]any) Block {
	snap := make([]any, len(rows))
	for i, r := range rows {
		snap[i] = r
	}
	return Block{Type: "roadmap", Attrs: map[string]any{
		"type": "roadmap", "query": map[string]any{"type": "task"}, "snapshot": snap,
	}}
}

// trackOf returns the bordered track of each lane line (the text between the
// two │ rails), skipping lines that carry no track.
func trackOf(out string) []string {
	var tracks []string
	for _, ln := range strings.Split(out, "\n") {
		i := strings.Index(ln, "│")
		j := strings.LastIndex(ln, "│")
		if i >= 0 && j > i {
			tracks = append(tracks, ln[i+len("│"):j])
		}
	}
	return tracks
}

func TestRoadmapAllUnplacedDegradesToNoticeAndList(t *testing.T) {
	reg := testRegistry()
	b := liveQueryRoadmap(
		map[string]any{"title": "Wire the harness", "status": "ready", "priority": "1"},
		map[string]any{"title": "Render the board", "status": "in_progress", "priority": "0"},
		map[string]any{"title": "Ship the legend", "status": "done"},
	)
	out := renderBlock(reg, b, 80)

	// No two identical lane bars. MEASURED pre-fix on this surface: Go's clamp
	// gives a geometry-less row left 0 / width 0 -> a 1-cell bar, so every lane
	// painted the SAME `░····…` track (the Elixir twin's clamp gave 0/100, a
	// full-width bar). Either way N rows collapse to one indistinguishable bar.
	seen := map[string]int{}
	for _, tr := range trackOf(out) {
		if strings.ContainsAny(tr, "░▓") {
			seen[tr]++
			if seen[tr] >= 2 {
				t.Fatalf("live-query roadmap painted identical lane bars %q:\n%s", tr, out)
			}
		}
	}
	// In fact no lane track at all: the list below the notice carries the items.
	if n := len(trackOf(out)); n != 0 {
		t.Fatalf("all-unplaced roadmap drew %d lane tracks, want 0:\n%s", n, out)
	}
	if !strings.Contains(out, roadmapUnplacedCopy) {
		t.Fatalf("missing the cannot-place notice %q:\n%s", roadmapUnplacedCopy, out)
	}
	// The items are listed, not dropped.
	for _, title := range []string{"Wire the harness", "Render the board", "Ship the legend"} {
		if !strings.Contains(out, title) {
			t.Errorf("item %q dropped from the unplaced degrade:\n%s", title, out)
		}
	}
}

func TestRoadmapPartialGeometryMarksOnlyTheUnplacedLane(t *testing.T) {
	reg := testRegistry()
	b := liveQueryRoadmap(
		map[string]any{"title": "Placed", "status": "ready", "left": 10.0, "width": 30.0},
		map[string]any{"title": "Unplaced", "status": "ready"},
	)
	out := renderBlock(reg, b, 80)
	lines := strings.Split(out, "\n")
	var placed, unplaced string
	for _, ln := range lines {
		switch {
		case strings.HasPrefix(ln, "Placed"):
			placed = ln
		case strings.HasPrefix(ln, "Unplaced"):
			unplaced = ln
		}
	}
	if !strings.Contains(placed, "░") {
		t.Errorf("the author-pct lane lost its bar: %q", placed)
	}
	if strings.Contains(unplaced, "░") || !strings.Contains(unplaced, roadmapLaneUnplacedCopy) {
		t.Errorf("the geometry-less lane should carry %q and no bar: %q", roadmapLaneUnplacedCopy, unplaced)
	}
	if strings.Contains(out, roadmapUnplacedCopy) {
		t.Errorf("a roadmap with one placed lane must not show the all-unplaced notice:\n%s", out)
	}
}

func TestRoadmapAuthorPctAndDateRailsStillPlace(t *testing.T) {
	reg := testRegistry()
	pct := liveQueryRoadmap(
		map[string]any{"title": "A", "status": "done", "left": 0.0, "width": 40.0},
		map[string]any{"title": "B", "status": "ready", "left": 40.0, "width": 35.0},
	)
	if out := renderBlock(reg, pct, 80); strings.Contains(out, roadmapLaneUnplacedCopy) || len(trackOf(out)) != 2 {
		t.Errorf("author-pct control changed:\n%s", out)
	}
	dated := Block{Type: "roadmap", Attrs: map[string]any{
		"type": "roadmap", "start": "2026-01-01", "end": "2026-12-31",
		"snapshot": []any{map[string]any{"title": "Q2", "status": "ready", "start": "2026-04-01", "end": "2026-06-30"}},
	}}
	if out := renderBlock(reg, dated, 80); strings.Contains(out, roadmapLaneUnplacedCopy) || !strings.Contains(out, "░") {
		t.Errorf("date-rail control changed:\n%s", out)
	}
	// A numeric-looking STRING is not author geometry (Elixir's is_number/1).
	str := liveQueryRoadmap(map[string]any{"title": "S", "status": "ready", "left": "40"})
	if out := renderBlock(reg, str, 80); !strings.Contains(out, roadmapUnplacedCopy) {
		t.Errorf("a string left must not count as geometry:\n%s", out)
	}
}
