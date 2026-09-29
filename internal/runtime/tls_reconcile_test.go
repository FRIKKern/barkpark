package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// THE FLIP-ON-A-LIVE-SITE GAP.
//
// Every test here drives an IDLE cycle: the control plane has no pending
// deployment, so nothing is claimed and no container is touched. That is the
// whole point — the defect is that a serving_mode flip on a site the box is
// ALREADY serving reached the box only through the next deploy's claim inline,
// so between the flip and that deploy the rendered TLS block stayed stale
// (on-demand ACME behind the Cloudflare proxy = a live 526; and, in reverse,
// `tls internal` over a now-direct hostname = a self-signed cert for every
// visitor).
//
// The assertions are on the BYTES WRITTEN to the Caddyfile and on the `caddy
// reload` subprocess — what the box actually serves — never on an internal
// call count.

// reconcileCP is a control plane that answers claim with 404 no_pending (an
// idle box) and serves GET /v1/agent/sites from a body supplied as RAW JSON.
// The body is assembled by string concatenation from the shared fixture, never
// by marshalling this package's own structs, so what these tests pin is the
// WIRE — the route, the envelope key, the field spellings.
type reconcileCP struct {
	sitesJSON  string // the `sites` array body; empty → the route 404s
	sitesCalls int
}

func (c *reconcileCP) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/agent/deployments/claim", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"no_pending"}`))
	})

	mux.HandleFunc("/v1/agent/sites", func(w http.ResponseWriter, _ *http.Request) {
		c.sitesCalls++
		if c.sitesJSON == "" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
			return
		}
		_, _ = w.Write([]byte(`{"sites":[` + c.sitesJSON + `]}`))
	})

	return mux
}

// liveBox seeds a box that is already serving `shop` on port 7001 in the given
// TLS mode, alongside a FOREIGN vhost the runtime does not manage. Returns the
// executor, its filesystem, its runner, and the State read back off disk —
// State comes from StateFromDisk, so the live-site facts travel through the
// real Caddyfile parser exactly as they do in production.
func liveBox(t *testing.T, cp *reconcileCP, tlsMode string) (*Executor, *mapFS, *fakeRunner, State) {
	t.Helper()

	srv := httptest.NewServer(cp.handler())
	t.Cleanup(srv.Close)

	seed := caddyfile.Rewrite(nil, caddyfile.Box{
		Sites: []caddyfile.Site{{
			Slug:    "shop",
			Domains: []string{"shop.example.com"},
			Port:    7001,
			TLSMode: tlsMode,
		}},
	})
	// A vhost the runtime must never rewrite away — the jarl-box outage class.
	seed = append(seed, []byte("\nstudio.example.com {\n  reverse_proxy 127.0.0.1:4000\n}\n")...)

	fs := newMapFS()
	fs.files["/etc/caddy/Caddyfile"] = seed

	runner := &fakeRunner{}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "tok",
		WorkerID:      "w1",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		FS:            fs,
		Runner:        runner,
		Ports:         &fixedPorts{next: 7002},
	}

	state, err := e.StateFromDisk(context.Background())
	if err != nil {
		t.Fatalf("StateFromDisk: %v", err)
	}
	if len(state.LiveSites) != 1 || state.LiveSites[0].Slug != "shop" {
		t.Fatalf("seeded state must hold exactly the shop site, got %+v", state.LiveSites)
	}
	return e, fs, runner, state
}

// rawSiteFixture returns one `sites_state_*` object from the shared fixture as
// the raw JSON text it is stored as.
func rawSiteFixture(t *testing.T, name string) string {
	t.Helper()
	return strings.TrimSpace(string(servingModeFixture(t, name)))
}

// caddyReloads counts `caddy reload` invocations on the fake runner.
func caddyReloads(calls []call) int {
	n := 0
	for _, c := range calls {
		if c.name == "caddy" && len(c.args) > 0 && c.args[0] == "reload" {
			n++
		}
	}
	return n
}

// TestRunOnce_IdleCycle_FlipToCFProxiedRerendersLiveSiteWithoutADeploy is THE
// RED-WITHOUT test for this change: on the unmodified executor an idle cycle
// returns the moment the claim 404s, so the Caddyfile keeps its on_demand
// block, `caddy reload` never runs, and both assertions below fail.
func TestRunOnce_IdleCycle_FlipToCFProxiedRerendersLiveSiteWithoutADeploy(t *testing.T) {
	cp := &reconcileCP{sitesJSON: rawSiteFixture(t, "sites_state_cf_proxied")}
	e, fs, runner, state := liveBox(t, cp, caddyfile.TLSModeOnDemand)

	had, err := e.RunOnce(context.Background(), state)
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if had {
		t.Fatalf("no deployment was pending; RunOnce must report an idle cycle")
	}

	got := string(fs.files["/etc/caddy/Caddyfile"])
	if !strings.Contains(got, "  tls internal\n") {
		t.Errorf("a live site flipped to cf_proxied must be re-rendered `tls internal` WITHOUT a deploy:\n%s", got)
	}
	if strings.Contains(got, "on_demand") {
		t.Errorf("the stale on-demand block must be gone (ACME behind the CF proxy is a 526):\n%s", got)
	}
	if n := caddyReloads(runner.calls); n != 1 {
		t.Errorf("a rewritten Caddyfile must be reloaded exactly once, got %d reloads", n)
	}
	// The rewrite must not touch what the runtime does not manage.
	if !strings.Contains(got, "studio.example.com {") {
		t.Errorf("reconciliation must preserve foreign vhosts:\n%s", got)
	}
	if !strings.Contains(got, "reverse_proxy 127.0.0.1:7001") {
		t.Errorf("reconciliation must keep the site pointed at its live container port:\n%s", got)
	}
}

// TestRunOnce_IdleCycle_FlipBackToDirectRestoresOnDemand is the same defect
// pointed the other way: a cf_proxied → direct flip must drop `tls internal`,
// which over a hostname that now resolves straight to the box would serve a
// self-signed cert to every visitor.
func TestRunOnce_IdleCycle_FlipBackToDirectRestoresOnDemand(t *testing.T) {
	cp := &reconcileCP{sitesJSON: rawSiteFixture(t, "sites_state_direct")}
	e, fs, runner, state := liveBox(t, cp, caddyfile.TLSModeInternal)

	if _, err := e.RunOnce(context.Background(), state); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	got := string(fs.files["/etc/caddy/Caddyfile"])
	if strings.Contains(got, "tls internal") {
		t.Errorf("a site flipped back to direct must NOT keep a self-signed block:\n%s", got)
	}
	if !strings.Contains(got, "on_demand") {
		t.Errorf("a direct site must render the on-demand cert block:\n%s", got)
	}
	if n := caddyReloads(runner.calls); n != 1 {
		t.Errorf("want exactly 1 caddy reload, got %d", n)
	}
}

// TestRunOnce_IdleCycle_NoDriftWritesNothing — the box polls every few seconds.
// A reconcile that rewrote and reloaded on every idle cycle would churn Caddy
// forever, so no-drift must be a pure read.
func TestRunOnce_IdleCycle_NoDriftWritesNothing(t *testing.T) {
	cp := &reconcileCP{sitesJSON: rawSiteFixture(t, "sites_state_direct")}
	e, fs, runner, state := liveBox(t, cp, caddyfile.TLSModeOnDemand)
	before := string(fs.files["/etc/caddy/Caddyfile"])

	for i := 0; i < 3; i++ {
		if _, err := e.RunOnce(context.Background(), state); err != nil {
			t.Fatalf("RunOnce %d: %v", i, err)
		}
	}

	if after := string(fs.files["/etc/caddy/Caddyfile"]); after != before {
		t.Errorf("an in-sync site must leave the Caddyfile byte-identical:\n--- before\n%s\n--- after\n%s", before, after)
	}
	if n := caddyReloads(runner.calls); n != 0 {
		t.Errorf("an in-sync site must never reload Caddy, got %d reloads", n)
	}
	if cp.sitesCalls != 3 {
		t.Errorf("every idle cycle must re-derive the truth (level-triggered), got %d fetches", cp.sitesCalls)
	}
}

// TestRunOnce_IdleCycle_ControlPlaneWithoutTheRouteLeavesCaddyfileAlone — an
// older control plane 404s /v1/agent/sites. An empty site list must never be
// read as "every site is direct", which would downgrade a live cf_proxied box
// to on-demand ACME on its first idle cycle after an agent upgrade.
func TestRunOnce_IdleCycle_ControlPlaneWithoutTheRouteLeavesCaddyfileAlone(t *testing.T) {
	cp := &reconcileCP{} // empty sitesJSON → the route 404s
	e, fs, runner, state := liveBox(t, cp, caddyfile.TLSModeInternal)
	before := string(fs.files["/etc/caddy/Caddyfile"])

	if _, err := e.RunOnce(context.Background(), state); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if after := string(fs.files["/etc/caddy/Caddyfile"]); after != before {
		t.Errorf("a 404 from /v1/agent/sites must change nothing:\n%s", after)
	}
	if n := caddyReloads(runner.calls); n != 0 {
		t.Errorf("want 0 reloads against a control plane without the route, got %d", n)
	}
}

// TestReconciledSites_LeavesUnlistedAndOriginCASitesUntouched pins the two
// blocks reconciliation must never move.
func TestReconciledSites_LeavesUnlistedAndOriginCASitesUntouched(t *testing.T) {
	live := []caddyfile.Site{
		{Slug: "shop", TLSMode: caddyfile.TLSModeOnDemand},
		{Slug: "blog", TLSMode: caddyfile.TLSModeOnDemand},
		{Slug: "strict", TLSMode: caddyfile.TLSModeOriginCA, CertPath: "/c.pem", KeyPath: "/k.pem"},
	}
	// `blog` is absent from the response entirely; `strict` is cf_proxied but
	// serving CF Full-Strict from on-box cert files — correct, not drift.
	modes := map[string]string{"shop": ServingModeCFProxied, "strict": ServingModeCFProxied}

	out, drifted := reconciledSites(live, modes)

	if len(drifted) != 1 || drifted[0] != "shop" {
		t.Fatalf("only the listed, non-OriginCA site may drift, got %v", drifted)
	}
	if out[0].TLSMode != caddyfile.TLSModeInternal {
		t.Errorf("shop: want internal, got %q", out[0].TLSMode)
	}
	if out[1].TLSMode != caddyfile.TLSModeOnDemand {
		t.Errorf("blog is not listed by the control plane; want it untouched, got %q", out[1].TLSMode)
	}
	if out[2].TLSMode != caddyfile.TLSModeOriginCA || out[2].CertPath != "/c.pem" {
		t.Errorf("an Origin CA site must never be downgraded to self-signed, got %+v", out[2])
	}
	// The input slice must not be mutated in place — the caller still holds it.
	if live[0].TLSMode != caddyfile.TLSModeOnDemand {
		t.Errorf("reconciledSites must not mutate its input, got %q", live[0].TLSMode)
	}
}

// TestNormalizedTLSMode_EmptyBlockIsOnDemand — a parsed block with no `tls`
// line comes back with TLSMode "". Caddy serves that on demand, so it must
// compare equal to an explicit on_demand or every idle cycle would see drift.
func TestNormalizedTLSMode_EmptyBlockIsOnDemand(t *testing.T) {
	for _, in := range []string{"", caddyfile.TLSModeOnDemand, "sideways"} {
		if got := normalizedTLSMode(in); got != caddyfile.TLSModeOnDemand {
			t.Errorf("normalizedTLSMode(%q) = %q, want %q", in, got, caddyfile.TLSModeOnDemand)
		}
	}
	if got := normalizedTLSMode(caddyfile.TLSModeInternal); got != caddyfile.TLSModeInternal {
		t.Errorf("normalizedTLSMode(internal) = %q", got)
	}
}

// TestAgentSitesFixture_PinsTheReconcileWire is the Go half of the mirror lock
// for the NEW route: these are the exact objects
// cloud/test/barkpark_cloud/web/router_agent_serving_mode_test.exs requires
// GET /v1/agent/sites to emit. Rename a key on either side and the other
// side's suite reds.
func TestAgentSitesFixture_PinsTheReconcileWire(t *testing.T) {
	for name, wantMode := range map[string]string{
		"sites_state_cf_proxied": ServingModeCFProxied,
		"sites_state_direct":     ServingModeDirect,
	} {
		var s agentSite
		if err := json.Unmarshal(servingModeFixture(t, name), &s); err != nil {
			t.Fatalf("decode %s: %v", name, err)
		}
		if s.Slug != "shop" || len(s.Domains) != 1 || s.ServingMode != wantMode {
			t.Errorf("%s decodes to %+v, want slug=shop domains=1 serving_mode=%s", name, s, wantMode)
		}
	}
}
