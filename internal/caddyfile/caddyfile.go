// Package caddyfile renders the per-box Caddyfile that drives the runtime
// proxy in Barkpark Cloud's on-demand-TLS hosting model (P3).
//
// The file has three layers:
//
//  1. The global block with on_demand_tls + the ask-gate URL. The ask gate is
//     the cloud control plane's GET /v1/tls/ask?domain=... — a 200 means "this
//     domain is registered to one of our Sites; you may issue a cert"; a 404
//     stops Caddy from issuing certs for arbitrary hostnames pointed at the
//     box. Without this gate, the box is a cert-issuance DoS target. On a box
//     that fronts any site through Cloudflare, this block also carries the
//     once-only trusted_proxies allowlist (see TLSModeOriginCA).
//
//  2. One reverse-proxy block per live Site, keyed on the Site's domains. The
//     block points at the loopback port of the currently-running container.
//     blue/green swaps in the renderer: a deploy regenerates the file with the
//     new container's port, Caddy reloads, drains.
//
//  3. A studio fallback on :80 + :443 — the local Barkpark control surface
//     (api.barkpark.cloud subdomain in prod) keeps answering at /studio even
//     when no Sites are live yet.
//
// The renderer is intentionally pure: in → struct, out → string. No file I/O,
// no shell. Caller writes the result to /etc/caddy/Caddyfile and reloads.
package caddyfile

import (
	"fmt"
	"sort"
	"strings"
)

// maintenancePage is the self-contained HTML the box serves while the app is
// unreachable (the seconds-long restart window of a deploy). No external assets,
// a tiny inline auto-refresh — so it renders even with the backend fully down.
const maintenancePage = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Back in a moment</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1115;color:#e7e9ee;display:grid;place-items:center;min-height:100vh;margin:0}
.card{max-width:32rem;padding:2.5rem;text-align:center}
h1{font-size:1.5rem;margin:0 0 .5rem}
p{opacity:.7;line-height:1.5;margin:.25rem 0}
.spinner{width:2rem;height:2rem;border:3px solid #2a2f3a;border-top-color:#6ea8fe;border-radius:50%;margin:0 auto 1.5rem;animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="card">
<div class="spinner"></div>
<h1>Back in a moment</h1>
<p>Barkpark is deploying an update and will be right back. This page refreshes automatically.</p>
</div>
<script>setTimeout(function(){location.reload()},15000)</script>
</body>
</html>`

// MaintenanceHandler returns a Caddy `handle_errors` block that turns an
// upstream-unreachable error — what every request hits while the app restarts
// during a deploy — into a branded 503 "Back in a moment" page with a
// Retry-After header, instead of Caddy's raw 502. It fires ONLY on errors Caddy
// itself raises (dial failures, gateway timeouts); a 4xx/5xx the app returns is
// proxied through untouched, so this never masks a real application error.
//
// Each structural line is prefixed with indent so the block nests cleanly inside
// a site block. The body is a Caddyfile heredoc whose closing delimiter is
// flush-left, so the HTML/CSS braces are emitted verbatim and never parsed as
// Caddyfile syntax.
func MaintenanceHandler(indent string) string {
	var sb strings.Builder
	sb.WriteString(indent + "handle_errors {\n")
	sb.WriteString(indent + "\theader Retry-After \"15\"\n")
	// The block form of `respond` lets us set 503 AND supply a heredoc body — a
	// heredoc opener (`<<TOKEN`) must be the last token on its line, so the
	// status cannot follow it directly.
	sb.WriteString(indent + "\trespond 503 {\n")
	sb.WriteString(indent + "\t\tbody <<BARKPARK_MAINTENANCE\n")
	sb.WriteString(maintenancePage + "\n")
	sb.WriteString("BARKPARK_MAINTENANCE\n")
	sb.WriteString(indent + "\t\tclose\n")
	sb.WriteString(indent + "\t}\n")
	sb.WriteString(indent + "}\n")
	return sb.String()
}

// Box describes the runtime state the renderer needs to produce a Caddyfile.
type Box struct {
	// AskGateURL is the absolute URL Caddy will GET to ask "is this domain
	// allowed?" before issuing a cert. Typically
	// https://cloud.barkpark.cloud/v1/tls/ask.
	AskGateURL string

	// StudioUpstream is "host:port" of the local Barkpark API serving /studio
	// (default localhost:4000). When empty, no studio block is emitted.
	StudioUpstream string

	// Sites are the live hosted sites — one block per Site, each with its
	// domains keyed at the host level and its container port as upstream.
	Sites []Site
}

// Site kinds. Kind selects how the per-site block serves traffic. The empty
// string is the zero value and means KindReverseProxy, so existing callers that
// only set Slug/Domains/Port keep emitting a reverse_proxy block unchanged.
const (
	// KindReverseProxy proxies to a loopback container port (the P3 blue/green
	// container path). Requires Port > 0.
	KindReverseProxy = "reverse_proxy"
	// KindStatic serves files from a directory with file_server (the static-site
	// runtime target — subdomain-ready foundation, charter D9). Requires
	// Root != ""; there is no upstream port.
	KindStatic = "static"
)

// TLS modes. TLSMode selects how a site terminates TLS. The empty string is the
// zero value and means TLSModeOnDemand — so every existing caller, which sets
// no TLSMode at all, keeps emitting today's `tls { on_demand }` block verbatim.
// Any unrecognized value is likewise treated as on-demand (same defaulting
// contract as Kind).
const (
	// TLSModeOnDemand issues a cert per hostname through ACME at first
	// handshake, gated by the box's on_demand_tls ask URL. This is the default
	// and the right mode for a domain that resolves STRAIGHT to the box.
	TLSModeOnDemand = "on_demand"

	// TLSModeOriginCA terminates TLS with a long-lived Cloudflare Origin CA
	// certificate loaded from disk — no ACME, no issuance at handshake time.
	//
	// This is a CORRECTNESS requirement, not a preference: when a domain is
	// proxied through Cloudflare (orange cloud) in Full (Strict) mode, the box
	// never sees the visitor's TLS handshake — Cloudflare does. Caddy's
	// on-demand ACME challenge (TLS-ALPN-01) therefore cannot complete through
	// the proxy, the origin ends up with no usable cert, and every visitor gets
	// Cloudflare error 526 (invalid SSL certificate). A CF-fronted site MUST
	// present a pre-issued Origin CA cert instead. Requires CertPath + KeyPath.
	TLSModeOriginCA = "origin_ca"

	// TLSModeInternal terminates TLS with a self-signed certificate Caddy mints
	// and rotates locally (`tls internal`) — no cert files on disk, no ACME, no
	// challenge at handshake time.
	//
	// This is the mode for a site proxied through Cloudflare in Full (NON-Strict)
	// mode: Cloudflare connects to the box over TLS but does not validate the
	// origin certificate, so a locally-minted cert is sufficient. It shares the
	// 526-avoidance property with Origin CA — a proxied origin must NEVER run
	// on-demand ACME, whose TLS-ALPN-01 challenge cannot complete through the
	// proxy — but needs no cert/key pair to provision, so unlike Origin CA it is
	// always renderable (no CertPath/KeyPath, so tlsReady never skips it). It is
	// the zero-provisioning CF-Full path a `bp provider add cloudflare` flow can
	// switch on without the box operator ever handling a PEM file.
	TLSModeInternal = "internal"
)

// cloudflareIPRanges is Cloudflare's published edge network — the only peers
// allowed to set the client-IP headers we honour. Sourced from
// https://www.cloudflare.com/ips/ (list current as of 2026-07-14; Cloudflare
// changes it rarely, and a stale entry degrades to "that edge IP is not
// trusted", never to "an untrusted peer is").
//
// Trusting these — and ONLY these — is what makes CF-Connecting-IP safe to
// believe: without a trusted_proxies allowlist, any client could forge the
// header and spoof its own address in logs, rate limits, and access rules.
var cloudflareIPRanges = []string{
	// IPv4
	"173.245.48.0/20",
	"103.21.244.0/22",
	"103.22.200.0/22",
	"103.31.4.0/22",
	"141.101.64.0/18",
	"108.162.192.0/18",
	"190.93.240.0/20",
	"188.114.96.0/20",
	"197.234.240.0/22",
	"198.41.128.0/17",
	"162.158.0.0/15",
	"104.16.0.0/13",
	"104.24.0.0/14",
	"172.64.0.0/13",
	"131.0.72.0/22",
	// IPv6
	"2400:cb00::/32",
	"2606:4700::/32",
	"2803:f800::/32",
	"2405:b500::/32",
	"2405:8100::/32",
	"2a06:98c0::/29",
	"2c0f:f248::/32",
}

// Site describes one hosted site's runtime state for Caddy: which domains it
// answers on, and how it serves them.
//
// Kind selects the serving strategy. For KindReverseProxy (the default / empty
// string) the block proxies to loopback Port. For KindStatic the block serves
// files from Root with file_server and ignores Port. A site is only rendered
// when it is "ready" for its kind — a reverse_proxy needs a live Port, a static
// site needs a served Root — so a not-yet-ready site never squats a domain a
// serving site also lists.
type Site struct {
	Slug    string
	Domains []string
	Port    int

	// Kind is the serving strategy: "" / KindReverseProxy (default) or
	// KindStatic. Any other value is treated as reverse_proxy.
	Kind string
	// Root is the served directory for a KindStatic site (e.g. the site's
	// `current` release symlink). Ignored for reverse_proxy sites.
	Root string

	// TLSMode is the TLS termination strategy: "" / TLSModeOnDemand (default),
	// TLSModeOriginCA (CF Full-Strict, cert files from disk), or TLSModeInternal
	// (CF Full, self-signed, no files). Any unrecognized value is treated as
	// on-demand. Orthogonal to Kind — a static site and a proxied site can each
	// be CF-fronted or not.
	TLSMode string
	// CertPath and KeyPath are the on-box PEM files for a TLSModeOriginCA site
	// (the Cloudflare Origin CA cert and its private key). Both are REQUIRED in
	// that mode and ignored otherwise. A site that asks for Origin CA without a
	// safe pair is not served at all (see tlsReady) — it is never quietly
	// downgraded to on-demand, which is precisely the 526 outage this mode
	// exists to prevent.
	CertPath string
	KeyPath  string
}

// isStatic reports whether s serves files with file_server rather than
// proxying to a container port.
func (s Site) isStatic() bool { return s.Kind == KindStatic }

// usesOriginCA reports whether s terminates TLS with a pre-issued Cloudflare
// Origin CA cert loaded from disk (TLSModeOriginCA) — the CF Full-Strict path.
// This is the only mode that needs a CertPath/KeyPath pair.
func (s Site) usesOriginCA() bool { return s.TLSMode == TLSModeOriginCA }

// usesInternalTLS reports whether s terminates TLS with a self-signed cert Caddy
// mints locally (TLSModeInternal) — the CF Full (non-Strict) path. No cert files,
// no ACME challenge (which the proxy would block → error 526).
func (s Site) usesInternalTLS() bool { return s.TLSMode == TLSModeInternal }

// isCloudflareFronted reports whether s sits behind the Cloudflare proxy (orange
// cloud) at all — either Full-Strict with an Origin CA cert (usesOriginCA) or
// Full with a self-signed internal cert (usesInternalTLS). Both mean the box
// never sees the visitor's address directly, so the global block must trust the
// CF edge ranges to believe CF-Connecting-IP. Both also forbid on-demand ACME,
// whose challenge cannot complete through the proxy.
func (s Site) isCloudflareFronted() bool { return s.usesOriginCA() || s.usesInternalTLS() }

// tlsReady reports whether s's TLS configuration can actually be rendered. An
// on-demand site (the default) and an internal-TLS site (self-signed, no files)
// each need nothing. Only an Origin-CA site needs a cert/key pair that is safe
// to splice into a `tls <cert> <key>` directive.
//
// This gate FAILS CLOSED for Origin CA: a site with a missing or unsafe pair is
// skipped entirely rather than falling back to `tls { on_demand }`. That
// fallback would look like a harmless default and behave like an outage —
// ACME cannot complete through the Cloudflare proxy, so every visitor to that
// host would get error 526. An internal-TLS site provisions no files, so it is
// always ready (the same 526-safety with zero operator setup).
func (s Site) tlsReady() bool {
	if !s.usesOriginCA() {
		return true
	}
	return safeCaddyPath(s.CertPath) && safeCaddyPath(s.KeyPath)
}

// anyCloudflareFronted reports whether any site in sites sits behind the
// Cloudflare proxy — served with either an Origin CA cert or a self-signed
// internal cert — i.e. whether the box sits behind Cloudflare at all.
//
// This is a pre-pass because the global block is written BEFORE the site loop
// runs (and before sites are even sorted), while `trusted_proxies` is a global
// option that must be emitted exactly once no matter how many CF-fronted sites
// there are. A plain OR is order-independent, so it costs nothing and cannot
// perturb the deterministic site ordering.
//
// Sites that could never render as CF-fronted (unsafe cert/key — see tlsReady)
// do not count: they will be skipped, so no traffic for them ever arrives.
func anyCloudflareFronted(sites []Site) bool {
	for _, s := range sites {
		if s.isCloudflareFronted() && s.tlsReady() {
			return true
		}
	}
	return false
}

// Render produces the Caddyfile text for box. Deterministic: sites are emitted
// in slug order, domains within a site are sorted — same input → byte-identical
// output, so a no-op rerender doesn't churn the on-disk file or trigger a
// pointless Caddy reload. Domains are deduped both within and across sites (a
// duplicate site address makes Caddy reject the whole config); since sites are
// processed in slug order, the first site to claim a contested domain wins it.
//
// Every site block is stamped with the runtime's managed-block marker (see
// ManagedMarkerPrefix), so a later Parse/Rewrite can tell the runtime's own
// blocks from foreign vhosts it must preserve.
func Render(box Box) string {
	var sb strings.Builder

	// Pre-pass: does ANY site sit behind Cloudflare? The global block below is
	// written before the site loop, so the once-only `trusted_proxies` option
	// has to be decided up front rather than appended from inside the loop.
	cfFronted := anyCloudflareFronted(box.Sites)

	// Global block: on_demand_tls + ask gate, and — only on a CF-fronted box —
	// the trusted-proxy allowlist. Each half is independent, so a box with an
	// ask gate and no CF site renders byte-identically to before this option
	// existed.
	if box.AskGateURL != "" || cfFronted {
		sb.WriteString("{\n")
		if box.AskGateURL != "" {
			sb.WriteString("  on_demand_tls {\n")
			fmt.Fprintf(&sb, "    ask %s\n", box.AskGateURL)
			sb.WriteString("  }\n")
		}
		if cfFronted {
			// Behind Cloudflare every request arrives from a CF edge IP, so the
			// remote address is useless: without this, logs, rate limits and
			// access rules all see Cloudflare instead of the visitor. Trusting
			// the CF ranges — and only them — makes CF-Connecting-IP believable;
			// a direct-to-origin client cannot forge it, because it is not a
			// trusted peer.
			sb.WriteString("  servers {\n")
			fmt.Fprintf(&sb, "    trusted_proxies static %s\n", strings.Join(cloudflareIPRanges, " "))
			sb.WriteString("    client_ip_headers CF-Connecting-IP\n")
			sb.WriteString("  }\n")
		}
		sb.WriteString("}\n\n")
	}

	// Studio fallback — the local Barkpark control surface stays reachable
	// even when no customer sites are configured. Bound to :80 so a bare-IP
	// request to the box answers something useful instead of a default page.
	if box.StudioUpstream != "" {
		sb.WriteString(":80 {\n")
		fmt.Fprintf(&sb, "  reverse_proxy %s\n", box.StudioUpstream)
		sb.WriteString(MaintenanceHandler("  "))
		sb.WriteString("}\n\n")
	}

	// Sort sites by slug for determinism.
	sites := append([]Site(nil), box.Sites...)
	sort.Slice(sites, func(i, j int) bool { return sites[i].Slug < sites[j].Slug })

	// Track every domain already claimed so a host key is never emitted twice.
	// Caddy rejects a duplicate site address and fails the whole config load,
	// so an intra-site repeat or a cross-site collision would wedge reloads for
	// every hosted site. Slug order makes first-writer-wins deterministic.
	seen := map[string]bool{}

	for _, s := range sites {
		if writeSiteBlock(&sb, s, seen) {
			sb.WriteString("\n")
		}
	}

	return sb.String()
}

// writeSiteBlock emits one runtime-managed site block — its marker comment,
// host key, TLS directive, and serving directives, ending "}\n" — and reports
// whether anything was written. Shared by Render (full file) and Rewrite
// (foreign-preserving regeneration), so the two paths can never drift.
//
// A not-yet-ready site is skipped BEFORE consuming its domains, so it can't
// squat a domain and steal it from a serving site that also lists it.
// Readiness is kind-specific: a static site needs a served Root; a
// reverse_proxy site needs a live upstream Port. A static site's Root is
// also spliced verbatim into `root * <Root>`, so a Root that would break
// Caddyfile syntax (whitespace, braces, control bytes) fails closed —
// the whole file must never be wedged by one bad value.
//
// TLS readiness is orthogonal to kind and gates both: an Origin-CA site
// without a safe cert/key pair is skipped rather than downgraded to
// on-demand (which would be a 526 outage, not a fallback).
func writeSiteBlock(sb *strings.Builder, s Site, seen map[string]bool) bool {
	if !s.tlsReady() {
		return false
	}
	if s.isStatic() {
		if !safeCaddyPath(s.Root) {
			return false
		}
	} else if s.Port <= 0 {
		return false
	}
	// Filter customer-supplied domains: a hostile or malformed domain
	// spliced verbatim into the host key would break Caddyfile syntax
	// (one bad domain fails the whole file) or inject directives; a
	// valid-but-already-claimed domain is dropped to avoid a duplicate key.
	var clean []string
	for _, d := range s.Domains {
		if validDomain(d) && !seen[d] {
			seen[d] = true
			clean = append(clean, d)
		}
	}
	if len(clean) == 0 {
		return false
	}
	sort.Strings(clean)

	sb.WriteString(managedMarker(s) + "\n")
	fmt.Fprintf(sb, "%s {\n", strings.Join(clean, ", "))
	switch {
	case s.usesOriginCA():
		// Pre-issued Cloudflare Origin CA cert (CF Full-Strict): load it from
		// disk, never ask ACME. tlsReady() has already vetted both paths for
		// splice safety.
		fmt.Fprintf(sb, "  tls %s %s\n", s.CertPath, s.KeyPath)
	case s.usesInternalTLS():
		// Self-signed cert Caddy mints locally (CF Full, non-Strict): no cert
		// files, no ACME. The on-demand challenge could not complete through
		// the CF proxy (error 526), and CF does not validate the origin cert
		// in Full mode, so a locally-minted cert is exactly right.
		sb.WriteString("  tls internal\n")
	default:
		sb.WriteString("  tls {\n")
		sb.WriteString("    on_demand\n")
		sb.WriteString("  }\n")
	}
	if s.isStatic() {
		// Serve the immutable release directory. A static site has no
		// process to restart — the deploy swaps the `current` symlink
		// atomically (charter D11), so there is no unreachable window and
		// therefore NO MaintenanceHandler: file_server's own 404 for a
		// missing page must surface as a real 404, not get masked into the
		// "Back in a moment" deploy page that handle_errors would impose.
		fmt.Fprintf(sb, "  root * %s\n", s.Root)
		sb.WriteString("  file_server\n")
	} else {
		fmt.Fprintf(sb, "  reverse_proxy 127.0.0.1:%d\n", s.Port)
		sb.WriteString(MaintenanceHandler("  "))
	}
	sb.WriteString("}\n")
	return true
}

// safeCaddyPath reports whether p is safe to splice verbatim into a Caddyfile
// directive that takes an on-box path — `root * <p>` for a static site's served
// directory, and `tls <cert> <key>` for an Origin-CA site's PEM pair. It rejects
// the empty string and anything carrying whitespace, control bytes, or the
// Caddyfile-structural characters "{", "}", so a malformed path can neither
// break the file's syntax (one bad value fails the whole file) nor inject
// directives. These are box-local paths (a release directory, a cert file), so
// a legitimate value never contains any of them.
//
// One guard for all three paths on purpose: the rejection set is a property of
// Caddyfile splice safety, not of what the path points at, so a second copy
// could only drift out of sync with this one.
func safeCaddyPath(p string) bool {
	if p == "" {
		return false
	}
	for _, r := range p {
		if r <= ' ' || r == 0x7f || r == '{' || r == '}' {
			return false
		}
	}
	return true
}

// validDomain reports whether d is safe to splice into a Caddyfile host key.
// It accepts a plain hostname (optionally with a single leading "*." wildcard
// label) made only of ASCII letters, digits, "." and "-". Anything with
// whitespace, control bytes, "{", "}", "," or other punctuation is rejected so
// a hostile or malformed customer domain can neither break the Caddyfile syntax
// (one bad domain fails the whole file) nor inject Caddy directives.
func validDomain(d string) bool {
	if d == "" || len(d) > 253 {
		return false
	}
	d = strings.TrimPrefix(d, "*.")
	if d == "" {
		return false
	}
	for _, r := range d {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '-' {
			continue
		}
		return false
	}
	// Each dot-separated label must be non-empty and not lead or trail with "-",
	// so structurally-invalid hosts (".", "..", "a..b.com", "-foo.com",
	// "foo-.com", ".com", "com.") can't reach Caddy and wedge every reload.
	for _, label := range strings.Split(d, ".") {
		if label == "" || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
	}
	return true
}
