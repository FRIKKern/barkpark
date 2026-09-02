package taskboard

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

func testClient(baseURL string) *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: baseURL, Token: "t"})
}

// capture records what the httptest server saw so the test can assert the exact
// request the action layer sent (path + decoded JSON body).
type capture struct {
	path string
	body map[string]interface{}
}

func serve(t *testing.T, status int, respBody string, cap *capture) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cap.path = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &cap.body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, respBody)
	}))
}

func TestDoClaim_Success(t *testing.T) {
	var cap capture
	srv := serve(t, http.StatusOK, `{"ok":true,"doc":{"claim":{"epoch":4}}}`, &cap)
	defer srv.Close()

	got := DoClaim(testClient(srv.URL), "t1", "tui-mbp")

	if !got.OK {
		t.Fatalf("expected OK, got %+v", got)
	}
	if got.Message != "claimed as tui-mbp · epoch 4" {
		t.Errorf("message = %q", got.Message)
	}
	// Exact request assertions: targeted claim path + worker_id body.
	if cap.path != "/v1/tasks/t1/claim" {
		t.Errorf("path = %q", cap.path)
	}
	if cap.body["worker_id"] != "tui-mbp" {
		t.Errorf("worker_id = %v", cap.body["worker_id"])
	}
}

func TestDoClaim_Failures(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		resp    string
		wantMsg string
	}{
		{"resource_conflict", http.StatusConflict, `{"ok":false,"reason":"resource_conflict"}`,
			"claim failed: resource conflict — files held by another task"},
		{"already_claimed", http.StatusConflict, `{"ok":false,"reason":"already_claimed"}`,
			"claim failed: already claimed by another worker"},
		{"stale_claim", http.StatusConflict, `{"ok":false,"reason":"stale_claim"}`,
			"claim failed: claim moved under us (stale)"},
		{"not_ready", http.StatusConflict, `{"ok":false,"reason":"not_ready"}`,
			"claim failed: task is not ready"},
		{"not_found", http.StatusNotFound, `{"ok":false,"reason":"not_found"}`,
			"claim failed: task not found"},
		// ok:true but no fencing epoch → apiclient synthesises an error we pass through verbatim-ish.
		{"no_epoch", http.StatusOK, `{"ok":true,"doc":{"claim":{"epoch":0}}}`,
			"claim failed: claim t1: server returned no fencing epoch"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cap capture
			srv := serve(t, tc.status, tc.resp, &cap)
			defer srv.Close()

			got := DoClaim(testClient(srv.URL), "t1", "tui-mbp")
			if got.OK {
				t.Fatalf("expected failure, got %+v", got)
			}
			if got.Message != tc.wantMsg {
				t.Errorf("message = %q, want %q", got.Message, tc.wantMsg)
			}
		})
	}
}

func TestDoClaim_NetworkFailure(t *testing.T) {
	srv := serve(t, http.StatusOK, ``, &capture{})
	url := srv.URL
	srv.Close() // now nothing listens — the POST fails at the transport.

	got := DoClaim(testClient(url), "t1", "tui-mbp")
	if got.OK {
		t.Fatalf("expected failure, got %+v", got)
	}
	// Transport errors must arrive SHORT — "server unreachable (connection
	// refused)" — never the raw Go url.Error that spells the whole request.
	if !strings.HasPrefix(got.Message, "claim failed: server unreachable (") {
		t.Errorf("message = %q, want a short server-unreachable message", got.Message)
	}
	if strings.Contains(got.Message, "http://") {
		t.Errorf("message = %q leaks the raw request URL", got.Message)
	}
}

func TestDoClose_Success(t *testing.T) {
	var cap capture
	srv := serve(t, http.StatusOK, `{"ok":true,"doc":{}}`, &cap)
	defer srv.Close()

	got := DoClose(testClient(srv.URL), "t1", "tui-mbp", 4)

	if !got.OK {
		t.Fatalf("expected OK, got %+v", got)
	}
	if got.Message != "closed · epoch 4" {
		t.Errorf("message = %q", got.Message)
	}
	if cap.path != "/v1/tasks/t1/close" {
		t.Errorf("path = %q", cap.path)
	}
	// Epoch CAS: the observed epoch the caller held must ride the close body.
	if cap.body["worker_id"] != "tui-mbp" {
		t.Errorf("worker_id = %v", cap.body["worker_id"])
	}
	if cap.body["observed_epoch"] != float64(4) {
		t.Errorf("observed_epoch = %v (want 4)", cap.body["observed_epoch"])
	}
	if cap.body["lifecycle_status"] != "done" {
		t.Errorf("lifecycle_status = %v (want done)", cap.body["lifecycle_status"])
	}
}

func TestDoClose_Failures(t *testing.T) {
	cases := []struct {
		name    string
		resp    string
		wantMsg string
	}{
		{"stale_claim", `{"ok":false,"reason":"stale_claim"}`,
			"close rejected: claim moved under us (stale)"},
		{"invalid_lifecycle", `{"ok":false,"reason":"invalid_lifecycle:frobnicate"}`,
			"close rejected: invalid_lifecycle:frobnicate"}, // unknown reason → verbatim
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cap capture
			srv := serve(t, http.StatusConflict, tc.resp, &cap)
			defer srv.Close()

			got := DoClose(testClient(srv.URL), "t1", "tui-mbp", 4)
			if got.OK {
				t.Fatalf("expected failure, got %+v", got)
			}
			if got.Message != tc.wantMsg {
				t.Errorf("message = %q, want %q", got.Message, tc.wantMsg)
			}
		})
	}
}

// TestDoClaim_SurfacesNotice: a clean claim whose 2xx envelope carries a
// rail-awareness notice folds the top notice into the strip line AND overrides
// the role — blocked_while_claimed is warn, rail_changed is info, and a
// blocked_while_claimed outranks a rail_changed when both ride the envelope.
func TestDoClaim_SurfacesNotice(t *testing.T) {
	cases := []struct {
		name     string
		resp     string
		wantMsg  string
		wantRole Role
	}{
		{"blocked_while_claimed", `{"ok":true,"doc":{"claim":{"epoch":4}},"notices":[{"type":"blocked_while_claimed","task_id":"t9","blockers":["t3"]}]}`,
			"claimed as tui-mbp · epoch 4 · blocked while claimed: t9", RoleWarn},
		{"rail_changed", `{"ok":true,"doc":{"claim":{"epoch":4}},"notices":[{"type":"rail_changed","parent_id":"epic-2","rail_rev":"r7"}]}`,
			"claimed as tui-mbp · epoch 4 · rail changed: epic-2", RoleInfo},
		{"blocked outranks rail", `{"ok":true,"doc":{"claim":{"epoch":4}},"notices":[{"type":"rail_changed","parent_id":"epic-2","rail_rev":"r7"},{"type":"blocked_while_claimed","task_id":"t9","blockers":["t3"]}]}`,
			"claimed as tui-mbp · epoch 4 · blocked while claimed: t9", RoleWarn},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cap capture
			srv := serve(t, http.StatusOK, tc.resp, &cap)
			defer srv.Close()

			got := DoClaim(testClient(srv.URL), "t1", "tui-mbp")
			if !got.OK {
				t.Fatalf("expected OK, got %+v", got)
			}
			if got.Message != tc.wantMsg {
				t.Errorf("message = %q, want %q", got.Message, tc.wantMsg)
			}
			if got.Role != tc.wantRole {
				t.Errorf("role = %v, want %v", got.Role, tc.wantRole)
			}
		})
	}
}

// TestDoClose_ResyncGuidance: the two recoverable fence reasons render the
// actionable next-keypress guidance in danger, not the bare humanised reason —
// the whole point of the polish — and carry the ResyncKind the reducer arms its
// recovery on.
//
// doc_changed_since_claim LEADS WITH observed_rev on purpose. The copy it
// replaced ("reopen the task (enter) to re-read, then close again") named a
// recovery that cannot work: a same-worker re-read preserves the claim's
// work_digest, so the next rev-less close repeats the identical 409
// (docs/setup/TASK-SYSTEM.md; close.ex check_work_digest). The line must name
// observed_rev, the keys to press, and what the pinned close does.
func TestDoClose_ResyncGuidance(t *testing.T) {
	cases := []struct {
		name     string
		resp     string
		wantMsg  string
		wantKind ResyncKind
	}{
		{"fenced_off", `{"ok":false,"reason":"fenced_off"}`,
			"fenced off — the task changed under you (blocker/move/sweep); press c to renew, then x again",
			ResyncRenewClaim},
		{"doc_changed_since_claim", `{"ok":false,"reason":"doc_changed_since_claim"}`,
			"close now needs observed_rev: the brief changed under your claim — re-read it (enter), then x x closes pinned to the revision on screen; a bare re-read alone repeats this refusal",
			ResyncObservedRev},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cap capture
			srv := serve(t, http.StatusConflict, tc.resp, &cap)
			defer srv.Close()

			got := DoClose(testClient(srv.URL), "t1", "tui-mbp", 4)
			if got.OK {
				t.Fatalf("expected failure, got %+v", got)
			}
			if got.Message != tc.wantMsg {
				t.Errorf("message = %q, want %q", got.Message, tc.wantMsg)
			}
			if got.Role != RoleDanger {
				t.Errorf("role = %v, want RoleDanger", got.Role)
			}
			if got.Resync != tc.wantKind {
				t.Errorf("Resync = %v, want %v", got.Resync, tc.wantKind)
			}
		})
	}
}

// The drift line must NOT send the user down the dead-end path the ledger
// contract forbids: a bare "re-read, then close again" repeats the same 409. The
// line has to NAME observed_rev — this pins the property, not just today's
// wording, so a future re-word cannot quietly reintroduce the dead end.
func TestDoClose_DriftGuidanceNamesObservedRev(t *testing.T) {
	var cap capture
	srv := serve(t, http.StatusConflict, `{"ok":false,"reason":"doc_changed_since_claim"}`, &cap)
	defer srv.Close()

	got := DoClose(testClient(srv.URL), "t1", "tui-mbp", 4)
	if !strings.Contains(got.Message, "observed_rev") {
		t.Errorf("drift guidance = %q, must name observed_rev — the only recovery that can land", got.Message)
	}
	if got.Resync != ResyncObservedRev {
		t.Errorf("Resync = %v, want ResyncObservedRev", got.Resync)
	}
	// The retired dead end, verbatim: a re-read alone leaves the claim-time work
	// digest in place, so this instruction produces the same refusal forever.
	if strings.Contains(got.Message, "re-read, then close again") {
		t.Errorf("drift guidance = %q still tells the user to close again after a bare re-read", got.Message)
	}
}

// The observed_rev close is a real strict-CAS request, not decoration: the rev
// the caller pinned must ride the close body verbatim.
func TestDoCloseRev_PinsObservedRevOnTheWire(t *testing.T) {
	var cap capture
	srv := serve(t, http.StatusOK, `{"ok":true,"doc":{}}`, &cap)
	defer srv.Close()

	got := DoCloseRev(testClient(srv.URL), "t1", "tui-mbp", 4, "rev-9f")
	if !got.OK {
		t.Fatalf("expected OK, got %+v", got)
	}
	if cap.body["observed_rev"] != "rev-9f" {
		t.Errorf("observed_rev = %v, want rev-9f", cap.body["observed_rev"])
	}
	// An EMPTY rev must not put the key on the wire at all — that is the
	// fence-armed ordinary close (DoCloseRev falls through to DoClose).
	var cap2 capture
	srv2 := serve(t, http.StatusOK, `{"ok":true,"doc":{}}`, &cap2)
	defer srv2.Close()
	if got := DoCloseRev(testClient(srv2.URL), "t1", "tui-mbp", 4, ""); !got.OK {
		t.Fatalf("expected OK, got %+v", got)
	}
	if _, present := cap2.body["observed_rev"]; present {
		t.Errorf("a rev-less close put observed_rev on the wire (%v) — the work-digest fence must stay armed", cap2.body["observed_rev"])
	}
}

func TestDoClose_NetworkFailure(t *testing.T) {
	srv := serve(t, http.StatusOK, ``, &capture{})
	url := srv.URL
	srv.Close()

	got := DoClose(testClient(url), "t1", "tui-mbp", 4)
	if got.OK {
		t.Fatalf("expected failure, got %+v", got)
	}
	if !strings.HasPrefix(got.Message, "close rejected: server unreachable (") {
		t.Errorf("message = %q, want a short server-unreachable message", got.Message)
	}
	if strings.Contains(got.Message, "http://") {
		t.Errorf("message = %q leaks the raw request URL", got.Message)
	}
}

func TestResolveWorker(t *testing.T) {
	t.Run("env override wins", func(t *testing.T) {
		t.Setenv("BARKPARK_WORKER_ID", "opus-3")
		if got := ResolveWorker(); got != "opus-3" {
			t.Errorf("ResolveWorker() = %q, want opus-3", got)
		}
	})
	t.Run("falls back to tui-<hostname>", func(t *testing.T) {
		t.Setenv("BARKPARK_WORKER_ID", "")
		got := ResolveWorker()
		if !strings.HasPrefix(got, "tui-") {
			t.Errorf("ResolveWorker() = %q, want a tui- prefix", got)
		}
		if got == "tui-" {
			t.Errorf("ResolveWorker() = %q, hostname suffix missing", got)
		}
	})
}

func TestStudioTaskURL(t *testing.T) {
	cases := []struct {
		name    string
		baseURL string
		docID   string
		want    string
	}{
		{"http host", "http://localhost:4000", "t1", "http://localhost:4000/studio/production/task/t1"},
		{"https preserved", "https://guerrilla.barkpark.cloud", "abc", "https://guerrilla.barkpark.cloud/studio/production/task/abc"},
		{"trailing slash trimmed", "https://acme.test/", "t1", "https://acme.test/studio/production/task/t1"},
		{"multiple trailing slashes trimmed", "https://acme.test///", "t1", "https://acme.test/studio/production/task/t1"},
		{"draft doc id escaped", "https://acme.test", "drafts.a b", "https://acme.test/studio/production/task/drafts.a%20b"},
		{"slash in doc id escaped", "https://acme.test", "a/b", "https://acme.test/studio/production/task/a%2Fb"},
		{"empty base yields empty", "", "t1", ""},
		{"empty doc id yields empty", "https://acme.test", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := StudioTaskURL(tc.baseURL, tc.docID); got != tc.want {
				t.Errorf("StudioTaskURL(%q, %q) = %q, want %q", tc.baseURL, tc.docID, got, tc.want)
			}
		})
	}
}
