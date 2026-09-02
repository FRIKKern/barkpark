package manifest

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// THE INCIDENT THIS FILE PINS (task-154120e78138085a). /v1/capabilities is the
// FIRST call every bp invocation makes. On 2026-08-23, roughly ten fleet agents
// plus a lead session writing to guerrilla made that call answer
//
//	{"error":{"code":"rate_limited","message":"too many requests",
//	          "details":{"retry_after":1}}}
//
// and `bp task close` — carrying two thousand bytes of hard-won evidence — died
// there, before the close request was ever attempted. The operator saw a
// rate-limit error for a request the server never received. Two consecutive
// closes failed that way; the third, identical, succeeded.
//
// Every test below counts REQUESTS. A retry proven by "the command eventually
// worked" is not proven, and a cache hit proven by a timing measurement is not
// proven either.

// versionedManifest builds a valid manifest body with a caller-chosen
// manifest_version / generated_at / etag — the three fields the cache's
// invalidation and downgrade paths turn on.
func versionedManifest(version, generatedAt, etag string) string {
	return `{"manifest_version":"` + version + `","server":{"name":"x","version":"1","base_url":"http://x"},` +
		`"auth_tier":"none","generated_at":"` + generatedAt + `","etag":"` + etag + `","nouns":[],"commands":[]}`
}

// rateLimitBody is the envelope the live server actually sent, retry_after and
// all. The value is small so the test spends milliseconds, not seconds — the
// PATH under test is identical either way, and Fetch reads the number rather
// than assuming one.
func rateLimitBody(retryAfter string) string {
	if retryAfter == "" {
		return `{"error":{"code":"rate_limited","message":"too many requests"}}`
	}
	return `{"error":{"code":"rate_limited","message":"too many requests","details":{"retry_after":` + retryAfter + `}}}`
}

// ACCEPTANCE CRITERION 4, first half. A 429 on the first fetch retries ONCE,
// honouring the retry_after the refusal itself named, and then succeeds against
// a server that has stopped refusing. Proven by the request COUNT — two
// requests reached the handler — not by observing that Fetch returned a
// manifest.
//
// This fails on today's main: Fetch's default branch turns any non-200/304 into
// an error immediately, so the handler would see exactly one request and Fetch
// would return "unexpected status 429".
func TestFetchRetriesOnceOnRateLimitThenSucceeds(t *testing.T) {
	var requests int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		if requests == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(rateLimitBody("0.02")))
			return
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	m, err := Fetch(c, NewCache(t.TempDir()))
	if err != nil {
		t.Fatalf("Fetch should have retried the 429 and succeeded: %v", err)
	}
	if m == nil || m.ManifestVersion != "1" {
		t.Fatalf("manifest after retry = %+v", m)
	}
	if requests != 2 {
		t.Errorf("want exactly 2 requests (the 429 and one retry); got %d", requests)
	}
}

// The Retry-After HEADER is honoured too, in delta-seconds form, and takes
// precedence over the envelope. "0" is a legitimate directive ("retry now") and
// keeps this test free.
func TestFetchRetriesOnRetryAfterHeader(t *testing.T) {
	var requests int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		if requests == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			// No details.retry_after: the header alone must be enough.
			_, _ = w.Write([]byte(rateLimitBody("")))
			return
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	if _, err := Fetch(c, NewCache(t.TempDir())); err != nil {
		t.Fatalf("Fetch with Retry-After: 0: %v", err)
	}
	if requests != 2 {
		t.Errorf("want 2 requests (429 + one retry off the header); got %d", requests)
	}
}

// ACCEPTANCE CRITERION 4, second half — the refusals. A retry happens ONLY when
// the server named a wait we are willing to serve. No value at all, an
// HTTP-date header, a negative value, or an hour are each a reason NOT to
// re-ask: the request count must stay at 1 and the error must surface.
//
// The hour case is the one worth stating out loud: retryAfterCap does not CLAMP
// 3600s down to 2s, because re-asking at 2s a limiter that said "wait an hour"
// is exactly the hammering this retry exists to avoid.
func TestFetchDoesNotRetryWhenRetryAfterIsAbsentOrAbsurd(t *testing.T) {
	cases := []struct {
		name   string
		header string
		body   string
	}{
		{"no retry_after anywhere", "", rateLimitBody("")},
		{"an hour is not a wait a CLI serves", "", rateLimitBody("3600")},
		{"negative", "", rateLimitBody("-5")},
		{"HTTP-date header form is declined", "Wed, 21 Oct 2026 07:28:00 GMT", rateLimitBody("")},
		{"non-numeric details", "", `{"error":{"code":"rate_limited","message":"m","details":{"retry_after":"soon"}}}`},
		{"details is a list, not an object", "", `{"error":{"code":"rate_limited","message":"m","details":["soon"]}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var requests int
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				requests++
				if tc.header != "" {
					w.Header().Set("Retry-After", tc.header)
				}
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
			_, err := Fetch(c, NewCache(t.TempDir()))
			if err == nil {
				t.Fatal("a 429 with no usable retry_after and no cache must surface as an error")
			}
			if !strings.Contains(err.Error(), "429") {
				t.Errorf("error should name the status; got %q", err)
			}
			if requests != 1 {
				t.Errorf("want exactly 1 request (no retry); got %d", requests)
			}
		})
	}
}

// THE FIX'S REASON FOR EXISTING. A warm cache + a server that will not stop
// saying 429 = the command RUNS. Fetch returns the cached manifest and a nil
// error, and says so on stderr exactly once.
//
// This is also the assertion the mutation in TestMUTATION_BreakingTheCacheWrite
// (below) must be able to turn red.
func TestFetchServesCachedManifestWhenRateLimited(t *testing.T) {
	var requests int
	refuse := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		if refuse {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(rateLimitBody("")))
			return
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	cache := NewCache(t.TempDir())
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})

	// Warm the cache with one good 200.
	if _, err := Fetch(c, cache); err != nil {
		t.Fatalf("warming fetch: %v", err)
	}
	if requests != 1 {
		t.Fatalf("warming fetch should be 1 request; got %d", requests)
	}

	// Now the server is under fleet load and refuses everything.
	refuse = true
	var m *Manifest
	var err error
	stderr := captureStderr(t, func() { m, err = Fetch(c, cache) })

	if err != nil {
		t.Fatalf("a 429 with a warm cache must NOT fail the command: %v", err)
	}
	if m == nil || m.ManifestVersion != "1" {
		t.Fatalf("cached manifest not served: %+v", m)
	}
	if requests != 2 {
		t.Errorf("want 2 requests total (warm + the refused one); got %d", requests)
	}
	if !strings.Contains(stderr, "cached manifest") || !strings.Contains(stderr, "429") {
		t.Errorf("the fallback must announce itself on stderr, naming why; got %q", stderr)
	}
	if strings.Count(stderr, "using the cached manifest") != 1 {
		t.Errorf("want exactly ONE notice; got %q", stderr)
	}
}

// A 5xx and a dead server are the same class of fault as a 429 — a statement
// about the SERVER, not about the caller — so a warm cache carries the command
// through both.
func TestFetchServesCachedManifestOnServerFaultAndTransportError(t *testing.T) {
	t.Run("500", func(t *testing.T) {
		var requests int
		fail := false
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			requests++
			if fail {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"code":"internal_error","message":"boom"}}`))
				return
			}
			w.Header().Set("ETag", "e1")
			_, _ = w.Write([]byte(minimalManifest))
		}))
		defer srv.Close()

		cache := NewCache(t.TempDir())
		c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
		if _, err := Fetch(c, cache); err != nil {
			t.Fatalf("warming fetch: %v", err)
		}
		fail = true

		var m *Manifest
		var err error
		_ = captureStderr(t, func() { m, err = Fetch(c, cache) })
		if err != nil || m == nil {
			t.Fatalf("a 500 with a warm cache must serve the cache; got m=%v err=%v", m, err)
		}
	})

	t.Run("transport error", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("ETag", "e1")
			_, _ = w.Write([]byte(minimalManifest))
		}))
		cache := NewCache(t.TempDir())
		c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
		if _, err := Fetch(c, cache); err != nil {
			t.Fatalf("warming fetch: %v", err)
		}
		srv.Close() // the server is gone; the next GET cannot connect at all

		var m *Manifest
		var err error
		stderr := captureStderr(t, func() { m, err = Fetch(c, cache) })
		if err != nil || m == nil {
			t.Fatalf("a dead server with a warm cache must serve the cache; got m=%v err=%v", m, err)
		}
		if !strings.Contains(stderr, "the request failed") {
			t.Errorf("stderr should name the transport failure; got %q", stderr)
		}
	})
}

// THE LINE THE CACHE MUST NOT CROSS. A 401 or 403 is a statement about the
// CALLER — the token was rejected — and the cache is keyed by a hash of that
// token. Serving a cached manifest here would let a revoked credential keep
// driving the whole command tree it used to be entitled to, and would turn a
// crisp "your token was rejected" into a command that fails later and stranger.
// 404 is excluded for its own reason: /v1/capabilities not being deployed is
// exactly what --manifest / BARKPARK_MANIFEST exists for, and it must keep
// saying so.
func TestFetchFailsLoudlyOnAuthRefusalEvenWithAWarmCache(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			reject := false
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if reject {
					w.WriteHeader(status)
					_, _ = w.Write([]byte(`{"error":{"code":"unauthorized","message":"invalid token"}}`))
					return
				}
				w.Header().Set("ETag", "e1")
				_, _ = w.Write([]byte(minimalManifest))
			}))
			defer srv.Close()

			cache := NewCache(t.TempDir())
			c := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "tok"})
			if _, err := Fetch(c, cache); err != nil {
				t.Fatalf("warming fetch: %v", err)
			}
			reject = true

			m, err := Fetch(c, cache)
			if err == nil {
				t.Fatalf("a %d must fail even with a warm cache; got manifest %+v", status, m)
			}
			if !strings.Contains(err.Error(), "invalid token") {
				t.Errorf("the server's explanation must survive; got %q", err)
			}
		})
	}
}

// ACCEPTANCE CRITERION 1 — THE MUTATION. A cache test that cannot tell a hit
// from a miss is the defect it is meant to prevent. This runs
// TestFetchServesCachedManifestWhenRateLimited's exact shape against a cache
// whose Store never lands, and asserts the warm-cache assertion GOES RED: with
// no entry on disk, the 429 must surface as an error instead of being papered
// over. If this test ever fails, the warm-cache assertion above is passing
// vacuously and proves nothing.
func TestMUTATION_BreakingTheCacheWriteRedsTheWarmCacheAssertion(t *testing.T) {
	var requests int
	refuse := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		if refuse {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(rateLimitBody("")))
			return
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	// THE MUTATION: a cache rooted UNDER A REGULAR FILE, so MkdirAll can never
	// create the directory, every Store fails (Fetch swallows the error —
	// caching is best-effort by contract) and every Load misses. Nothing else
	// about the run changes.
	blocker := filepath.Join(t.TempDir(), "this-is-a-file")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatalf("writing the mutation's blocker file: %v", err)
	}
	broken := NewCache(filepath.Join(blocker, "cache"))

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	if _, err := Fetch(c, broken); err != nil {
		t.Fatalf("warming fetch (uncached, but a live 200): %v", err)
	}
	if _, _, ok := broken.Load(CacheKey(c.BaseURL(), c.Token())); ok {
		t.Fatal("the mutation did not apply: the cache still holds an entry, so this run proves nothing")
	}

	refuse = true
	m, err := Fetch(c, broken)
	if err == nil {
		t.Fatalf("MUTATION DID NOT REGISTER: a 429 with an EMPTY cache returned a manifest (%+v). "+
			"That means TestFetchServesCachedManifestWhenRateLimited would pass without the cache ever "+
			"being read, and its green is worthless.", m)
	}
	if !strings.Contains(err.Error(), "429") {
		t.Errorf("error should be the honest 429; got %q", err)
	}
	if requests != 2 {
		t.Errorf("want 2 requests; got %d", requests)
	}
}
