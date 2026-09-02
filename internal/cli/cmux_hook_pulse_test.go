package cli

// cmux_hook_pulse_test.go — the PreToolUse heartbeat is a PULSE, not a re-claim.
//
// WHY THE OLD ASSERTIONS HAD TO GO. The retired tests counted claims: "first
// PreToolUse claims = 1, second = still 1". That count cannot tell the two verbs
// apart. A pulse and a re-claim both renew the lease and both bump the epoch, so
// a claim-count test is green on the version that renews SILENTLY and green on
// the version that narrates — it measures the throttle and nothing else. The
// defect the row named lives in the half a count cannot see: which endpoint was
// hit, what now-line rode the body, and which epoch came back for the close.
//
// So these tests assert the VERB (the /pulse path, with /claim proven untouched),
// the PAYLOAD (a sanitized, bounded now-line derived from the hook context, with
// the transcript path and session id proven absent from the wire), the EPOCH
// (the pulse's returned epoch reaches the on-disk stamp, and the Stop close uses
// it), and the THROTTLE (still ≤1 per renewEvery). Reverting hookPreToolUse to
// taskboard.DoClaim reds every one of them on the claims/pulses assertion.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// pulseHarness wires one hook invocation at a CALLER-OWNED config dir, so a
// test can share the on-disk stamp across several fires (hookHarness mints a
// fresh TempDir per call, which would hide every throttle and stamp effect).
func pulseHarness(t *testing.T, dir, server, task, surface, stdin string) manifest.Context {
	t.Helper()
	t.Setenv("BARKPARK_TASK", task)
	t.Setenv("BARKPARK_WORKER_ID", "")
	t.Setenv("CMUX_SURFACE_ID", surface)
	t.Setenv("CMUX_WORKSPACE_ID", "")
	t.Setenv("BP_CMUX_DEBUG", "")
	hookStdin = strings.NewReader(stdin)
	userConfigDir = func() (string, error) { return dir, nil }
	return manifest.Context{Server: server, Token: "t", Workspace: "default", Project: "default", Dataset: "production"}
}

// fireHook runs one hook event and returns stdout/stderr/exit.
func fireHook(t *testing.T, ctx manifest.Context, event string) (stdout, stderr string, code int) {
	t.Helper()
	var so, se bytes.Buffer
	code = runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, ctx, []string{event})
	return so.String(), se.String(), code
}

// ── the verb ────────────────────────────────────────────────────────────────

// THE REGRESSION TEST. PreToolUse must hit /pulse and must NOT hit /claim.
// Reverting hookPreToolUse to taskboard.DoClaim makes pulses 0 and claims 1 —
// both halves red, and the fake server's `unexpected request` guard never fires
// because /claim is a legitimate endpoint on it. The assertion is the only thing
// standing between the two verbs.
func TestHookPreToolUsePulsesAndNeverReclaims(t *testing.T) {
	srv, rec := newHookServer(t, []bool{false}, 4)
	dir := t.TempDir()
	ctx := pulseHarness(t, dir, srv.URL, "task-p", "SRF1",
		`{"session_id":"sess-SECRET","transcript_path":"/home/me/.claude/t.jsonl","tool_name":"Bash","cwd":"/Volumes/SATECHI/github/barkpark"}`)

	so, _, code := fireHook(t, ctx, "PreToolUse")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if so != "" {
		t.Errorf("PreToolUse wrote to stdout: %q (must be empty)", so)
	}

	snap := rec.snapshot()
	if snap.pulses != 1 {
		t.Fatalf("pulses = %d, want 1 — PreToolUse must renew through POST /v1/tasks/:id/pulse", snap.pulses)
	}
	if snap.claims != 0 {
		t.Fatalf("claims = %d, want 0 — the heartbeat must NOT re-claim (a claim renews silently and takes a lapsed row back)", snap.claims)
	}
	if snap.lastWkr != "cmux-SRF1" {
		t.Errorf("pulse worker_id = %q, want cmux-SRF1", snap.lastWkr)
	}
	if want := "cmux pane: running Bash in barkpark"; snap.lastNow != want {
		t.Errorf("pulse now = %q, want %q (tool_name + cwd basename)", snap.lastNow, want)
	}
	// The wire is the assertion: nothing from the transcript or the session id
	// may ride a heartbeat that lands in a board-visible field.
	if len(snap.pulseRaw) != 1 {
		t.Fatalf("captured %d pulse bodies, want 1", len(snap.pulseRaw))
	}
	for _, leak := range []string{"sess-SECRET", "transcript", ".jsonl", "/home/me", "SATECHI"} {
		if strings.Contains(snap.pulseRaw[0], leak) {
			t.Errorf("pulse body %q carries %q — the now-line vocabulary is tool_name + cwd BASENAME only", snap.pulseRaw[0], leak)
		}
	}
}

// The pulse's returned epoch — which the server BUMPED — reaches the on-disk
// stamp. This is the state the Stop close reads in a later process.
func TestHookPreToolUseStampsTheReturnedEpoch(t *testing.T) {
	// claimEpoch 4 → the fake server answers the Nth pulse with epoch 4+N,
	// mirroring the live server's current_epoch+1 bump.
	srv, _ := newHookServer(t, []bool{false}, 4)
	dir := t.TempDir()
	ctx := pulseHarness(t, dir, srv.URL, "task-p", "S", `{"tool_name":"Read","cwd":"/x/repo"}`)

	if _, _, code := fireHook(t, ctx, "PreToolUse"); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	st, ok := readRenewStamp("cmux-S", "task-p")
	if !ok {
		t.Fatal("no renew stamp after a landed pulse — the close has no epoch to use")
	}
	if st.LastEpoch != 5 {
		t.Errorf("stamp last_epoch = %d, want 5 (the epoch the pulse RETURNED, not the one the pane last held)", st.LastEpoch)
	}
	got, ok := stampedEpoch("cmux-S", "task-p")
	if !ok || got != 5 {
		t.Errorf("stampedEpoch = (%d,%v), want (5,true)", got, ok)
	}
}

// ── the throttle ────────────────────────────────────────────────────────────

// At most one pulse per renewEvery; the window reopens once the stamp ages out,
// and the second pulse re-stamps the NEW epoch.
func TestHookPreToolUsePulseThrottle(t *testing.T) {
	srv, rec := newHookServer(t, []bool{false}, 10)
	dir := t.TempDir()
	ctx := pulseHarness(t, dir, srv.URL, "task-p", "S", `{"tool_name":"Bash","cwd":"/x/repo"}`)

	// First fire: no stamp → fails open → pulses.
	if _, _, code := fireHook(t, ctx, "PreToolUse"); code != exitOK {
		t.Fatalf("first PreToolUse exit = %d", code)
	}
	if n := rec.snapshot().pulses; n != 1 {
		t.Fatalf("pulses after the first fire = %d, want 1", n)
	}

	// Second fire immediately: inside the window → no request at all.
	hookStdin = strings.NewReader(`{"tool_name":"Bash","cwd":"/x/repo"}`)
	so, _, code := fireHook(t, ctx, "PreToolUse")
	if code != exitOK {
		t.Fatalf("second PreToolUse exit = %d", code)
	}
	if so != "" {
		t.Errorf("throttled PreToolUse wrote to stdout: %q", so)
	}
	snap := rec.snapshot()
	if snap.pulses != 1 {
		t.Errorf("pulses after the second fire = %d, want still 1 (throttled)", snap.pulses)
	}
	if snap.claims != 0 {
		t.Errorf("claims = %d, want 0 — a throttled heartbeat must not fall back to a re-claim", snap.claims)
	}

	// Age the stamp past the window and fire again: the window has reopened.
	backdateStamp(t, "cmux-S", "task-p", renewEvery+time.Second)
	hookStdin = strings.NewReader(`{"tool_name":"Grep","cwd":"/x/repo"}`)
	if _, _, code := fireHook(t, ctx, "PreToolUse"); code != exitOK {
		t.Fatalf("third PreToolUse exit = %d", code)
	}
	snap = rec.snapshot()
	if snap.pulses != 2 {
		t.Fatalf("pulses after the window reopened = %d, want 2", snap.pulses)
	}
	if want := "cmux pane: running Grep in repo"; snap.lastNow != want {
		t.Errorf("second pulse now = %q, want %q — each pulse narrates the CURRENT tool", snap.lastNow, want)
	}
	st, _ := readRenewStamp("cmux-S", "task-p")
	if st.LastEpoch != 12 {
		t.Errorf("stamp last_epoch = %d, want 12 (the SECOND pulse's epoch)", st.LastEpoch)
	}
}

// backdateStamp rewrites the (worker,task) stamp's last_renew_unix to `age` ago,
// leaving every other field intact — the only way to cross renewEvery or
// leaseTTLFloor in a unit test without sleeping.
func backdateStamp(t *testing.T, worker, task string, age time.Duration) {
	t.Helper()
	p, err := cmuxStampPath(worker, task)
	if err != nil {
		t.Fatalf("stamp path: %v", err)
	}
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read stamp: %v", err)
	}
	var s renewStamp
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("decode stamp: %v", err)
	}
	s.LastRenewUnix = time.Now().Add(-age).Unix()
	out, _ := json.Marshal(s)
	if err := os.WriteFile(p, out, 0o644); err != nil {
		t.Fatalf("write stamp: %v", err)
	}
}

// ── the now-line: sanitized, bounded, derived ───────────────────────────────

func TestHookNowLineIsSanitizedBoundedAndDerived(t *testing.T) {
	cases := []struct {
		name string
		in   hookInput
		want string
	}{
		{"tool + cwd basename", hookInput{ToolName: "Bash", CWD: "/a/b/barkpark"}, "cmux pane: running Bash in barkpark"},
		{"tool only", hookInput{ToolName: "Edit"}, "cmux pane: running Edit"},
		{"cwd only", hookInput{CWD: "/a/b/web"}, "cmux pane: working in web"},
		{"empty context", hookInput{}, "cmux pane: active"},
		// A malformed body decodes to the zero value; the pulse still needs a
		// non-empty now, and "active" is the most it can honestly claim.
		{"root cwd is not a name", hookInput{CWD: "/"}, "cmux pane: active"},
		{"dot cwd is not a name", hookInput{CWD: "."}, "cmux pane: active"},
		// Everything outside [A-Za-z0-9._-] is DROPPED, not escaped.
		{"shell metacharacters dropped", hookInput{ToolName: "Ba$h; rm -rf /"}, "cmux pane: running Bahrm-rf"},
		{"quotes and newlines dropped", hookInput{ToolName: "a\"b\nc\td"}, "cmux pane: running abcd"},
		{"non-ascii dropped", hookInput{ToolName: "Bash→火"}, "cmux pane: running Bash"},
		{"a token that sanitizes to nothing is absent", hookInput{ToolName: "!!!", CWD: "/a/b/ok"}, "cmux pane: working in ok"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := hookNowLine(c.in); got != c.want {
				t.Errorf("hookNowLine = %q, want %q", got, c.want)
			}
		})
	}

	t.Run("bounded and never carries the transcript or session", func(t *testing.T) {
		in := hookInput{
			SessionID:      "sess-SECRET-0123456789",
			TranscriptPath: "/home/me/.claude/projects/x/transcript.jsonl",
			ToolName:       strings.Repeat("T", 4096),
			CWD:            "/a/" + strings.Repeat("d", 4096),
		}
		got := hookNowLine(in)
		if len(got) > nowLineMax {
			t.Errorf("now-line is %d bytes, want ≤ %d", len(got), nowLineMax)
		}
		for _, leak := range []string{"sess-SECRET", "transcript", ".jsonl", "/home/me"} {
			if strings.Contains(got, leak) {
				t.Errorf("now-line %q carries %q", got, leak)
			}
		}
		for _, r := range got {
			ok := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' ||
				r == '.' || r == '_' || r == '-' || r == ' ' || r == ':'
			if !ok {
				t.Fatalf("now-line %q carries the out-of-vocabulary rune %q", got, r)
			}
		}
	})
}

// A malformed / oversized / absent hook body must still produce a LANDED pulse
// carrying the generic line — the heartbeat's job is renewing the lease, and a
// body it could not parse is not a reason to let the claim expire.
func TestHookPreToolUseMalformedContextStillPulses(t *testing.T) {
	cases := []struct {
		name  string
		stdin string
	}{
		{"not json at all", `{not json at all`},
		{"empty body", ``},
		{"json but not an object", `["a","b"]`},
		{"object with the wrong types", `{"tool_name":42,"cwd":{"x":1}}`},
		{"oversized body", `{"tool_name":"Bash","cwd":"/x/` + strings.Repeat("y", 1<<20) + `"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv, rec := newHookServer(t, []bool{false}, 3)
			ctx := pulseHarness(t, t.TempDir(), srv.URL, "task-p", "S", c.stdin)
			so, _, code := fireHook(t, ctx, "PreToolUse")
			assertHookInert(t, code, so)
			snap := rec.snapshot()
			if snap.pulses != 1 {
				t.Fatalf("pulses = %d, want 1 — a body the hook could not parse must not skip the renewal", snap.pulses)
			}
			if snap.claims != 0 {
				t.Errorf("claims = %d, want 0", snap.claims)
			}
			if snap.lastNow == "" {
				t.Error("pulse now-line is empty — the server rejects an empty now with a 400")
			}
			if len(snap.lastNow) > nowLineMax {
				t.Errorf("now-line is %d bytes, want ≤ %d even from a hostile body", len(snap.lastNow), nowLineMax)
			}
		})
	}
}

// A lost lease answers not_holder. The hook must breadcrumb it and STOP — never
// escalate to a re-claim, which is exactly the theft the pulse verb refuses.
func TestHookPreToolUseNotHolderDoesNotEscalateToAReclaim(t *testing.T) {
	srv, rec := newPulseRefusingServer(t, "not_holder")
	ctx := pulseHarness(t, t.TempDir(), srv.URL, "task-p", "S", `{"tool_name":"Bash","cwd":"/x/repo"}`)
	so, _, code := fireHook(t, ctx, "PreToolUse")
	assertHookInert(t, code, so)

	snap := rec.snapshot()
	if snap.pulses != 1 {
		t.Fatalf("pulses = %d, want 1 (the refusal was actually reached)", snap.pulses)
	}
	if snap.claims != 0 {
		t.Fatalf("claims = %d, want 0 — a refused pulse must NOT be retried as a claim; that would take a reaped row back", snap.claims)
	}
	bc, ok := readHookBreadcrumb("cmux-S")
	if !ok {
		t.Fatal("no breadcrumb after a refused pulse — a swallowed failure must stay diagnosable")
	}
	if !strings.Contains(bc.Error, "not_holder") {
		t.Errorf("breadcrumb = %q, want the server's own reason", bc.Error)
	}
	// A refused pulse must NOT re-stamp: the throttle would then hide the loss
	// for a whole window.
	if _, ok := readRenewStamp("cmux-S", "task-p"); ok {
		t.Error("a refused pulse wrote a renew stamp — the next tool call would skip the retry")
	}
}

// newPulseRefusingServer answers /pulse with a 409 + the given reason, and
// records any /claim the hook might wrongly fall back to.
func newPulseRefusingServer(t *testing.T, reason string) (*httptest.Server, *hookRec) {
	t.Helper()
	rec := &hookRec{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.mu.Lock()
		defer rec.mu.Unlock()
		switch {
		case strings.HasSuffix(r.URL.Path, "/pulse"):
			rec.pulses++
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"ok":false,"reason":"` + reason + `"}`))
		case strings.HasSuffix(r.URL.Path, "/claim"):
			rec.claims++
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":99}}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

// ── concurrent hooks ────────────────────────────────────────────────────────

// Claude fires hooks from concurrent tool calls, and subagents in the same pane
// share (worker, task) — so several PreToolUse processes race the SAME stamp
// file. The contract under that race is unchanged: every fire exits 0 with empty
// stdout, none re-claims, the throttle still bounds the storm, and the stamp
// left behind is a VALID one carrying a real epoch (a torn stamp would make the
// close fall back to a re-claim, not close on garbage).
func TestHookPreToolUseConcurrentHooks(t *testing.T) {
	const fires = 12
	srv, rec := newHookServer(t, []bool{false}, 100)
	dir := t.TempDir()
	// nil stdin: drainHookStdin handles it, so the goroutines share no reader.
	// Every fire therefore composes the generic line, which is the point — the
	// race under test is the STAMP, not the now-line.
	ctx := pulseHarness(t, dir, srv.URL, "task-c", "S", ``)
	hookStdin = nil

	var wg sync.WaitGroup
	codes := make([]int, fires)
	outs := make([]string, fires)
	for i := 0; i < fires; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			var so, se bytes.Buffer
			codes[i] = runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, ctx, []string{"PreToolUse"})
			outs[i] = so.String()
		}(i)
	}
	wg.Wait()

	for i := range codes {
		if codes[i] != exitOK {
			t.Errorf("fire %d exit = %d, want 0 — a hook must never break the agent, racing or not", i, codes[i])
		}
		if outs[i] != "" {
			t.Errorf("fire %d stdout = %q, want empty", i, outs[i])
		}
	}
	snap := rec.snapshot()
	if snap.claims != 0 {
		t.Errorf("claims = %d, want 0 — no fire may fall back to a re-claim", snap.claims)
	}
	if snap.pulses < 1 || snap.pulses > fires {
		t.Fatalf("pulses = %d, want between 1 and %d", snap.pulses, fires)
	}
	// The throttle is best-effort under a race (every fire that reads before the
	// first write sees no stamp and fails open), so the assertion is the BOUND,
	// not an exact count. What must hold exactly: the surviving stamp parses and
	// names an epoch the server actually issued.
	st, ok := readRenewStamp("cmux-S", "task-c")
	if !ok {
		t.Fatal("no readable stamp survived the concurrent fires")
	}
	if st.LastEpoch < 101 || st.LastEpoch > 100+fires {
		t.Errorf("stamp last_epoch = %d, want an epoch the server issued (101..%d)", st.LastEpoch, 100+fires)
	}
	if _, ok := stampedEpoch("cmux-S", "task-c"); !ok {
		t.Error("stampedEpoch declined the surviving stamp — the close would pay a re-claim it did not need")
	}
}

// ── the close reads the stamped epoch ───────────────────────────────────────

// Criterion: the epoch the Stop/SessionEnd close needs is captured in hook
// state. With a fresh stamp the close spends NO re-claim and fences on the
// stamped epoch.
func TestHookStopClosesOnTheStampedEpoch(t *testing.T) {
	for _, event := range []string{"Stop", "SessionEnd"} {
		t.Run(event, func(t *testing.T) {
			srv, rec := newHookServer(t, []bool{true, true}, 4)
			dir := t.TempDir()
			ctx := pulseHarness(t, dir, srv.URL, "task-p", "S", `{"tool_name":"Bash","cwd":"/x/repo"}`)

			// One PreToolUse pulse stamps epoch 5 (claimEpoch 4 + first pulse).
			if _, _, code := fireHook(t, ctx, "PreToolUse"); code != exitOK {
				t.Fatalf("PreToolUse exit = %d", code)
			}
			hookStdin = strings.NewReader(`{}`)
			so, _, code := fireHook(t, ctx, event)
			assertHookInert(t, code, so)

			snap := rec.snapshot()
			if snap.closes != 1 {
				t.Fatalf("closes = %d, want 1", snap.closes)
			}
			if snap.claims != 0 {
				t.Errorf("claims = %d, want 0 — the stamped epoch made the re-claim unnecessary (that re-claim was itself an epoch bump)", snap.claims)
			}
			if len(snap.closeEps) != 1 || snap.closeEps[0] != 5 {
				t.Errorf("close observed_epoch = %v, want [5] — the epoch the PULSE returned", snap.closeEps)
			}
		})
	}
}

// A stamp older than the lease TTL floor stops vouching: the lease may have been
// reaped and re-claimed, so the close pays the re-claim and uses the LIVE epoch.
func TestHookStopReclaimsWhenTheStampIsPastTheLeaseFloor(t *testing.T) {
	srv, rec := newHookServer(t, []bool{true}, 4)
	dir := t.TempDir()
	ctx := pulseHarness(t, dir, srv.URL, "task-p", "S", `{"tool_name":"Bash","cwd":"/x/repo"}`)
	if _, _, code := fireHook(t, ctx, "PreToolUse"); code != exitOK {
		t.Fatalf("PreToolUse exit = %d", code)
	}
	backdateStamp(t, "cmux-S", "task-p", leaseTTLFloor+time.Minute)
	if _, ok := stampedEpoch("cmux-S", "task-p"); ok {
		t.Fatal("stampedEpoch still vouches past the lease TTL floor")
	}

	hookStdin = strings.NewReader(`{}`)
	so, _, code := fireHook(t, ctx, "Stop")
	assertHookInert(t, code, so)
	snap := rec.snapshot()
	if snap.claims != 1 {
		t.Errorf("claims = %d, want 1 (the stamp aged out, so the close re-claims for a live epoch)", snap.claims)
	}
	if len(snap.closeEps) != 1 || snap.closeEps[0] != 4 {
		t.Errorf("close observed_epoch = %v, want [4] — the re-claimed epoch", snap.closeEps)
	}
}

// A stamped epoch that is fresh but WRONG (something else renewed the claim
// inside the window) must cost one refused close, not a wrong one: the hook
// re-claims for the live epoch and closes again.
func TestHookStopFallsBackToAReclaimWhenTheStampedEpochIsFenced(t *testing.T) {
	const liveEpoch = 77
	rec := &hookRec{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.mu.Lock()
		defer rec.mu.Unlock()
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/pulse"):
			rec.pulses++
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":5}}}`))
		case strings.HasSuffix(p, "/claim"):
			rec.claims++
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":` + itoaT(liveEpoch) + `}}}`))
		case strings.HasSuffix(p, "/close"):
			rec.closes++
			var body struct {
				Epoch int `json:"observed_epoch"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			rec.closeEps = append(rec.closeEps, body.Epoch)
			// The live epoch fence: only the current epoch closes.
			if body.Epoch != liveEpoch {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"fenced_off"}`))
				return
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
		case strings.Contains(p, "/v1/data/doc/") && strings.Contains(p, "/task/"):
			rec.gets++
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{
				"_id": "task-x", "rev": "r-1", "lifecycle_status": "in_progress",
				"acceptance_criteria": []map[string]any{{"criterion": "c", "met": true}},
			}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)

	dir := t.TempDir()
	ctx := pulseHarness(t, dir, srv.URL, "task-p", "S", `{"tool_name":"Bash","cwd":"/x/repo"}`)
	if _, _, code := fireHook(t, ctx, "PreToolUse"); code != exitOK {
		t.Fatalf("PreToolUse exit = %d", code)
	}
	hookStdin = strings.NewReader(`{}`)
	so, _, code := fireHook(t, ctx, "Stop")
	assertHookInert(t, code, so)

	snap := rec.snapshot()
	if len(snap.closeEps) != 2 {
		t.Fatalf("close attempts = %v, want two (the stamped epoch, then the re-claimed one)", snap.closeEps)
	}
	if snap.closeEps[0] != 5 || snap.closeEps[1] != liveEpoch {
		t.Errorf("close epochs = %v, want [5 %d]", snap.closeEps, liveEpoch)
	}
	if snap.claims != 1 {
		t.Errorf("claims = %d, want 1 (exactly one re-claim, and only after the fence refused)", snap.claims)
	}
	// The retry landed, so the failure breadcrumb the fenced attempt left must be
	// gone: a breadcrumb means "the MOST RECENT hook action failed".
	if bc, ok := readHookBreadcrumb("cmux-S"); ok {
		t.Errorf("stale breadcrumb %q survived a landed close", bc.Error)
	}
}

// isFencedOff matches the epoch fence and ONLY the epoch fence — a refusal a
// fresh epoch cannot fix must never trigger the second close.
func TestIsFencedOff(t *testing.T) {
	cases := []struct {
		reason string
		want   bool
	}{
		{"fenced_off", true},
		{"stale_claim", true},
		{"FENCED_OFF", true},
		{"fenced_off:epoch", true},
		{"doc_changed_since_claim", false},
		{"doc_changed_since_claim:brief", false},
		{"not_holder", false},
		{"not_found", false},
		{"fenced_offering", false},
		{"", false},
	}
	for _, c := range cases {
		t.Run(c.reason, func(t *testing.T) {
			var err error
			if c.reason != "" {
				err = errors.New(c.reason)
			}
			if got := isFencedOff(err); got != c.want {
				t.Errorf("isFencedOff(%q) = %v, want %v", c.reason, got, c.want)
			}
		})
	}
}
