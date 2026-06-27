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
	if !strings.Contains(got, ":80 {\n  reverse_proxy localhost:4000\n}") {
		t.Errorf("studio block missing or wrong: %q", got)
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
