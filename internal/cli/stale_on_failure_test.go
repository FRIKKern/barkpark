package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// task-63e7054c896a4987: an agent on bp 1.26.26 spent an hour working around a
// bug 1.26.29 had fixed, because the update notice is TTY-only and announced
// once a week at most. A failed command now says bp is behind, on any stderr,
// from cli-release-cache.json alone.

const staleLineMarker = "this may already be fixed: bp upgrade"

// staleFixture sandboxes the config dir, points the release lookup at a dead
// server, pins the binary's version and seeds cli-release-cache.json with
// latest ("" seeds nothing). tty sets the stderr seam.
func staleFixture(t *testing.T, binary, latest string, tty bool) string {
	t.Helper()
	root := noticeFixture(t)
	deadReleaseBase(t)
	withCLIVersion(t, binary)
	isStderrTTY = func() bool { return tty }
	if latest != "" {
		if err := writeReleaseCache(latest); err != nil {
			t.Fatalf("seed release cache: %v", err)
		}
	}
	// Commands below run from an empty directory, so no .barkpark.json up the
	// tree can change how they fail.
	t.Chdir(t.TempDir())
	return root
}

// `bp make schema` with no name fails locally (exit 2) after the update check
// has started, and `bp --version` succeeds without a network call.
var (
	failingArgs    = []string{"make", "schema"}
	succeedingArgs = []string{"--version"}
)

func TestStaleOnFailureNonTTYFailurePrintsOneLine(t *testing.T) {
	staleFixture(t, "1.26.26", "1.26.29", false)

	out, code := captureExecuteCode(t, failingArgs)
	if code == exitOK {
		t.Fatalf("`bp make schema` exited 0; the test needs a failing command:\n%s", out)
	}
	want := "bp 1.26.26 is older than the latest release, 1.26.29; " + staleLineMarker
	if n := strings.Count(out, want); n != 1 {
		t.Errorf("want the staleness line exactly once on non-TTY stderr, got %d:\n%s", n, out)
	}
}

func TestStaleOnFailureNonTTYSuccessPrintsNothing(t *testing.T) {
	staleFixture(t, "1.26.26", "1.26.29", false)

	out, code := captureExecuteCode(t, succeedingArgs)
	if code != exitOK {
		t.Fatalf("`bp --version` exit = %d", code)
	}
	if strings.Contains(out, staleLineMarker) || strings.Contains(out, "is available") {
		t.Errorf("a successful command printed a staleness line:\n%s", out)
	}
}

// On a TTY the exit notice may fire as well. The run says it once, never twice.
func TestStaleOnFailureTTYFailureSaysItOnce(t *testing.T) {
	root := staleFixture(t, "1.26.26", "1.26.29", true)
	// A fresh throttle stamp keeps the exit notice off the network.
	writeNoticeCache(t, root, updateCheckCache{CheckedAt: time.Now().UTC().Format(time.RFC3339)})

	out, code := captureExecuteCode(t, failingArgs)
	if code == exitOK {
		t.Fatalf("`bp make schema` exited 0:\n%s", out)
	}
	lines := strings.Count(out, staleLineMarker) + strings.Count(out, "is available (you run")
	if lines != 1 {
		t.Errorf("want exactly one staleness line on a TTY failure, got %d:\n%s", lines, out)
	}

	// The weekly exit notice is now pinned. The next failure still says it,
	// through the failure line.
	out, _ = captureExecuteCode(t, failingArgs)
	if strings.Count(out, staleLineMarker) != 1 {
		t.Errorf("the second TTY failure did not print the failure line:\n%s", out)
	}
}

func TestStaleOnFailureTTYSuccessPrintsNoFailureLine(t *testing.T) {
	staleFixture(t, "1.26.26", "1.26.29", true)

	out, code := captureExecuteCode(t, succeedingArgs)
	if code != exitOK {
		t.Fatalf("`bp --version` exit = %d", code)
	}
	if strings.Contains(out, staleLineMarker) {
		t.Errorf("a successful command printed the failure line:\n%s", out)
	}
}

func TestStaleOnFailureSilentWhenCurrentOrNoCache(t *testing.T) {
	for _, tc := range []struct {
		name, binary, latest string
	}{
		{"current binary", "1.26.29", "1.26.29"},
		{"binary newer than the cache", "1.26.30", "1.26.29"},
		{"empty cache", "1.26.26", ""},
		{"dev build", "dev", "1.26.29"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			staleFixture(t, tc.binary, tc.latest, false)
			out, code := captureExecuteCode(t, failingArgs)
			if code == exitOK {
				t.Fatalf("`bp make schema` exited 0")
			}
			if strings.Contains(out, staleLineMarker) {
				t.Errorf("printed a staleness line:\n%s", out)
			}
		})
	}
}

func TestStaleOnFailureEnvSilencer(t *testing.T) {
	for _, tty := range []bool{false, true} {
		staleFixture(t, "1.26.26", "1.26.29", tty)
		t.Setenv("BARKPARK_NO_UPDATE_NOTICE", "1")
		out, _ := captureExecuteCode(t, failingArgs)
		if strings.Contains(out, staleLineMarker) || strings.Contains(out, "is available") {
			t.Errorf("tty=%v: BARKPARK_NO_UPDATE_NOTICE did not silence the line:\n%s", tty, out)
		}
	}
}

// A malformed or hostile cached value never reaches the terminal.
func TestStaleOnFailureRefusesAMalformedCachedVersion(t *testing.T) {
	staleFixture(t, "1.26.26", "9.9.9\x1b[31m", false)
	if line := staleOnFailureLine(); line != "" {
		t.Errorf("printed a line from a malformed cache value: %q", line)
	}
}

// The failure path reads the cache only: a failed non-TTY command makes no
// request to the release server and writes neither cache file.
func TestStaleOnFailureMakesNoNetworkCallAndWritesNothing(t *testing.T) {
	root := staleFixture(t, "1.26.26", "1.26.29", false)
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		http.NotFound(w, r)
	}))
	defer srv.Close()
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", srv.URL)
	before, _ := os.ReadFile(releaseCacheFilePathForTest(t))

	out, _ := captureExecuteCode(t, failingArgs)
	if !strings.Contains(out, staleLineMarker) {
		t.Fatalf("no line:\n%s", out)
	}
	if n := hits.Load(); n != 0 {
		t.Errorf("the failure path made %d request(s) to the release server", n)
	}
	after, _ := os.ReadFile(releaseCacheFilePathForTest(t))
	if string(before) != string(after) {
		t.Error("the failure path rewrote cli-release-cache.json")
	}
	if _, err := os.Stat(noticeCachePath(root)); err == nil {
		t.Error("the failure path wrote update-check.json")
	}
}

// `bp upgrade` and `bp version` are the update surface; a failure there does
// not repeat the line.
func TestStaleOnFailureSkipsTheUpdateSurface(t *testing.T) {
	staleFixture(t, "1.26.26", "1.26.29", false)
	for _, args := range [][]string{{"upgrade", "--bogus"}, {"-o", "json", "version"}} {
		var buf strings.Builder
		out := newWriter(os.Stdout, &buf)
		reportStaleOnFailure(out, args, exitUsage)
		if buf.Len() != 0 {
			t.Errorf("%v printed %q", args, buf.String())
		}
	}
}

func releaseCacheFilePathForTest(t *testing.T) string {
	t.Helper()
	p, err := releaseCachePath()
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// `bp version` reports the cached latest release in json and in the table.
func TestVersionReportsTheCachedLatestRelease(t *testing.T) {
	staleFixture(t, "1.26.26", "1.26.29", false)

	out, stdout, _ := newTestWriter()
	out.output = "json"
	if code := runVersion(out, globals{}); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	var got map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("not JSON: %v (%q)", err, stdout.String())
	}
	if got["cli_version"] != "1.26.26" || got["latest_cli"] != "1.26.29" || got["update_available"] != true {
		t.Errorf("json = %v", got)
	}
	if s, _ := got["latest_cli_checked_at"].(string); s == "" {
		t.Errorf("json carries no latest_cli_checked_at: %v", got)
	}

	out, stdout, _ = newTestWriter()
	out.output = "table"
	runVersion(out, globals{})
	table := stdout.String()
	if !strings.HasPrefix(table, "bp 1.26.26\n") {
		t.Errorf("the first line changed; scripts read it:\n%s", table)
	}
	if !strings.Contains(table, "latest release: 1.26.29") || !strings.Contains(table, "bp upgrade") {
		t.Errorf("table does not name the latest release:\n%s", table)
	}
}

func TestVersionWithoutACacheSaysUnknown(t *testing.T) {
	staleFixture(t, "1.26.26", "", false)

	out, stdout, _ := newTestWriter()
	out.output = "json"
	runVersion(out, globals{})
	var got map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("not JSON: %v", err)
	}
	for _, k := range []string{"latest_cli", "update_available"} {
		if _, ok := got[k]; ok {
			t.Errorf("an empty cache produced %q: %v", k, got)
		}
	}

	out, stdout, _ = newTestWriter()
	out.output = "table"
	runVersion(out, globals{})
	if !strings.Contains(stdout.String(), "latest release: unknown") {
		t.Errorf("table:\n%s", stdout.String())
	}
}

func TestVersionCurrentBinary(t *testing.T) {
	staleFixture(t, "1.26.29", "1.26.29", false)
	out, stdout, _ := newTestWriter()
	out.output = "table"
	runVersion(out, globals{})
	if !strings.Contains(stdout.String(), "this bp is current") {
		t.Errorf("table:\n%s", stdout.String())
	}
}
