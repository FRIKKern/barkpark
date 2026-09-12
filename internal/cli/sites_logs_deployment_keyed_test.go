package cli

// sites_logs_deployment_keyed_test.go — `bp sites logs <site> <deployment-id>`,
// the client half of dr-bl-recorder-http-read-path.
//
// THE DEFECT THIS EXISTS FOR. The control plane grew an operator read path for
// the black box recorder — GET /v1/sites/:id/deployments/:dep_id/build-log,
// answered by `BarkparkCloud.Sites.BuildLog.for_deployment/2` — and `bp sites
// logs` could not address it. The verb was SLUG-keyed: it resolved the LATEST
// deployment and printed the builder's `build_log_url` pointer, which is the
// wrong key by construction, because "why did deployment <uuid> fail?" is a
// question about ONE deployment and a site that has deployed since has moved
// every latest-pointer off it.
//
// THE TRAP, and it is why the negative arm below is the test that matters. The
// server exposes the structured RECORD now; the recorded BYTES are a separate,
// still-blocked slice (the box refuses them — the build env file carries
// BARKPARK_TOKEN= in plaintext). A client whose output or --help implied the
// bytes were available would be describing a guarantee the server does not
// provide. So TestSitesLogsNeverClaimsTheRecordedBytesAreAvailable scans the
// help and the rendered 200 for byte/content CLAIMS, and carries its own
// non-vacuity guard: the scanner is fed the exact over-claiming sentence and
// must flag it, so the day the detector goes blind it says so instead of
// passing everything.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

// sitesFixtureBody is the one-site listing every test here resolves "blog"
// against.
const sitesFixtureBody = `{"sites":[
	{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
]}`

const buildLogPath = "/v1/sites/site-1/deployments/dep-9/build-log"

// runSitesLogsFixture points `bp sites logs blog dep-9` at a scripted
// control plane answering the build-log route with (status, body), and returns
// the recorded requests plus what the command printed.
func runSitesLogsFixture(t *testing.T, status int, body string, output string) (*scriptedCloud, string, string, int) {
	t.Helper()
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody).
		route("GET", buildLogPath, status, body)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = output
		return runSites(out, []string{"logs", "blog", "dep-9"})
	})
	return s, stdout, stderr, code
}

// TestSitesLogsAddressesTheBuildLogByDeploymentID is the positive key test: the
// second positional MUST become the deployment segment of the build-log route,
// and the latest-deployment listing must not be consulted at all — reading the
// latest pointer is the very thing this form replaces.
func TestSitesLogsAddressesTheBuildLogByDeploymentID(t *testing.T) {
	s, stdout, _, code := runSitesLogsFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"20260908-abc","log_state":"available","available":true,
		"log_path":"/opt/barkpark/logs/blog-20260908-abc.log","log_bytes":4096,"exit_code":1,
		"failure_reason":"nixpacks build failed",
		"stages":[{"name":"build","status":"failed"}],
		"journal_command":"journalctl -u barkpark-site-blog"
	}`, "table")

	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if got := len(s.requestsFor("GET", buildLogPath)); got != 1 {
		t.Fatalf("expected exactly one GET %s, got %d (requests: %#v)", buildLogPath, got, s.requests)
	}
	if got := len(s.requestsFor("GET", "/v1/sites/site-1/deployments")); got != 0 {
		t.Fatalf("the deployment-keyed form must not read the latest-deployment listing, got %d requests", got)
	}
	for _, want := range []string{"dep-9", "20260908-abc", "log_state: available", "exit code: 1", "nixpacks build failed", "stage build: failed"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("render missing %q:\n%s", want, stdout)
		}
	}
}

// TestSitesLogsRendersEachServerOutcomeDistinguishably: the control plane
// separates its answers BY STATUS CODE on purpose (404 no such deployment / 410
// evicted / 200 with an honest log_state, plus 409 box_unbound and 502
// box_unreachable). A client that collapsed any two of them would reintroduce
// exactly the conflation `Sites.BuildLog` was written to remove — so this
// asserts each case names its own thing AND that no two renders are equal.
func TestSitesLogsRendersEachServerOutcomeDistinguishably(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		body     string
		wantExit int
		want     []string
	}{
		{
			name:   "200 available",
			status: http.StatusOK,
			body:   `{"deployment_id":"dep-9","build_id":"b1","log_state":"available","available":true}`,
			want:   []string{"log_state: available"},
		},
		{
			name:   "200 missing",
			status: http.StatusOK,
			body:   `{"deployment_id":"dep-9","build_id":"b1","log_state":"missing","available":false}`,
			want:   []string{"log_state: missing"},
		},
		{
			name:   "200 never_recorded with a build id",
			status: http.StatusOK,
			body:   `{"deployment_id":"dep-9","build_id":"b1","log_state":"never_recorded","available":false}`,
			want:   []string{"log_state: never_recorded", "build id: b1"},
		},
		{
			// "it was here and retention took it" — a definite answer, so exit 0.
			name:   "410 evicted",
			status: http.StatusGone,
			body:   `{"deployment_id":"dep-9","build_id":"b1","error":"build_log_evicted","available":false,"log_state":"evicted","evicted_at":"2026-09-01T00:00:00Z"}`,
			want:   []string{"log_state: evicted", "reclaimed by retention at 2026-09-01T00:00:00Z"},
		},
		{
			name:     "404 no such deployment",
			status:   http.StatusNotFound,
			body:     `{"error":"not_found"}`,
			wantExit: exitGeneric,
			want:     []string{"no deployment dep-9 under site \"blog\""},
		},
		{
			name:     "409 box unbound",
			status:   http.StatusConflict,
			body:     `{"deployment_id":"dep-9","build_id":"b1","error":"box_unbound","detail":"this site is not bound to a live instance, so no box can be asked"}`,
			wantExit: exitGeneric,
			want:     []string{"not bound to a live instance"},
		},
		{
			// `unknown` is one of the recorder's own five states. The control
			// plane does not recognise it, answers 502 and names the word it got
			// in `box_log_state` — the CLI must print that word VERBATIM rather
			// than smoothing it into a generic failure.
			name:     "502 box answered with a log_state the plane does not understand",
			status:   http.StatusBadGateway,
			body:     `{"deployment_id":"dep-9","build_id":"b1","error":"box_unreachable","detail":"the box answered with a log_state this control plane does not understand","box_log_state":"unknown"}`,
			wantExit: exitGeneric,
			want:     []string{`the box reported log_state "unknown"`},
		},
	}

	seen := map[string]string{}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, stdout, stderr, code := runSitesLogsFixture(t, tc.status, tc.body, "table")
			if code != tc.wantExit {
				t.Fatalf("exit = %d, want %d\nstdout:%s\nstderr:%s", code, tc.wantExit, stdout, stderr)
			}
			rendered := stdout + stderr
			for _, want := range tc.want {
				if !strings.Contains(rendered, want) {
					t.Fatalf("%s: render missing %q:\nstdout:%s\nstderr:%s", tc.name, want, stdout, stderr)
				}
			}
			if prev, dup := seen[rendered]; dup {
				t.Fatalf("%s renders identically to %s — the outcomes are not distinguishable:\n%s", tc.name, prev, rendered)
			}
			seen[rendered] = tc.name
		})
	}
}

// TestSitesLogsPreRecorderDeploymentIsItsOwnCase: a Deployment row with NO
// build_id is answered by `BuildLog.unkeyed/1` as a 200 carrying `build_id`
// null. It is neither an error nor a missing log, and rendering it as either
// would put a legitimate "predates the recorder" deployment back in the same
// bucket as "no such deployment".
func TestSitesLogsPreRecorderDeploymentIsItsOwnCase(t *testing.T) {
	_, stdout, stderr, code := runSitesLogsFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":null,"log_state":"never_recorded","available":false,
		"detail":"this deployment carries no build_id (it predates build-keyed recording), so nothing was ever recorded under it"
	}`, "table")

	if code != exitOK {
		t.Fatalf("a pre-recorder deployment is not a failure: exit = %d\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "predates build-keyed recording") {
		t.Fatalf("the pre-recorder case must say so in its own words:\n%s", stdout)
	}
	if !strings.Contains(stdout, "not a missing log and not an error") {
		t.Fatalf("the pre-recorder case must refuse both wrong readings explicitly:\n%s", stdout)
	}
	// It must NOT read like the 404 or like a plain empty record.
	if strings.Contains(stdout+stderr, "no deployment dep-9") {
		t.Fatalf("a pre-recorder deployment rendered as a 404:\n%s", stdout+stderr)
	}

	// And the machine surface says the same thing without prose.
	_, jsonOut, _, jcode := runSitesLogsFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":null,"log_state":"never_recorded","available":false
	}`, "json")
	if jcode != exitOK {
		t.Fatalf("-o json exit = %d, want 0\n%s", jcode, jsonOut)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		t.Fatalf("-o json is not JSON: %v\n%s", err, jsonOut)
	}
	if env["pre_recorder"] != true {
		t.Fatalf("-o json must flag the pre-recorder case, got %#v", env["pre_recorder"])
	}
	if env["build_id"] != nil {
		t.Fatalf("a null build_id must stay null, got %#v", env["build_id"])
	}
	if env["log_state"] != "never_recorded" {
		t.Fatalf("log_state must be relayed verbatim, got %#v", env["log_state"])
	}
}

// byteClaimRe matches a sentence CLAIMING the recorded log bytes/content are
// produced by this surface. It deliberately keys on the verb+object pair, so
// naming a path or a byte COUNT (which the record legitimately carries) is not a
// claim, and neither is a negated sentence — negation is stripped by
// claimsRecordedBytes below, line by line.
var byteClaimRe = regexp.MustCompile(`(?i)\b(print|prints|show|shows|stream|streams|tail|tails|follow|follows|output|outputs|download|downloads|fetch|fetches|dump|dumps|cat|view|views|display|displays)\b[^.\n]{0,40}\b(log|build)\s+(bytes|contents|content|output|lines|text)\b`)

// negationRe marks a line as a DENIAL rather than a claim. A test that flagged
// "does not print the build log contents" would force the code to stop saying
// the honest thing, which is the opposite of the point.
var negationRe = regexp.MustCompile(`(?i)\b(not|never|cannot|can't|without|no)\b`)

// claimsRecordedBytes returns the offending lines of text, if any.
func claimsRecordedBytes(text string) []string {
	var bad []string
	for _, line := range strings.Split(text, "\n") {
		if byteClaimRe.MatchString(line) && !negationRe.MatchString(line) {
			bad = append(bad, strings.TrimSpace(line))
		}
	}
	return bad
}

// TestSitesLogsByteClaimDetectorIsNotBlind is the non-vacuity guard for the
// negative arm. A scanner that matches nothing passes everything, so it is fed
// the exact over-claim it exists to catch — and the exact honest denial it must
// NOT catch.
func TestSitesLogsByteClaimDetectorIsNotBlind(t *testing.T) {
	claims := []string{
		"  bp sites logs <site> <deployment-id>   print the build log contents",
		"prints the recorded log output for one deployment",
		"streams the build log lines from the box",
		"downloads the log bytes recorded for that build",
	}
	for _, c := range claims {
		if got := claimsRecordedBytes(c); len(got) == 0 {
			t.Fatalf("detector went blind on an over-claim: %q", c)
		}
	}
	denials := []string{
		"this is the recorded build RECORD, not the build log bytes",
		"IT DOES NOT PRINT THE BUILD LOG BYTES and cannot",
		"  recorded on the box at /var/log/x.log (4096 bytes) (not fetched by this command)",
	}
	for _, d := range denials {
		if got := claimsRecordedBytes(d); len(got) != 0 {
			t.Fatalf("detector flagged an honest denial %q: %v", d, got)
		}
	}
}

// TestSitesLogsNeverClaimsTheRecordedBytesAreAvailable is THE NEGATIVE ARM, and
// #17752 moved what it guards. The bytes ARE served now — but only the SCRUBBED
// ones, off a second route, and only through `runSiteBuildLogBytes`. What may
// still never happen is the RECORD render implying it holds the bytes: this
// fixture scripts the record route alone, so anything the 200 says about bytes
// here is said without having read any. The help's promise moved with the code —
// it no longer claims the bytes can never be served, it claims UNSCRUBBED ones
// are refused by name, which is the guarantee the command now actually makes.
func TestSitesLogsNeverClaimsTheRecordedBytesAreAvailable(t *testing.T) {
	withTempConfigHome(t)
	helpOut, _, helpCode := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"logs", "--help"})
	})
	if helpCode != exitOK {
		t.Fatalf("help exit = %d, want 0", helpCode)
	}
	if strings.TrimSpace(helpOut) == "" {
		t.Fatal("help printed nothing — the scan below would be vacuous")
	}
	if bad := claimsRecordedBytes(helpOut); len(bad) != 0 {
		t.Fatalf("--help claims the recorded log bytes are available:\n%s", strings.Join(bad, "\n"))
	}
	if !strings.Contains(helpOut, "IT WILL NOT HAND YOU UNSCRUBBED BYTES") {
		t.Fatalf("--help must say plainly that unscrubbed bytes are refused:\n%s", helpOut)
	}
	if !strings.Contains(helpOut, `not the same fact as "there is no log"`) {
		t.Fatalf("--help must say a refusal is not an absence:\n%s", helpOut)
	}

	// The richest 200 the route can answer with: log_state available, a path, a
	// byte count. If any render over-claims, this one does.
	_, stdout, _, code := runSitesLogsFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"b1","log_state":"available","available":true,
		"log_path":"/opt/barkpark/logs/blog-b1.log","log_bytes":40960,
		"journal_command":"journalctl -u barkpark-site-blog"
	}`, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if bad := claimsRecordedBytes(stdout); len(bad) != 0 {
		t.Fatalf("the 200 render claims the recorded log bytes are available:\n%s", strings.Join(bad, "\n"))
	}
	if !strings.Contains(stdout, siteBuildLogBytesNotice) {
		t.Fatalf("the 200 render must carry the not-the-bytes notice:\n%s", stdout)
	}
	if !strings.Contains(stdout, "not fetched by this command") {
		t.Fatalf("naming the on-box path must say it was not fetched:\n%s", stdout)
	}

	// The machine surface carries the same fact as a FIELD, so a script never
	// has to parse prose to learn the bytes are absent.
	_, jsonOut, _, _ := runSitesLogsFixture(t, http.StatusOK, `{
		"deployment_id":"dep-9","build_id":"b1","log_state":"available","available":true,
		"log_path":"/opt/barkpark/logs/blog-b1.log","log_bytes":40960
	}`, "json")
	var env map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		t.Fatalf("-o json is not JSON: %v\n%s", err, jsonOut)
	}
	if env["log_bytes_served"] != false {
		t.Fatalf("-o json must declare log_bytes_served:false, got %#v", env["log_bytes_served"])
	}
	// No key anywhere in the envelope may carry log CONTENT.
	for _, forbidden := range []string{"log", "log_content", "log_contents", "log_lines", "log_text", "content"} {
		if _, present := env[forbidden]; present {
			t.Fatalf("-o json carries a %q key — the envelope must not offer log content", forbidden)
		}
	}
}

// TestSitesLogsSlugFormStillWorksAndNamesTheDeploymentKeyedForm: the pointer
// view is unchanged (it answers a different question), but it now names the
// deployment-keyed verb instead of leaving the user to find it.
func TestSitesLogsSlugFormNamesTheDeploymentKeyedForm(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-1","site_id":"site-1","status":"building","build_log_url":"https://logs.example.com/dep-1.log","inserted_at":"2026-06-26T02:00:00Z"}
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
	if !strings.Contains(stdout, "bp sites logs blog dep-1") {
		t.Fatalf("the pointer view must name the deployment-keyed form:\n%s", stdout)
	}
	if len(s.requestsFor("GET", "/v1/sites/site-1/deployments/dep-1/build-log")) != 0 {
		t.Fatal("the slug form must not read the operator-gated build-log route")
	}
}

// TestSitesLogsRejectsAThirdPositional: the usage line names two operands, so a
// third is a usage error rather than a silently ignored argument.
func TestSitesLogsRejectsAThirdPositional(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, sitesFixtureBody)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"logs", "blog", "dep-9", "extra"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage=%d\n%s", code, exitUsage, stderr)
	}
}
