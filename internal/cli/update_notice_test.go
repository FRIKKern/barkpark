package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// noticeFixture sandboxes everything the update notice touches: the config
// dir (withTempConfigHome, like every config test), the tty seam (forced
// true — the notice is TTY-only), and the kill-switch env var (cleared).
// Returns the sandboxed config-home root for direct cache-file inspection.
func noticeFixture(t *testing.T) string {
	t.Helper()
	root := withTempConfigHome(t)
	t.Setenv("BARKPARK_NO_UPDATE_NOTICE", "")
	old := isStderrTTY
	isStderrTTY = func() bool { return true }
	t.Cleanup(func() { isStderrTTY = old })
	return root
}

// noticeCachePath is where the sandboxed update-check.json lands.
func noticeCachePath(root string) string {
	return filepath.Join(root, "barkpark", "update-check.json")
}

// writeNoticeCache seeds the sandboxed cache file directly.
func writeNoticeCache(t *testing.T, root string, c updateCheckCache) {
	t.Helper()
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(noticeCachePath(root), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

// readNoticeCache reads the sandboxed cache file back for assertions.
func readNoticeCache(t *testing.T, root string) updateCheckCache {
	t.Helper()
	raw, err := os.ReadFile(noticeCachePath(root))
	if err != nil {
		t.Fatalf("read update-check.json: %v", err)
	}
	var c updateCheckCache
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatalf("parse update-check.json: %v", err)
	}
	return c
}

// deadReleaseBase points BARKPARK_CLI_RELEASE_BASE at a closed server so any
// accidental network attempt fails fast (connection refused) instead of
// escaping to the real GitHub.
func deadReleaseBase(t *testing.T) {
	t.Helper()
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", url)
}

func TestNoticeSilenceGates(t *testing.T) {
	// Every gate must produce total silence: no output AND no file IO (the
	// cache file must not even be created).
	cases := []struct {
		name       string
		version    string
		env        string
		subcommand string
		tty        bool
	}{
		{name: "dev build", version: "dev", subcommand: "whoami", tty: true},
		{name: "env kill-switch", version: "0.0.1", env: "1", subcommand: "whoami", tty: true},
		{name: "upgrade subcommand", version: "0.0.1", subcommand: "upgrade", tty: true},
		{name: "version subcommand", version: "0.0.1", subcommand: "version", tty: true},
		{name: "non-tty stderr", version: "0.0.1", subcommand: "whoami", tty: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := noticeFixture(t)
			deadReleaseBase(t)
			withCLIVersion(t, tc.version)
			if tc.env != "" {
				t.Setenv("BARKPARK_NO_UPDATE_NOTICE", tc.env)
			}
			if !tc.tty {
				isStderrTTY = func() bool { return false }
			}
			// A fresh cache announcing a newer release makes silence observable:
			// an ungated run WOULD print here.
			writeNoticeCache(t, root, updateCheckCache{
				CheckedAt: time.Now().UTC().Format(time.RFC3339),
				Latest:    "9.9.9",
			})
			pre, _ := os.ReadFile(noticeCachePath(root))

			var stderr bytes.Buffer
			finishUpdateNotice(&stderr, startUpdateCheck(tc.subcommand))

			if stderr.Len() != 0 {
				t.Errorf("gated run wrote to stderr: %q", stderr.String())
			}
			post, _ := os.ReadFile(noticeCachePath(root))
			if !bytes.Equal(pre, post) {
				t.Errorf("gated run mutated the cache file")
			}
		})
	}
}

func TestNoticeDevBuildCreatesNoCache(t *testing.T) {
	root := noticeFixture(t)
	deadReleaseBase(t)
	withCLIVersion(t, "dev")

	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	if stderr.Len() != 0 {
		t.Errorf("dev build wrote to stderr: %q", stderr.String())
	}
	if _, err := os.Stat(noticeCachePath(root)); !os.IsNotExist(err) {
		t.Errorf("dev build should touch no files; stat err = %v", err)
	}
}

func TestNoticeFreshCachePrintsOnceThenPinsNotified(t *testing.T) {
	root := noticeFixture(t)
	deadReleaseBase(t) // fresh cache → no network; a dead base proves it
	withCLIVersion(t, "0.0.1")
	writeNoticeCache(t, root, updateCheckCache{
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
		Latest:    "0.0.2",
	})

	// First run: one line, notified persisted.
	var first bytes.Buffer
	finishUpdateNotice(&first, startUpdateCheck("whoami"))
	want := "bp 0.0.2 is available (you run 0.0.1) — upgrade: bp upgrade\n"
	if first.String() != want {
		t.Errorf("first run stderr = %q, want %q", first.String(), want)
	}
	if got := readNoticeCache(t, root); got.Notified != "0.0.2" {
		t.Errorf("notified = %q, want 0.0.2", got.Notified)
	}

	// Second run: same release, already announced → silence.
	var second bytes.Buffer
	finishUpdateNotice(&second, startUpdateCheck("whoami"))
	if second.Len() != 0 {
		t.Errorf("second run should be silent, got %q", second.String())
	}
}

func TestNoticeStaleCacheFetchesAndStamps(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "0.0.1")
	srv := fakeReleaseTree(t, "cli-v0.0.2", nil)
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	stale := time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339)
	writeNoticeCache(t, root, updateCheckCache{CheckedAt: stale})

	before := time.Now().Add(-time.Minute)
	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	got := readNoticeCache(t, root)
	// The fetched version lands in the ONE store that holds it — the release
	// cache — not in a second copy inside update-check.json.
	if rc, fresh := readReleaseCache(); !fresh || rc.Latest != "0.0.2" {
		t.Errorf("release cache = %+v fresh=%v, want fresh latest 0.0.2 (fetched from the redirect)", rc, fresh)
	}
	if got.Latest != "" {
		t.Errorf("update-check.json must keep no copy of the version, got %q", got.Latest)
	}
	stamped, err := time.Parse(time.RFC3339, got.CheckedAt)
	if err != nil || !stamped.After(before) {
		t.Errorf("checked_at = %q, want a fresh RFC3339 stamp (err=%v)", got.CheckedAt, err)
	}
	if !bytes.Contains(stderr.Bytes(), []byte("bp 0.0.2 is available")) {
		t.Errorf("stale-cache run should announce the fetched release, got %q", stderr.String())
	}
	if got.Notified != "0.0.2" {
		t.Errorf("notified = %q, want 0.0.2", got.Notified)
	}
}

// TestNoticeResolveWritesReleaseCache: the update-notice background resolve is
// network-bearing, so it must also warm the release cache a later network-free
// whoami reads its freshness verdict from — not only update-check.json.
func TestNoticeResolveWritesReleaseCache(t *testing.T) {
	noticeFixture(t)
	withCLIVersion(t, "0.0.1")
	srv := fakeReleaseTree(t, "cli-v0.0.2", nil)
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)

	// A cold release cache before the run makes the write observable.
	if _, fresh := readReleaseCache(); fresh {
		t.Fatalf("release cache must start cold")
	}
	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	rc, fresh := readReleaseCache()
	if !fresh || rc.Latest != "0.0.2" {
		t.Fatalf("release cache = %+v fresh=%v, want fresh latest 0.0.2 from the notice resolve", rc, fresh)
	}
}

// TestNoticeFailedResolveWritesNoReleaseCache: a fetch that fails must leave the
// release cache untouched — no verdict is cached from a resolve that never
// produced one.
func TestNoticeFailedResolveWritesNoReleaseCache(t *testing.T) {
	noticeFixture(t)
	withCLIVersion(t, "0.0.1")
	deadReleaseBase(t) // connection refused → the fetch fails fast

	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	if _, fresh := readReleaseCache(); fresh {
		t.Errorf("a failed notice resolve must write no release cache")
	}
}

func TestNoticeNetworkFailureIsSilentButStamps(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "0.0.1")
	deadReleaseBase(t) // connection refused — the fetch fails fast
	// No cache at all → stale path, fetch attempted.

	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	if stderr.Len() != 0 {
		t.Errorf("network failure must be silent, got %q", stderr.String())
	}
	got := readNoticeCache(t, root)
	if got.CheckedAt == "" {
		t.Error("checked_at should be stamped even when the fetch fails")
	}
	if got.Latest != "" || got.Notified != "" {
		t.Errorf("failed fetch should persist no latest/notified: %+v", got)
	}
}

func TestNoticeCorruptCacheTreatedAsEmpty(t *testing.T) {
	root := noticeFixture(t)
	withCLIVersion(t, "0.0.1")
	srv := fakeReleaseTree(t, "cli-v0.0.2", nil)
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	// A truncated/garbage cache must behave like a missing one (stale → fetch).
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(noticeCachePath(root), []byte(`{"checked_at": "20`), 0o600); err != nil {
		t.Fatal(err)
	}

	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	if !bytes.Contains(stderr.Bytes(), []byte("bp 0.0.2 is available")) {
		t.Errorf("corrupt cache should be treated as empty and re-fetch, got %q", stderr.String())
	}
	got := readNoticeCache(t, root)
	if got.Notified != "0.0.2" || got.CheckedAt == "" {
		t.Errorf("cache should be rebuilt cleanly after corruption: %+v", got)
	}
	if rc, fresh := readReleaseCache(); !fresh || rc.Latest != "0.0.2" {
		t.Errorf("release cache after corruption = %+v fresh=%v, want fresh latest 0.0.2", rc, fresh)
	}
}

func TestNoticeUpToDateIsSilent(t *testing.T) {
	root := noticeFixture(t)
	deadReleaseBase(t)
	withCLIVersion(t, "0.0.2")
	// Fresh cache whose latest does NOT outrank the running version.
	writeNoticeCache(t, root, updateCheckCache{
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
		Latest:    "0.0.2",
	})

	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	if stderr.Len() != 0 {
		t.Errorf("up-to-date run should be silent, got %q", stderr.String())
	}
	if got := readNoticeCache(t, root); got.Notified != "" {
		t.Errorf("no notice → notified must stay empty, got %q", got.Notified)
	}
}

// writeStaleReleaseCacheFile plants a release-cache reading with an arbitrary
// resolve stamp, which writeReleaseCache (always "now") cannot produce.
func writeStaleReleaseCacheFile(t *testing.T, root, latest string, checkedAt time.Time) {
	t.Helper()
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(releaseCache{Latest: latest, CheckedAt: checkedAt})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, releaseCacheFile), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestNoticeReadsVersionResolvedElsewhere is the RED-on-revert arm for the
// single-source-of-truth change. `bp upgrade` and `bp doctor --onboarding`
// resolve the newest release and write ONLY cli-release-cache.json. While the
// notice kept its own copy in update-check.json, that resolve was invisible to
// it: the throttle said "checked recently", the private copy was empty, and the
// operator was told nothing. Reading the one store fixes it with no network.
func TestNoticeReadsVersionResolvedElsewhere(t *testing.T) {
	root := noticeFixture(t)
	deadReleaseBase(t) // a fresh throttle stamp means NO lookup; prove it
	withCLIVersion(t, "0.0.1")

	// The throttle is fresh — as it is for the 24h after any bp run.
	writeNoticeCache(t, root, updateCheckCache{
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
	})
	// ...and a sibling surface (upgrade/doctor) just resolved a newer release.
	if err := writeReleaseCache("9.9.9"); err != nil {
		t.Fatalf("writeReleaseCache: %v", err)
	}

	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))

	if !bytes.Contains(stderr.Bytes(), []byte("bp 9.9.9 is available")) {
		t.Errorf("notice must compare against the release cache a sibling surface wrote, got %q", stderr.String())
	}
	if note := staleClientNote(); !strings.Contains(note, "9.9.9 is released") {
		t.Errorf("stale-client note must read the same store, got %q", note)
	}
}

// TestNoticeAndWhoamiGateTheSameValueDifferently is the QUIET arm: the two
// lifetimes this row proposed to merge must stay separate. One store now holds
// the version, but its age means different things to its two consumers — past
// releaseCacheTTL whoami must report UNREPORTED (never compare against a day-
// stale reading) while the notice and the refusal-time note must KEEP naming
// the newer release (an offline operator is still behind). A merge that gave
// both consumers one gate would break exactly one of these two assertions.
func TestNoticeAndWhoamiGateTheSameValueDifferently(t *testing.T) {
	root := noticeFixture(t)
	deadReleaseBase(t)
	withCLIVersion(t, "0.0.1")
	writeNoticeCache(t, root, updateCheckCache{
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
	})
	writeStaleReleaseCacheFile(t, root, "9.9.9", time.Now().Add(-48*time.Hour).UTC())

	// whoami's leg: a reading older than the TTL is ABSENT.
	if rc, fresh := readReleaseCache(); fresh {
		t.Errorf("whoami's freshness leg must treat a 48h-old reading as absent, got %+v", rc)
	}
	// The notice's leg: same record, no TTL.
	var stderr bytes.Buffer
	finishUpdateNotice(&stderr, startUpdateCheck("whoami"))
	if !bytes.Contains(stderr.Bytes(), []byte("bp 9.9.9 is available")) {
		t.Errorf("the notice must not inherit whoami's TTL, got %q", stderr.String())
	}
	if note := staleClientNote(); !strings.Contains(note, "9.9.9 is released") {
		t.Errorf("the stale-client note must not inherit whoami's TTL, got %q", note)
	}
}

// TestNoticeThrottleSurvivesAFailedResolve is the second QUIET arm: the other
// lifetime, the ATTEMPT throttle. update-check.json's checked_at is stamped
// BEFORE the fetch and kept when the fetch fails, so an outage cannot make
// every bp invocation re-dial. Anchoring the throttle on the release cache's
// resolve stamp instead (the obvious "one cache" collapse) would make this run
// hit the network again.
func TestNoticeThrottleSurvivesAFailedResolve(t *testing.T) {
	noticeFixture(t)
	withCLIVersion(t, "0.0.1")
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		http.NotFound(w, r)
	}))
	defer srv.Close()
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)

	// First run: cold cache → a lookup is attempted and fails (404s).
	var first bytes.Buffer
	finishUpdateNotice(&first, startUpdateCheck("whoami"))
	if hits == 0 {
		t.Fatalf("the first run must attempt a lookup")
	}
	if _, fresh := readReleaseCache(); fresh {
		t.Fatalf("a failed resolve must leave the release cache cold")
	}

	// Second run: the failed attempt is still an attempt. No network.
	after := hits
	var second bytes.Buffer
	finishUpdateNotice(&second, startUpdateCheck("whoami"))
	if hits != after {
		t.Errorf("a failed resolve must still throttle the next run: %d extra request(s)", hits-after)
	}
	if second.Len() != 0 {
		t.Errorf("no known release → silence, got %q", second.String())
	}
}
