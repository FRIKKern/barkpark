package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/mattn/go-isatty"
)

// The quiet update notice: after any eligible command, bp MAY print one stderr
// line pointing at `bp upgrade` when a newer cli-v* release exists. The
// anti-spam contract is the point — a check hits the network at most once per
// updateCheckInterval, a given release is announced ONCE ever, and every
// failure mode (no cache dir, corrupt cache, network down, slow redirect) is
// silence. Stdout and exit codes are never touched. This is the CLI's own
// version space (cliVersion ldflag, cli-v* releases) — never the instance's
// v* tags.
//
// Shape: startUpdateCheck fires the (rare) background fetch WHEN THE COMMAND
// STARTS, so the lookup overlaps the command's own network time instead of
// racing a 250ms grace at exit — a cold HTTPS round trip to github.com would
// lose that race almost every time and the notice would never fire. The
// goroutine persists a completed fetch itself, so even a lookup that outlives
// this wait (but not the process) lands in the cache for the NEXT run.

// updateCheckInterval is how long a persisted check stays fresh — no network
// is touched while the cache's checked_at is younger than this.
const updateCheckInterval = 24 * time.Hour

// updateFetchWait caps how long finishUpdateNotice lingers on a still-running
// lookup at command exit. By then the fetch has had the whole command's
// runtime; this is only the final grace.
const updateFetchWait = 250 * time.Millisecond

// updateRenotifyInterval re-arms a notice for a release we ALREADY announced,
// when the operator is STILL running an older bp that many days later.
//
// Why this exists (pds-bl-bp-search-false-negative): Notified alone pins a
// release forever, so the announcement is once-EVER per release. If no newer
// release lands afterwards, an operator who scrolled past that one line — or
// whose notice was eaten by a --output json run, a non-TTY wrapper, or a
// pane that had already scrolled — is silently behind FOREVER. That is the
// exact state six surveyors were in when their bp's refusal copy told them
// `bp search` did not exist and they fell back to grep. Staleness that
// PERSISTS gets restated; staleness that is fixed never prints again, because
// the version comparison below stops matching.
//
// It re-arms off the CACHE only: no extra network, no extra latency — the
// 24h updateCheckInterval still governs every lookup.
const updateRenotifyInterval = 7 * 24 * time.Hour

// versionShape is the only thing we will ever compare or print as a version.
// The cache file is user-writable and Latest ultimately derives from a remote
// redirect — without this gate a hostile/hand-edited value could inject ANSI
// escape sequences straight into the user's terminal.
var versionShape = regexp.MustCompile(`^[0-9]+(\.[0-9]+)*$`)

// isStderrTTY is a seam so tests can force a TTY: the notice is human-facing
// chrome, so redirected/piped stderr (CI, cron, scripts) must stay clean.
var isStderrTTY = func() bool {
	return isatty.IsTerminal(os.Stderr.Fd())
}

// updateCheckCache is the on-disk anti-spam state, persisted as
// update-check.json next to config.json. Notified remembers the last release
// we announced so each release prints at most once, ever.
type updateCheckCache struct {
	CheckedAt  string `json:"checked_at,omitempty"`  // RFC3339 of the last network check
	Latest     string `json:"latest,omitempty"`      // newest cli-v* version seen
	Notified   string `json:"notified,omitempty"`    // last version announced to the user
	NotifiedAt string `json:"notified_at,omitempty"` // RFC3339 of that announcement
}

// pendingUpdateCheck carries the in-flight state from startUpdateCheck to
// finishUpdateNotice. nil means "every gate said no — do nothing at exit".
type pendingUpdateCheck struct {
	cache updateCheckCache
	fetch <-chan string // nil when the cache was fresh (no lookup started)
}

// updateCachePath returns the cache file's absolute path (same dir as
// config.json).
func updateCachePath() (string, error) {
	dir, err := configDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "update-check.json"), nil
}

// loadUpdateCache reads the cache. A missing, unreadable, or corrupt file is
// the zero value — never an error, per the silence contract.
func loadUpdateCache() updateCheckCache {
	path, err := updateCachePath()
	if err != nil {
		return updateCheckCache{}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return updateCheckCache{}
	}
	var c updateCheckCache
	if json.Unmarshal(raw, &c) != nil {
		return updateCheckCache{}
	}
	return c
}

// saveUpdateCache persists the cache best-effort and ATOMICALLY (temp file +
// rename): two concurrent bp invocations may both write, and a torn half-JSON
// would otherwise zero the anti-spam state and re-announce. Any failure
// (read-only home, missing dir) is swallowed — the worst case is a repeat
// check or a repeat notice, never an error surfaced to the user.
func saveUpdateCache(c updateCheckCache) {
	path, err := updateCachePath()
	if err != nil {
		return
	}
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".update-check-*")
	if err != nil {
		return
	}
	name := tmp.Name()
	_, werr := tmp.Write(append(raw, '\n'))
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Chmod(name, 0o600) != nil || os.Rename(name, path) != nil {
		_ = os.Remove(name)
	}
}

// startUpdateCheck runs the silence gates and, when the cache has gone stale,
// kicks off the release lookup in the background. Call it when the command
// STARTS so the lookup overlaps the command's own runtime. Returns nil when
// the notice machinery should do nothing at all for this invocation.
func startUpdateCheck(subcommand string) *pendingUpdateCheck {
	// Silence gates, checked before ANY file or network IO. Dev builds have no
	// release to compare against; the env var is the operator kill-switch (any
	// non-empty value silences); non-TTY stderr means scripts/CI, which must
	// stay byte-clean; and `upgrade`/`version` already ARE the update surface.
	if cliVersion == "dev" {
		return nil
	}
	if os.Getenv("BARKPARK_NO_UPDATE_NOTICE") != "" {
		return nil
	}
	if subcommand == "upgrade" || subcommand == "version" {
		return nil
	}
	if !isStderrTTY() {
		return nil
	}

	cache := loadUpdateCache()
	fresh := false
	if t, err := time.Parse(time.RFC3339, cache.CheckedAt); err == nil {
		since := time.Since(t)
		// A future-dated stamp (clock skew, hand-edit) must count as STALE:
		// treating it as fresh would disable checks until the wall clock
		// catches up — potentially forever.
		fresh = since >= 0 && since < updateCheckInterval
	}
	if fresh {
		return &pendingUpdateCheck{cache: cache}
	}

	// Stamp checked_at NOW and persist immediately — even if the fetch never
	// completes, the next 24h of runs stay off the network.
	cache.CheckedAt = time.Now().UTC().Format(time.RFC3339)
	saveUpdateCache(cache)

	// Resolve the latest release in the background. The goroutine persists a
	// valid result ITSELF, so a fetch that finishes after finishUpdateNotice's
	// grace (but before process exit) still lands for the next run. The
	// channel is buffered so a late send never blocks.
	ch := make(chan string, 1)
	go func() {
		latest, err := latestReleaseVersion(releaseRepoBase())
		if err != nil || !versionShape.MatchString(latest) {
			ch <- ""
			return
		}
		c := loadUpdateCache()
		c.Latest = latest
		saveUpdateCache(c)
		// This background resolve is network-bearing too, so route its result
		// into the release cache whoami reads its freshness verdict from — any
		// network-touching invocation refreshes the whoami leg, not just the
		// doctor. Best-effort: a write failure never blocks the notice.
		_ = writeReleaseCache(latest)
		ch <- latest
	}()
	return &pendingUpdateCheck{cache: cache, fetch: ch}
}

// finishUpdateNotice completes the check startUpdateCheck began: collect a
// finished lookup (waiting at most updateFetchWait), then print the at-most-
// one notice line. It never errors, never touches stdout, and never changes
// the exit code — Execute defers it and ignores it entirely.
func finishUpdateNotice(stderr io.Writer, pending *pendingUpdateCheck) {
	if pending == nil {
		return
	}
	cache := pending.cache
	if pending.fetch != nil {
		select {
		case latest := <-pending.fetch:
			if latest != "" {
				cache.Latest = latest
			}
		case <-time.After(updateFetchWait):
			// Still running — the goroutine will persist for next time.
		}
	}

	// Notify at most once per release: a known newer latest that we have not
	// announced yet prints one line, then Notified pins it forever. The shape
	// gate keeps a hand-edited/hostile Latest (ANSI escapes, garbage) out of
	// both the comparison and the terminal.
	if cache.Latest == "" || !versionShape.MatchString(cache.Latest) {
		return
	}
	if cache.Notified == cache.Latest && !renotifyDue(cache.NotifiedAt, time.Now()) {
		return
	}
	if compareVersions(cache.Latest, cliVersion) <= 0 {
		return
	}
	fmt.Fprintf(stderr, "bp %s is available (you run %s) — upgrade: bp upgrade\n", cache.Latest, cliVersion)
	// Re-load before pinning Notified so we never clobber a fresher Latest
	// persisted by the goroutine after our snapshot.
	c := loadUpdateCache()
	c.Notified = cache.Latest
	c.NotifiedAt = time.Now().UTC().Format(time.RFC3339)
	saveUpdateCache(c)
}

// renotifyDue reports whether an already-announced release may be announced
// again: true once updateRenotifyInterval has elapsed since notifiedAt.
//
// An unparseable or EMPTY stamp is due — a cache written before notified_at
// existed carries a pinned Notified and no timestamp, and treating that as
// "not due" would keep exactly the operators this row is about permanently
// silent. A FUTURE stamp (clock skew, hand-edit) is NOT due: the interval has
// genuinely not elapsed, and re-arming on skew would print every run.
func renotifyDue(notifiedAt string, now time.Time) bool {
	t, err := time.Parse(time.RFC3339, notifiedAt)
	if err != nil {
		return true
	}
	return now.Sub(t) >= updateRenotifyInterval
}

// staleClientNote returns the ONE line telling a human operator that the bp
// they are running is behind the newest cli-v* release — or "" when we cannot
// PROVE it, which is every ambiguous case.
//
// This is the refusal-time arm of the same signal finishUpdateNotice prints at
// exit. The moment a reader is most likely to draw a FALSE conclusion from an
// old client is the moment that client refuses: `unknown command "search"` is
// how six independent agents in one wave concluded the verb did not exist and
// fell back to grep, when in fact dispatch is manifest-driven and the server
// had declared it all along. A refusal from a client that KNOWS it is behind
// has to say so.
//
// Cost is a single read of the already-persisted update-check.json: no
// network, no blocking, correct offline. A dev build returns "" (there is no
// release to compare against — the same verdict `bp whoami` reports as
// UNREPORTED), as does the BARKPARK_NO_UPDATE_NOTICE kill switch.
func staleClientNote() string {
	if cliVersion == "dev" {
		return ""
	}
	if os.Getenv("BARKPARK_NO_UPDATE_NOTICE") != "" {
		return ""
	}
	c := loadUpdateCache()
	if c.Latest == "" || !versionShape.MatchString(c.Latest) {
		return ""
	}
	if compareVersions(c.Latest, cliVersion) <= 0 {
		return ""
	}
	return fmt.Sprintf("note: you are running bp %s; %s is released. an out-of-date bp can refuse a command the server DOES have — re-check with `bp upgrade` before concluding it does not exist.", cliVersion, c.Latest)
}
