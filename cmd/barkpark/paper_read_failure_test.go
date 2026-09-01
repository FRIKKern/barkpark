package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// The doc-list panes are covered in doclist_read_failure_test.go and the
// single-document surfaces in singledoc_read_failure_test.go. This file covers
// the LAST pane kind that reads through Query: the PAPER pane, whose three
// inline resolvers (taskChipResolver, paperValueResolver, resolvePaperRef →
// paperRefResolver) each threw the read outcome away.
//
// The paper pane's failure mode is quieter than an empty list but the same lie:
// a refused or unreachable read produces the SAME miss a genuinely absent
// document does — the plain wikilink, the pinned fallback, the raw id — so the
// paper reads as fully rendered when a whole class of its references never
// loaded. The degrade itself is CORRECT and must stay (an inline resolver has
// no business turning a sentence into an error message); what was missing is a
// pane-level notice saying the render is incomplete.
//
// Every test below therefore asserts BOTH halves: the failure prints the
// notice, the honest miss does not, and the inline degrade text survives
// unchanged in both.

// paperFixture is one paper block tree exercising exactly ONE of the three
// resolver call sites, plus the literal that its miss must still render.
type paperFixture struct {
	name    string // the call site under test
	blocks  string // portable-doc JSON
	degrade string // the text a MISS must still show (the documented degrade)
}

var paperFixtures = []paperFixture{
	{
		// paper.go taskChipResolver — m.ds.Query("task", "")
		name:    "taskChipResolver/wikilink",
		blocks:  `{"version":1,"blocks":[{"type":"paragraph","content":[{"type":"text","value":"Tracked by "},{"type":"wikilink","target":"task-alpha","docId":"task-alpha"}]}]}`,
		degrade: "task-alpha",
	},
	{
		// paper.go paperValueResolver — m.ds.Query(schemas[i].Name, "")
		name:    "paperValueResolver/valueref",
		blocks:  `{"version":1,"blocks":[{"type":"paragraph","content":[{"type":"text","value":"Owner: "},{"type":"valueref","target":"person-1","field":"title","fallback":"pinned-owner"}]}]}`,
		degrade: "pinned-owner",
	},
	{
		// paper.go resolvePaperRef — m.ds.Query(schemas[i].Name, "")
		name:    "resolvePaperRef/field-reference",
		blocks:  `{"version":1,"blocks":[{"type":"field-reference","label":"Author","value":"person-1","refType":"person"}]}`,
		degrade: "person-1",
	},
}

// paperModelAgainst builds a model whose store answers every query with the
// given status + body AND whose paper machinery is wired the way runTUI wires
// it, so buildPaperContent renders for real.
func paperModelAgainst(t *testing.T, status int, body, blocks string) model {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)

	prev := schemas
	t.Cleanup(func() { schemas = prev })
	schemas = []Schema{{Name: "person", Title: "People", Icon: "👤"}}

	theme := barkparkPaperTheme()
	decoded, err := pdrender.Decode([]byte(blocks))
	if err != nil || len(decoded) == 0 {
		t.Fatalf("fixture: block tree did not decode (%v, %d blocks)", err, len(decoded))
	}
	return model{
		ds:                  apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t", Dataset: "production"}),
		paperTheme:          theme,
		paperProfile:        pdrender.NoColor,
		paperRegistry:       pdrender.DefaultRegistry(theme),
		selectedPaperBlocks: decoded,
	}
}

const paperReadFailedLine = "Couldn't load referenced documents"

// THE BUG THIS PINS: each of the three paper resolvers discarded the read
// outcome, so a 403/500/unreachable store rendered a paper that LOOKS complete
// — every unresolved reference wearing its ordinary "not found" degrade. The
// pane must say the render is incomplete.
func TestPaperPaneReportsAFailedReferenceRead(t *testing.T) {
	for _, f := range paperFixtures {
		for _, status := range []int{401, 403, 500, 503} {
			m := paperModelAgainst(t, status, `{"error":"nope"}`, f.blocks)
			out := m.buildPaperContent(72)
			if !strings.Contains(out, paperReadFailedLine) {
				t.Errorf("%s: HTTP %d rendered a paper with no failure notice:\n%s", f.name, status, out)
			}
			// The degrade is the RIGHT inline behaviour and must not be
			// replaced by an error string inside the prose.
			if !strings.Contains(out, f.degrade) {
				t.Errorf("%s: HTTP %d lost the inline degrade %q:\n%s", f.name, status, f.degrade, out)
			}
		}
	}
}

// The other half of the contract, and the half that makes the test non-vacuous:
// an honest miss (a decodable 200 whose page simply does not carry the
// referenced document) renders the SAME body with NO notice. A test that only
// checked "the failure case renders something" would pass on the buggy code,
// because the miss renders something too.
func TestPaperPaneKeepsTheSilentDegradeOnAnHonestMiss(t *testing.T) {
	for _, f := range paperFixtures {
		m := paperModelAgainst(t, 200, `{"result":{"count":0,"documents":[]}}`, f.blocks)
		out := m.buildPaperContent(72)
		if strings.Contains(out, "Couldn't load") {
			t.Errorf("%s: an honest empty read reported a failure it did not have:\n%s", f.name, out)
		}
		if !strings.Contains(out, f.degrade) {
			t.Errorf("%s: an honest miss lost its degrade %q:\n%s", f.name, f.degrade, out)
		}
	}
}

// A read that RESOLVES must not carry the notice either — the notice is keyed
// on a failure-caused miss, not on the mere presence of a resolver.
func TestPaperPaneIsSilentWhenTheReferencesResolve(t *testing.T) {
	const page = `{"result":{"documents":[{"_id":"person-1","_type":"person","title":"Ada Lovelace"}]}}`
	for _, f := range paperFixtures[1:] { // the two person-keyed fixtures
		m := paperModelAgainst(t, 200, page, f.blocks)
		out := m.buildPaperContent(72)
		if strings.Contains(out, "Couldn't load") {
			t.Errorf("%s: a successful read reported a failure:\n%s", f.name, out)
		}
		if !strings.Contains(out, "Ada Lovelace") {
			t.Errorf("%s: a successful read did not render the resolved title:\n%s", f.name, out)
		}
	}
}

// A resolver whose OWN type read succeeded must not be dragged into a failure
// by an unrelated type's refusal: resolvePaperRef scans every schema, and
// flagging on any failure would cry wolf on a paper whose reference resolved
// fine. The notice is reported only when the lookup actually MISSED.
func TestPaperPaneDoesNotCryWolfWhenTheReferenceResolvedAnyway(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/person") {
			_, _ = w.Write([]byte(`{"result":{"documents":[{"_id":"person-1","_type":"person","title":"Ada Lovelace"}]}}`))
			return
		}
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"forbidden"}`))
	}))
	t.Cleanup(srv.Close)

	prev := schemas
	t.Cleanup(func() { schemas = prev })
	// The REFUSED type is scanned FIRST, so the scan has already seen a failure
	// by the time it finds the match. Ordering it the other way lets the scan
	// return before it ever meets the refusal, and the test would pass on a
	// resolver that flags every failure it sees.
	schemas = []Schema{{Name: "secret", Title: "Secrets"}, {Name: "person", Title: "People"}}

	theme := barkparkPaperTheme()
	decoded, err := pdrender.Decode([]byte(paperFixtures[2].blocks))
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	m := model{
		ds:                  apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t", Dataset: "production"}),
		paperTheme:          theme,
		paperProfile:        pdrender.NoColor,
		paperRegistry:       pdrender.DefaultRegistry(theme),
		selectedPaperBlocks: decoded,
	}
	out := m.buildPaperContent(72)
	if !strings.Contains(out, "Ada Lovelace") {
		t.Fatalf("fixture: the reference did not resolve:\n%s", out)
	}
	if strings.Contains(out, "Couldn't load") {
		t.Errorf("a resolved reference reported a failure because an UNRELATED type was refused:\n%s", out)
	}
}

// The notice has to reach the actual editor pane, not just the helper: the
// paper branch of buildEditorContent is what the pane renders.
func TestEditorPaneShowsThePaperReadFailureNotice(t *testing.T) {
	m := paperModelAgainst(t, 500, `{"error":"boom"}`, paperFixtures[0].blocks)
	m.selectedDoc = &Doc{ID: "paper-1", Type: "paper", Title: "A Paper"}
	m.editorSchema = &Schema{Name: "paper", Title: "Papers"}
	if !m.isCurrentPaper() {
		t.Fatal("fixture: the model does not render as a paper")
	}
	out := m.renderEditor(80, 24, true)
	if !strings.Contains(out, paperReadFailedLine) {
		t.Errorf("the editor pane rendered a paper with unread references and said nothing:\n%s", out)
	}
}

// The failure notice and the doc-list/editor placeholders must stay one
// vocabulary — a second, divergent error shape in the same TUI is worse than
// the bug. Same glyph, same dim styling, same second line.
func TestPaperNoticeMatchesTheEstablishedFailureVocabulary(t *testing.T) {
	notice := strings.Join(paperReadFailedNotice(), "\n")
	if !strings.Contains(notice, "✕ "+paperReadFailedLine) {
		t.Errorf("paper notice lost the shared ✕ prefix:\n%s", notice)
	}
	if !strings.Contains(notice, "the server refused or is unreachable") {
		t.Errorf("paper notice lost the shared second line:\n%s", notice)
	}
	// It must never borrow the doc-list wording — that one asserts emptiness.
	if strings.Contains(notice, "No documents yet") {
		t.Errorf("paper notice reuses the empty-state wording:\n%s", notice)
	}
}
