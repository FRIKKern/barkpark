package manifest

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/apierr"
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
//
// THE CACHE IS ALSO A FALLBACK, NOT ONLY A FAST PATH (task-154120e78138085a).
// /v1/capabilities is the FIRST call every bp invocation makes, so any refusal
// on it kills the real command before it is ever attempted — measured on
// 2026-08-23, a `bp task close` carrying two thousand bytes of evidence died on
// a 429 for a write the server never received. When the network cannot be
// reached or answers 429/5xx AND a validated manifest for this exact key is
// already on disk, Fetch serves that manifest with one stderr notice instead of
// failing the command. A 401/403 is NOT covered: a rejected credential is an
// answer about the CALLER, and papering over it with a cache minted by a token
// that still worked would let a revoked token keep driving a full command tree.
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

	res, err := client.GetConditionalCallerOwnsBackpressure(url, cachedETag)

	// ONE retry on 429, and only when the server named a wait we are willing to
	// serve (see retryAfterDelay). The row that filed this measured the server
	// sending {"details":{"retry_after":1}} and the client discarding it: three
	// consecutive closes, two dead, the third identical and fine. A single
	// re-ask after the interval the refusal itself named is the difference. It
	// is deliberately ONE retry — this is a rate limiter, and the correct
	// response to "too many requests" is emphatically not more of them.
	if err == nil && res.StatusCode == http.StatusTooManyRequests {
		if delay, ok := retryAfterDelay(res); ok {
			time.Sleep(delay)
			// A transport failure on the retry keeps the ORIGINAL 429: the
			// server already told us something specific, and reporting a
			// dial error instead would lose the diagnosis. Either way the
			// cache fallback below still applies.
			if retried, rerr := client.GetConditionalCallerOwnsBackpressure(url, cachedETag); rerr == nil {
				res = retried
			}
		}
	}

	if err != nil {
		// Transport failure (DNS, dial, timeout). A cached manifest is a
		// perfectly good command tree; the command's own request will fail on
		// its own terms if the network really is gone, and it will say so about
		// the request the operator actually made.
		if haveCacheHit {
			warnServingCachedManifest(client.BaseURL(), fmt.Sprintf("the request failed (%v)", err))
			return cachedM, nil
		}
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
			// Downgrade guard: catches a genuinely OLDER 200 body than the one
			// we already have cached — clock skew between replicas, or a
			// replayed stale cached body reaching us through some intermediary.
			// It does NOT catch a rolled-back deploy: api/lib/barkpark/plugins/
			// capabilities.ex:230-231 stamps generated_at with DateTime.utc_now()
			// at manifest-BUILD time, and capabilities_controller.ex:60 calls
			// Capabilities.manifest/2 per request with no memoization anywhere
			// in that module — so a rolled-back server re-stamps a FRESH
			// timestamp on every request and never looks "older" here. That
			// hazard is real but invisible at this layer; this guard's job is
			// narrower: never let a body we can prove is older silently
			// overwrite the cache. cachedGen, ok=false means either no cache
			// hit or a legacy cacheEntry with no recorded generation (see
			// CachedGeneration) — "unknown," so we proceed exactly as before.
			// Equal-or-newer also proceeds exactly as before.
			if cachedGen, _, ok := cache.CachedGeneration(key); ok && isOlderGeneration(m.GeneratedAt, cachedGen) {
				fmt.Fprintf(os.Stderr,
					"bp: refusing capabilities manifest from %s — it is OLDER than the cached one (incoming generated_at=%s, cached generated_at=%s); keeping the cached manifest and not overwriting the cache\n",
					client.BaseURL(), m.GeneratedAt, cachedGen)
				// Keep the cached manifest rather than failing the command: a
				// downgrade here is most likely clock skew, not a broken
				// server, and the caller just wants a usable manifest. We never
				// Store() the older body (the cache must not be overwritten by
				// it) and we never return an error from this branch — a stale
				// command tree answer beats no answer at all. If the cached
				// entry fails to load back (shouldn't happen; Store validates
				// before writing) we fall back to the freshly-parsed body
				// rather than fail the call outright.
				if cachedM, _, ok := cache.Load(key); ok {
					return cachedM, nil
				}
				return m, nil
			}
			etag := res.ETag
			if etag == "" {
				etag = m.ETag // fall back to the manifest's own etag field
			}
			_ = cache.Store(key, res.Body, etag)
		}
		return m, nil
	default:
		// A refusal we can ride out on the cache: the server is overloaded or
		// broken, not saying anything about who we are. Serve the cached
		// manifest so the command the operator typed gets to run.
		if haveCacheHit && servableFromCacheOnStatus(res.StatusCode) {
			warnServingCachedManifest(client.BaseURL(), fmt.Sprintf("it answered %d", res.StatusCode))
			return cachedM, nil
		}
		// The server's explanatory envelope is sitting in res.Body (already
		// bounded upstream by GetConditional's maxManifestBytes LimitReader) —
		// surface it instead of a zero-diagnostic dead end. GET /v1/capabilities
		// is the FIRST call bp makes, so a bad token or broken server needs to
		// say *why*, not just "401".
		msg := strings.TrimSpace(string(res.Body))
		if msg != "" {
			return nil, &StatusError{Status: res.StatusCode, Body: clampErrBody(msg)}
		}
		return nil, &StatusError{Status: res.StatusCode}
	}
}

// StatusError is the refusal Fetch returns when the server answered a status it
// cannot ride out on the cache. It carries the STATUS as a field, not only in
// the message, because the one caller that must tell an authentication refusal
// (401/403) apart from every other failure — `bp whoami`, deciding whether a
// shell env token just shadowed a working saved credential — otherwise has to
// scrape the number back out of English. Error() is byte-identical to the two
// fmt.Errorf strings this replaced, so every message assertion still holds.
type StatusError struct {
	Status int
	Body   string // already clamped by clampErrBody; may be empty
}

func (e *StatusError) Error() string {
	if e.Body != "" {
		return fmt.Sprintf("fetch manifest: unexpected status %d — %s", e.Status, e.Body)
	}
	return fmt.Sprintf("fetch manifest: unexpected status %d", e.Status)
}

// Unauthenticated reports whether the server REFUSED the credential (401/403) —
// as opposed to being down, overloaded, or absent. nil is false: "we never
// asked" is not "the credential was rejected".
func (e *StatusError) Unauthenticated() bool {
	return e != nil && (e.Status == http.StatusUnauthorized || e.Status == http.StatusForbidden)
}

// retryAfterCap bounds the wait Fetch will sit through on a 429. Two seconds is
// chosen against the two sides of the trade: the measured refusal named
// retry_after: 1, so the real case fits comfortably; and this sleep rides inside
// an interactive CLI call that has not yet run the command the operator typed.
//
// A LONGER DIRECTIVE IS NOT CLAMPED DOWN TO THE CAP — it is declined outright,
// and Fetch falls through to the cache (or to the honest 429 error). Clamping
// would re-ask at 2s a server that just said "wait 60", which is precisely the
// hammering the retry exists to avoid; "I cannot wait that long" is an honest
// answer and "I will wait a thirtieth of what you asked" is not.
const retryAfterCap = 2 * time.Second

// retryAfterDelay reads the wait a 429 named, from the Retry-After header first
// and the error envelope's details.retry_after second (the shape the Barkpark
// API actually sends: {"error":{"code":"rate_limited","details":{"retry_after":1}}}).
//
// ok=false means DO NOT RETRY, and it covers every case where a retry would be
// a guess rather than an instruction: no header and no envelope field, a header
// in the HTTP-date form (declined deliberately — parsing a date to decide a
// sub-second sleep buys nothing and mis-parsing it buys a stall), a negative or
// NaN value, or a value larger than retryAfterCap. Absence is never treated as
// "retry immediately": a limiter that did not say when is a limiter to leave
// alone.
func retryAfterDelay(res *apiclient.ConditionalGetResult) (time.Duration, bool) {
	if res == nil {
		return 0, false
	}
	if secs, ok := headerRetryAfterSeconds(res.RetryAfter); ok {
		return boundedRetryDelay(secs)
	}
	if env, ok := apierr.Parse(res.Body); ok {
		if secs, ok := env.RetryAfterSeconds(); ok {
			return boundedRetryDelay(secs)
		}
	}
	return 0, false
}

// headerRetryAfterSeconds reads the delta-seconds form of Retry-After. The
// HTTP-date form returns ok=false (see retryAfterDelay).
func headerRetryAfterSeconds(h string) (float64, bool) {
	h = strings.TrimSpace(h)
	if h == "" {
		return 0, false
	}
	n, err := strconv.Atoi(h)
	if err != nil {
		return 0, false
	}
	return float64(n), true
}

// boundedRetryDelay turns a server-named second count into a wait, refusing
// anything negative, NaN (the !(secs >= 0) form catches both) or over the cap.
// The bound is checked in SECONDS, before the multiply, so an absurd value can
// never overflow the float→Duration conversion into a plausible-looking wait.
func boundedRetryDelay(secs float64) (time.Duration, bool) {
	if !(secs >= 0) {
		return 0, false
	}
	if secs > retryAfterCap.Seconds() {
		return 0, false
	}
	return time.Duration(secs * float64(time.Second)), true
}

// servableFromCacheOnStatus reports whether a cached manifest may stand in for a
// response with this status.
//
// The line is drawn at WHAT THE STATUS IS ABOUT. 429 and 5xx are statements
// about the SERVER's current condition — load, a bad deploy, a sick replica —
// and say nothing that invalidates a manifest the same server minted for this
// same key earlier. 401 and 403 are statements about the CALLER, and the cache
// is keyed by a hash of the token: serving one would let a revoked or expired
// credential keep driving the full command tree its old token earned, turning a
// crisp "your token was rejected" into a command that fails later and stranger.
// 404 is excluded too — /v1/capabilities not being deployed is exactly what the
// --manifest / BARKPARK_MANIFEST escape hatch is for, and it must keep saying so.
func servableFromCacheOnStatus(status int) bool {
	return status == http.StatusTooManyRequests || (status >= 500 && status <= 599)
}

// warnServingCachedManifest emits the ONE line that says a cached command tree
// is standing in for a live one. On stderr, always: stdout carries `-o json`
// and a notice there would corrupt every machine-readable result. It does not
// touch the exit code either — the command the operator typed runs, and
// succeeds or fails on its own merits.
func warnServingCachedManifest(baseURL, because string) {
	fmt.Fprintf(os.Stderr,
		"bp: could not refresh the capabilities manifest from %s — %s; using the cached manifest (it may be stale, and the command itself is unaffected)\n",
		baseURL, because)
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
