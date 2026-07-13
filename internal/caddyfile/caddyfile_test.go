package caddyfile

import (
	"strings"
	"testing"
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
		"# site shop (port 7001)\n" +
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
		"# site blog (static /srv/sites/blog/current)\n" +
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
	if !strings.Contains(got, "# site flat (static /srv/sites/flat/current)\n") {
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
