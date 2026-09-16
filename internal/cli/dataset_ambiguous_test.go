package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE FIXTURE MUST CONTAIN THE SUBJECT. A corpus with no cross-dataset twin
// cannot detect this defect at all — the guard would pass on a CLI that reads
// `page.dataset_ambiguous` and on one that has never heard of it, which is a
// green with no subject. So every RED arm below serves a page whose envelope
// NAMES withheld ids, in the shape the live server emits (measured against
// guerrilla 2026-09-16: ten aker-brygge<->production `akbr-*` rows plus the
// production<->tasks `stw1-basepath-redirect-fix`), and every QUIET arm serves
// the identical corpus with the field ABSENT.

const (
	twinAkbr = "akbr-feedback-2026-08-epic"
	twinStw1 = "stw1-basepath-redirect-fix"
)

// liveShapedAmbiguous is the envelope fragment the live unscoped /v1/tasks page
// carries, abridged to two of the eleven.
var liveShapedAmbiguous = []map[string]any{
	{"doc_id": twinAkbr, "datasets": []string{"aker-brygge", "production"}},
	{"doc_id": twinStw1, "datasets": []string{"production", "tasks"}},
}

func taskPageBody(rows []json.RawMessage, ambiguous []map[string]any, hasMore bool, offset, limit int) []byte {
	page := map[string]any{
		"dataset":       nil,
		"dataset_scope": "all-datasets-in-scope",
		"datasets":      []string{"production"},
		"has_more":      hasMore,
		"limit":         limit,
		"offset":        offset,
		"returned":      len(rows),
	}
	if ambiguous != nil {
		page["dataset_ambiguous"] = ambiguous
	}
	body, _ := json.Marshal(map[string]any{"ok": true, "docs": rows, "page": page})
	return body
}

// ===========================================================================
// THE RED ARM, MACHINE HALF — `--all` must not lose the withheld set.
//
// This is the test that FAILS if the omission returns. Revert either
// `twins = mergeDatasetTwins(...)` or `wrapped = attachDatasetTwins(...)` in
// paginatedAllWalk and it reds: the stitched `{docs: […]}` carries no `page`
// block at all, which is exactly the pre-fix behaviour measured live.
// ===========================================================================

func TestPaginatedAll_CarriesWithheldTwinsAcrossTheStitch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		n := 100
		if offset == 200 {
			n = 1
		}
		rows := make([]json.RawMessage, n)
		for i := range rows {
			rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"row-%d"}`, offset+i))
		}
		// Every page of the walk restates the scope-wide withheld set, exactly
		// as the live server does.
		w.Write(taskPageBody(rows, liveShapedAmbiguous, n == 100, offset, 101))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	cmd := manifest.Command{Noun: "task", Verb: "ls", HTTP: manifest.HTTP{Method: "GET"}}

	if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}, paginatedAllOpts{}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
	}

	var got struct {
		Docs []json.RawMessage `json:"docs"`
		Page *struct {
			DatasetAmbiguous []datasetTwin `json:"dataset_ambiguous"`
		} `json:"page"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("stitched output not JSON: %v\n%s", err, stdout.String())
	}

	// THE PAGE IS STILL SHORT BY DESIGN. The remedy reports the omission; it
	// must not serve the withheld rows. 201 is the row count the walk always
	// emitted — a build that un-collapsed the twins would read 203 here.
	if len(got.Docs) != 201 {
		t.Fatalf("rows=%d, want 201 — the fix REPORTS the omission, it must not un-collapse the page", len(got.Docs))
	}
	for _, row := range got.Docs {
		if bytes.Contains(row, []byte(twinAkbr)) || bytes.Contains(row, []byte(twinStw1)) {
			t.Fatalf("a withheld twin was served as a ROW: %s", row)
		}
	}

	// THE MACHINE HALF: a script reading -o json can tell rows were withheld,
	// and WHICH ones, under --all as under a single page.
	if got.Page == nil {
		t.Fatalf("the --all stitch dropped the page block entirely — a script cannot tell rows were withheld: %s", stdout.String())
	}
	if len(got.Page.DatasetAmbiguous) != 2 {
		t.Fatalf("page.dataset_ambiguous = %d entries, want 2: %s", len(got.Page.DatasetAmbiguous), stdout.String())
	}
	byID := map[string][]string{}
	for _, twin := range got.Page.DatasetAmbiguous {
		byID[twin.DocID] = twin.Datasets
	}
	if ds, ok := byID[twinStw1]; !ok || strings.Join(ds, ",") != "production,tasks" {
		t.Fatalf("%s missing or wrong datasets: %v", twinStw1, byID)
	}
	if _, ok := byID[twinAkbr]; !ok {
		t.Fatalf("%s missing from the stitched withheld set: %v", twinAkbr, byID)
	}

	// THE PROSE HALF, same run: stderr must name at least one real twin.
	if !strings.Contains(stderr.String(), twinStw1) {
		t.Fatalf("stderr never named a withheld id: %q", stderr.String())
	}
}

// ===========================================================================
// THE QUIET ARM — the positive control. Same walk, same row count, same
// server, only `dataset_ambiguous` absent. The stitch must be BYTE-IDENTICAL
// to the pre-fix shape and stderr must carry no twin notice. A note that
// always appears measures nothing.
// ===========================================================================

func TestPaginatedAll_TwinFreeLedgerStitchesByteIdentically(t *testing.T) {
	newSrv := func(ambiguous []map[string]any) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
			n := 100
			if offset == 200 {
				n = 1
			}
			rows := make([]json.RawMessage, n)
			for i := range rows {
				rows[i] = json.RawMessage(fmt.Sprintf(`{"id":"row-%d"}`, offset+i))
			}
			w.Write(taskPageBody(rows, ambiguous, n == 100, offset, 101))
		}))
	}
	run := func(t *testing.T, srv *httptest.Server) (string, string) {
		t.Helper()
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.output = "json"
		cmd := manifest.Command{Noun: "task", Verb: "ls", HTTP: manifest.HTTP{Method: "GET"}}
		if code := runPaginatedAll(out, cmd, srv.URL, map[string]string{}, paginatedAllOpts{}); code != exitOK {
			t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
		}
		return stdout.String(), stderr.String()
	}

	quietSrv := newSrv(nil)
	defer quietSrv.Close()
	quietOut, quietErr := run(t, quietSrv)

	// Byte-identical to the shape the walk emitted before this change: the row
	// array and nothing else.
	if quietOut != `{"docs":[`+rowsJoined(201)+"]}\n" {
		t.Fatalf("twin-free stitch is not byte-identical to the pre-fix shape:\n%s", quietOut)
	}
	if strings.Contains(quietErr, "WITHHELD") || strings.Contains(quietErr, "dataset_ambiguous") {
		t.Fatalf("a twin-free page emitted a withheld notice — the note measures nothing if it always fires: %q", quietErr)
	}

	// THE COMPANION. Without this, the quiet arm above would pass just as well
	// on a CLI that detects no withholding at all. Same corpus, field present:
	// the two outputs MUST differ.
	loudSrv := newSrv(liveShapedAmbiguous)
	defer loudSrv.Close()
	loudOut, loudErr := run(t, loudSrv)
	if loudOut == quietOut {
		t.Fatalf("withheld and twin-free ledgers stitched identically — the quiet arm proves nothing:\n%s", loudOut)
	}
	if !strings.Contains(loudErr, "WITHHELD") {
		t.Fatalf("withheld ledger emitted no notice: %q", loudErr)
	}
}

func rowsJoined(n int) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = fmt.Sprintf(`{"id":"row-%d"}`, i)
	}
	return strings.Join(parts, ",")
}

// ===========================================================================
// THE SINGLE-PAGE PROSE ARM. A single page already passes the envelope
// through untouched, so the machine half needed no repair there — but nothing
// was ever SAID. Revert the warnIfDatasetTwinsWithheld call in runCommand and
// this reds.
// ===========================================================================

func TestDatasetTwinsNotice_NamesIdsAndDatasetsOnlyWhenWithheld(t *testing.T) {
	// Silent on every shape that names nothing. These are the cases that keep
	// the guard callable unconditionally on every list page.
	for name, body := range map[string]string{
		"no page block":        `{"ok":true,"docs":[]}`,
		"page without field":   `{"ok":true,"docs":[],"page":{"has_more":false}}`,
		"empty ambiguous list": `{"ok":true,"docs":[],"page":{"dataset_ambiguous":[]}}`,
		"blank doc_id only":    `{"ok":true,"docs":[],"page":{"dataset_ambiguous":[{"doc_id":"  ","datasets":["a"]}]}}`,
		"not a list envelope":  `not json at all`,
	} {
		t.Run("quiet/"+name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			warnIfDatasetTwinsWithheld(out, []byte(body))
			if stderr.Len() != 0 {
				t.Fatalf("spoke about a page that withheld nothing: %q", stderr.String())
			}
		})
	}

	t.Run("loud/names the id and its datasets", func(t *testing.T) {
		body := taskPageBody([]json.RawMessage{json.RawMessage(`{"id":"a"}`)}, liveShapedAmbiguous, true, 0, 1)
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		warnIfDatasetTwinsWithheld(out, body)
		got := stderr.String()
		for _, want := range []string{twinAkbr, twinStw1, "aker-brygge", "tasks", "WITHHELD 2 row(s)"} {
			if !strings.Contains(got, want) {
				t.Fatalf("notice missing %q: %q", want, got)
			}
		}
		if stdout.Len() != 0 {
			t.Fatalf("the notice must ride stderr so -o json stdout stays parseable; stdout=%q", stdout.String())
		}
	})
}

// mergeDatasetTwins unions by doc_id and sorts, so the stitch is deterministic
// regardless of which page answered first or whether a twin appeared mid-walk.
func TestMergeDatasetTwins_UnionsByDocIDAndSorts(t *testing.T) {
	a := []datasetTwin{{DocID: "z", Datasets: []string{"production", "tasks"}}}
	b := []datasetTwin{{DocID: "z", Datasets: []string{"production", "tasks"}}, {DocID: "a", Datasets: []string{"x"}}}
	got := mergeDatasetTwins(a, b)
	if len(got) != 2 || got[0].DocID != "a" || got[1].DocID != "z" {
		t.Fatalf("merge = %+v, want [a z] with no duplicate", got)
	}
	if merged := mergeDatasetTwins(a, nil); len(merged) != 1 {
		t.Fatalf("an empty page must not disturb the accumulator: %+v", merged)
	}
}

// attachDatasetTwins never touches the row array and never fires on an empty
// set — the two properties acceptance criterion 3 turns on.
func TestAttachDatasetTwins_NoOpWhenNothingWithheld(t *testing.T) {
	base := []byte(`{"docs":[{"id":"a"}]}`)
	if got := attachDatasetTwins(base, nil); string(got) != string(base) {
		t.Fatalf("empty set changed the body: %s", got)
	}
	got := attachDatasetTwins(base, []datasetTwin{{DocID: twinStw1, Datasets: []string{"production", "tasks"}}})
	var env struct {
		Docs []json.RawMessage `json:"docs"`
		Page struct {
			DatasetAmbiguous []datasetTwin `json:"dataset_ambiguous"`
		} `json:"page"`
	}
	if err := json.Unmarshal(got, &env); err != nil {
		t.Fatalf("not JSON: %v — %s", err, got)
	}
	if len(env.Docs) != 1 {
		t.Fatalf("rows were altered: %s", got)
	}
	if len(env.Page.DatasetAmbiguous) != 1 || env.Page.DatasetAmbiguous[0].DocID != twinStw1 {
		t.Fatalf("withheld set not attached: %s", got)
	}
}
