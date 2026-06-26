package cloud

// rehearsal_test.go is the cloud-13 FINISH LINE: a single Go integration test
// that drives the WHOLE local→live promise offline, end to end, against the
// all-fakes stack. Nothing here touches a real cloud, DNS zone, box, registry,
// or control plane — yet the full user flow runs green:
//
//	bp login → bp launch hetzner --name acme → bp barkparks (acme is "up")
//
// The wiring (no live anything):
//
//	┌─ fakeControlPlane (httptest.Server) ──────────────────────────────────┐
//	│  POST /v1/auth/login  → {token, team_id}                              │
//	│  POST /v1/launch      → runs the REAL WarmPool.Provision against the   │
//	│                          fakes (FakeProvider, FakeDNS, recordingRunner,│
//	│                          greenGate, FakeRegistry), stores the LiveServer│
//	│                          keyed by name, returns the barkpark JSON       │
//	│  GET  /v1/barkparks   → the stored barkparks, health "up" (Provision's  │
//	│                          gate passed and it registered)                 │
//	└───────────────────────────────────────────────────────────────────────┘
//	                          ▲ driven by the REAL internal/cloudclient ▲
//
// The test does NOT re-prove the warm-pool chain in isolation (that is
// warmpool_test.go's job). It proves the chain ran THROUGH the client round-trip
// by asserting the same fake instances the launch handler used: the provider
// popped a host + created a replacement, DNS holds the A record, the runner saw
// the Caddy steps with PHX_HOST set + the migrate step, the gate passed, the
// registry has the server, and ListBarkparks reflects it healthy. A second case
// proves the FAIL-CLOSED guarantee end to end: a RED health checker makes Launch
// surface an error and leaves barkparks WITHOUT a healthy acme.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// rehearsalChain is the set of all-fakes the launch handler provisions through —
// the test captures it so it can assert, after the client round-trip, that the
// REAL WarmPool.Provision actually fired every seam (not just that HTTP 200'd).
type rehearsalChain struct {
	pool   *Pool
	prov   *FakeProvider
	dns    *FakeDNS
	runner *recordingRunner
	reg    *FakeRegistry
}

// newRehearsalChain seeds a one-host warm pool over fresh fakes — the same wiring
// newFakeWarmPool uses, but returned as a struct the handler closes over and the
// test asserts against.
func newRehearsalChain(t *testing.T) *rehearsalChain {
	t.Helper()
	prov := NewFakeProvider()
	pool, err := SeedPool(context.Background(), prov, 1, ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"})
	if err != nil {
		t.Fatalf("SeedPool: %v", err)
	}
	return &rehearsalChain{
		pool:   pool,
		prov:   prov,
		dns:    NewFakeDNS(),
		runner: &recordingRunner{},
		reg:    NewFakeRegistry(),
	}
}

// warmPool builds the WarmPool wired to this chain's fakes, with the supplied
// health checker (green for the happy path, red for fail-closed).
func (c *rehearsalChain) warmPool(health HealthChecker) *WarmPool {
	return &WarmPool{
		Pool:     c.pool,
		DNS:      c.dns,
		Runner:   c.runner,
		Health:   health,
		Registry: c.reg,
	}
}

// fakeControlPlane is the offline stand-in for the cloud-12a control plane. It
// implements exactly the three routes the rehearsal drives, and runs the REAL
// WarmPool.Provision on launch so the local→live chain executes for real behind
// the HTTP boundary. health is injectable so one fake plane serves both the green
// and the fail-closed cases.
type fakeControlPlane struct {
	chain  *rehearsalChain
	health HealthChecker

	mu        sync.Mutex
	barkparks []cloudclient.Barkpark // stored by launch, served by /v1/barkparks
}

// newFakeControlPlane wires a control plane over a chain + a health checker.
func newFakeControlPlane(chain *rehearsalChain, health HealthChecker) *fakeControlPlane {
	return &fakeControlPlane{chain: chain, health: health}
}

// handler is the httptest.Server handler implementing the cloud-12a contract.
func (cp *fakeControlPlane) handler() http.Handler {
	mux := http.NewServeMux()

	// POST /v1/auth/login → {token, team_id}. No real auth — any credential mints
	// a deterministic session so the rest of the flow has a Bearer to carry.
	mux.HandleFunc("/v1/auth/login", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"method_not_allowed"}`, http.StatusMethodNotAllowed)
			return
		}
		writeJSON(w, http.StatusOK, cloudclient.LoginResp{Token: "sess-rehearsal", TeamID: "team-acme"})
	})

	// POST /v1/launch → run the REAL warm-pool provision for the requested name,
	// store the resulting LiveServer keyed by name, return the barkpark row. A
	// missing Bearer is a 401; a missing name is a 422 (mirrors the real plane).
	mux.HandleFunc("/v1/launch", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"method_not_allowed"}`, http.StatusMethodNotAllowed)
			return
		}
		if r.Header.Get("Authorization") != "Bearer sess-rehearsal" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		var body struct {
			Name     string `json:"name"`
			Provider string `json:"provider"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if strings.TrimSpace(body.Name) == "" {
			http.Error(w, `{"error":"name_required"}`, http.StatusUnprocessableEntity)
			return
		}

		// THE local→live move, server-side: pop a warm host and drive the whole
		// assign→secrets→dns→caddy→migrate→health→register chain against the fakes.
		spec := GoLiveSpec{
			Name:    body.Name,
			Zone:    "barkpark.cloud",
			App:     4000,
			Spec:    ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"},
			BaseURL: "http://10.0.0.1:4000", // fake health target; greenGate ignores it
		}
		wp := cp.chain.warmPool(cp.health)
		live, err := wp.Provision(r.Context(), spec)
		if err != nil {
			// Fail closed: the gate (or any chain step) refused. Surface it as the
			// control plane's launch-failed error so the client gets a clean failure
			// and the fleet never lists an unhealthy server as ready.
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "launch_failed: " + err.Error()})
			return
		}

		// Provision passed its health gate and registered → the row is healthy.
		bp := cloudclient.Barkpark{
			ID:           "bp-" + live.Name,
			Name:         live.Name,
			Slug:         live.Name,
			URL:          "https://" + live.FQDN,
			Host:         live.IP,
			Mode:         "managed",
			HealthStatus: "up",
			AgentStatus:  "unknown",
			TeamID:       "team-acme",
		}
		cp.mu.Lock()
		cp.barkparks = append(cp.barkparks, bp)
		cp.mu.Unlock()

		writeJSON(w, http.StatusOK, map[string]any{"barkpark": bp})
	})

	// GET /v1/barkparks → the stored fleet (only servers that launched green).
	mux.HandleFunc("/v1/barkparks", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer sess-rehearsal" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		cp.mu.Lock()
		list := append([]cloudclient.Barkpark(nil), cp.barkparks...)
		cp.mu.Unlock()
		writeJSON(w, http.StatusOK, map[string]any{"barkparks": list})
	})

	return mux
}

// writeJSON is the tiny JSON responder the fake plane shares across routes.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// TestRehearsal_LocalToLive_GreenEndToEnd is THE proof: the whole local→live
// promise runs offline and green. It logs in, launches "acme", lists the fleet —
// all through the REAL cloudclient against a fake control plane that runs the
// REAL WarmPool.Provision — then asserts every seam of the chain actually fired.
func TestRehearsal_LocalToLive_GreenEndToEnd(t *testing.T) {
	chain := newRehearsalChain(t)
	plane := newFakeControlPlane(chain, greenGate("http://10.0.0.1:4000"))
	srv := httptest.NewServer(plane.handler())
	defer srv.Close()

	ctx := context.Background()

	// The seeded warm host (warm-1) is what the launch will pop. Capture its IP up
	// front so we can prove DNS/registry point at exactly it.
	before, _ := chain.prov.List(ctx)
	if len(before) != 1 || before[0].Name != "warm-1" {
		t.Fatalf("pre-launch pool: want [warm-1], got %+v", before)
	}
	assignedIP := before[0].IP

	client := &cloudclient.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	// ── step 1: bp login ──────────────────────────────────────────────────────
	login, err := client.Login(ctx, "user@acme.test", "hunter2")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if login.Token == "" {
		t.Fatalf("Login returned an empty token")
	}
	client.Token = login.Token // carry the session as Bearer, like `bp login` persists it

	// ── step 2: bp launch hetzner --name acme ─────────────────────────────────
	bp, err := client.Launch(ctx, "hetzner", "acme")
	if err != nil {
		t.Fatalf("Launch: %v (the local→live chain must run green offline)", err)
	}
	if bp.Name != "acme" {
		t.Errorf("launched barkpark name = %q, want acme", bp.Name)
	}
	if bp.HealthStatus != "up" {
		t.Errorf("launched barkpark health = %q, want up", bp.HealthStatus)
	}

	// ── step 3: bp barkparks → acme is present and healthy ────────────────────
	fleet, err := client.ListBarkparks(ctx)
	if err != nil {
		t.Fatalf("ListBarkparks: %v", err)
	}
	got, ok := findBarkpark(fleet, "acme")
	if !ok {
		t.Fatalf("ListBarkparks did not include acme: %+v", fleet)
	}
	if got.HealthStatus != "up" {
		t.Errorf("acme health in fleet = %q, want up", got.HealthStatus)
	}

	// ── now prove the REAL chain ran behind the round-trip (not just HTTP 200) ──

	// (a) FakeProvider popped warm-1 AND created warm-2 as the replacement.
	after, _ := chain.prov.List(ctx)
	if len(after) != 2 {
		t.Fatalf("provider after launch: want 2 hosts (popped + replacement), got %d: %+v", len(after), after)
	}
	var sawReplacement bool
	for _, s := range after {
		if s.Name == "warm-2" {
			sawReplacement = true
		}
	}
	if !sawReplacement {
		t.Errorf("no replacement warm host (warm-2) created — pool did not stay warm: %+v", after)
	}
	if chain.pool.Len() != 1 {
		t.Errorf("pool ready count = %d after launch, want 1 (popped one, refilled one)", chain.pool.Len())
	}

	// (b) FakeDNS has an A record acme.barkpark.cloud → the popped host IP.
	values, err := chain.dns.Resolve(ctx, "acme.barkpark.cloud")
	if err != nil {
		t.Fatalf("dns.Resolve: %v", err)
	}
	if len(values) != 1 || values[0] != assignedIP {
		t.Errorf("DNS for acme.barkpark.cloud = %v, want [%s] (the popped host)", values, assignedIP)
	}

	// (c) the recording runner saw the Caddy steps with PHX_HOST set AND migrate.
	if len(chain.runner.cmds) == 0 {
		t.Fatal("no Caddy/migrate steps ran through the injected runner")
	}
	steps := chain.runner.joined()
	if !strings.Contains(steps, "PHX_HOST=acme.barkpark.cloud") {
		t.Errorf("Caddy steps did not set PHX_HOST=acme.barkpark.cloud; ran:\n%s", steps)
	}
	if !strings.Contains(steps, "PHX_SCHEME=https") {
		t.Errorf("Caddy steps did not set PHX_SCHEME=https; ran:\n%s", steps)
	}
	if !strings.Contains(steps, "ecto.migrate") {
		t.Errorf("migrate step did not run; ran:\n%s", steps)
	}

	// (d) the registry has the verified server (the health gate passed before it).
	if !chain.reg.Has("acme.barkpark.cloud") {
		t.Errorf("acme.barkpark.cloud not registered; registry=%+v", chain.reg.Registered())
	}
	if regd := chain.reg.Registered(); len(regd) != 1 {
		t.Errorf("registry: want exactly 1 server, got %d", len(regd))
	} else {
		if regd[0].IP != assignedIP {
			t.Errorf("registered IP = %q, want the popped host IP %q", regd[0].IP, assignedIP)
		}
		if regd[0].Secrets.SecretKeyBase == "" || regd[0].Secrets.AdminToken == "" {
			t.Errorf("registered server missing minted secrets: %+v", regd[0].Secrets)
		}
	}
}

// TestRehearsal_LocalToLive_FailsClosedEndToEnd proves the fail-closed guarantee
// across the WHOLE flow: with a RED health checker, Launch surfaces an error and
// the fleet never lists acme as healthy. The chain refused to register an
// unverified server, and the control plane refused to report it — fail closed,
// end to end.
func TestRehearsal_LocalToLive_FailsClosedEndToEnd(t *testing.T) {
	chain := newRehearsalChain(t)
	plane := newFakeControlPlane(chain, redGateRehearsal())
	srv := httptest.NewServer(plane.handler())
	defer srv.Close()

	ctx := context.Background()
	client := &cloudclient.Client{BaseURL: srv.URL, HTTP: srv.Client()}

	login, err := client.Login(ctx, "user@acme.test", "hunter2")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	client.Token = login.Token

	// Launch must FAIL — the health gate is red, so Provision fails closed and the
	// control plane surfaces a launch error rather than a healthy row.
	_, err = client.Launch(ctx, "hetzner", "acme")
	if err == nil {
		t.Fatal("Launch: want an error when the health gate is red, got nil (chain did not fail closed)")
	}
	if !strings.Contains(err.Error(), "health") && !strings.Contains(err.Error(), "launch_failed") {
		t.Errorf("launch error should reflect the failed health gate, got: %v", err)
	}

	// The server must NOT be registered — fail closed.
	if chain.reg.Has("acme.barkpark.cloud") {
		t.Errorf("acme.barkpark.cloud was registered despite a red gate — not fail-closed")
	}

	// And the fleet must NOT list a healthy acme.
	fleet, err := client.ListBarkparks(ctx)
	if err != nil {
		t.Fatalf("ListBarkparks: %v", err)
	}
	if got, ok := findBarkpark(fleet, "acme"); ok && got.HealthStatus == "up" {
		t.Errorf("fleet lists acme as up despite a red gate: %+v", got)
	}
}

// redGateRehearsal is the fail-path health checker: it returns a non-OK report
// AND a non-nil error, exactly as RunHealthGate does on a 403 websocket — the
// canonical fail-closed signal.
func redGateRehearsal() HealthChecker {
	return func(_ context.Context, base, _ string) (setup.HealthReport, error) {
		rep := setup.HealthReport{
			BaseURL: base,
			OK:      false,
			Checks: []setup.CheckResult{
				{Name: "capabilities", Pass: true, Detail: "ok (fake)"},
				{Name: "websocket-not-403", Pass: false, Detail: "403 — check_origin/PHX_HOST drift (fake)"},
			},
		}
		return rep, errHealthGate(rep)
	}
}

// errHealthGate mirrors RunHealthGate's error shape so the fail-path checker is
// indistinguishable from the real gate refusing.
func errHealthGate(rep setup.HealthReport) error {
	return &gateError{failures: rep.Failures()}
}

type gateError struct{ failures []string }

func (e *gateError) Error() string {
	return "health gate failed: " + strings.Join(e.failures, ", ") + " not ready"
}

// findBarkpark returns the named barkpark from a fleet listing.
func findBarkpark(list []cloudclient.Barkpark, name string) (cloudclient.Barkpark, bool) {
	for _, b := range list {
		if b.Name == name {
			return b, true
		}
	}
	return cloudclient.Barkpark{}, false
}
