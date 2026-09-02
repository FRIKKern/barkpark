package cli

// mcp_ratelimit.go — the per-client-IP token bucket that fronts the
// `bp mcp serve --http` listener.
//
// WHY IN-PROCESS, NOT CADDY. The obvious place for a rate limit is the reverse
// proxy, and the ruling that opened this work asked for exactly that: a
// `rate_limit` block on the armed /mcp route. It cannot be had. Caddy's
// `rate_limit` directive is the THIRD-PARTY module mholt/caddy-ratelimit, not
// part of the stock binary: the fleet runs stock Debian caddy 2.11.4, whose
// `caddy list-modules` carries no rate module, and so does the Mac that runs
// deploy/instance-deploy_test.sh. An armed `rate_limit` block therefore fails
// `caddy validate` on every box AND in the harness — the config would not load
// at all, taking the whole site down, not just the limit. A custom xcaddy fleet
// build was ruled out: a permanent build-and-patch tax on every host for an
// availability-only clamp on one loopback-bound route. So the intent moves
// inside our own binary, where it costs one file and no new dependency.
//
// WHAT IT BUYS. The --http endpoint is unauthenticated at the transport layer
// by design (forward-through bearer, charter D18): every peer that reaches the
// port gets a request served before any credential is looked at, and in
// stateless mode the SDK rebuilds the whole MCP server per request. #15235 armed
// read/idle/header deadlines there, which bound per-CONNECTION time; they do
// nothing about a peer that sends perfectly well-formed requests as fast as it
// can. The bucket is what bounds request RATE.
//
// THE KEY IS THE PROXY-SET IP, AND ONLY FROM A PROXY. X-Forwarded-For is
// client-writable: anyone can send `X-Forwarded-For: <random>` and mint a fresh
// bucket per request, which would make the limiter worse than nothing. So the
// header is read ONLY when the socket peer is itself a trusted proxy (default:
// loopback, which is the deploy shape — Caddy and bp on the same box, bp bound
// to 127.0.0.1:4010, charter D19). From a trusted proxy we take the LAST hop,
// because a proxy APPENDS the peer it actually saw to whatever the client sent:
// in `X-Forwarded-For: 1.2.3.4, 9.9.9.9` the client wrote 1.2.3.4 and Caddy
// appended 9.9.9.9, so 9.9.9.9 is the only value in that header no client could
// choose. From any other peer the header is ignored entirely and the TCP peer
// address is the key.
//
// AN ESTABLISHED SSE STREAM IS NEVER KILLED. The decision is taken once, before
// the handler runs; a request that is admitted is never revisited. So a POST
// /mcp whose response is a long-lived text/event-stream keeps streaming to
// completion even if the same IP's bucket empties meanwhile — the same reason
// WriteTimeout is deliberately zero on this server (newMCPHTTPServer).
//
// MEMORY IS BOUNDED. A flood of distinct source IPs would otherwise grow the
// bucket map without limit — a memory exhaustion vector handed to the attacker
// by the defence. Buckets idle past mcpRateIdleTTL are swept, and if the map is
// still at mcpRateMaxBuckets the least-recently-seen half is evicted. Evicting a
// bucket is safe: a fresh bucket starts FULL, so the worst case of over-eager
// eviction is that an attacker gets one extra burst — never a wrong refusal of a
// legitimate client.

import (
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Documented defaults. An MCP client is interactive: a human or an agent making
// tool calls, not a firehose. 5 requests/second sustained with a 20-request
// burst absorbs a client that fans out a handful of tools at once and still
// clamps a flood by two orders of magnitude.
const (
	// mcpRateDefaultRate is the sustained refill in requests per second per IP.
	mcpRateDefaultRate = 5.0
	// mcpRateDefaultBurst is the bucket depth: how many requests one IP may make
	// back-to-back from a full bucket before the sustained rate binds.
	mcpRateDefaultBurst = 20.0
	// mcpRateMaxBuckets caps the tracking map. ~4k live IPs is far beyond any
	// legitimate use of a loopback-proxied MCP shim, and the map is a few hundred
	// KB at that size.
	mcpRateMaxBuckets = 4096
	// mcpRateIdleTTL is how long an untouched bucket survives a sweep. Well past
	// the time a full-depth bucket takes to refill, so sweeping never discards
	// state that was still doing work.
	mcpRateIdleTTL = 10 * time.Minute
	// mcpRateLogEvery is the log window: at most ONE line per offending IP per
	// window, carrying the count of refusals suppressed since the last line. A
	// line per refused request would let the flood write the disk full — the
	// limiter would become the amplifier.
	mcpRateLogEvery = time.Minute
)

// Environment overrides. Flags are deliberately not added: `bp mcp serve --http`
// runs from a systemd unit in the deploy shape, where an Environment= line is
// the natural knob, and parseMCPServeArgs stays the small surface it is.
const (
	// mcpRateEnvRate sets the sustained per-IP rate in requests/second.
	// "0" (or any value <= 0) DISABLES the limiter entirely — the escape hatch
	// for an operator whose traffic shape the defaults get wrong.
	mcpRateEnvRate = "BARKPARK_MCP_RATE"
	// mcpRateEnvBurst sets the bucket depth in requests.
	mcpRateEnvBurst = "BARKPARK_MCP_BURST"
	// mcpRateEnvTrustedProxies is a comma-separated CIDR list of peers whose
	// X-Forwarded-For is believed. Default: loopback only.
	mcpRateEnvTrustedProxies = "BARKPARK_MCP_TRUSTED_PROXIES"
)

// mcpRateDefaultTrustedProxies is the default trusted-proxy set: loopback only,
// which is exactly the deploy shape (Caddy → 127.0.0.1:4010).
var mcpRateDefaultTrustedProxies = []string{"127.0.0.0/8", "::1/128"}

// mcpRateBucket is one IP's token bucket plus its log bookkeeping. tokens is
// lazily refilled on read (see take), so there is no sweeper goroutine.
type mcpRateBucket struct {
	tokens     float64
	refilledAt time.Time
	seenAt     time.Time
	loggedAt   time.Time
	suppressed int
}

// mcpRateLimiter is an in-process per-IP token bucket. The zero value is not
// usable; build one with newMCPRateLimiter or newMCPRateLimiterFromEnv.
type mcpRateLimiter struct {
	rate    float64 // tokens per second
	burst   float64 // bucket depth
	trusted []*net.IPNet
	now     func() time.Time
	logf    func(format string, args ...any)

	mu      sync.Mutex
	buckets map[string]*mcpRateBucket
}

// newMCPRateLimiter builds a limiter with the given rate/burst and the default
// loopback trusted-proxy set. A rate or burst that is not positive yields nil —
// the disabled limiter, which middleware passes straight through.
func newMCPRateLimiter(rate, burst float64, logf func(string, ...any)) *mcpRateLimiter {
	if rate <= 0 || burst <= 0 {
		return nil
	}
	return &mcpRateLimiter{
		rate:    rate,
		burst:   burst,
		trusted: parseMCPRateCIDRs(mcpRateDefaultTrustedProxies),
		now:     time.Now,
		logf:    logf,
		buckets: make(map[string]*mcpRateBucket),
	}
}

// newMCPRateLimiterFromEnv builds the limiter the --http listener actually uses,
// reading the documented environment overrides. Returns nil when disabled
// (BARKPARK_MCP_RATE=0), which is a pass-through, not an error: an operator who
// turns the clamp off gets exactly the pre-#15235 behaviour and no surprises.
// A malformed value is reported on stderr and the default is used — a typo in a
// unit file must not take the endpoint down.
func newMCPRateLimiterFromEnv(logf func(string, ...any)) *mcpRateLimiter {
	rate := mcpRateEnvFloat(mcpRateEnvRate, mcpRateDefaultRate, logf)
	burst := mcpRateEnvFloat(mcpRateEnvBurst, mcpRateDefaultBurst, logf)
	l := newMCPRateLimiter(rate, burst, logf)
	if l == nil {
		return nil
	}
	if raw := strings.TrimSpace(os.Getenv(mcpRateEnvTrustedProxies)); raw != "" {
		nets := parseMCPRateCIDRs(strings.Split(raw, ","))
		if len(nets) == 0 && logf != nil {
			logf("mcp serve: %s=%q parsed to no usable CIDR — keeping the loopback default", mcpRateEnvTrustedProxies, raw)
		} else {
			l.trusted = nets
		}
	}
	return l
}

// mcpRateEnvFloat reads a non-negative float from the environment, falling back
// to def on absence or on a malformed value (loudly, so the typo is findable).
func mcpRateEnvFloat(name string, def float64, logf func(string, ...any)) float64 {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil || v < 0 || math.IsNaN(v) || math.IsInf(v, 0) {
		if logf != nil {
			logf("mcp serve: ignoring %s=%q (want a number >= 0) — using %g", name, raw, def)
		}
		return def
	}
	return v
}

// parseMCPRateCIDRs turns CIDR strings into networks, skipping anything
// unparseable. A bare IP ("10.0.0.7") is accepted as a /32 or /128.
func parseMCPRateCIDRs(in []string) []*net.IPNet {
	var out []*net.IPNet
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, n, err := net.ParseCIDR(s); err == nil {
			out = append(out, n)
			continue
		}
		if ip := net.ParseIP(s); ip != nil {
			bits := 32
			if ip.To4() == nil {
				bits = 128
			}
			out = append(out, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
		}
	}
	return out
}

// trustedPeer reports whether ip is a proxy whose X-Forwarded-For we believe.
func (l *mcpRateLimiter) trustedPeer(ip net.IP) bool {
	for _, n := range l.trusted {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// clientIP is the limiter's key for req: the proxy-set client IP when the socket
// peer is a trusted proxy, otherwise the socket peer itself. A header from an
// untrusted peer is IGNORED — believing it would let any caller mint a fresh
// bucket per request and defeat the limit completely.
func (l *mcpRateLimiter) clientIP(req *http.Request) string {
	host := req.RemoteAddr
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.TrimSpace(host)
	peer := net.ParseIP(host)
	if peer == nil {
		// Not an IP (a unix socket, a test's opaque RemoteAddr): key on it
		// verbatim rather than lumping every such peer under one bucket.
		return host
	}
	if !l.trustedPeer(peer) {
		return peer.String()
	}
	if hop := lastForwardedHop(req.Header.Values("X-Forwarded-For")); hop != "" {
		return hop
	}
	return peer.String()
}

// lastForwardedHop returns the LAST entry of the X-Forwarded-For chain — the hop
// the trusted proxy appended, i.e. the peer IT actually saw. Every earlier entry
// is client-supplied and must never be the key. Returns "" when no entry parses
// as an IP, in which case the caller falls back to the socket peer.
func lastForwardedHop(values []string) string {
	for i := len(values) - 1; i >= 0; i-- {
		parts := strings.Split(values[i], ",")
		for j := len(parts) - 1; j >= 0; j-- {
			c := strings.TrimSpace(parts[j])
			if c == "" {
				continue
			}
			// Tolerate a hop written with a port ("9.9.9.9:1234", "[::1]:80").
			if h, _, err := net.SplitHostPort(c); err == nil {
				c = h
			}
			c = strings.Trim(c, "[]")
			if ip := net.ParseIP(c); ip != nil {
				return ip.String()
			}
			return "" // a malformed last hop is not a licence to read an earlier one
		}
	}
	return ""
}

// take spends one token for key. It returns ok=false when the bucket is empty,
// with retryAfter = how long until one token exists (never below a second, so a
// well-behaved client's Retry-After is always actionable), and logLine set on
// the first refusal in the current log window (empty otherwise).
func (l *mcpRateLimiter) take(key string) (ok bool, retryAfter time.Duration, logLine string) {
	now := l.now()

	l.mu.Lock()
	defer l.mu.Unlock()

	b := l.buckets[key]
	if b == nil {
		l.evictLocked(now)
		b = &mcpRateBucket{tokens: l.burst, refilledAt: now}
		l.buckets[key] = b
	} else if d := now.Sub(b.refilledAt); d > 0 {
		b.tokens = math.Min(l.burst, b.tokens+d.Seconds()*l.rate)
		b.refilledAt = now
	}
	b.seenAt = now

	if b.tokens >= 1 {
		b.tokens--
		return true, 0, ""
	}

	// Refused. Retry-After is the time to one whole token, rounded up.
	secs := (1 - b.tokens) / l.rate
	retryAfter = time.Duration(math.Ceil(secs)) * time.Second
	if retryAfter < time.Second {
		retryAfter = time.Second
	}

	b.suppressed++
	if b.loggedAt.IsZero() || now.Sub(b.loggedAt) >= mcpRateLogEvery {
		logLine = fmt.Sprintf(
			"mcp serve: RATE LIMITED %s — %d request(s) refused with 429 since the last line (limit %g/s, burst %g); retry after %s. Set %s=0 to disable the clamp.",
			key, b.suppressed, l.rate, l.burst, retryAfter, mcpRateEnvRate)
		b.loggedAt = now
		b.suppressed = 0
	}
	return false, retryAfter, logLine
}

// evictLocked keeps the bucket map bounded before a new key is inserted. First
// it drops everything idle past the TTL; if that is not enough it drops the
// least-recently-seen half. Caller holds l.mu.
func (l *mcpRateLimiter) evictLocked(now time.Time) {
	if len(l.buckets) < mcpRateMaxBuckets {
		return
	}
	for k, b := range l.buckets {
		if now.Sub(b.seenAt) > mcpRateIdleTTL {
			delete(l.buckets, k)
		}
	}
	if len(l.buckets) < mcpRateMaxBuckets {
		return
	}
	// Still full of ACTIVE keys — a live flood of distinct sources. Drop the
	// oldest half. A dropped attacker gets one extra burst, which is bounded;
	// an unbounded map is not.
	type seen struct {
		key string
		at  time.Time
	}
	all := make([]seen, 0, len(l.buckets))
	for k, b := range l.buckets {
		all = append(all, seen{k, b.seenAt})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].at.Before(all[j].at) })
	for _, s := range all[:len(all)/2] {
		delete(l.buckets, s.key)
	}
}

// size reports how many buckets are tracked (the memory-bound assertion).
func (l *mcpRateLimiter) size() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}

// middleware wraps next in the limiter. A nil limiter is a pass-through, so the
// disabled configuration costs nothing at request time.
//
// The decision is taken ONCE, before next is called: an admitted request — an
// SSE stream that may run for the length of a downstream Barkpark call — is
// never interrupted by a later refusal on the same key.
func (l *mcpRateLimiter) middleware(next http.Handler) http.Handler {
	if l == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		ok, retryAfter, logLine := l.take(l.clientIP(req))
		if ok {
			next.ServeHTTP(w, req)
			return
		}
		if logLine != "" && l.logf != nil {
			l.logf("%s", logLine)
		}
		w.Header().Set("Retry-After", strconv.Itoa(int(retryAfter/time.Second)))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusTooManyRequests)
		fmt.Fprintf(w, "429 too many requests: this MCP endpoint allows %g requests/second per client IP (burst %g). Retry after %d s.\n",
			l.rate, l.burst, int(retryAfter/time.Second))
	})
}
