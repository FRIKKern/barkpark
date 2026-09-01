package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The defect these tests pin (pds-bl-hook-observed-rev-defeats-fence): the Stop
// hook used to read a fresh rev and pass observed_rev on EVERY auto-close.
// close.ex short-circuits check_work_digest the moment observed_rev is non-nil,
// so the unattended closer was the one closer the work-digest fence never
// protected — and an out-of-band brief rewrite closed SILENTLY, indistinguishable
// from the agent ticking its own acceptance boxes.
//
// D82 (the observed_rev bypass) is INTENTIONAL and stays. What changes is that
// the fence is armed FIRST and the bypass is announced: the hook closes plainly,
// and only a doc_changed_since_claim refusal opens the strict-rev CAS — after
// naming the drift on the hook's diagnostic channel.
//
// CRITICAL: the fake server here refuses a REV-LESS close and accepts a close
// carrying observed_rev — the exact asymmetry the live server has. A server that
// accepted both would make these tests vacuous: the old always-bypass hook would
// pass them.

// fenceRec records what the fence-aware fake server saw, per close attempt.
type fenceRec struct {
	closes int
	gets   int
	revs   []string // observed_rev on each close, in order ("" = fence armed)
	lastEp int
	fenced int // closes refused with doc_changed_since_claim
	docRev string
	reason string
}

// newFenceServer serves the hook's three endpoints. `drift` decides whether the
// brief moved under the claim: when true a rev-less close is REFUSED with the
// server's work-digest fence reason, and only a close carrying observed_rev ==
// docRev lands. When false every close lands, so a hook that arms the fence
// never needs the bypass at all.
func newFenceServer(t *testing.T, drift bool) (*httptest.Server, *fenceRec) {
	t.Helper()
	rec := &fenceRec{docRev: "r-fresh-1", reason: "doc_changed_since_claim:brief"}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":11}}}`))
		case strings.HasSuffix(p, "/close"):
			rec.closes++
			var body struct {
				Epoch int    `json:"observed_epoch"`
				Rev   string `json:"observed_rev"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.revs = append(rec.revs, body.Rev)
			rec.lastEp = body.Epoch
			if drift && body.Rev == "" {
				// The live fence: no observed_rev, and the brief moved.
				rec.fenced++
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"` + rec.reason + `"}`))
				return
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
		case strings.Contains(p, "/v1/data/doc/") && strings.Contains(p, "/task/"):
			rec.gets++
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{
				"_id":              "task-x",
				"rev":              rec.docRev,
				"lifecycle_status": "in_progress",
				"acceptance_criteria": []map[string]any{
					{"criterion": "c", "met": true},
				},
			}})
		default:
			t.Errorf("unexpected request: %s %s", r.Method, p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

// runFenceHook drives one Stop with BP_CMUX_DEBUG on so the diagnostic channel
// (the hook's only lawful venue — stdout is forbidden) is capturable.
func runFenceHook(t *testing.T, server string) (stdout, stderr string, code int) {
	t.Helper()
	ctx := hookHarness(t, server, "task-x", "S", `{}`)
	t.Setenv("BP_CMUX_DEBUG", "1")
	var so, se bytes.Buffer
	code = runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
	return so.String(), se.String(), code
}

// NO DRIFT: the hook must close with the work-digest fence ARMED — no
// observed_rev on the wire at all. The old hook sent the rev unconditionally,
// so its close was never fence-checked even when there was nothing to bypass.
func TestHookStopArmsTheWorkDigestFenceFirst(t *testing.T) {
	srv, rec := newFenceServer(t, false)
	so, _, code := runFenceHook(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the hook's cardinal contract)", code)
	}
	if so != "" {
		t.Errorf("hook wrote to stdout: %q (must be empty)", so)
	}
	if rec.closes != 1 {
		t.Fatalf("closes = %d, want 1", rec.closes)
	}
	if rec.revs[0] != "" {
		t.Errorf("first close carried observed_rev = %q, want \"\" — the fence must be ARMED on the first attempt, not bypassed pre-emptively", rec.revs[0])
	}
	if rec.lastEp != 11 {
		t.Errorf("close observed_epoch = %d, want the re-claimed 11", rec.lastEp)
	}
	// One read proves acceptance. The fresh-rev read is now paid ONLY when the
	// fence actually refuses — an undrifted close spends one fewer round trip.
	if rec.gets != 1 {
		t.Errorf("gets = %d, want 1 (acceptance read only — no fresh-rev read when the fence holds)", rec.gets)
	}
}

// DRIFT: the fence refuses, the hook NAMES the drift, then takes D82's bypass.
// The report is the whole point of the row — an unattended close that skips the
// one guard against an out-of-band criterion rewrite must not do it silently.
func TestHookStopReportsBriefDriftBeforeBypassingTheFence(t *testing.T) {
	srv, rec := newFenceServer(t, true)
	so, se, code := runFenceHook(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the hook's cardinal contract)", code)
	}
	if so != "" {
		t.Errorf("hook wrote to stdout: %q (must be empty)", so)
	}
	if rec.fenced != 1 {
		t.Fatalf("the work-digest fence refused %d closes, want 1 — the hook never armed it (this test would be vacuous)", rec.fenced)
	}
	if rec.closes != 2 {
		t.Fatalf("closes = %d, want 2 (fenced attempt, then the observed_rev retry)", rec.closes)
	}
	if rec.revs[1] != rec.docRev {
		t.Errorf("retry close observed_rev = %q, want %q — D82's bypass must still land the close", rec.revs[1], rec.docRev)
	}
	// The report: the drift is named, and the server's own reason (whose suffix
	// carries the changed field) rides along.
	if !strings.Contains(se, "the brief changed under this claim") {
		t.Errorf("the auto-close did not REPORT the drift; stderr was:\n%s", se)
	}
	if !strings.Contains(se, rec.reason) {
		t.Errorf("the drift report does not name the server's reason %q (its suffix is the changed field); stderr was:\n%s", rec.reason, se)
	}
}

// DRIFT + the fresh rev is UNREADABLE: there is no sanctioned bypass to take,
// and a rev-less retry would only repeat the 409. The hook must leave the task
// claimed (→ lease-expiry → resume, the honest direction) and NOT close.
func TestHookStopLeavesClaimedWhenDriftedAndRevUnreadable(t *testing.T) {
	var closes, gets int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":11}}}`))
		case strings.HasSuffix(p, "/close"):
			closes++
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"doc_changed_since_claim"}`))
		default:
			gets++
			if gets >= 2 {
				// The post-refusal fresh-rev read fails.
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{
				"_id":              "task-x",
				"rev":              "r-fresh-1",
				"lifecycle_status": "in_progress",
				"acceptance_criteria": []map[string]any{
					{"criterion": "c", "met": true},
				},
			}})
		}
	}))
	t.Cleanup(srv.Close)

	so, se, code := runFenceHook(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if so != "" {
		t.Errorf("hook wrote to stdout: %q (must be empty)", so)
	}
	if gets != 2 {
		t.Fatalf("gets = %d, want 2 (acceptance read, then the fresh-rev read the refusal triggers)", gets)
	}
	if closes != 1 {
		t.Errorf("closes = %d, want 1 — with no readable rev there is no bypass to take, so the fenced attempt must not be retried", closes)
	}
	if !strings.Contains(se, "current rev is unreadable") {
		t.Errorf("the hook did not say WHY it left the task claimed; stderr was:\n%s", se)
	}
}

// A close refusal that is NOT the work-digest fence must never escalate to a
// strict-CAS retry: fenced_off means someone else moved the row, and retrying
// with observed_rev would close over them.
func TestHookStopDoesNotBypassANonDigestRefusal(t *testing.T) {
	var closes int
	var revs []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":11}}}`))
		case strings.HasSuffix(p, "/close"):
			closes++
			var body struct {
				Rev string `json:"observed_rev"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			revs = append(revs, body.Rev)
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"fenced_off"}`))
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{
				"_id":              "task-x",
				"rev":              "r-fresh-1",
				"lifecycle_status": "in_progress",
				"acceptance_criteria": []map[string]any{
					{"criterion": "c", "met": true},
				},
			}})
		}
	}))
	t.Cleanup(srv.Close)

	so, _, code := runFenceHook(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if so != "" {
		t.Errorf("hook wrote to stdout: %q (must be empty)", so)
	}
	if closes != 1 {
		t.Fatalf("closes = %d, want 1 — a fenced_off refusal must NOT be retried through the observed_rev bypass", closes)
	}
	if revs[0] != "" {
		t.Errorf("close carried observed_rev = %q, want \"\"", revs[0])
	}
}
