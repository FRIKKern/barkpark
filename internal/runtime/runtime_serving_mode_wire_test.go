package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// cf-agent-sites-tls-channel — THE BOX HALF OF THE CP→BOX TLS CHANNEL.
//
// TestRunOnce_CFProxiedServingMode_RendersInternalTLS (runtime_test.go) proves
// the DERIVATION: given an InlineSite value whose ServingMode is cf_proxied,
// the rendered Caddyfile says `tls internal`. It builds that value as a Go
// struct, so it says nothing about the JSON key the control plane actually
// sends — a rename of the `serving_mode` tag would leave it green while every
// real box fell back to on-demand ACME and served a 526 behind Cloudflare.
//
// These tests close that gap. They serve the control plane's payload as RAW
// JSON — read from the shared fixture
// internal/runtime/testdata/agent_claim_site_payload.json — so what is proven
// is the WIRE: the key, its spelling, and the value vocabulary.
//
// ## The mirror lock
//
// The same fixture is asserted from the other side by
// cloud/test/barkpark_cloud/web/router_agent_serving_mode_test.exs, which
// requires the control plane's claim/pending serializer to emit these exact
// objects. One definition, two readers: rename the key or change the
// vocabulary on either surface and the other surface's suite reds.

// servingModeFixture returns one named `site` object from the shared fixture,
// as raw JSON, exactly as it sits in the file.
func servingModeFixture(t *testing.T, name string) json.RawMessage {
	t.Helper()
	path := filepath.Join("testdata", "agent_claim_site_payload.json")
	buf, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture %s: %v", path, err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(buf, &doc); err != nil {
		t.Fatalf("parse shared fixture %s: %v", path, err)
	}
	raw, ok := doc[name]
	if !ok {
		t.Fatalf("shared fixture %s has no %q entry", path, name)
	}
	return raw
}

// rawClaimCP is a control plane that answers ONE claim with a body assembled by
// string concatenation — never by marshalling this package's own structs, which
// would make the test a round-trip of its own tags rather than a wire contract.
type rawClaimCP struct {
	siteJSON json.RawMessage
	served   bool
}

func (c *rawClaimCP) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/agent/deployments/claim", func(w http.ResponseWriter, r *http.Request) {
		if c.served {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"no_pending"}`))
			return
		}
		c.served = true
		body := fmt.Sprintf(`{"deployment":{"id":"d-12345678abcdef","site_id":"s-aabbccdd",`+
			`"status":"pushing","image_tag":"site-shop-d-12345678","environment":"production",`+
			`"branch":"main","site":%s},"observed_epoch":1}`, string(c.siteJSON))
		_, _ = w.Write([]byte(body))
	})

	mux.HandleFunc("/v1/agent/sites/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not_found"}`))
	})

	mux.HandleFunc("/v1/agent/deployments/", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/transition") {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"deployment":{"status":"live"}}`))
	})

	return mux
}

// renderFromWire walks one real claim→live cycle against a control plane that
// answers with the named fixture object verbatim, and returns the Caddyfile the
// executor wrote.
func renderFromWire(t *testing.T, fixtureName string) string {
	t.Helper()

	cp := &rawClaimCP{siteJSON: servingModeFixture(t, fixtureName)}

	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	fs := newMapFS()
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		AskGateURL:    "https://cloud.barkpark.cloud/v1/tls/ask",
		HTTPClient:    srv.Client(),
		Runner:        &fakeRunner{},
		FS:            fs,
		Ports:         &fixedPorts{next: mustPort(t, containerSrv.URL)},
		HealthTimeout: 2 * time.Second,
	}
	if _, err := e.RunOnce(context.Background(), State{}); err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	caddy, ok := fs.files["/etc/caddy/Caddyfile"]
	if !ok {
		t.Fatal("Caddyfile was not written")
	}
	return string(caddy)
}

func TestClaimWire_ServingModeDecodesFromTheControlPlaneKey(t *testing.T) {
	// The decode step alone, before any rendering: the control plane's
	// `serving_mode` key must land on InlineSite.ServingMode. This is the
	// assertion a tag rename breaks.
	var site InlineSite
	if err := json.Unmarshal(servingModeFixture(t, "cf_proxied"), &site); err != nil {
		t.Fatalf("decode cf_proxied site: %v", err)
	}
	if site.ServingMode != ServingModeCFProxied {
		t.Errorf("ServingMode = %q, want %q — the control plane's `serving_mode` key did not reach the field",
			site.ServingMode, ServingModeCFProxied)
	}
	if site.Slug != "shop" {
		t.Errorf("Slug = %q, want %q (fixture drifted)", site.Slug, "shop")
	}

	var direct InlineSite
	if err := json.Unmarshal(servingModeFixture(t, "direct"), &direct); err != nil {
		t.Fatalf("decode direct site: %v", err)
	}
	if direct.ServingMode != ServingModeDirect {
		t.Errorf("ServingMode = %q, want %q", direct.ServingMode, ServingModeDirect)
	}

	// The pre-change control plane sends no such key at all.
	var legacy InlineSite
	if err := json.Unmarshal(servingModeFixture(t, "legacy_control_plane"), &legacy); err != nil {
		t.Fatalf("decode legacy site: %v", err)
	}
	if legacy.ServingMode != "" {
		t.Errorf("ServingMode = %q, want the zero value — the legacy fixture must carry no serving_mode",
			legacy.ServingMode)
	}
}

func TestClaimWire_CFProxiedFromTheWireRendersInternalTLS(t *testing.T) {
	// End to end from the raw control-plane body: a cf_proxied site must render
	// `tls internal` and must NEVER emit an on_demand cert block — behind the
	// Cloudflare proxy the ACME challenge cannot complete, and the origin
	// answers 526.
	caddy := renderFromWire(t, "cf_proxied")
	if !strings.Contains(caddy, "  tls internal\n") {
		t.Errorf("a cf_proxied claim must render `tls internal`:\n%s", caddy)
	}
	if strings.Contains(caddy, "  tls {\n    on_demand\n  }") {
		t.Errorf("a cf_proxied claim must NOT emit an on_demand cert block (526 outage):\n%s", caddy)
	}
	if !strings.Contains(caddy, "shop.example.com") {
		t.Errorf("the site's domain did not survive the wire:\n%s", caddy)
	}
}

func TestClaimWire_DirectAndLegacyKeepOnDemand(t *testing.T) {
	// `direct` is the explicit standalone mode; `legacy_control_plane` is a
	// control plane that sends no serving_mode at all. Both must keep today's
	// on-demand block — the pre-Cloudflare behaviour, untouched — and neither
	// may render a self-signed origin.
	for _, name := range []string{"direct", "legacy_control_plane"} {
		caddy := renderFromWire(t, name)
		if !strings.Contains(caddy, "  tls {\n    on_demand\n  }\n") {
			t.Errorf("%s must keep the on_demand site block:\n%s", name, caddy)
		}
		if strings.Contains(caddy, "tls internal") {
			t.Errorf("%s must NOT render tls internal:\n%s", name, caddy)
		}
		if strings.Contains(caddy, "trusted_proxies") {
			t.Errorf("%s is not CF-fronted and must not emit trusted_proxies:\n%s", name, caddy)
		}
	}
}
