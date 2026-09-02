package cli

// cloud_autoupdate_cmd_test.go proves `bp cloud autoupdate` and `bp cloud
// rollout` against a fake control plane: the four policy verbs PATCH the
// autoupdate route with the RIGHT body, render an honest receipt (pin carries
// the no-rollback caveat), and pass -o json through; the rollout verbs hit the
// PLATFORM-OPERATOR `/v1/operator/autoupdate*` GET/POST routes WITH the session
// bearer and render the fleet brake state; and the auth / usage / not-found /
// forbidden edges match the cloud-verb contract. None of these verbs ever writes
// bp config.
//
// Every rollout assertion goes through assertOperatorCall, which checks the path
// and the Authorization header together — see its comment for why checking one
// without the other is what let this file stay green over a dead feature.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// autoupdateServer stands up a fake control plane that records the last
// method/path/auth/body it saw and answers with the given status + body. It
// seeds a cloud login pointed at itself so the command resolves a UUID instance
// with no fleet-list round trip.
func autoupdateServer(t *testing.T, status int, body string) (rec *struct{ method, path, auth, body string }) {
	t.Helper()
	rec = &struct{ method, path, auth, body string }{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		rec.method, rec.path, rec.auth, rec.body = r.Method, r.URL.Path, r.Header.Get("Authorization"), string(raw)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return rec
}

func runAutoupdate(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudAutoupdate(w, globals{}, args)
	return sout.String(), serr.String(), code
}

func runRollout(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudRollout(w, globals{}, args)
	return sout.String(), serr.String(), code
}

func TestAutoupdatePinSendsBodyAndReceipt(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ok":true,"autoupdate":{"enabled":true,"paused":false,"pinned_release":"v1.4.2"}}`)

	stdout, stderr, code := runAutoupdate(t, "table", "pin", testInstanceID, "v1.4.2")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr: %s", code, stderr)
	}
	if rec.method != "PATCH" || rec.path != "/v1/barkparks/"+testInstanceID+"/autoupdate" {
		t.Fatalf("hit %s %s, want PATCH the autoupdate route", rec.method, rec.path)
	}
	if rec.auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud bearer", rec.auth)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(rec.body), &body); err != nil {
		t.Fatalf("body not json: %v (%s)", err, rec.body)
	}
	if body["pinned_release"] != "v1.4.2" || len(body) != 1 {
		t.Fatalf("pin body = %v, want exactly {pinned_release:v1.4.2}", body)
	}
	if !strings.Contains(stdout, "pinned to v1.4.2") || !strings.Contains(stdout, "does not roll back") {
		t.Fatalf("receipt missing pin caveat:\n%s", stdout)
	}
	if !strings.Contains(stdout, "pinned@v1.4.2") {
		t.Fatalf("policy summary missing pin:\n%s", stdout)
	}
}

func TestAutoupdateUnpinSendsBlankPin(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ok":true,"autoupdate":{"enabled":true,"paused":false,"pinned_release":null}}`)

	stdout, _, code := runAutoupdate(t, "table", "unpin", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var body map[string]any
	_ = json.Unmarshal([]byte(rec.body), &body)
	if v, ok := body["pinned_release"]; !ok || v != "" {
		t.Fatalf("unpin body = %v, want {pinned_release:\"\"}", body)
	}
	if !strings.Contains(stdout, "unpinned") {
		t.Fatalf("receipt:\n%s", stdout)
	}
}

func TestAutoupdatePauseAndResumeBodies(t *testing.T) {
	for _, tc := range []struct {
		verb string
		want bool
	}{{"pause", true}, {"resume", false}} {
		rec := autoupdateServer(t, 200, `{"ok":true,"autoupdate":{"enabled":true,"paused":`+boolJSON(tc.want)+`,"pinned_release":null}}`)
		_, stderr, code := runAutoupdate(t, "table", tc.verb, testInstanceID)
		if code != exitOK {
			t.Fatalf("%s exit = %d, want 0\nstderr: %s", tc.verb, code, stderr)
		}
		var body map[string]any
		_ = json.Unmarshal([]byte(rec.body), &body)
		if got, ok := body["autoupdate_paused"].(bool); !ok || got != tc.want {
			t.Fatalf("%s body = %v, want {autoupdate_paused:%v}", tc.verb, body, tc.want)
		}
	}
}

func boolJSON(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func TestAutoupdatePinJSONPassthrough(t *testing.T) {
	autoupdateServer(t, 200, `{"ok":true,"autoupdate":{"enabled":true,"paused":false,"pinned_release":"v1.4.2"}}`)
	stdout, _, code := runAutoupdate(t, "json", "pin", testInstanceID, "v1.4.2")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env struct {
		OK         bool `json:"ok"`
		Autoupdate struct {
			Enabled       bool   `json:"enabled"`
			Paused        bool   `json:"paused"`
			PinnedRelease string `json:"pinned_release"`
		} `json:"autoupdate"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json out not decodable: %v\n%s", err, stdout)
	}
	if !env.OK || env.Autoupdate.PinnedRelease != "v1.4.2" {
		t.Fatalf("json envelope = %+v", env)
	}
}

func TestAutoupdateNotFoundMapsExit(t *testing.T) {
	autoupdateServer(t, 404, `{"error":"not_found"}`)
	_, stderr, code := runAutoupdate(t, "table", "pause", testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want exitNotFound", code)
	}
	if !strings.Contains(stderr, "no such instance") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestAutoupdateInvalidMapsUsage(t *testing.T) {
	// The real control plane emits the NESTED {"error":{"code":"invalid"}} shape
	// on this route (not the flat {"error":"invalid"} string) — this fixture
	// must match production or the test is vacuous (proven pre-fix: it failed
	// with exitGeneric because routeError couldn't decode the nested body).
	autoupdateServer(t, 422, `{"error":{"code":"invalid"}}`)
	_, _, code := runAutoupdate(t, "table", "pin", testInstanceID, "bad")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage", code)
	}
}

func TestAutoupdatePinBlankReleaseRejected(t *testing.T) {
	// No server needed — this fails on arg validation before any network call.
	withTempConfigHome(t)
	_, stderr, code := runAutoupdate(t, "table", "pin", testInstanceID, "   ")
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage", code)
	}
	if !strings.Contains(stderr, "cannot be blank") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestAutoupdateUsageEdges(t *testing.T) {
	withTempConfigHome(t)
	// Unknown verb.
	if _, _, code := runAutoupdate(t, "table", "frobnicate", testInstanceID); code != exitUsage {
		t.Fatalf("unknown verb exit = %d, want usage", code)
	}
	// Missing instance.
	if _, _, code := runAutoupdate(t, "table", "pause"); code != exitUsage {
		t.Fatalf("missing instance exit = %d, want usage", code)
	}
	// Help.
	if out, _, code := runAutoupdate(t, "table", "-h"); code != exitOK || !strings.Contains(out, "self-update policy") {
		t.Fatalf("help exit = %d out=%q", code, out)
	}
}

func TestAutoupdateRequiresLogin(t *testing.T) {
	withTempConfigHome(t) // no cloud token seeded
	_, stderr, code := runAutoupdate(t, "table", "pause", testInstanceID)
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth", code)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("stderr = %q", stderr)
	}
}

// assertOperatorCall is the ONE place the rollout tests state what a rollout call
// must look like on the wire: the platform-operator door AND the key that opens
// it. Splitting these apart is how this suite went vacuous — every rollout
// assertion here used to check the path alone, so it stayed green while the verb
// aimed a bp-login SESSION at `/v1/admin/autoupdate*`, a route gated by a
// constant-time compare against WORKER_TOKEN that no human credential can ever
// satisfy (isu-backlog-operator-principal). Path without credential proves the
// request was addressed; credential without path proves it was signed; only both
// together prove it could have succeeded.
func assertOperatorCall(t *testing.T, rec *struct{ method, path, auth, body string }, wantMethod, wantPath string) {
	t.Helper()
	if rec.method != wantMethod || rec.path != wantPath {
		t.Fatalf("hit %s %s, want %s %s", rec.method, rec.path, wantMethod, wantPath)
	}
	if strings.HasPrefix(rec.path, "/v1/admin/") {
		t.Fatalf("rollout knocked on the WORKER door %s — a bp-login session can never open it", rec.path)
	}
	if rec.auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer %q — an unauthenticated call cannot pass "+
			"require_platform_operator no matter which path it hits", rec.auth, "Bearer sess-abc")
	}
}

func TestRolloutStatusRendersState(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ok":true,"halted":false,"eligible":3,"behind":2,"in_flight":1}`)
	stdout, stderr, code := runRollout(t, "table", "status")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr: %s", code, stderr)
	}
	assertOperatorCall(t, rec, "GET", "/v1/operator/autoupdate")
	for _, want := range []string{"running", "eligible:  3", "behind:    2", "in-flight: 1"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("status render missing %q:\n%s", want, stdout)
		}
	}
}

func TestRolloutHaltPostsAndReceipts(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ok":true,"halted":true}`)
	stdout, _, code := runRollout(t, "table", "halt")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	assertOperatorCall(t, rec, "POST", "/v1/operator/autoupdate/halt")
	if !strings.Contains(stdout, "halted") || !strings.Contains(stdout, "HALTED") {
		t.Fatalf("halt render:\n%s", stdout)
	}
}

func TestRolloutResumeRoute(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ok":true,"halted":false}`)
	_, _, code := runRollout(t, "table", "resume")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	assertOperatorCall(t, rec, "POST", "/v1/operator/autoupdate/resume")
}

// TestRolloutJSONPathAndAuth closes the last hole: -o json takes a different
// render branch, and it must not take a different REQUEST.
func TestRolloutJSONPathAndAuth(t *testing.T) {
	rec := autoupdateServer(t, 200, `{"ok":true,"halted":true}`)
	if _, _, code := runRollout(t, "json", "halt"); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	assertOperatorCall(t, rec, "POST", "/v1/operator/autoupdate/halt")
}

// TestRolloutForbiddenNamesTheAllowlist pins the honest 403: the caller IS signed
// in (the session bearer went out — asserted, not assumed), the control plane
// refused on the platform-operator allowlist, and the message must name
// PLATFORM_ADMIN_EMAILS. The anti-assertion is the point: telling this operator
// to "log in again" is a lie that costs them a login loop during the incident
// the brake exists for, because a fresh session produces the identical 403.
func TestRolloutForbiddenNamesTheAllowlist(t *testing.T) {
	for _, verb := range []string{"status", "halt", "resume"} {
		rec := autoupdateServer(t, 403, `{"error":"forbidden","required":"platform_operator","scope":"platform"}`)
		_, stderr, code := runRollout(t, "table", verb)
		if code != exitAuth {
			t.Fatalf("%s exit = %d, want exitAuth\nstderr: %s", verb, code, stderr)
		}
		if rec.auth != "Bearer sess-abc" {
			t.Fatalf("%s: 403 path sent auth %q — the refusal must be of a SIGNED request", verb, rec.auth)
		}
		if !strings.Contains(stderr, "PLATFORM_ADMIN_EMAILS") {
			t.Fatalf("%s: 403 message must name the allowlist knob, got %q", verb, stderr)
		}
		if !strings.Contains(stderr, "not a platform operator") {
			t.Fatalf("%s: 403 message must say WHO was refused, got %q", verb, stderr)
		}
		if strings.Contains(stderr, "not logged in") {
			t.Fatalf("%s: 403 must not read as a login problem — the session is valid and a fresh one 403s identically: %q", verb, stderr)
		}
	}
}

func TestRolloutStatusJSONPassthrough(t *testing.T) {
	autoupdateServer(t, 200, `{"ok":true,"halted":true,"behind":5}`)
	stdout, _, code := runRollout(t, "json", "status")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json out not decodable: %v\n%s", err, stdout)
	}
	if env["halted"] != true {
		t.Fatalf("json passthrough lost halted: %v", env)
	}
}

func TestRolloutOlderControlPlane404(t *testing.T) {
	autoupdateServer(t, 404, `{"error":"not_found"}`)
	_, stderr, code := runRollout(t, "table", "status")
	if code != exitNotFound {
		t.Fatalf("exit = %d, want exitNotFound", code)
	}
	if !strings.Contains(stderr, "no fleet-rollout control") {
		t.Fatalf("stderr = %q", stderr)
	}
}

func TestRolloutRequiresLogin(t *testing.T) {
	withTempConfigHome(t)
	_, _, code := runRollout(t, "table", "status")
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth", code)
	}
}

// TestAutoupdateNeverWritesConfig proves the HARD INVARIANT: a policy change must
// never repoint or mutate the ambient bp config (no ActiveServer, no cloud-url
// rewrite beyond what the login seed put there).
func TestAutoupdateNeverWritesConfig(t *testing.T) {
	autoupdateServer(t, 200, `{"ok":true,"autoupdate":{"enabled":true,"paused":true,"pinned_release":null}}`)
	before, err := LoadConfig()
	if err != nil {
		t.Fatalf("load before: %v", err)
	}
	if _, _, code := runAutoupdate(t, "table", "pause", testInstanceID); code != exitOK {
		t.Fatalf("pause exit = %d", code)
	}
	after, err := LoadConfig()
	if err != nil {
		t.Fatalf("load after: %v", err)
	}
	if before.Server != after.Server || before.CloudURL != after.CloudURL || before.CloudToken != after.CloudToken {
		t.Fatalf("config mutated: before=%+v after=%+v", before, after)
	}
}
