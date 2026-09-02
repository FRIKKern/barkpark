package manifest

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// These two tests close the acceptance arms that the existing suite proved only
// halfway. TestCacheKeySaltsByToken (cache_test.go) proves two tokens compute
// DIFFERENT keys — a property of CacheKey. It does not prove what a CALLER sees
// coming out of Fetch, which is what the row asked for and what the incident was
// about. TestFetchCachesThenHonors304 (fetch_test.go) proves a 304 returns the
// cached manifest; it never changes the manifest, so it cannot prove that a
// CHANGED one gets picked up.

// tierManifest is a manifest projected for one auth tier, the way
// api/lib/barkpark/plugins/capabilities.ex projects it: the admin tier carries
// the commands, the anonymous tier carries none and reports auth_tier "none".
// This is the exact shape that produced the row's worst trap — a manifest
// fetched WITHOUT a credential makes bp report that `task` does not exist.
func tierManifest(version, tier, generatedAt, etag string) string {
	commands := "[]"
	if tier == "admin" {
		commands = `[{"id":"task.close","noun":"task","verb":"close","summary":"close a task",` +
			`"http":{"method":"POST","path_template":"/v1/tasks/{id}/close"},"auth_tier":"write",` +
			`"args":[],"flags":[]}]`
	}
	return `{"manifest_version":"` + version + `","server":{"name":"x","version":"1","base_url":"http://x"},` +
		`"auth_tier":"` + tier + `","generated_at":"` + generatedAt + `","etag":"` + etag + `",` +
		`"nouns":[],"commands":` + commands + `}`
}

// ACCEPTANCE CRITERION 2, asserted BOTH DIRECTIONS ON ONE INPUT: one cache
// directory, one server, two tokens. The admin caller keeps seeing its command
// AND the anonymous caller keeps not seeing it — neither tier's entry can be
// served to the other.
//
// The failure this forbids is the row's own measured trap at cache level: a
// manifest carrying auth_tier "none" reaching an entitled caller makes every
// command it is allowed to run report "exists but is hidden at your auth tier",
// which reads as a permissions bug or a missing feature rather than a stale
// cache. The inverse — an admin body served to an anon caller — would advertise
// a command tree the server will then refuse.
func TestFetchNeverServesOneTiersManifestToAnother(t *testing.T) {
	var anonSawIfNoneMatch, adminNotModified int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tier, etag := "none", "e-anon"
		if r.Header.Get("Authorization") == "Bearer admin-token" {
			tier, etag = "admin", "e-admin"
		}
		if tier == "none" && r.Header.Get("If-None-Match") != "" {
			anonSawIfNoneMatch++
		}
		w.Header().Set("ETag", etag)
		// The real controller short-circuits a matching validator to 304.
		if r.Header.Get("If-None-Match") == etag {
			if tier == "admin" {
				adminNotModified++
			}
			w.WriteHeader(http.StatusNotModified)
			return
		}
		_, _ = w.Write([]byte(tierManifest("1", tier, "2026-06-01T00:00:00Z", etag)))
	}))
	defer srv.Close()

	// ONE cache dir shared by both callers — the whole point.
	cache := NewCache(t.TempDir())
	admin := apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "admin-token"})
	anon := apiclient.New(apiclient.Config{BaseURL: srv.URL})

	// 1. The admin caller populates the cache and sees its command.
	m, err := Fetch(admin, cache)
	if err != nil {
		t.Fatalf("admin fetch: %v", err)
	}
	if m.AuthTier != "admin" || len(m.Commands) != 1 {
		t.Fatalf("admin fetch = tier %q, %d commands; want admin/1", m.AuthTier, len(m.Commands))
	}

	// 2. DIRECTION ONE — the lower tier still does NOT see them. The anon
	// caller hits the same cache dir and must miss: no admin body, and no admin
	// ETag smuggled out as an If-None-Match (which would let the server answer
	// 304 and hand the anon caller the admin tree).
	m, err = Fetch(anon, cache)
	if err != nil {
		t.Fatalf("anon fetch: %v", err)
	}
	if m.AuthTier != "none" || len(m.Commands) != 0 {
		t.Errorf("THE ADMIN MANIFEST LEAKED TO AN ANONYMOUS CALLER: tier %q, %d commands", m.AuthTier, len(m.Commands))
	}
	if anonSawIfNoneMatch != 0 {
		t.Errorf("the anon request carried an If-None-Match (%d of them) — it is validating against another tier's entry", anonSawIfNoneMatch)
	}

	// 3. DIRECTION TWO — the higher tier still sees its commands, and is still
	// served from ITS OWN slot: the anon fetch in between must not have
	// clobbered the admin entry, proven by the server answering 304 (the admin
	// ETag was still on disk to send).
	m, err = Fetch(admin, cache)
	if err != nil {
		t.Fatalf("admin re-fetch: %v", err)
	}
	if m.AuthTier != "admin" || len(m.Commands) != 1 {
		t.Errorf("the admin caller LOST its commands after an anon fetch: tier %q, %d commands", m.AuthTier, len(m.Commands))
	}
	if adminNotModified != 1 {
		t.Errorf("the admin re-fetch should have validated against its own cached ETag and gotten one 304; got %d", adminNotModified)
	}
}

// ACCEPTANCE CRITERION 3. A server-side manifest_version bump INVALIDATES the
// cache, proven by BUMPING IT and observing the refetch — a 200 body served
// where the unbumped control gets a 304.
//
// The mechanism is not incidental. etag_for/1 in
// api/lib/barkpark/plugins/capabilities.ex content-addresses the ETag over the
// projected body with only "etag" and "generated_at" dropped, so
// manifest_version is INSIDE the hash: bumping it necessarily changes the
// validator, the client's stale If-None-Match no longer matches, and the server
// answers 200 with the new body. That is why this test can bump the version and
// expect a refetch rather than having to special-case the field anywhere in the
// client.
func TestFetchRefetchesWhenManifestVersionBumps(t *testing.T) {
	version, etag, generatedAt := "1", "e-v1", "2026-06-01T00:00:00Z"
	var bodiesServed, notModified int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", etag)
		if r.Header.Get("If-None-Match") == etag {
			notModified++
			w.WriteHeader(http.StatusNotModified)
			return
		}
		bodiesServed++
		_, _ = w.Write([]byte(tierManifest(version, "none", generatedAt, etag)))
	}))
	defer srv.Close()

	cache := NewCache(t.TempDir())
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	key := CacheKey(c.BaseURL(), c.Token())

	// 1. Cold: one body served, version 1 cached.
	m, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("first fetch: %v", err)
	}
	if m.ManifestVersion != "1" || bodiesServed != 1 {
		t.Fatalf("first fetch = version %q after %d bodies; want 1/1", m.ManifestVersion, bodiesServed)
	}

	// 2. CONTROL, before touching anything: an unbumped server answers 304 and
	// serves NO body. Without this the "refetch" in step 3 could just be a
	// cache that never worked.
	if _, err := Fetch(c, cache); err != nil {
		t.Fatalf("control fetch: %v", err)
	}
	if notModified != 1 || bodiesServed != 1 {
		t.Fatalf("control fetch should be a pure 304: notModified=%d bodiesServed=%d", notModified, bodiesServed)
	}

	// 3. THE BUMP. New manifest_version, hence a new content-addressed ETag and
	// a newer generated_at (the deploy is later than the one it replaces).
	version, etag, generatedAt = "2", "e-v2", "2026-06-02T00:00:00Z"

	m, err = Fetch(c, cache)
	if err != nil {
		t.Fatalf("fetch after the bump: %v", err)
	}
	if m.ManifestVersion != "2" {
		t.Errorf("THE BUMP DID NOT INVALIDATE THE CACHE: still serving version %q", m.ManifestVersion)
	}
	if bodiesServed != 2 {
		t.Errorf("want a second body served (the refetch); bodiesServed=%d", bodiesServed)
	}
	if notModified != 1 {
		t.Errorf("the bumped fetch must not have been a 304; notModified=%d", notModified)
	}

	// 4. And the cache now holds the NEW generation, so the next invocation
	// validates against v2 rather than re-downloading forever.
	if gen, mv, ok := cache.CachedGeneration(key); !ok || mv != "2" || gen != "2026-06-02T00:00:00Z" {
		t.Errorf("cache did not adopt the new generation: gen=%q version=%q ok=%v", gen, mv, ok)
	}
	if cached, _, ok := cache.Load(key); !ok || cached.ManifestVersion != "2" {
		t.Errorf("cached body is not the bumped one: ok=%v version=%q", ok, cached.ManifestVersion)
	}
}
