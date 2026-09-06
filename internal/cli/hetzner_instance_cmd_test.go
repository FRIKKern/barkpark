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
	"sort"
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

	// forceStatus/keepRow parameterise the deprovision answer, so a test can
	// stand up the control plane that makes eject's old receipt a lie: one that
	// IGNORES the detach key, answers 200 with "deprovisioning" (a worker
	// teardown is queued) and keeps the row.
	forceStatus string
	keepRow     bool

	// adoptSilently / adoptHost parameterise the ADOPT answer the same way, so
	// a test can stand up the two control planes that make adopt's old receipt
	// a lie while answering a perfectly well-formed 201:
	//   adoptSilently — validates the payload, echoes it back, records NOTHING.
	//   adoptHost     — records the row against a DIFFERENT host (the box the
	//                   clone-swap just destroyed, say), so the dashboard drives
	//                   a machine that no longer exists.
	// Neither is detectable from the 201 body, which is why the read-back is
	// the only thing that can tell them from an adoption that worked.
	adoptSilently bool
	adoptHost     string
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
				if f.keepRow {
					kept = append(kept, row)
				}
			}
			f.rows = kept
			if status != "" && f.forceStatus != "" {
				status = f.forceStatus
			}
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
			slug, _ := body["slug"].(string)
			team, _ := body["team_id"].(string)
			host, _ := body["host"].(string)
			rawURL, _ := body["url"].(string)
			stored := host
			if f.adoptHost != "" {
				stored = f.adoptHost
			}
			if !f.adoptSilently {
				f.mu.Lock()
				f.rows = append(f.rows, cpBarkpark{
					ID: "adopted-1", Slug: slug, DNSLabel: slug, TeamID: team,
					Host: stored, URL: rawURL, Mode: "managed",
				})
				f.mu.Unlock()
			}
			// The BODY echoes the attrs it was handed either way — a lying
			// plane and an honest one are byte-identical here on purpose.
			w.WriteHeader(http.StatusCreated)
			_, _ = fmt.Fprintf(w, `{"ok":true,"barkpark":{"id":"adopted-1","slug":%q,"team_id":%q,"host":%q}}`,
				slug, team, host)
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

func TestInstanceAuditDNSZoneNotFoundHintsSeparateToken(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	t.Setenv("HCLOUD_TOKEN", "compute-secret")
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, http.StatusOK, `{"servers":[]}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, http.StatusNotFound, `{"error":{"code":"not_found","message":"Zone not found"}}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "instance", "audit")
	if code != exitNotFound {
		t.Fatalf("audit zone lookup exited %d, want %d; stderr: %s", code, exitNotFound, stderr)
	}
	for _, want := range []string{"BARKPARK_DNS_HCLOUD_TOKEN", "cloud/postfix/README.md", "Zone not found"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("audit error missing %q hint context: %s", want, stderr)
		}
	}
	if strings.Contains(stderr, "compute-secret") {
		t.Errorf("audit error exposed compute token: %s", stderr)
	}
}

func TestInstanceAuditDNSZoneNotFoundWithExplicitTokenDoesNotHint(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, http.StatusOK, `{"servers":[]}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, http.StatusNotFound, `{"error":{"code":"not_found","message":"Zone not found"}}`)
	})

	_, stderr, code := runHzCLI(t, "table", "hetzner", "instance", "audit", "--dns-token", "dns-secret")
	if code != exitNotFound {
		t.Fatalf("audit zone lookup exited %d, want %d; stderr: %s", code, exitNotFound, stderr)
	}
	for _, absent := range []string{"BARKPARK_DNS_HCLOUD_TOKEN", "cloud/postfix/README.md", "dns-secret"} {
		if strings.Contains(stderr, absent) {
			t.Errorf("audit error unexpectedly contains %q: %s", absent, stderr)
		}
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

// instJSONReceipt decodes a `-o json` receipt, so assertions read KEYS rather
// than substrings — the difference between "the id appears somewhere in the
// output" and "the receipt states this".
func instJSONReceipt(t *testing.T, stdout string) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("receipt is not json (%v): %s", err, stdout)
	}
	return payload
}

// instArchiveFake stands up the wire for one archive of bp-okey-1: the server
// list, the create_image action, and the action poll. The caller adds the
// GET /images/<id> read-back — which is the whole point: whether it is there,
// and what it says, must change the receipt.
func instArchiveFake(t *testing.T) *fakeHzAPI {
	t.Helper()
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
	return f
}

// TestInstanceArchiveObservesTheImageItCreated is the post-condition proof for
// `instance archive`: the receipt's image_id used to be a straight echo of the
// create-action response, and the action completing says the SNAPSHOT JOB
// finished, not that a restorable image exists. The three sub-cases assert that
// the receipt is built from the READ-BACK and that a disagreeing read-back
// produces a DIFFERENT receipt — which is the only thing that makes the
// confirming read worth issuing.
func TestInstanceArchiveObservesTheImageItCreated(t *testing.T) {
	confirmed := ""
	t.Run("confirmed", func(t *testing.T) {
		instTestTuning(t)
		f := instArchiveFake(t)
		f.mux.HandleFunc("GET /images/777", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"image":{"id":777,"type":"snapshot","status":"available","description":"bp archive"}}`)
		})
		stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "archive", "okey.barkpark.cloud")
		if code != exitOK {
			t.Fatalf("archive exited %d, stderr: %s", code, stderr)
		}
		if f.count("GET", "/images/777") == 0 {
			t.Fatal("archive never re-read the image it created — image_id is a create-response echo, " +
				"and the action completing does not say a restorable image exists")
		}
		got := instJSONReceipt(t, stdout)
		if got["image_status"] != "available" {
			t.Errorf("receipt image_status = %v, want the OBSERVED \"available\"", got["image_status"])
		}
		if _, ok := got["confirmation"]; ok {
			t.Errorf("a confirmed archive must not carry a confirmation key: %s", stdout)
		}
		confirmed = stdout
	})

	t.Run("unreadable image is confirmation-unavailable, not a failed verb", func(t *testing.T) {
		instTestTuning(t)
		f := instArchiveFake(t)
		f.mux.HandleFunc("GET /images/777", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 404, `{"error":{"code":"not_found","message":"image not found"}}`)
		})
		stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "archive", "okey.barkpark.cloud")
		if code != exitOK {
			t.Fatalf("archive exited %d — a failed CONFIRMING read is not a failed snapshot, stderr: %s", code, stderr)
		}
		got := instJSONReceipt(t, stdout)
		if got["confirmation"] != "unavailable" {
			t.Errorf("receipt = %s, want confirmation: unavailable when the image cannot be re-read", stdout)
		}
		if _, ok := got["image_status"]; ok {
			t.Errorf("an unconfirmed archive must not report an image_status it never observed: %s", stdout)
		}
		if stdout == confirmed {
			t.Error("the unconfirmed receipt is byte-identical to the confirmed one — the read-back changes nothing")
		}
	})

	t.Run("a non-available image is a failed archive", func(t *testing.T) {
		instTestTuning(t)
		f := instArchiveFake(t)
		f.mux.HandleFunc("GET /images/777", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"image":{"id":777,"type":"snapshot","status":"unavailable"}}`)
		})
		stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "archive", "okey.barkpark.cloud")
		if code == exitOK {
			t.Fatalf("archive exited 0 on an image reporting status \"unavailable\" — nothing can be restored "+
				"from it, and resurrect/clone-swap boot from exactly this image: %s", stdout)
		}
		if !strings.Contains(stderr+stdout, "unavailable") {
			t.Errorf("the refusal does not name the observed status: %s %s", stdout, stderr)
		}
	})
}

// TestInstanceArchiveStopReportsWhetherItQuiesced closes the receipt lie nobody
// had named: `archive --stop` degrades to a crash-consistent snapshot when the
// SSH quiesce fails, and it said so ONLY through out.info — which writer.info
// writes to stderr only when verbose. So `archive --stop -o json` emitted a
// byte-identical receipt for a cleanly-stopped Postgres and a live one.
func TestInstanceArchiveStopReportsWhetherItQuiesced(t *testing.T) {
	run := func(t *testing.T, sshErr error) (string, string, int) {
		t.Helper()
		instTestTuning(t)
		if sshErr != nil {
			instSSH = func(host, command string) error { return sshErr }
		}
		f := instArchiveFake(t)
		f.mux.HandleFunc("GET /images/777", func(w http.ResponseWriter, r *http.Request) {
			hzWriteJSON(w, 200, `{"image":{"id":777,"type":"snapshot","status":"available"}}`)
		})
		return runHzCLI(t, "json", "hetzner", "instance", "archive", "okey.barkpark.cloud", "--stop")
	}

	var clean, crashed string
	t.Run("clean stop", func(t *testing.T) {
		stdout, stderr, code := run(t, nil)
		if code != exitOK {
			t.Fatalf("archive --stop exited %d, stderr: %s", code, stderr)
		}
		if got := instJSONReceipt(t, stdout)["quiesced"]; got != true {
			t.Errorf("receipt quiesced = %v, want true after a successful stop", got)
		}
		clean = stdout
	})
	t.Run("failed stop", func(t *testing.T) {
		stdout, stderr, code := run(t, fmt.Errorf("dial tcp 192.0.2.9:22: i/o timeout"))
		if code != exitOK {
			t.Fatalf("archive --stop exited %d — an unreachable box degrades to an online snapshot, "+
				"it does not fail the verb; stderr: %s", code, stderr)
		}
		got := instJSONReceipt(t, stdout)
		if got["quiesced"] != false {
			t.Errorf("receipt quiesced = %v, want false — the snapshot is crash-consistent", got["quiesced"])
		}
		if got["quiesce_error"] == nil {
			t.Errorf("receipt does not say WHY the quiesce failed: %s", stdout)
		}
		crashed = stdout
	})
	if clean != "" && clean == crashed {
		t.Error("a cleanly-quiesced snapshot and a crash-consistent snapshot of a LIVE database emit " +
			"byte-identical receipts — the degradation is invisible to anyone not running -v")
	}
	if clean != "" && !strings.Contains(clean, `"quiesced"`) {
		t.Errorf("quiesced is optional in the receipt, so its absence reads as \"fine\": %s", clean)
	}
}

// instEjectFake stands up the compute wire for an eject of gyldendal: the
// source box, the archive, the clone, DNS, and the old box's delete.
func instEjectFake(t *testing.T) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	instSSHKeyLookup(f)
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
	f.mux.HandleFunc("GET /images/800", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"image":{"id":800,"type":"snapshot","status":"available"}}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"server":{"id":24,"name":"bp-gyldendal-r800","status":"running","public_net":{"ipv4":{"ip":"192.0.2.24"}}},
			"action":{"id":51,"status":"success","progress":100},"next_actions":[]}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/gyldendal/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":52,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("DELETE /servers/23", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"action":{"id":53,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":50,"status":"success"},{"id":51,"status":"success"},{"id":52,"status":"success"},{"id":53,"status":"success"}]}`)
	})
	return f
}

// TestInstanceEjectDetachIsConfirmedNotAssumed is the sharpest of the four,
// because eject is DESTRUCTIVE. cpFleet.Deprovision exists to return
// "removed" | "deprovisioning"; eject threw that status away and asserted
// "now standalone — the control plane no longer manages it" in PROSE on
// err == nil. A control plane that ignores the detach key answers 200 with
// "deprovisioning" and has a worker en route to delete the clone eject just
// built — and the owner reads a ✓ saying the opposite.
//
// The ruling this test pins: an unconfirmed detach is not a failed verb (the
// clone IS serving) and not a silent exit 0 either. It takes the SAME
// hzPartial / confirmation-unavailable shape runHetznerServerAction takes when
// only the confirming read fails — never a third shape.
func TestInstanceEjectDetachIsConfirmedNotAssumed(t *testing.T) {
	eject := func(t *testing.T, cp *fakeCP) (string, string, int) {
		t.Helper()
		instHealthOK(t)
		instEjectFake(t)
		return runHzCLI(t, "json", "hetzner", "instance", "eject", "gyldendal.barkpark.cloud",
			"--control-url", cp.srv.URL, "--worker-token", "wtok")
	}
	row := func() []cpBarkpark {
		return []cpBarkpark{{
			ID: "row-gy", Slug: "gyldendal", Host: "192.0.2.23", DNSLabel: "gyldendal",
			URL: "https://gyldendal.barkpark.cloud", Mode: "managed",
		}}
	}

	var confirmed string
	t.Run("confirmed detach", func(t *testing.T) {
		instTestTuning(t)
		cp := newFakeCP(t, row())
		stdout, stderr, code := eject(t, cp)
		if code != exitOK {
			t.Fatalf("eject exited %d, stderr: %s stdout: %s", code, stderr, stdout)
		}
		got := instJSONReceipt(t, stdout)
		if got["registry_detach"] != "removed" {
			t.Errorf("receipt registry_detach = %v, want the status the control plane RETURNED", got["registry_detach"])
		}
		if got["registry_row"] != "gone" {
			t.Errorf("receipt registry_row = %v — 'now standalone' is earned by re-reading cp.List(), "+
				"not by err == nil", got["registry_row"])
		}
		if got["complete"] == false {
			t.Errorf("a confirmed detach must be a ✓, not a partial: %s", stdout)
		}
		confirmed = stdout
	})

	t.Run("control plane queues a worker teardown instead of detaching", func(t *testing.T) {
		instTestTuning(t)
		cp := newFakeCP(t, row())
		cp.forceStatus = "deprovisioning" // it ignored the detach key
		cp.keepRow = true                 // …and the row survives
		stdout, stderr, code := eject(t, cp)
		if code != exitOK {
			t.Fatalf("eject exited %d — the clone IS serving, so this is not a failed verb; stderr: %s", code, stderr)
		}
		got := instJSONReceipt(t, stdout)
		if got["complete"] != false {
			t.Fatalf("eject reported a completed verb while the control plane said %q — a worker is en route to "+
				"delete the clone this eject just built: %s", "deprovisioning", stdout)
		}
		note, _ := got["note"].(string)
		if !strings.Contains(note, "deprovisioning") {
			t.Errorf("the partial does not name the status the control plane returned: %s", stdout)
		}
		if strings.Contains(note, "now standalone") {
			t.Errorf("the receipt still claims the instance is standalone: %s", stdout)
		}
		if got["confirmation"] != "unavailable" {
			t.Errorf("an unconfirmed detach must take the EXISTING confirmation-unavailable shape, not a third one: %s", stdout)
		}
		if stdout == confirmed {
			t.Error("the unconfirmed eject receipt is byte-identical to the confirmed one")
		}
	})

	t.Run("removed but the row is still there", func(t *testing.T) {
		instTestTuning(t)
		cp := newFakeCP(t, row())
		cp.keepRow = true // says "removed", keeps the row
		stdout, stderr, code := eject(t, cp)
		if code != exitOK {
			t.Fatalf("eject exited %d, stderr: %s", code, stderr)
		}
		got := instJSONReceipt(t, stdout)
		if got["complete"] != false {
			t.Fatalf("the detach reported \"removed\" but cp.List() still carries the row, and eject reported a "+
				"completed verb anyway: %s", stdout)
		}
		if note, _ := got["note"].(string); !strings.Contains(note, "row-gy") {
			t.Errorf("the partial does not name the surviving row: %s", stdout)
		}
	})
}

// ---------------------------------------------------------------------------
// resurrect + adopt: the receipt residue (pds-w27-bl-…-verb-receipt-residue)
// ---------------------------------------------------------------------------

// instHealthStub answers the /api/schemas probe with `code` and counts the
// hits, passing every other instHTTP call (the control-plane fake!) through to
// the real transport. instHealthOK is the always-200 special case; a resurrect
// receipt has to distinguish PROBED-OK from PROBED-AND-FAILED from NOT-PROBED,
// and only the third one is invisible to a stub that always succeeds.
func instHealthStub(t *testing.T, code int, hits *int) {
	t.Helper()
	old := instHTTP
	instHTTP = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if strings.HasSuffix(req.URL.Path, "/api/schemas") {
			*hits++
			rec := httptest.NewRecorder()
			rec.WriteHeader(code)
			return rec.Result(), nil
		}
		return http.DefaultTransport.RoundTrip(req)
	})}
	t.Cleanup(func() { instHTTP = old })
}

// instResurrectFake stands up the wire for one resurrect of okey.barkpark.cloud
// from archive 777. `created` is the raw `server` object POST /servers answers
// with, so a caller can decide whether the create response already settles the
// running+IPv4 poll or the GET /servers/10 read-back has to.
func instResurrectFake(t *testing.T, created string) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	instSSHKeyLookup(f)
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"servers":[]}`)
	})
	f.mux.HandleFunc("GET /images", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"images":[
			{"id":777,"type":"snapshot","status":"available","created":"2026-07-02T10:00:00Z",
			 "labels":{"barkpark-archive":"true","barkpark-fqdn":"okey.barkpark.cloud","barkpark-server-type":"cx23","barkpark-location":"fsn1"}}
		]}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"server":`+created+`,
			"action":{"id":40,"status":"success","progress":100},"next_actions":[]}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/okey/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":41,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":40,"status":"success"},{"id":41,"status":"success"}]}`)
	})
	return f
}

// instResurrectRunning is a create response that already reports running with a
// public IPv4 — the common case, where instCreateFromArchive's poll is
// satisfied on its first look and issues no GET at all.
const instResurrectRunning = `{"id":10,"name":"bp-okey-r777","status":"running",
	"public_net":{"ipv4":{"ip":"192.0.2.77"}},"image":{"id":777,"type":"snapshot"}}`

// TestInstanceResurrectReceiptStatesHealthInAllThreeModes pins the residue the
// wave-27 gate widening left standing: `--no-health` produced a receipt where
// `health` was simply ABSENT. An absent key is not a skip — it reads exactly
// like a receipt written before the key existed, and exactly like a probe that
// crashed before it could record anything. Three modes, three receipts, and the
// test asserts they are three DISTINCT strings, because a skip that renders as
// the same bytes as a pass is the whole bug.
func TestInstanceResurrectReceiptStatesHealthInAllThreeModes(t *testing.T) {
	type mode struct {
		name     string
		args     []string
		httpCode int
		wantExit int
		wantOK   bool
	}
	modes := []mode{
		{"probed ok", nil, 200, exitOK, true},
		{"declined", []string{"--no-health"}, 200, exitOK, true},
		{"probed and failed", nil, 503, exitGeneric, false},
	}
	health := map[string]string{}
	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			instTestTuning(t)
			hits := 0
			instHealthStub(t, m.httpCode, &hits)
			instResurrectFake(t, instResurrectRunning)

			args := append([]string{"json", "hetzner", "instance", "resurrect", "okey.barkpark.cloud"}, m.args...)
			stdout, stderr, code := runHzCLI(t, args[0], args[1:]...)
			if code != m.wantExit {
				t.Fatalf("resurrect %v exited %d, want %d; stderr: %s stdout: %s", m.args, code, m.wantExit, stderr, stdout)
			}
			got := instJSONReceipt(t, stdout)
			if got["ok"] != m.wantOK {
				t.Errorf("receipt ok = %v, want %v: %s", got["ok"], m.wantOK, stdout)
			}
			raw, present := got["health"]
			if !present {
				t.Fatalf("receipt carries NO health key in mode %q — silence is not a report: %s", m.name, stdout)
			}
			text, _ := raw.(string)
			if strings.TrimSpace(text) == "" {
				t.Fatalf("receipt health is empty in mode %q: %s", m.name, stdout)
			}
			health[m.name] = text

			// The probe count is the independent witness that the key is not
			// merely a different string for the same behaviour.
			wantHits := hits > 0
			if (m.args == nil) != wantHits {
				t.Errorf("mode %q probed /api/schemas %d times — the receipt and the wire disagree about whether the gate ran", m.name, hits)
			}
		})
	}
	if health["declined"] == health["probed ok"] {
		t.Errorf("a declined health gate and a passed one produce the SAME health value (%q) — "+
			"the receipt cannot tell an operator which happened", health["declined"])
	}
	if !strings.Contains(health["declined"], "skipped") || !strings.Contains(health["declined"], "no-health") {
		t.Errorf("the declined receipt says %q — it has to name the skip AND the flag that caused it", health["declined"])
	}
	if health["probed and failed"] == health["probed ok"] {
		t.Errorf("a failed health gate and a passed one produce the SAME health value (%q)", health["probed ok"])
	}
}

// TestInstanceResurrectImageIDIsReadBackNotRequested is the other half of the
// residue. `image_id` was `img.ID` — the archive the verb ASKED Hetzner to boot,
// rendered in a receipt that reads as a statement about the box that came up.
// It is right on every honest create, which is exactly why it survived: the
// only input that can tell an echo from an observation is a server that reports
// a DIFFERENT image, and no test had ever fed one in.
func TestInstanceResurrectImageIDIsReadBackNotRequested(t *testing.T) {
	instTestTuning(t)
	instHealthOK(t)
	// The create response is deliberately NOT settled (initializing, no IPv4),
	// so instCreateFromArchive must take its GET /servers/10 read-back — and
	// that read-back is where the image below comes from.
	f := instResurrectFake(t, `{"id":10,"name":"bp-okey-r777","status":"initializing","public_net":{"ipv4":{"ip":""}}}`)
	f.mux.HandleFunc("GET /servers/10", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server":{"id":10,"name":"bp-okey-r777","status":"running",
			"public_net":{"ipv4":{"ip":"192.0.2.77"}},"image":{"id":700,"type":"snapshot"}}}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "resurrect", "okey.barkpark.cloud")
	if code != exitOK {
		t.Fatalf("resurrect exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	if f.count("GET", "/servers/10") == 0 {
		t.Fatal("resurrect never re-read the server it created — this test's premise has expired")
	}
	got := instJSONReceipt(t, stdout)
	if got["image_id"] != float64(700) {
		t.Errorf("receipt image_id = %v, want 700 — the image the BOX reports, not the 777 the request named: %s",
			got["image_id"], stdout)
	}
	if got["requested_image_id"] != float64(777) {
		t.Errorf("receipt requested_image_id = %v, want 777: %s", got["requested_image_id"], stdout)
	}
	if got["image_observed"] != true {
		t.Errorf("receipt image_observed = %v, want true: %s", got["image_observed"], stdout)
	}
	dis, _ := got["image_disagreement"].(string)
	if !strings.Contains(dis, "777") || !strings.Contains(dis, "700") {
		t.Errorf("receipt image_disagreement = %q — a box that came up on an image nobody asked for must be "+
			"REPORTED, naming both ids: %s", dis, stdout)
	}
}

// instAdoptFake stands up the hetzner wire for one adopt of
// gyldendal.barkpark.cloud: the standalone box, its archive, the clone, DNS,
// and the old box's teardown.
func instAdoptFake(t *testing.T) *fakeHzAPI {
	t.Helper()
	f := newFakeHzAPI(t)
	instSSHKeyLookup(f)
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
	f.mux.HandleFunc("GET /images/800", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"image":{"id":800,"type":"snapshot","status":"available","labels":{"barkpark-server-type":"cx23","barkpark-location":"fsn1"}}}`)
	})
	f.mux.HandleFunc("POST /servers", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{
			"server":{"id":24,"name":"bp-gyldendal-r800","status":"running",
				"public_net":{"ipv4":{"ip":"192.0.2.24"}},"image":{"id":800,"type":"snapshot"}},
			"action":{"id":51,"status":"success","progress":100},"next_actions":[]}`)
	})
	f.mux.HandleFunc("POST /zones/barkpark.cloud/rrsets/gyldendal/A/actions/set_records", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 201, `{"action":{"id":52,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("DELETE /servers/23", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"action":{"id":53,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":50,"status":"success"},{"id":51,"status":"success"},{"id":52,"status":"success"},{"id":53,"status":"success"}]}`)
	})
	return f
}

// TestInstanceAdoptRegistrationIsConfirmedNotAssumed is the post-condition proof
// for adopt's REGISTRY half — the half the wave-27 exemption explicitly left
// standing. The server half was already honest (instCloneSwap health-gates the
// clone before destroying the old box); registry_id and team_id came straight
// out of cp.Adopt's 201 body, which is the control plane repeating the attrs it
// was handed. Two well-formed 201s below are lies, and neither is visible in
// that body: one records nothing at all, one records the row against a host
// this very verb has already destroyed.
func TestInstanceAdoptRegistrationIsConfirmedNotAssumed(t *testing.T) {
	run := func(t *testing.T, tune func(*fakeCP)) (string, string, int, *fakeCP) {
		t.Helper()
		instTestTuning(t)
		instHealthOK(t)
		instAdoptFake(t)
		cp := newFakeCP(t, nil)
		tune(cp)
		stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "adopt", "gyldendal.barkpark.cloud",
			"--team", "team-7", "--control-url", cp.srv.URL, "--worker-token", "wtok")
		return stdout, stderr, code, cp
	}

	confirmed := ""
	t.Run("a plane that really records the row", func(t *testing.T) {
		stdout, stderr, code, cp := run(t, func(*fakeCP) {})
		if code != exitOK {
			t.Fatalf("adopt exited %d, stderr: %s stdout: %s", code, stderr, stdout)
		}
		reads := 0
		for _, r := range cp.requests() {
			if strings.HasPrefix(r, "GET /v1/internal/barkparks") {
				reads++
			}
		}
		if reads == 0 {
			t.Fatal("adopt never re-read the registry — registry_id is a 201-body echo, and a 201 says the payload " +
				"parsed, not that a row exists")
		}
		got := instJSONReceipt(t, stdout)
		if got["registry_id"] != "adopted-1" || got["team_id"] != "team-7" {
			t.Errorf("receipt registry_id/team_id = %v/%v, want adopted-1/team-7: %s", got["registry_id"], got["team_id"], stdout)
		}
		if got["registry_host"] != "192.0.2.24" {
			t.Errorf("receipt registry_host = %v, want the clone's 192.0.2.24: %s", got["registry_host"], stdout)
		}
		if _, unconfirmed := got["confirmation"]; unconfirmed {
			t.Errorf("a confirmed adoption must not carry a confirmation key: %s", stdout)
		}
		confirmed = stdout
	})

	t.Run("a plane that 201s and records nothing", func(t *testing.T) {
		stdout, stderr, code, _ := run(t, func(cp *fakeCP) { cp.adoptSilently = true })
		if code != exitOK {
			t.Fatalf("adopt exited %d — the clone IS serving, so an unconfirmed REGISTRATION is not a failed verb; stderr: %s", code, stderr)
		}
		got := instJSONReceipt(t, stdout)
		if got["confirmation"] != "unavailable" || got["complete"] != false {
			t.Errorf("receipt = %s, want confirmation: unavailable and complete: false when the row is not in the registry", stdout)
		}
		if _, claimed := got["registry_id"]; claimed {
			t.Errorf("an unconfirmed adoption reports a registry_id it never read back: %s", stdout)
		}
		note, _ := got["note"].(string)
		if !strings.Contains(note, "adopted-1") || !strings.Contains(note, "does not carry it") {
			t.Errorf("the note does not name the row the plane claimed: %q", note)
		}
		if stdout == confirmed {
			t.Error("the unconfirmed receipt is byte-identical to the confirmed one — the read-back changes nothing")
		}
	})

	t.Run("a plane that records the row against the wrong host", func(t *testing.T) {
		// 192.0.2.23 is the OLD box — the one instCloneSwap just destroyed.
		stdout, stderr, code, _ := run(t, func(cp *fakeCP) { cp.adoptHost = "192.0.2.23" })
		if code != exitOK {
			t.Fatalf("adopt exited %d, stderr: %s", code, stderr)
		}
		got := instJSONReceipt(t, stdout)
		if got["confirmation"] != "unavailable" || got["complete"] != false {
			t.Errorf("receipt = %s, want an unconfirmed adoption when the row's host is not the clone's", stdout)
		}
		note, _ := got["note"].(string)
		if !strings.Contains(note, "192.0.2.23") || !strings.Contains(note, "192.0.2.24") {
			t.Errorf("the note does not name BOTH the host the registry holds and the clone's: %q", note)
		}
		if stdout == confirmed {
			t.Error("a row pointing at a destroyed box produces the same receipt as a correct adoption")
		}
	})
}

// task-688ebffc4b0aa50a — THE BY-NAME TRAP, ported to the instance teardown.
//
// `instance decommission` deleted the A rrset for the fqdn's FIRST LABEL only
// and then verified the same single name, so a sibling rrset at the SAME box IP
// — the go-live `<slug>-<teamid>` record `provision_support`/go-live publishes,
// or an attached custom domain the claim payload never mentions — survived the
// teardown while the receipt printed "no residue" and exited zero. That is the
// exact failure `bp cloud support remove` was fixed out of (stepDNS's by-VALUE
// sweep, PDF-D101) and the exact failure this row names: "not by deleting the
// row-URL's first label, which would remove `<name>` and leave `<name>-<teamid>`
// while still reporting delta zero."
//
// The zone here holds THREE A rrsets: the platform name, its go-live sibling at
// the same address, and a bystander at a DIFFERENT address. A correct teardown
// takes the first two and leaves the third standing — the by-value sweep must be
// wide enough to catch the sibling and narrow enough to spare the stranger.
func TestInstanceDecommissionSweepsSiblingAtSameIPBystanderSurvives(t *testing.T) {
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

	// The live zone, mutated by the DELETEs the run issues — so the verify leg
	// re-reads what the teardown actually left behind, never a canned answer.
	zone := map[string]string{
		"okey":          "192.0.2.9",
		"okey-506f035e": "192.0.2.9",
		"bystander":     "192.0.2.77",
	}
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/{name}/A", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		delete(zone, r.PathValue("name"))
		mu.Unlock()
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		names := make([]string, 0, len(zone))
		for n := range zone {
			names = append(names, n)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, n := range names {
			parts = append(parts, `{"id":"`+n+`/A","name":"`+n+`","type":"A","records":[{"value":"`+zone[n]+`"}]}`)
		}
		mu.Unlock()
		hzWriteJSON(w, 200, `{"rrsets":[`+strings.Join(parts, ",")+`]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success"},{"id":90,"status":"success"},{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "decommission", "okey.barkpark.cloud")

	mu.Lock()
	_, platformLeft := zone["okey"]
	_, siblingLeft := zone["okey-506f035e"]
	_, bystanderLeft := zone["bystander"]
	mu.Unlock()

	if platformLeft {
		t.Error("the platform A record okey.barkpark.cloud survived the teardown")
	}
	if siblingLeft {
		t.Error("the go-live sibling okey-506f035e.barkpark.cloud survived the teardown at the released box IP — a by-name delete left it standing (task-688ebffc4b0aa50a)")
	}
	if !bystanderLeft {
		t.Error("the by-value sweep took bystander.barkpark.cloud, which sits at a DIFFERENT address — the sweep is too wide")
	}
	if code != exitOK {
		t.Fatalf("decommission exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
	var report map[string]any
	_ = json.Unmarshal([]byte(stdout), &report)
	if report["ok"] != true {
		t.Errorf("report.ok = %v, want true (residue: %v)", report["ok"], report["residue"])
	}
}

// task-688ebffc4b0aa50a — THE DEGRADED ARM, and the only test that reaches the
// verify leg on its own. When another MANAGED box sits on the same address under
// a different identity label, the by-value sweep would take that co-tenant's live
// A record down with ours, so the teardown degrades to the by-name delete
// (cloud.WarmPool.DeprovisionByIP's `exclusiveIP` law, ported). The sibling then
// legitimately survives — and the point of this row is that the run must SAY SO:
// the by-value verify names it and the exit is non-zero, instead of the by-name
// verify reading "no residue" over a record that is still live.
func TestInstanceDecommissionSharedIPDegradesToByNameAndReportsResidue(t *testing.T) {
	instTestTuning(t)
	f := newFakeHzAPI(t)

	var mu sync.Mutex
	deleted := false
	// TWO managed boxes at 192.0.2.9: ours, and a stranger under a different
	// barkpark-fqdn label. Only ours is ever deleted (the fqdn fence).
	coTenant := instServerJSON(11, "bp-stranger-1", "192.0.2.9", "stranger.barkpark.cloud")
	f.mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("name") != "" {
			hzWriteJSON(w, 200, `{"servers":[]}`)
			return
		}
		mu.Lock()
		gone := deleted
		mu.Unlock()
		if gone {
			hzWriteJSON(w, 200, `{"servers":[`+coTenant+`]}`)
			return
		}
		hzWriteJSON(w, 200, `{"servers":[`+instServerJSON(9, "bp-okey-1", "192.0.2.9", "okey.barkpark.cloud")+`,`+coTenant+`]}`)
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

	zone := map[string]string{"okey": "192.0.2.9", "stranger": "192.0.2.9"}
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/{name}/A", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		delete(zone, r.PathValue("name"))
		mu.Unlock()
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		names := make([]string, 0, len(zone))
		for n := range zone {
			names = append(names, n)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, n := range names {
			parts = append(parts, `{"id":"`+n+`/A","name":"`+n+`","type":"A","records":[{"value":"`+zone[n]+`"}]}`)
		}
		mu.Unlock()
		hzWriteJSON(w, 200, `{"rrsets":[`+strings.Join(parts, ",")+`]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success"},{"id":90,"status":"success"},{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "decommission", "okey.barkpark.cloud")

	mu.Lock()
	_, strangerLeft := zone["stranger"]
	mu.Unlock()
	if !strangerLeft {
		t.Fatal("the co-tenant's live A record was swept — the exclusivity fence did not hold")
	}
	if code == exitOK {
		t.Errorf("decommission exited 0 with a record still live at the released address — the by-value verify read clean (stdout: %s)", stdout)
	}
	var report map[string]any
	_ = json.Unmarshal([]byte(stdout), &report)
	if report["ok"] != false {
		t.Errorf("report.ok = %v, want false", report["ok"])
	}
	residue := fmt.Sprint(report["residue"])
	if !strings.Contains(residue, "stranger.barkpark.cloud") {
		t.Errorf("residue does not name the surviving record: %s", residue)
	}
	if !strings.Contains(stderr, "shared with another managed box") {
		t.Errorf("the degraded sweep was not narrated on stderr:\n%s", stderr)
	}
}

// task-688ebffc4b0aa50a — THE NARROWING GUARD. The by-value sweep must never
// REPLACE the by-name delete: a platform A record whose value has drifted off
// the box IP (hand-repointed, or a stale row) is invisible to a value match, so
// a sweep-only teardown would be NARROWER than the by-name one it replaces and
// would leave the instance's own name resolving after its box is gone. Both
// fire, always.
func TestInstanceDecommissionStillDeletesPlatformRecordWhenValueDrifted(t *testing.T) {
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

	// The platform record points at a DIFFERENT address than the box it names —
	// a by-value sweep at 192.0.2.9 can never see it.
	zone := map[string]string{"okey": "203.0.113.4"}
	f.mux.HandleFunc("DELETE /zones/barkpark.cloud/rrsets/{name}/A", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		delete(zone, r.PathValue("name"))
		mu.Unlock()
		hzWriteJSON(w, 200, `{"action":{"id":91,"status":"success","progress":100}}`)
	})
	f.mux.HandleFunc("GET /zones/barkpark.cloud/rrsets", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		names := make([]string, 0, len(zone))
		for n := range zone {
			names = append(names, n)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, n := range names {
			parts = append(parts, `{"id":"`+n+`/A","name":"`+n+`","type":"A","records":[{"value":"`+zone[n]+`"}]}`)
		}
		mu.Unlock()
		hzWriteJSON(w, 200, `{"rrsets":[`+strings.Join(parts, ",")+`]}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":31,"status":"success"},{"id":90,"status":"success"},{"id":91,"status":"success"}]}`)
	})

	stdout, stderr, code := runHzCLI(t, "json", "hetzner", "instance", "decommission", "okey.barkpark.cloud")

	mu.Lock()
	_, platformLeft := zone["okey"]
	mu.Unlock()
	if platformLeft {
		t.Error("the platform A record survived because its value had drifted off the box IP — the by-value sweep REPLACED the by-name delete instead of adding to it")
	}
	if code != exitOK {
		t.Fatalf("decommission exited %d, stderr: %s stdout: %s", code, stderr, stdout)
	}
}
