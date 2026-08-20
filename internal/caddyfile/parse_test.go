package caddyfile

import (
	"reflect"
	"strings"
	"testing"
)

// realBoxCaddyfile mirrors the shape of the jarl production box's Caddyfile:
// a global ask-gate block, a bare-:80 studio fallback, the instance API/Studio
// vhost (provisioner-owned — proxies the box's own Barkpark on 127.0.0.1:4000,
// with a heredoc'd maintenance handler whose CSS braces would wreck a naive
// brace counter), an attach-domain vhost (provisioner marker, `tls
// { on_demand }`), and two runtime-managed site blocks — one with the current
// marker, one with the legacy pre-marker header.
const realBoxCaddyfile = `{
  on_demand_tls {
    ask https://cloud.barkpark.cloud/v1/tls/ask
  }
}

:80 {
  reverse_proxy localhost:4000
}

# Instance API + Studio vhost — provisioner-owned, NOT the runtime's.
jarl.barkpark.cloud {
	reverse_proxy 127.0.0.1:4000
	handle_errors {
		respond 503 {
			body <<MAINT
<!doctype html>
<style>
h1{font-size:1.5rem;margin:0 0 .5rem
</style>
} :6666 {
MAINT
			close
		}
	}
}

# Managed by barkpark-provisioner (attach-domain) — custom host barkpark.jarl.no.
# On-demand TLS is gated by the control plane's /v1/tls/ask. Do not edit by hand.
barkpark.jarl.no {
	tls {
		on_demand
	}
	reverse_proxy 127.0.0.1:4000
}

# Managed by barkpark-runtime — site jarl-website (port 7001). Do not edit by hand.
jarl.no, www.jarl.no {
  tls {
    on_demand
  }
  reverse_proxy 127.0.0.1:7001
}

# site legacy-blog (port 7002)
blog.example.com {
  tls {
    on_demand
  }
  reverse_proxy 127.0.0.1:7002
}
`

func TestParse_RealBoxShape(t *testing.T) {
	// The full recovery a boot (or any deploy cycle) must make from disk:
	// managed blocks — current AND legacy marker — come back as Sites with
	// slug, domains, and upstream port; every port claimed by a foreign block
	// (the instance vhost + the attach-domain vhost, both on 4000) is foreign;
	// and the heredoc body (unbalanced braces, a hostile "} :6666 {" line)
	// perturbs none of it.
	p := Parse([]byte(realBoxCaddyfile))

	wantSites := []Site{
		{Slug: "jarl-website", Domains: []string{"jarl.no", "www.jarl.no"}, Port: 7001},
		{Slug: "legacy-blog", Domains: []string{"blog.example.com"}, Port: 7002},
	}
	if !reflect.DeepEqual(p.Sites, wantSites) {
		t.Errorf("Sites mismatch:\n got %+v\nwant %+v", p.Sites, wantSites)
	}

	wantPorts := map[int]bool{4000: true}
	if !reflect.DeepEqual(p.ForeignPorts, wantPorts) {
		t.Errorf("ForeignPorts = %v, want %v", p.ForeignPorts, wantPorts)
	}
}

func TestParse_EmptyAndMissingContent(t *testing.T) {
	for name, src := range map[string]string{"empty": "", "whitespace": "\n\n  \n"} {
		p := Parse([]byte(src))
		if len(p.Sites) != 0 || len(p.ForeignPorts) != 0 {
			t.Errorf("%s: expected empty parse, got sites=%v ports=%v", name, p.Sites, p.ForeignPorts)
		}
	}
}

func TestParse_MarkerForms(t *testing.T) {
	// Only the runtime's own markers make a block managed. The provisioner's
	// attach-domain marker, hand-written comments, and near-miss headers are
	// all foreign — the fail-safe reading for a shared file.
	block := "x.example.com {\n  reverse_proxy 127.0.0.1:7009\n}\n"
	cases := []struct {
		name    string
		comment string
		managed bool
		slug    string
	}{
		{"current marker, port", "# Managed by barkpark-runtime — site shop (port 7009). Do not edit by hand.", true, "shop"},
		{"current marker, static", "# Managed by barkpark-runtime — site blog (static /srv/blog/current). Do not edit by hand.", true, "blog"},
		{"legacy header, port", "# site shop (port 7009)", true, "shop"},
		{"legacy header, static", "# site blog (static /srv/blog/current)", true, "blog"},
		{"provisioner marker", "# Managed by barkpark-provisioner (attach-domain) — custom host x.example.com.", false, ""},
		{"prose mentioning a site", "# site notes: do not touch", false, ""},
		{"unrelated comment", "# reverse proxy for the app", false, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := Parse([]byte(c.comment + "\n" + block))
			if c.managed {
				if len(p.Sites) != 1 || p.Sites[0].Slug != c.slug {
					t.Fatalf("expected managed site %q, got %+v", c.slug, p.Sites)
				}
				if len(p.ForeignPorts) != 0 {
					t.Errorf("managed block's port must not be foreign: %v", p.ForeignPorts)
				}
			} else {
				if len(p.Sites) != 0 {
					t.Fatalf("expected foreign block, got sites %+v", p.Sites)
				}
				if !p.ForeignPorts[7009] {
					t.Errorf("foreign block's port must be reserved: %v", p.ForeignPorts)
				}
			}
		})
	}
}

func TestParse_RecoversTLSModeAndStaticKind(t *testing.T) {
	// TLS mode and static kind must survive a parse→rewrite round trip: losing
	// `tls internal` would downgrade a Cloudflare-proxied origin to on-demand
	// ACME (error 526 for every visitor), and losing Kind/Root would turn a
	// file_server site into a portless skip.
	src := "# Managed by barkpark-runtime — site cf (port 7003). Do not edit by hand.\n" +
		"cf.example.com {\n  tls internal\n  reverse_proxy 127.0.0.1:7003\n}\n\n" +
		"# Managed by barkpark-runtime — site oca (port 7004). Do not edit by hand.\n" +
		"oca.example.com {\n  tls /c/oca.pem /c/oca.key\n  reverse_proxy 127.0.0.1:7004\n}\n\n" +
		"# Managed by barkpark-runtime — site flat (static /srv/flat/current). Do not edit by hand.\n" +
		"flat.example.com {\n  tls {\n    on_demand\n  }\n  root * /srv/flat/current\n  file_server\n}\n"
	want := []Site{
		{Slug: "cf", Domains: []string{"cf.example.com"}, Port: 7003, TLSMode: TLSModeInternal},
		{Slug: "oca", Domains: []string{"oca.example.com"}, Port: 7004, TLSMode: TLSModeOriginCA, CertPath: "/c/oca.pem", KeyPath: "/c/oca.key"},
		{Slug: "flat", Domains: []string{"flat.example.com"}, Kind: KindStatic, Root: "/srv/flat/current"},
	}
	if got := Parse([]byte(src)).Sites; !reflect.DeepEqual(got, want) {
		t.Errorf("Sites mismatch:\n got %+v\nwant %+v", got, want)
	}
}

func TestParse_RenderedOutputRoundTrips(t *testing.T) {
	// Render → Parse recovers exactly what was rendered — the loop the
	// executor lives on: each deploy parses the file the previous deploy
	// wrote. The maintenance-handler heredoc rides inside every proxied block,
	// so this also proves heredoc bodies don't corrupt managed-block parsing.
	box := Box{
		AskGateURL:     "https://cloud.barkpark.cloud/v1/tls/ask",
		StudioUpstream: "localhost:4000",
		Sites: []Site{
			{Slug: "shop", Domains: []string{"shop.com", "www.shop.com"}, Port: 7001},
			{Slug: "blog", Domains: []string{"blog.com"}, Kind: KindStatic, Root: "/srv/blog/current"},
		},
	}
	p := Parse([]byte(Render(box)))

	// Render emits slug-sorted with sorted domains; Parse reads file order.
	want := []Site{
		{Slug: "blog", Domains: []string{"blog.com"}, Kind: KindStatic, Root: "/srv/blog/current"},
		{Slug: "shop", Domains: []string{"shop.com", "www.shop.com"}, Port: 7001},
	}
	if !reflect.DeepEqual(p.Sites, want) {
		t.Errorf("round-trip mismatch:\n got %+v\nwant %+v", p.Sites, want)
	}
	// The studio fallback (:80 → localhost:4000) is not a managed site, so its
	// port is foreign — reserved, never allocated to a container.
	if !p.ForeignPorts[4000] {
		t.Errorf("studio upstream port must be foreign: %v", p.ForeignPorts)
	}
}

func TestRewrite_EmptyPreviousIsFullRender(t *testing.T) {
	box := Box{
		AskGateURL: "https://x/ask",
		Sites:      []Site{{Slug: "shop", Domains: []string{"shop.com"}, Port: 7001}},
	}
	for name, prev := range map[string][]byte{"nil": nil, "empty": {}, "whitespace": []byte("\n \n")} {
		if got, want := string(Rewrite(prev, box)), Render(box); got != want {
			t.Errorf("%s: Rewrite of empty file must equal Render:\n--- got ---\n%s\n--- want ---\n%s", name, got, want)
		}
	}
}

func TestRewrite_PreservesForeignBlocksByteIdentical(t *testing.T) {
	// The production clobber, replayed: a deploy bumps jarl-website to a new
	// port. Every foreign byte — global block, studio fallback, instance
	// vhost, attach-domain vhost — must survive byte-identical and in place;
	// the managed blocks are re-rendered (legacy header upgraded to the
	// current marker, maintenance handler included). Golden-string assert.
	prev := []byte(realBoxCaddyfile)
	sites := Parse(prev).Sites
	for i := range sites {
		if sites[i].Slug == "jarl-website" {
			sites[i].Port = 7005 // the blue/green swap
		}
	}
	got := string(Rewrite(prev, Box{
		AskGateURL:     "https://cloud.barkpark.cloud/v1/tls/ask",
		StudioUpstream: "localhost:4000",
		Sites:          sites,
	}))

	foreign := realBoxCaddyfile[:strings.Index(realBoxCaddyfile, "\n# Managed by barkpark-runtime — site jarl-website")+1]
	want := foreign +
		"# Managed by barkpark-runtime — site jarl-website (port 7005). Do not edit by hand.\n" +
		"jarl.no, www.jarl.no {\n" +
		"  tls {\n    on_demand\n  }\n" +
		"  reverse_proxy 127.0.0.1:7005\n" +
		MaintenanceHandler("  ") +
		"}\n" +
		"\n" +
		"# Managed by barkpark-runtime — site legacy-blog (port 7002). Do not edit by hand.\n" +
		"blog.example.com {\n" +
		"  tls {\n    on_demand\n  }\n" +
		"  reverse_proxy 127.0.0.1:7002\n" +
		MaintenanceHandler("  ") +
		"}\n"
	if got != want {
		t.Errorf("rewrite drifted from golden:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
	if !strings.HasPrefix(got, foreign) {
		t.Errorf("foreign region not byte-identical:\n--- got prefix ---\n%s\n--- want prefix ---\n%s", got[:len(foreign)], foreign)
	}
}

func TestRewrite_AppendsNewSiteAfterForeignFile(t *testing.T) {
	// First deploy onto a provisioner-created file: nothing managed exists yet,
	// so the whole file is foreign and the new site block is appended — the
	// global/studio blocks are NOT re-emitted (the file already has its own).
	prev := "{\n  on_demand_tls {\n    ask https://x/ask\n  }\n}\n\n" +
		"api.example.com {\n\treverse_proxy 127.0.0.1:4000\n}\n"
	got := string(Rewrite([]byte(prev), Box{
		AskGateURL:     "https://x/ask",
		StudioUpstream: "localhost:4000",
		Sites:          []Site{{Slug: "shop", Domains: []string{"shop.com"}, Port: 7001}},
	}))
	want := prev +
		"\n# Managed by barkpark-runtime — site shop (port 7001). Do not edit by hand.\n" +
		"shop.com {\n" +
		"  tls {\n    on_demand\n  }\n" +
		"  reverse_proxy 127.0.0.1:7001\n" +
		MaintenanceHandler("  ") +
		"}\n"
	if got != want {
		t.Errorf("append drifted from golden:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

func TestRewrite_ForeignDomainNeverDuplicated(t *testing.T) {
	// A domain a foreign block already serves must not be emitted again in a
	// managed block — a duplicate site address makes Caddy reject the WHOLE
	// config and wedges every vhost on the box.
	prev := "taken.example.com {\n\treverse_proxy 127.0.0.1:4000\n}\n"
	got := string(Rewrite([]byte(prev), Box{
		Sites: []Site{{Slug: "shop", Domains: []string{"taken.example.com", "free.example.com"}, Port: 7001}},
	}))
	if n := strings.Count(got, "taken.example.com"); n != 1 {
		t.Errorf("foreign-owned domain must appear exactly once (the foreign block), got %d:\n%s", n, got)
	}
	if !strings.Contains(got, "free.example.com {\n") {
		t.Errorf("managed block should serve its remaining domain:\n%s", got)
	}

	// And a site whose ONLY domain is foreign-owned emits nothing at all.
	got = string(Rewrite([]byte(prev), Box{
		Sites: []Site{{Slug: "shop", Domains: []string{"taken.example.com"}, Port: 7001}},
	}))
	if got != prev {
		t.Errorf("fully-shadowed site must leave the file untouched:\n--- got ---\n%s\n--- want ---\n%s", got, prev)
	}
}

func TestRewrite_DropsManagedBlockForRemovedSlug(t *testing.T) {
	// A managed slug absent from box.Sites is dropped; foreign content stays.
	prev := "api.example.com {\n\treverse_proxy 127.0.0.1:4000\n}\n\n" +
		"# Managed by barkpark-runtime — site gone (port 7001). Do not edit by hand.\n" +
		"gone.example.com {\n  tls {\n    on_demand\n  }\n  reverse_proxy 127.0.0.1:7001\n}\n"
	got := string(Rewrite([]byte(prev), Box{Sites: nil}))
	if strings.Contains(got, "gone.example.com") {
		t.Errorf("removed slug's block should be dropped:\n%s", got)
	}
	if !strings.Contains(got, "api.example.com {\n\treverse_proxy 127.0.0.1:4000\n}\n") {
		t.Errorf("foreign block must survive:\n%s", got)
	}
}

func TestRewrite_IdempotentAndDeterministic(t *testing.T) {
	// Same input → byte-identical output, and a second rewrite of its own
	// output is a fixed point — a no-op deploy cycle never churns the on-disk
	// file or triggers a pointless Caddy reload. The second pass also proves
	// the parser reads back its OWN output (maintenance-handler heredocs and
	// all), the loop the executor lives on.
	prev := []byte(realBoxCaddyfile)
	box := Box{
		AskGateURL:     "https://cloud.barkpark.cloud/v1/tls/ask",
		StudioUpstream: "localhost:4000",
		Sites:          Parse(prev).Sites,
	}
	first := Rewrite(prev, box)
	if again := Rewrite(prev, box); string(again) != string(first) {
		t.Errorf("Rewrite is not deterministic:\n--- a ---\n%s\n--- b ---\n%s", first, again)
	}
	box.Sites = Parse(first).Sites
	if second := Rewrite(first, box); string(second) != string(first) {
		t.Errorf("Rewrite of own output is not a fixed point:\n--- first ---\n%s\n--- second ---\n%s", first, second)
	}
}

func TestRewrite_OutputIsParseableWithSameState(t *testing.T) {
	// After a rewrite, a fresh Parse must recover the same managed state and
	// the same foreign ports — the invariant the executor's per-cycle
	// StateFromDisk depends on.
	prev := []byte(realBoxCaddyfile)
	box := Box{Sites: Parse(prev).Sites}
	out := Rewrite(prev, box)
	p := Parse(out)
	if !reflect.DeepEqual(p.Sites, box.Sites) {
		t.Errorf("managed state changed across rewrite:\n got %+v\nwant %+v", p.Sites, box.Sites)
	}
	if !p.ForeignPorts[4000] {
		t.Errorf("foreign ports lost across rewrite: %v", p.ForeignPorts)
	}
}
