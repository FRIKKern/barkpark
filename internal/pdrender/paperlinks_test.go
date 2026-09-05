package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Live-corpus guard for `paper-links` — the block type that rendered on the
// Elixir (compose.ex) and React (@barkpark/react) surfaces but was registered
// in NO Go renderer, so it drew the "unknown block" box on the TUI.
//
// CENSUS RE-RUN, 2026-09-02 (not copied from the filing — re-measured):
//
//	curl -s 'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=100&offset=N'
//	# anonymous read, perspective=published, paged to exhaustion
//	published papers: 1050
//	paper-links blocks: 151 in papers: 145
//
// testdata/paper_links_corpus.json holds three of those real blocks verbatim —
// one per layout arm (default / chapters / timeline) — so the golden is pinned
// to the shape production actually stores, not to a synthetic one.

// paperLinksCorpusBlocks decodes the committed corpus fixture.
func paperLinksCorpusBlocks(t *testing.T) []Block {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "paper_links_corpus.json"))
	if err != nil {
		t.Fatalf("read paper_links_corpus.json: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode paper_links_corpus.json: %v", err)
	}
	if len(blocks) != 3 {
		t.Fatalf("fixture must hold the three layout arms, got %d blocks", len(blocks))
	}
	return blocks
}

// TestPaperLinksGolden pins the rendered corpus fixture byte-for-byte.
// Regenerate with `go test ./internal/pdrender/ -run TestPaperLinksGolden -update`.
func TestPaperLinksGolden(t *testing.T) {
	got := renderFixture(t, "paper_links_corpus.json", 80)
	goldenPath := filepath.Join("testdata", "golden", "paper_links_corpus_w80.txt")
	if *update {
		if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden (run with -update to create): %v", err)
	}
	if got != string(want) {
		t.Errorf("paper-links render mismatch at width 80\n--- got ---\n%s\n--- want ---\n%s", got, string(want))
	}
}

// TestPaperLinksRendersEveryReferencedPaper is the criterion assertion: the
// golden output must carry EVERY referenced paper's title and its reader link,
// and must never show the unknown-block box. It reads the expectations out of
// the fixture itself, so adding a ref to the fixture cannot silently go
// unasserted.
func TestPaperLinksRendersEveryReferencedPaper(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "paper_links_corpus.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var doc struct {
		Blocks []struct {
			Type  string `json:"type"`
			Title string `json:"title"`
			Refs  []struct {
				Slug  string `json:"slug"`
				Title string `json:"title"`
			} `json:"refs"`
		} `json:"blocks"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("unmarshal fixture: %v", err)
	}

	out := renderFixture(t, "paper_links_corpus.json", 80)
	assertNoUnknownBlock(t, "paper_links_corpus.json", out)

	// Every ref in every layout arm must appear, title AND link. Both wrap at 80
	// columns — titles at spaces, URLs at their hyphens — so presence is checked
	// against two folded views of the render: `flat` collapses the line breaks
	// and indent to single spaces, `tight` removes whitespace entirely (which is
	// what re-joins a URL split across "…viable-" / "everywhere-strategy)"). A
	// wrapped string is still present; a missing one is missing in both views.
	flat := strings.Join(strings.Fields(out), " ")
	tight := strings.Join(strings.Fields(out), "")
	present := func(want string) bool {
		return strings.Contains(flat, strings.Join(strings.Fields(want), " ")) ||
			strings.Contains(tight, strings.Join(strings.Fields(want), ""))
	}

	refs := 0
	for _, b := range doc.Blocks {
		if b.Type != "paper-links" {
			t.Fatalf("fixture block is %q, expected paper-links", b.Type)
		}
		if !present(b.Title) {
			t.Errorf("section title %q missing from render", b.Title)
		}
		for _, r := range b.Refs {
			refs++
			if !present(r.Title) {
				t.Errorf("referenced paper title %q missing from render", r.Title)
			}
			if !present("(/papers/" + r.Slug + ")") {
				t.Errorf("referenced paper link /papers/%s missing from render", r.Slug)
			}
		}
	}
	// Non-vacuity: the fixture must actually carry refs, or every loop above
	// passes by never running.
	if refs != 17 {
		t.Fatalf("fixture carries %d refs, expected the 17 real corpus refs", refs)
	}
}

// TestPaperLinksSuppressesARestatedReason mirrors paper_link_reason/2: a reason
// that only restates the description is dropped, a distinct one is shown.
//
// Worth recording: across all 151 live blocks (census above) NOT ONE ref has a
// reason that differs from its description, so the "Why it matters:" line is
// suppressed everywhere in production today. The distinct-reason input below is
// the cross-surface parity fixture's
// (js/packages/react/tests/fixtures/pd-golden/paper-links.golden.json), which is
// exactly the authored shape the Elixir emitter is frozen against.
func TestPaperLinksSuppressesARestatedReason(t *testing.T) {
	render := func(ref map[string]any) string {
		reg := testRegistry()
		return reg.RenderDoc([]Block{{Type: "paper-links", Attrs: map[string]any{
			"type": "paper-links", "title": "Continue reading",
			"refs": []any{ref},
		}}}, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	}

	distinct := render(map[string]any{
		"slug":        "paper-authoring-excellence",
		"title":       "Paper authoring excellence",
		"description": "A practical guide to publishing clear, useful Papers.",
		"reason":      "See the principles behind this example.",
	})
	if !strings.Contains(distinct, "Why it matters: See the principles behind this example.") {
		t.Errorf("a distinct reason must render:\n%s", distinct)
	}

	// The real corpus shape: reason == description, trailing period and case
	// normalized away by normalizedCopy.
	restated := render(map[string]any{
		"slug":        "the-80-column-standard",
		"title":       "The 80-Column Standard",
		"description": "The principle behind keeping rich Papers useful in an ordinary terminal.",
		"reason":      "The principle behind keeping rich Papers useful in an ordinary terminal.",
	})
	if strings.Contains(restated, "Why it matters") {
		t.Errorf("a reason restating the description must be suppressed:\n%s", restated)
	}
	if !strings.Contains(restated, "The principle behind keeping rich Papers useful") {
		t.Errorf("the description itself must still render:\n%s", restated)
	}
}

// TestPaperLinksLiveMetadataWins covers the `_paper_links` resolution the public
// reader injects (transient, so it never appears in stored corpus blocks):
// live copy leads, unless the ref sets prefer_authored_copy.
func TestPaperLinksLiveMetadataWins(t *testing.T) {
	block := func(preferAuthored bool) Block {
		return Block{Type: "paper-links", Attrs: map[string]any{
			"type": "paper-links", "title": "Related",
			"refs": []any{map[string]any{
				"slug": "the-80-column-standard", "title": "Authored title",
				"description": "Authored copy.", "prefer_authored_copy": preferAuthored,
			}},
			"_paper_links": map[string]any{"the-80-column-standard": map[string]any{
				"title": "Live title", "description": "Live copy.",
				"event_type": "publish", "rev": "abc123", "updated_at": "2026-09-01",
			}},
		}}
	}
	reg := testRegistry()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	live := reg.RenderDoc([]Block{block(false)}, ctx)
	if !strings.Contains(live, "Live title") || strings.Contains(live, "Authored title") {
		t.Errorf("live metadata must win by default:\n%s", live)
	}
	// The metadata line is what proves _paper_links was read, not just a title swap.
	if !strings.Contains(live, "publish · rev abc123 · 2026-09-01") {
		t.Errorf("resolved metadata line missing:\n%s", live)
	}

	authored := reg.RenderDoc([]Block{block(true)}, ctx)
	if !strings.Contains(authored, "Authored title") || strings.Contains(authored, "Live title") {
		t.Errorf("prefer_authored_copy must lead with authored copy:\n%s", authored)
	}
}

// TestPaperLinksEmptyRefsRenderNothing mirrors compose.ex's `if cards == ""`
// guard: a block with no usable refs is skipped, not boxed.
func TestPaperLinksEmptyRefsRenderNothing(t *testing.T) {
	reg := testRegistry()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	for name, attrs := range map[string]map[string]any{
		"no refs key": {"type": "paper-links", "title": "Related"},
		"empty refs":  {"type": "paper-links", "title": "Related", "refs": []any{}},
		"slugless":    {"type": "paper-links", "title": "Related", "refs": []any{map[string]any{"title": "no slug"}, "  "}},
	} {
		out := reg.RenderDoc([]Block{{Type: "paper-links", Attrs: attrs}}, ctx)
		if strings.TrimSpace(out) != "" {
			t.Errorf("%s: expected nothing, got:\n%s", name, out)
		}
	}
}
