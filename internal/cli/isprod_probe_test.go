package cli

// Red-without-fix probe for onb-backlog-isprod-custom-host-write-confirm.
//
// The wave-4 verifier ran exactly these probes against pre-fix main and proved
// the hole: isProd("https://api.acme-cms.com", server name "guerrilla") was
// FALSE and isProdServer("https://api.acme-cms.com") was FALSE — a custom-host
// production instance (cms.gyldendal.no is the live example) skipped the
// destructive-write confirm entirely, and live-fleet probes showed every host
// emits the generic server.name "barkpark", so the name leg caught no real
// prod either. This file is that probe with its assertions INVERTED: on any
// tree where the fail-closed flip regresses, these tests go red again.
//
// Deliberately a separate file from cli_test.go (owned by the command-
// discovery slice this wave).

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The verifier's probe case, inverted: a custom production hostname with a
// non-prod-named manifest MUST be treated as prod (fail closed).
func TestIsProdFailsClosedOnCustomHost(t *testing.T) {
	ctx := manifest.Context{Server: "https://api.acme-cms.com"}
	m := &manifest.Manifest{Server: manifest.Server{Name: "guerrilla", BaseURL: "https://api.acme-cms.com"}}
	if !isProd(ctx, m) {
		t.Errorf("isProd(custom host, name guerrilla) = false — custom-host prod skips the write confirm (fail-open regression)")
	}

	// Generic fleet identity: every live host emits server.name "barkpark", so
	// the name leg must not be what saves us.
	m2 := &manifest.Manifest{Server: manifest.Server{Name: "barkpark", BaseURL: "https://cms.gyldendal.no"}}
	if !isProd(manifest.Context{Server: "https://cms.gyldendal.no"}, m2) {
		t.Errorf("isProd(cms.gyldendal.no, name barkpark) = false — the live-fleet shape fails open")
	}
}

// seed_cmd.go passes an EMPTY manifest (its Server.Name leg is dead), so the
// URL heuristic alone must still fail closed there.
func TestIsProdFailsClosedWithEmptyManifest(t *testing.T) {
	if !isProd(manifest.Context{Server: "https://cms.gyldendal.no"}, &manifest.Manifest{}) {
		t.Errorf("isProd(custom host, empty manifest) = false — the seed path fails open")
	}
}

// Local targets stay unprompted: the flip must not tax local development.
func TestIsProdLocalTargetsStayUnprompted(t *testing.T) {
	for _, server := range []string{
		"http://localhost:4000",
		"http://127.0.0.1:4000",
		"http://0.0.0.0:4000",
	} {
		if isProd(manifest.Context{Server: server}, &manifest.Manifest{}) {
			t.Errorf("isProd(%s) = true — local target must stay unprompted", server)
		}
	}
}

// An explicitly prod-named manifest stays prod regardless of URL.
func TestIsProdNamedProdStaysProd(t *testing.T) {
	m := &manifest.Manifest{Server: manifest.Server{Name: "production"}}
	if !isProd(manifest.Context{Server: "https://anything.example"}, m) {
		t.Errorf("isProd(name production) = false")
	}
}

// isProdServer is isProd's hand-copied twin on the builtin write path — the
// verifier proved it carried the identical hole. Inverted alongside.
func TestIsProdServerFailsClosedOnCustomHost(t *testing.T) {
	if !isProdServer("https://api.acme-cms.com") {
		t.Errorf("isProdServer(custom host) = false — bp task create fails open on custom-host prod")
	}
	if !isProdServer("https://api.barkpark.cloud") {
		t.Errorf("isProdServer(api.barkpark.cloud) = false")
	}
	for _, server := range []string{
		"http://localhost:4000",
		"http://127.0.0.1:4000",
		"http://0.0.0.0:4000",
	} {
		if isProdServer(server) {
			t.Errorf("isProdServer(%s) = true — local target must stay unprompted", server)
		}
	}
}

// --- /v1/meta production signal (the tolerant opt-out) -----------------------

func metaStub(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/meta" {
			t.Errorf("unexpected path %s (want /v1/meta)", r.URL.Path)
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// production:false is the ONE signal that may skip the confirm.
func TestServerDeclaredNonProdTrueOnlyOnExplicitFalse(t *testing.T) {
	srv := metaStub(t, 200, `{"serverTime":"2026-08-17T00:00:00Z","production":false}`)
	if !serverDeclaredNonProd(srv.URL) {
		t.Errorf("serverDeclaredNonProd(production:false) = false — the opt-out is dead")
	}
}

// Everything else keeps the guard: true, absent (old server), non-2xx,
// unparseable, unreachable — all fail closed.
func TestServerDeclaredNonProdFailsClosed(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"production true", 200, `{"production":true}`},
		{"field absent (old server)", 200, `{"serverTime":"2026-08-17T00:00:00Z"}`},
		{"non-2xx", 503, `{"production":false}`},
		{"unparseable body", 200, `not json`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := metaStub(t, tc.status, tc.body)
			if serverDeclaredNonProd(srv.URL) {
				t.Errorf("serverDeclaredNonProd(%s) = true — must fail closed", tc.name)
			}
		})
	}

	t.Run("unreachable", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		url := srv.URL
		srv.Close()
		if serverDeclaredNonProd(url) {
			t.Errorf("serverDeclaredNonProd(unreachable) = true — must fail closed")
		}
	})
}
