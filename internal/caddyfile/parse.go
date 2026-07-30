package caddyfile

// Caddyfile state recovery + foreign-preserving rewrite for the on-box runtime
// executor.
//
// The executor is NOT the only writer of /etc/caddy/Caddyfile: the provisioner
// creates the instance API/Studio vhost, attach-domain appends custom-host
// vhosts, and operators repair things by hand. The executor therefore treats
// the file as shared ground:
//
//   - Parse reconstructs the executor's state from disk — every block carrying
//     a runtime marker comment comes back as a Site (slug, domains, upstream
//     port, kind, TLS mode), and every loopback upstream port claimed by an
//     UNMARKED block is reported as foreign so the port allocator never
//     collides with it (the instance API vhost proxies 127.0.0.1:4000).
//
//   - Rewrite regenerates ONLY the runtime-managed blocks. Any block without a
//     runtime marker is foreign and immutable: it survives the rewrite
//     byte-identical, in place. The previous MVP re-rendered the whole file
//     from scratch, which deleted every foreign vhost on the box.
//
// The marker convention mirrors the provisioner's attach-domain convention
// ("# Managed by barkpark-provisioner (attach-domain) — …"): one marker
// comment line directly above the block it owns. The legacy header the old
// renderer emitted ("# site <slug> (port <n>)") is also recognized as managed,
// so blocks written before the marker existed are recovered and upgraded
// rather than duplicated.
//
// The parser is deliberately pragmatic, tuned to the Caddyfile dialect this
// repo emits: line-based, brace-depth tracked outside double quotes, heredoc
// bodies (`<<TOKEN` … flush-left `TOKEN`, the maintenance-page idiom) treated
// as literal so their HTML/CSS braces never perturb the depth. Anything it
// cannot positively identify as runtime-managed it leaves untouched — the
// fail-safe direction for a shared file.

import (
	"bytes"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// ManagedMarkerPrefix opens the marker comment stamped directly above every
// site block the runtime owns. A block WITHOUT a runtime marker is foreign:
// Parse never returns it as a Site and Rewrite preserves it byte-identical.
const ManagedMarkerPrefix = "# Managed by barkpark-runtime"

var (
	// managedMarkerRe matches the current marker line and captures the slug.
	managedMarkerRe = regexp.MustCompile(`^# Managed by barkpark-runtime — site (\S+) \((?:port \d+|static \S+)\)\. Do not edit by hand\.$`)
	// legacyMarkerRe matches the header the pre-marker renderer emitted. Blocks
	// under it are runtime-written, so they must be recovered as managed —
	// treating them as foreign would preserve them AND append a fresh block for
	// the same slug, a duplicate site address that wedges every Caddy reload.
	legacyMarkerRe = regexp.MustCompile(`^# site (\S+) \((?:port \d+|static \S+)\)$`)

	// upstreamRe extracts the loopback upstream port from a reverse_proxy line.
	upstreamRe = regexp.MustCompile(`^reverse_proxy\s+(?:127\.0\.0\.1|localhost):(\d+)\b`)
	// rootRe extracts a static site's served directory.
	rootRe = regexp.MustCompile(`^root \* (\S+)$`)
	// tlsFilesRe matches the Origin-CA form `tls <cert> <key>` (two path args —
	// `tls internal` and the `tls {` block opener both have one and never match).
	tlsFilesRe = regexp.MustCompile(`^tls (\S+) (\S+)$`)
)

// managedMarker renders the marker comment for s (no trailing newline).
func managedMarker(s Site) string {
	if s.isStatic() {
		return fmt.Sprintf("%s — site %s (static %s). Do not edit by hand.", ManagedMarkerPrefix, s.Slug, s.Root)
	}
	return fmt.Sprintf("%s — site %s (port %d). Do not edit by hand.", ManagedMarkerPrefix, s.Slug, s.Port)
}

// Parsed is what Parse recovers from an on-disk Caddyfile.
type Parsed struct {
	// Sites are the runtime-managed blocks (marker-carrying), in file order.
	Sites []Site
	// ForeignPorts are the loopback upstream ports claimed by blocks the
	// runtime does NOT manage — e.g. the instance API/Studio vhost proxying
	// 127.0.0.1:4000, or an attach-domain vhost the provisioner appended. The
	// port allocator must treat every one of them as in use.
	ForeignPorts map[int]bool
}

// Parse reconstructs runtime state from the raw Caddyfile bytes. It never
// fails: unrecognizable content is simply not managed, which is the safe
// reading for a shared file.
func Parse(src []byte) Parsed {
	p := Parsed{ForeignPorts: map[int]bool{}}
	for _, seg := range parseSegments(string(src)) {
		if seg.managed {
			p.Sites = append(p.Sites, siteFromSegment(seg))
			continue
		}
		for _, ln := range seg.codeLines {
			if m := upstreamRe.FindStringSubmatch(ln); m != nil {
				port, _ := strconv.Atoi(m[1])
				p.ForeignPorts[port] = true
			}
		}
	}
	return p
}

// Rewrite regenerates the Caddyfile so it serves box.Sites while preserving,
// byte-identical and in place, every block the runtime does not manage. A
// managed block whose slug is still in box.Sites is re-rendered where it
// stands; a slug no longer present is dropped; a slug with no existing block
// is appended at the end (slug-sorted). A domain already claimed by a foreign
// block is never emitted in a managed block — a duplicate site address makes
// Caddy reject the whole config and wedge every vhost on the box.
//
// An empty (or missing) previous file falls back to the full Render, which
// carries the global ask-gate and studio blocks; on a non-empty file those
// blocks already exist — whoever wrote them owns them — and are preserved as
// foreign content like everything else.
func Rewrite(prev []byte, box Box) []byte {
	if len(bytes.TrimSpace(prev)) == 0 {
		return []byte(Render(box))
	}
	segs := parseSegments(string(prev))

	// Domains owned by foreign blocks are off-limits to managed rendering.
	seen := map[string]bool{}
	for _, seg := range segs {
		if seg.managed {
			continue
		}
		for _, d := range addressesOf(seg.addrLine) {
			seen[d] = true
		}
	}

	bySlug := map[string]Site{}
	for _, s := range box.Sites {
		bySlug[s.Slug] = s
	}

	var sb strings.Builder
	emitted := map[string]bool{}
	for _, seg := range segs {
		if !seg.managed {
			sb.WriteString(seg.text)
			continue
		}
		s, ok := bySlug[seg.slug]
		if !ok || emitted[seg.slug] {
			continue // site removed, or a duplicate managed block — drop it
		}
		var block strings.Builder
		if writeSiteBlock(&block, s, seen) {
			emitted[seg.slug] = true
			sb.WriteString(seg.blanks) // keep the original inter-block spacing
			sb.WriteString(block.String())
		}
	}

	// Append sites that had no existing managed block, slug-sorted for
	// determinism (same input → byte-identical output, no reload churn).
	fresh := make([]Site, 0, len(box.Sites))
	for _, s := range box.Sites {
		if !emitted[s.Slug] {
			fresh = append(fresh, s)
		}
	}
	sort.Slice(fresh, func(i, j int) bool { return fresh[i].Slug < fresh[j].Slug })
	for _, s := range fresh {
		var block strings.Builder
		if writeSiteBlock(&block, s, seen) {
			if out := sb.String(); out != "" && !strings.HasSuffix(out, "\n") {
				sb.WriteString("\n")
			}
			sb.WriteString("\n")
			sb.WriteString(block.String())
		}
	}
	return []byte(sb.String())
}

// segment is one top-level unit of the file: a run of comment/blank lines, or
// a block (its preceding comment lines included) from its address line through
// its closing brace.
type segment struct {
	text      string   // raw bytes, preserved verbatim for foreign segments
	blanks    string   // leading whitespace-only lines (kept when replacing)
	managed   bool     // a runtime marker precedes the block
	slug      string   // slug captured from the marker (managed only)
	addrLine  string   // trimmed first line of the block, e.g. "a.com, b.com {"
	codeLines []string // trimmed non-comment, non-heredoc lines inside the block
}

// parseSegments splits src into top-level segments. Concatenating every
// segment's text reproduces src byte-identically.
func parseSegments(src string) []segment {
	var (
		segs    []segment
		prefix  []string // pending depth-0 comment/blank lines
		cur     *segment
		depth   int
		heredoc string // active heredoc delimiter, "" when none
	)
	seal := func() {
		segs = append(segs, *cur)
		cur = nil
	}

	for _, line := range splitKeepNewlines(src) {
		if cur != nil && heredoc != "" {
			cur.text += line
			if strings.TrimRight(line, "\r\n") == heredoc {
				heredoc = ""
			}
			continue
		}
		trimmed := strings.TrimSpace(line)
		if cur == nil {
			if trimmed == "" || strings.HasPrefix(trimmed, "#") {
				prefix = append(prefix, line)
				continue
			}
			// A content line at depth 0 opens a block segment; the pending
			// comment lines belong to it (that is where its marker lives).
			cur = &segment{text: strings.Join(prefix, ""), addrLine: trimmed}
			for _, p := range prefix {
				if strings.TrimSpace(p) != "" {
					break
				}
				cur.blanks += p
			}
			for _, p := range prefix {
				pc := strings.TrimSpace(p)
				if m := managedMarkerRe.FindStringSubmatch(pc); m != nil {
					cur.managed, cur.slug = true, m[1]
				} else if m := legacyMarkerRe.FindStringSubmatch(pc); m != nil {
					cur.managed, cur.slug = true, m[1]
				}
			}
			prefix = nil
		} else if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			cur.codeLines = append(cur.codeLines, trimmed)
		}
		cur.text += line

		delta, hd := scanBraces(line)
		depth += delta
		if hd != "" {
			heredoc = hd
			continue
		}
		if depth <= 0 {
			depth = 0
			seal()
		}
	}
	if cur != nil {
		seal() // unterminated block — carry it through untouched
	}
	if len(prefix) > 0 {
		segs = append(segs, segment{text: strings.Join(prefix, "")})
	}
	return segs
}

// scanBraces returns the brace-depth delta of line and, when its last code
// token opens a heredoc (`<<TOKEN`), the heredoc delimiter. Braces inside
// double quotes are literal; a `#` at line start or after whitespace starts a
// comment that ends the code portion.
func scanBraces(line string) (int, string) {
	delta := 0
	code := line
	inQuote := false
scan:
	for i := 0; i < len(line); i++ {
		switch c := line[i]; {
		case c == '"':
			inQuote = !inQuote
		case inQuote:
			// quoted content is literal
		case c == '{':
			delta++
		case c == '}':
			delta--
		case c == '#' && (i == 0 || line[i-1] == ' ' || line[i-1] == '\t'):
			code = line[:i]
			break scan
		}
	}
	fields := strings.Fields(code)
	if n := len(fields); n > 0 {
		if last := fields[n-1]; len(last) > 2 && strings.HasPrefix(last, "<<") {
			return delta, strings.TrimPrefix(last, "<<")
		}
	}
	return delta, ""
}

// siteFromSegment recovers the Site a managed segment describes: domains from
// the address line, then port / static root / TLS mode from the block body.
// TLS recovery matters: a rewrite that lost a site's `tls internal` would
// silently downgrade a Cloudflare-proxied origin to on-demand ACME — the 526
// outage that mode exists to prevent.
func siteFromSegment(seg segment) Site {
	s := Site{Slug: seg.slug, Domains: addressesOf(seg.addrLine)}
	for _, ln := range seg.codeLines {
		switch {
		case ln == "tls internal":
			s.TLSMode = TLSModeInternal
		default:
			if m := upstreamRe.FindStringSubmatch(ln); m != nil {
				s.Port, _ = strconv.Atoi(m[1])
			} else if m := rootRe.FindStringSubmatch(ln); m != nil {
				s.Kind, s.Root = KindStatic, m[1]
			} else if m := tlsFilesRe.FindStringSubmatch(ln); m != nil {
				s.TLSMode, s.CertPath, s.KeyPath = TLSModeOriginCA, m[1], m[2]
			}
		}
	}
	return s
}

// addressesOf splits a block's address line ("a.com, b.com {") into its
// comma-separated addresses. The global-options opener ("{") yields none.
func addressesOf(addrLine string) []string {
	addr := strings.TrimSpace(strings.TrimSuffix(addrLine, "{"))
	if addr == "" {
		return nil
	}
	var out []string
	for _, d := range strings.Split(addr, ",") {
		if d = strings.TrimSpace(d); d != "" {
			out = append(out, d)
		}
	}
	return out
}

// splitKeepNewlines splits s into lines, each retaining its trailing "\n",
// so re-joining reproduces s byte-identically.
func splitKeepNewlines(s string) []string {
	var out []string
	for len(s) > 0 {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			out = append(out, s)
			break
		}
		out = append(out, s[:i+1])
		s = s[i+1:]
	}
	return out
}
