package setup

import (
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// statusHandler returns a handler that answers `code` for any path NOT in
// overrides, and the override code for paths that are. This lets one fake
// server simulate "capabilities 200 but websocket 403", etc.
func statusHandler(defaultCode int, overrides map[string]int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, ok := overrides[r.URL.Path]; ok {
			w.WriteHeader(c)
			return
		}
		w.WriteHeader(defaultCode)
	})
}

// allGreenOverrides is the set of per-path codes that make every BaseURL-hitting
// check pass (capabilities/postgres 200, studio 200, websocket 426 not-403).
func allGreenOverrides() map[string]int {
	return map[string]int{
		"/v1/capabilities": http.StatusOK,
		"/studio":          http.StatusOK,
		"/live/websocket":  http.StatusUpgradeRequired, // 426 — not 403
		"/w/default/p/default/v1/data/query/production/post": http.StatusOK,
	}
}

// poolFor builds a one-cert trust store from a TLS test server so its
// self-signed cert verifies under the gate's (non-skip) TLS check.
func poolFor(srv *httptest.Server) *x509.CertPool {
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	return pool
}

// --- check 3: websocket 403 is THE failure mode -----------------------------

func TestWebsocketCheck(t *testing.T) {
	cases := []struct {
		name     string
		wsStatus int
		wantPass bool
	}{
		{"403 is the check_origin/PHX_HOST drift failure", http.StatusForbidden, false},
		{"101 switching protocols passes", http.StatusSwitchingProtocols, true},
		{"426 upgrade-required passes", http.StatusUpgradeRequired, true},
		{"400 bad-preflight passes (origin accepted)", http.StatusBadRequest, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(statusHandler(http.StatusOK, map[string]int{
				"/live/websocket": tc.wsStatus,
			}))
			defer srv.Close()

			g := HealthGate{BaseURL: srv.URL}
			got := g.checkWebsocket()
			if got.Pass != tc.wantPass {
				t.Fatalf("websocket status %d: pass=%v want %v (detail: %s)",
					tc.wsStatus, got.Pass, tc.wantPass, got.Detail)
			}
			if tc.wsStatus == http.StatusForbidden && !strings.Contains(got.Detail, "403") {
				t.Fatalf("403 failure detail should name the 403; got %q", got.Detail)
			}
		})
	}
}

// The websocket check must send the exact Makefile:173 headers.
func TestWebsocketCheckSendsUpgradeHeaders(t *testing.T) {
	var gotHeaders http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeaders = r.Header.Clone()
		w.WriteHeader(http.StatusUpgradeRequired)
	}))
	defer srv.Close()

	g := HealthGate{BaseURL: srv.URL}
	if res := g.checkWebsocket(); !res.Pass {
		t.Fatalf("expected pass on 426, got fail: %s", res.Detail)
	}
	for k, want := range map[string]string{
		"Upgrade":               "websocket",
		"Connection":            "Upgrade",
		"Sec-Websocket-Key":     "test",
		"Sec-Websocket-Version": "13",
	} {
		if got := gotHeaders.Get(k); got != want {
			t.Errorf("header %s = %q, want %q", k, got, want)
		}
	}
	if o := gotHeaders.Get("Origin"); o != srv.URL {
		t.Errorf("Origin = %q, want %q", o, srv.URL)
	}
}

// --- checks 1 & 2: capabilities/studio ---------------------------------------

func TestCapabilitiesCheck(t *testing.T) {
	cases := []struct {
		code     int
		wantPass bool
	}{
		{http.StatusOK, true},
		{http.StatusInternalServerError, false},
		{http.StatusBadGateway, false},
	}
	for _, tc := range cases {
		srv := httptest.NewServer(statusHandler(tc.code, nil))
		g := HealthGate{BaseURL: srv.URL}
		if got := g.checkCapabilities(); got.Pass != tc.wantPass {
			t.Errorf("capabilities code %d: pass=%v want %v", tc.code, got.Pass, tc.wantPass)
		}
		srv.Close()
	}
}

func TestStudioCheck(t *testing.T) {
	cases := []struct {
		code     int
		wantPass bool
	}{
		{http.StatusOK, true},
		{http.StatusFound, true}, // 302 scoped-path redirect is fine
		{http.StatusInternalServerError, false},
	}
	for _, tc := range cases {
		srv := httptest.NewServer(statusHandler(http.StatusOK, map[string]int{"/studio": tc.code}))
		g := HealthGate{BaseURL: srv.URL}
		if got := g.checkStudio(); got.Pass != tc.wantPass {
			t.Errorf("studio code %d: pass=%v want %v", tc.code, got.Pass, tc.wantPass)
		}
		srv.Close()
	}
}

// --- check 4: TLS ------------------------------------------------------------

func TestTLSCheck(t *testing.T) {
	t.Run("valid cert verifies", func(t *testing.T) {
		srv := httptest.NewTLSServer(statusHandler(http.StatusOK, nil))
		defer srv.Close()
		g := HealthGate{BaseURL: srv.URL, RootCAs: poolFor(srv)}
		if got := g.checkTLS(); !got.Pass {
			t.Fatalf("expected TLS pass for trusted cert, got fail: %s", got.Detail)
		}
	})

	t.Run("untrusted cert fails", func(t *testing.T) {
		srv := httptest.NewTLSServer(statusHandler(http.StatusOK, nil))
		defer srv.Close()
		// No RootCAs injected: the self-signed test cert is NOT in the system
		// trust store, so verification must fail.
		g := HealthGate{BaseURL: srv.URL}
		got := g.checkTLS()
		if got.Pass {
			t.Fatalf("expected TLS fail for untrusted self-signed cert, got pass: %s", got.Detail)
		}
	})

	t.Run("http base URL has no TLS to verify", func(t *testing.T) {
		srv := httptest.NewServer(statusHandler(http.StatusOK, nil))
		defer srv.Close()
		g := HealthGate{BaseURL: srv.URL}
		if got := g.checkTLS(); !got.Pass {
			t.Fatalf("http base should pass TLS check (nothing to verify), got fail: %s", got.Detail)
		}
	})
}

// --- checks 5/6/7: injected probe endpoints ----------------------------------

func TestPostgresCheck(t *testing.T) {
	cases := []struct {
		code     int
		wantPass bool
	}{
		{http.StatusOK, true},
		{http.StatusInternalServerError, false},
	}
	for _, tc := range cases {
		srv := httptest.NewServer(statusHandler(tc.code, nil))
		g := HealthGate{BaseURL: srv.URL, PostgresProbeURL: srv.URL + "/query"}
		if got := g.checkPostgres(); got.Pass != tc.wantPass {
			t.Errorf("postgres probe code %d: pass=%v want %v", tc.code, got.Pass, tc.wantPass)
		}
		srv.Close()
	}
	t.Run("empty probe URL is not-ready", func(t *testing.T) {
		g := HealthGate{PostgresProbeURL: ""}
		if got := g.checkPostgres(); got.Pass {
			t.Fatalf("empty postgres probe URL must fail, got pass: %s", got.Detail)
		}
	})
}

func TestStubProbeChecks(t *testing.T) {
	cases := []struct {
		code     int
		wantPass bool
	}{
		{http.StatusOK, true},
		{http.StatusServiceUnavailable, false},
	}
	for _, tc := range cases {
		srv := httptest.NewServer(statusHandler(tc.code, nil))
		g := HealthGate{
			AgentStatusURL:  srv.URL + "/agent",
			BackupStatusURL: srv.URL + "/backup",
		}
		if got := g.checkAgentConnected(); got.Pass != tc.wantPass {
			t.Errorf("agent probe code %d: pass=%v want %v", tc.code, got.Pass, tc.wantPass)
		}
		if got := g.checkBackupScheduled(); got.Pass != tc.wantPass {
			t.Errorf("backup probe code %d: pass=%v want %v", tc.code, got.Pass, tc.wantPass)
		}
		srv.Close()
	}
	t.Run("unset stub URLs are not-ready", func(t *testing.T) {
		g := HealthGate{}
		if g.checkAgentConnected().Pass {
			t.Error("unset agent URL must fail")
		}
		if g.checkBackupScheduled().Pass {
			t.Error("unset backup URL must fail")
		}
	})
	t.Run("StubsOptional skips unset stub URLs (pass)", func(t *testing.T) {
		g := HealthGate{StubsOptional: true}
		if !g.checkAgentConnected().Pass {
			t.Error("with StubsOptional, an unset agent URL must skip-pass (v1: agent is cloud-9/10)")
		}
		if !g.checkBackupScheduled().Pass {
			t.Error("with StubsOptional, an unset backup URL must skip-pass (v1: backups are cloud-9/10)")
		}
	})
}

// --- top-level gate: all-green passes, any-red fails -------------------------

func TestRunHealthGate(t *testing.T) {
	t.Run("all checks green => OK and no error", func(t *testing.T) {
		srv := httptest.NewTLSServer(statusHandler(http.StatusOK, allGreenOverrides()))
		defer srv.Close()

		report, err := RunHealthGate(srv.URL, "tok", HealthGate{
			RootCAs:          poolFor(srv),
			PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
			AgentStatusURL:   srv.URL + "/agent",
			BackupStatusURL:  srv.URL + "/backup",
		})
		if err != nil {
			t.Fatalf("expected no error when all green, got: %v\n%s", err, report)
		}
		if !report.OK {
			t.Fatalf("expected report.OK=true, got false: %s", report)
		}
		if len(report.Checks) != 7 {
			t.Fatalf("expected exactly 7 checks, got %d", len(report.Checks))
		}
		for _, c := range report.Checks {
			if !c.Pass {
				t.Errorf("check %s should pass: %s", c.Name, c.Detail)
			}
		}
	})

	t.Run("a single 403 websocket sinks the whole gate", func(t *testing.T) {
		ov := allGreenOverrides()
		ov["/live/websocket"] = http.StatusForbidden // the footgun
		srv := httptest.NewTLSServer(statusHandler(http.StatusOK, ov))
		defer srv.Close()

		report, err := RunHealthGate(srv.URL, "tok", HealthGate{
			RootCAs:          poolFor(srv),
			PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
			AgentStatusURL:   srv.URL + "/agent",
			BackupStatusURL:  srv.URL + "/backup",
		})
		if err == nil {
			t.Fatalf("expected gate error on websocket 403, got nil\n%s", report)
		}
		if report.OK {
			t.Fatal("report.OK must be false when websocket is 403")
		}
		fails := report.Failures()
		if len(fails) != 1 || fails[0] != "websocket-not-403" {
			t.Fatalf("expected exactly the websocket-not-403 failure, got %v", fails)
		}
	})

	t.Run("StubsOptional=true still fails closed on a hard check (websocket 403)", func(t *testing.T) {
		// This is the EXACT shape the warm-pool's defaultHealthChecker uses
		// (StubsOptional:true so the unwired agent/backup stubs skip-pass). The
		// flag must ONLY relax the unwired stubs — a hard check that is genuinely
		// red (the websocket-403 footgun) must still sink the gate, or a broken box
		// would reach a customer.
		ov := allGreenOverrides()
		ov["/live/websocket"] = http.StatusForbidden // the footgun, red
		srv := httptest.NewTLSServer(statusHandler(http.StatusOK, ov))
		defer srv.Close()

		report, err := RunHealthGate(srv.URL, "tok", HealthGate{
			RootCAs:          poolFor(srv),
			PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
			StubsOptional:    true, // agent/backup unwired → skip-pass; must NOT save the gate
		})
		if err == nil {
			t.Fatalf("StubsOptional must not rescue a red websocket — expected a gate error, got nil\n%s", report)
		}
		if report.OK {
			t.Fatal("report.OK must be false: a hard websocket 403 fails closed even with StubsOptional")
		}
		fails := report.Failures()
		if len(fails) != 1 || fails[0] != "websocket-not-403" {
			t.Fatalf("expected exactly the websocket-not-403 failure (stubs skip-passed), got %v", fails)
		}
	})

	t.Run("missing stub probe URLs sink the gate", func(t *testing.T) {
		srv := httptest.NewTLSServer(statusHandler(http.StatusOK, allGreenOverrides()))
		defer srv.Close()

		// No AgentStatusURL/BackupStatusURL → checks 6/7 are not-ready.
		report, err := RunHealthGate(srv.URL, "tok", HealthGate{
			RootCAs:          poolFor(srv),
			PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
		})
		if err == nil {
			t.Fatalf("expected gate error when stub probes unset, got nil\n%s", report)
		}
		fails := report.Failures()
		if len(fails) != 2 {
			t.Fatalf("expected 2 failures (agent+backup), got %v", fails)
		}
	})
}
