package cli

// `bp paper export` against a fake source route. The CENSUS these tests defend
// is in paper_export_cmd.go's header: get and list already shipped as the
// generic `bp doc get|ls paper`, export did not — so what is proven here is the
// ROUND TRIP, not the fetch: the bytes export puts on stdout are the bytes
// `POST /v1/plugins/bulldocs/papers` accepts, block-for-block.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakePaperSourceServer serves the JSON leg of GET /papers/:slug/source in the
// REAL envelope shape: {id,title,_rev,source:{kind,blocks|html}}.
type fakePaperSourceServer struct {
	envelope string
	status   int
	lastPath string
	lastQ    string

	// row is the stored document GET /v1/data/doc/:ds/paper/:slug answers with
	// (the publish wall's label spine lives there, not in the reader source).
	// Empty means the route 404s — the share-scoped reader's situation.
	row      string
	rowReads int
}

func (f *fakePaperSourceServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/papers/", func(w http.ResponseWriter, r *http.Request) {
		f.lastPath = r.URL.Path
		f.lastQ = r.URL.RawQuery
		if !strings.HasSuffix(r.URL.Path, "/source") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if f.status != 0 {
			w.WriteHeader(f.status)
		}
		_, _ = w.Write([]byte(f.envelope))
	})
	// The stored-row read is SCOPED (/w/<ws>/p/<proj>/v1/data/doc/…), so match
	// on the segment rather than a prefix pattern.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.URL.Path, "/v1/data/doc/") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f.rowReads++
		if f.row == "" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":` + f.row + `}`))
	})
	return mux
}

const exportBlocks = `[{"id":"b0","type":"heading","level":1,"text":"Round trip"},` +
	`{"id":"b1","type":"paragraph","content":[{"type":"text","value":"the blocks are the truth"}]},` +
	`{"id":"b2","type":"table","shape":"rows","rows":[{"cells":[{"value":"a"},{"value":"b"}]}]}]`

func TestPaperExportEmitsPublishPayloadOnStdout(t *testing.T) {
	fake := &fakePaperSourceServer{
		envelope: `{"id":"p1","title":"T","_rev":"abc123","source":{"kind":"blocks","blocks":` + exportBlocks + `}}`,
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runPaper(out, g, []string{"export", "p1"}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}

	// It read the JSON leg of the source route, not the BPML one.
	if fake.lastPath != "/papers/p1/source" || !strings.Contains(fake.lastQ, "format=json") {
		t.Fatalf("export fetched %s?%s, want /papers/p1/source?format=json", fake.lastPath, fake.lastQ)
	}

	var payload map[string]any
	if err := json.Unmarshal(so.Bytes(), &payload); err != nil {
		t.Fatalf("stdout is not JSON (%v):\n%s", err, so.String())
	}

	// The publish endpoint's contract: slug + blocks, and NOTHING the stored row
	// carries that it would refuse or ignore.
	if payload["slug"] != "p1" {
		t.Fatalf("slug = %v, want p1", payload["slug"])
	}
	if payload["title"] != "T" {
		t.Fatalf("title = %v, want T", payload["title"])
	}
	for _, banned := range []string{"_id", "_rev", "_type", "_createdAt", "_updatedAt", "ifRev", "if_rev"} {
		if _, ok := payload[banned]; ok {
			t.Fatalf("payload carries %q — publish is unfenced create-or-replace and refuses ifRev; a stored-row field is not a publish body:\n%s", banned, so.String())
		}
	}

	// BLOCK-FOR-BLOCK: the exported blocks are the served blocks, not a
	// re-rendering of them.
	gotBlocks, err := json.Marshal(payload["blocks"])
	if err != nil {
		t.Fatal(err)
	}
	var want any
	if err := json.Unmarshal([]byte(exportBlocks), &want); err != nil {
		t.Fatal(err)
	}
	wantBlocks, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	if string(gotBlocks) != string(wantBlocks) {
		t.Fatalf("blocks changed in flight:\n got: %s\nwant: %s", gotBlocks, wantBlocks)
	}
}

// The round trip proper: export's stdout, fed back to the ingest endpoint,
// arrives as a body the server accepts — same slug, same blocks.
func TestPaperExportOutputIsAcceptedByIngest(t *testing.T) {
	fake := &fakePaperSourceServer{
		envelope: `{"id":"p1","title":"T","_rev":"abc123","source":{"kind":"blocks","blocks":` + exportBlocks + `}}`,
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"export", "p1"}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}

	// The ingest guard, transcribed from BulldocsIngestController.ingest/2:
	// %{"slug" => slug, "blocks" => blocks} when is_binary(slug) and slug != ""
	// and is_list(blocks).
	var body struct {
		Slug   string            `json:"slug"`
		Blocks []json.RawMessage `json:"blocks"`
	}
	if err := json.Unmarshal(so.Bytes(), &body); err != nil {
		t.Fatalf("export output is not an ingest body: %v", err)
	}
	if body.Slug == "" {
		t.Fatal("ingest would refuse: empty slug")
	}
	if len(body.Blocks) != 3 {
		t.Fatalf("ingest would receive %d blocks, export served 3 — content lost in the round trip", len(body.Blocks))
	}
}

// A body_html paper exports its HTML leg and NEVER a synthesised blocks[]: the
// publish endpoint has a body_html clause and that is the honest target.
func TestPaperExportHTMLPaperKeepsTheHTMLLeg(t *testing.T) {
	fake := &fakePaperSourceServer{
		envelope: `{"id":"p2","title":"Legacy","_rev":"r","source":{"kind":"html","html":"<h1>old</h1>"}}`,
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"export", "p2"}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(so.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["body_html"] != "<h1>old</h1>" {
		t.Fatalf("body_html = %v, want the served HTML", payload["body_html"])
	}
	if _, ok := payload["blocks"]; ok {
		t.Fatalf("an html-source paper exported blocks — nothing derived them:\n%s", so.String())
	}
}

func TestPaperExportWritesFileWithOut(t *testing.T) {
	fake := &fakePaperSourceServer{
		envelope: `{"id":"p1","title":"T","_rev":"abc123","source":{"kind":"blocks","blocks":` + exportBlocks + `}}`,
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	dir, g := paperTestEnv(t, srv.URL)
	dest := filepath.Join(dir, "payload.json")

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"export", "p1", "--out", dest}); code != exitOK {
		t.Fatalf("export --out exit = %d; stderr=%s", code, se.String())
	}
	raw, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("--out wrote no file: %v", err)
	}
	if !strings.Contains(string(raw), `"slug": "p1"`) {
		t.Fatalf("file is not the payload:\n%s", raw)
	}
	if strings.Contains(so.String(), `"slug"`) {
		t.Fatalf("--out also dumped the payload to stdout:\n%s", so.String())
	}
}

// A refusal renders the SERVER's words, and puts nothing on stdout — a caller
// redirecting stdout into a file must not end up with a truncated "payload".
func TestPaperExportMissingPaperRefusesCleanly(t *testing.T) {
	fake := &fakePaperSourceServer{
		status:   http.StatusNotFound,
		envelope: `{"error":{"code":"not_found","message":"no such paper","hint":"check the slug"}}`,
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runPaper(out, g, []string{"export", "ghost"}); code == exitOK {
		t.Fatalf("export of a missing paper exited OK; stdout=%s", so.String())
	}
	if so.Len() != 0 {
		t.Fatalf("a refusal wrote to stdout:\n%s", so.String())
	}
	if !strings.Contains(se.String(), "not_found") && !strings.Contains(se.String(), "no such paper") {
		t.Fatalf("refusal did not render the server's words:\n%s", se.String())
	}
}

func TestPaperExportUsageErrors(t *testing.T) {
	_, g := paperTestEnv(t, "http://127.0.0.1:1")
	for _, args := range [][]string{{"export"}, {"export", "a", "b"}, {"export", "a", "--out"}} {
		var so, se bytes.Buffer
		out := newWriter(&so, &se)
		if code := runPaper(out, g, args); code != exitUsage {
			t.Fatalf("runPaper %v exit = %d, want exitUsage", args, code)
		}
	}
}

// The publish wall requires a description (20+ chars) and 1-12 weighted tags.
// The reader source route serves neither, so export reads the stored row for
// them — without this the round trip loses the spine and the re-publish is
// refused.
func TestPaperExportCarriesTheLabelSpine(t *testing.T) {
	fake := &fakePaperSourceServer{
		envelope: `{"id":"p1","title":"T","_rev":"abc123","source":{"kind":"blocks","blocks":` + exportBlocks + `}}`,
		row:      `{"_id":"p1","description":"a description long enough for the wall","tags":[{"tag":"cli","strength":80,"rationale":"why"}]}`,
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"export", "p1"}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	if fake.rowReads == 0 {
		t.Fatal("export never read the stored row — the label spine cannot have come from anywhere")
	}

	var payload map[string]any
	if err := json.Unmarshal(so.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["description"] != "a description long enough for the wall" {
		t.Fatalf("description = %v; the re-publish would be refused label_spine", payload["description"])
	}
	tags, ok := payload["tags"].([]any)
	if !ok || len(tags) != 1 {
		t.Fatalf("tags = %v, want the row's one weighted tag", payload["tags"])
	}
	if se.Len() != 0 {
		t.Fatalf("a complete payload still warned:\n%s", se.String())
	}
}

// When the spine cannot be recovered the payload is still served — but the
// caller is TOLD, on stderr, that re-publishing it will be refused. A silent
// partial payload is the failure this guards.
func TestPaperExportWarnsWhenTheSpineIsUnreachable(t *testing.T) {
	fake := &fakePaperSourceServer{
		envelope: `{"id":"p1","title":"T","_rev":"abc123","source":{"kind":"blocks","blocks":` + exportBlocks + `}}`,
		// row empty: the document API 404s for this caller.
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"export", "p1"}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	if !strings.Contains(se.String(), "description") || !strings.Contains(se.String(), "refused") {
		t.Fatalf("no warning that the payload cannot be re-published:\n%s", se.String())
	}
	// stdout is still the payload, and still only the payload.
	var payload map[string]any
	if err := json.Unmarshal(so.Bytes(), &payload); err != nil {
		t.Fatalf("stdout is not the payload: %v", err)
	}
	if _, ok := payload["description"]; ok {
		t.Fatal("export invented a description")
	}
}
