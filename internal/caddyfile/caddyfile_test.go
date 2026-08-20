package caddyfile

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRender_EmptyBox(t *testing.T) {
	got := Render(Box{})
	if got != "" {
		t.Errorf("empty Box should render empty string, got %q", got)
	}
}

func TestRender_GlobalAskGate(t *testing.T) {
	got := Render(Box{AskGateURL: "https://cloud.barkpark.cloud/v1/tls/ask"})
	want := "{\n  on_demand_tls {\n    ask https://cloud.barkpark.cloud/v1/tls/ask\n  }\n}\n\n"
	if got != want {
		t.Errorf("ask-gate render mismatch:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

func TestRender_StudioFallback(t *testing.T) {
	got := Render(Box{StudioUpstream: "localhost:4000"})
	if !strings.Contains(got, ":80 {\n  reverse_proxy localhost:4000\n") {
		t.Errorf("studio block missing or wrong: %q", got)
	}
	// The studio block also carries the maintenance handler so a bare-IP visit
	// during a restart gets a branded 503, not a raw 502.
	if !strings.Contains(got, MaintenanceHandler("  ")) {
		t.Errorf("studio block missing maintenance handler: %q", got)
	}
}

func TestMaintenanceHandler_ShapeAndStatus(t *testing.T) {
	h := MaintenanceHandler("  ")
	for _, sub := range []string{
		"  handle_errors {",
		"header Retry-After \"15\"",
		"respond 503 {",
		"body <<BARKPARK_MAINTENANCE",
		"Back in a moment",
		"\nBARKPARK_MAINTENANCE\n", // closing delimiter flush-left so the body stays literal
	} {
		if !strings.Contains(h, sub) {
			t.Errorf("maintenance handler missing %q:\n%s", sub, h)
		}
	}
}

func TestRender_EverySiteGetsMaintenance(t *testing.T) {
	got := Render(Box{
		Sites: []Site{
			{Slug: "a", Domains: []string{"a.com"}, Port: 7001},
			{Slug: "b", Domains: []string{"b.com"}, Port: 7002},
		},
	})
	if n := strings.Count(got, "handle_errors {"); n != 2 {
		t.Errorf("expected one maintenance handler per site (2), got %d:\n%s", n, got)
	}
}

func TestRender_OneSite_DomainsSortedAndJoined(t *testing.T) {
	got := Render(Box{
		AskGateURL: "https://x/ask",
		Sites: []Site{
			{Slug: "shop", Domains: []string{"www.shop.com", "shop.com"}, Port: 7001},
		},
	})

	// Domains sorted alphabetically and comma-joined for the host key.
	if !strings.Contains(got, "shop.com, www.shop.com {") {
		t.Errorf("expected sorted host key 'shop.com, www.shop.com {', got:\n%s", got)
	}
	if !strings.Contains(got, "tls {\n    on_demand\n  }") {
		t.Errorf("on_demand tls block missing: %s", got)
	}
	if !strings.Contains(got, "reverse_proxy 127.0.0.1:7001") {
		t.Errorf("reverse_proxy missing or wrong port: %s", got)
	}
}

func TestRender_MultipleSites_SortedBySlug(t *testing.T) {
	got := Render(Box{
		Sites: []Site{
			{Slug: "zebra", Domains: []string{"zebra.com"}, Port: 7003},
			{Slug: "apple", Domains: []string{"apple.com"}, Port: 7001},
			{Slug: "middle", Domains: []string{"middle.com"}, Port: 7002},
		},
	})

	iApple := strings.Index(got, "site apple")
	iMiddle := strings.Index(got, "site middle")
	iZebra := strings.Index(got, "site zebra")

	if iApple < 0 || iMiddle < 0 || iZebra < 0 {
		t.Fatalf("missing site markers: apple=%d middle=%d zebra=%d", iApple, iMiddle, iZebra)
	}
	if !(iApple < iMiddle && iMiddle < iZebra) {
		t.Errorf("sites not in slug order: apple=%d middle=%d zebra=%d", iApple, iMiddle, iZebra)
	}
}

func TestRender_Deterministic_SameInputSameBytes(t *testing.T) {
	box := Box{
		AskGateURL:     "https://x/ask",
		StudioUpstream: "localhost:4000",
		Sites: []Site{
			{Slug: "s2", Domains: []string{"b.com", "a.com"}, Port: 7002},
			{Slug: "s1", Domains: []string{"x.com"}, Port: 7001},
		},
	}
	a := Render(box)
	b := Render(box)
	if a != b {
		t.Errorf("Render is not deterministic — same input produced different output:\n--- a ---\n%s\n--- b ---\n%s", a, b)
	}
}

func TestRender_SkipSitesMissingPortOrDomains(t *testing.T) {
	got := Render(Box{
		Sites: []Site{
			{Slug: "no-port", Domains: []string{"foo.com"}, Port: 0},
			{Slug: "no-domains", Domains: []string{}, Port: 7001},
			{Slug: "good", Domains: []string{"good.com"}, Port: 7002},
		},
	})
	if strings.Contains(got, "no-port") || strings.Contains(got, "no-domains") {
		t.Errorf("skipped sites should not appear in output:\n%s", got)
	}
	if !strings.Contains(got, "good.com") {
		t.Errorf("complete site should appear: %s", got)
	}
}

func TestValidDomain(t *testing.T) {
	cases := []struct {
		d    string
		want bool
	}{
		{"shop.com", true},
		{"www.shop.com", true},
		{"*.shop.com", true},
		{"a-b.example.co.uk", true},
		{"", false},
		{"*.", false},
		{"has space.com", false},
		{"bad\ndomain.com", false},
		{"has\ttab.com", false},
		{"brace{.com", false},
		{"brace}.com", false},
		{"a,b.com", false},
		{"under_score.com", false},
		{"slash/.com", false},
		{strings.Repeat("a", 254), false},
		{".", false},
		{"..", false},
		{"a..b.com", false},
		{"-foo.com", false},
		{"foo-.com", false},
		{".com", false},
		{"com.", false},
	}
	for _, c := range cases {
		if got := validDomain(c.d); got != c.want {
			t.Errorf("validDomain(%q) = %v, want %v", c.d, got, c.want)
		}
	}
}

func TestRender_CrossSiteDuplicateDomainDedup(t *testing.T) {
	// Two sites claim the same domain. A duplicate site address would make
	// Caddy reject the whole config, so the domain must render exactly once —
	// and, sites being slug-sorted, "alpha" (first) wins it over "beta".
	got := Render(Box{
		Sites: []Site{
			{Slug: "beta", Domains: []string{"beta.com", "shared.example.com"}, Port: 7002},
			{Slug: "alpha", Domains: []string{"alpha.com", "shared.example.com"}, Port: 7001},
		},
	})
	if n := strings.Count(got, "shared.example.com"); n != 1 {
		t.Errorf("shared domain should render exactly once, got %d:\n%s", n, got)
	}
	// First writer (alpha, by slug order) keeps the contested domain.
	iAlpha := strings.Index(got, "site alpha")
	iBeta := strings.Index(got, "site beta")
	iShared := strings.Index(got, "shared.example.com")
	if iAlpha < 0 || iBeta < 0 || iShared < 0 {
		t.Fatalf("missing markers: alpha=%d beta=%d shared=%d", iAlpha, iBeta, iShared)
	}
	if !(iAlpha < iShared && iShared < iBeta) {
		t.Errorf("contested domain should sit in alpha's block: alpha=%d shared=%d beta=%d", iAlpha, iShared, iBeta)
	}
}

func TestRender_IntraSiteDuplicateDomainDedup(t *testing.T) {
	// A single site listing the same domain twice must not emit a repeated
	// entry in its host key (Caddy rejects a repeated address).
	got := Render(Box{
		Sites: []Site{
			{Slug: "solo", Domains: []string{"dup.example.com", "dup.example.com"}, Port: 7001},
		},
	})
	if n := strings.Count(got, "dup.example.com"); n != 1 {
		t.Errorf("intra-site duplicate should render once, got %d:\n%s", n, got)
	}
	// Host key holds the domain with no trailing comma-join of itself.
	if !strings.Contains(got, "dup.example.com {") {
		t.Errorf("expected clean single-domain host key 'dup.example.com {', got:\n%s", got)
	}
}

func TestRender_DedupDeterministic(t *testing.T) {
	// Dedup must not perturb determinism: same input → byte-identical output.
	box := Box{
		Sites: []Site{
			{Slug: "beta", Domains: []string{"shared.example.com", "beta.com"}, Port: 7002},
			{Slug: "alpha", Domains: []string{"shared.example.com", "alpha.com", "alpha.com"}, Port: 7001},
		},
	}
	a := Render(box)
	b := Render(box)
	if a != b {
		t.Errorf("dedup render is not deterministic:\n--- a ---\n%s\n--- b ---\n%s", a, b)
	}
}

func TestRender_HostileDomainsFiltered(t *testing.T) {
	// (a) newline dropped, (b) brace/space dropped, (d) mixed keeps valid only.
	got := Render(Box{
		Sites: []Site{
			{Slug: "mix", Domains: []string{
				"good.com",
				"evil.com\n} :6000 {\n  reverse_proxy 127.0.0.1:9",
				"has space.com",
				"brace{.com",
				"also-good.com",
			}, Port: 7001},
		},
	})
	if !strings.Contains(got, "also-good.com, good.com {") {
		t.Errorf("expected only valid domains in host key, got:\n%s", got)
	}
	for _, bad := range []string{"reverse_proxy 127.0.0.1:9", "has space.com", "brace{.com", ":6000 {"} {
		if strings.Contains(got, bad) {
			t.Errorf("hostile fragment %q leaked into output:\n%s", bad, got)
		}
	}
}

func TestRender_SiteSkippedWhenAllDomainsInvalid(t *testing.T) {
	// (c) a site whose only domain is invalid is skipped entirely.
	got := Render(Box{
		Sites: []Site{
			{Slug: "only-bad", Domains: []string{"bad\ndomain.com"}, Port: 7001},
			{Slug: "keeper", Domains: []string{"keeper.com"}, Port: 7002},
		},
	})
	if strings.Contains(got, "only-bad") {
		t.Errorf("site with no valid domains should be skipped:\n%s", got)
	}
	if !strings.Contains(got, "keeper.com") {
		t.Errorf("valid site should appear: %s", got)
	}
}

func TestRender_AllValidGolden(t *testing.T) {
	// An all-valid input renders byte-identically to the golden (ask gate +
	// one site block + its maintenance handler).
	got := Render(Box{
		AskGateURL: "https://cloud.barkpark.cloud/v1/tls/ask",
		Sites: []Site{
			{Slug: "shop", Domains: []string{"www.shop.com", "shop.com"}, Port: 7001},
		},
	})
	want := "{\n  on_demand_tls {\n    ask https://cloud.barkpark.cloud/v1/tls/ask\n  }\n}\n\n" +
		"# Managed by barkpark-runtime — site shop (port 7001). Do not edit by hand.\n" +
		"shop.com, www.shop.com {\n" +
		"  tls {\n    on_demand\n  }\n" +
		"  reverse_proxy 127.0.0.1:7001\n" +
		MaintenanceHandler("  ") +
		"}\n\n"
	if got != want {
		t.Errorf("all-valid render drifted from golden:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

func TestRender_StaticKindGolden(t *testing.T) {
	// A static-kind site renders the on_demand tls block + root/file_server
	// (NOT reverse_proxy) and — unlike a proxied site — carries no maintenance
	// handler, so file_server's own 404 surfaces instead of a fake deploy page.
	got := Render(Box{
		AskGateURL: "https://cloud.barkpark.cloud/v1/tls/ask",
		Sites: []Site{
			{Slug: "blog", Domains: []string{"www.blog.com", "blog.com"}, Kind: KindStatic, Root: "/srv/sites/blog/current"},
		},
	})
	want := "{\n  on_demand_tls {\n    ask https://cloud.barkpark.cloud/v1/tls/ask\n  }\n}\n\n" +
		"# Managed by barkpark-runtime — site blog (static /srv/sites/blog/current). Do not edit by hand.\n" +
		"blog.com, www.blog.com {\n" +
		"  tls {\n    on_demand\n  }\n" +
		"  root * /srv/sites/blog/current\n" +
		"  file_server\n" +
		"}\n\n"
	if got != want {
		t.Errorf("static-kind render drifted from golden:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
	if strings.Contains(got, "reverse_proxy") {
		t.Errorf("static site must not emit reverse_proxy:\n%s", got)
	}
	if strings.Contains(got, "handle_errors") {
		t.Errorf("static site must not emit the maintenance handler (404s must surface):\n%s", got)
	}
}

func TestRender_MixedBox_StaticAndReverseProxy(t *testing.T) {
	// One static + one reverse_proxy site render correctly together, slug-sorted.
	got := Render(Box{
		Sites: []Site{
			{Slug: "proxied", Domains: []string{"app.com"}, Port: 7001},
			{Slug: "flat", Domains: []string{"docs.com"}, Kind: KindStatic, Root: "/srv/sites/flat/current"},
		},
	})

	// Static block: root + file_server, no proxy, no maintenance handler.
	if !strings.Contains(got, "# Managed by barkpark-runtime — site flat (static /srv/sites/flat/current). Do not edit by hand.\n") {
		t.Errorf("static site header missing:\n%s", got)
	}
	if !strings.Contains(got, "docs.com {\n  tls {\n    on_demand\n  }\n  root * /srv/sites/flat/current\n  file_server\n}") {
		t.Errorf("static block malformed:\n%s", got)
	}
	// Proxied block: reverse_proxy + its maintenance handler, no root/file_server.
	if !strings.Contains(got, "app.com {\n  tls {\n    on_demand\n  }\n  reverse_proxy 127.0.0.1:7001\n") {
		t.Errorf("reverse_proxy block malformed:\n%s", got)
	}
	// The static site contributes no reverse_proxy and no file_server leaks into
	// the proxied one. Exactly one of each directive across the whole box.
	if n := strings.Count(got, "file_server"); n != 1 {
		t.Errorf("expected exactly one file_server (static only), got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "reverse_proxy"); n != 1 {
		t.Errorf("expected exactly one reverse_proxy (proxied only), got %d:\n%s", n, got)
	}
	// Maintenance handler rides the proxied site only, not the static one.
	if n := strings.Count(got, "handle_errors {"); n != 1 {
		t.Errorf("expected exactly one maintenance handler (proxied only), got %d:\n%s", n, got)
	}
	// Slug order: flat (f) before proxied (p).
	if iFlat, iProxied := strings.Index(got, "site flat"), strings.Index(got, "site proxied"); !(iFlat >= 0 && iFlat < iProxied) {
		t.Errorf("sites not slug-ordered: flat=%d proxied=%d", iFlat, iProxied)
	}
}

func TestRender_StaticSkippedWhenRootMissingOrUnsafe(t *testing.T) {
	// A static site is gated on a safe, non-empty Root (mirroring Port>0 for
	// proxied sites), so an empty/unsafe Root is skipped and never squats its
	// domains — a serving site that also lists them keeps them.
	got := Render(Box{
		Sites: []Site{
			{Slug: "no-root", Domains: []string{"a.com"}, Kind: KindStatic, Root: ""},
			{Slug: "bad-root", Domains: []string{"b.com"}, Kind: KindStatic, Root: "/srv/evil\n} :6000 {"},
			{Slug: "good", Domains: []string{"c.com"}, Kind: KindStatic, Root: "/srv/sites/good/current"},
		},
	})
	if strings.Contains(got, "no-root") || strings.Contains(got, "bad-root") {
		t.Errorf("static sites with empty/unsafe Root should be skipped:\n%s", got)
	}
	if strings.Contains(got, ":6000 {") {
		t.Errorf("unsafe Root fragment leaked into output:\n%s", got)
	}
	if !strings.Contains(got, "root * /srv/sites/good/current") {
		t.Errorf("static site with a safe Root should render:\n%s", got)
	}
}

func TestRender_StaticNotReadySiteDoesNotSquatDomain(t *testing.T) {
	// A not-ready static site (empty Root) and a serving static site both list
	// the same domain. Since sites are slug-sorted and the not-ready one is
	// skipped BEFORE consuming domains, the serving site keeps the domain.
	got := Render(Box{
		Sites: []Site{
			{Slug: "aaa-notready", Domains: []string{"shared.com"}, Kind: KindStatic, Root: ""},
			{Slug: "zzz-serving", Domains: []string{"shared.com"}, Kind: KindStatic, Root: "/srv/z/current"},
		},
	})
	if n := strings.Count(got, "shared.com"); n != 1 {
		t.Errorf("shared domain should render exactly once (serving site keeps it), got %d:\n%s", n, got)
	}
	if !strings.Contains(got, "shared.com {") {
		t.Errorf("serving site should own the domain:\n%s", got)
	}
}

func TestRender_StaticKind_Deterministic(t *testing.T) {
	box := Box{
		AskGateURL: "https://x/ask",
		Sites: []Site{
			{Slug: "s2", Domains: []string{"b.com", "a.com"}, Kind: KindStatic, Root: "/srv/s2/current"},
			{Slug: "s1", Domains: []string{"x.com"}, Port: 7001},
		},
	}
	if a, b := Render(box), Render(box); a != b {
		t.Errorf("mixed static/proxy render is not deterministic:\n--- a ---\n%s\n--- b ---\n%s", a, b)
	}
}

// --- Cloudflare Origin CA TLS mode (D18) ---------------------------------

func TestRender_OriginCAGolden(t *testing.T) {
	// A CF-fronted site loads a pre-issued Origin CA cert from disk and emits NO
	// on_demand block — behind the Cloudflare proxy an ACME TLS-ALPN-01 challenge
	// cannot complete, so on_demand there means error 526 for every visitor.
	// The box also gains the once-only trusted_proxies global option.
	got := Render(Box{
		AskGateURL: "https://cloud.barkpark.cloud/v1/tls/ask",
		Sites: []Site{{
			Slug:     "shop",
			Domains:  []string{"www.shop.com", "shop.com"},
			Port:     7001,
			TLSMode:  TLSModeOriginCA,
			CertPath: "/etc/caddy/certs/shop.pem",
			KeyPath:  "/etc/caddy/certs/shop.key",
		}},
	})
	want := "{\n" +
		"  on_demand_tls {\n    ask https://cloud.barkpark.cloud/v1/tls/ask\n  }\n" +
		"  servers {\n" +
		"    trusted_proxies static " + strings.Join(cloudflareIPRanges, " ") + "\n" +
		"    client_ip_headers CF-Connecting-IP\n" +
		"  }\n" +
		"}\n\n" +
		"# Managed by barkpark-runtime — site shop (port 7001). Do not edit by hand.\n" +
		"shop.com, www.shop.com {\n" +
		"  tls /etc/caddy/certs/shop.pem /etc/caddy/certs/shop.key\n" +
		"  reverse_proxy 127.0.0.1:7001\n" +
		MaintenanceHandler("  ") +
		"}\n\n"
	if got != want {
		t.Errorf("origin-CA render drifted from golden:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
	if strings.Contains(got, "on_demand\n") {
		t.Errorf("CF-fronted site must NOT emit an on_demand cert directive (526 outage):\n%s", got)
	}
}

func TestRender_OriginCA_StaticSite(t *testing.T) {
	// TLSMode is orthogonal to Kind: a static site can be CF-fronted too.
	got := Render(Box{
		Sites: []Site{{
			Slug:     "blog",
			Domains:  []string{"blog.com"},
			Kind:     KindStatic,
			Root:     "/srv/sites/blog/current",
			TLSMode:  TLSModeOriginCA,
			CertPath: "/etc/caddy/certs/blog.pem",
			KeyPath:  "/etc/caddy/certs/blog.key",
		}},
	})
	if !strings.Contains(got, "blog.com {\n  tls /etc/caddy/certs/blog.pem /etc/caddy/certs/blog.key\n  root * /srv/sites/blog/current\n  file_server\n}") {
		t.Errorf("CF-fronted static block malformed:\n%s", got)
	}
	if strings.Contains(got, "on_demand") {
		t.Errorf("CF-fronted static site must not emit on_demand:\n%s", got)
	}
}

func TestRender_InternalGolden(t *testing.T) {
	// A CF-Full-proxied site renders `tls internal` (self-signed, no cert files,
	// no ACME) and emits NO on_demand block — behind the Cloudflare proxy an ACME
	// challenge cannot complete, so on_demand there means error 526. The box also
	// gains the once-only trusted_proxies global option (it IS behind CF).
	got := Render(Box{
		AskGateURL: "https://cloud.barkpark.cloud/v1/tls/ask",
		Sites: []Site{{
			Slug:    "shop",
			Domains: []string{"www.shop.com", "shop.com"},
			Port:    7001,
			TLSMode: TLSModeInternal,
		}},
	})
	want := "{\n" +
		"  on_demand_tls {\n    ask https://cloud.barkpark.cloud/v1/tls/ask\n  }\n" +
		"  servers {\n" +
		"    trusted_proxies static " + strings.Join(cloudflareIPRanges, " ") + "\n" +
		"    client_ip_headers CF-Connecting-IP\n" +
		"  }\n" +
		"}\n\n" +
		"# Managed by barkpark-runtime — site shop (port 7001). Do not edit by hand.\n" +
		"shop.com, www.shop.com {\n" +
		"  tls internal\n" +
		"  reverse_proxy 127.0.0.1:7001\n" +
		MaintenanceHandler("  ") +
		"}\n\n"
	if got != want {
		t.Errorf("internal-TLS render drifted from golden:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
	// The site block must carry `tls internal` and NOT the on_demand cert block.
	if !strings.Contains(got, "  tls internal\n") {
		t.Errorf("internal-TLS site must emit `tls internal`:\n%s", got)
	}
	if strings.Contains(got, "    on_demand\n") {
		t.Errorf("internal-TLS site must NOT emit an on_demand cert directive (526 outage):\n%s", got)
	}
}

func TestRender_Internal_NeedsNoCertFiles(t *testing.T) {
	// Unlike Origin CA, internal TLS provisions no PEM pair — a site with empty
	// CertPath/KeyPath must still render (never be skipped by tlsReady), because
	// Caddy mints the self-signed cert itself.
	got := Render(Box{
		Sites: []Site{{
			Slug:    "blog",
			Domains: []string{"blog.com"},
			Port:    7002,
			TLSMode: TLSModeInternal,
			// CertPath / KeyPath deliberately empty.
		}},
	})
	if !strings.Contains(got, "blog.com {\n  tls internal\n  reverse_proxy 127.0.0.1:7002\n") {
		t.Errorf("internal-TLS site with no cert files must still render:\n%s", got)
	}
}

func TestRender_Internal_StaticSite(t *testing.T) {
	// TLSMode is orthogonal to Kind: a static site can be CF-Full-proxied too.
	got := Render(Box{
		Sites: []Site{{
			Slug:    "docs",
			Domains: []string{"docs.com"},
			Kind:    KindStatic,
			Root:    "/srv/sites/docs/current",
			TLSMode: TLSModeInternal,
		}},
	})
	if !strings.Contains(got, "docs.com {\n  tls internal\n  root * /srv/sites/docs/current\n  file_server\n}") {
		t.Errorf("internal-TLS static block malformed:\n%s", got)
	}
	if strings.Contains(got, "on_demand") {
		t.Errorf("internal-TLS static site must not emit on_demand:\n%s", got)
	}
}

func TestRender_Internal_GetsTrustedProxies(t *testing.T) {
	// An internal-TLS site IS behind Cloudflare (CF Full), so the box must trust
	// the CF edge ranges exactly as an Origin-CA box does — otherwise every
	// request logs a Cloudflare IP instead of the visitor's.
	got := Render(Box{
		Sites: []Site{{
			Slug:    "s",
			Domains: []string{"s.com"},
			Port:    7001,
			TLSMode: TLSModeInternal,
		}},
	})
	if n := strings.Count(got, "trusted_proxies"); n != 1 {
		t.Errorf("internal-TLS (CF-fronted) box must emit exactly one trusted_proxies stanza, got %d:\n%s", n, got)
	}
	if !strings.Contains(got, "client_ip_headers CF-Connecting-IP") {
		t.Errorf("internal-TLS box must honour CF-Connecting-IP:\n%s", got)
	}
}

func TestRender_Internal_MixedWithOriginCAAndOnDemand(t *testing.T) {
	// All three TLS modes coexist in one box: origin_ca loads cert files, internal
	// mints self-signed, on_demand keeps its block. The two CF-fronted modes share
	// the single global trusted_proxies option.
	got := Render(Box{
		AskGateURL: "https://cloud.barkpark.cloud/v1/tls/ask",
		Sites: []Site{
			{Slug: "a-ocsp", Domains: []string{"a.com"}, Port: 7001, TLSMode: TLSModeOriginCA, CertPath: "/c/a.pem", KeyPath: "/c/a.key"},
			{Slug: "b-internal", Domains: []string{"b.com"}, Port: 7002, TLSMode: TLSModeInternal},
			{Slug: "c-ondemand", Domains: []string{"c.com"}, Port: 7003},
		},
	})
	if !strings.Contains(got, "a.com {\n  tls /c/a.pem /c/a.key\n") {
		t.Errorf("origin-CA site must load cert files:\n%s", got)
	}
	if !strings.Contains(got, "b.com {\n  tls internal\n") {
		t.Errorf("internal site must emit `tls internal`:\n%s", got)
	}
	if !strings.Contains(got, "c.com {\n  tls {\n    on_demand\n  }\n") {
		t.Errorf("on-demand site must keep its on_demand block:\n%s", got)
	}
	// Exactly one on_demand cert block (site c), one trusted_proxies (global).
	if n := strings.Count(got, "    on_demand\n"); n != 1 {
		t.Errorf("only the on-demand neighbour keeps an on_demand block, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "trusted_proxies"); n != 1 {
		t.Errorf("two CF-fronted sites must still share one trusted_proxies stanza, got %d:\n%s", n, got)
	}
}

func TestRender_ZeroValueAndUnknownTLSMode_StayOnDemand(t *testing.T) {
	// The zero value is on-demand (that is what keeps every existing caller
	// byte-identical), an explicit TLSModeOnDemand means the same thing, and an
	// unrecognized value defaults to on-demand exactly like Kind does.
	site := func(mode string) Box {
		return Box{Sites: []Site{{Slug: "s", Domains: []string{"s.com"}, Port: 7001, TLSMode: mode}}}
	}
	zero := Render(site(""))
	explicit := Render(site(TLSModeOnDemand))
	unknown := Render(site("nonsense"))

	if !strings.Contains(zero, "  tls {\n    on_demand\n  }\n") {
		t.Errorf("zero-value TLSMode must render the on_demand block:\n%s", zero)
	}
	if zero != explicit {
		t.Errorf("explicit on_demand must be byte-identical to the zero value:\n--- zero ---\n%s\n--- explicit ---\n%s", zero, explicit)
	}
	if zero != unknown {
		t.Errorf("unknown TLSMode must default to on_demand:\n--- zero ---\n%s\n--- unknown ---\n%s", zero, unknown)
	}
	// None of these is CF-fronted, so no global servers block appears.
	for name, out := range map[string]string{"zero": zero, "explicit": explicit, "unknown": unknown} {
		if strings.Contains(out, "trusted_proxies") || strings.Contains(out, "servers {") {
			t.Errorf("%s: non-CF box must not emit trusted_proxies:\n%s", name, out)
		}
	}
}

func TestRender_TrustedProxies_EmittedOnceForManyCFSites(t *testing.T) {
	// trusted_proxies is a GLOBAL option: two CF-fronted sites must still yield
	// exactly one servers block (a repeat would be a config error), and it must
	// sit in the global block ahead of every site block.
	got := Render(Box{
		Sites: []Site{
			{Slug: "b", Domains: []string{"b.com"}, Port: 7002, TLSMode: TLSModeOriginCA, CertPath: "/c/b.pem", KeyPath: "/c/b.key"},
			{Slug: "a", Domains: []string{"a.com"}, Port: 7001, TLSMode: TLSModeOriginCA, CertPath: "/c/a.pem", KeyPath: "/c/a.key"},
			{Slug: "c", Domains: []string{"c.com"}, Port: 7003}, // plain on-demand neighbour
		},
	})
	if n := strings.Count(got, "trusted_proxies"); n != 1 {
		t.Errorf("expected exactly one trusted_proxies stanza, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "servers {"); n != 1 {
		t.Errorf("expected exactly one servers block, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "client_ip_headers CF-Connecting-IP"); n != 1 {
		t.Errorf("expected exactly one client_ip_headers line, got %d:\n%s", n, got)
	}
	// Global option precedes the first site block.
	if iProxies, iSite := strings.Index(got, "trusted_proxies"), strings.Index(got, "site a (port"); !(iProxies >= 0 && iProxies < iSite) {
		t.Errorf("trusted_proxies must precede the site blocks: proxies=%d site=%d", iProxies, iSite)
	}
	// The CF sites load certs; the on-demand neighbour keeps its on_demand block.
	if !strings.Contains(got, "a.com {\n  tls /c/a.pem /c/a.key\n") || !strings.Contains(got, "b.com {\n  tls /c/b.pem /c/b.key\n") {
		t.Errorf("CF sites must load their own cert pairs:\n%s", got)
	}
	if n := strings.Count(got, "    on_demand\n"); n != 1 {
		t.Errorf("only the non-CF site keeps an on_demand block, got %d:\n%s", n, got)
	}
	// A well-known CF range and the IPv6 half both made it in.
	for _, cidr := range []string{"173.245.48.0/20", "104.16.0.0/13", "2400:cb00::/32"} {
		if !strings.Contains(got, cidr) {
			t.Errorf("trusted_proxies missing Cloudflare range %s:\n%s", cidr, got)
		}
	}
}

func TestRender_CFBox_WithoutAskGate_StillOpensGlobalBlock(t *testing.T) {
	// The two halves of the global block are independent: a CF box with no ask
	// gate still needs one, and it must not carry an empty on_demand_tls stanza.
	got := Render(Box{
		Sites: []Site{
			{Slug: "s", Domains: []string{"s.com"}, Port: 7001, TLSMode: TLSModeOriginCA, CertPath: "/c/s.pem", KeyPath: "/c/s.key"},
		},
	})
	if !strings.HasPrefix(got, "{\n  servers {\n") {
		t.Errorf("CF box with no ask gate should open a global block holding only servers:\n%s", got)
	}
	if strings.Contains(got, "on_demand_tls") {
		t.Errorf("no ask gate configured → no on_demand_tls stanza:\n%s", got)
	}
}

func TestRender_OriginCA_UnsafeCertOrKeySkipsSite_NeverFallsBackToOnDemand(t *testing.T) {
	// An Origin-CA site whose cert/key is missing or unsafe must be SKIPPED, not
	// quietly downgraded to on_demand — that "fallback" is the 526 outage this
	// mode exists to prevent. And no fragment may splice through into the file.
	got := Render(Box{
		Sites: []Site{
			{Slug: "no-cert", Domains: []string{"a.com"}, Port: 7001, TLSMode: TLSModeOriginCA, KeyPath: "/c/a.key"},
			{Slug: "no-key", Domains: []string{"b.com"}, Port: 7002, TLSMode: TLSModeOriginCA, CertPath: "/c/b.pem"},
			{Slug: "brace-cert", Domains: []string{"c.com"}, Port: 7003, TLSMode: TLSModeOriginCA, CertPath: "/c/evil{.pem", KeyPath: "/c/c.key"},
			{Slug: "space-key", Domains: []string{"d.com"}, Port: 7004, TLSMode: TLSModeOriginCA, CertPath: "/c/d.pem", KeyPath: "/c/d key.pem"},
			{Slug: "inject-key", Domains: []string{"e.com"}, Port: 7005, TLSMode: TLSModeOriginCA, CertPath: "/c/e.pem", KeyPath: "/c/e.key\n} :6000 {\n  reverse_proxy 127.0.0.1:9"},
			{Slug: "good", Domains: []string{"f.com"}, Port: 7006, TLSMode: TLSModeOriginCA, CertPath: "/c/f.pem", KeyPath: "/c/f.key"},
		},
	})
	for _, skipped := range []string{"no-cert", "no-key", "brace-cert", "space-key", "inject-key"} {
		if strings.Contains(got, skipped) {
			t.Errorf("origin-CA site %q with an unsafe cert/key must be skipped:\n%s", skipped, got)
		}
	}
	for _, leak := range []string{":6000 {", "reverse_proxy 127.0.0.1:9", "evil{.pem", "d key.pem"} {
		if strings.Contains(got, leak) {
			t.Errorf("unsafe cert/key fragment %q leaked into output:\n%s", leak, got)
		}
	}
	// Critically: none of the skipped sites fell back to an on_demand cert.
	if strings.Contains(got, "on_demand") {
		t.Errorf("a CF-fronted site must never fall back to on_demand (526):\n%s", got)
	}
	// The one well-formed CF site still serves.
	if !strings.Contains(got, "f.com {\n  tls /c/f.pem /c/f.key\n") {
		t.Errorf("the safe origin-CA site should render:\n%s", got)
	}
}

func TestRender_UnsafeCFSiteAloneEmitsNoTrustedProxies(t *testing.T) {
	// A CF site that can never render (unsafe key) must not drag in the global
	// trusted_proxies block on its own — nothing is being served behind CF.
	got := Render(Box{
		Sites: []Site{
			{Slug: "broken", Domains: []string{"a.com"}, Port: 7001, TLSMode: TLSModeOriginCA, CertPath: "/c/a.pem", KeyPath: ""},
			{Slug: "plain", Domains: []string{"b.com"}, Port: 7002},
		},
	})
	if strings.Contains(got, "trusted_proxies") || strings.Contains(got, "servers {") {
		t.Errorf("no renderable CF site → no trusted_proxies:\n%s", got)
	}
	if !strings.Contains(got, "b.com {") {
		t.Errorf("the plain site should still render:\n%s", got)
	}
}

func TestRender_UnsafeCFSiteDoesNotSquatDomain(t *testing.T) {
	// The TLS gate runs BEFORE domains are consumed, so a CF site that cannot
	// serve (unsafe cert) cannot steal a domain from a site that can.
	got := Render(Box{
		Sites: []Site{
			{Slug: "aaa-broken", Domains: []string{"shared.com"}, Port: 7001, TLSMode: TLSModeOriginCA, CertPath: "", KeyPath: ""},
			{Slug: "zzz-serving", Domains: []string{"shared.com"}, Port: 7002},
		},
	})
	if n := strings.Count(got, "shared.com"); n != 1 {
		t.Errorf("shared domain should render exactly once (serving site keeps it), got %d:\n%s", n, got)
	}
	if !strings.Contains(got, "site zzz-serving") {
		t.Errorf("the serving site should own the contested domain:\n%s", got)
	}
}

func TestRender_OriginCA_Deterministic(t *testing.T) {
	box := Box{
		AskGateURL: "https://x/ask",
		Sites: []Site{
			{Slug: "s2", Domains: []string{"b.com", "a.com"}, Kind: KindStatic, Root: "/srv/s2/current", TLSMode: TLSModeOriginCA, CertPath: "/c/s2.pem", KeyPath: "/c/s2.key"},
			{Slug: "s1", Domains: []string{"x.com"}, Port: 7001},
		},
	}
	if a, b := Render(box), Render(box); a != b {
		t.Errorf("CF-fronted render is not deterministic:\n--- a ---\n%s\n--- b ---\n%s", a, b)
	}
}

func TestSafeCaddyPath(t *testing.T) {
	// The splice guard for every on-box path (root, cert, key): same rejection
	// set — empty, whitespace, control bytes, braces.
	cases := []struct {
		p    string
		want bool
	}{
		{"/srv/sites/blog/current", true},
		{"/etc/caddy/certs/shop.pem", true},
		{"relative/path.pem", true},
		{"", false},
		{" ", false},
		{"/c/has space.pem", false},
		{"/c/tab\t.pem", false},
		{"/c/new\nline.pem", false},
		{"/c/brace{.pem", false},
		{"/c/brace}.pem", false},
		{"/c/null\x00.pem", false},
		{"/c/del\x7f.pem", false},
	}
	for _, c := range cases {
		if got := safeCaddyPath(c.p); got != c.want {
			t.Errorf("safeCaddyPath(%q) = %v, want %v", c.p, got, c.want)
		}
	}
}

func TestRender_BlueGreen_SamePortConfig(t *testing.T) {
	// Simulating a blue/green swap: same site, different port → renders
	// different upstream. (The agent will then `caddy reload`, drain old.)
	blue := Render(Box{Sites: []Site{{Slug: "x", Domains: []string{"x.com"}, Port: 7001}}})
	green := Render(Box{Sites: []Site{{Slug: "x", Domains: []string{"x.com"}, Port: 7002}}})

	if !strings.Contains(blue, "127.0.0.1:7001") {
		t.Errorf("blue should point at :7001: %s", blue)
	}
	if !strings.Contains(green, "127.0.0.1:7002") {
		t.Errorf("green should point at :7002: %s", green)
	}
	if blue == green {
		t.Errorf("blue and green should differ (different upstream port)")
	}
}

// TestRenderedConfigIsValidCaddyfile hands the rendered config to a REAL caddy
// binary. Everything else in this file asserts that we produce the bytes we
// intended; none of it can tell whether Caddy can actually PARSE them. That gap
// is the dangerous one: the global `servers { trusted_proxies … }` +
// `client_ip_headers` block is written from knowledge of Caddy's global options,
// and a syntax error there does not degrade the CF sites — it fails the whole
// config to load and wedges EVERY site on the box. A string test would stay
// cheerfully green through that.
//
// Skips when caddy is not installed (so the unit suite stays hermetic); runs for
// real on any dev box or CI image that has it.
func TestRenderedConfigIsValidCaddyfile(t *testing.T) {
	bin, err := exec.LookPath("caddy")
	if err != nil {
		t.Skip("caddy binary not on PATH — skipping real-parser validation")
	}

	certPath, keyPath := selfSignedPair(t)

	cases := []struct {
		name string
		box  Box
	}{
		{
			name: "cloudflare-fronted origin-ca site (the new path)",
			box: Box{
				AskGateURL:     "https://cloud.barkpark.cloud/v1/tls/ask",
				StudioUpstream: "localhost:4000",
				Sites: []Site{{
					Slug:     "blog",
					Domains:  []string{"blog.example.com"},
					Kind:     KindStatic,
					Root:     "/opt/barkpark/sites/blog/current",
					TLSMode:  TLSModeOriginCA,
					CertPath: certPath,
					KeyPath:  keyPath,
				}},
			},
		},
		{
			// A mixed box is the realistic one: the global trusted_proxies block
			// fires for the whole server, so a non-CF site must still parse.
			name: "mixed box — an origin-ca site beside an on-demand proxied site",
			box: Box{
				AskGateURL:     "https://cloud.barkpark.cloud/v1/tls/ask",
				StudioUpstream: "localhost:4000",
				Sites: []Site{
					{
						Slug:     "blog",
						Domains:  []string{"blog.example.com"},
						Kind:     KindStatic,
						Root:     "/opt/barkpark/sites/blog/current",
						TLSMode:  TLSModeOriginCA,
						CertPath: certPath,
						KeyPath:  keyPath,
					},
					{Slug: "app", Domains: []string{"app.example.com"}, Port: 8081},
				},
			},
		},
		{
			// The zero value — today's live shape. If this ever fails to parse we
			// have broken a running box, not a new feature.
			name: "the default on-demand box (byte-identical to today)",
			box: Box{
				AskGateURL:     "https://cloud.barkpark.cloud/v1/tls/ask",
				StudioUpstream: "localhost:4000",
				Sites:          []Site{{Slug: "app", Domains: []string{"app.example.com"}, Port: 8081}},
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "Caddyfile")
			cfg := Render(tc.box)
			if err := os.WriteFile(path, []byte(cfg), 0o600); err != nil {
				t.Fatalf("write Caddyfile: %v", err)
			}
			cmd := exec.Command(bin, "validate", "--adapter", "caddyfile", "--config", path)
			// Keep caddy from touching the real data/config dirs.
			cmd.Env = append(os.Environ(),
				"XDG_DATA_HOME="+t.TempDir(),
				"XDG_CONFIG_HOME="+t.TempDir(),
			)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("caddy validate REJECTED the rendered config: %v\n--- config ---\n%s\n--- caddy said ---\n%s",
					err, cfg, out)
			}
		})
	}
}

// selfSignedPair writes a throwaway cert/key pair and returns their paths. Caddy's
// `validate` provisions the TLS app, which actually OPENS the files named by
// `tls <cert> <key>` — so validating the origin-CA path needs real PEMs on disk.
// They are never served; they exist so the parser can get all the way through.
func selfSignedPair(t *testing.T) (certPath, keyPath string) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "blog.example.com"},
		DNSNames:     []string{"blog.example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}

	dir := t.TempDir()
	certPath = filepath.Join(dir, "origin.pem")
	keyPath = filepath.Join(dir, "origin.key")

	if err := os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	return certPath, keyPath
}
