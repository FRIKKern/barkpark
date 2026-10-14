package cli

// dev_pull_media_test.go covers task-bf56c5d0302a2d6f: the media half of
// `bp dev pull`.
//
//  1. --no-media moves documents and media records and sends no media request.
//  2. Each file is read from the scoped delivery route
//     /w/<ws>/p/<project>/media/files/<path>, with the project resolved from the
//     row's project_id. The flat /media/files/ route answered 404 for every row
//     outside the Default workspace.
//  3. A 429 is waited out (Retry-After, or a fallback when absent) and the same
//     file is retried, on both the fetch and the push; the pacer spaces
//     requests. A file the source answers 404 for is listed and the pull exits 0.
//  4. The receipt names the source's shares and tokens that the dev profile
//     does not carry, with the commands to recreate them.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeMediaClock replaces the pacer's sleep and clock for one test. Sleeps
// advance the fake clock instead of blocking, and every sleep is recorded.
func fakeMediaClock(t *testing.T) *[]time.Duration {
	t.Helper()
	var slept []time.Duration
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	oldSleep, oldNow := mediaSleep, mediaNow
	mediaSleep = func(d time.Duration) {
		slept = append(slept, d)
		now = now.Add(d)
	}
	mediaNow = func() time.Time { return now }
	t.Cleanup(func() { mediaSleep, mediaNow = oldSleep, oldNow })
	return &slept
}

// ── 1. --no-media ────────────────────────────────────────────────────────────

func TestDevPullNoMediaSkipsEveryMediaRequest(t *testing.T) {
	workspaceEnvIsolate(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "bundle.tar")
	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle, "--no-media")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if len(sprobe.blobPaths) != 0 {
		t.Fatalf("--no-media still fetched %d media file(s): %v", len(sprobe.blobPaths), sprobe.blobPaths)
	}
	if len(tprobe.blobPUTs) != 0 {
		t.Fatalf("--no-media still pushed %d media file(s): %v", len(tprobe.blobPUTs), tprobe.blobPUTs)
	}
	if tprobe.importQuery != "mode=merge" || tprobe.importBytes == 0 {
		t.Fatalf("--no-media must still import the bundle (query %q, %d bytes)", tprobe.importQuery, tprobe.importBytes)
	}
	if !strings.Contains(stdout, "files skipped (--no-media); 2 media record(s) imported") {
		t.Fatalf("receipt does not say the files were skipped and the records imported:\n%s", stdout)
	}
	if _, err := os.Stat(bundle + ".blobs"); err == nil {
		t.Fatalf("--no-media created a sidecar directory")
	}
}

func TestDevPullNoMediaMachineReceipt(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"), "--no-media")
	if code != exitOK {
		t.Fatalf("exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	var doc struct {
		Media struct {
			Mode    string `json:"mode"`
			Records int    `json:"records"`
		} `json:"media"`
	}
	if err := json.Unmarshal([]byte(stdout), &doc); err != nil {
		t.Fatalf("receipt did not parse: %v\n%s", err, stdout)
	}
	if doc.Media.Mode != "skipped" || doc.Media.Records != 2 {
		t.Fatalf("media block = %+v, want mode=skipped records=2", doc.Media)
	}
}

func TestDevPullNoMediaRerunKeepsTheFlag(t *testing.T) {
	got := devPullRerunCmd("prod", "laptop", "acme", "production", "/tmp/b.tar", true, true)
	if !strings.HasSuffix(got, "--resume --no-media") {
		t.Fatalf("re-run command %q drops --no-media", got)
	}
}

// ── 2. the fetch route ───────────────────────────────────────────────────────

// TestDevPullReadsFilesFromTheScopedRoute: every media GET goes to the scoped
// route. The mock source does not serve the flat /media/files/ route at all,
// so a regression shows as an unexpected request and a failed pull.
func TestDevPullReadsFilesFromTheScopedRoute(t *testing.T) {
	workspaceEnvIsolate(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code != exitOK {
		t.Fatalf("exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if len(sprobe.blobPaths) != len(devPullBlobs) {
		t.Fatalf("source saw %d media GETs, want %d", len(sprobe.blobPaths), len(devPullBlobs))
	}
	for _, p := range sprobe.blobPaths {
		if !strings.HasPrefix(p, "/w/acme/p/default/media/files/") {
			t.Fatalf("media GET %q is not on the scoped route", p)
		}
	}
	if len(tprobe.blobPUTs) != len(devPullBlobs) {
		t.Fatalf("target received %d pushes, want %d", len(tprobe.blobPUTs), len(devPullBlobs))
	}
}

// TestBundleMediaIndexResolvesProjectSlugs: the route's project comes from the
// row's project_id joined against the bundle's own projects member, and the
// workspace from the manifest.
func TestBundleMediaIndexResolvesProjectSlugs(t *testing.T) {
	manifest := `{"format":"bp-export-v1","workspace_slug":"gyldendal-no","tables":[` +
		`{"name":"projects","columns":["id","workspace_id","slug","name"]},` +
		`{"name":"media_files","columns":["id","path","size","project_id"]}]}`
	bundle := devPullTarWithMembers(t, [][2]string{
		{"manifest.json", manifest},
		{"tables/projects.copy", "p-1\tws\tdefault\tDefault\np-2\tws\tweb\tWeb\n"},
		{"tables/media_files.copy", "m-1\td/x/a.jpg\t3\tp-2\nm-2\td/x/b.jpg\t4\tp-1\nm-3\td/x/c.jpg\t5\t\\N\n"},
	})
	f := filepath.Join(t.TempDir(), "b.tar")
	if err := os.WriteFile(f, bundle, 0o644); err != nil {
		t.Fatal(err)
	}
	refs, ws, err := bundleMediaIndex(f)
	if err != nil {
		t.Fatalf("bundleMediaIndex: %v", err)
	}
	if ws != "gyldendal-no" {
		t.Fatalf("workspace = %q, want the manifest's workspace_slug", ws)
	}
	want := map[string]string{"d/x/a.jpg": "web", "d/x/b.jpg": "default", "d/x/c.jpg": ""}
	for _, r := range refs {
		if r.project != want[r.path] {
			t.Fatalf("ref %s project = %q, want %q", r.path, r.project, want[r.path])
		}
	}
	base := "http://src"
	got := blobFetchURL(base, ws, refs[0])
	if got != "http://src/w/gyldendal-no/p/web/media/files/d/x/a.jpg" {
		t.Fatalf("fetch URL = %q", got)
	}
	if got := blobFetchURL(base, ws, refs[2]); got != "http://src/w/gyldendal-no/p/default/media/files/d/x/c.jpg" {
		t.Fatalf("a row with no project must use the default project, got %q", got)
	}
	if got := blobFetchURL(base, "", refs[0]); got != "http://src/media/files/d/x/a.jpg" {
		t.Fatalf("a bundle with no workspace must keep the flat route, got %q", got)
	}
}

// ── 3. pacing, 429 and missing files ────────────────────────────────────────

func TestDevPullWaitsOutRateLimitsAndFinishes(t *testing.T) {
	workspaceEnvIsolate(t)
	slept := fakeMediaClock(t)
	src, sprobe := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs,
		rateLimited: 2, retryAfter: "3",
	})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{rateLimited: 1})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code != exitOK {
		t.Fatalf("a rate-limited pull must finish, exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if sprobe.hits429 != 4 {
		t.Fatalf("source answered 429 %d times, want 4 (2 per file)", sprobe.hits429)
	}
	if len(tprobe.blobPUTs) != 2 {
		t.Fatalf("target accepted %d pushes, want 2 after the 429 retries", len(tprobe.blobPUTs))
	}
	threes := 0
	for _, d := range *slept {
		if d == 3*time.Second {
			threes++
		}
	}
	if threes != 4 {
		t.Fatalf("waited Retry-After (3s) %d times, want 4; sleeps: %v", threes, *slept)
	}
	if !strings.Contains(stdout, "2 fetched, 2 uploaded") {
		t.Fatalf("receipt does not reconcile after retries:\n%s", stdout)
	}
	if !strings.Contains(stdout, "6 request(s) answered 429 and were retried") {
		t.Fatalf("receipt does not report the 429 retries:\n%s", stdout)
	}
}

func TestMediaPacerSpacesRequestsAndWidensAfterA429(t *testing.T) {
	slept := fakeMediaClock(t)
	p := newMediaPacer(240) // one request every 250ms
	p.wait()
	p.wait()
	if len(*slept) != 1 || (*slept)[0] != 250*time.Millisecond {
		t.Fatalf("second request slept %v, want one 250ms gap", *slept)
	}
	p.rateLimited("", 0) // no header: fallback wait
	if p.interval <= 250*time.Millisecond {
		t.Fatalf("interval after a 429 = %v, want wider than the base 250ms", p.interval)
	}
	if last := (*slept)[len(*slept)-1]; last != time.Second {
		t.Fatalf("a 429 without Retry-After waited %v, want the 1s fallback", last)
	}
	for i := 0; i < mediaEaseAfter*20; i++ {
		p.succeeded()
	}
	if p.interval != p.base {
		t.Fatalf("interval after a long success run = %v, want it eased back to the base %v", p.interval, p.base)
	}
}

func TestMediaPacerGivesUpAfterTheRetryCap(t *testing.T) {
	fakeMediaClock(t)
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Retry-After", "1")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	t.Cleanup(srv.Close)
	p := newMediaPacer(0)
	resp, err := p.do(srv.Client(), func() (*http.Request, error) { return http.NewRequest(http.MethodGet, srv.URL, nil) })
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want the last 429 handed back", resp.StatusCode)
	}
	if hits != mediaMaxRateLimitRetries+1 {
		t.Fatalf("server saw %d attempts, want %d", hits, mediaMaxRateLimitRetries+1)
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	if d, ok := parseRetryAfter("7", now); !ok || d != 7*time.Second {
		t.Fatalf("seconds form = %v %v", d, ok)
	}
	if d, ok := parseRetryAfter(now.Add(5*time.Second).Format(http.TimeFormat), now); !ok || d != 5*time.Second {
		t.Fatalf("date form = %v %v", d, ok)
	}
	for _, bad := range []string{"", "soon", "-1"} {
		if _, ok := parseRetryAfter(bad, now); ok {
			t.Fatalf("%q parsed as a delay", bad)
		}
	}
}

func TestDevPullListsAMissingBlobAndDoesNotFail(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs, missingBlob: "2026/01/a.png",
	})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	bundle := filepath.Join(t.TempDir(), "b.tar")
	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", bundle)
	if code != exitOK {
		t.Fatalf("a missing blob must not fail the pull, exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if len(tprobe.blobPUTs) != 1 || tprobe.blobPUTs[0] != "2026/01/b.jpg" {
		t.Fatalf("target pushes = %v, want only the file that exists", tprobe.blobPUTs)
	}
	for _, want := range []string{"1 fetched, 1 uploaded", "1 media file(s) the source answered 404 for", "2026/01/a.png", bundle + ".missing.txt"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("receipt lacks %q:\n%s", want, stdout)
		}
	}
	list, err := os.ReadFile(bundle + ".missing.txt")
	if err != nil || strings.TrimSpace(string(list)) != "2026/01/a.png" {
		t.Fatalf("missing list file = %q, %v", list, err)
	}
}

// TestDevPullAServerErrorStillFails: only a 404 is listed. A 500 is a real
// failure and keeps the pull from importing.
func TestDevPullAServerErrorStillFails(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs, failBlob: "2026/01/a.png",
	})
	tgt, tprobe := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, _, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"))
	if code == exitOK {
		t.Fatalf("a 500 on a blob reported success:\n%s", stdout)
	}
	if tprobe.importBytes != 0 {
		t.Fatalf("the target was imported into despite a failed fetch")
	}
	if c, _, _ := devPullFailureDetails(t, stdout); c != "dev_pull_blob_fetch_failed" {
		t.Fatalf("code = %q, want dev_pull_blob_fetch_failed", c)
	}
}

// ── 4. shares and tokens not carried ─────────────────────────────────────────

const devPullSharesJSON = `{"active":true,"shares":[
 {"scope":"acme/default/production","workspace":"acme","project":"default","dataset":"production","surfaces":["media"],"access":"read","source":"stored"},
 {"scope":"acme/default/staging","workspace":"acme","project":"default","dataset":"staging","surfaces":["docs"],"access":"read","source":"stored"},
 {"scope":"other/default/production","workspace":"other","project":"default","dataset":"production","surfaces":["docs"],"access":"read","source":"stored"}]}`

const devPullTokensJSON = `{"tokens":[
 {"label":"twin-local","kind":"api","permissions":["read"],"dataset":"production","revoked_at":null,"expires_at":null},
 {"label":"old key","kind":"api","permissions":["read"],"dataset":"production","revoked_at":"2026-09-01T00:00:00Z","expires_at":null},
 {"label":"expired","kind":"api","permissions":["read"],"dataset":"production","revoked_at":null,"expires_at":"2020-01-01T00:00:00Z"},
 {"label":"staging only","kind":"api","permissions":["read"],"dataset":"staging","revoked_at":null,"expires_at":null},
 {"label":"support desk","kind":"ticket","permissions":["read"],"dataset":"production","revoked_at":null,"expires_at":null}]}`

func TestDevPullNamesSharesAndTokensNotCarried(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs,
		sharesJSON: devPullSharesJSON, tokensJSON: devPullTokensJSON,
	})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"), "--no-media")
	if code != exitOK {
		t.Fatalf("exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	for _, want := range []string{
		"share  acme/default/production  media (read)",
		"token  twin-local  read on production",
		"token  support desk  read on production (kind ticket: recreate it where it was made)",
		"bp -s laptop share add acme/default/production media --access read --yes",
		"bp -s laptop -w acme -p default token create twin-local --permissions read --dataset production --yes",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("receipt lacks %q:\n%s", want, stdout)
		}
	}
	for _, unwanted := range []string{"old key", "expired", "staging only", "acme/default/staging", "other/default"} {
		if strings.Contains(stdout, unwanted) {
			t.Fatalf("receipt lists %q, which is revoked, expired or outside this dataset:\n%s", unwanted, stdout)
		}
	}
}

func TestDevPullNotCarriedInTheMachineReceipt(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{
		profile: "dev", dataset: "production", blobs: devPullBlobs,
		sharesJSON: devPullSharesJSON, tokensJSON: devPullTokensJSON,
	})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "json",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"), "--no-media")
	if code != exitOK {
		t.Fatalf("exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	var doc struct {
		NotCarried devPullNotCarried `json:"not_carried"`
	}
	if err := json.Unmarshal([]byte(stdout), &doc); err != nil {
		t.Fatalf("receipt did not parse: %v\n%s", err, stdout)
	}
	nc := doc.NotCarried
	if len(nc.Shares) != 1 || len(nc.Tokens) != 2 || len(nc.Commands) != 2 {
		t.Fatalf("not_carried = %+v, want 1 share, 2 tokens, 2 commands", nc)
	}
}

func TestDevPullNotCarriedSaysWhenTheSourceRefuses(t *testing.T) {
	workspaceEnvIsolate(t)
	src, _ := devPullSourceServer(t, devPullSourceOpts{profile: "dev", dataset: "production", blobs: devPullBlobs})
	tgt, _ := devPullTargetServer(t, devPullTargetOpts{})
	devPullSaveServers(t, src.URL, tgt.URL)

	// A source that answers 403 on both lists: the pull still succeeds and says
	// the list could not be read.
	refusing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/shares" || strings.HasSuffix(r.URL.Path, "/v1/tokens") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"admin only"}}`))
			return
		}
		src.Config.Handler.ServeHTTP(w, r)
	}))
	t.Cleanup(refusing.Close)
	devPullSaveServers(t, refusing.URL, tgt.URL)

	stdout, stderr, code := runDevPullCmd(t, globals{}, "table",
		"prod", "laptop", "acme/production", "--yes", "--bundle", filepath.Join(t.TempDir(), "b.tar"), "--no-media")
	if code != exitOK {
		t.Fatalf("a refused listing must not fail the pull, exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "could not list shares: HTTP 403") || !strings.Contains(stdout, "could not list tokens: HTTP 403") {
		t.Fatalf("receipt does not say the lists could not be read:\n%s", stdout)
	}
}

func TestShellWordQuotesOnlyWhenNeeded(t *testing.T) {
	cases := map[string]string{
		"twin-local": "twin-local",
		"read,write": "read,write",
		"old key":    "'old key'",
		"it's":       `'it'\''s'`,
		"":           "''",
	}
	for in, want := range cases {
		if got := shellWord(in); got != want {
			t.Fatalf("shellWord(%q) = %q, want %q", in, got, want)
		}
	}
}
