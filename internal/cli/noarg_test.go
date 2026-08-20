package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestLoadFailureAdviceLocalKeepsMixLine(t *testing.T) {
	for _, base := range []string{
		"http://localhost:4000",
		"http://127.0.0.1:4000",
		"http://0.0.0.0:4000",
		"", // empty target → local floor
	} {
		got := LoadFailureAdvice(base)
		if !strings.Contains(got, "mix phx.server") {
			t.Errorf("local target %q: expected mix phx.server advice, got %q", base, got)
		}
		if strings.Contains(got, "bp doctor") {
			t.Errorf("local target %q: must not point at bp doctor, got %q", base, got)
		}
	}
}

func TestLoadFailureAdviceRemoteNamesURLAndDoctor(t *testing.T) {
	base := "https://guerrilla.barkpark.cloud"
	got := LoadFailureAdvice(base)
	// A remote target must name the URL (so the user knows WHAT to reach) and point
	// at `bp doctor` (the health gate), never the useless local mix-phx.server line.
	if !strings.Contains(got, base) {
		t.Errorf("remote advice should name the URL %q, got %q", base, got)
	}
	if !strings.Contains(got, "bp doctor") {
		t.Errorf("remote advice should point at bp doctor, got %q", got)
	}
	if strings.Contains(got, "mix phx.server") {
		t.Errorf("remote advice must NOT print the local mix line, got %q", got)
	}
}

func TestIsLocalTarget(t *testing.T) {
	cases := map[string]bool{
		"http://localhost:4000":            true,
		"http://127.0.0.1:4000":            true,
		"http://[::1]:4000":                true,
		"http://0.0.0.0:4000":              true,
		"":                                 true,
		"https://guerrilla.barkpark.cloud": false,
		"http://89.167.28.206":             false,
		"https://api.barkpark.cloud/v1":    false,
	}
	for base, want := range cases {
		if got := isLocalTarget(base); got != want {
			t.Errorf("isLocalTarget(%q) = %v, want %v", base, got, want)
		}
	}
}

func TestRenderStatusCard(t *testing.T) {
	card := RenderStatusCard(StatusCardInfo{
		Bin:         "/usr/local/bin/bp",
		BaseURL:     "https://guerrilla.barkpark.cloud",
		Source:      "saved: guerrilla",
		Workspace:   "default",
		Project:     "default",
		Dataset:     "production",
		SchemaCount: 12,
	})
	// Every content-first line the card promises must be present: what the binary
	// is, where it points, the scope, the schema count, and the three help commands.
	for _, want := range []string{
		"headless CMS",
		"bin:      /usr/local/bin/bp",
		"server:   https://guerrilla.barkpark.cloud [saved: guerrilla]",
		"workspace=default · project=default · dataset=production",
		"schemas:  12 loaded",
		"help[1]:  `bp task ready`",
		"help[2]:  `bp doc ls <type>`",
		"help[3]:  `bp --help`",
	} {
		if !strings.Contains(card, want) {
			t.Errorf("status card missing %q:\n%s", want, card)
		}
	}
}

func TestFormatTaskCountsLine(t *testing.T) {
	// Canonical order, zero-count statuses omitted, grand total closes the line.
	got := formatTaskCountsLine(map[string]int{
		"open":        12,
		"in_progress": 3,
		"blocked":     0, // omitted (zero)
		"done":        40,
		"cancelled":   2,
	})
	want := "tasks: 12 open · 3 in_progress · 40 done · 2 cancelled  (57 total)"
	if got != want {
		t.Errorf("counts line = %q, want %q", got, want)
	}
}

func TestFormatTaskCountsLineEmptyIsBlank(t *testing.T) {
	if got := formatTaskCountsLine(nil); got != "" {
		t.Errorf("nil counts should yield empty line so the caller drops it, got %q", got)
	}
	if got := formatTaskCountsLine(map[string]int{"open": 0, "done": 0}); got != "" {
		t.Errorf("all-zero counts should yield empty line, got %q", got)
	}
}

func TestFormatTaskCountsLineSurfacesUnknownStatus(t *testing.T) {
	// A status the server introduces later must be surfaced (after the canonical
	// order), never silently dropped.
	got := formatTaskCountsLine(map[string]int{"open": 1, "archived": 5})
	if !strings.Contains(got, "5 archived") {
		t.Errorf("unknown status should still render, got %q", got)
	}
	if !strings.Contains(got, "(6 total)") {
		t.Errorf("total should include the unknown status, got %q", got)
	}
}

func TestFetchTaskCountsDecodesPrimeCounts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/tasks/prime" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		// A trimmed but shape-faithful prime envelope: counts alongside the fields
		// fetchTaskCounts must tolerate and ignore.
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"worker":null,"in_progress":[],"ready":[],"recent_events":[],"rails":{},"counts":{"open":12,"in_progress":3,"done":40}}`))
	}))
	defer srv.Close()

	counts, err := fetchTaskCounts(manifest.Context{Server: srv.URL})
	if err != nil {
		t.Fatalf("fetchTaskCounts: %v", err)
	}
	if counts["open"] != 12 || counts["in_progress"] != 3 || counts["done"] != 40 {
		t.Errorf("decoded counts = %v, want open=12 in_progress=3 done=40", counts)
	}
	// End-to-end: the wire counts render into the one honest line the bare `bp task`
	// path prints above the verb list.
	if line := formatTaskCountsLine(counts); !strings.Contains(line, "tasks: 12 open · 3 in_progress · 40 done") {
		t.Errorf("counts line from wire = %q", line)
	}
}

func TestFetchTaskCountsOfflineErrorsSoLineIsDropped(t *testing.T) {
	// Offline / unreachable target: fetchTaskCounts must return an error (not hang,
	// not panic) so the Execute path simply omits the counts line and still prints
	// usage. Point at a closed port on the loopback.
	_, err := fetchTaskCounts(manifest.Context{Server: "http://127.0.0.1:1"})
	if err == nil {
		t.Fatal("expected an error against an unreachable server, got nil")
	}
}

func TestFetchTaskCountsNon200Errors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer srv.Close()
	if _, err := fetchTaskCounts(manifest.Context{Server: srv.URL}); err == nil {
		t.Error("expected an error on a non-200 prime response")
	}
}

// --- AXI wave-2 decision 19 (Go half): bare `bp <noun>` per-noun counts line ---

// countsServer returns an httptest server that answers GET /v1/data/counts/:dataset
// with the frozen decision-19 envelope carrying the given per-type counts, and 404s
// everything else — so a test proves the client hits the exact route and shape.
func countsServer(t *testing.T, dataset string, counts map[string]int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/data/counts/"+dataset {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		payload := map[string]any{
			"ok":          true,
			"dataset":     dataset,
			"perspective": "published",
			"counts":      counts,
		}
		_ = json.NewEncoder(w).Encode(payload)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestFormatNounCountsLineRendersPresentNoun(t *testing.T) {
	counts := map[string]int{"post": 42, "page": 1, "task": 9}
	if got := formatNounCountsLine("post", counts); got != "post: 42 published documents" {
		t.Errorf("plural noun line = %q", got)
	}
	// Singular count uses the singular unit.
	if got := formatNounCountsLine("page", counts); got != "page: 1 published document" {
		t.Errorf("singular noun line = %q", got)
	}
	// A present-but-zero count still renders — "empty type" is honest info.
	if got := formatNounCountsLine("author", map[string]int{"author": 0}); got != "author: 0 published documents" {
		t.Errorf("zero-count noun line = %q", got)
	}
}

func TestFormatNounCountsLineAbsentNounIsBlank(t *testing.T) {
	// A command noun with no counts entry (`bp doc`, or a pre-counts server) yields
	// "" so the caller drops the line and prints the bare verb list unchanged.
	if got := formatNounCountsLine("doc", map[string]int{"post": 42}); got != "" {
		t.Errorf("absent noun should yield empty line, got %q", got)
	}
	if got := formatNounCountsLine("post", nil); got != "" {
		t.Errorf("nil counts should yield empty line, got %q", got)
	}
}

func TestFormatDatasetCountsLineOrdersCapsAndTotals(t *testing.T) {
	got := formatDatasetCountsLine(map[string]int{
		"post": 40, "page": 40, "author": 5, "media": 4, "tag": 3,
		"menu": 2, "redirect": 1, "block": 1, "settings": 0, // zero omitted
	})
	// Ties (post/page both 40) break by name → page before post; grand total sums
	// only non-zero types (8 of them); the list caps at datasetCountsCap (6) and
	// collapses the 2-row tail into "+2 more".
	want := "documents: 40 page · 40 post · 5 author · 4 media · 3 tag · 2 menu · +2 more  (96 total)"
	if got != want {
		t.Errorf("dataset counts line = %q, want %q", got, want)
	}
}

func TestFormatDatasetCountsLineEmptyIsBlank(t *testing.T) {
	if got := formatDatasetCountsLine(nil); got != "" {
		t.Errorf("nil counts should yield empty line, got %q", got)
	}
	if got := formatDatasetCountsLine(map[string]int{"post": 0}); got != "" {
		t.Errorf("all-zero counts should yield empty line, got %q", got)
	}
}

func TestFetchDatasetCountsDecodesFrozenShape(t *testing.T) {
	srv := countsServer(t, "production", map[string]int{"post": 42, "page": 7})
	counts, err := fetchDatasetCounts(manifest.Context{Server: srv.URL, Dataset: "production"})
	if err != nil {
		t.Fatalf("fetchDatasetCounts: %v", err)
	}
	if counts["post"] != 42 || counts["page"] != 7 {
		t.Errorf("decoded counts = %v, want post=42 page=7", counts)
	}
}

func TestFetchDatasetCountsEmptyDatasetErrors(t *testing.T) {
	// No dataset resolved → error (never a request against `/v1/data/counts/`).
	if _, err := fetchDatasetCounts(manifest.Context{Server: "http://127.0.0.1:1"}); err == nil {
		t.Error("expected an error when no dataset is resolved")
	}
}

func TestFetchDatasetCounts404Errors(t *testing.T) {
	// A pre-counts server (no data.counts route) 404s → error so the line is dropped.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer srv.Close()
	if _, err := fetchDatasetCounts(manifest.Context{Server: srv.URL, Dataset: "production"}); err == nil {
		t.Error("expected an error on a 404 counts response")
	}
}

func TestFetchDatasetCountsMalformedErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"counts":`)) // truncated JSON
	}))
	defer srv.Close()
	if _, err := fetchDatasetCounts(manifest.Context{Server: srv.URL, Dataset: "production"}); err == nil {
		t.Error("expected an error on a malformed counts body")
	}
}

func TestFetchDatasetCountsOfflineErrors(t *testing.T) {
	if _, err := fetchDatasetCounts(manifest.Context{Server: "http://127.0.0.1:1", Dataset: "production"}); err == nil {
		t.Fatal("expected an error against an unreachable server, got nil")
	}
}

// TestNounCountsLineRendersForNonTaskNoun proves criterion 2(a): a non-task noun on
// a 200 with the frozen shape renders the line end-to-end (fetch → format).
func TestNounCountsLineRendersForNonTaskNoun(t *testing.T) {
	srv := countsServer(t, "production", map[string]int{"post": 42})
	got := nounCountsLine("post", false, manifest.Context{Server: srv.URL, Dataset: "production"})
	if got != "post: 42 published documents" {
		t.Errorf("nounCountsLine = %q, want the rendered post line", got)
	}
}

// TestNounCountsLineMachineOutIsBlank proves criterion 2(c): machine output carries
// NO line even against a live 200 server — the omission is the -o json guard, not a
// fetch failure (the server here would happily answer).
func TestNounCountsLineMachineOutIsBlank(t *testing.T) {
	srv := countsServer(t, "production", map[string]int{"post": 42})
	if got := nounCountsLine("post", true, manifest.Context{Server: srv.URL, Dataset: "production"}); got != "" {
		t.Errorf("machine output must carry no counts line, got %q", got)
	}
}

// TestNounCountsLineTaskExcluded proves the `task` noun keeps its own richer
// lifecycle line: the generic per-noun line never fires for it, even on a 200.
func TestNounCountsLineTaskExcluded(t *testing.T) {
	srv := countsServer(t, "production", map[string]int{"task": 9})
	if got := nounCountsLine("task", false, manifest.Context{Server: srv.URL, Dataset: "production"}); got != "" {
		t.Errorf("task noun must be excluded from the generic line, got %q", got)
	}
}

// TestNounCountsLineSilentDegrade proves criterion 2(b): a 404 / offline / malformed
// server (or a noun with no counts entry) drops the line without error.
func TestNounCountsLineSilentDegrade(t *testing.T) {
	// Pre-counts server (404 on the route).
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer down.Close()
	if got := nounCountsLine("post", false, manifest.Context{Server: down.URL, Dataset: "production"}); got != "" {
		t.Errorf("404 server should drop the line, got %q", got)
	}
	// Offline target.
	if got := nounCountsLine("post", false, manifest.Context{Server: "http://127.0.0.1:1", Dataset: "production"}); got != "" {
		t.Errorf("offline server should drop the line, got %q", got)
	}
	// Reachable 200, but the queried noun has no counts entry → no line.
	srv := countsServer(t, "production", map[string]int{"page": 3})
	if got := nounCountsLine("post", false, manifest.Context{Server: srv.URL, Dataset: "production"}); got != "" {
		t.Errorf("noun absent from counts should drop the line, got %q", got)
	}
}

func TestRenderStatusCardShowsDocumentsLine(t *testing.T) {
	card := RenderStatusCard(StatusCardInfo{
		Bin:         "/usr/local/bin/bp",
		BaseURL:     "https://guerrilla.barkpark.cloud",
		Source:      "saved: guerrilla",
		Workspace:   "default",
		Project:     "default",
		Dataset:     "production",
		SchemaCount: 12,
		Counts:      map[string]int{"post": 42, "page": 7},
	})
	if !strings.Contains(card, "documents: 42 post · 7 page  (49 total)") {
		t.Errorf("status card missing documents line:\n%s", card)
	}
}

func TestRenderStatusCardOmitsDocumentsLineWhenNoCounts(t *testing.T) {
	// No counts (pre-counts / offline server) → the card omits the line entirely,
	// staying a complete, honest status without a bald "documents:" header.
	card := RenderStatusCard(StatusCardInfo{
		Bin:         "/usr/local/bin/bp",
		BaseURL:     "https://guerrilla.barkpark.cloud",
		SchemaCount: 12,
	})
	if strings.Contains(card, "documents:") {
		t.Errorf("status card must omit documents line with no counts:\n%s", card)
	}
}
