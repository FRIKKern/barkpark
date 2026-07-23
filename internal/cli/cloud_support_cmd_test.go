package cli

// cloud_support_cmd_test.go proves `bp cloud support add` — the Personal Dev
// Fleet's ONE ACTION (Wave C, PDF-D56..D62) — against FAKES only: an httptest
// main (mutate / fleet bind routes / export / roster) plus an injected
// SupportRunner recorder. No hcloud, no SSH, no sleeps beyond a shrunken poll.
//
// The load-bearing claims, one test each:
//   - the eight named states run IN ORDER and the receipt is honest (happy path)
//   - a create-time placement failure writes NOTHING — zero requests reach the
//     main (PDF-D58; the roster row is written only after create succeeds)
//   - the roster row rides content.status=provisioning + ttl_s, NEVER a
//     top-level status, and is published in the same batch (PDF-D56)
//   - bind is real: token minted, control-plane row registered with token_id
//     (+ fleet_parent_id when --parent given), token delivered via a redacted
//     0600 env write as BARKPARK_API_TOKEN — and never printed
//   - the dataset leg exports profile=dev, streams the exact tar bytes to the
//     box, enables allow_bundle_import first, then merge-imports on-box
//   - runtime: fleet files from origin/main content, agent CLI FAIL-OPEN,
//     FLEET_MAX_CLASS from the measured class, provider keys NEVER copied
//     (the ssh one-liner is printed instead)
//   - honest terminal states: roster-row write failure, bind mint failure,
//     online-poll timeout (never faking online)

import (
	"bytes"
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

// supportEnvIsolate clears the ambient content-context env + config so the run
// resolves the "main" purely from the globals the test passes.
func supportEnvIsolate(t *testing.T) {
	t.Helper()
	withTempConfigHome(t)
	for _, k := range []string{"BARKPARK_API_URL", "BARKPARK_SERVER", "BARKPARK_API_TOKEN"} {
		t.Setenv(k, "")
	}
}

// supportSaveSeams snapshots every injected seam and restores it on cleanup, so
// tests never leak overrides into each other.
func supportSaveSeams(t *testing.T) {
	t.Helper()
	origCreate := supportCreateServer
	origProvider := supportProviderFor
	origRunner := supportRunnerFor
	origConfigure := supportConfigureHost
	origInterval := supportRosterPollInterval
	origBudget := supportRosterPollBudget
	origClock := supportClock
	t.Cleanup(func() {
		supportCreateServer = origCreate
		supportProviderFor = origProvider
		supportRunnerFor = origRunner
		supportConfigureHost = origConfigure
		supportRosterPollInterval = origInterval
		supportRosterPollBudget = origBudget
		supportClock = origClock
	})
}

// fakeSupportRunner records every step / feed / output request. Failure
// injection is by Title substring so tests name the step they break.
type fakeSupportRunner struct {
	mu        sync.Mutex
	steps     []cloud.CaddyStep // Run calls, in order
	outputs   map[string]string // RunOutput script -> stdout
	feeds     map[string][]byte // RunFeed script -> stdin bytes
	failTitle string            // Run fails when Title contains this
	waitErr   error
}

func newFakeSupportRunner() *fakeSupportRunner {
	return &fakeSupportRunner{outputs: map[string]string{}, feeds: map[string][]byte{}}
}

func (f *fakeSupportRunner) Run(_ context.Context, s cloud.CaddyStep) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.steps = append(f.steps, s)
	if f.failTitle != "" && strings.Contains(s.Title, f.failTitle) {
		return fmt.Errorf("injected failure at %q", s.Title)
	}
	return nil
}

func (f *fakeSupportRunner) RunOutput(_ context.Context, script string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if out, ok := f.outputs[script]; ok {
		return out, nil
	}
	return "", fmt.Errorf("no fake output for script %q", script)
}

func (f *fakeSupportRunner) RunFeed(_ context.Context, _, script string, stdin io.Reader) (string, error) {
	b, err := io.ReadAll(stdin)
	if err != nil {
		return "", err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.feeds[script] = b
	return "", nil
}

func (f *fakeSupportRunner) WaitReady(_ context.Context, _ time.Duration) error { return f.waitErr }

// scripts joins every Run step's script text for substring asserts.
func (f *fakeSupportRunner) scripts() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var b strings.Builder
	for _, s := range f.steps {
		b.WriteString(s.Title)
		b.WriteString("\n")
		b.WriteString(strings.Join(s.Argv, " "))
		b.WriteString("\n")
	}
	return b.String()
}

// supportMainRecorder is the fake MAIN: it serves the mutate, bind, export and
// roster routes and records everything that arrives.
type supportMainRecorder struct {
	mu       sync.Mutex
	requests []string          // "METHOD path" in arrival order
	bodies   map[string][]byte // path -> last body
	tarBytes string

	mutateStatus int // 0 => 200
	mintStatus   int
	rosterRow    map[string]any // nil => empty roster
}

func newSupportMainRecorder() *supportMainRecorder {
	return &supportMainRecorder{
		bodies:   map[string][]byte{},
		tarBytes: "SCRUBBED-DATASET-TAR-\x00\x01-bytes",
	}
}

func (m *supportMainRecorder) count(prefix string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, r := range m.requests {
		if strings.HasPrefix(r, prefix) {
			n++
		}
	}
	return n
}

func (m *supportMainRecorder) serve(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		m.mu.Lock()
		m.requests = append(m.requests, r.Method+" "+r.URL.Path)
		m.bodies[r.URL.Path] = body
		m.mu.Unlock()

		switch {
		case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/v1/data/mutate/"):
			status := m.mutateStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"ok":true,"results":[]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/fleet/support-tokens":
			status := m.mintStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			if status < 300 {
				_, _ = w.Write([]byte(`{"token":"sup-ledger-tok-abc123","token_id":"tid-42"}`))
			} else {
				_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no such route"}}`))
			}
		case r.Method == http.MethodPost && r.URL.Path == "/v1/fleet/supports":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"id":"support-row-1"}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/workspaces/") && strings.HasSuffix(r.URL.Path, "/export"):
			w.Header().Set("Content-Type", "application/x-tar")
			_, _ = w.Write([]byte(m.tarBytes))
		case r.Method == http.MethodGet && r.URL.Path == "/v1/fleet/roster":
			var docs []map[string]any
			m.mu.Lock()
			if m.rosterRow != nil {
				docs = append(docs, m.rosterRow)
			}
			m.mu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]any{"documents": docs})
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found"}}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// supportHappyWiring installs the standard happy-path fakes: create succeeds,
// SSH ready, configure returns minted secrets, capacity measures standard.
func supportHappyWiring(t *testing.T, runner *fakeSupportRunner) {
	t.Helper()
	supportSaveSeams(t)
	supportProviderFor = func() (cloud.CloudProvider, error) { return nil, nil }
	supportCreateServer = func(_ context.Context, _ cloud.CloudProvider, _ string, name string) (cloud.Server, error) {
		return cloud.Server{
			Name:   "warm-cafe01",
			IP:     "203.0.113.9",
			Labels: map[string]string{cloud.FleetSupportLabelKey: name},
		}, nil
	}
	supportRunnerFor = func(string) cloud.SupportRunner { return runner }
	supportConfigureHost = func(_ context.Context, _ cloud.SupportRunner, opts cloud.SupportConfigureOpts) (cloud.Secrets, error) {
		if opts.Narrate != nil {
			opts.Narrate("health-local", "ok")
		}
		return cloud.Secrets{AdminToken: "box-admin-tok-xyz"}, nil
	}
	runner.outputs[supportCapacityMeasureScript] = `{"size_class":"standard","slots_total":1,"slots_free":1}`
	supportRosterPollInterval = time.Millisecond
	supportRosterPollBudget = 250 * time.Millisecond
}

// runSupport drives the FULL runCloud dispatcher (case "support") so the switch
// wiring is part of the proof.
func runSupport(t *testing.T, g globals, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	w.output = g.output
	code := runCloud(w, g, append([]string{"support"}, args...))
	return sout.String(), serr.String(), code
}

// TestCloudSupportAddHappyPath: the eight named states in order, the roster row
// shape, the bind, the dataset stream, the runtime install, the key one-liner,
// and the final receipt.
func TestCloudSupportAddHappyPath(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{
		"worker": "hex", "status": "idle",
		"capacity": map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1},
	}
	srv := main.serve(t)

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"},
		"add", "hex", "--agent", "claude", "--parent", "cp-row-7")
	if code != exitOK {
		t.Fatalf("want exit %d, got %d\nstdout:\n%s\nstderr:\n%s", exitOK, code, stdout, stderr)
	}

	// The eight named states, in order, on stdout (human progress narration).
	last := -1
	for _, state := range []string{"create", "wait-ready", "roster-row", "configure", "bind", "dataset", "runtime", "online"} {
		idx := strings.Index(stdout, "→ "+state+":")
		if idx < 0 {
			t.Fatalf("state %q never narrated\nstdout:\n%s", state, stdout)
		}
		if idx < last {
			t.Fatalf("state %q narrated out of order\nstdout:\n%s", state, stdout)
		}
		last = idx
	}

	// Roster row (PDF-D56): content.status=provisioning, ttl_s, NEVER top-level
	// status; published in the same atomic batch; dataset in the path.
	if got := main.count("POST /v1/data/mutate/production"); got != 1 {
		t.Fatalf("want exactly 1 mutate call, got %d (%v)", got, main.requests)
	}
	var mutate struct {
		Mutations []map[string]json.RawMessage `json:"mutations"`
	}
	if err := json.Unmarshal(main.bodies["/v1/data/mutate/production"], &mutate); err != nil {
		t.Fatalf("mutate body not JSON: %v", err)
	}
	if len(mutate.Mutations) != 2 {
		t.Fatalf("want createOrReplace+publish, got %d mutations", len(mutate.Mutations))
	}
	var doc map[string]any
	if err := json.Unmarshal(mutate.Mutations[0]["createOrReplace"], &doc); err != nil {
		t.Fatalf("first mutation is not createOrReplace: %v", err)
	}
	if doc["_id"] != "listener-hex" || doc["_type"] != "listener" {
		t.Fatalf("roster doc identity wrong: %v", doc)
	}
	if _, hasTopStatus := doc["status"]; hasTopStatus {
		t.Fatalf("roster doc carries a TOP-LEVEL status — PDF-D56 forbids it: %v", doc)
	}
	content, _ := doc["content"].(map[string]any)
	if content["status"] != "provisioning" || content["worker"] != "hex" {
		t.Fatalf("content.status/worker wrong: %v", content)
	}
	if ttl, _ := content["ttl_s"].(float64); int(ttl) != supportProvisioningTTL {
		t.Fatalf("want ttl_s=%d, got %v", supportProvisioningTTL, content["ttl_s"])
	}
	var pub map[string]any
	if err := json.Unmarshal(mutate.Mutations[1]["publish"], &pub); err != nil || pub["id"] != "listener-hex" || pub["type"] != "listener" {
		t.Fatalf("publish mutation wrong: %s", mutate.Mutations[1]["publish"])
	}

	// Bind: mint + control-plane row with token_id AND the explicit --parent.
	if main.count("POST /v1/fleet/support-tokens") != 1 || main.count("POST /v1/fleet/supports") != 1 {
		t.Fatalf("bind calls wrong: %v", main.requests)
	}
	// The mint contract key is "name" (the endpoint 422s without it).
	var mint map[string]any
	if err := json.Unmarshal(main.bodies["/v1/fleet/support-tokens"], &mint); err != nil {
		t.Fatalf("mint body not JSON: %v", err)
	}
	if mint["name"] != "hex" {
		t.Fatalf("mint body must carry name=hex (the endpoint's required key): %v", mint)
	}
	var reg map[string]any
	if err := json.Unmarshal(main.bodies["/v1/fleet/supports"], &reg); err != nil {
		t.Fatalf("supports body not JSON: %v", err)
	}
	// parent_id + host are the CP endpoint's contract keys (PDF-D61).
	if reg["token_id"] != "tid-42" || reg["parent_id"] != "cp-row-7" || reg["worker"] != "hex" ||
		reg["name"] != "hex" || reg["host"] != "203.0.113.9" {
		t.Fatalf("support registration wrong: %v", reg)
	}

	// Dataset leg: profile=dev export, exact tar bytes streamed, import gated
	// behind allow_bundle_import, merge import on the box's OWN localhost.
	exportPath := "/api/workspaces/default/export"
	if main.count("GET "+exportPath) != 1 {
		t.Fatalf("want 1 export GET at %s, got %v", exportPath, main.requests)
	}
	var fed []byte
	for _, b := range runner.feeds {
		fed = b
	}
	if string(fed) != main.tarBytes {
		t.Fatalf("streamed tar bytes differ: got %q want %q", fed, main.tarBytes)
	}
	scripts := runner.scripts()
	for _, want := range []string{
		"BARKPARK_ALLOW_BUNDLE_IMPORT=1",
		"install-cli.sh",
		"--file /opt/barkpark-fleet/dataset.tar --yes --merge",
		"http://localhost:4000",
		"fleet-run.sh",
		"fleet-protocol.md",
		"barkpark-fleet-listener.service",
		"BARKPARK_API_URL",
		"BARKPARK_API_TOKEN",
		"chmod 600 /etc/barkpark/fleet-listener.env",
		"'standard'",
		"systemctl enable --now barkpark-fleet-listener",
	} {
		if !strings.Contains(scripts, want) {
			t.Fatalf("no on-box step contains %q\nscripts:\n%s", want, scripts)
		}
	}

	// The minted ledger token rides ONLY inside the redacted env step — it is
	// never narrated and never printed.
	if strings.Contains(stdout, "sup-ledger-tok-abc123") || strings.Contains(stderr, "sup-ledger-tok-abc123") {
		t.Fatalf("minted token leaked into output")
	}
	redacted := false
	for _, s := range runner.steps {
		for _, r := range s.Redact {
			if r == "sup-ledger-tok-abc123" {
				redacted = true
			}
		}
	}
	if !redacted {
		t.Fatalf("the env-write step does not redact the minted token")
	}

	// Provider keys are NEVER copied: no step mentions the key var; the ssh
	// one-liner hands it over instead.
	if strings.Contains(scripts, "ANTHROPIC_API_KEY") {
		t.Fatalf("a provisioning step references ANTHROPIC_API_KEY — keys must never be copied")
	}
	if !strings.Contains(stdout, "ANTHROPIC_API_KEY=<your-key>") || !strings.Contains(stdout, "ssh root@203.0.113.9") {
		t.Fatalf("the ssh key one-liner is missing\nstdout:\n%s", stdout)
	}

	if !strings.Contains(stdout, "support hex is ONLINE") {
		t.Fatalf("final receipt missing\nstdout:\n%s", stdout)
	}
}

// TestCloudSupportAddCreateFailureWritesNothing: a placement failure (the
// live-proven Hetzner 412) prints the provider error and provably writes
// NOTHING — zero requests reach the main, no runner is touched.
func TestCloudSupportAddCreateFailureWritesNothing(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
		return cloud.Server{}, fmt.Errorf("hetzner: create server: resource_unavailable (412): no cx22 available in fsn1")
	}
	main := newSupportMainRecorder()
	srv := main.serve(t)

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
	if code == exitOK {
		t.Fatalf("want failure exit, got OK\nstdout:%s", stdout)
	}
	main.mu.Lock()
	writes := len(main.requests)
	main.mu.Unlock()
	if writes != 0 {
		t.Fatalf("create failed but %d request(s) reached the main: %v", writes, main.requests)
	}
	if len(runner.steps) != 0 || len(runner.feeds) != 0 {
		t.Fatalf("create failed but the runner was driven: %+v", runner.steps)
	}
	if !strings.Contains(stderr, "resource_unavailable (412)") {
		t.Fatalf("provider error not surfaced\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stderr, "nothing was created and nothing was written") {
		t.Fatalf("honest written-state line missing\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stderr, "bp cloud support add hex") {
		t.Fatalf("next-command line missing\nstderr:\n%s", stderr)
	}
}

// TestCloudSupportAddRosterRowFailure: the main refuses the mutate — the fail
// is honest (box exists + billing, NO roster row) and the bind never runs.
func TestCloudSupportAddRosterRowFailure(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	main := newSupportMainRecorder()
	main.mutateStatus = http.StatusForbidden
	srv := main.serve(t)

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
	if code == exitOK {
		t.Fatalf("want failure exit")
	}
	if !strings.Contains(stderr, "NO roster row written") {
		t.Fatalf("honest state line missing\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stderr, "main answered 403") {
		t.Fatalf("status not surfaced\nstderr:\n%s", stderr)
	}
	if got := main.count("POST /v1/fleet/support-tokens"); got != 0 {
		t.Fatalf("bind ran after a roster-row failure (%d mint calls)", got)
	}
}

// TestCloudSupportAddBindMintFailure: the main lacks the fleet bind routes —
// the fail names the missing route and the honest next command.
func TestCloudSupportAddBindMintFailure(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	main := newSupportMainRecorder()
	main.mintStatus = http.StatusNotFound
	srv := main.serve(t)

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
	if code == exitOK {
		t.Fatalf("want failure exit")
	}
	if !strings.Contains(stderr, "support-token mint failed") || !strings.Contains(stderr, "main answered 404") {
		t.Fatalf("mint failure not honest\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stderr, "/v1/fleet/support-tokens") {
		t.Fatalf("next step does not name the missing route\nstderr:\n%s", stderr)
	}
	if got := main.count("POST /v1/fleet/supports"); got != 0 {
		t.Fatalf("registration ran after mint failed")
	}
}

// TestCloudSupportAddOnlineTimeout: the listener never beats — the poll expires
// with an honest timeout (the row ages to offline; online is never faked), yet
// the bring-up steps all completed and the key one-liner was still printed.
func TestCloudSupportAddOnlineTimeout(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{"worker": "hex", "status": "provisioning"} // never gains capacity
	srv := main.serve(t)

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
	if code == exitOK {
		t.Fatalf("want timeout exit, got OK")
	}
	if !strings.Contains(stderr, "never faking online") {
		t.Fatalf("honest timeout line missing\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stderr, "last read: provisioning") {
		t.Fatalf("last roster read not reported\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stderr, "journalctl -u barkpark-fleet-listener") {
		t.Fatalf("next command missing\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stdout, "ANTHROPIC_API_KEY=<your-key>") {
		t.Fatalf("key one-liner must print even on a poll timeout\nstdout:\n%s", stdout)
	}
}

// TestCloudSupportAddAgentInstallFailOpen: a broken npm install degrades the
// agent CLI LOUDLY but the bring-up still succeeds (presence never depends on
// the vendor CLI).
func TestCloudSupportAddAgentInstallFailOpen(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	runner.failTitle = "install node + the agent CLI"
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{
		"worker": "hex", "status": "idle",
		"capacity": map[string]any{"size_class": "light", "slots_total": 1, "slots_free": 1},
	}
	srv := main.serve(t)

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex", "--agent", "codex")
	if code != exitOK {
		t.Fatalf("agent install must be fail-open, got exit %d\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stderr, "codex CLI install degraded") {
		t.Fatalf("degradation must be loud\nstderr:\n%s", stderr)
	}
	if !strings.Contains(stdout, "support hex is ONLINE") {
		t.Fatalf("bring-up should still succeed\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "OPENAI_API_KEY=<your-key>") {
		t.Fatalf("codex key one-liner missing\nstdout:\n%s", stdout)
	}
}

// TestCloudSupportAddDryRun: --dry-run prints the eight states and touches
// NOTHING — no provider, no runner, no main.
func TestCloudSupportAddDryRun(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
		t.Fatal("dry run must not create")
		return cloud.Server{}, nil
	}
	main := newSupportMainRecorder()
	srv := main.serve(t)

	stdout, _, code := runSupport(t, globals{server: srv.URL, token: "op-tok", dryRun: true}, "add", "hex")
	if code != exitOK {
		t.Fatalf("dry run exit %d\nstdout:\n%s", code, stdout)
	}
	for _, want := range []string{"DRY RUN", "create", "wait-ready", "roster-row", "configure", "bind", "dataset", "runtime", "online"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("dry-run narration missing %q\nstdout:\n%s", want, stdout)
		}
	}
	main.mu.Lock()
	defer main.mu.Unlock()
	if len(main.requests) != 0 {
		t.Fatalf("dry run reached the main: %v", main.requests)
	}
}

// TestCloudSupportUsage: the fences — bad name, unknown agent, missing name,
// and the honest not-built answer for remove.
func TestCloudSupportUsage(t *testing.T) {
	supportEnvIsolate(t)
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing name", []string{"add"}, "want exactly one <name>"},
		{"bad name", []string{"add", "Bad_Name"}, "invalid support name"},
		{"unknown agent", []string{"add", "hex", "--agent", "gemini"}, "unknown --agent"},
		{"remove not built", []string{"remove", "hex"}, "not built yet"},
		{"unknown verb", []string{"paint", "hex"}, "unknown support command"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, code := runSupport(t, globals{}, tc.args...)
			if code != exitUsage {
				t.Fatalf("want exit %d, got %d", exitUsage, code)
			}
			if !strings.Contains(stderr, tc.want) {
				t.Fatalf("want %q in stderr:\n%s", tc.want, stderr)
			}
		})
	}
}

// TestCloudSupportAddJSONReceipt: -o json emits one structured receipt whose
// truth matches the run (and still never carries the minted token).
func TestCloudSupportAddJSONReceipt(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{
		"worker": "hex", "status": "idle",
		"capacity": map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1},
	}
	srv := main.serve(t)

	stdout, _, code := runSupport(t, globals{server: srv.URL, token: "op-tok", output: "json", outputSet: true}, "add", "hex")
	if code != exitOK {
		t.Fatalf("exit %d\nstdout:\n%s", code, stdout)
	}
	var receipt struct {
		OK      bool `json:"ok"`
		Support struct {
			Name     string `json:"name"`
			IP       string `json:"ip"`
			MaxClass string `json:"max_class"`
			Unit     string `json:"unit"`
			TokenID  string `json:"token_id"`
		} `json:"support"`
		KeyVar string `json:"key_var"`
	}
	if err := json.Unmarshal([]byte(stdout), &receipt); err != nil {
		t.Fatalf("receipt not JSON: %v\n%s", err, stdout)
	}
	if !receipt.OK || receipt.Support.Name != "hex" || receipt.Support.IP != "203.0.113.9" ||
		receipt.Support.MaxClass != "standard" || receipt.Support.Unit != "barkpark-fleet-listener" ||
		receipt.Support.TokenID != "tid-42" || receipt.KeyVar != "ANTHROPIC_API_KEY" {
		t.Fatalf("receipt wrong: %+v", receipt)
	}
	if strings.Contains(stdout, "sup-ledger-tok-abc123") {
		t.Fatalf("minted token leaked into the JSON receipt")
	}
}
