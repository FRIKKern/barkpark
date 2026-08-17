package cli

// Exact-host guard classifier (onb-backlog-isprod-localhost-substring-corner).
//
// After the #12033 fail-closed flip, the prod write-guard's LAST fail-open
// escape was its substring local-check: any URL merely CONTAINING
// "localhost"/"127.0.0.1"/"0.0.0.0" classified local and skipped the confirm
// (localhost.evil.com, my-127.0.0.1.attacker.net, prod-0.0.0.0.evil.io) — and
// a server-supplied manifest base_url containing "localhost" suppressed the
// guard for a NON-local ctx.Server. Both twins (isProd, isProdServer) now
// collapse onto ONE pinned exact-host classifier, isLocalHost (run.go), which
// classifies ctx.Server ALONE.
//
// These tests are the mutation tripwires, both directions:
//   - revert isLocalHost to the substring body → the hostile-host tests red
//     (fail-open direction);
//   - swap isLocalHost for ServerKind(...) == "local" → the divergence pins
//     red (bypass-widening direction: RFC1918 + mDNS would stop prompting).
//
// whoami note: builtins.go's whoami display flag calls isProd on the loaded
// manifest, so its printed prod value flips with this classifier — [::1] and
// 127.0.1.1 now read non-prod, hostile lookalike hosts now read prod. That is
// INTENDED: the display follows the dial target, and the classifier stays a
// pure offline heuristic (no network in isLocalHost/isProd themselves).

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Fail-open direction: hostile hostnames that embed a local token must
// classify PROD on BOTH twins — this is exactly what the substring shape got
// wrong, so a revert to substring matching reds every case here.
func TestIsProdHostileLookalikeHostsClassifyProd(t *testing.T) {
	hostile := []string{
		"https://localhost.evil.com",
		"https://my-127.0.0.1.attacker.net",
		"https://prod-0.0.0.0.evil.io",
	}
	for _, s := range hostile {
		if isLocalHost(s) {
			t.Errorf("isLocalHost(%s) = true — hostile lookalike classifies local (fail-open)", s)
		}
		if !isProd(manifest.Context{Server: s}, &manifest.Manifest{}) {
			t.Errorf("isProd(%s) = false — hostile lookalike skips the write confirm", s)
		}
		if !isProdServer(s) {
			t.Errorf("isProdServer(%s) = false — builtin task-create fails open on hostile lookalike", s)
		}
	}
}

// Fail-open direction, masking channel: a server-supplied manifest base_url
// containing "localhost" must NOT suppress the guard for a non-local
// ctx.Server. Classification reads ctx.Server ALONE (D35) — BaseURL is the
// server's own echo of the dialed host and must never loosen the guard.
func TestIsProdBaseURLCannotMaskNonLocalServer(t *testing.T) {
	ctx := manifest.Context{Server: "https://cms.gyldendal.no"}
	m := &manifest.Manifest{Server: manifest.Server{Name: "barkpark", BaseURL: "http://localhost:4000"}}
	if !isProd(ctx, m) {
		t.Errorf("isProd(cms.gyldendal.no with localhost base_url) = false — server-controlled BaseURL suppresses the guard")
	}
}

// False-prompt direction: genuine loopback forms classify LOCAL — including
// the shapes the substring era false-prompted on ([::1], 127.0.1.1) and the
// trailing-dot DNS root form. hostOf returns the BRACKETED [::1] for IPv6
// URLs; the bare forms are pinned too.
func TestIsLocalHostLoopbackFamilyClassifiesLocal(t *testing.T) {
	local := []string{
		"[::1]",
		"http://[::1]:4000",
		"localhost",
		"http://localhost:4000",
		"http://localhost.:4000", // one trailing dot stripped (DNS root form)
		"https://localhost./",
		"http://127.0.0.1:4000",
		"http://127.0.1.1:4000", // Debian/Ubuntu loopback — 127/8, not just .0.0.1
		"http://0.0.0.0:4000",
	}
	for _, s := range local {
		if !isLocalHost(s) {
			t.Errorf("isLocalHost(%s) = false — loopback misclassified PROD (false prompt)", s)
		}
		if isProd(manifest.Context{Server: s}, &manifest.Manifest{}) {
			t.Errorf("isProd(%s) = true — loopback target must stay unprompted", s)
		}
		if isProdServer(s) {
			t.Errorf("isProdServer(%s) = true — loopback target must stay unprompted", s)
		}
	}
}

// Fail-closed floor: empty/unparseable hosts classify PROD — the guard never
// gives an unprovable target the benefit of the doubt. Two trailing dots are
// NOT normalized away (only one is — DNS root form), so "localhost.." stays
// PROD too.
func TestIsLocalHostFailsClosedOnUnprovableHosts(t *testing.T) {
	for _, s := range []string{"", "   ", "http://", "http://user@/path", "localhost.."} {
		if isLocalHost(s) {
			t.Errorf("isLocalHost(%q) = true — unprovable host must fail closed to PROD", s)
		}
	}
}

// Divergence pins: the guard classifier is DELIBERATELY narrower than
// ServerKind (config.go). ServerKind is a UX classifier — it calls RFC1918
// LAN ranges and *.local mDNS names "local", but those dial OTHER machines,
// so the write-guard keeps prompting there (false prompt is the safe failure;
// --yes and /v1/meta production:false are the sanctioned exits). Swapping
// isLocalHost for ServerKind == "local" reds this table — that swap was
// mutation-proven to WIDEN the prod bypass (192.168.x/10.x/172.16.x/*.local
// would stop prompting) and to break the 0.0.0.0 + trailing-dot carve-outs.
func TestIsLocalHostNarrowerThanServerKind(t *testing.T) {
	cases := []struct {
		server    string
		kind      string // ServerKind's answer (UX classifier)
		guardWant bool   // isLocalHost's answer (security floor)
	}{
		{"http://192.168.1.50:4000", "local", false}, // RFC1918 LAN: UX-local, guard-PROD
		{"http://10.0.0.5:4000", "local", false},
		{"http://172.16.0.9:4000", "local", false},
		{"http://mymac.local:4000", "local", false},   // mDNS: another machine on the LAN
		{"http://app.localhost:4000", "cloud", false}, // *.localhost excluded (resolver-dependent)
		{"http://0.0.0.0:4000", "cloud", true},        // ServerKind calls 0.0.0.0 cloud; guard keeps the dev carve-out
		{"http://localhost.:4000", "cloud", true},     // ServerKind has no trailing-dot normalization
		{"https://guerrilla.barkpark.cloud", "cloud", false},
		{"https://evil.com.", "cloud", false}, // trailing dot on a public name stays prod
		{"", "cloud", false},                  // empty → fail closed
	}
	for _, c := range cases {
		if got := ServerKind(c.server); got != c.kind {
			t.Errorf("ServerKind(%q) = %q, want %q (pin drifted — re-derive the divergence table)", c.server, got, c.kind)
		}
		if got := isLocalHost(c.server); got != c.guardWant {
			t.Errorf("isLocalHost(%q) = %v, want %v", c.server, got, c.guardWant)
		}
	}
}
