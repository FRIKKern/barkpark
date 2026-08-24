package cli

// cloud_support_cmd_test.go proves `bp cloud support add` + `remove` — the
// Personal Dev Fleet's ONE ACTION and its mirror (Wave C, PDF-D56..D62,
// D68..D72) — against FAKES only, on a TWO-HOST harness (PDF-D72): an httptest
// MAIN (mutate / token mint+revoke / export / roster) AND a distinct httptest
// CONTROL PLANE (barkparks list / fleet supports register+delete), seeded via
// seedCloudLogin/SaveConfig(CloudURL). Every bind/unbind test asserts WHICH
// host received the call — the round-1 single-fake-host harness is exactly why
// the bind-targets-the-wrong-host bug passed 9/9 green.
//
// The load-bearing claims, one test each:
//   - the eight named states run IN ORDER and the receipt is honest (happy path)
//   - a create-time placement failure writes NOTHING — zero requests reach the
//     main (PDF-D58; the roster row is written only after create succeeds)
//   - the roster row rides content.status=provisioning + ttl_s, NEVER a
//     top-level status, and is published in the same batch (PDF-D56)
//   - bind is real AND correctly split (PDF-D69): the token is minted on the
//     MAIN, the group record is registered on the CONTROL PLANE — which-host
//     asserted; a missing Cloud login fails BEFORE the box create; the CP's
//     401 / 422 no_team / 403 forbidden refusals get named narrations
//   - parent auto-resolve (PDF-D70): url-host match (never the host column),
//     one/zero/many branches, --parent wins outright
//   - the dataset leg exports profile=dev, streams the exact tar bytes to the
//     box, enables allow_bundle_import first, then merge-imports on-box
//   - runtime: fleet files from origin/main content, agent CLI FAIL-OPEN,
//     FLEET_MAX_CLASS from the measured class, provider keys NEVER copied
//     (the ssh one-liner is printed instead)
//   - honest terminal states: roster-row write failure, bind mint failure,
//     online-poll timeout (never faking online)
//   - remove (PDF-D68, five surfaces since PDF-D101): the ordered teardown,
//     the identity fence, the verify-gone census (planted survivors caught +
//     named, non-zero), double-remove idempotence, partial-state convergence,
//     the 403→401 token probe (alive = named survivor), and the A-record
//     sweep BY VALUE (both same-IP records deleted, the by-name trap; the
//     credential precedence --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute;
//     warn-and-continue on a failing delete; honest SKIP when the CP row
//     carries no url)

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
	// axi-b4: the server/token names come from the shared dialect lists; the
	// DNS token is this suite's own and stays literal.
	for _, k := range append(append(append([]string{}, ServerEnvNames...), TokenEnvNames...), "BARKPARK_DNS_HCLOUD_TOKEN") {
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
	origDNS := supportDNSFor
	t.Cleanup(func() {
		supportCreateServer = origCreate
		supportProviderFor = origProvider
		supportRunnerFor = origRunner
		supportConfigureHost = origConfigure
		supportRosterPollInterval = origInterval
		supportRosterPollBudget = origBudget
		supportClock = origClock
		supportDNSFor = origDNS
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

// supportCallLog is a cross-host, cross-seam order log: the main recorder, the
// CP recorder, and the provider wrapper all append to ONE list so a test can
// assert the PDF-D68 teardown ORDER across all of them.
type supportCallLog struct {
	mu    sync.Mutex
	calls []string
}

func (l *supportCallLog) add(s string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, s)
}

func (l *supportCallLog) list() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]string, len(l.calls))
	copy(out, l.calls)
	return out
}

// supportAssertOrder asserts each want appears (as a substring) at a strictly
// increasing position in log.
func supportAssertOrder(t *testing.T, log []string, wants ...string) {
	t.Helper()
	idx := -1
	for _, want := range wants {
		found := -1
		for i, c := range log {
			if i > idx && strings.Contains(c, want) {
				found = i
				break
			}
		}
		if found < 0 {
			t.Fatalf("call containing %q not found after index %d\nlog:\n%s", want, idx, strings.Join(log, "\n"))
		}
		idx = found
	}
}

// supportMainRecorder is the fake MAIN: it serves the mutate, token mint +
// revoke, export and roster routes and records everything that arrives.
type supportMainRecorder struct {
	mu       sync.Mutex
	requests []string          // "METHOD path" in arrival order
	bodies   map[string][]byte // path -> last body
	tarBytes string

	mutateStatus int // 0 => 200
	mintStatus   int
	rosterRow    map[string]any // nil => empty roster

	// remove-side knobs.
	log                *supportCallLog // optional cross-host order log
	revokeStatus       int             // 0 => 200 {revoked:true}
	revoked            bool            // set once the revoke DELETE lands — drives the 403→401 probe
	probeBearer        string          // the support's own raw token; the mint route answers 403/401 to it
	probeStuckValid    bool            // planted survivor: the probe stays 403 after revoke
	rosterDeleteHonest bool            // a delete mutation actually drops rosterRow
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
		if m.log != nil {
			m.log.add("main " + r.Method + " " + r.URL.Path)
		}
		m.mu.Unlock()

		switch {
		case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/v1/data/mutate/"):
			m.mu.Lock()
			if m.rosterDeleteHonest && strings.Contains(string(body), `"delete"`) {
				m.rosterRow = nil
			}
			status := m.mutateStatus
			m.mu.Unlock()
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"ok":true,"results":[]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/fleet/support-tokens":
			// The census token probe: the support's OWN bearer reads 403 while the
			// token is valid (authenticated, not admin) and 401 after revoke.
			m.mu.Lock()
			bearer := m.probeBearer
			dead := m.revoked && !m.probeStuckValid
			m.mu.Unlock()
			if bearer != "" && r.Header.Get("Authorization") == "Bearer "+bearer {
				if dead {
					w.WriteHeader(http.StatusUnauthorized)
					_, _ = w.Write([]byte(`{"error":{"code":"unauthorized"}}`))
				} else {
					w.WriteHeader(http.StatusForbidden)
					_, _ = w.Write([]byte(`{"error":{"code":"forbidden"}}`))
				}
				return
			}
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
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/fleet/support-tokens/"):
			id := strings.TrimPrefix(r.URL.Path, "/v1/fleet/support-tokens/")
			m.mu.Lock()
			status := m.revokeStatus
			if status == 0 {
				status = http.StatusOK
			}
			if status < 300 {
				m.revoked = true
			}
			m.mu.Unlock()
			w.WriteHeader(status)
			if status < 300 {
				_ = json.NewEncoder(w).Encode(map[string]any{"token_id": id, "revoked": true})
			} else {
				_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no token with that id"}}`))
			}
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

// supportCPRecorder is the fake CONTROL PLANE — the PDF-D72 second host. It
// serves the fleet-registry routes (barkparks list, fleet supports register +
// delete) and records everything, so tests can assert WHICH host received the
// register/unbind calls.
type supportCPRecorder struct {
	mu       sync.Mutex
	requests []string
	bodies   map[string][]byte

	rows           []map[string]any // GET /v1/barkparks payload
	registerStatus int              // 0 => 201
	registerBody   string           // non-2xx body override (e.g. `{"error":"no_team"}`)
	deleteStatus   int              // 0 => 200
	honestDelete   bool             // DELETE /v1/fleet/supports/:id actually drops the row
	deleteQueries  []string         // the RAW query string of every DELETE /v1/fleet/supports/:id
	log            *supportCallLog
}

// deleteQuery returns the raw query string of the nth (0-based) support DELETE,
// or "" when fewer were made. `?mode=detach` is the CLI ASSERTING it already
// swept the zone, so which runs send it is a behaviour worth pinning.
func (c *supportCPRecorder) deleteQuery(n int) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if n >= len(c.deleteQueries) {
		return ""
	}
	return c.deleteQueries[n]
}

func newSupportCPRecorder() *supportCPRecorder {
	return &supportCPRecorder{bodies: map[string][]byte{}}
}

func (c *supportCPRecorder) count(prefix string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, r := range c.requests {
		if strings.HasPrefix(r, prefix) {
			n++
		}
	}
	return n
}

func (c *supportCPRecorder) serve(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		c.mu.Lock()
		c.requests = append(c.requests, r.Method+" "+r.URL.Path)
		c.bodies[r.URL.Path] = body
		if c.log != nil {
			c.log.add("cp " + r.Method + " " + r.URL.Path)
		}
		c.mu.Unlock()

		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/barkparks":
			c.mu.Lock()
			rows := append([]map[string]any(nil), c.rows...)
			c.mu.Unlock()
			_ = json.NewEncoder(w).Encode(map[string]any{"barkparks": rows})
		case r.Method == http.MethodPost && r.URL.Path == "/v1/fleet/supports":
			status := c.registerStatus
			if status == 0 {
				status = http.StatusCreated
			}
			w.WriteHeader(status)
			if status < 300 {
				_, _ = w.Write([]byte(`{"barkpark":{"id":"support-row-1","name":"hex","fleet_role":"support"}}`))
			} else if c.registerBody != "" {
				_, _ = w.Write([]byte(c.registerBody))
			} else {
				_, _ = w.Write([]byte(`{"error":"invalid"}`))
			}
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/fleet/supports/"):
			id := strings.TrimPrefix(r.URL.Path, "/v1/fleet/supports/")
			c.mu.Lock()
			c.deleteQueries = append(c.deleteQueries, r.URL.RawQuery)
			c.mu.Unlock()
			status := c.deleteStatus
			if status == 0 {
				status = http.StatusOK
			}
			// 202 is the control plane KEEPING the row while its worker tears the
			// box + A record down, so an honest fake must not drop it (the real
			// route deletes the row from the worker's succeed callback instead).
			if status < 300 && status != http.StatusAccepted && c.honestDelete {
				c.mu.Lock()
				kept := c.rows[:0]
				for _, row := range c.rows {
					if fmt.Sprintf("%v", row["id"]) != id {
						kept = append(kept, row)
					}
				}
				c.rows = kept
				c.mu.Unlock()
			}
			w.WriteHeader(status)
			switch {
			case status == http.StatusAccepted:
				_, _ = w.Write([]byte(`{"ok":true,"status":"deprovisioning"}`))
			case status < 300:
				_, _ = w.Write([]byte(`{"ok":true,"status":"removed"}`))
			default:
				_, _ = w.Write([]byte(`{"error":"not_found"}`))
			}
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// supportCPMainRow is one registered MAIN on the fake control plane. The host
// column is a DECOY raw IP by design (mirroring live rows): PDF-D70's
// auto-resolve must match by url host, never the host column.
func supportCPMainRow(mainURL string) map[string]any {
	return map[string]any{
		"id": "cp-main-1", "name": "my-main", "url": mainURL,
		"host": "198.51.100.7", "fleet_role": "main",
	}
}

// supportSeedCP stands up the fake CONTROL PLANE and seeds the bp-login config
// (CloudURL + CloudToken via SaveConfig — the precedented seedCloudLogin
// pattern, which survives supportEnvIsolate's temp XDG_CONFIG_HOME). A
// non-empty mainURL seeds one main row whose url matches the active main so a
// bare `add` auto-resolves its parent (PDF-D70).
func supportSeedCP(t *testing.T, mainURL string) (*supportCPRecorder, *httptest.Server) {
	t.Helper()
	cp := newSupportCPRecorder()
	if mainURL != "" {
		cp.rows = []map[string]any{supportCPMainRow(mainURL)}
	}
	srv := cp.serve(t)
	seedCloudLogin(t, srv.URL)
	return cp, srv
}

// supportFleetProvider wraps the in-memory FakeProvider with order logging and
// planted-lie knobs for the census tests.
type supportFleetProvider struct {
	*cloud.FakeProvider
	log         *supportCallLog
	lieOnDelete bool           // planted survivor: Delete reports success but keeps the box
	foreign     []cloud.Server // when non-nil, ListByLabel returns these verbatim
}

func (p *supportFleetProvider) Delete(ctx context.Context, name string) error {
	if p.log != nil {
		p.log.add("provider Delete " + name)
	}
	if p.lieOnDelete {
		return nil
	}
	return p.FakeProvider.Delete(ctx, name)
}

func (p *supportFleetProvider) ListByLabel(ctx context.Context, key, val string) ([]cloud.Server, error) {
	if p.log != nil {
		p.log.add("provider ListByLabel " + key + "=" + val)
	}
	if p.foreign != nil {
		return p.foreign, nil
	}
	return p.FakeProvider.ListByLabel(ctx, key, val)
}

// supportSeedBox plants one labeled support box in a fresh wrapped provider and
// wires supportProviderFor to it. Callers must have run supportSaveSeams.
func supportSeedBox(t *testing.T, log *supportCallLog, name, worker string) *supportFleetProvider {
	t.Helper()
	fp := cloud.NewFakeProvider()
	if name != "" {
		if _, err := fp.Create(context.Background(), cloud.ServerSpec{Name: name}); err != nil {
			t.Fatalf("seed box: %v", err)
		}
		if err := fp.LabelServer(context.Background(), name, cloud.FleetSupportLabelKey, worker); err != nil {
			t.Fatalf("label box: %v", err)
		}
	}
	p := &supportFleetProvider{FakeProvider: fp, log: log}
	supportProviderFor = func() (cloud.CloudProvider, error) { return p, nil }
	return p
}

// supportFakeDNS wraps the in-memory FakeDNS with order logging and a
// planted-lie knob for the census tests: a delete that errors leaves the
// record standing, so the fifth census leg has something real to catch.
type supportFakeDNS struct {
	*cloud.FakeDNS
	log        *supportCallLog
	failDelete bool
}

func (d *supportFakeDNS) DeleteRecord(ctx context.Context, zone, name, typ string) error {
	if d.log != nil {
		d.log.add("dns DeleteRecord " + name)
	}
	if d.failDelete {
		return fmt.Errorf("injected dns delete failure for %s", name)
	}
	return d.FakeDNS.DeleteRecord(ctx, zone, name, typ)
}

// supportSeedDNS plants the TWO A records every provisioner-born support
// leaks — the support chain's own label (TTL 60) AND the go-live sibling
// <name>-<teamid> (no TTL) — BOTH at the box IP (the by-name trap: deleting
// only the first passes a by-name census while the leak survives), plus an
// unrelated record at a different IP that must SURVIVE the sweep. Wires
// supportDNSFor to the fake and captures the resolved credential so tests can
// assert the --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute precedence.
// Callers must have run supportSaveSeams.
func supportSeedDNS(t *testing.T, log *supportCallLog, name, ip string) (*supportFakeDNS, *string) {
	t.Helper()
	fake := &supportFakeDNS{FakeDNS: cloud.NewFakeDNS(), log: log}
	seed := func(label, value string, ttl int) {
		if err := fake.FakeDNS.UpsertRecord(context.Background(), cloud.Record{
			Zone: "barkpark.cloud", Name: label, Type: "A", Value: value, TTL: ttl,
		}); err != nil {
			t.Fatalf("seed dns %s: %v", label, err)
		}
	}
	seed(name, ip, 60)                   // the support chain's record (TTL 60)
	seed(name+"-506f035e", ip, 0)        // the go-live sibling — the by-name trap
	seed("bystander", "203.0.113.77", 0) // unrelated value — must survive
	gotToken := new(string)
	supportDNSFor = func(tok string) cloud.DNSProvider {
		*gotToken = tok
		return fake
	}
	return fake, gotToken
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
	cp, _ := supportSeedCP(t, srv.URL)

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

	// Bind (PDF-D69): the mint lands on the MAIN, the register on the CONTROL
	// PLANE — which-host asserted BOTH ways (the round-1 harness could not see
	// a wrong-host bind).
	if main.count("POST /v1/fleet/support-tokens") != 1 || cp.count("POST /v1/fleet/supports") != 1 {
		t.Fatalf("bind calls wrong: main=%v cp=%v", main.requests, cp.requests)
	}
	if main.count("POST /v1/fleet/supports") != 0 {
		t.Fatalf("the register leg hit the MAIN — PDF-D69 requires the control plane: %v", main.requests)
	}
	if cp.count("POST /v1/fleet/support-tokens") != 0 {
		t.Fatalf("the mint leg hit the CONTROL PLANE — it lives on the main: %v", cp.requests)
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
	if err := json.Unmarshal(cp.bodies["/v1/fleet/supports"], &reg); err != nil {
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
		// task-2ba0270056e7da6e: the target workspace is ensured on the box
		// BEFORE the merge-import (create tolerates already-exists), so a
		// template-workspace bundle lands on the proven adopt branch.
		"POST http://localhost:4000/api/workspaces",
		`"slug":"default"`,
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

	// Ordering: this run's workspace IS "default" (no --workspace, no context),
	// so the seeded-workspace reset bracket must fire — the warm image's baked
	// Postgres carries seed docs, so without the reset the box's own "default"
	// flunks the merge engine's empty-shell proof and the import 409s
	// workspace_slug_conflict. Strict order:
	// reset < re-mint#1 < ensure < import < re-mint#2 (both default-workspace
	// deletes — the reset's and the import's PDS-D9 adopt-delete — cascade the
	// box admin token, api_tokens.workspace_id :delete_all).
	resetIdx, ensureIdx, importIdx := -1, -1, -1
	var mintIdxs []int
	for i, s := range runner.steps {
		joined := strings.Join(s.Argv, " ")
		if strings.Contains(joined, "Barkpark.Tenancy.delete_workspace") {
			resetIdx = i
		}
		if strings.Contains(joined, "Barkpark.Auth.create_token") {
			mintIdxs = append(mintIdxs, i)
			if !strings.Contains(joined, "box-admin-tok-xyz") {
				t.Fatal("the re-mint must restore the chain's own admin token value verbatim")
			}
		}
		if strings.Contains(joined, "POST http://localhost:4000/api/workspaces") {
			ensureIdx = i
		}
		if strings.Contains(joined, "workspace import") {
			importIdx = i
		}
	}
	if resetIdx == -1 {
		t.Fatal("the default-workspace reset step never ran on a ws=default add")
	}
	if len(mintIdxs) != 2 {
		t.Fatalf("want exactly 2 admin-token re-mints (post-reset + post-import), got %d", len(mintIdxs))
	}
	if ensureIdx == -1 || importIdx == -1 ||
		!(resetIdx < mintIdxs[0] && mintIdxs[0] < ensureIdx && ensureIdx < importIdx && importIdx < mintIdxs[1]) {
		t.Fatalf("default-workspace bracket out of order: reset=%d mint1=%d ensure=%d import=%d mint2=%d",
			resetIdx, mintIdxs[0], ensureIdx, importIdx, mintIdxs[1])
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
	supportSeedCP(t, srv.URL)

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
	cp, _ := supportSeedCP(t, srv.URL)

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
	if got := cp.count("POST /v1/fleet/supports"); got != 0 {
		t.Fatalf("register ran after a roster-row failure (%d register calls)", got)
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
	cp, _ := supportSeedCP(t, srv.URL)

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
	if got := cp.count("POST /v1/fleet/supports"); got != 0 {
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
	supportSeedCP(t, srv.URL)

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
	supportSeedCP(t, srv.URL)

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
// for BOTH verbs (the round-1 "remove not built yet" stub + its test are
// replaced as a pair by the real verb's fences).
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
		{"remove missing name", []string{"remove"}, "want exactly one <name>"},
		{"remove bad name", []string{"remove", "Bad_Name"}, "invalid support name"},
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
	supportSeedCP(t, srv.URL) // bare add: the parent auto-resolves (PDF-D70)

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

// ── bind rewire + auto-resolve (PDF-D69/D70) ─────────────────────────────────

// TestCloudSupportAddMissingCloudTokenFailsBeforeCreate: a known-missing Cloud
// credential must never bill a box (PDF-D69/D58) — the gate fires BEFORE the
// provider create and names `bp login`.
func TestCloudSupportAddMissingCloudTokenFailsBeforeCreate(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
		t.Fatal("a missing Cloud login must fail BEFORE the box create")
		return cloud.Server{}, nil
	}
	main := newSupportMainRecorder()
	srv := main.serve(t)
	// NO seedCloudLogin: the config has no CloudToken.

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
	if code != exitAuth {
		t.Fatalf("want exit %d (auth), got %d\nstderr:\n%s", exitAuth, code, stderr)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("the bp-login hint is missing\nstderr:\n%s", stderr)
	}
	main.mu.Lock()
	defer main.mu.Unlock()
	if len(main.requests) != 0 {
		t.Fatalf("a logged-out add reached the main: %v", main.requests)
	}
}

// TestCloudSupportAddBindWhichHost: the PDF-D69 which-host proof in isolation —
// the mint NEVER hits the CP, the register NEVER hits the main, and the mint
// body is byte-identical to the round-1 contract ({"name","worker"}).
func TestCloudSupportAddBindWhichHost(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportHappyWiring(t, runner)
	main := newSupportMainRecorder()
	main.rosterRow = map[string]any{
		"worker": "hex", "status": "idle",
		"capacity": map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1},
	}
	srv := main.serve(t)
	cp, _ := supportSeedCP(t, srv.URL)

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
	if code != exitOK {
		t.Fatalf("exit %d\nstderr:\n%s", code, stderr)
	}
	if main.count("POST /v1/fleet/support-tokens") != 1 || cp.count("POST /v1/fleet/support-tokens") != 0 {
		t.Fatalf("mint must land on the MAIN only: main=%v cp=%v", main.requests, cp.requests)
	}
	if cp.count("POST /v1/fleet/supports") != 1 || main.count("POST /v1/fleet/supports") != 0 {
		t.Fatalf("register must land on the CONTROL PLANE only: main=%v cp=%v", main.requests, cp.requests)
	}
	var mint map[string]any
	if err := json.Unmarshal(main.bodies["/v1/fleet/support-tokens"], &mint); err != nil {
		t.Fatalf("mint body not JSON: %v", err)
	}
	if len(mint) != 2 || mint["name"] != "hex" || mint["worker"] != "hex" {
		t.Fatalf("mint body must stay byte-identical to the round-1 contract: %v", mint)
	}
}

// TestCloudSupportAddCPRefusalNarrations: the CP's credential-aware refusals
// each get a NAMED narration — 401 → bp login, 422 no_team → bp team use,
// 403 → team-admin / deploy-ability (the PAT ruling made explicit).
//
// The `403 no_team (post-#9956)` row is the STATUS-FLIP guard (cch-w40-s4): the
// control plane's team gate is being converted from 422 {"error":"no_team"} to
// 403 {"error":"forbidden","reason":"no_team","scope":"team"}. Reading the STATUS
// alone hands a caller who HAS NO TEAM a sentence about a ROLE they cannot be
// granted without one — so the two no_team rows must stay identical in hint and
// exit across that flip, while the plain `403 forbidden` row proves a real
// authority refusal is still narrated as one.
func TestCloudSupportAddCPRefusalNarrations(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		body     string
		wantHint string
		wantExit int
	}{
		{"401 dead session", http.StatusUnauthorized, `{"error":"unauthorized"}`, "bp login", exitAuth},
		{"422 no_team", http.StatusUnprocessableEntity, `{"error":"no_team"}`, "bp team use", exitGeneric},
		{"403 no_team (post-#9956)", http.StatusForbidden, `{"error":"forbidden","reason":"no_team","scope":"team"}`, "bp team use", exitGeneric},
		// Added at review: the cause AS the code at the new status. The predicate
		// read `reason` only, so this body fell into the role arm and told a
		// teamless caller they needed team-admin.
		{"403 no_team, cause as code", http.StatusForbidden, `{"error":"no_team"}`, "bp team use", exitGeneric},
		{"403 forbidden", http.StatusForbidden, `{"error":"forbidden"}`, "a session needs team-admin, a PAT needs the deploy ability", exitAuth},
		{"403 role", http.StatusForbidden, `{"error":"forbidden","reason":"role","required":"team_admin"}`, "a session needs team-admin, a PAT needs the deploy ability", exitAuth},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			supportEnvIsolate(t)
			runner := newFakeSupportRunner()
			supportHappyWiring(t, runner)
			main := newSupportMainRecorder()
			srv := main.serve(t)
			cp, _ := supportSeedCP(t, srv.URL)
			cp.registerStatus = tc.status
			cp.registerBody = tc.body

			_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
			if code != tc.wantExit {
				t.Fatalf("want exit %d, got %d\nstderr:\n%s", tc.wantExit, code, stderr)
			}
			if !strings.Contains(stderr, tc.wantHint) {
				t.Fatalf("want the named narration %q\nstderr:\n%s", tc.wantHint, stderr)
			}
			// A teamless caller must never ALSO be handed the role sentence — the
			// role is not the problem and cannot be granted without a team.
			if tc.wantHint == "bp team use" && strings.Contains(stderr, "a session needs team-admin") {
				t.Fatalf("a no_team refusal was narrated as a role problem\nstderr:\n%s", stderr)
			}
			// The honest written-state line still names the minted-but-unbound token.
			if !strings.Contains(stderr, "NOT registered") {
				t.Fatalf("honest state line missing\nstderr:\n%s", stderr)
			}
		})
	}
}

// TestCloudSupportAddParentAutoResolve: PDF-D70's three branches + the
// --parent-wins fast path + the host-column trap (a row whose HOST matches but
// whose URL does not must NOT resolve — the host column is a raw IP on every
// real row and matching it returns garbage by construction).
func TestCloudSupportAddParentAutoResolve(t *testing.T) {
	newMain := func(t *testing.T) (*supportMainRecorder, *httptest.Server) {
		t.Helper()
		main := newSupportMainRecorder()
		main.rosterRow = map[string]any{
			"worker": "hex", "status": "idle",
			"capacity": map[string]any{"size_class": "standard", "slots_total": 1, "slots_free": 1},
		}
		return main, main.serve(t)
	}

	t.Run("exactly one url-host match resolves", func(t *testing.T) {
		supportEnvIsolate(t)
		runner := newFakeSupportRunner()
		supportHappyWiring(t, runner)
		_, srv := newMain(t)
		cp, _ := supportSeedCP(t, srv.URL)
		// Decoys: a support row (never a parent) and an unrelated main.
		cp.rows = append(cp.rows,
			map[string]any{"id": "cp-sup-9", "name": "old-sup", "url": srv.URL, "fleet_role": "support"},
			map[string]any{"id": "cp-other", "name": "other-main", "url": "https://elsewhere.example", "fleet_role": "main"},
		)

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
		if code != exitOK {
			t.Fatalf("exit %d\nstderr:\n%s", code, stderr)
		}
		var reg map[string]any
		if err := json.Unmarshal(cp.bodies["/v1/fleet/supports"], &reg); err != nil {
			t.Fatalf("supports body not JSON: %v", err)
		}
		if reg["parent_id"] != "cp-main-1" {
			t.Fatalf("auto-resolved parent_id wrong: %v", reg)
		}
	})

	t.Run("zero matches refuses naming candidates before create", func(t *testing.T) {
		supportEnvIsolate(t)
		runner := newFakeSupportRunner()
		supportHappyWiring(t, runner)
		supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
			t.Fatal("a failed parent resolve must never create a box")
			return cloud.Server{}, nil
		}
		main, srv := newMain(t)
		cp, _ := supportSeedCP(t, "")
		// The HOST-COLUMN TRAP: this row's host IS the main's host, but its url
		// is elsewhere — PDF-D70 says NEVER match the host column, so this must
		// be a zero-match refusal, not a resolve.
		cp.rows = []map[string]any{{
			"id": "cp-trap", "name": "trap-main",
			"url":        "https://elsewhere.example",
			"host":       strings.TrimPrefix(strings.TrimPrefix(srv.URL, "http://"), "https://"),
			"fleet_role": "main",
		}}

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
		if code == exitOK {
			t.Fatalf("want refusal, got OK")
		}
		if !strings.Contains(stderr, "no control-plane row's url matches") {
			t.Fatalf("refusal not named\nstderr:\n%s", stderr)
		}
		if !strings.Contains(stderr, "trap-main") {
			t.Fatalf("candidates not named\nstderr:\n%s", stderr)
		}
		main.mu.Lock()
		defer main.mu.Unlock()
		if len(main.requests) != 0 {
			t.Fatalf("a refused resolve reached the main: %v", main.requests)
		}
	})

	t.Run("many matches refuses naming candidates", func(t *testing.T) {
		supportEnvIsolate(t)
		runner := newFakeSupportRunner()
		supportHappyWiring(t, runner)
		supportCreateServer = func(context.Context, cloud.CloudProvider, string, string) (cloud.Server, error) {
			t.Fatal("an ambiguous parent resolve must never create a box")
			return cloud.Server{}, nil
		}
		_, srv := newMain(t)
		cp, _ := supportSeedCP(t, srv.URL)
		cp.rows = append(cp.rows, map[string]any{"id": "cp-main-2", "name": "twin-main", "url": srv.URL, "fleet_role": "main"})

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex")
		if code == exitOK {
			t.Fatalf("want refusal, got OK")
		}
		if !strings.Contains(stderr, "refusing to pick one") ||
			!strings.Contains(stderr, "my-main") || !strings.Contains(stderr, "twin-main") {
			t.Fatalf("ambiguity refusal must name every candidate\nstderr:\n%s", stderr)
		}
	})

	t.Run("explicit --parent wins outright", func(t *testing.T) {
		supportEnvIsolate(t)
		runner := newFakeSupportRunner()
		supportHappyWiring(t, runner)
		_, srv := newMain(t)
		cp, _ := supportSeedCP(t, srv.URL)

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "add", "hex", "--parent", "cp-row-7")
		if code != exitOK {
			t.Fatalf("exit %d\nstderr:\n%s", code, stderr)
		}
		if got := cp.count("GET /v1/barkparks"); got != 0 {
			t.Fatalf("--parent must skip the fleet list entirely, got %d GETs", got)
		}
		var reg map[string]any
		if err := json.Unmarshal(cp.bodies["/v1/fleet/supports"], &reg); err != nil {
			t.Fatalf("supports body not JSON: %v", err)
		}
		if reg["parent_id"] != "cp-row-7" {
			t.Fatalf("explicit --parent must win: %v", reg)
		}
	})
}

// ── the mirror verb: remove (PDF-D68/D72) ────────────────────────────────────

// supportRemoveWiring seeds the standard remove fixture: a main that answers
// revoke + roster honestly, a CP carrying the main row AND the support row
// (with the url the DNS zone derives from), a provider holding the labeled box
// (FakeProvider's first create ⇒ IP 10.0.0.1), a fake DNS zone carrying BOTH
// leaked A records at that IP, and a runner that yields the probe secret.
// Everything shares one order log.
func supportRemoveWiring(t *testing.T) (*supportMainRecorder, *httptest.Server, *supportCPRecorder, *supportFleetProvider, *supportFakeDNS, *supportCallLog) {
	t.Helper()
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportSaveSeams(t)
	log := &supportCallLog{}

	main := newSupportMainRecorder()
	main.log = log
	main.probeBearer = "sup-ledger-tok-abc123"
	main.rosterDeleteHonest = true
	main.rosterRow = map[string]any{"worker": "hex", "status": "idle"}
	srv := main.serve(t)

	cp, _ := supportSeedCP(t, srv.URL)
	cp.log = log
	cp.honestDelete = true
	cp.rows = append(cp.rows, map[string]any{
		"id": "support-row-1", "name": "hex", "fleet_role": "support",
		"url":             "https://hex.barkpark.cloud",
		"fleet_parent_id": "cp-main-1", "fleet_token_id": "tid-42",
	})

	provider := supportSeedBox(t, log, "warm-cafe01", "hex")
	dns, _ := supportSeedDNS(t, log, "hex", "10.0.0.1") // FakeProvider's first create ⇒ 10.0.0.1
	runner.outputs[supportProbeSecretScript] = "sup-ledger-tok-abc123\n"
	supportRunnerFor = func(string) cloud.SupportRunner { return runner }
	return main, srv, cp, provider, dns, log
}

// TestCloudSupportRemoveHappyTeardown: the full PDF-D68 order — CP read FIRST,
// token revoke on the main, identity-fenced box delete, the by-VALUE A-record
// sweep (PDF-D101), roster-row delete via the dataset-in-path mutate, CP row
// DELETE LAST — then the five-surface census re-reads everything and reports
// delta zero, with the REAL 403→401 token probe.
func TestCloudSupportRemoveHappyTeardown(t *testing.T) {
	main, srv, cp, _, _, log := supportRemoveWiring(t)

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code != exitOK {
		t.Fatalf("want exit 0, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}

	// The teardown ORDER, across both hosts and the provider seam.
	supportAssertOrder(t, log.list(),
		"cp GET /v1/barkparks",                        // read FIRST — the sole durable token-id holder
		"main DELETE /v1/fleet/support-tokens/tid-42", // then revoke on the main
		"provider Delete warm-cafe01",                 // then the fenced box delete
		"dns DeleteRecord hex",                        // then the by-VALUE A sweep: the support record…
		"dns DeleteRecord hex-506f035e",               // …AND the same-IP go-live sibling (the by-name trap)
		"main POST /v1/data/mutate/production",        // then the roster row
		"cp DELETE /v1/fleet/supports/support-row-1",  // CP row LAST
	)

	// The roster delete is the PDF-D44d dataset-in-path {id,type} mutate.
	var mutate struct {
		Mutations []map[string]map[string]any `json:"mutations"`
	}
	if err := json.Unmarshal(main.bodies["/v1/data/mutate/production"], &mutate); err != nil {
		t.Fatalf("mutate body not JSON: %v", err)
	}
	if len(mutate.Mutations) != 1 || mutate.Mutations[0]["delete"] == nil ||
		mutate.Mutations[0]["delete"]["id"] != "listener-hex" || mutate.Mutations[0]["delete"]["type"] != "listener" {
		t.Fatalf("roster delete mutation wrong: %s", main.bodies["/v1/data/mutate/production"])
	}

	// The census RE-READS: a second label listing, a roster re-GET, a CP re-list.
	listings := 0
	for _, c := range log.list() {
		if strings.Contains(c, "provider ListByLabel") {
			listings++
		}
	}
	if listings < 2 {
		t.Fatalf("the census must RE-READ the provider (want >=2 listings, got %d)\nlog:\n%s", listings, strings.Join(log.list(), "\n"))
	}
	if main.count("GET /v1/fleet/roster") < 1 {
		t.Fatalf("the census never re-read the roster: %v", main.requests)
	}
	if cp.count("GET /v1/barkparks") < 2 {
		t.Fatalf("the census never re-read the control plane: %v", cp.requests)
	}

	// The token leg is the REAL probe: the support's own bearer hit the
	// admin-gated mint endpoint (403 pre-revoke baseline, 401 after).
	if !strings.Contains(stdout, "401 after revoke") {
		t.Fatalf("token probe verdict missing\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "census delta zero") {
		t.Fatalf("census verdict missing\nstdout:\n%s", stdout)
	}
	// The probe secret is never printed.
	if strings.Contains(stdout, "sup-ledger-tok-abc123") || strings.Contains(stderr, "sup-ledger-tok-abc123") {
		t.Fatalf("the probe secret leaked into output")
	}
}

// TestCloudSupportRemoveForeignIdentityRefusal: a box whose identity label
// names a DIFFERENT support is REFUSED loudly — nothing is deleted anywhere
// (the DeprovisionByIP fence, ported).
func TestCloudSupportRemoveForeignIdentityRefusal(t *testing.T) {
	main, srv, cp, provider, _, log := supportRemoveWiring(t)
	provider.foreign = []cloud.Server{{
		Name:   "warm-other",
		IP:     "203.0.113.99",
		Labels: map[string]string{cloud.FleetSupportLabelKey: "someone-else"},
	}}

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code == exitOK {
		t.Fatalf("want refusal, got OK")
	}
	if !strings.Contains(stderr, `"someone-else"`) || !strings.Contains(stderr, "REFUSING") {
		t.Fatalf("the refusal must name the foreign identity\nstderr:\n%s", stderr)
	}
	for _, c := range log.list() {
		if strings.Contains(c, "provider Delete") {
			t.Fatalf("a foreign-identity box was deleted:\n%s", strings.Join(log.list(), "\n"))
		}
	}
	if main.count("DELETE /v1/fleet/support-tokens/") != 0 {
		t.Fatalf("the token was revoked despite the refusal: %v", main.requests)
	}
	if cp.count("DELETE /v1/fleet/supports/") != 0 {
		t.Fatalf("the CP row was deleted despite the refusal: %v", cp.requests)
	}
}

// TestCloudSupportRemoveTwoBoxAnomaly: >1 label match is a named anomaly —
// never pick-one.
func TestCloudSupportRemoveTwoBoxAnomaly(t *testing.T) {
	_, srv, _, provider, _, log := supportRemoveWiring(t)
	provider.foreign = []cloud.Server{
		{Name: "warm-a", IP: "203.0.113.1", Labels: map[string]string{cloud.FleetSupportLabelKey: "hex"}},
		{Name: "warm-b", IP: "203.0.113.2", Labels: map[string]string{cloud.FleetSupportLabelKey: "hex"}},
	}

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code == exitOK {
		t.Fatalf("want refusal, got OK")
	}
	if !strings.Contains(stderr, "2 boxes carry") || !strings.Contains(stderr, "warm-a") || !strings.Contains(stderr, "warm-b") {
		t.Fatalf("the anomaly must name every box\nstderr:\n%s", stderr)
	}
	for _, c := range log.list() {
		if strings.Contains(c, "provider Delete") {
			t.Fatalf("an ambiguous match was deleted:\n%s", strings.Join(log.list(), "\n"))
		}
	}
}

// TestCloudSupportRemovePlantedSurvivors: every surface LIES about deleting —
// the census catches and NAMES all five survivors and exits non-zero. This is
// the proof the verify-gone check can fail (a census that cannot fail proves
// nothing).
func TestCloudSupportRemovePlantedSurvivors(t *testing.T) {
	main, srv, cp, provider, dns, _ := supportRemoveWiring(t)
	provider.lieOnDelete = true     // box survives its "successful" delete
	main.rosterDeleteHonest = false // roster row survives the mutate
	cp.honestDelete = false         // CP row survives the DELETE
	main.probeStuckValid = true     // token still answers 403 after revoke
	dns.failDelete = true           // the A records survive their deletes

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code == exitOK {
		t.Fatalf("planted survivors must exit non-zero\nstdout:\n%s", stdout)
	}
	all := stdout + stderr
	for _, want := range []string{
		"server warm-cafe01",              // survivor 1: the box
		"roster row listener-hex still",   // survivor 2: the roster row
		"control-plane row support-row-1", // survivor 3: the CP row
		"STILL VALID",                     // survivor 4: the token (403, not 401)
		"A record hex.barkpark.cloud still resolves to box IP 10.0.0.1",          // survivor 5a: the support A record
		"A record hex-506f035e.barkpark.cloud still resolves to box IP 10.0.0.1", // survivor 5b: the go-live sibling
	} {
		if !strings.Contains(all, want) {
			t.Fatalf("survivor %q not named\noutput:\n%s", want, all)
		}
	}
}

// TestCloudSupportRemoveDoubleRemoveIdempotent: everything already gone — the
// second run exits 0 reporting already-gone, census clean.
func TestCloudSupportRemoveDoubleRemoveIdempotent(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportSaveSeams(t)
	log := &supportCallLog{}

	main := newSupportMainRecorder()
	main.log = log
	main.rosterRow = nil // roster row gone
	srv := main.serve(t)

	cp, _ := supportSeedCP(t, srv.URL) // only the main row — support row gone
	cp.log = log
	supportSeedBox(t, log, "", "") // provider holds no box
	supportRunnerFor = func(string) cloud.SupportRunner { return runner }

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code != exitOK {
		t.Fatalf("double remove must exit 0, got %d\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "already unbound") || !strings.Contains(stdout, "already gone") {
		t.Fatalf("already-gone narration missing\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "census delta zero") {
		t.Fatalf("census verdict missing\nstdout:\n%s", stdout)
	}
	if main.count("DELETE /v1/fleet/support-tokens/") != 0 {
		t.Fatalf("nothing to revoke, yet a revoke fired: %v", main.requests)
	}
}

// TestCloudSupportRemovePartialStateConverges: the box is already gone but the
// roster row + CP row survive (a crashed earlier remove) and the token is
// already revoked (revoke answers 404) — the re-run converges to census-clean.
func TestCloudSupportRemovePartialStateConverges(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportSaveSeams(t)
	log := &supportCallLog{}

	main := newSupportMainRecorder()
	main.log = log
	main.revokeStatus = http.StatusNotFound // token already revoked
	main.rosterDeleteHonest = true
	main.rosterRow = map[string]any{"worker": "hex", "status": "provisioning"}
	srv := main.serve(t)

	cp, _ := supportSeedCP(t, srv.URL)
	cp.log = log
	cp.honestDelete = true
	cp.rows = append(cp.rows, map[string]any{
		"id": "support-row-1", "name": "hex", "fleet_role": "support", "fleet_token_id": "tid-42",
	})
	supportSeedBox(t, log, "", "") // box already gone
	supportRunnerFor = func(string) cloud.SupportRunner { return runner }

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code != exitOK {
		t.Fatalf("partial state must converge to exit 0, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "already gone (404)") {
		t.Fatalf("idempotent revoke narration missing\nstdout:\n%s", stdout)
	}
	if main.count("POST /v1/data/mutate/production") != 1 {
		t.Fatalf("the surviving roster row was not deleted: %v", main.requests)
	}
	if cp.count("DELETE /v1/fleet/supports/support-row-1") != 1 {
		t.Fatalf("the surviving CP row was not deleted: %v", cp.requests)
	}
	if !strings.Contains(stdout, "census delta zero") {
		t.Fatalf("census verdict missing\nstdout:\n%s", stdout)
	}
}

// TestCloudSupportRemoveDryRun: --dry-run prints the ordered plan and touches
// NOTHING — no provider, no main, no CP, no login required.
func TestCloudSupportRemoveDryRun(t *testing.T) {
	supportEnvIsolate(t)
	runner := newFakeSupportRunner()
	supportSaveSeams(t)
	supportProviderFor = func() (cloud.CloudProvider, error) {
		t.Fatal("dry run must not touch the provider")
		return nil, nil
	}
	supportRunnerFor = func(string) cloud.SupportRunner { return runner }
	main := newSupportMainRecorder()
	srv := main.serve(t)

	stdout, _, code := runSupport(t, globals{server: srv.URL, token: "op-tok", dryRun: true}, "remove", "hex")
	if code != exitOK {
		t.Fatalf("dry run exit %d\nstdout:\n%s", code, stdout)
	}
	for _, want := range []string{"DRY RUN", "cp-read", "locate", "token", "server", "dns", "roster", "cp-row", "census"} {
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

// TestCloudSupportRemoveCPRowForbiddenNarration: a 403 on the CP-row DELETE
// warns with the NAMED credential fix (a bare "re-run" can never converge on a
// credential refusal — PDF-D69/D71 vocabulary), continues, and the census still
// names the surviving row with a non-zero exit.
func TestCloudSupportRemoveCPRowForbiddenNarration(t *testing.T) {
	main, srv, cp, _, _, _ := supportRemoveWiring(t)
	cp.deleteStatus = http.StatusForbidden
	cp.honestDelete = false

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code == exitOK {
		t.Fatalf("a surviving CP row must exit non-zero\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stderr, "a session needs team-admin, a PAT needs the deploy ability") {
		t.Fatalf("the 403 warn must name the credential fix\nstderr:\n%s", stderr)
	}
	all := stdout + stderr
	if !strings.Contains(all, "control-plane row support-row-1 still registered") {
		t.Fatalf("the census must still name the survivor\noutput:\n%s", all)
	}
	// Everything BEFORE the CP row still tore down (warn-and-continue, not stop).
	if main.count("DELETE /v1/fleet/support-tokens/tid-42") != 1 {
		t.Fatalf("the token revoke must still have run: %v", main.requests)
	}
}

// TestCloudSupportRemoveDNSSweepByValue: the A-record teardown is BY VALUE
// (PDF-D101) — the zone holds the support's own record AND the go-live sibling
// <name>-<teamid>, BOTH at the box IP, and BOTH are deleted (a by-name delete
// removes one, leaves the other, and a by-name census still reads clean). The
// sweep runs between the box delete and the roster leg, and --dns-token is the
// credential that actually reaches the DNS provider (never the fleet compute
// token, which sees zero zones).
func TestCloudSupportRemoveDNSSweepByValue(t *testing.T) {
	_, srv, _, _, _, log := supportRemoveWiring(t)
	_, gotToken := supportSeedDNS(t, log, "hex", "10.0.0.1") // rewire to capture the token

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex", "--dns-token", "dns-proj-tok")
	if code != exitOK {
		t.Fatalf("want exit 0, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *gotToken != "dns-proj-tok" {
		t.Fatalf("--dns-token must reach the DNS provider, got %q", *gotToken)
	}
	supportAssertOrder(t, log.list(),
		"provider Delete warm-cafe01",          // the box goes first…
		"dns DeleteRecord hex",                 // …then the by-VALUE sweep: the support record…
		"dns DeleteRecord hex-506f035e",        // …AND the same-IP go-live sibling (the by-name trap)
		"main POST /v1/data/mutate/production", // …then the roster leg
	)
	if !strings.Contains(stdout, "hex.barkpark.cloud") || !strings.Contains(stdout, "hex-506f035e.barkpark.cloud") {
		t.Fatalf("the deleted records must be named\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "dns verified by value") {
		t.Fatalf("the census must report the dns leg verified by value\nstdout:\n%s", stdout)
	}
}

// TestCloudSupportRemoveDetachOnlyWhenTheZoneWasSwept (task-688ebffc4b0aa50a):
// the control-plane row DELETE now carries `?mode=detach` — "I already tore the
// A record down, drop the row" — and it must carry that ONLY on the runs where
// this command can actually say so. The CP's default is to KEEP a live support's
// row and enqueue a teardown, precisely because that row is the last thing that
// names the record; a detach asserted on a run that never swept would throw the
// name away and leave the record standing, which is the whole bug.
func TestCloudSupportRemoveDetachOnlyWhenTheZoneWasSwept(t *testing.T) {
	t.Run("the sweep ran: detach is asserted", func(t *testing.T) {
		_, srv, cp, _, _, _ := supportRemoveWiring(t)

		stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex", "--dns-token", "dns-proj-tok")
		if code != exitOK {
			t.Fatalf("want exit 0, got %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
		}
		if !strings.Contains(stdout, "dns verified by value") {
			t.Fatalf("precondition: this run must have swept the zone\nstdout:\n%s", stdout)
		}
		if got := cp.deleteQuery(0); got != "mode=detach" {
			t.Fatalf("a swept run must assert detach on the CP row delete, got query %q", got)
		}
	})

	t.Run("the sweep was SKIPPED: no detach, the control plane decides", func(t *testing.T) {
		_, srv, cp, _, _, _ := supportRemoveWiring(t)
		// Strip the row's url: dnsTarget() can derive no zone/label, so stepDNS
		// SKIPS — this run has no idea whether a record survives.
		cp.mu.Lock()
		for _, row := range cp.rows {
			delete(row, "url")
		}
		cp.mu.Unlock()

		stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex", "--dns-token", "dns-proj-tok")
		_ = code
		all := stdout + stderr
		if !strings.Contains(all, "SKIPPED") {
			t.Fatalf("precondition: the dns leg must have skipped\noutput:\n%s", all)
		}
		if got := cp.deleteQuery(0); got != "" {
			t.Fatalf("a run that never swept must NOT claim detach, got query %q", got)
		}
	})
}

// TestCloudSupportRemoveCPHandoffIsNamedNotSwallowed (task-688ebffc4b0aa50a):
// when the control plane answers 202 it KEPT the row on purpose and enqueued a
// deprovision job so its own worker tears the box + A record down. That is
// neither a failure nor a removal, and the census must say which — a bare
// "still registered" would read as a leak and a silent ✓ would be a lie.
func TestCloudSupportRemoveCPHandoffIsNamedNotSwallowed(t *testing.T) {
	_, srv, cp, _, _, _ := supportRemoveWiring(t)
	cp.deleteStatus = http.StatusAccepted

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex", "--dns-token", "dns-proj-tok")
	all := stdout + stderr
	if code == exitOK {
		t.Fatalf("a surviving CP row must not exit 0\noutput:\n%s", all)
	}
	if !strings.Contains(all, "202") || !strings.Contains(all, "deprovision job") {
		t.Fatalf("the 202 hand-off must be narrated at the cp-row step\noutput:\n%s", all)
	}
	if !strings.Contains(all, "the control plane kept it on purpose") {
		t.Fatalf("the census must name WHY the row survived, not just that it did\noutput:\n%s", all)
	}
}

// TestCloudSupportRemoveDNSBothRecordsGoneBystanderSurvives: after the sweep,
// BOTH same-IP records are gone from the zone and the unrelated record at a
// different IP is untouched — asserted against the fake zone itself, not the
// command's own narration.
func TestCloudSupportRemoveDNSBothRecordsGoneBystanderSurvives(t *testing.T) {
	_, srv, _, _, dns, _ := supportRemoveWiring(t)

	_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex", "--dns-token", "dns-proj-tok")
	if code != exitOK {
		t.Fatalf("want exit 0, got %d\nstderr:\n%s", code, stderr)
	}
	for _, fqdn := range []string{"hex.barkpark.cloud", "hex-506f035e.barkpark.cloud"} {
		vals, err := dns.FakeDNS.Resolve(context.Background(), fqdn)
		if err != nil {
			t.Fatalf("resolve %s: %v", fqdn, err)
		}
		if len(vals) != 0 {
			t.Fatalf("A record %s must be gone after the by-value sweep, still resolves to %v", fqdn, vals)
		}
	}
	vals, err := dns.FakeDNS.Resolve(context.Background(), "bystander.barkpark.cloud")
	if err != nil {
		t.Fatalf("resolve bystander: %v", err)
	}
	if len(vals) != 1 || vals[0] != "203.0.113.77" {
		t.Fatalf("the unrelated record must SURVIVE the sweep, got %v", vals)
	}
}

// TestCloudSupportRemoveDNSTokenPrecedence: the sweep credential follows
// instDNSClient's law — --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute —
// and the compute fallback is never silent (the fleet compute token sees ZERO
// zones, so a quiet fallback would fail the leg silently on every real
// teardown).
func TestCloudSupportRemoveDNSTokenPrecedence(t *testing.T) {
	t.Run("env token wins over compute", func(t *testing.T) {
		_, srv, _, _, _, log := supportRemoveWiring(t)
		_, gotToken := supportSeedDNS(t, log, "hex", "10.0.0.1")
		t.Setenv("BARKPARK_DNS_HCLOUD_TOKEN", "env-dns-tok")

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
		if code != exitOK {
			t.Fatalf("exit %d\nstderr:\n%s", code, stderr)
		}
		if *gotToken != "env-dns-tok" {
			t.Fatalf("BARKPARK_DNS_HCLOUD_TOKEN must reach the DNS provider, got %q", *gotToken)
		}
		if strings.Contains(stderr, "riding the compute token") {
			t.Fatalf("an env-resolved credential must not warn about the compute fallback\nstderr:\n%s", stderr)
		}
	})

	t.Run("--dns-token beats the env", func(t *testing.T) {
		_, srv, _, _, _, log := supportRemoveWiring(t)
		_, gotToken := supportSeedDNS(t, log, "hex", "10.0.0.1")
		t.Setenv("BARKPARK_DNS_HCLOUD_TOKEN", "env-dns-tok")

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex", "--dns-token", "flag-dns-tok")
		if code != exitOK {
			t.Fatalf("exit %d\nstderr:\n%s", code, stderr)
		}
		if *gotToken != "flag-dns-tok" {
			t.Fatalf("--dns-token must beat the env, got %q", *gotToken)
		}
	})

	t.Run("compute fallback warns loudly", func(t *testing.T) {
		_, srv, _, _, _, log := supportRemoveWiring(t)
		_, gotToken := supportSeedDNS(t, log, "hex", "10.0.0.1")

		_, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
		if code != exitOK {
			t.Fatalf("exit %d\nstderr:\n%s", code, stderr)
		}
		if *gotToken != "" {
			t.Fatalf("the compute fallback passes an empty token (CloudDNS inherits the process credential), got %q", *gotToken)
		}
		if !strings.Contains(stderr, "riding the compute token") || !strings.Contains(stderr, "ZERO zones") {
			t.Fatalf("the compute fallback must warn loudly\nstderr:\n%s", stderr)
		}
	})
}

// TestCloudSupportRemoveDNSDeleteFailureWarnsAndContinues: a failing DNS
// delete is WARN-AND-CONTINUE — the roster and CP legs still tear down — and
// the census's fifth leg then names every surviving A record BY VALUE with a
// non-zero exit. The census, not the step, is what fails the command.
func TestCloudSupportRemoveDNSDeleteFailureWarnsAndContinues(t *testing.T) {
	main, srv, cp, _, dns, _ := supportRemoveWiring(t)
	dns.failDelete = true

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code == exitOK {
		t.Fatalf("surviving A records must exit non-zero\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stderr, "⚠ dns: sweep failed") || !strings.Contains(stderr, "continuing; the census below is the truth") {
		t.Fatalf("the DNS failure must warn-and-continue, never stop\nstderr:\n%s", stderr)
	}
	// The steps AFTER dns still ran (warn-and-continue, not r.fail).
	if main.count("POST /v1/data/mutate/production") != 1 {
		t.Fatalf("the roster leg must still run after a DNS failure: %v", main.requests)
	}
	if cp.count("DELETE /v1/fleet/supports/support-row-1") != 1 {
		t.Fatalf("the CP-row leg must still run after a DNS failure: %v", cp.requests)
	}
	all := stdout + stderr
	for _, want := range []string{
		"A record hex.barkpark.cloud still resolves to box IP 10.0.0.1",
		"A record hex-506f035e.barkpark.cloud still resolves to box IP 10.0.0.1",
	} {
		if !strings.Contains(all, want) {
			t.Fatalf("the census must name the surviving A record %q\noutput:\n%s", want, all)
		}
	}
}

// TestCloudSupportRemoveDNSSkipNoURL: a CP row without a url means the DNS
// zone cannot be derived — the leg is SKIPPED and SAYS SO (an honest absence,
// PDS-D287), it is never reported clean, no DNS provider is ever built, and
// the rest of the teardown still converges to exit 0.
func TestCloudSupportRemoveDNSSkipNoURL(t *testing.T) {
	_, srv, cp, _, _, _ := supportRemoveWiring(t)
	cp.mu.Lock()
	for _, row := range cp.rows {
		if fmt.Sprintf("%v", row["id"]) == "support-row-1" {
			delete(row, "url")
		}
	}
	cp.mu.Unlock()
	supportDNSFor = func(string) cloud.DNSProvider {
		t.Fatal("the skip path must never build a DNS provider")
		return nil
	}

	stdout, stderr, code := runSupport(t, globals{server: srv.URL, token: "op-tok"}, "remove", "hex")
	if code != exitOK {
		t.Fatalf("a skipped DNS leg is not residue — want exit 0, got %d\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "dns: SKIPPED — the control-plane row carries no url") {
		t.Fatalf("the skip must be said explicitly\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "NOT verified clean") {
		t.Fatalf("a skipped leg must never read as clean\nstdout:\n%s", stdout)
	}
	if !strings.Contains(stdout, "dns SKIPPED") || strings.Contains(stdout, "dns verified by value") {
		t.Fatalf("the success line must carry the skip, not a clean verdict\nstdout:\n%s", stdout)
	}
}

// TestSupportDNSForSatisfiesRecordLister observes the CALL SITE, not a rebuild
// of it. supportDNSFor is declared to return cloud.DNSProvider — an INTERFACE —
// so it is the one production wiring whose RecordLister satisfaction no
// compile-time `var _ RecordLister` in package cloud can see: swap the body for
// any other DNSProvider, or wrap it in a decorator that forwards only
// DNSProvider, and the build stays green while deprovisionDNS (warmpool.go)
// silently degrades from the by-VALUE A-record sweep to the by-NAME delete,
// leaving custom-domain records pointing at an IP Hetzner hands to someone else.
// cch-w57-s5's in-package table test cannot reach this seam (internal/cli/cloud
// cannot import internal/cli); this arm closes it from the other side.
func TestSupportDNSForSatisfiesRecordLister(t *testing.T) {
	for _, tok := range []string{"", "token-from---dns-token"} {
		p := supportDNSFor(tok)
		if p == nil {
			t.Fatalf("supportDNSFor(%q) returned nil — the remove-side sweep has no provider", tok)
		}
		if _, ok := p.(cloud.RecordLister); !ok {
			t.Fatalf("supportDNSFor(%q) builds %T, which does NOT satisfy cloud.RecordLister: "+
				"deprovisionDNS would take the by-name degrade arm for the whole fleet", tok, p)
		}
	}
}
