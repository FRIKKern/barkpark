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
	CheckedAt string `json:"checked_at,omitempty"` // RFC3339 of the last network check
	Latest    string `json:"latest,omitempty"`     // newest cli-v* version seen
	Notified  string `json:"notified,omitempty"`   // last version announced to the user
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
	if cache.Notified == cache.Latest {
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
	saveUpdateCache(c)
}
