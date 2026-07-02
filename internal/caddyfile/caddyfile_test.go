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
