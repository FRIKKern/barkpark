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
	return true
}
