package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/charmbracelet/x/ansi"
)

// A related payload mirroring GET /v1/data/related — a strong tag match, a
// weaker tag match, and a backlink-only (references-only) degrade, plus one
// title-less entry that must fall back to its doc_id.
const relatedFixtureJSON = `{
  "result": {
    "related": [
      {"doc_id":"post-a","type":"post","title":"Deep Dive on Ecto","score":1.55,
       "sources":["tags","references"],
       "shared_tags":[{"tag":"elixir","src_strength":80,"cand_strength":60},
                      {"tag":"phoenix","src_strength":55,"cand_strength":40}]},
      {"doc_id":"post-b","type":"guide","title":"","score":0.60,
       "sources":["tags"],
       "shared_tags":[{"tag":"otp","src_strength":30,"cand_strength":30}]},
      {"doc_id":"post-c","type":"note","title":"A Backlinker","score":0.40,
       "sources":["references"],"shared_tags":[]}
    ],
    "count": 3
  }
}`

func TestFormatRelatedSection(t *testing.T) {
	entries := []paperRelatedEntry{
		{DocID: "post-a", Type: "post", Title: "Deep Dive on Ecto", Score: 1.55,
			Sources: []string{"tags", "references"},
			SharedTags: []paperRelatedSharedTag{
				{Tag: "elixir", SrcStrength: 80, CandStrength: 60},
				{Tag: "phoenix", SrcStrength: 55, CandStrength: 40},
			}},
		{DocID: "post-b", Type: "guide", Title: "", Score: 0.60,
			Sources:    []string{"tags"},
			SharedTags: []paperRelatedSharedTag{{Tag: "otp", SrcStrength: 30, CandStrength: 30}}},
		{DocID: "post-c", Type: "note", Title: "A Backlinker", Score: 0.40,
			Sources: []string{"references"}},
	}
	got := formatRelatedSection(entries, 80)

	// Heading present, separated by a leading blank line.
	if !strings.HasPrefix(got, "\nRelated\n") {
		t.Fatalf("section must start with a blank line + Related heading, got:\n%q", got)
	}
	// Score is rendered to 2 decimals, title shown, type in parens.
	if !strings.Contains(got, "1.55  Deep Dive on Ecto  (post)") {
		t.Errorf("missing score/title/type line for post-a:\n%s", got)
	}
	// Shared tags with BOTH strengths (src·cand) — the WHY of the match.
	if !strings.Contains(got, "tags: elixir (80·60), phoenix (55·40)") {
		t.Errorf("missing shared-tags-with-strengths detail:\n%s", got)
	}
	// Title-less entry falls back to its doc_id (weighted docs usually lack a
	// title column value).
	if !strings.Contains(got, "0.60  post-b  (guide)") {
		t.Errorf("title-less entry must fall back to doc_id:\n%s", got)
	}
	// References-only entry carries the backlink marker; tag entries do NOT.
	if !strings.Contains(got, "0.40  A Backlinker  (note)  · backlink") {
		t.Errorf("references-only entry must be marked backlink:\n%s", got)
	}
	if strings.Contains(got, "Deep Dive on Ecto  (post)  · backlink") {
		t.Errorf("a tag-sourced entry must NOT be marked backlink:\n%s", got)
	}
	// No trailing newline — outf adds the single one.
	if strings.HasSuffix(got, "\n") {
		t.Errorf("section must not carry a trailing newline (outf adds it):\n%q", got)
	}
}

func TestFormatRelatedSectionEmpty(t *testing.T) {
	if got := formatRelatedSection(nil, 80); got != "" {
		t.Errorf("empty entries must yield empty section, got %q", got)
	}
}

func TestFormatRelatedSectionCapsAtTopN(t *testing.T) {
	entries := make([]paperRelatedEntry, paperRelatedTopN+3)
	for i := range entries {
		entries[i] = paperRelatedEntry{DocID: "d", Type: "post", Score: 1.0, Sources: []string{"tags"}}
	}
	got := formatRelatedSection(entries, 80)
	// One line per entry (no shared tags here) + heading + leading blank line.
	if n := strings.Count(got, "\n"); n != paperRelatedTopN+1 {
		t.Errorf("expected %d entry lines capped at TopN, got %d newlines:\n%s",
			paperRelatedTopN, n, got)
	}
}

func TestFormatRelatedSectionWrapsLongTitlesAndTags(t *testing.T) {
	entries := []paperRelatedEntry{{
		DocID:   "paper-long",
		Type:    "paper",
		Title:   "Authoring Excellence — Wave 7: finish the backlog, make every trgm predicate index-reachable without hiding the decision",
		Score:   2.15,
		Sources: []string{"tags"},
		SharedTags: []paperRelatedSharedTag{
			{Tag: "authoring-excellence-with-a-deliberately-long-name", SrcStrength: 100, CandStrength: 95},
			{Tag: "wave-paper", SrcStrength: 70, CandStrength: 80},
		},
	}}
	got := formatRelatedSection(entries, 80)
	for i, line := range strings.Split(got, "\n") {
		if width := ansi.StringWidth(line); width > 80 {
			t.Fatalf("line %d width = %d, want <= 80:\n%s", i, width, got)
		}
	}
	if !strings.Contains(got, "\n        predicate index-reachable") {
		t.Fatalf("long title continuation did not align under title content:\n%s", got)
	}
	if !strings.Contains(got, "\n              paper (70·80)") {
		t.Fatalf("long tag continuation did not align under tag content:\n%s", got)
	}
}

func relatedTestClient(serverURL string) *apiclient.Client {
	return apiclient.New(apiclient.Config{
		BaseURL:   serverURL,
		Token:     "test-token",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	})
}

func TestPaperRenderRelatedHappyPath(t *testing.T) {
	var gotPath, gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(relatedFixtureJSON))
	}))
	defer srv.Close()

	section := paperRenderRelated(relatedTestClient(srv.URL), "production", "post-source", paperRelatedTopN, 80)

	// Threaded through the workspace/project-scoped related route with the bearer.
	if want := "/w/acme/p/site/v1/data/related/production/post-source"; gotPath != want {
		t.Errorf("request path = %q, want %q", gotPath, want)
	}
	if gotAuth != "Bearer test-token" {
		t.Errorf("bearer not sent, got %q", gotAuth)
	}
	if !strings.Contains(section, "Related") ||
		!strings.Contains(section, "Deep Dive on Ecto") ||
		!strings.Contains(section, "elixir (80·60)") ||
		!strings.Contains(section, "· backlink") {
		t.Errorf("rendered section missing expected content:\n%s", section)
	}
}

func TestPaperRenderRelatedFailsOpen(t *testing.T) {
	// Non-2xx (the anon 404 existence-hiding, or any server error) → "".
	err500 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer err500.Close()
	if got := paperRenderRelated(relatedTestClient(err500.URL), "production", "id", 5, 80); got != "" {
		t.Errorf("non-2xx must fail open to empty section, got %q", got)
	}

	// Garbage body → decode failure → "".
	garbage := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("not json"))
	}))
	defer garbage.Close()
	if got := paperRenderRelated(relatedTestClient(garbage.URL), "production", "id", 5, 80); got != "" {
		t.Errorf("undecodable body must fail open, got %q", got)
	}

	// Empty related list → "" (no section, not an empty heading).
	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"result":{"related":[],"count":0}}`))
	}))
	defer empty.Close()
	if got := paperRenderRelated(relatedTestClient(empty.URL), "production", "id", 5, 80); got != "" {
		t.Errorf("empty related list must yield no section, got %q", got)
	}

	// Guard rails: nil client / empty id never touch the network.
	if got := paperRenderRelated(nil, "production", "id", 5, 80); got != "" {
		t.Errorf("nil client must fail open, got %q", got)
	}
	if got := paperRenderRelated(relatedTestClient(err500.URL), "production", "  ", 5, 80); got != "" {
		t.Errorf("blank id must fail open, got %q", got)
	}
}

// The manifest verbs doc.related and tag.browse carry their rows under "related"
// / "tags"; renderTable must tabulate them (a row per entry), not cram the whole
// array into ONE key/value cell.
func TestRenderTableRelatedAndTagsEnvelopes(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		wantRow string
	}{
		{"related", `{"related":[{"doc_id":"a","type":"post","score":1.5},{"doc_id":"b","type":"note","score":0.6}],"count":2}`, "doc_id"},
		{"tags", `{"tags":[{"tag":"elixir","count":12},{"tag":"phoenix","count":7}],"count":2}`, "tag"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var buf bytes.Buffer
			w := newWriter(&buf, &buf)
			renderTable(w, []byte(c.payload))
			out := buf.String()
			// A real table has a header row naming the columns, and one line per
			// entry — never the crammed single-cell shape renderKV produces.
			if !strings.Contains(out, c.wantRow) {
				t.Errorf("%s envelope did not tabulate (missing %q column):\n%s", c.name, c.wantRow, out)
			}
			if lines := strings.Count(strings.TrimRight(out, "\n"), "\n"); lines < 2 {
				t.Errorf("%s envelope rendered %d+1 lines, expected a header + 2 rows:\n%s", c.name, lines, out)
			}
		})
	}
}

// REGRESSION: a single document (doc.get, also table output) whose content
// carries a top-level "tags" array (flattened by Envelope.render) must render as
// key/value — the new "tags" envelope key must NOT hijack it into tabulating the
// tag array. The "_id" guard in envelopeRows is what protects this.
func TestRenderTableSingleDocWithTagsRendersKV(t *testing.T) {
	doc := `{"_id":"post-1","_type":"post","title":"Hello","tags":["a","b","c"],"status":"published"}`
	var buf bytes.Buffer
	w := newWriter(&buf, &buf)
	renderTable(w, []byte(doc))
	out := buf.String()

	// KV shape: each field on its own "key  value" line.
	for _, field := range []string{"_id", "_type", "title", "status", "tags"} {
		if !strings.Contains(out, field) {
			t.Errorf("KV render missing field %q:\n%s", field, out)
		}
	}
	// If the tags array had hijacked the render, the doc's own fields (_id,
	// title, status) would be absent — assert they are present alongside tags.
	if !strings.Contains(out, "post-1") || !strings.Contains(out, "Hello") {
		t.Errorf("document fields lost — tags array wrongly tabulated:\n%s", out)
	}
}
