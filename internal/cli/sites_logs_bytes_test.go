package cli

// sites_logs_bytes_test.go — `bp sites logs <site> <deployment-id>` and the
// RECORDED BYTES, the cli half of dr-bl-recorder-http-read-path c3.
//
// THE DEFECT THIS EXISTS FOR, stated as the row states it: a REFUSAL THAT READS
// AS AN ABSENCE HIDES A LOG SITTING ON THE BOX. #17752 opened
// `GET /v1/sites/:id/deployments/:dep_id/build-log/bytes`, whose 422
// `build_log_unscrubbed` means the bytes EXIST and are withheld because they
// were never folded through the secret scrubber. An operator told "no log found"
// stops looking for a file that is right there on disk. Every arm below exists
// to keep one of six different facts from collapsing into that one sentence.
//
// THE TEST THAT MATTERS is TestSitesLogsRefusesUnscrubbedBytesByName, and it
// asserts BOTH DIRECTIONS: the refusal is named, AND no empty-log/no-log-found
// wording appears. A presence assertion alone would pass on a render that
// printed the refusal and then, two lines down, also said the log was empty.
//
// THE OLD-BOX ARM is the subtle one. A box predating `bytes=1` answers the
// RECORD — a 200 with `log_state: "available"` and NO `tail` key. Decoded into
// Go, an absent `tail` and an explicit `"tail": null` are the same nil pointer,
// so the discriminator is the KEY SET (SiteBuildLogBytes.TailPresent), and the
// two arms below differ by exactly that one key.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const buildLogBytesPath = "/v1/sites/site-1/deployments/dep-9/build-log/bytes"

// a 200 record so the deployment-keyed render always reaches the byte read.
const bytesRecordFixture = `{
	"deployment_id":"dep-9","build_id":"b1","log_state":"available","available":true,
	"log_path":"/opt/barkpark/logs/blog-b1.log","log_bytes":4096
}`

// runSitesLogsBytesFixture scripts BOTH reads the deployment-keyed form makes —
// the record route and the byte route — and returns what the command printed.
func runSitesLogsBytesFixture(t *testing.T, status int, body string, output string) (*scriptedCloud, string, string, int) {
	t.Helper()
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody).
		route("GET", buildLogPath, http.StatusOK, bytesRecordFixture).
		route("GET", buildLogBytesPath, status, body)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = output
		return runSites(out, []string{"logs", "blog", "dep-9"})
	})
	return s, stdout, stderr, code
}

// absenceWordings is the vocabulary a refusal must never borrow. Each phrase
// tells an operator the bytes are NOT THERE, which is the false half of the fact
// when the server said they exist and are withheld.
var absenceWordings = []string{
	"no log found", "no log", "empty log", "log is empty",
	"recorded no bytes", "nothing was recorded", "there is no log",
}

func assertNoAbsenceWording(t *testing.T, text string) {
	t.Helper()
	low := strings.ToLower(text)
	for _, w := range absenceWordings {
		if strings.Contains(low, w) {
			t.Fatalf("the render borrowed the absence wording %q for a refusal:\n%s", w, text)
		}
	}
}

// THE KEY TEST. `bp sites logs <site> <dep-id>` must actually ASK the byte
// sub-route, and a served 200 must put the bytes on stdout.
func TestSitesLogsFetchesAndPrintsTheRecordedBytes(t *testing.T) {
	s, stdout, _, code := runSitesLogsBytesFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"b1","available":true,"slug":"blog",
		"log_state":"available","log_scrub":3,"log_path":"/opt/barkpark/logs/blog-b1.log",
		"log_bytes":4096,"tail_bytes":58,"truncated":false,
		"tail":"npm ERR! code ELIFECYCLE\nnpm ERR! build failed\n","evicted_at":null
	}`, "table")

	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if got := len(s.requestsFor("GET", buildLogBytesPath)); got != 1 {
		t.Fatalf("expected exactly one GET %s, got %d (requests: %#v)", buildLogBytesPath, got, s.requests)
	}
	for _, want := range []string{"npm ERR! code ELIFECYCLE", "npm ERR! build failed", "58 bytes", "scrub pattern-set 3"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("render missing %q:\n%s", want, stdout)
		}
	}
	assertNoAbsenceWording(t, stdout)
}

// A truncated tail carries its own marker line as the FIRST line of the bytes —
// it is IN the log, not only in the envelope — and the render must not swallow
// it while re-wrapping.
func TestSitesLogsPrintsTheTruncationMarkerLine(t *testing.T) {
	_, stdout, _, code := runSitesLogsBytesFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"b1","available":true,
		"log_state":"available","log_scrub":3,"log_bytes":9000000,"tail_bytes":40,
		"truncated":true,
		"tail":"…[truncated: showing the last 40 of 9000000 bytes]\nfinal line\n"
	}`, "table")

	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "…[truncated") {
		t.Fatalf("the truncation marker line must survive to stdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "TRUNCATED") {
		t.Fatalf("the envelope flag must be named too:\n%s", stdout)
	}
	if !strings.Contains(stdout, "final line") {
		t.Fatalf("the bytes after the marker must still print:\n%s", stdout)
	}
}

// THE TEST THAT MATTERS (criterion c1). 422 build_log_unscrubbed: the bytes
// EXIST and are withheld. Both directions asserted — the refusal is named, and
// no absence wording appears anywhere in the output.
func TestSitesLogsRefusesUnscrubbedBytesByName(t *testing.T) {
	_, stdout, stderr, code := runSitesLogsBytesFixture(t, http.StatusUnprocessableEntity, `{
		"deployment_id":"dep-9","build_id":"b1","error":"build_log_unscrubbed",
		"available":false,"log_scrub":null,"log_state":"available","log_bytes":30993,
		"log_path":"/opt/barkpark/logs/blog-b1.log","tail":null
	}`, "table")

	all := stdout + stderr
	if code != exitOK {
		t.Fatalf("a refusal about the bytes must not erase the record answer: exit = %d\n%s", code, all)
	}
	// PRESENCE: the unscrubbed state is named, and so is the fact the bytes exist.
	for _, want := range []string{"NEVER SCRUBBED", "withheld", "refusal, not an absence", "30993 bytes"} {
		if !strings.Contains(all, want) {
			t.Fatalf("the refusal must name %q:\n%s", want, all)
		}
	}
	// ABSENCE: no empty-log / no-log-found wording anywhere.
	assertNoAbsenceWording(t, all)

	// And the machine surface says the same thing without prose.
	_, jsonOut, _, _ := runSitesLogsBytesFixture(t, http.StatusUnprocessableEntity, `{
		"deployment_id":"dep-9","build_id":"b1","error":"build_log_unscrubbed",
		"log_scrub":null,"log_state":"available","log_bytes":30993,"tail":null
	}`, "json")
	var env map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		t.Fatalf("-o json is not JSON: %v\n%s", err, jsonOut)
	}
	if env["log_bytes_served"] != false {
		t.Fatalf("a withheld log must not read as served: %#v", env["log_bytes_served"])
	}
	if env["bytes_error"] != "build_log_unscrubbed" {
		t.Fatalf("-o json must carry the server's own refusal word, got %#v", env["bytes_error"])
	}
	if env["tail"] != nil {
		t.Fatalf("a withheld tail must be null, got %#v", env["tail"])
	}
}

// AN OLD BOX IS NOT AN EMPTY LOG. The two cases below differ by exactly one
// thing — whether the body carries a `tail` KEY — and they must not render the
// same. A decoder keying on the VALUE cannot tell them apart at all.
func TestSitesLogsDiscriminatesOnTheTailKeyNotItsValue(t *testing.T) {
	// (a) the key is ABSENT: a box too old to serve bytes. We do not know.
	_, oldBox, _, code := runSitesLogsBytesFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"b1","available":true,"log_state":"available","log_scrub":3
	}`, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, oldBox)
	}
	if !strings.Contains(oldBox, "no tail field at all") || !strings.Contains(oldBox, "we do not know") {
		t.Fatalf("an old box's answer must read as 'we do not know', not as an empty log:\n%s", oldBox)
	}
	assertNoAbsenceWording(t, oldBox)

	// (b) the key is PRESENT and null with a non-available state: a genuine
	// absence, and the only arm allowed to say so.
	_, noBytes, _, _ := runSitesLogsBytesFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"b1","available":false,
		"log_state":"never_recorded","log_scrub":3,"tail":null
	}`, "table")
	if !strings.Contains(noBytes, "recorded no bytes") {
		t.Fatalf("a real absence must say so plainly:\n%s", noBytes)
	}
	if oldBox == noBytes {
		t.Fatal("the absent-key and the null-value renders are identical — the discriminator is the VALUE, not the key")
	}
}

// EVERY OTHER STATUS, each naming its own thing and none of them equal to
// another. The 502 and 409 arms carry the row's own words: "we do not know",
// never "there is no log".
func TestSitesLogsRendersEachByteStatusDistinguishably(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   []string
	}{
		{
			name:   "410 evicted names the date",
			status: http.StatusGone,
			body:   `{"error":"build_log_evicted","evicted_at":"2026-09-01T04:00:00Z","log_state":"evicted"}`,
			want:   []string{"reclaimed by retention", "2026-09-01T04:00:00Z", "not coming back"},
		},
		{
			name:   "404 is a disagreement, not a missing deployment",
			status: http.StatusNotFound,
			body:   `{"error":"not_found"}`,
			want:   []string{"does not recognise deployment dep-9", "the two disagree", "we do not know"},
		},
		{
			name:   "409 box_unbound could not ask",
			status: http.StatusConflict,
			body:   `{"error":"box_unbound","detail":"this site is not bound to a live instance"}`,
			want:   []string{"no box is bound", "we do not know"},
		},
		{
			name:   "502 box_unreachable is not an absence",
			status: http.StatusBadGateway,
			body:   `{"error":"box_unreachable","detail":"could not reach the box that recorded this build"}`,
			want:   []string{"could not be asked", "we do not know", "could not reach the box"},
		},
	}

	renders := map[string]string{}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, stdout, stderr, code := runSitesLogsBytesFixture(t, tc.status, tc.body, "table")
			all := stdout + stderr
			if code != exitOK {
				t.Fatalf("the byte read's outcome must not erase the record answer: exit = %d\n%s", code, all)
			}
			for _, want := range tc.want {
				if !strings.Contains(all, want) {
					t.Fatalf("render missing %q:\n%s", want, all)
				}
			}
			assertNoAbsenceWording(t, all)
			for other, prev := range renders {
				if prev == all {
					t.Fatalf("%q renders identically to %q — two different facts collapsed into one", tc.name, other)
				}
			}
			renders[tc.name] = all
		})
	}
}

// A pre-recorder deployment carries no build_id, so there is no key to ask the
// byte route about. The command must not ask — a 404 about a build that never
// existed, printed beside a 200 about the deployment that did, is noise that
// reads like a fault.
func TestSitesLogsDoesNotAskForBytesOfAPreRecorderDeployment(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody).
		route("GET", buildLogPath, http.StatusOK,
			`{"deployment_id":"dep-9","build_id":null,"log_state":"never_recorded","available":false}`)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"logs", "blog", "dep-9"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if got := len(s.requestsFor("GET", buildLogBytesPath)); got != 0 {
		t.Fatalf("a deployment with no build_id has no byte key to ask about, got %d requests", got)
	}
}

// THE FALLBACK SENTENCE (criterion c2). The slug form's pointer view used to
// promise "the builder writes it once the build starts" — a promise that can
// never come true for a box-keyed deployment, because `build_log_url` is stamped
// only by the off-band builder door.
func TestSitesLogsPointerViewDoesNotPromiseABuilderWrite(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-1","site_id":"site-1","status":"building","build_log_url":"","inserted_at":"2026-06-26T02:00:00Z"}
		]}`)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"logs", "blog"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if strings.Contains(stdout, "the builder writes it once the build starts") {
		t.Fatalf("the pointer view still promises a write that never happens for a box build:\n%s", stdout)
	}
	if !strings.Contains(stdout, "off-band builder door") {
		t.Fatalf("the fallback must say WHO stamps that column, so the absence stops reading as 'wait longer':\n%s", stdout)
	}
}
