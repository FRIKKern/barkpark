package provisioner

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeInstanceBehavior tunes the httptest fake instance the golden-path VERIFY
// gate probes. The zero value is an ALL-GREEN box: /v1/capabilities → 200,
// /v1/auth/login → 401 (auth stack answers, bad creds rejected), /studio → one
// scoped 302 → 200. Individual fields flip a probe red.
type fakeInstanceBehavior struct {
	// capStatus is the GET /v1/capabilities status (0 → 200).
	capStatus int
	// loginStatus is the POST /v1/auth/login status (0 → 401). Set to 500 to
	// simulate the #957 dead-on-arrival class (session/cookie stack crashes).
	loginStatus int
	// loginBody is the login response body (default a small JSON error).
	loginBody string
	// studioAlwaysRedirect makes every /studio* path 302 forever, blowing
	// CheckStudio's ≤3-hop budget so verify.studio fails.
	studioAlwaysRedirect bool
}

// newFakeInstance stands up an httptest server that mimics the three endpoints
// the VERIFY gate probes, per behavior. It is torn down via t.Cleanup.
func newFakeInstance(t *testing.T, b fakeInstanceBehavior) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/capabilities", func(w http.ResponseWriter, _ *http.Request) {
		code := b.capStatus
		if code == 0 {
			code = http.StatusOK
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	mux.HandleFunc("/v1/auth/login", func(w http.ResponseWriter, _ *http.Request) {
		code := b.loginStatus
		if code == 0 {
			code = http.StatusUnauthorized
		}
		body := b.loginBody
		if body == "" {
			body = `{"error":"invalid credentials"}`
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write([]byte(body))
	})

	// /studio and every scoped sub-path. Default: /studio 302s ONCE to a scoped
	// path that renders 200 (exercises Plug.Session, the whole reason CheckStudio
	// walks the hop). studioAlwaysRedirect 302s forever → the ≤3-hop walk fails.
	studio := func(w http.ResponseWriter, r *http.Request) {
		if b.studioAlwaysRedirect {
			http.Redirect(w, r, "/studio/hop", http.StatusFound)
			return
		}
		if r.URL.Path == "/studio" {
			http.Redirect(w, r, "/w/default/studio", http.StatusFound)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("<!doctype html><title>Studio</title>"))
	}
	mux.HandleFunc("/studio", studio)
	mux.HandleFunc("/", studio)

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// verifyRec records every step transition (step, status, detail) in order. Its
// Report ALWAYS returns an error to prove the gate verdict is INDEPENDENT of
// StepReporter delivery — a control plane that drops every report must neither
// flip a green gate red nor a red gate green.
type verifyRec struct {
	mu      sync.Mutex
	entries []struct{ step, status, detail string }
}

func (r *verifyRec) Report(_ context.Context, _, step, status, detail string) error {
	r.mu.Lock()
	r.entries = append(r.entries, struct{ step, status, detail string }{step, status, detail})
	r.mu.Unlock()
	return errString("control plane unreachable (simulated)")
}

// seq returns the ordered "step/status" list.
func (r *verifyRec) seq() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.entries))
	for _, e := range r.entries {
		out = append(out, e.step+"/"+e.status)
	}
	return out
}

func (r *verifyRec) has(want string) bool {
	for _, s := range r.seq() {
		if s == want {
			return true
		}
	}
	return false
}

// detail returns the LAST detail reported for step/status, or "".
func (r *verifyRec) detail(step, status string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := ""
	for _, e := range r.entries {
		if e.step == step && e.status == status {
			out = e.detail
		}
	}
	return out
}

// details returns every detail reported for step/status, in order.
func (r *verifyRec) details(step, status string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, e := range r.entries {
		if e.step == step && e.status == status {
			out = append(out, e.detail)
		}
	}
	return out
}

// allDetails returns every non-empty detail reported, in order.
func (r *verifyRec) allDetails() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, e := range r.entries {
		if e.detail != "" {
			out = append(out, e.detail)
		}
	}
	return out
}

// assertOrder checks want appears as an ordered subsequence of seq.
func assertOrder(t *testing.T, seq []string, want ...string) {
	t.Helper()
	i := 0
	for _, s := range seq {
		if i < len(want) && s == want[i] {
			i++
		}
	}
	if i != len(want) {
		t.Errorf("step sequence %v is missing the ordered spine %v (matched %d/%d)", seq, want, i, len(want))
	}
}

// TestProvisionVerifyFailsOn500Login (C2 case a) proves the whole point of the
// gate: a box whose /v1/auth/login 500s (the #957 32-byte-SECRET_KEY_BASE
// dead-on-arrival class) FAILS the provision. verify/failed carries the login
// evidence, ProvisionWith returns an error, the box is torn down (nil teardown,
// no orphan), and `ready` is NEVER reached — so the worker never POSTs /succeed
// and the control plane never declares a login-dead box ready.
func TestProvisionVerifyFailsOn500Login(t *testing.T) {
	seams, prov, dns, _ := fakeSeams(t)
	inst := newFakeInstance(t, fakeInstanceBehavior{
		loginStatus: http.StatusInternalServerError,
		loginBody:   `{"error":"session store crashed"}`,
	})
	seams.VerifyBaseURL = inst.URL
	rec := &verifyRec{}
	seams.StepReporter = rec.Report

	job := JobSpec{JobID: "job-doa", Name: "Dead On Arrival", Slug: "doa", Region: "nbg1", ServerType: "cax11"}
	_, _, _, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("ProvisionWith against a 500-on-login instance returned nil, want an error (verify must fail closed)")
	}
	if teardown != nil {
		t.Error("ProvisionWith returned a non-nil teardown after a failed verify, want nil (the box was torn down)")
	}

	// verify/failed names the login probe + the 500 + the body snippet.
	failed := rec.detail("verify", "failed")
	if !strings.Contains(failed, "verify.login") || !strings.Contains(failed, "500") {
		t.Errorf("verify/failed detail = %q, want it to name verify.login and the 500", failed)
	}
	if !strings.Contains(failed, "session store crashed") {
		t.Errorf("verify/failed detail = %q, want it to carry the response body snippet", failed)
	}
	// The gate stopped the chain: ready was never reported, verify/done never fired.
	if rec.has("ready/started") || rec.has("ready/done") {
		t.Errorf("ready was reported despite a failed verify; steps=%v", rec.seq())
	}
	if rec.has("verify/done") {
		t.Errorf("verify/done fired despite a red login probe; steps=%v", rec.seq())
	}
	// No orphan: server + DNS torn down.
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("failed-verify left %d servers, want 0 (cleanup): %+v", len(hosts), hosts)
	}
	if v, _ := dns.Resolve(context.Background(), "doa.barkpark.cloud"); len(v) != 0 {
		t.Errorf("failed-verify left DNS %v, want none", v)
	}
}

// TestProvisionVerifyAllGreenSequence (C2 case b) proves the happy path narrates
// the honest spine: after content/done comes verify/started, exactly THREE
// verify/progress lines (one green probe each, in order), verify/done, then
// ready — in that order.
func TestProvisionVerifyAllGreenSequence(t *testing.T) {
	seams, _, _, _ := fakeSeams(t) // fakeSeams already wires an all-green instance
	rec := &verifyRec{}
	seams.StepReporter = rec.Report
	seams.Bootstrap = func(context.Context, BootstrapRequest) (*BootstrapOutputs, error) {
		return &BootstrapOutputs{Template: "blog", Workspace: "acme"}, nil
	}

	job := JobSpec{JobID: "job-green", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "blog"}
	if _, _, _, _, err := ProvisionWith(context.Background(), seams, job); err != nil {
		t.Fatalf("ProvisionWith all-green: %v", err)
	}

	assertOrder(t, rec.seq(),
		"content/done",
		"verify/started",
		"verify/progress", "verify/progress", "verify/progress",
		"verify/done",
		"ready/done",
	)

	progress := rec.details("verify", "progress")
	if len(progress) != 3 {
		t.Fatalf("want 3 verify/progress lines (one per probe), got %d: %v", len(progress), progress)
	}
	for i, want := range []string{"verify.api", "verify.login", "verify.studio"} {
		if !strings.HasPrefix(progress[i], want) {
			t.Errorf("verify/progress[%d] = %q, want it to start with %q", i, progress[i], want)
		}
		if !strings.Contains(progress[i], "ms)") {
			t.Errorf("verify/progress[%d] = %q, want an elapsed-ms suffix", i, progress[i])
		}
	}
}

// TestProvisionVerifyFailsOnStudioRedirectLoop (C2 case c) proves a Studio that
// 302s past the ≤3-hop budget (never rendering) fails the gate — the health
// gate's own hop logic, reused. api + login pass first, then studio fails; the
// box is torn down.
func TestProvisionVerifyFailsOnStudioRedirectLoop(t *testing.T) {
	seams, prov, _, _ := fakeSeams(t)
	inst := newFakeInstance(t, fakeInstanceBehavior{studioAlwaysRedirect: true})
	seams.VerifyBaseURL = inst.URL
	rec := &verifyRec{}
	seams.StepReporter = rec.Report

	job := JobSpec{JobID: "job-loop", Name: "Loopy", Slug: "loop", Region: "nbg1", ServerType: "cax11"}
	_, _, _, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("ProvisionWith against a Studio redirect loop returned nil, want an error")
	}
	if teardown != nil {
		t.Error("ProvisionWith returned a non-nil teardown after a failed studio probe, want nil")
	}
	if failed := rec.detail("verify", "failed"); !strings.Contains(failed, "verify.studio") {
		t.Errorf("verify/failed detail = %q, want it to name verify.studio", failed)
	}
	// api + login passed BEFORE studio (two progress lines, no more).
	if got := len(rec.details("verify", "progress")); got != 2 {
		t.Errorf("want 2 green verify/progress lines (api, login) before studio failed, got %d: %v", got, rec.details("verify", "progress"))
	}
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("failed studio verify left %d servers, want 0: %+v", len(hosts), hosts)
	}
}

// TestProvisionVerifyNeverLeaksToken (C2 case d) scans EVERY reported step detail
// and EVERY console line for the minted admin token — it must never appear. The
// verify probes are anonymous / sentinel-cred, so the token is held but never
// sent, and the console redactor is belt-and-suspenders on top.
func TestProvisionVerifyNeverLeaksToken(t *testing.T) {
	seams, _, _, _ := fakeSeams(t)
	rec := &verifyRec{}
	seams.StepReporter = rec.Report
	cons := &consoleRec{}
	seams.ConsoleReporter = cons.Report
	seams.Bootstrap = func(context.Context, BootstrapRequest) (*BootstrapOutputs, error) {
		return &BootstrapOutputs{Template: "blog", Workspace: "acme"}, nil
	}

	job := JobSpec{JobID: "job-secret", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "blog"}
	_, adminToken, _, _, err := ProvisionWith(context.Background(), seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}
	if !strings.HasPrefix(adminToken, "bp_admin_") {
		t.Fatalf("expected a bp_admin_ token, got %q", adminToken)
	}

	for _, d := range rec.allDetails() {
		if strings.Contains(d, adminToken) || strings.Contains(d, "bp_admin_") {
			t.Errorf("a step detail leaked the admin token: %q", d)
		}
	}
	if joined := cons.joined(); strings.Contains(joined, adminToken) || strings.Contains(joined, "bp_admin_") {
		t.Errorf("a console line leaked the admin token; console=%q", joined)
	}
	// Non-vacuous: verify actually ran all three probes.
	if got := len(rec.details("verify", "progress")); got != 3 {
		t.Errorf("verify did not narrate its 3 probes; got %v", rec.details("verify", "progress"))
	}
}
