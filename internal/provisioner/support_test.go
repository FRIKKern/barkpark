package provisioner

// support_test.go proves the provision_support chain (MVP-0, PDF-D83/D84/D88/
// D89) against httptest FAKES — a fake control plane (claim/step/console/
// succeed/fail), a fake parent main (mutate/mint/export/roster), and a
// recording SupportRunner. No live Hetzner, no SSH, no real cloud anywhere.
//
// The custody test is the high-flip-risk assert (PDF-D83 brief): the parent
// main's admin token must appear in NO step report, NO console line, NO
// succeed/fail body, and NO on-box script — proven by grep over EVERYTHING the
// fakes captured.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// supportFakeRunner is the recording cloud.SupportRunner: every step script,
// feed script, and output script is captured for the custody grep.
type supportFakeRunner struct {
	mu      sync.Mutex
	steps   []cloud.CaddyStep
	feeds   []string // RunFeed scripts
	outputs []string // RunOutput scripts
	// capacityJSON is what the capacity-measure script returns.
	capacityJSON string
	// runErr, when set, fails every Run call (drives the configure-adjacent
	// failure paths from the caller's side when needed).
	runErr error
}

func (r *supportFakeRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.steps = append(r.steps, s)
	return r.runErr
}

func (r *supportFakeRunner) RunOutput(_ context.Context, script string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.outputs = append(r.outputs, script)
	if script == supportCapacityMeasureScript {
		return r.capacityJSON, nil
	}
	return "ok", nil
}

func (r *supportFakeRunner) RunFeed(_ context.Context, _ string, script string, stdin io.Reader) (string, error) {
	io.Copy(io.Discard, stdin) // drain like the real SSH pipe
	r.mu.Lock()
	defer r.mu.Unlock()
	r.feeds = append(r.feeds, script)
	return "", nil
}

func (r *supportFakeRunner) WaitReady(context.Context, time.Duration) error { return nil }

// allScripts returns every script text the runner saw (custody grep surface).
func (r *supportFakeRunner) allScripts() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, s := range r.steps {
		out = append(out, strings.Join(s.Argv, " "))
		out = append(out, s.Title, s.Cmd)
	}
	out = append(out, r.feeds...)
	out = append(out, r.outputs...)
	return out
}

var _ cloud.SupportRunner = (*supportFakeRunner)(nil)

// supportHarness stands up the fake CP + fake parent main and records
// EVERYTHING for ordering + custody asserts.
type supportHarness struct {
	mu sync.Mutex

	cp   *httptest.Server
	main *httptest.Server

	claims     int
	claimJSON  func() string // built lazily so it can reference main.URL
	stepBodies []string      // raw step-report bodies, in order
	steps      []string      // "step/status" in order
	console    []string      // console lines
	succeeds   []string      // succeed bodies
	fails      []string      // fail bodies
	events     []string      // cross-server ordered event log (roster/succeed/fail)

	rosterLive   bool // true → roster returns the live row
	rosterCalls  int
	mintToken    string
	mintTokenID  string // "" → the mint response carries NO token_id key
	parentToken  string
	exportedTars int

	// failEchoLeg, when set to "mutate" or "mint", makes that parent-main leg
	// answer 500 with a body that ECHOES the parent token plus echoSecret (an
	// unregistered secret-like string) — the header-echoing error page the
	// custody fixes defend against.
	failEchoLeg string
	echoSecret  string
}

func newSupportHarness(t *testing.T) *supportHarness {
	t.Helper()
	h := &supportHarness{
		rosterLive:  true,
		mintToken:   "sup-ledger-tok-abc123",
		mintTokenID: "tid-1",
		parentToken: "parent-admin-tok-hunter2-XYZ",
		echoSecret:  "would-be-minted-tok-9f8e7d",
	}

	// echoFail writes the header-echoing 500 body for the failEchoLeg leg.
	echoFail := func(w http.ResponseWriter) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintf(w, `{"error":"internal","request_headers":"Authorization: Bearer %s","token":%q}`, h.parentToken, h.echoSecret)
	}

	h.main = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer "+h.parentToken {
			t.Errorf("parent main called without the claim's admin bearer: %q on %s", got, r.URL.Path)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/v1/data/mutate/"):
			h.add("mutate")
			if h.failEchoLeg == "mutate" {
				echoFail(w)
				return
			}
			fmt.Fprint(w, `{"ok":true}`)
		case r.Method == http.MethodPost && r.URL.Path == "/v1/fleet/support-tokens":
			h.add("mint")
			if h.failEchoLeg == "mint" {
				echoFail(w)
				return
			}
			if h.mintTokenID != "" {
				fmt.Fprintf(w, `{"token":%q,"token_id":%q}`, h.mintToken, h.mintTokenID)
			} else {
				fmt.Fprintf(w, `{"token":%q}`, h.mintToken)
			}
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/workspaces/"):
			h.add("export")
			h.mu.Lock()
			h.exportedTars++
			h.mu.Unlock()
			w.Header().Set("Content-Type", "application/x-tar")
			fmt.Fprint(w, "FAKE-TAR-BYTES")
		case r.Method == http.MethodGet && r.URL.Path == "/v1/fleet/roster":
			h.add("roster")
			h.mu.Lock()
			h.rosterCalls++
			live := h.rosterLive
			h.mu.Unlock()
			if live {
				fmt.Fprint(w, `{"documents":[{"worker":"helper","status":"idle","capacity":{"size_class":"standard","slots_total":1,"slots_free":1}}]}`)
			} else {
				fmt.Fprint(w, `{"documents":[{"worker":"helper","status":"provisioning"}]}`)
			}
		default:
			t.Errorf("unexpected parent-main call: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(h.main.Close)

	h.claimJSON = func() string {
		return fmt.Sprintf(`{"job":{"id":"job-sup-1","claim_token":"ct-1"},"barkpark":{"id":"bp-1","name":"helper","slug":"helper","region":"nbg1","server_type":"cx23"},"support":{"parent_url":%q,"parent_admin_token":%q,"dataset":"production","workspace":"default","name":"helper"}}`,
			h.main.URL, h.parentToken)
	}

	h.cp = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		switch {
		case r.URL.Path == "/v1/internal/support-jobs/claim":
			h.mu.Lock()
			h.claims++
			first := h.claims == 1
			h.mu.Unlock()
			if first {
				fmt.Fprint(w, h.claimJSON())
			} else {
				w.WriteHeader(http.StatusNoContent)
			}
		case strings.HasSuffix(r.URL.Path, "/step"):
			var m struct{ Step, Status, Detail string }
			json.Unmarshal(body, &m)
			h.mu.Lock()
			h.stepBodies = append(h.stepBodies, string(body))
			h.steps = append(h.steps, m.Step+"/"+m.Status)
			h.mu.Unlock()
			fmt.Fprint(w, `{"ok":true}`)
		case strings.HasSuffix(r.URL.Path, "/console"):
			var m struct{ Line string }
			json.Unmarshal(body, &m)
			h.mu.Lock()
			h.console = append(h.console, m.Line)
			h.mu.Unlock()
			fmt.Fprint(w, `{"ok":true}`)
		case strings.HasSuffix(r.URL.Path, "/succeed"):
			h.add("succeed")
			h.mu.Lock()
			h.succeeds = append(h.succeeds, string(body))
			h.mu.Unlock()
			fmt.Fprint(w, `{"ok":true}`)
		case strings.HasSuffix(r.URL.Path, "/fail"):
			h.add("fail")
			h.mu.Lock()
			h.fails = append(h.fails, string(body))
			h.mu.Unlock()
			fmt.Fprint(w, `{"ok":true}`)
		default:
			t.Errorf("unexpected control-plane call: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(h.cp.Close)
	return h
}

func (h *supportHarness) add(event string) {
	h.mu.Lock()
	h.events = append(h.events, event)
	h.mu.Unlock()
}

// worker builds a Worker + recording seams bound to the harness.
func (h *supportHarness) worker(runner *supportFakeRunner, deleted *[]string) *Worker {
	seams := SupportSeams{
		CreateServer: func(_ context.Context, name string) (cloud.Server, error) {
			return cloud.Server{Name: "support-box-" + name, IP: "203.0.113.9"}, nil
		},
		DeleteServer: func(_ context.Context, serverName string) error {
			h.mu.Lock()
			*deleted = append(*deleted, serverName)
			h.mu.Unlock()
			return nil
		},
		RunnerFor: func(string) cloud.SupportRunner { return runner },
		ConfigureHost: func(_ context.Context, _ cloud.SupportRunner, _ cloud.SupportConfigureOpts) (cloud.Secrets, error) {
			return cloud.Secrets{AdminToken: "bp_admin_boxtoken123"}, nil
		},
		StepReporter:       (&HTTPStepReporter{ControlURL: h.cp.URL, Token: "wtok"}).Report,
		ConsoleReporter:    (&HTTPConsoleReporter{ControlURL: h.cp.URL, Token: "wtok"}).Report,
		RosterPollInterval: 2 * time.Millisecond,
		RosterPollBudget:   250 * time.Millisecond,
	}
	return &Worker{
		ControlURL:         h.cp.URL,
		Token:              "wtok",
		Interval:           2 * time.Millisecond,
		ReportRetryBackoff: time.Millisecond,
		ProvisionTimeout:   10 * time.Second,
		SupportProvision:   DefaultSupportProvision(seams),
	}
}

// TestRunSupportWith_ClaimsAndDispatchesHappyPath proves the 5th drain loop
// claims from /v1/internal/support-jobs/claim, dispatches the full support
// chain, reports the steps STRICTLY as create→configure→content→verify→ready,
// and succeeds ONLY AFTER the fake roster returned a live row with capacity.
func TestRunSupportWith_ClaimsAndDispatchesHappyPath(t *testing.T) {
	h := newSupportHarness(t)
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = w.RunSupportWith(ctx, func(claimed bool, err error) {
			if err != nil {
				t.Errorf("support cycle error: %v", err)
			}
			if claimed {
				cancel() // one job drained through the LOOP — stop.
			}
		})
	}()
	<-done

	h.mu.Lock()
	defer h.mu.Unlock()

	if h.claims == 0 {
		t.Fatal("the loop never hit /v1/internal/support-jobs/claim")
	}
	if len(h.succeeds) != 1 {
		t.Fatalf("want exactly one succeed report, got %d (fails: %v)", len(h.succeeds), h.fails)
	}
	if len(h.fails) != 0 {
		t.Fatalf("no fail report expected on the happy path, got: %v", h.fails)
	}

	// The succeed body carries the box IP + echoes the claim fence.
	var sb map[string]any
	if err := json.Unmarshal([]byte(h.succeeds[0]), &sb); err != nil {
		t.Fatalf("succeed body not JSON: %v", err)
	}
	if ip, _ := sb["ip"].(string); ip != "203.0.113.9" {
		t.Fatalf("succeed reported ip %q, want 203.0.113.9", ip)
	}
	if ct, _ := sb["claim_token"].(string); ct != "ct-1" {
		t.Fatalf("succeed did not echo the claim token, got %q", ct)
	}
	// task-5866ec745efcd7f7: the minted ledger token's OPAQUE id rides the
	// succeed body so the CP row's fleet_token_id is set and `bp cloud support
	// remove` can revoke the token. The token VALUE itself must never ride.
	if tid, _ := sb["token_id"].(string); tid != "tid-1" {
		t.Fatalf("succeed must carry the minted token_id, got %q in %s", tid, h.succeeds[0])
	}
	if strings.Contains(h.succeeds[0], h.mintToken) {
		t.Fatal("CUSTODY VIOLATION: the succeed body carried the ledger token VALUE")
	}

	// PDF-D84: steps are reported ONLY as create/configure/content/verify/ready.
	seen := map[string]bool{}
	for _, s := range h.steps {
		name := strings.SplitN(s, "/", 2)[0]
		seen[name] = true
		switch name {
		case "create", "configure", "content", "verify", "ready":
		default:
			t.Fatalf("off-vocabulary step reported: %q (the CP validate_step would 422)", s)
		}
	}
	for _, want := range []string{"create", "configure", "content", "verify", "ready"} {
		if !seen[want] {
			t.Fatalf("step %q never reported; got %v", want, h.steps)
		}
	}
	// Strict boundary order: each step's done precedes the next step's started.
	boundary := []string{"create/started", "create/done", "configure/started", "configure/done",
		"content/started", "content/done", "verify/started", "verify/done", "ready/started", "ready/done"}
	idx := 0
	for _, s := range h.steps {
		if idx < len(boundary) && s == boundary[idx] {
			idx++
		}
	}
	if idx != len(boundary) {
		t.Fatalf("step boundaries out of order: matched %d of %v in %v", idx, boundary, h.steps)
	}

	// PDF-D89: succeed is reported only AFTER a live roster read.
	lastRoster, succeedAt := -1, -1
	for i, e := range h.events {
		if e == "roster" {
			lastRoster = i
		}
		if e == "succeed" {
			succeedAt = i
		}
	}
	if lastRoster == -1 || succeedAt == -1 || lastRoster > succeedAt {
		t.Fatalf("succeed must follow a roster read: events %v", h.events)
	}
	if h.rosterCalls == 0 {
		t.Fatal("the verify step never polled the roster")
	}
	// The content legs all ran against the parent main.
	for _, want := range []string{"mutate", "mint", "export"} {
		found := false
		for _, e := range h.events {
			if e == want {
				found = true
			}
		}
		if !found {
			t.Fatalf("parent-main leg %q never ran: events %v", want, h.events)
		}
	}
	if len(deleted) != 0 {
		t.Fatalf("no teardown expected on the happy path, deleted: %v", deleted)
	}
}

// TestRunOnceSupport_NoMintTokenID_OmitsSucceedKey proves the additive succeed
// contract stays byte-tolerant (task-5866ec745efcd7f7): a mint response that
// carries NO token_id yields a succeed body WITHOUT the token_id key — the
// pre-fix ip-only shape — so an old parent main degrades cleanly instead of
// sending an empty-string id the CP would persist as garbage.
func TestRunOnceSupport_NoMintTokenID_OmitsSucceedKey(t *testing.T) {
	h := newSupportHarness(t)
	h.mintTokenID = "" // the mint envelope has no id to report
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)

	if _, err := w.RunOnceSupport(context.Background()); err != nil {
		t.Fatalf("RunOnceSupport: %v", err)
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.succeeds) != 1 {
		t.Fatalf("want one succeed, got %d (fails: %v)", len(h.succeeds), h.fails)
	}
	var sb map[string]any
	if err := json.Unmarshal([]byte(h.succeeds[0]), &sb); err != nil {
		t.Fatalf("succeed body not JSON: %v", err)
	}
	if _, present := sb["token_id"]; present {
		t.Fatalf("token_id must be ABSENT when the mint carried no id, got: %s", h.succeeds[0])
	}
}

// TestSupport_WorkspaceEnsureStep proves the content step's on-box ordering fix
// (task-2ba0270056e7da6e): before the merge-import runs, a workspace-ensure
// step POSTs /api/workspaces {name,slug} for the CLAIM's workspace with the
// BOX's admin token (already-exists tolerated), so a template-launched parent's
// bootstrap-workspace bundle always lands on the live-proven PDS-D9 adopt
// branch instead of the fresh-box slug-absent branch that 500'd live.
func TestSupport_WorkspaceEnsureStep(t *testing.T) {
	h := newSupportHarness(t)
	// A TEMPLATE-shaped claim: the parent's bootstrap workspace slug is the
	// instance slug, which no fresh box has — the exact live-failure shape.
	h.claimJSON = func() string {
		return fmt.Sprintf(`{"job":{"id":"job-sup-tmpl","claim_token":"ct-t"},"barkpark":{"id":"bp-2","name":"helper","slug":"helper","region":"nbg1","server_type":"cx23"},"support":{"parent_url":%q,"parent_admin_token":%q,"dataset":"production","workspace":"mvp0proof-m-260724152727","name":"helper"}}`,
			h.main.URL, h.parentToken)
	}
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)

	if _, err := w.RunOnceSupport(context.Background()); err != nil {
		t.Fatalf("RunOnceSupport: %v", err)
	}

	h.mu.Lock()
	if len(h.succeeds) != 1 {
		t.Fatalf("want one succeed, got %d (fails: %v)", len(h.succeeds), h.fails)
	}
	h.mu.Unlock()

	runner.mu.Lock()
	defer runner.mu.Unlock()
	ensureIdx, importIdx := -1, -1
	for i, s := range runner.steps {
		joined := strings.Join(s.Argv, " ")
		switch {
		case strings.Contains(joined, "POST http://localhost:4000/api/workspaces"):
			ensureIdx = i
			// The claim's workspace slug is threaded into BOTH the JSON body keys.
			if !strings.Contains(joined, `"name":"mvp0proof-m-260724152727"`) ||
				!strings.Contains(joined, `"slug":"mvp0proof-m-260724152727"`) {
				t.Fatalf("the ensure step must carry the claim's workspace slug, got: %s", joined)
			}
			// The BOX admin token drives it (and is redacted) — never the parent's.
			if !strings.Contains(joined, "bp_admin_boxtoken123") {
				t.Fatal("the ensure step must authenticate with the box's own admin token")
			}
			if strings.Contains(joined, h.parentToken) {
				t.Fatal("CUSTODY VIOLATION: the parent admin token reached the ensure script")
			}
			if len(s.Redact) == 0 {
				t.Fatal("the workspace-ensure step must Redact the box admin token")
			}
		case strings.Contains(joined, "workspace import"):
			importIdx = i
			if !strings.Contains(joined, "workspace import 'mvp0proof-m-260724152727'") {
				t.Fatalf("the import step must target the claim's workspace, got: %s", joined)
			}
		}
	}
	if ensureIdx == -1 {
		t.Fatal("the workspace-ensure step never ran")
	}
	if importIdx == -1 {
		t.Fatal("the merge-import step never ran")
	}
	if ensureIdx > importIdx {
		t.Fatalf("the workspace-ensure step must run BEFORE the merge-import (ensure=%d import=%d)", ensureIdx, importIdx)
	}
}

// TestRunOnceSupport_RosterTimeout_FailsNeverSucceeds proves PDF-D89's honest
// timeout: a roster that never reads live FAILS the job (fail reported,
// succeed NEVER), and the box is torn down so a dead support never bills.
func TestRunOnceSupport_RosterTimeout_FailsNeverSucceeds(t *testing.T) {
	h := newSupportHarness(t)
	h.rosterLive = false // the row stays provisioning forever
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)

	claimed, err := w.RunOnceSupport(context.Background())
	if err != nil {
		t.Fatalf("RunOnceSupport should consume the job cleanly (fail reported), got: %v", err)
	}
	if !claimed {
		t.Fatal("the job should have been claimed + consumed")
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.succeeds) != 0 {
		t.Fatalf("NEVER succeed without the roster read — succeed was reported: %v", h.succeeds)
	}
	if len(h.fails) != 1 {
		t.Fatalf("want exactly one fail report, got %d", len(h.fails))
	}
	if !strings.Contains(h.fails[0], "never faking online") {
		t.Fatalf("the fail must name the honest timeout, got: %s", h.fails[0])
	}
	failedSeen := false
	for _, s := range h.steps {
		if s == "verify/failed" {
			failedSeen = true
		}
	}
	if !failedSeen {
		t.Fatalf("verify/failed never reported; steps: %v", h.steps)
	}
	if len(deleted) != 1 || deleted[0] != "support-box-helper" {
		t.Fatalf("the half-built box must be torn down on a verify timeout, deleted: %v", deleted)
	}
	if h.rosterCalls < 2 {
		t.Fatalf("the poll should have retried before the budget expired, rosterCalls=%d", h.rosterCalls)
	}
}

// TestSupport_CredentialCustody is the HIGH-FLIP-RISK assert (PDF-D83 brief):
// the parent main's admin token appears NOWHERE in captured output — not in a
// step report, not in a console line, not in a succeed/fail body, and not in
// any on-box script. The LEDGER token may reach the box (0600 env — that IS
// its delivery) but must never appear in step/console output. Run over BOTH
// the happy path and the timeout-fail path.
func TestSupport_CredentialCustody(t *testing.T) {
	for _, tc := range []struct {
		name        string
		rosterLive  bool
		failEchoLeg string // parent-main leg that 500s with a token-echoing body
	}{
		{"happy_path", true, ""},
		{"roster_timeout_fail", false, ""},
		// Header-echoing error pages: the non-2xx body CONTAINS the parent token
		// (plus an unregistered secret-like string). The mutate leg pins the
		// step-detail + fail-body redaction; the mint leg pins the withheld body.
		{"mutate_500_echoes_token", true, "mutate"},
		{"mint_500_echoes_token", true, "mint"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newSupportHarness(t)
			h.rosterLive = tc.rosterLive
			h.failEchoLeg = tc.failEchoLeg
			runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
			var deleted []string
			w := h.worker(runner, &deleted)

			if _, err := w.RunOnceSupport(context.Background()); err != nil {
				t.Fatalf("RunOnceSupport: %v", err)
			}

			h.mu.Lock()
			cpOutput := strings.Join(append(append(append(append([]string{},
				h.stepBodies...), h.console...), h.succeeds...), h.fails...), "\n")
			h.mu.Unlock()
			scripts := strings.Join(runner.allScripts(), "\n")

			// The parent admin token: NEVER, anywhere.
			if strings.Contains(cpOutput, h.parentToken) {
				t.Fatal("CUSTODY VIOLATION: the parent admin token leaked into step/console/succeed/fail output")
			}
			if strings.Contains(scripts, h.parentToken) {
				t.Fatal("CUSTODY VIOLATION: the parent admin token was written into an on-box script")
			}
			// A failed leg must actually exercise the /fail sink…
			if tc.failEchoLeg != "" && len(h.fails) != 1 {
				t.Fatalf("the %s-500 scenario must report exactly one fail, got %d", tc.failEchoLeg, len(h.fails))
			}
			// …and a mint error must withhold the WHOLE body: even UNREGISTERED
			// secret-shaped content must never surface (redaction cannot scrub a
			// token the worker never learned).
			if tc.failEchoLeg == "mint" && strings.Contains(cpOutput, h.echoSecret) {
				t.Fatal("CUSTODY VIOLATION: the mint error echoed the response body")
			}
			// The minted ledger token: never in step/console output…
			if strings.Contains(cpOutput, h.mintToken) {
				t.Fatal("CUSTODY VIOLATION: the ledger token leaked into step/console output")
			}
			// …but on the happy path it IS delivered to the box (0600 env).
			if tc.rosterLive && tc.failEchoLeg == "" && !strings.Contains(scripts, h.mintToken) {
				t.Fatal("the ledger token never reached the box env — the listener could not authenticate")
			}
			// Provider keys are NEVER written (PDF-D62/D88): no provider/model key
			// assignment appears in any on-box script.
			for _, banned := range []string{"ANTHROPIC_API_KEY=", "OPENAI_API_KEY=", "HCLOUD_TOKEN"} {
				if strings.Contains(scripts, banned) {
					t.Fatalf("CUSTODY VIOLATION: %q written into an on-box script", banned)
				}
			}
			// The box's own admin token drives the on-box import and must ride with
			// Redact so a failing step's captured output is scrubbed.
			importSeen := false
			for _, s := range runner.steps {
				joined := strings.Join(s.Argv, " ")
				if strings.Contains(joined, "workspace import") {
					importSeen = true
					if len(s.Redact) == 0 {
						t.Fatal("the on-box import step must Redact the box admin token")
					}
				}
				if strings.Contains(joined, "BARKPARK_API_TOKEN") && len(s.Redact) == 0 {
					t.Fatal("the unit-install step must Redact the ledger token")
				}
			}
			if tc.failEchoLeg == "" && !importSeen {
				t.Fatal("the on-box merge-import step never ran")
			}
		})
	}
}

// TestRunOnceSupport_CreateFailure_WritesNothing proves PDF-D58 re-hosted: a
// placement failure fails the job honestly with NOTHING written — no box
// teardown (none exists), no roster row, no token mint on the parent main.
func TestRunOnceSupport_CreateFailure_WritesNothing(t *testing.T) {
	h := newSupportHarness(t)
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)
	// Override the seams with a failing create.
	seams := SupportSeams{
		CreateServer: func(context.Context, string) (cloud.Server, error) {
			return cloud.Server{}, fmt.Errorf("resource_unavailable: no cx23 in nbg1")
		},
		DeleteServer: func(_ context.Context, name string) error {
			deleted = append(deleted, name)
			return nil
		},
		RunnerFor: func(string) cloud.SupportRunner { return runner },
		ConfigureHost: func(context.Context, cloud.SupportRunner, cloud.SupportConfigureOpts) (cloud.Secrets, error) {
			t.Fatal("configure must not run after a failed create")
			return cloud.Secrets{}, nil
		},
		StepReporter: (&HTTPStepReporter{ControlURL: h.cp.URL, Token: "wtok"}).Report,
	}
	w.SupportProvision = DefaultSupportProvision(seams)

	claimed, err := w.RunOnceSupport(context.Background())
	if err != nil {
		t.Fatalf("RunOnceSupport: %v", err)
	}
	if !claimed {
		t.Fatal("the job should have been claimed + consumed via the fail report")
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.fails) != 1 || !strings.Contains(h.fails[0], "resource_unavailable") {
		t.Fatalf("want one honest fail naming the provider error, got: %v", h.fails)
	}
	if len(h.succeeds) != 0 {
		t.Fatalf("no succeed after a failed create: %v", h.succeeds)
	}
	if len(deleted) != 0 {
		t.Fatalf("nothing to tear down after a create failure, deleted: %v", deleted)
	}
	for _, e := range h.events {
		if e == "mutate" || e == "mint" || e == "export" || e == "roster" {
			t.Fatalf("a create failure must write NOTHING to the parent main; events: %v", h.events)
		}
	}
	if len(runner.allScripts()) != 0 {
		t.Fatalf("no on-box script may run after a failed create: %v", runner.allScripts())
	}
}

// TestRunOnceSupport_FlatClaimDialect proves the claim decode tolerates the
// CP's ACTUAL envelope: support_provision_claim_json reuses the flat claim_json
// shape (job_id/claim_token at the TOP level, no job/barkpark nesting) while
// the PDF-D83 pin nests them. The support map is identical in both dialects —
// the whole chain must drain to a succeed either way.
func TestRunOnceSupport_FlatClaimDialect(t *testing.T) {
	h := newSupportHarness(t)
	h.claimJSON = func() string {
		return fmt.Sprintf(`{"job_id":"job-sup-flat","claim_token":"ct-flat","name":"helper","slug":"helper","region":"nbg1","server_type":"cx23","env":{},"template":null,"support":{"parent_url":%q,"parent_admin_token":%q,"dataset":"production","workspace":"default","name":"helper"}}`,
			h.main.URL, h.parentToken)
	}
	runner := &supportFakeRunner{capacityJSON: `{"size_class":"standard"}`}
	var deleted []string
	w := h.worker(runner, &deleted)

	claimed, err := w.RunOnceSupport(context.Background())
	if err != nil {
		t.Fatalf("flat-dialect claim must drain cleanly, got: %v", err)
	}
	if !claimed {
		t.Fatal("the flat-dialect job should have been claimed")
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.succeeds) != 1 {
		t.Fatalf("want one succeed on the flat dialect, got %d (fails: %v)", len(h.succeeds), h.fails)
	}
	var sb map[string]any
	if err := json.Unmarshal([]byte(h.succeeds[0]), &sb); err != nil {
		t.Fatalf("succeed body not JSON: %v", err)
	}
	if ct, _ := sb["claim_token"].(string); ct != "ct-flat" {
		t.Fatalf("the flat dialect's claim token must be echoed on succeed, got %q", ct)
	}
	if len(deleted) != 0 {
		t.Fatalf("no teardown on the flat-dialect happy path, deleted: %v", deleted)
	}
}

// TestRunOnceSupport_NoJob_NoWiring covers the quiet paths: a 204 claim is not
// an error, and a worker without the support seam skips the queue entirely.
func TestRunOnceSupport_NoJob_NoWiring(t *testing.T) {
	h := newSupportHarness(t)
	runner := &supportFakeRunner{}
	var deleted []string
	w := h.worker(runner, &deleted)

	// Drain the single fake job so the queue is empty, then re-claim → 204.
	if _, err := w.RunOnceSupport(context.Background()); err != nil {
		t.Fatalf("first cycle: %v", err)
	}
	claimed, err := w.RunOnceSupport(context.Background())
	if err != nil {
		t.Fatalf("204 must not be an error: %v", err)
	}
	if claimed {
		t.Fatal("an empty queue must report claimed=false")
	}

	// No SupportProvision wired → the drain is a silent no-op.
	w2 := &Worker{ControlURL: h.cp.URL, Token: "wtok"}
	claimed, err = w2.RunOnceSupport(context.Background())
	if err != nil || claimed {
		t.Fatalf("unwired support drain must no-op, got claimed=%v err=%v", claimed, err)
	}
}
