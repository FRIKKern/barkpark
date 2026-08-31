package manifest

import (
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// CapabilitiesPath is the flat endpoint that emits the manifest. The CLI
// prepends the server base_url (carried by the apiclient.Client).
const CapabilitiesPath = "/v1/capabilities"

// Fetch returns the capabilities manifest for client, using cache as an
// ETag-validated layer:
//
//  1. Compute the cache key from the client's base URL + token salt.
//  2. If a cached entry exists, send GET /v1/capabilities with If-None-Match.
//  3. On 304 Not Modified, return the cached manifest (the server confirmed it
//     is still current) — zero re-parse of a fresh body, the whole point of the
//     ETag dance.
//  4. On 200, parse the fresh body, refresh the cache (best-effort), and return.
//
// A nil cache disables caching: Fetch always does an unconditional GET. Cache
// write failures are swallowed — the cache is an optimisation, never a
// correctness dependency.
func Fetch(client *apiclient.Client, cache *Cache) (*Manifest, error) {
	if client == nil {
		return nil, fmt.Errorf("fetch manifest: nil client")
	}

	// ?views=1 and ?chat=1 are the additive-key opt-ins (charter law 7, the
	// ?build=1 precedent): a server that knows a feature emits its key ONLY to
	// callers that ask, so a stale binary that never sends the param keeps
	// receiving the exact old shape and its strict decode never sees an
	// unknown key. Older servers ignore the params entirely (proven inert —
	// byte-identical 200s). chat=1 rides in the SAME commit that models
	// Manifest.Chat — no bp ever asks for a key it cannot decode.
	url := client.BaseURL() + CapabilitiesPath + "?views=1&chat=1"

	var (
		key          string
		cachedETag   string
		cachedM      *Manifest
		haveCacheHit bool
	)
	if cache != nil {
		key = CacheKey(client.BaseURL(), client.Token())
		cachedM, cachedETag, haveCacheHit = cache.Load(key)
	}

	res, err := client.GetConditional(url, cachedETag)
	if err != nil {
		return nil, fmt.Errorf("fetch manifest: %w", err)
	}

	switch res.StatusCode {
	case http.StatusNotModified:
		if haveCacheHit {
			return cachedM, nil
		}
		// 304 without a cached body is a server/contract violation — we sent
		// no If-None-Match (or the entry vanished). Fail loudly rather than
		// return a nil manifest.
		return nil, fmt.Errorf("fetch manifest: 304 Not Modified but no cached manifest for key")
	case http.StatusOK:
		m, err := Parse(res.Body)
		if err != nil {
			return nil, err
		}
		if cache != nil {
			// Downgrade guard: a stale replica, caching proxy, or rolled-back
			// deploy behind a load balancer can hand us a 200 whose
			// generated_at is OLDER than the manifest we already have cached.
			// Every other failure mode on this path is already loud (see the
			// 304-without-body branch above); silently Store()-ing a backwards
			// manifest was the one exception. cachedGen, ok=false means either
			// no cache hit or a legacy cacheEntry with no recorded generation
			// (see CachedGeneration) — "unknown," so we proceed exactly as
			// before. Equal-or-newer also proceeds exactly as before.
			if cachedGen, _, ok := cache.CachedGeneration(key); ok && isOlderGeneration(m.GeneratedAt, cachedGen) {
				fmt.Fprintf(os.Stderr,
					"bp: refusing capabilities manifest from %s — it is OLDER than the cached one (incoming generated_at=%s, cached generated_at=%s); keeping the cached manifest and not overwriting the cache\n",
					client.BaseURL(), m.GeneratedAt, cachedGen)
				// Fail-closed by convention: bp never silently runs its command
				// tree backwards. We do not fall back to the cached manifest
				// here either — a caller that reached the StatusOK branch sent
				// no If-None-Match match (or the server chose not to 304), so
				// there is no cache-freshness guarantee backing a quiet
				// fallback; refusing forces the anomaly to surface instead of
				// hiding behind an old-but-plausible answer.
				return nil, fmt.Errorf("fetch manifest: refusing downgrade from %s: generated_at %s is older than cached %s", client.BaseURL(), m.GeneratedAt, cachedGen)
			}
			etag := res.ETag
			if etag == "" {
				etag = m.ETag // fall back to the manifest's own etag field
			}
			_ = cache.Store(key, res.Body, etag)
		}
		return m, nil
	default:
		// The server's explanatory envelope is sitting in res.Body (already
		// bounded upstream by GetConditional's maxManifestBytes LimitReader) —
		// surface it instead of a zero-diagnostic dead end. GET /v1/capabilities
		// is the FIRST call bp makes, so a bad token or broken server needs to
		// say *why*, not just "401".
		msg := strings.TrimSpace(string(res.Body))
		if msg != "" {
			return nil, fmt.Errorf("fetch manifest: unexpected status %d — %s", res.StatusCode, clampErrBody(msg))
		}
		return nil, fmt.Errorf("fetch manifest: unexpected status %d", res.StatusCode)
	}
}

// isOlderGeneration reports whether incoming is strictly older than cached.
// Both are manifest generated_at values, expected RFC3339 (time.RFC3339Nano
// also accepts the no-fractional-second form the fixtures use). Either value
// being empty or unparseable means the comparison is UNKNOWN, not "older" —
// isOlderGeneration returns false so the caller proceeds exactly as it did
// before this guard existed, never blocking on a timestamp it can't read.
func isOlderGeneration(incoming, cached string) bool {
	if incoming == "" || cached == "" {
		return false
	}
	in, err := time.Parse(time.RFC3339Nano, incoming)
	if err != nil {
		return false
	}
	ca, err := time.Parse(time.RFC3339Nano, cached)
	if err != nil {
		return false
	}
	return in.Before(ca)
}

// clampErrBody bounds a server body before it lands in an error string, cutting
// on a rune boundary (walk back with utf8.RuneStart so a multi-byte rune is
// never split) and marking truncation with an ellipsis.
func clampErrBody(s string) string {
	const max = 2048
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}
