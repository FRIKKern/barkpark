package taskboard

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// paper_fence_test.go — the board's OWN fence around FetchPaper, the third
// network read path (the first two are fenced by PR 8604's envelope work).
//
// Two distinct jobs live here, and they are not the same kind of test:
//
//   - TestFetchPaperRefusesObjectShapedPoisons PINS a refusal the board today
//     BORROWS. Five of run.go's nine poison bodies decode cleanly into the
//     source payload struct and land with an ABSENT source.kind, so they die in
//     internal/apiclient's PaperSource default arm ("unknown kind"). Nothing in
//     internal/taskboard asserted that, so loosening that arm reddened nothing
//     on the board's side and silently reopened the whole class. This test is
//     GREEN on origin/main by construction — it is a lock, not a bug report.
//
//   - TestFetchPaperRefusesWellFormedEmptyBlocks is the DETECTOR for the live
//     fail-open one notch narrower: a 200 carrying a well-formed source of kind
//     "blocks" with an EMPTY array passed every apiclient check (non-empty
//     trimmed bytes, valid JSON, a KNOWN kind), returned err=nil, and
//     renderPaperBody's !blocksNonEmpty arm rendered the dim line "not found" —
//     an envelope that answered with NOTHING presented to the reader as an
//     honest miss. RED on origin/main, GREEN with the FetchPaper fence.

// objectShapedPoisons are the five of run.go's nine poison bodies that decode
// as (or into) an object and therefore reach the source-kind switch with an
// absent kind. The other four (an HTML proxy page, zero bytes, a bare array,
// plaintext) never survive json.Unmarshal into the payload struct at all.
var objectShapedPoisons = []struct{ name, body string }{
	{"json_null", `null`},
	{"ok_false_error_envelope", `{"ok":false,"error":{"code":"upstream_down","message":"nope"}}`},
	{"unknown_envelope_key", `{"widgets":[{"a":1},{"b":2}]}`},
	{"result_null", `{"result":null}`},
	{"empty_object", `{}`},
}

func TestFetchPaperRefusesObjectShapedPoisons(t *testing.T) {
	for _, tc := range objectShapedPoisons {
		t.Run(tc.name, func(t *testing.T) {
			srv := paperServer(t, tc.body)
			defer srv.Close()

			ps, err := FetchPaper(paperClient(srv.URL), "production", "drafts.the-paper")
			if err == nil {
				t.Fatalf("HTTP 200 %s accepted as a paper: state=%+v", tc.body, ps)
			}
			if ps.Err == "" {
				t.Fatalf("a refused read must carry a one-line Err on the state: %+v", ps)
			}
			if blocksNonEmpty(ps.BlocksRaw) || ps.HTMLOnly {
				t.Fatalf("a refused read must hydrate no source arm: %+v", ps)
			}
		})
	}
}

// emptyBlocksPayload is the well-formed-empty envelope: a KNOWN kind, valid
// JSON, non-zero bytes — and no content whatsoever.
const emptyBlocksPayload = `{"id":"drafts.the-paper","title":"The Charter","_rev":"rev-7","source":{"kind":"blocks","blocks":[]}}`

func TestFetchPaperRefusesWellFormedEmptyBlocks(t *testing.T) {
	srv := paperServer(t, emptyBlocksPayload)
	defer srv.Close()

	ps, err := FetchPaper(paperClient(srv.URL), "production", "drafts.the-paper")
	if err == nil {
		t.Fatalf("a kind=blocks envelope carrying an EMPTY array returned err=nil: state=%+v", ps)
	}
	if ps.Err == "" {
		t.Fatalf("a refused read must carry a one-line Err on the state: %+v", ps)
	}

	// The reader must not be told "not found" about an envelope that answered.
	resetPaperCache()
	body := renderPaperBody(ps, 60, nil)
	if len(body) != 1 {
		t.Fatalf("a refused state must render exactly one honest line, got %d: %q", len(body), body)
	}
	plain := strings.TrimSpace(ansi.Strip(body[0]))
	if plain == "not found" {
		t.Fatalf("an empty-but-well-formed envelope still renders the dim miss line %q", plain)
	}
	if !strings.HasPrefix(plain, "could not load paper —") {
		t.Fatalf("refusal line = %q, want the could-not-load state", plain)
	}
}

// The release-gate read path (PaperReleaseSource) admits the SAME empty array:
// its envelope check is `len(bytes.TrimSpace(blocks)) == 0 || !json.Valid(...)`,
// and "[]" passes both. FetchPaper's fence must cover both of its arms.
func TestFetchPaperRefusesWellFormedEmptyBlocksOnReleasePath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"sha256:`+strings.Repeat("b", 64)+`"`)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Barkpark-Release-Gate", taskReleaseGate)
		w.Header().Set("X-Barkpark-Wave-Revision", taskWaveRev)
		w.Header().Set("X-Barkpark-Paper-Candidate", taskCandidate)
		w.Header().Set("X-Barkpark-Paper-Role", "campaign")
		_, _ = fmt.Fprintf(w, `{"release_gate_id":%q,"wave_revision":%q,"candidate_id":%q,"role":"campaign","document_id":%q,"doc_id":"campaign-paper","title":"Campaign","content_digest":%q,"source":{"kind":"blocks","blocks":[]}}`,
			taskReleaseGate, taskWaveRev, taskCandidate, taskDocument, strings.Repeat("b", 64))
	}))
	defer srv.Close()
	ref := srv.URL + "/w/ws/p/proj/v1/cycles/epic/wave/release-gates/" + taskReleaseGate +
		"/papers/campaign/source?wave_revision=" + taskWaveRev + "&candidate_id=" + taskCandidate

	ps, err := FetchPaper(paperClient(srv.URL), "production", ref)
	if err == nil {
		t.Fatalf("a release-pinned kind=blocks envelope carrying an EMPTY array returned err=nil: state=%+v", ps)
	}
	if ps.Err == "" {
		t.Fatalf("a refused release read must carry a one-line Err on the state: %+v", ps)
	}
}

// The CONTROL for the fence: a one-block paper is the smallest honest body, and
// it must still hydrate. Without this, "refuse empty blocks" could be satisfied
// by refusing every blocks paper.
func TestFetchPaperAcceptsSingleBlockPaper(t *testing.T) {
	srv := paperServer(t, `{"id":"p","title":"Tiny","_rev":"r1","source":{"kind":"blocks","blocks":[{"type":"paragraph","content":[{"type":"text","value":"one"}]}]}}`)
	defer srv.Close()

	ps, err := FetchPaper(paperClient(srv.URL), "production", "p")
	if err != nil {
		t.Fatalf("a one-block paper must hydrate: %v", err)
	}
	if !blocksNonEmpty(ps.BlocksRaw) || ps.Err != "" {
		t.Fatalf("a one-block paper must carry its blocks with no Err: %+v", ps)
	}
}
