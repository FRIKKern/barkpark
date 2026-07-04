package taskboard

import (
	"flag"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

var updatePaper = flag.Bool("update-paper", false, "regenerate the paper-frame golden")

// paperNow is the injected clock every paper test renders against, so ages and
// claim tints are byte-stable regardless of when the suite runs.
var paperNow = time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)

// fixtureBlocks is the golden paper's body: an L1 heading, a paragraph carrying
// a wikilink task chip (resolved live from the snapshot), and a fenced code
// block — enough to exercise pdrender wholesale.
const fixtureBlocks = `[
  {"type":"heading","level":1,"text":"Paper frame charter"},
  {"type":"paragraph","content":[
    {"type":"text","value":"Driven by "},
    {"type":"wikilink","target":"task-alpha","docId":"drafts.task-alpha","children":[]},
    {"type":"text","value":" — read it inline."}
  ]},
  {"type":"code","code":"go test ./internal/taskboard/...","language":"bash"}
]`

// paperServer answers the scoped paper-doc GET with the given result object.
func paperServer(t *testing.T, resultJSON string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"result":` + resultJSON + `}`))
	}))
}

func paperClient(url string) *apiclient.Client {
	return apiclient.New(apiclient.Config{
		BaseURL: url, Token: "t", Workspace: "ws", Project: "proj",
		Dataset: "production", Perspective: "drafts",
	})
}

func resetPaperCache() {
	paperCacheMu.Lock()
	paperCache = map[string][]string{}
	paperDecodeCount = 0
	paperCacheMu.Unlock()
}

func TestFetchPaperHydratesBlocks(t *testing.T) {
	srv := paperServer(t, `{"_id":"drafts.the-paper","title":"The Charter","_rev":"rev-7","blocks":`+fixtureBlocks+`}`)
	defer srv.Close()

	ps, err := FetchPaper(paperClient(srv.URL), "production", "drafts.the-paper")
	if err != nil {
		t.Fatalf("FetchPaper: %v", err)
	}
	if ps.Title != "The Charter" || ps.Rev != "rev-7" {
		t.Errorf("title/rev = %q/%q, want The Charter/rev-7", ps.Title, ps.Rev)
	}
	if ps.HTMLOnly {
		t.Errorf("HTMLOnly must be false when blocks are present")
	}
	if !blocksNonEmpty(ps.BlocksRaw) {
		t.Errorf("BlocksRaw must carry the block array")
	}
	if ps.Err != "" {
		t.Errorf("Err must be empty on success, got %q", ps.Err)
	}
}

// A block-less paper that carries body_html is the honest browser-handoff state.
func TestFetchPaperHTMLOnly(t *testing.T) {
	srv := paperServer(t, `{"_id":"p","title":"Legacy","_rev":"r1","blocks":[],"body_html":"<h1>hi</h1>"}`)
	defer srv.Close()

	ps, err := FetchPaper(paperClient(srv.URL), "production", "p")
	if err != nil {
		t.Fatalf("FetchPaper: %v", err)
	}
	if !ps.HTMLOnly {
		t.Errorf("HTMLOnly must be true for a body_html-only paper")
	}
	if blocksNonEmpty(ps.BlocksRaw) {
		t.Errorf("BlocksRaw must be empty for an HTML-only paper")
	}
}

// A non-2xx read is a one-line Err on a still-usable state AND a returned error.
func TestFetchPaperError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not_found"}`))
	}))
	defer srv.Close()

	ps, err := FetchPaper(paperClient(srv.URL), "production", "ghost")
	if err == nil {
		t.Fatalf("FetchPaper on 404 must return an error")
	}
	if ps.Err == "" {
		t.Errorf("Err must carry the failure for the render frame")
	}
	if ps.Slug != "ghost" {
		t.Errorf("state must retain the slug even on error, got %q", ps.Slug)
	}
}

// The four honest body states each render a single dim line and NO stops (only
// the rail supplies stops, and these states have an empty rail).
func TestRenderPaperFrameHonestStates(t *testing.T) {
	resetPaperCache()
	cases := []struct {
		name string
		ps   PaperState
		want string
	}{
		{"loading", PaperState{Slug: "p", Loading: true}, "loading"},
		{"error", PaperState{Slug: "p", Err: "boom"}, "could not load paper"},
		{"htmlonly", PaperState{Slug: "p", HTMLOnly: true}, "HTML-only paper"},
		{"empty", PaperState{Slug: "p"}, "not found"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			lines, stops := RenderPaperFrame(tc.ps, nil, nil, 0, 80, paperNow)
			joined := ansi.Strip(strings.Join(lines, "\n"))
			if !strings.Contains(joined, tc.want) {
				t.Errorf("frame missing %q:\n%s", tc.want, joined)
			}
			if len(stops) != 0 {
				t.Errorf("empty rail must yield 0 stops, got %d", len(stops))
			}
			// Never a crash, always at least the title + a body line.
			if len(lines) < 2 {
				t.Errorf("frame too short: %d lines", len(lines))
			}
		})
	}
}

// Stops index the exact rail line and carry the task's doc_id; the cursor row
// wears the ▎ selection bar and no other row does.
func TestRenderPaperFrameStopsAndSelection(t *testing.T) {
	resetPaperCache()
	driven := drivenFixture()
	lines, stops := RenderPaperFrame(PaperState{Slug: "p", Title: "P"}, driven, driven, 1, 80, paperNow)
	if len(stops) != len(driven) {
		t.Fatalf("stops = %d, want %d", len(stops), len(driven))
	}
	for i, s := range stops {
		if s.Kind != FrameTask {
			t.Errorf("stop %d kind = %v, want FrameTask", i, s.Kind)
		}
		if s.Ref != driven[i].DocID {
			t.Errorf("stop %d ref = %q, want %q", i, s.Ref, driven[i].DocID)
		}
		if s.Line < 0 || s.Line >= len(lines) {
			t.Fatalf("stop %d line %d out of range", i, s.Line)
		}
		row := ansi.Strip(lines[s.Line])
		if !strings.Contains(row, strings.TrimSpace(driven[i].Title)) {
			t.Errorf("stop %d line %q missing title %q", i, row, driven[i].Title)
		}
		selected := strings.HasPrefix(row, "▎")
		if want := i == 1; selected != want {
			t.Errorf("stop %d selected=%v, want %v (cursor=1)", i, selected, want)
		}
	}
}

// A re-render at the same (slug, rev, width) does ZERO Decode work — Doey's
// markdown-cache lesson, proven via the decode counter.
func TestPaperBodyCacheHitSkipsDecode(t *testing.T) {
	resetPaperCache()
	ps := PaperState{Slug: "cache-me", Rev: "rev-1", BlocksRaw: []byte(fixtureBlocks)}
	driven := drivenFixture()

	RenderPaperFrame(ps, driven, driven, 0, 80, paperNow)
	if paperDecodeCount != 1 {
		t.Fatalf("first render Decode count = %d, want 1", paperDecodeCount)
	}
	RenderPaperFrame(ps, driven, driven, 0, 80, paperNow)
	if paperDecodeCount != 1 {
		t.Errorf("cache hit re-ran Decode: count = %d, want still 1", paperDecodeCount)
	}
	// A width change is a new key → one more Decode.
	RenderPaperFrame(ps, driven, driven, 0, 60, paperNow)
	if paperDecodeCount != 2 {
		t.Errorf("width change Decode count = %d, want 2", paperDecodeCount)
	}
}

func TestPaperMeasureCaps(t *testing.T) {
	if got := paperMeasure(120); got != paperMaxMeasure {
		t.Errorf("measure(120) = %d, want %d (capped)", got, paperMaxMeasure)
	}
	if got := paperMeasure(80); got != paperMaxMeasure {
		t.Errorf("measure(80) = %d, want %d (80 - gutter is still over the cap)", got, paperMaxMeasure)
	}
	if got := paperMeasure(50); got != 48 {
		t.Errorf("measure(50) = %d, want 48 (50 - gutter, under the cap)", got)
	}
	if got := paperMeasure(5); got < 1 {
		t.Errorf("measure(5) = %d, want a positive floor", got)
	}
}

// drivenFixture is the golden's driven-tasks rail: an active claim + a ready
// task, both index-aligned with their doc ids for the stop assertions.
func drivenFixture() []Task {
	return []Task{
		{
			DocID: "drafts.task-alpha", Title: "Wire the driven-tasks rail",
			Lifecycle: "in_progress", Priority: "1",
			UpdatedAt: paperNow.Add(-2 * time.Hour),
			Claim:     &Claim{Worker: "opus-3", ClaimedAt: paperNow.Add(-90 * time.Second)},
			Criteria:  &Criteria{Met: 2, Total: 3},
		},
		{
			DocID: "drafts.task-beta", Title: "Golden the paper frame at 80",
			Lifecycle: "ready",
			UpdatedAt: paperNow.Add(-26 * time.Hour),
		},
	}
}

// TestRenderPaperFrameGolden80 fetches a fixture paper over httptest, renders
// the whole frame at 80 cols (heading + code + a live wikilink chip + the driven
// rail), strips ANSI, and compares to the golden.
func TestRenderPaperFrameGolden80(t *testing.T) {
	resetPaperCache()
	srv := paperServer(t, `{"_id":"drafts.the-paper","title":"Paper frame charter","_rev":"rev-7","blocks":`+fixtureBlocks+`}`)
	defer srv.Close()

	ps, err := FetchPaper(paperClient(srv.URL), "production", "drafts.the-paper")
	if err != nil {
		t.Fatalf("FetchPaper: %v", err)
	}
	driven := drivenFixture()
	lines, _ := RenderPaperFrame(ps, driven, driven, 0, 80, paperNow)
	got := ansi.Strip(strings.Join(lines, "\n")) + "\n"

	path := filepath.Join("testdata", "paper_80.txt")
	if *updatePaper {
		if werr := os.WriteFile(path, []byte(got), 0o644); werr != nil {
			t.Fatalf("write golden: %v", werr)
		}
		return
	}
	want, rerr := os.ReadFile(path)
	if rerr != nil {
		t.Fatalf("read golden (run with -update-paper): %v", rerr)
	}
	if got != string(want) {
		t.Errorf("paper frame at 80 diverged from %s\n--- got ---\n%s\n--- want ---\n%s", path, got, string(want))
	}
}

// No rendered line may exceed the pane width, across a width sweep, on the
// multi-byte fixture (chip glyphs + em dashes) — AND across every honest state
// (loading / error / HTML-only / not-found) and the empty-rail case, whose fixed
// dim strings ("No tasks reference this paper", 29 cells) must clip to a narrow
// pane exactly like the body states do.
func TestRenderPaperFrameNeverExceedsWidth(t *testing.T) {
	resetPaperCache()
	withBlocks := PaperState{Slug: "drafts.the-paper", Title: "Paper frame charter", Rev: "rev-7", BlocksRaw: []byte(fixtureBlocks)}
	states := []struct {
		name   string
		ps     PaperState
		driven []Task
	}{
		{"body+rail", withBlocks, drivenFixture()},
		{"body+emptyrail", withBlocks, nil},
		{"loading", PaperState{Slug: "drafts.the-paper", Title: "Paper frame charter", Loading: true}, nil},
		{"error", PaperState{Slug: "drafts.the-paper", Err: "boom went the fetch, badly, at length"}, nil},
		{"htmlonly", PaperState{Slug: "drafts.the-paper", HTMLOnly: true}, nil},
		{"notfound", PaperState{Slug: "drafts.the-paper"}, nil},
	}
	for _, st := range states {
		for _, width := range []int{12, 16, 20, 24, 40, 52, 60, 72, 80, 100, 120} {
			resetPaperCache()
			lines, _ := RenderPaperFrame(st.ps, st.driven, st.driven, 0, width, paperNow)
			for i, ln := range lines {
				if w := ansi.StringWidth(ln); w > width {
					t.Errorf("%s width %d: line %d is %d cols (over budget): %q", st.name, width, i, w, ansi.Strip(ln))
				}
			}
		}
	}
}
