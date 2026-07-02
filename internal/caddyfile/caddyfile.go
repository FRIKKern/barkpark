// Package caddyfile renders the per-box Caddyfile that drives the runtime
// proxy in Barkpark Cloud's on-demand-TLS hosting model (P3).
//
// The file has three layers:
//
//  1. The global block with on_demand_tls + the ask-gate URL. The ask gate is
//     the cloud control plane's GET /v1/tls/ask?domain=... — a 200 means "this
//     domain is registered to one of our Sites; you may issue a cert"; a 404
//     stops Caddy from issuing certs for arbitrary hostnames pointed at the
//     box. Without this gate, the box is a cert-issuance DoS target.
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

// Site describes one hosted site's runtime state for Caddy: which domains it
// answers on, and which loopback port serves it.
type Site struct {
	Slug    string
	Domains []string
	Port    int
}

// Render produces the Caddyfile text for box. Deterministic: sites are emitted
// in slug order, domains within a site are sorted — same input → byte-identical
// output, so a no-op rerender doesn't churn the on-disk file or trigger a
// pointless Caddy reload.
func Render(box Box) string {
	var sb strings.Builder

	// Global block: on_demand_tls + ask gate.
	if box.AskGateURL != "" {
		sb.WriteString("{\n")
		sb.WriteString("  on_demand_tls {\n")
		fmt.Fprintf(&sb, "    ask %s\n", box.AskGateURL)
		sb.WriteString("  }\n")
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

	for _, s := range sites {
		// Filter customer-supplied domains: a hostile or malformed domain
		// spliced verbatim into the host key would break Caddyfile syntax
		// (one bad domain fails the whole file) or inject directives.
		var clean []string
		for _, d := range s.Domains {
			if validDomain(d) {
				clean = append(clean, d)
			}
		}
		if len(clean) == 0 || s.Port <= 0 {
			continue
		}
		sort.Strings(clean)

		fmt.Fprintf(&sb, "# site %s (port %d)\n", s.Slug, s.Port)
		fmt.Fprintf(&sb, "%s {\n", strings.Join(clean, ", "))
		sb.WriteString("  tls {\n")
		sb.WriteString("    on_demand\n")
		sb.WriteString("  }\n")
		fmt.Fprintf(&sb, "  reverse_proxy 127.0.0.1:%d\n", s.Port)
		sb.WriteString(MaintenanceHandler("  "))
		sb.WriteString("}\n\n")
	}

	return sb.String()
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
