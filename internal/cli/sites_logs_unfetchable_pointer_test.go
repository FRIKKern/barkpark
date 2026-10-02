// sites_logs_unfetchable_pointer_test.go — THE GUARD FOR task-2f6445d961a84992.
//
// A KEY NAMED build_log_url MUST NOT BE PRINTED AS A LINK UNLESS THE READER CAN
// OPEN IT. `internal/builder` stamped `file://` + a path on the builder host's
// own filesystem, and this command printed it bare as `log: <url>` — a pointer
// that resolves on exactly one machine, and never the operator's.
//
// BOTH ARMS, and they are different tests on purpose:
//
//   - THE LOSING ARM: a fixture whose build_log_url scheme is NOT reader-
//     fetchable must make the surface say so and name the door that works.
//     Revert runSitesLogs to the bare `log: %s` line and this reds.
//   - THE QUIET ARM: a legitimate https:// URL must still print as a link,
//     unchanged, with none of the honesty copy. Over-broadening the guard into
//     "warn on every URL" reds this.
//
// The losing arm is a TABLE over shapes — file://, ftp://, s3://, journal:, a
// bare path — because the defect is a SHAPE (the reader's transport cannot
// retrieve it), not a two-name list somebody has to keep extending.
package cli

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// runSitesLogsPointerFixture points `bp sites logs blog` (the LATEST-keyed
// pointer view, no deployment id) at a scripted cloud whose one deployment
// carries buildLogURL verbatim.
func runSitesLogsPointerFixture(t *testing.T, buildLogURL string, output string) (string, int) {
	t.Helper()
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-1","site_id":"site-1","status":"failed","build_log_url":`+jsonString(buildLogURL)+`,"inserted_at":"2026-06-26T02:00:00Z"}
		]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = output
		return runSites(out, globals{}, []string{"logs", "blog"})
	})
	return stdout, code
}

// jsonString quotes a fixture value so a scheme with a `//` or a `"` cannot
// break the hand-written JSON body above.
func jsonString(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

// TestSitesLogsRefusesToLinkAnUnfetchablePointer is the LOSING arm.
func TestSitesLogsRefusesToLinkAnUnfetchablePointer(t *testing.T) {
	for _, raw := range []string{
		"file:///var/lib/barkpark/build-logs/dep-1.log",
		"ftp://logs.example.com/dep-1.log",
		"s3://barkpark-logs/dep-1.log",
		"journal:barkpark-builder",
		"/var/lib/barkpark/build-logs/dep-1.log",
	} {
		t.Run(raw, func(t *testing.T) {
			stdout, code := runSitesLogsPointerFixture(t, raw, "table")
			if code != exitOK {
				t.Fatalf("exit = %d, want 0\n%s", code, stdout)
			}
			// (1) It must NOT be presented as a retrievable log.
			if strings.Contains(stdout, "log: "+raw) {
				t.Fatalf("a reader CANNOT fetch %q, yet the surface printed it as `log: <url>`:\n%s", raw, stdout)
			}
			// (2) It must say why, in the reader's terms.
			if !strings.Contains(stdout, "not a URL you can open") {
				t.Fatalf("the surface must SAY the pointer is unopenable by its reader, got:\n%s", stdout)
			}
			// (3) It must name the door that DOES serve the log.
			if !strings.Contains(stdout, "bp sites logs blog dep-1") {
				t.Fatalf("the surface must name the deployment-keyed read, got:\n%s", stdout)
			}
		})
	}
}

// TestSitesLogsStillLinksAFetchableURL is the QUIET arm: a legitimate https
// pointer keeps printing as a link, with none of the honesty copy.
func TestSitesLogsStillLinksAFetchableURL(t *testing.T) {
	const ok = "https://logs.example.com/dep-1.log"
	stdout, code := runSitesLogsPointerFixture(t, ok, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "log: "+ok) {
		t.Fatalf("a fetchable https pointer must still print as a link:\n%s", stdout)
	}
	if strings.Contains(stdout, "not a URL you can open") {
		t.Fatalf("the guard fired on a URL the reader CAN fetch — it is too broad:\n%s", stdout)
	}
}

// TestSitesLogsJSONMarksFetchability: the machine reader gets the same fact the
// human does, so a script does not have to re-derive the scheme rule.
func TestSitesLogsJSONMarksFetchability(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want string
	}{
		{"https://logs.example.com/dep-1.log", `"build_log_url_fetchable":true`},
		{"file:///var/lib/barkpark/build-logs/dep-1.log", `"build_log_url_fetchable":false`},
		{"", `"build_log_url_fetchable":false`},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			stdout, code := runSitesLogsPointerFixture(t, tc.raw, "json")
			if code != exitOK {
				t.Fatalf("exit = %d, want 0\n%s", code, stdout)
			}
			if !strings.Contains(strings.ReplaceAll(stdout, " ", ""), tc.want) {
				t.Fatalf("want %s in JSON for %q, got:\n%s", tc.want, tc.raw, stdout)
			}
		})
	}
}
