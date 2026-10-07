package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// importFakeServer is an in-memory dataset that answers the two routes
// `bp export` and `bp import` use: the NDJSON export and the mutate batch. It
// follows the server's semantics for the two ops the import sends:
// createOrReplace writes the DRAFT id (Content.Mutations apply_one/3 resolves
// DraftId.draft_id(id)), and publish moves drafts.<id> onto <id>. Export
// renders each document with the envelope keys Content.Envelope adds.
type importFakeServer struct {
	t   *testing.T
	srv *httptest.Server

	mu   sync.Mutex
	docs map[string]map[string]json.RawMessage // id -> user fields + _type
	rev  int

	// requests records each mutate request: mutation count and body bytes.
	requests []importFakeRequest
	// failOn makes the mutate request with this 1-based index answer 422 and
	// apply nothing, as the server's single transaction does.
	failOn int
}

type importFakeRequest struct {
	mutations int
	bytes     int
	body      []byte
}

func newImportFakeServer(t *testing.T) *importFakeServer {
	t.Helper()
	f := &importFakeServer{t: t, docs: map[string]map[string]json.RawMessage{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *importFakeServer) ctx() manifest.Context {
	return manifest.Context{Server: f.srv.URL, Workspace: "ws", Project: "proj", Dataset: "production"}
}

// seed stores a document directly, the way a dataset holds it.
func (f *importFakeServer) seed(id, typ string, fields map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	doc := map[string]json.RawMessage{}
	for k, v := range fields {
		b, err := json.Marshal(v)
		if err != nil {
			f.t.Fatalf("seed %s: %v", id, err)
		}
		doc[k] = b
	}
	doc["_type"], _ = json.Marshal(typ)
	f.docs[id] = doc
}

func (f *importFakeServer) handle(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/w/ws/p/proj/v1/data/export/"):
		f.export(w)
	case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/w/ws/p/proj/v1/data/mutate/"):
		f.mutate(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (f *importFakeServer) export(w http.ResponseWriter) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ids := make([]string, 0, len(f.docs))
	for id := range f.docs {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	w.Header().Set("Content-Type", "application/x-ndjson")
	for _, id := range ids {
		env := map[string]json.RawMessage{}
		for k, v := range f.docs[id] {
			env[k] = v
		}
		f.rev++
		env["_id"], _ = json.Marshal(id)
		env["_rev"], _ = json.Marshal(fmt.Sprintf("rev-%d", f.rev))
		env["_draft"], _ = json.Marshal(strings.HasPrefix(id, "drafts."))
		env["_publishedId"], _ = json.Marshal(strings.TrimPrefix(id, "drafts."))
		env["_createdAt"], _ = json.Marshal(fmt.Sprintf("2026-10-07T00:00:%02dZ", f.rev%60))
		env["_updatedAt"], _ = json.Marshal(fmt.Sprintf("2026-10-07T00:01:%02dZ", f.rev%60))
		line, _ := json.Marshal(env)
		_, _ = w.Write(append(line, '\n'))
	}
}

func (f *importFakeServer) mutate(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var req struct {
		Mutations []map[string]map[string]json.RawMessage `json:"mutations"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"code":"malformed","message":"invalid request body"}}`))
		return
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, importFakeRequest{mutations: len(req.Mutations), bytes: len(body), body: body})
	if len(req.Mutations) > importMaxMutations {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"error":{"code":"batch_too_large","message":"too many mutations"}}`))
		return
	}
	if f.failOn == len(f.requests) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"error":{"code":"validation_failed","message":"title is required"}}`))
		return
	}

	// Apply on a copy and commit at the end: one request, one transaction.
	next := map[string]map[string]json.RawMessage{}
	for k, v := range f.docs {
		next[k] = v
	}
	var results []map[string]string
	for _, m := range req.Mutations {
		for op, attrs := range m {
			var id, typ string
			_ = json.Unmarshal(attrs["_id"], &id)
			_ = json.Unmarshal(attrs["id"], &id)
			_ = json.Unmarshal(attrs["_type"], &typ)
			_ = json.Unmarshal(attrs["type"], &typ)
			switch op {
			case "createOrReplace":
				for _, k := range importServerOwnedKeys {
					if _, ok := attrs[k]; ok {
						f.t.Errorf("createOrReplace for %s carried the server-owned key %s", id, k)
					}
				}
				doc := map[string]json.RawMessage{}
				for k, v := range attrs {
					if k != "_id" {
						doc[k] = v
					}
				}
				next["drafts."+strings.TrimPrefix(id, "drafts.")] = doc
			case "publish":
				draft, ok := next["drafts."+id]
				if !ok {
					w.WriteHeader(http.StatusNotFound)
					_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no draft to publish"}}`))
					return
				}
				next[id] = draft
				delete(next, "drafts."+id)
			default:
				f.t.Errorf("unexpected mutation op %q", op)
			}
			results = append(results, map[string]string{"id": id, "operation": op})
		}
	}
	f.docs = next
	_ = json.NewEncoder(w).Encode(map[string]any{"transactionId": "tx", "results": results})
}

// importExportTo runs `bp export --out` against srv and returns the file path.
func importExportTo(t *testing.T, f *importFakeServer) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	var so, se bytes.Buffer
	if code := runExport(newWriter(&so, &se), globals{}, f.ctx(), []string{"--out", path}); code != exitOK {
		t.Fatalf("export exit = %d; stderr=%s", code, se.String())
	}
	return path
}

// importDocsByID reads an NDJSON export and keys each document by _id with the
// keys the server rewrites on every write removed (_rev and the timestamps).
func importDocsByID(t *testing.T, path string) map[string]map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	out := map[string]map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var doc map[string]any
		if err := json.Unmarshal([]byte(line), &doc); err != nil {
			t.Fatalf("bad line %q: %v", line, err)
		}
		delete(doc, "_rev")
		delete(doc, "_createdAt")
		delete(doc, "_updatedAt")
		out[doc["_id"].(string)] = doc
	}
	return out
}

func runImportForTest(t *testing.T, ctx manifest.Context, g globals, args ...string) (int, string, string) {
	t.Helper()
	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	out.output = g.output
	code := runImport(out, g, ctx, args)
	return code, so.String(), se.String()
}

func seedRoundTripSource(f *importFakeServer) {
	f.seed("post-1", "post", map[string]any{"title": "First", "body": "Hello", "tags": []string{"a", "b"}})
	f.seed("post-2", "post", map[string]any{"title": "Second", "meta": map[string]any{"views": 12, "ratio": 0.5, "nested": map[string]any{"ok": true}}})
	// A draft on top of a published twin: the draft must stay a draft and
	// must not be lost under the published row.
	f.seed("drafts.post-2", "post", map[string]any{"title": "Second, edited"})
	// A draft with no published twin.
	f.seed("drafts.post-3", "post", map[string]any{"title": "Unpublished"})
	f.seed("author-1", "author", map[string]any{"name": "Åse", "ref": map[string]any{"_ref": "post-1", "_type": "reference"}})
}

// ROUND TRIP (criterion 4). Export a dataset, import the file into an EMPTY
// dataset, export that, and compare: the same number of documents and the
// same content for every document, drafts and published alike.
func TestRunImportRoundTripsExportIntoEmptyDataset(t *testing.T) {
	src := newImportFakeServer(t)
	seedRoundTripSource(src)
	backup := importExportTo(t, src)

	dst := newImportFakeServer(t)
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, backup)
	if code != exitOK {
		t.Fatalf("import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "imported 5 documents into ws/proj/production") {
		t.Errorf("stdout = %q, want the applied count and scope", stdout)
	}

	restored := importExportTo(t, dst)
	want := importDocsByID(t, backup)
	got := importDocsByID(t, restored)
	if len(got) != len(want) {
		t.Fatalf("restored %d documents, backup has %d", len(got), len(want))
	}
	for id, w := range want {
		if !reflect.DeepEqual(got[id], w) {
			t.Errorf("document %s differs after the round trip:\n got %v\nwant %v", id, got[id], w)
		}
	}
}

// ORDER AND SHAPE (criterion 1). Published rows are applied before drafts, a
// published row is createOrReplace + publish, a draft row is createOrReplace
// only, and no server-owned key is sent (the fake server fails the test when
// one arrives).
func TestRunImportAppliesPublishedBeforeDraftsAndDropsServerKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup.ndjson")
	lines := []string{
		`{"_id":"drafts.a","_type":"post","_rev":"r1","_draft":true,"_publishedId":"a","_createdAt":"x","_updatedAt":"y","title":"draft a"}`,
		`{"_id":"a","_type":"post","_rev":"r2","_draft":false,"_publishedId":"a","_createdAt":"x","_updatedAt":"y","title":"pub a"}`,
		`{"_id":"b","_type":"post","_rev":"r3","title":"pub b"}`,
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := newImportFakeServer(t)
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, path)
	if code != exitOK {
		t.Fatalf("import exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if len(dst.requests) != 1 {
		t.Fatalf("mutate requests = %d, want 1", len(dst.requests))
	}
	var body struct {
		Mutations []map[string]map[string]any `json:"mutations"`
	}
	if err := json.Unmarshal(dst.requests[0].body, &body); err != nil {
		t.Fatal(err)
	}
	var seq []string
	for _, m := range body.Mutations {
		for op, attrs := range m {
			id, _ := attrs["_id"].(string)
			if id == "" {
				id, _ = attrs["id"].(string)
			}
			seq = append(seq, op+":"+id)
		}
	}
	// The draft row's createOrReplace comes after the publishes. Sent before
	// them, `publish a` would promote the draft's content over the published
	// row, which is what this test first caught.
	wantSeq := []string{"createOrReplace:a", "createOrReplace:b", "publish:a", "publish:b", "createOrReplace:drafts.a"}
	if !reflect.DeepEqual(seq, wantSeq) {
		t.Errorf("mutation order = %v, want %v", seq, wantSeq)
	}
	if _, ok := dst.docs["drafts.a"]; !ok {
		t.Error("drafts.a did not stay a draft")
	}
	if _, ok := dst.docs["a"]; !ok {
		t.Error("a was not published")
	}
}

// DRY RUN (criterion 2). It reports create, overwrite and skip per document
// and writes nothing.
func TestRunImportDryRunReportsAndWritesNothing(t *testing.T) {
	src := newImportFakeServer(t)
	seedRoundTripSource(src)
	backup := importExportTo(t, src)

	dst := newImportFakeServer(t)
	dst.seed("post-1", "post", map[string]any{"title": "already here"})

	// The export sorts ids: author-1, drafts.post-2, drafts.post-3, post-1,
	// post-2 on lines 1 to 5. Apply order puts the published rows first
	// (author-1, post-1, post-2), so --from-line 4 (post-1) skips author-1 only.
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{dryRun: true, output: "json"}, backup, "--overwrite", "--from-line", "4")
	if code != exitOK {
		t.Fatalf("dry-run exit = %d; stdout=%s stderr=%s", code, stdout, stderr)
	}
	if len(dst.requests) != 0 {
		t.Fatalf("dry run sent %d mutate requests, want 0", len(dst.requests))
	}
	var report struct {
		DryRun    bool `json:"dry_run"`
		Documents []struct {
			Line   int    `json:"line"`
			ID     string `json:"id"`
			Action string `json:"action"`
		} `json:"documents"`
	}
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("dry-run stdout is not one JSON document: %v\n%s", err, stdout)
	}
	got := map[string]string{}
	for _, d := range report.Documents {
		got[d.ID] = d.Action
	}
	want := map[string]string{
		"author-1": "skip", "post-1": "overwrite", "post-2": "create",
		"drafts.post-2": "create", "drafts.post-3": "create",
	}
	if !report.DryRun || !reflect.DeepEqual(got, want) {
		t.Errorf("dry-run actions = %v (dry_run=%v), want %v", got, report.DryRun, want)
	}
	if len(dst.docs) != 1 {
		t.Errorf("target holds %d documents after a dry run, want the 1 it had", len(dst.docs))
	}
}

// COLLISION (criterion 2). An id that already exists is refused unless
// --overwrite is given, the refusal names the ids, and nothing is written.
func TestRunImportRefusesExistingIDsUnlessOverwrite(t *testing.T) {
	src := newImportFakeServer(t)
	seedRoundTripSource(src)
	backup := importExportTo(t, src)

	dst := newImportFakeServer(t)
	dst.seed("post-1", "post", map[string]any{"title": "already here"})
	// A draft-only document in the target collides with the published row
	// post-2 too, because createOrReplace writes drafts.post-2.
	dst.seed("drafts.post-2", "post", map[string]any{"title": "local draft"})

	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, backup)
	if code != exitConflict {
		t.Fatalf("exit = %d, want %d (conflict); stderr=%s", code, exitConflict, stderr)
	}
	for _, id := range []string{"post-1", "post-2", "drafts.post-2"} {
		if !strings.Contains(stderr, id) {
			t.Errorf("refusal does not name %s:\n%s", id, stderr)
		}
	}
	if strings.Contains(stderr, "author-1") {
		t.Errorf("refusal names author-1, which does not exist in the target:\n%s", stderr)
	}
	if len(dst.requests) != 0 {
		t.Fatalf("a refused import sent %d mutate requests", len(dst.requests))
	}

	code, _, stderr = runImportForTest(t, dst.ctx(), globals{}, backup, "--overwrite")
	if code != exitOK {
		t.Fatalf("--overwrite exit = %d; stderr=%s", code, stderr)
	}
	if got := string(dst.docs["post-1"]["title"]); got != `"First"` {
		t.Errorf("post-1 title = %s after --overwrite, want the backup's", got)
	}
}

// BATCHING (criterion 3). No request carries more than 1000 mutations or more
// bytes than the cap, and a published row's two mutations never split.
func TestRunImportBatchesStayUnderMutateLimits(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup.ndjson")
	var b strings.Builder
	for n := 0; n < 1200; n++ {
		fmt.Fprintf(&b, `{"_id":"p-%04d","_type":"post","title":"%s"}`+"\n", n, strings.Repeat("x", 100))
	}
	for n := 0; n < 300; n++ {
		fmt.Fprintf(&b, `{"_id":"drafts.d-%04d","_type":"post","title":"draft"}`+"\n", n)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	dst := newImportFakeServer(t)
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, path)
	if code != exitOK {
		t.Fatalf("import exit = %d; stderr=%s", code, stderr)
	}
	total := 0
	for k, r := range dst.requests {
		if r.mutations > importMaxMutations {
			t.Errorf("request %d carried %d mutations, over %d", k+1, r.mutations, importMaxMutations)
		}
		total += r.mutations
	}
	if total != 1200*2+300 {
		t.Errorf("sent %d mutations, want %d", total, 1200*2+300)
	}
	if len(dst.docs) != 1500 {
		t.Errorf("target holds %d documents, want 1500", len(dst.docs))
	}

	// A small byte cap forces many batches; each must fit it.
	dst2 := newImportFakeServer(t)
	const cap = 20_000
	code, _, stderr = runImportForTest(t, dst2.ctx(), globals{}, path, "--batch-bytes", fmt.Sprint(cap))
	if code != exitOK {
		t.Fatalf("import --batch-bytes exit = %d; stderr=%s", code, stderr)
	}
	if len(dst2.requests) < 10 {
		t.Errorf("--batch-bytes %d produced %d requests, want many", cap, len(dst2.requests))
	}
	for k, r := range dst2.requests {
		if r.bytes > cap {
			t.Errorf("request %d is %d bytes, over the %d cap", k+1, r.bytes, cap)
		}
	}
	if len(dst2.docs) != 1500 {
		t.Errorf("target holds %d documents, want 1500", len(dst2.docs))
	}
}

// RESUME (criterion 3). A failed batch names the first line it did not apply,
// and a rerun with --from-line on that line finishes the restore.
func TestRunImportFailedBatchNamesLineAndResumes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup.ndjson")
	var b strings.Builder
	for n := 0; n < 1200; n++ {
		fmt.Fprintf(&b, `{"_id":"p-%04d","_type":"post","title":"t"}`+"\n", n)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	dst := newImportFakeServer(t)
	dst.failOn = 2
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, path)
	if code == exitOK {
		t.Fatalf("import with a failing batch exited 0; stderr=%s", stderr)
	}
	// 500 published rows (1000 mutations) per batch, so batch 2 starts on line 501.
	if !strings.Contains(stderr, "stopped at line 501") || !strings.Contains(stderr, "--from-line 501") {
		t.Fatalf("stderr does not name line 501 as the resume point:\n%s", stderr)
	}
	if len(dst.docs) != 500 {
		t.Fatalf("target holds %d documents after the failure, want the first batch's 500", len(dst.docs))
	}

	dst.failOn = 0
	code, stdout, stderr := runImportForTest(t, dst.ctx(), globals{}, path, "--from-line", "501")
	if code != exitOK {
		t.Fatalf("resume exit = %d; stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "500 skipped") {
		t.Errorf("resume stdout = %q, want 500 skipped", stdout)
	}
	if len(dst.docs) != 1200 {
		t.Errorf("target holds %d documents after the resume, want 1200", len(dst.docs))
	}
}

// A backup the server cut short ends with the export's incomplete marker. The
// import must refuse it before writing anything.
func TestRunImportRefusesIncompleteExportMarker(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.ndjson")
	body := `{"_id":"a","_type":"post","title":"t"}` + "\n" + `{"_barkpark_export":"incomplete","documents":1}` + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := newImportFakeServer(t)
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, path)
	if code != exitValidation {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitValidation, stderr)
	}
	if !strings.Contains(stderr, "line 2") || !strings.Contains(stderr, "incomplete marker") {
		t.Errorf("stderr = %q, want it to name line 2 and the incomplete marker", stderr)
	}
	if len(dst.requests) != 0 {
		t.Errorf("sent %d mutate requests for a refused file", len(dst.requests))
	}
}

// A backup whose sidecar disagrees with it is truncated or edited; the import
// refuses it.
func TestRunImportRefusesFileThatDoesNotMatchItsSidecar(t *testing.T) {
	src := newImportFakeServer(t)
	seedRoundTripSource(src)
	backup := importExportTo(t, src)
	raw, err := os.ReadFile(backup)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitAfter(string(raw), "\n")
	if err := os.WriteFile(backup, []byte(strings.Join(lines[:2], "")), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := newImportFakeServer(t)
	code, _, stderr := runImportForTest(t, dst.ctx(), globals{}, backup)
	if code != exitValidation || !strings.Contains(stderr, "does not match its sidecar") {
		t.Fatalf("exit = %d, stderr = %q; want a sidecar refusal", code, stderr)
	}
	if len(dst.requests) != 0 {
		t.Errorf("sent %d mutate requests for a refused file", len(dst.requests))
	}
}

func TestRunImportHelpAndUsage(t *testing.T) {
	var so, se bytes.Buffer
	if code := runImport(newWriter(&so, &se), globals{help: true}, manifest.Context{}, nil); code != exitOK {
		t.Fatalf("--help exit = %d", code)
	}
	for _, want := range []string{"--dry-run", "--overwrite", "--from-line", "createOrReplace + publish", "1000 mutations"} {
		if !strings.Contains(so.String(), want) {
			t.Errorf("import --help does not mention %q", want)
		}
	}
	so.Reset()
	se.Reset()
	if code := runImport(newWriter(&so, &se), globals{}, manifest.Context{}, nil); code != exitUsage {
		t.Errorf("no file: exit = %d, want %d", code, exitUsage)
	}
}
