package manifest

import (
	"fmt"
	"net/http"
	"strings"
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

	url := client.BaseURL() + CapabilitiesPath

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
