package cli

// hetzner_instance_cmd_test.go drives `bp cloud hetzner instance …` against
// the same httptest fake of api.hetzner.cloud the other hetzner tests use,
// PLUS an httptest fake of the control plane's /v1/internal/barkparks surface.
// The decommission tests assert the DIVISION OF LABOUR: on the registry path
// the worker owns the teardown (the CLI must NOT delete the server itself);
// on the direct path the CLI does — and both end in the residue verification.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// instTestTuning makes the poll loops instant and neuters SSH + health probes
// (each test overrides the health transport as needed).
func instTestTuning(t *testing.T) *instSSHRecorder {
	t.Helper()
	oldPoll, oldMax, oldHTTP, oldSSH, oldPin := instPoll, instPollMax, instHTTP, instSSH, instHealthPin
	instPoll = time.Millisecond
	instPollMax = 5
	instHealthPin = false // health probes must hit the test's instHTTP stub
	rec := &instSSHRecorder{}
	instSSH = rec.run
	t.Cleanup(func() {
		instPoll, instPollMax, instHTTP, instSSH, instHealthPin = oldPoll, oldMax, oldHTTP, oldSSH, oldPin
	})
	t.Setenv("BARKPARK_DNS_HCLOUD_TOKEN", "") // DNS falls back to the compute fake
	t.Setenv("WORKER_TOKEN", "")              // registry only when a test opts in
	t.Setenv("BARKPARK_SSH_KEY", "test-key")  // create-from-archive requires a key
	return rec
}

// instSSHKeyLookup answers the resolveHzSSHKeys wire call for "test-key".
func instSSHKeyLookup(f *fakeHzAPI) {
	f.mux.HandleFunc("GET /ssh_keys", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"ssh_keys":[{"id":7,"name":"test-key","fingerprint":"aa:bb"}]}`)
	})
}

type instSSHRecorder struct {
	mu    sync.Mutex
	calls []string
}

func (r *instSSHRecorder) run(host, command string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, host+" :: "+command)
	return nil
}

func (r *instSSHRecorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

// instHealthOK answers the health probe (…/api/schemas) with an in-memory 200
// while passing every other instHTTP call (the control-plane fake!) through to
// the real transport.
func instHealthOK(t *testing.T) {
	t.Helper()
	old := instHTTP
	instHTTP = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if strings.HasSuffix(req.URL.Path, "/api/schemas") {
			rec := httptest.NewRecorder()
			rec.WriteHeader(http.StatusOK)
			return rec.Result(), nil
		}
		return http.DefaultTransport.RoundTrip(req)
	})}
	t.Cleanup(func() { instHTTP = old })
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

// fakeCP is the control-plane stand-in: a mutable row list + a request log.
type fakeCP struct {
	t   *testing.T
	srv *httptest.Server

	mu   sync.Mutex
	rows []cpBarkpark
	reqs []string // "METHOD path body"
}

func newFakeCP(t *testing.T, rows []cpBarkpark) *fakeCP {
	t.Helper()
	f := &fakeCP{t: t, rows: rows}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		b, _ := json.Marshal(body)
		f.reqs = append(f.reqs, r.Method+" "+r.URL.Path+" "+string(b))
		f.mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer wtok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/internal/barkparks":
			f.mu.Lock()
			payload, _ := json.Marshal(map[string]any{"barkparks": f.rows})
			f.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(payload)
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/deprovision"):
			id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/internal/barkparks/"), "/deprovision")
			detach := body["mode"] == "detach"
			f.mu.Lock()
			kept := f.rows[:0]
			var status string
			for _, row := range f.rows {
				if row.ID != id {
					kept = append(kept, row)
					continue
				}
				if detach || row.Host == "" {
					status = "removed"
				} else {
					status = "deprovisioning"
				}
			}
			f.rows = kept
			f.mu.Unlock()
			if status == "" {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":"not_found"}`))
				return
			}
			code := http.StatusOK
			if status == "deprovisioning" {
				code = http.StatusAccepted
			}
			w.WriteHeader(code)
			_, _ = fmt.Fprintf(w, `{"ok":true,"status":%q}`, status)
		case r.Method == http.MethodPost && r.URL.Path == "/v1/internal/barkparks":
			w.WriteHeader(http.StatusCreated)
			_, _ = fmt.Fprintf(w, `{"ok":true,"barkpark":{"id":"adopted-1","slug":%q,"team_id":%q}}`,
				body["slug"], body["team_id"])
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeCP) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.reqs...)
}

// instServerJSON renders one managed server for the /servers list.
func instServerJSON(id int, name, ip, fqdn string) string {
	return fmt.Sprintf(`{"id":%d,"name":%q,"status":"running",
		"public_net":{"ipv4":{"ip":%q}},
		"labels":{"barkpark-managed":"true","barkpark-fqdn":%q},
		"server_type":{"name":"cx23"},
		"location":{"name":"fsn1"}}`, id, name, ip, fqdn)
}

func TestInstanceArchiveStampsResurrectionLabels(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("POST /servers/9/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"image":{"id":777,"type":"snapshot"},"action":{"id":31,"status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success","progress":100}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "archive", "okey.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("archive exited %d, stderr: %s", code, stderr)
	}
	req, ok := f.find("POST", "/servers/9/actions/create_image")
	if !ok {
		t.Fatal("no create_image was issued")
	}
	labels, _ := req.Body["labels"].(map[string]any)
	for k, want := range map[string]string{
		instArchiveLabelKey: "true",
		"barkpark-fqdn":     "okey.barkpark.cloud",
		instArchiveTypeKey:  "cx23",
		instArchiveLocKey:   "fsn1",
	} {
		if labels[k] != want {
			t.Errorf("create_image label %s = %v, want %q", k, labels[k], want)
		}
	}
	if req.Body["type"] != "snapshot" {
		t.Errorf("create_image type = %v, want snapshot", req.Body["type"])
	}
	if f.count("GET", "/actions") == 0 {
		t.Error("archive never waited for the snapshot action")
	}
	if !strings.Contains(stdout, "777") {
		t.Errorf("receipt does not carry the image id: %s", stdout)
	}
}

func TestInstanceDecommissionViaRegistryWorkerOwnsTeardown(t *testing.T) {
	rec := instTestTuning(t)
	f := newFakeHzAPI(t)
	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-1", Slug: "okey", Host: "192.0.2.9", DNSLabel: "okey",
		URL: "https://okey.barkpark.cloud", Mode: "managed",
	}})

	var mu sync.Mutex
	tornDown := false // flips when the "worker" (the cp fake) accepted the job
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		mu.Lock()
		gone := tornDown
		mu.Unlock()
		if gone {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("POST /servers/9/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"image":{"id":777,"type":"snapshot"},"action":{"id":31,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gone := tornDown
		mu.Unlock()
		if gone {
			hzWriteJSON(w, 200, `{"rrsets":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"okey/A","name":"okey","type":"A","records":[{"value":"192.0.2.9"}]}]}`)
	})
	f.mux.HandleFunc("DELETE /servers/9", func(w http.ResponseWriter, r *http.Request) {
		t.Error("the CLI deleted the server itself — on the registry path the WORKER owns the teardown")
		hzWriteJSON(w, 200, `{"action":{"id":90,"status":"success","progress":100}}`)
	})

	// The cp fake drops the row on the deprovision POST; flip the infra state
	// with it, as the real worker would.
	base := cp.srv.Config.Handler
	cp.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/deprovision") {
			mu.Lock()
			tornDown = true
			mu.Unlock()
		}
		base.ServeHTTP(w, r)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "decommission", "okey.barkpark.cloud",
		"--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("decommission exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	if rec.count() == 0 {
		t.Error("decommission never quiesced the box before archiving")
	}
	if _, ok := f.find("POST", "/servers/9/actions/create_image"); !ok {
		t.Error("decommission never archived before tearing down")
	}
	var report map[string]any
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report is not JSON: %v: %s", err, stdout)
	}
	if report["ok"] != true {
		t.Errorf("report.ok = %v, want true (residue: %v)", report["ok"], report["residue"])
	}
	deprovisioned := false
	for _, r := range cp.requests() {
		if strings.Contains(r, "POST /v1/internal/barkparks/row-1/deprovision") {
			deprovisioned = true
			if strings.Contains(r, "detach") {
				t.Error("live row rode the detach path — it must use the worker queue")
			}
		}
	}
	if !deprovisioned {
		t.Error("the registry row was never deprovisioned")
	}
}

func TestInstanceDecommissionDirectTearsDownAndVerifies(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	var mu sync.Mutex
	deleted := false
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		mu.Lock()
		gone := deleted
		mu.Unlock()
		if gone {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("POST /servers/9/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"image":{"id":777,"type":"snapshot"},"action":{"id":31,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("DELETE /servers/9", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		deleted = true
		mu.Unlock()
		hzWriteJSON(w, 200, `{"action":{"id":90,"status":"success","progress":100}}`)
	})
	rrsetDeleted := false
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/okey/A", func(w http.ResponseWriter, r *http.Request) {
		rrsetDeleted = true
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		if rrsetDeleted {
			hzWriteJSON(w, 200, `{"rrsets":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"okey/A","name":"okey","type":"A","records":[{"value":"192.0.2.9"}]}]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success"},{"id":90,"status":"success"},{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "decommission", "okey.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("decommission exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	if _, ok := f.find("DELETE", "/servers/9"); !ok {
		t.Error("direct decommission never deleted the server")
	}
	if !rrsetDeleted {
		t.Error("direct decommission never deleted the A record")
	}
	var report map[string]any
	_ = json.Unmarshal([]byte(stdout), &report)
	if report["ok"] != true {
		t.Errorf("report.ok = %v, want true (residue: %v)", report["ok"], report["residue"])
	}
}

func TestInstanceDecommissionDetachesStaleRow(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	// The `test` row claims an IP that a DIFFERENT identity (gallerias) now
	// owns — the worker's fence would refuse, so the CLI must detach the row
	// registry-only and clean the stale A record itself.
	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-stale", Slug: "test", Host: "192.0.2.50", DNSLabel: "test",
		URL: "https://test.barkpark.cloud", Mode: "managed",
	}})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(5, "bp-gallerias-1", "192.0.2.50", "gallerias.barkpark.cloud")+`]}`)
	})
	rrsetDeleted := false
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/test/A", func(w http.ResponseWriter, r *http.Request) {
		rrsetDeleted = true
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		if rrsetDeleted {
			hzWriteJSON(w, 200, `{"rrsets":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"rrsets":[{"id":"test/A","name":"test","type":"A","records":[{"value":"192.0.2.50"}]}]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "decommission", "test.barkpark.cloud",
		"--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("decommission exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	detached := false
	for _, r := range cp.requests() {
		if strings.Contains(r, "row-stale/deprovision") && strings.Contains(r, "detach") {
			detached = true
		}
	}
	if !detached {
		t.Error("the stale row was not detached (mode detach) — the worker fence would have failed the job")
	}
	if !rrsetDeleted {
		t.Error("the stale A record was not cleaned")
	}
	// gallerias' box must be untouched.
	if _, ok := f.find("DELETE", "/servers/5"); ok {
		t.Error("decommissioning the STALE row deleted the innocent box that now owns its recycled IP")
	}
	var report map[string]any
	_ = json.Unmarshal([]byte(stdout), &report)
	if report["ok"] != true {
		t.Errorf("report.ok = %v, want true (residue: %v)", report["ok"], report["residue"])
	}
}

func TestInstanceResurrectBootsFromNewestArchive(t *testing.T) {
	instTestTuning(t)
	instHealthOK(t)
	f := newFakeHzAPI(t)
	instSSHKeyLookup(f)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[]}`)
	})
	f.mux.HandleFunc("GET /images", func(w http.ResponseWriter, r *http.Request) {
		sel := r.URL.Query().Get("label_selector")
		if !strings.Contains(sel, instArchiveLabelKey+"=true") || !strings.Contains(sel, "barkpark-fqdn=okey.barkpark.cloud") {
			t.Errorf("images label_selector = %q, want the archive + fqdn labels", sel)
		}
		hzWriteJSON(w, 200, `{"images":[
			{"id":700,"type":"snapshot","status":"available","created":"2026-07-01T10:00:00Z",
			 "labels":{"barkpark-archive":"true","barkpark-fqdn":"okey.barkpark.cloud","barkpark-server-type":"cx23","barkpark-location":"fsn1"}},
			{"id":777,"type":"snapshot","status":"available","created":"2026-07-02T10:00:00Z",
			 "labels":{"barkpark-archive":"true","barkpark-fqdn":"okey.barkpark.cloud","barkpark-server-type":"cx23","barkpark-location":"fsn1"}}
		]}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"server":{"id":10,"name":"bp-okey-r777","status":"running","public_net":{"ipv4":{"ip":"192.0.2.77"}}},
			"action":{"id":40,"status":"success","progress":100},"next_actions":[]}`)
	})
	upserted := false
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/okey/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		upserted = true
		hzWriteJSON(w, 201, `{"action":{"id":41,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":40,"status":"success"},{"id":41,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "resurrect", "okey.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("resurrect exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	req, ok := f.find("POST", "/servers")
	if !ok {
		t.Fatal("resurrect never created a server")
	}
	if req.Body["image"] != float64(777) {
		t.Errorf("resurrect booted image %v, want 777 (the NEWEST archive)", req.Body["image"])
	}
	if req.Body["server_type"] != "cx23" || req.Body["location"] != "fsn1" {
		t.Errorf("resurrect ignored the archive's placement labels: %v / %v", req.Body["server_type"], req.Body["location"])
	}
	labels, _ := req.Body["labels"].(map[string]any)
	if labels["barkpark-fqdn"] != "okey.barkpark.cloud" || labels["barkpark-managed"] != "true" {
		t.Errorf("resurrected box is not fleet-labeled: %v", labels)
	}
	if !upserted {
		t.Error("resurrect never pointed DNS at the new box")
	}
	var receipt map[string]any
	_ = json.Unmarshal([]byte(stdout), &receipt)
	if receipt["health"] != "ok" {
		t.Errorf("receipt.health = %v, want ok: %s", receipt["health"], stdout)
	}
}

func TestInstanceEjectCloneSwapsAndDetaches(t *testing.T) {
	rec := instTestTuning(t)
	instHealthOK(t)
	f := newFakeHzAPI(t)
	instSSHKeyLookup(f)
	cp := newFakeCP(t, []cpBarkpark{{
		ID: "row-gy", Slug: "gyldendal", Host: "192.0.2.23", DNSLabel: "gyldendal",
		URL: "https://gyldendal.barkpark.cloud", Mode: "managed",
	}})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(23, "bp-gyldendal-1", "192.0.2.23", "gyldendal.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("POST /servers/23/actions/create_image", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"image":{"id":800,"type":"snapshot"},"action":{"id":50,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"server":{"id":24,"name":"bp-gyldendal-r800","status":"running","public_net":{"ipv4":{"ip":"192.0.2.24"}}},
			"action":{"id":51,"status":"success","progress":100},"next_actions":[]}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/gyldendal/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":52,"status":"success","progress":100}}`)
	})
	oldDeleted := false
	f.mux.HandleFunc("DELETE /servers/23", func(w http.ResponseWriter, r *http.Request) {
		oldDeleted = true
		hzWriteJSON(w, 200, `{"action":{"id":53,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":50,"status":"success"},{"id":51,"status":"success"},{"id":52,"status":"success"},{"id":53,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "eject", "gyldendal.barkpark.cloud",
		"--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitOK {
		t.Fatalf("eject exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	if rec.count() == 0 {
		t.Error("eject never quiesced the box before the archive")
	}
	if !oldDeleted {
		t.Error("eject never destroyed the old box after the clone took over")
	}
	detached := false
	for _, r := range cp.requests() {
		if strings.Contains(r, "row-gy/deprovision") && strings.Contains(r, "detach") {
			detached = true
		}
	}
	if !detached {
		t.Error("eject did not detach the registry row (a worker-queue deprovision would kill the clone)")
	}
	if !strings.Contains(stdout, "192.0.2.24") {
		t.Errorf("receipt does not carry the clone's IP: %s", stdout)
	}
}

func TestInstanceAuditFlagsOrphansAndStaleRows(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	cp := newFakeCP(t, []cpBarkpark{
		{ID: "r1", Slug: "gyldendal", Host: "192.0.2.23", DNSLabel: "gyldendal", URL: "https://gyldendal.barkpark.cloud"},
		{ID: "r2", Slug: "livetest", Host: "192.0.2.99", DNSLabel: "livetest", URL: "https://livetest.barkpark.cloud"},
	})
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(23, "bp-gyldendal-1", "192.0.2.23", "gyldendal.barkpark.cloud")+`]}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"rrsets":[
			{"id":"gyldendal/A","name":"gyldendal","type":"A","records":[{"value":"192.0.2.23"}]},
			{"id":"test1/A","name":"test1","type":"A","records":[{"value":"192.0.2.190"}]}
		]}`)
	})
	f.mux.HandleFunc("GET /images", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"images":[]}`)
	})
	f.mux.HandleFunc("GET /primary_ips", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"primary_ips":[]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "audit",
		"--control-url", cp.srv.URL, "--worker-token", "wtok")
	if code != exitGeneric {
		t.Fatalf("audit with findings exited %d, want %d — a dirty fleet must gate; stderr: %s", code, exitGeneric, stderr)
	}
	var report struct {
		OK       bool `json:"ok"`
		Findings []struct {
			Kind string `json:"kind"`
			Who  string `json:"who"`
		} `json:"findings"`
	}
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("audit report is not JSON: %v: %s", err, stdout)
	}
	if report.OK {
		t.Error("report.ok = true for a fleet with an orphan A record and a stale row")
	}
	kinds := map[string]string{}
	for _, f := range report.Findings {
		kinds[f.Kind] = f.Who
	}
	if kinds["dns-unmatched"] == "" {
		t.Errorf("audit missed the orphan A record test1: %v", kinds)
	}
	if kinds["row-stale-host"] != "livetest" {
		t.Errorf("audit missed the stale livetest row: %v", kinds)
	}
}

func TestInstanceResurrectRefusesLiveTwin(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`]}`)
	})

	_, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "resurrect", "okey.barkpark.cloud")
	if code != exitConflict {
		t.Fatalf("resurrect over a live twin exited %d, want %d (conflict); stderr: %s", code, exitConflict, stderr)
	}
	if f.count("POST", "/servers") != 0 {
		t.Error("resurrect created a second box for a fqdn that already has one")
	}
}
