package cli

// hetzner_overview_test.go proves `bp cloud hetzner overview` IS the shared
// GUI/CLI infrastructure contract (epic charter, decision 4): the -o json
// output is asserted byte-for-byte against the committed golden fixture
// cloud/priv/static/__fixtures__/hetzner_overview.json — the SAME file the
// SPA harness and the Elixir proxy assert against in later waves. Run with
// UPDATE_GOLDEN=1 to regenerate the fixture after a deliberate contract
// change (and update the other surfaces' assertions with it).

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// hzOverviewFixturePath is the committed golden envelope, relative to this
// package (internal/cli → repo root → cloud/priv/static/__fixtures__).
var hzOverviewFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "hetzner_overview.json")

// hzOverviewFixtureClock is the fixed fetched_at the golden fixture carries;
// the test pins hetznerOverviewNow to it so the envelope is byte-deterministic.
var hzOverviewFixtureClock = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

// pinHzOverviewClock freezes fetched_at for one test.
func pinHzOverviewClock(t *testing.T) {
	t.Helper()
	old := hetznerOverviewNow
	hetznerOverviewNow = func() time.Time { return hzOverviewFixtureClock }
	t.Cleanup(func() { hetznerOverviewNow = old })
}

// installHzOverviewHandlers populates the fake with exactly one resource of
// each of the nine kinds — the estate the golden fixture describes. skip
// names kinds (by wire path) the caller wants to handle itself.
func installHzOverviewHandlers(t *testing.T, f *fakeHzAPI, skip ...string) {
	t.Helper()
	skipped := map[string]bool{}
	for _, s := range skip {
		skipped[s] = true
	}
	handlers := map[string]string{
		"/servers": `{"servers":[{"id":42,"name":"guerrilla","status":"running",
			"server_type":{"id":1,"name":"cax21"},
			"location":{"id":3,"name":"hel1"},
			"datacenter":{"id":4,"name":"hel1-dc2","location":{"id":3,"name":"hel1"}},
			"public_net":{"ipv4":{"ip":"192.0.2.10"}},
			"created":"2026-05-01T10:00:00Z"}]}`,
		"/volumes": `{"volumes":[{"id":7,"name":"pg-data","status":"available","size":50,
			"server":42,"location":{"id":3,"name":"hel1"},"created":"2026-05-02T09:00:00Z"}]}`,
		"/networks": `{"networks":[{"id":5,"name":"internal","ip_range":"10.0.0.0/16",
			"subnets":[],"routes":[],"servers":[42],"created":"2026-05-03T08:00:00Z"}]}`,
		"/firewalls": `{"firewalls":[{"id":9,"name":"web-ingress",
			"rules":[{"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"]}],
			"applied_to":[{"type":"server","server":{"id":42}}],"created":"2026-05-04T07:00:00Z"}]}`,
		"/load_balancers": `{"load_balancers":[{"id":3,"name":"edge-lb",
			"load_balancer_type":{"id":1,"name":"lb11"},"location":{"id":3,"name":"hel1"},
			"public_net":{"enabled":true,"ipv4":{"ip":"192.0.2.7"}},
			"algorithm":{"type":"round_robin"},"services":[],"targets":[],
			"created":"2026-05-05T06:00:00Z"}]}`,
		"/floating_ips": `{"floating_ips":[{"id":11,"name":"failover-ip","type":"ipv4",
			"ip":"192.0.2.99","server":42,"home_location":{"id":3,"name":"hel1"},
			"created":"2026-05-06T05:00:00Z"}]}`,
		"/primary_ips": `{"primary_ips":[{"id":13,"name":"guerrilla-ip","type":"ipv4",
			"ip":"192.0.2.10","assignee_id":42,"assignee_type":"server",
			"created":"2026-05-07T04:00:00Z"}]}`,
		"/zones": `{"zones":[{"id":21,"name":"barkpark.cloud","mode":"primary","status":"ok",
			"ttl":10800,"record_count":12,"created":"2026-05-08T03:00:00Z"}]}`,
		"/images": `{"images":[{"id":31,"type":"backup","status":"available",
			"description":"guerrilla nightly","created_from":{"id":42,"name":"guerrilla"},
			"created":"2026-05-09T02:00:00Z"}]}`,
	}
	for path, body := range handlers {
		if skipped[path] {
			continue
		}
		f.mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, body)
		})
	}
}

// TestHetznerOverviewGoldenFixture: the full estate, -o json, byte-equal to
// the committed contract fixture — the reference the proxy and the SPA panel
// are asserted against in later waves.
func TestHetznerOverviewGoldenFixture(t *testing.T) {
	f := newFakeHzAPI(t)
	installHzOverviewHandlers(t, f)
	pinHzOverviewClock(t)

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "overview")
	if code != exitOK {
		t.Fatalf("overview exited %d, stderr: %s", code, stderr)
	}

	// All nine kinds were actually fetched, and backups filtered server-side.
	for _, path := range []string{"/servers", "/volumes", "/networks", "/firewalls",
		"/load_balancers", "/floating_ips", "/primary_ips", "/zones", "/images"} {
		if f.count("GET", path) == 0 {
			t.Errorf("overview never listed %s", path)
		}
	}
	if req, ok := f.find("GET", "/images"); !ok || !strings.Contains(req.Query, "type=backup") {
		t.Errorf("images query = %q, want the server-side type=backup filter", req.Query)
	}

	// The envelope is internally consistent: valid RFC3339 fetched_at, one
	// count per resources key, counts matching row lengths.
	var payload struct {
		OK        bool           `json:"ok"`
		FetchedAt string         `json:"fetched_at"`
		Provider  map[string]any `json:"provider"`
		Resources map[string]any `json:"resources"`
		Counts    map[string]int `json:"counts"`
		Errors    map[string]any `json:"errors"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("overview -o json emitted invalid JSON: %v\n%s", err, stdout)
	}
	if !payload.OK {
		t.Errorf("ok = false, want true")
	}
	if _, err := time.Parse(time.RFC3339, payload.FetchedAt); err != nil {
		t.Errorf("fetched_at %q is not RFC3339: %v", payload.FetchedAt, err)
	}
	if payload.Provider["kind"] != "hetzner" || payload.Provider["label"] != "Hetzner Cloud" {
		t.Errorf("provider = %v, want kind=hetzner label=Hetzner Cloud", payload.Provider)
	}
	if payload.Errors != nil {
		t.Errorf("errors = %v, want absent on a clean fetch", payload.Errors)
	}
	if len(payload.Resources) != 9 || len(payload.Counts) != 9 {
		t.Fatalf("resources/counts carry %d/%d keys, want 9/9", len(payload.Resources), len(payload.Counts))
	}
	for key, v := range payload.Resources {
		rows, ok := v.([]any)
		if !ok {
			t.Errorf("resources.%s = %T, want an array", key, v)
			continue
		}
		if len(rows) != 1 || payload.Counts[key] != 1 {
			t.Errorf("resources.%s has %d rows, counts %d — want 1/1", key, len(rows), payload.Counts[key])
		}
		row, _ := rows[0].(map[string]any)
		for _, field := range []string{"id", "name", "status"} {
			if _, has := row[field]; !has {
				t.Errorf("resources.%s row misses the contract-minimum %q: %v", key, field, row)
			}
		}
	}

	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(hzOverviewFixturePath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(hzOverviewFixturePath, []byte(stdout), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("golden fixture updated: %s", hzOverviewFixturePath)
		return
	}

	// The contract itself: byte-for-byte the committed fixture (the clock is
	// pinned to the fixture's fetched_at, so no normalization is needed —
	// any drift in a key, a row field, or the JSON shape fails here).
	want, err := os.ReadFile(hzOverviewFixturePath)
	if err != nil {
		t.Fatalf("golden fixture missing (run UPDATE_GOLDEN=1 go test to create): %v", err)
	}
	if stdout != string(want) {
		t.Errorf("overview envelope drifted from the golden fixture %s\n--- got ---\n%s\n--- want ---\n%s",
			hzOverviewFixturePath, stdout, want)
	}
}

// TestHetznerOverviewFixtureKindFields pins the per-kind field contract as
// data: every golden row carries EXACTLY these keys. The Elixir proxy's
// reconciliation test (HetznerProxyTest) asserts the identical @kind_fields
// map against the SAME fixture, so a drift in either surface's row shape fails
// on both — this is the one-contract-two-surfaces invariant made structural.
func TestHetznerOverviewFixtureKindFields(t *testing.T) {
	want := map[string][]string{
		"servers":        {"id", "name", "status", "type", "location", "ipv4", "created"},
		"volumes":        {"id", "name", "status", "size_gb", "server_id", "location", "created"},
		"networks":       {"id", "name", "status", "ip_range", "server_count", "created"},
		"firewalls":      {"id", "name", "status", "rule_count", "applied_to_count", "created"},
		"load_balancers": {"id", "name", "status", "type", "location", "ipv4", "service_count", "target_count", "created"},
		"floating_ips":   {"id", "name", "status", "ip", "type", "server_id", "created"},
		"primary_ips":    {"id", "name", "status", "ip", "type", "assignee_id", "created"},
		"dns_zones":      {"id", "name", "status", "mode", "record_count", "created"},
		"backups":        {"id", "name", "status", "created_from", "created"},
	}

	raw, err := os.ReadFile(hzOverviewFixturePath)
	if err != nil {
		t.Fatalf("golden fixture missing: %v", err)
	}
	var fixture struct {
		Resources map[string][]map[string]any `json:"resources"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("golden fixture is invalid JSON: %v", err)
	}

	for kind, fields := range want {
		rows := fixture.Resources[kind]
		if len(rows) != 1 {
			t.Errorf("fixture.%s has %d rows, want exactly 1", kind, len(rows))
			continue
		}
		got := make(map[string]bool, len(rows[0]))
		for k := range rows[0] {
			got[k] = true
		}
		if len(got) != len(fields) {
			t.Errorf("fixture.%s has %d keys, want %d (%v)", kind, len(got), len(fields), fields)
		}
		for _, f := range fields {
			if !got[f] {
				t.Errorf("fixture.%s row misses pinned field %q", kind, f)
			}
			delete(got, f)
		}
		for extra := range got {
			t.Errorf("fixture.%s row carries un-pinned field %q", kind, extra)
		}
	}
}

// TestHetznerOverviewRejectsStrayArgs: overview takes no positionals — a typo
// like `overview servers` errors like every sibling verb instead of silently
// fetching the whole estate, and never touches the API.
func TestHetznerOverviewRejectsStrayArgs(t *testing.T) {
	f := newFakeHzAPI(t)
	installHzOverviewHandlers(t, f)

	_, stderr, code := runHzCLI(t, "table", "hetzner", "overview", "servers")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage); stderr: %s", code, exitUsage, stderr)
	}
	if !strings.Contains(stderr, `unexpected argument "servers"`) {
		t.Errorf("stderr = %q, want the stray argument named", stderr)
	}
	if f.count("GET", "/servers") != 0 {
		t.Errorf("stray-arg overview still hit the API")
	}
}

// TestHetznerOverviewPartialFailure: one kind 500s — it rides as null with an
// errors entry and count 0, the other eight stay live, ok stays true, exit 0.
func TestHetznerOverviewPartialFailure(t *testing.T) {
	f := newFakeHzAPI(t)
	installHzOverviewHandlers(t, f, "/volumes")
	f.mux.HandleFunc("GET /volumes", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 500, `{"error":{"code":"server_error","message":"volume plane exploded"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "overview")
	if code != exitOK {
		t.Fatalf("degraded overview exited %d, want 0 (partial data is still data); stderr: %s", code, stderr)
	}
	var payload struct {
		OK        bool              `json:"ok"`
		FetchedAt string            `json:"fetched_at"`
		Resources map[string]any    `json:"resources"`
		Counts    map[string]int    `json:"counts"`
		Errors    map[string]string `json:"errors"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, stdout)
	}
	if !payload.OK {
		t.Errorf("ok = false, want true while any kind loaded")
	}
	if _, err := time.Parse(time.RFC3339, payload.FetchedAt); err != nil {
		t.Errorf("fetched_at %q is not RFC3339: %v", payload.FetchedAt, err)
	}
	// The failed kind is null — distinguishable from an empty estate — with
	// the failure named; its count is 0.
	vol, has := payload.Resources["volumes"]
	if !has || vol != nil {
		t.Errorf("resources.volumes = %v (present=%v), want an explicit null", vol, has)
	}
	if msg := payload.Errors["volumes"]; !strings.Contains(msg, "volume plane exploded") {
		t.Errorf("errors.volumes = %q, want the provider's message surfaced", msg)
	}
	if payload.Counts["volumes"] != 0 {
		t.Errorf("counts.volumes = %d, want 0 for a degraded kind", payload.Counts["volumes"])
	}
	// The other kinds were not zeroed by the failure.
	if servers, _ := payload.Resources["servers"].([]any); len(servers) != 1 || payload.Counts["servers"] != 1 {
		t.Errorf("servers degraded alongside volumes: rows %v, count %d", payload.Resources["servers"], payload.Counts["servers"])
	}
	if len(payload.Resources) != 9 || len(payload.Counts) != 9 {
		t.Errorf("resources/counts carry %d/%d keys, want all 9 even when degraded", len(payload.Resources), len(payload.Counts))
	}
}

// TestHetznerOverviewAllFail: nothing loads (dead API / bad token) — that is
// a failure, not an empty estate: non-zero exit, error on stderr, no envelope
// claiming ok.
func TestHetznerOverviewAllFail(t *testing.T) {
	newFakeHzAPI(t) // no handlers: every list 404s

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "overview")
	if code == exitOK {
		t.Fatalf("overview exited 0 with every kind failed; stdout: %s", stdout)
	}
	if !strings.Contains(stderr, "overview") {
		t.Errorf("stderr = %q, want the failing command named", stderr)
	}
}

// TestHetznerOverviewTable: the human view — provider header, per-kind count
// summary (with an honest "error" for a degraded kind), then lean sections
// for the non-empty kinds only.
func TestHetznerOverviewTable(t *testing.T) {
	f := newFakeHzAPI(t)
	installHzOverviewHandlers(t, f, "/zones")
	f.mux.HandleFunc("GET /zones", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 500, `{"error":{"code":"server_error","message":"dns plane down"}}`)
	})

	stdout, stderr, code := runHzCLI(t, "table", "hetzner", "overview")
	if code != exitOK {
		t.Fatalf("overview exited %d, stderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, "hetzner — Hetzner Cloud · fetched ") {
		t.Errorf("missing the provider header:\n%s", stdout)
	}
	if !strings.Contains(stdout, "KIND") || !strings.Contains(stdout, "COUNT") {
		t.Errorf("missing the counts summary table:\n%s", stdout)
	}
	// The degraded kind is honest in the summary AND explained below it.
	for _, want := range []string{"dns_zones", "error", "! dns_zones failed: ", "dns plane down"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("table output misses %q:\n%s", want, stdout)
		}
	}
	// Live kinds render a section with their rows.
	for _, want := range []string{"SERVERS (1)", "guerrilla", "running", "VOLUMES (1)", "pg-data", "BACKUPS (1)", "guerrilla nightly"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("table output misses %q:\n%s", want, stdout)
		}
	}
	// A failed kind never renders a section header.
	if strings.Contains(stdout, "DNS_ZONES (") {
		t.Errorf("degraded dns_zones still rendered a section:\n%s", stdout)
	}
}
