package cli

import (
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
