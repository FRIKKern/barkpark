package cli

// doctor_onboarding_test.go proves the D3 client-readiness receipt end-to-end
// WITHOUT a live deployment: the four resolver seams (PATH lookup, latest-release,
// manifest load, fleet list) are swapped to fakes, and the read-only tool-call
// proof runs the REAL execManifestCommand path against one httptest server so we
// can assert the call actually left the process (not a stub). Three obligations:
// (1) the receipt carries every field in shape; (2) no bearer token ever appears
// in the output; (3) the task_ready proof genuinely round-trips and surfaces its
// result. A fourth test pins the hardcoded MCP catalog to the LIVE registration
// so the two can never drift.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// swapVar sets *p to v and returns a restore func for defer — the seam-swap
// idiom the receipt's package vars are built for.
func swapVar[T any](p *T, v T) func() {
	old := *p
	*p = v
	return func() { *p = old }
}

// The two secrets that must NEVER surface in the receipt.
const (
	onbCloudSecret   = "cloud-bearer-MUST-NOT-LEAK"
	onbContentSecret = "content-bearer-MUST-NOT-LEAK"
)

// onbTestFixture stands up the httptest server (serving task_ready), seeds a
// Cloud session in the temp config, and swaps all four seams to fakes. It returns
// the server, the ctx pointed at it, and a pointer the caller reads to confirm
// the task_ready endpoint was actually hit.
func onbTestFixture(t *testing.T) (*httptest.Server, manifest.Context, *bool) {
	t.Helper()
	withTempConfigHome(t)

	readyHit := new(bool)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/tasks/ready" {
			*readyHit = true
			w.WriteHeader(http.StatusOK)
			io.WriteString(w, `{"tasks":[{"id":"a"},{"id":"b"}]}`)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(ts.Close)

	// Seed a Cloud session so (c) reports it — with a distinctive secret token
	// the no-bearer assertion hunts for.
	cfg := &Config{CloudURL: ts.URL, CloudToken: onbCloudSecret, CloudTeam: "gyldendal"}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}

	t.Cleanup(swapVar(&onboardingLookBP, func() (string, error) { return "/usr/local/bin/bp", nil }))
	t.Cleanup(swapVar(&onboardingLatestRelease, func() (string, error) { return "1.15.0", nil }))
	t.Cleanup(swapVar(&onboardingLoadManifest, func(g globals, ctx manifest.Context) (*manifest.Manifest, error) { return m, nil }))
	t.Cleanup(swapVar(&onboardingListFleet, func(c *Config) ([]cloudclient.Barkpark, error) {
		return []cloudclient.Barkpark{{
			ID:     "inst-123",
			Name:   "gyldendal-2",
			URL:    ts.URL,
			Host:   "gyldendal.example.com",
			Team:   &cloudclient.Team{Name: "Gyldendal", ID: "team-1"},
			TeamID: "team-1",
		}}, nil
	}))

	// Pin an installed version older than "latest" so (b) exercises the compare.
	old := cliVersion
	cliVersion = "1.14.0"
	t.Cleanup(func() { cliVersion = old })

	ctx := manifest.Context{
		Server:    ts.URL,
		Token:     onbContentSecret,
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
	}
	return ts, ctx, readyHit
}

// TestOnboardingReceiptShape: every field is populated and correct, the read-only
// proof genuinely hit the server, and the core verdict is READY.
func TestOnboardingReceiptShape(t *testing.T) {
	_, ctx, readyHit := onbTestFixture(t)

	r := buildOnboardingReceipt(globals{yes: true}, ctx, tokenProvenance{})

	// (a) PATH
	if !r.Path.Resolved || r.Path.Path != "/usr/local/bin/bp" {
		t.Fatalf("path check = %+v, want resolved /usr/local/bin/bp", r.Path)
	}
	// (b) CLI freshness — installed behind latest
	if r.CLI.Installed != "1.14.0" || r.CLI.Latest != "1.15.0" || r.CLI.Status != onbCLIBehind {
		t.Fatalf("cli check = %+v, want installed 1.14.0 latest 1.15.0 status behind", r.CLI)
	}
	if r.CLI.UpToDate == nil || *r.CLI.UpToDate {
		t.Fatalf("cli check up_to_date = %v, want a taken reading of false", r.CLI.UpToDate)
	}
	// (c) Cloud session — present, url + team, no token field on the struct
	if !r.CloudSession.Present || r.CloudSession.Team != "gyldendal" {
		t.Fatalf("cloud session = %+v, want present team gyldendal", r.CloudSession)
	}
	// (d) Instance identity from the fleet
	if r.Instance == nil {
		t.Fatalf("instance is nil, want the fleet-resolved target")
	}
	if r.Instance.ID != "inst-123" || r.Instance.Team != "Gyldendal" || r.Instance.Source != "cloud-fleet" {
		t.Fatalf("instance = %+v, want id inst-123 team Gyldendal source cloud-fleet", r.Instance)
	}
	// (e) Auth
	if !r.Auth.Reachable || r.Auth.Tier != "admin" {
		t.Fatalf("auth = %+v, want reachable admin", r.Auth)
	}
	// (f) MCP catalog
	if r.MCP.Count != 8 || len(r.MCP.Tools) != 8 {
		t.Fatalf("mcp catalog count = %d tools %v, want 8", r.MCP.Count, r.MCP.Tools)
	}
	// (g) Read-only tool-call proof — real call, real result
	if !r.ToolCall.OK || r.ToolCall.Status != http.StatusOK {
		t.Fatalf("tool call = %+v, want ok 200", r.ToolCall)
	}
	if !strings.Contains(r.ToolCall.Summary, "2 ready") {
		t.Fatalf("tool call summary = %q, want it to surface 2 ready tasks", r.ToolCall.Summary)
	}
	if !*readyHit {
		t.Fatalf("the task_ready endpoint was never hit — the proof is a stub, not a real call")
	}
	// (h) Reload instruction present
	if r.Reload == "" {
		t.Fatalf("reload instruction is empty")
	}
	// Core verdict
	if !r.OK {
		t.Fatalf("receipt OK = false, want READY: %+v", r)
	}
}

// TestOnboardingReceiptJSONNoBearer: the -o json render carries every field and
// NEITHER the cloud nor the content bearer appears anywhere in the output.
func TestOnboardingReceiptJSONNoBearer(t *testing.T) {
	_, ctx, _ := onbTestFixture(t)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runDoctorOnboarding(out, globals{yes: true}, ctx, []string{"--onboarding"}, tokenProvenance{})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (ready receipt)\n%s", code, stdout)
	}

	// No bearer, ever.
	if strings.Contains(stdout, onbCloudSecret) {
		t.Fatalf("cloud bearer leaked into the receipt:\n%s", stdout)
	}
	if strings.Contains(stdout, onbContentSecret) {
		t.Fatalf("content bearer leaked into the receipt:\n%s", stdout)
	}

	// Shape: all top-level fields present and typed.
	var env struct {
		OK   bool `json:"ok"`
		Path struct {
			Resolved bool   `json:"resolved"`
			Path     string `json:"path"`
		} `json:"path"`
		CLI struct {
			Installed string `json:"installed"`
			Latest    string `json:"latest"`
		} `json:"cli"`
		CloudSession struct {
			Present bool   `json:"present"`
			Team    string `json:"team"`
		} `json:"cloud_session"`
		Instance *struct {
			ID   string `json:"id"`
			Team string `json:"team"`
		} `json:"instance"`
		Auth struct {
			Reachable bool   `json:"reachable"`
			Tier      string `json:"tier"`
		} `json:"auth"`
		MCP struct {
			Count int      `json:"count"`
			Tools []string `json:"tools"`
		} `json:"mcp"`
		ToolCall struct {
			Tool   string `json:"tool"`
			OK     bool   `json:"ok"`
			Status int    `json:"status"`
		} `json:"tool_call"`
		Reload string `json:"reload_instruction"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal receipt: %v\n%s", err, stdout)
	}
	if !env.OK {
		t.Fatalf("ok=false in json:\n%s", stdout)
	}
	if !env.Path.Resolved || env.CLI.Installed == "" || env.CLI.Latest == "" {
		t.Fatalf("path/cli fields missing: %+v", env)
	}
	if !env.CloudSession.Present || env.Instance == nil || env.Instance.ID != "inst-123" {
		t.Fatalf("cloud/instance fields missing: %+v", env)
	}
	if !env.Auth.Reachable || env.Auth.Tier != "admin" {
		t.Fatalf("auth fields missing: %+v", env.Auth)
	}
	if env.MCP.Count != 8 || env.ToolCall.Tool != "task_ready" || !env.ToolCall.OK {
		t.Fatalf("mcp/tool_call fields wrong: mcp=%+v tool_call=%+v", env.MCP, env.ToolCall)
	}
	if env.Reload == "" {
		t.Fatalf("reload_instruction missing")
	}
}

// TestOnboardingToolCallProofFailureSurfaced: when task_ready returns non-2xx,
// the proof reports it honestly (ok=false, the server error code surfaced) and
// the core verdict is NOT READY — the proof is not a rubber stamp.
func TestOnboardingToolCallProofFailureSurfaced(t *testing.T) {
	withTempConfigHome(t)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		io.WriteString(w, `{"error":{"code":"unauthorized"}}`)
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	t.Cleanup(swapVar(&onboardingLookBP, func() (string, error) { return "/usr/local/bin/bp", nil }))
	t.Cleanup(swapVar(&onboardingLatestRelease, func() (string, error) { return "1.15.0", nil }))
	t.Cleanup(swapVar(&onboardingLoadManifest, func(g globals, ctx manifest.Context) (*manifest.Manifest, error) { return m, nil }))
	t.Cleanup(swapVar(&onboardingListFleet, func(c *Config) ([]cloudclient.Barkpark, error) { return nil, nil }))

	ctx := manifest.Context{Server: ts.URL, Workspace: "default", Project: "default", Dataset: "production"}
	r := buildOnboardingReceipt(globals{yes: true}, ctx, tokenProvenance{})

	if r.ToolCall.OK {
		t.Fatalf("tool call OK on a 403, want failure: %+v", r.ToolCall)
	}
	if !strings.Contains(r.ToolCall.Summary, "unauthorized") {
		t.Fatalf("tool call summary = %q, want the server error code surfaced", r.ToolCall.Summary)
	}
	if r.OK {
		t.Fatalf("receipt OK despite a failed tool call, want NOT READY")
	}
}

// TestOnboardingMCPCatalogMatchesRegistration pins the hardcoded receipt catalog
// to the LIVE registerTaskTools registration — a real in-memory MCP server —
// so a tool added/removed there without updating the receipt fails CI.
func TestOnboardingMCPCatalogMatchesRegistration(t *testing.T) {
	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	srv := mcp.NewServer(&mcp.Implementation{Name: "barkpark-tasks", Version: "test"}, nil)
	if err := registerTaskTools(srv, globals{yes: true}, manifest.Context{Server: "http://x", Token: "t"}, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	lt, err := cs.ListTools(bg, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	live := make([]string, 0, len(lt.Tools))
	for _, tool := range lt.Tools {
		live = append(live, tool.Name)
	}
	sort.Strings(live)

	want := append([]string(nil), mcpTaskToolNames...)
	sort.Strings(want)

	if strings.Join(live, ",") != strings.Join(want, ",") {
		t.Fatalf("receipt catalog %v drifted from the live registration %v", want, live)
	}
	if len(mcpTaskToolNames) != 8 {
		t.Fatalf("catalog has %d tools, want the curated 8", len(mcpTaskToolNames))
	}
}

// TestWhoamiCarriesOnboardingReceiptSpine proves the D10 reconciliation:
// `bp whoami -o json` carries the onboarding receipt SPINE additively — instance
// identity (local, network-free), the MCP tool catalog (version + the curated 8
// names), the read-only tool-call proof, and the client-reload instruction — over
// a reachable target, and it STILL never prints a bearer (neither the Cloud
// session token nor the content token leaks). `bp doctor --onboarding` composes
// over this exact spine using the same helpers, so a green spine here is proof the
// two receipts cannot fork.
func TestWhoamiCarriesOnboardingReceiptSpine(t *testing.T) {
	withTempConfigHome(t)

	readyHit := new(bool)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/tasks/ready" {
			*readyHit = true
			w.WriteHeader(http.StatusOK)
			io.WriteString(w, `{"tasks":[{"id":"a"},{"id":"b"},{"id":"c"}]}`)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(ts.Close)

	// A reachable manifest via the file override — no live /v1/capabilities.
	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(mcpTestManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)

	// Seed a Cloud session whose token must NOT leak into the spine.
	if err := SaveConfig(&Config{CloudURL: ts.URL, CloudToken: onbCloudSecret, CloudTeam: "gyldendal"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	ctx := manifest.Context{Server: ts.URL, Token: onbContentSecret, Workspace: "default", Project: "default", Dataset: "production"}

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runWhoami(out, globals{yes: true}, ctx, tokenProvenance{})
	})
	if code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, stdout)
	}

	// No bearer, ever — neither the Cloud session token nor the content token.
	if strings.Contains(stdout, onbCloudSecret) || strings.Contains(stdout, onbContentSecret) {
		t.Fatalf("whoami spine leaked a bearer token:\n%s", stdout)
	}

	var env struct {
		Instance *struct {
			URL    string `json:"url"`
			Team   string `json:"team"`
			Source string `json:"source"`
		} `json:"instance"`
		MCP struct {
			Version string   `json:"version"`
			Count   int      `json:"count"`
			Tools   []string `json:"tools"`
		} `json:"mcp"`
		ToolCall struct {
			Tool   string `json:"tool"`
			OK     bool   `json:"ok"`
			Status int    `json:"status"`
		} `json:"tool_call"`
		Reload string `json:"reload_instruction"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal whoami spine: %v\n%s", err, stdout)
	}
	// Instance identity — local, network-free (no cross-team fleet fetch here).
	if env.Instance == nil || env.Instance.Source != "local" || env.Instance.Team != "gyldendal" {
		t.Fatalf("instance spine = %+v, want local source + team gyldendal", env.Instance)
	}
	// MCP catalog — version (=cliVersion) present + the curated 8 names.
	if env.MCP.Version == "" || env.MCP.Count != 8 || len(env.MCP.Tools) != 8 {
		t.Fatalf("mcp spine = %+v, want a version + the 8 tools", env.MCP)
	}
	// Read-only tool-call proof — a REAL task_ready call round-tripped.
	if env.ToolCall.Tool != "task_ready" || !env.ToolCall.OK || env.ToolCall.Status != http.StatusOK {
		t.Fatalf("tool_call spine = %+v, want a green task_ready proof", env.ToolCall)
	}
	if !*readyHit {
		t.Fatalf("task_ready was never hit — the whoami spine proof is a stub, not a real call")
	}
	if env.Reload == "" {
		t.Fatalf("reload_instruction missing from the whoami spine")
	}
}

// TestWhoamiInstanceReadsServerEntryIdentity is the D9 ACTIVATION proof for the
// whoami receipt: once the connect path has stamped ServerEntry.InstanceID +
// Aliases + Team (slice 1), whoami's local instance block must READ them — not
// leave them empty. A prior wave shipped the plumbing inert; this pins the wire
// live so the receipt actually carries the instance ID and host aliases the wish
// names, sourced network-free from the saved config.
func TestWhoamiInstanceReadsServerEntryIdentity(t *testing.T) {
	const canonical = "https://gyldendal.barkpark.cloud"
	const custom = "https://cms.gyldendal.no"
	cfg := &Config{
		Server:    custom,
		CloudTeam: "some-active-team-uuid",
		KnownServers: []ServerEntry{
			{Server: custom, InstanceID: "inst-gyld", Aliases: []string{canonical}, Team: "Gyldendal"},
		},
	}
	inst := localInstance(cfg, manifest.Context{Server: custom})
	if inst == nil {
		t.Fatal("localInstance returned nil for an active target")
	}
	if inst.ID != "inst-gyld" {
		t.Fatalf("instance ID = %q, want the ServerEntry.InstanceID (inert plumbing not activated)", inst.ID)
	}
	if len(inst.Aliases) != 1 || inst.Aliases[0] != canonical {
		t.Fatalf("instance aliases = %v, want the ServerEntry.Aliases", inst.Aliases)
	}
	// Team prefers the entry's owning-team identity over the active-session team.
	if inst.Team != "Gyldendal" {
		t.Fatalf("instance team = %q, want the entry's owning team Gyldendal", inst.Team)
	}
	if inst.URL != custom {
		t.Fatalf("instance URL = %q, want %q", inst.URL, custom)
	}
}

// TestOnboardingInstancePrefersLocalOffline is the D15 offline win: with NO Cloud
// token (the genuinely-offline / self-hosted condition), a saved ServerEntry
// carrying the stamped InstanceID resolves the identity from local config ALONE
// (Source "local") and NEVER touches the network — neither the identity fetch nor
// the D39 alias-shadow advisory (which is token-gated). The fail-if-called fake is
// the tripwire proving no round-trip happens. (The token-present path — identity
// still local, advisory compare fires fail-open — is proven by the alias-shadow
// tests below.)
func TestOnboardingInstancePrefersLocalOffline(t *testing.T) {
	const server = "https://gyldendal.barkpark.cloud"
	const alias = "https://cms.gyldendal.no"

	cfg := &Config{
		Server:    server,
		CloudTeam: "active-team",
		// No CloudToken → HasCloudToken() is false: the offline path never touches
		// the network, and the token-gated advisory compare stays dormant.
		KnownServers: []ServerEntry{
			{Server: server, InstanceID: "inst-gyld", Aliases: []string{alias}, Team: "Gyldendal"},
		},
	}

	fleetCalls := 0
	t.Cleanup(swapVar(&onboardingListFleet, func(c *Config) ([]cloudclient.Barkpark, error) {
		fleetCalls++
		t.Errorf("onboardingListFleet was called — local-first must skip the fleet when a stamped InstanceID exists")
		return nil, errors.New("fleet must not be reached on the offline path")
	}))

	inst := onboardingInstance(cfg, manifest.Context{Server: server})
	if inst == nil {
		t.Fatal("onboardingInstance returned nil for an active target carrying a stamped identity")
	}
	if inst.Source != "local" {
		t.Fatalf("instance source = %q, want \"local\" (resolved without a fleet round-trip)", inst.Source)
	}
	if inst.ID != "inst-gyld" {
		t.Fatalf("instance ID = %q, want the ServerEntry.InstanceID inst-gyld", inst.ID)
	}
	if len(inst.Aliases) != 1 || inst.Aliases[0] != alias {
		t.Fatalf("instance aliases = %v, want the ServerEntry.Aliases [%s]", inst.Aliases, alias)
	}
	if inst.Team != "Gyldendal" {
		t.Fatalf("instance team = %q, want the entry's owning team Gyldendal", inst.Team)
	}
	if inst.AliasShadow != "" {
		t.Fatalf("alias-shadow advisory = %q, want empty on the no-token offline path", inst.AliasShadow)
	}
	if fleetCalls != 0 {
		t.Fatalf("fleet seam invoked %d time(s), want 0 — the offline path must not touch the network", fleetCalls)
	}
}

// TestOnboardingAliasShadowAdvisoryFires is the D39 compare-only reconcile: a
// local entry stamped with an InstanceID whose ONLY known host is the OLD one,
// against a fleet that has renamed that same instance's canonical target (matched
// by Barkpark.ID equality, never URL). The receipt keeps the LOCAL identity
// (Source "local") but adds an advisory naming the new canonical target and the
// `bp connect <newURL>` remedy — and mutates nothing.
func TestOnboardingAliasShadowAdvisoryFires(t *testing.T) {
	const oldHost = "https://old.gyldendal.barkpark.cloud"
	const newHost = "https://new.gyldendal.barkpark.cloud"

	cfg := &Config{
		Server:     oldHost,
		CloudToken: onbCloudSecret, // HasCloudToken() → the compare is armed
		KnownServers: []ServerEntry{
			{Server: oldHost, InstanceID: "inst-gyld", Team: "Gyldendal"},
		},
	}
	t.Cleanup(swapVar(&onboardingListFleet, func(c *Config) ([]cloudclient.Barkpark, error) {
		return []cloudclient.Barkpark{{
			ID:   "inst-gyld", // SAME InstanceID — matched by ID equality, not URL
			Name: "gyldendal",
			URL:  newHost, // the renamed canonical target
			Host: "new.gyldendal.barkpark.cloud",
		}}, nil
	}))

	inst := onboardingInstance(cfg, manifest.Context{Server: oldHost})
	if inst == nil {
		t.Fatal("onboardingInstance returned nil for an active target carrying a stamped identity")
	}
	if inst.Source != "local" {
		t.Fatalf("instance source = %q, want \"local\" — the advisory must not override local identity", inst.Source)
	}
	if inst.ID != "inst-gyld" {
		t.Fatalf("instance ID = %q, want the stamped inst-gyld", inst.ID)
	}
	if inst.AliasShadow == "" {
		t.Fatal("expected an alias-shadow advisory when the fleet renamed the canonical target away from local aliases")
	}
	if !strings.Contains(inst.AliasShadow, newHost) {
		t.Fatalf("advisory %q must name the new canonical target %q", inst.AliasShadow, newHost)
	}
	if !strings.Contains(inst.AliasShadow, "bp connect "+newHost) {
		t.Fatalf("advisory %q must name the remedy `bp connect %s`", inst.AliasShadow, newHost)
	}
	// The advisory is compare-only: local config is untouched (no new alias folded
	// in). Re-reading the saved entry proves no mutation happened.
	if got := cfg.KnownServers[0].Aliases; len(got) != 0 {
		t.Fatalf("KnownServers[0].Aliases = %v, want empty — the advisory must NOT mutate config", got)
	}
}

// TestOnboardingAliasShadowFailOpen proves the fail-open contract across all three
// silent conditions — no Cloud token, a fleet error, and no fleet row matching the
// InstanceID — plus the no-shadow case where the fleet's canonical target is
// already a known local alias. In every case the identity resolves local-first and
// NO advisory appears (the receipt stays byte-identical to the baseline).
func TestOnboardingAliasShadowFailOpen(t *testing.T) {
	const host = "https://gyldendal.barkpark.cloud"
	base := func() *Config {
		return &Config{
			Server: host,
			KnownServers: []ServerEntry{
				{Server: host, InstanceID: "inst-gyld", Team: "Gyldendal"},
			},
		}
	}

	cases := []struct {
		name  string
		cfg   func() *Config
		fleet func(*Config) ([]cloudclient.Barkpark, error)
	}{
		{
			name: "no cloud token",
			cfg:  base, // HasCloudToken() false
			fleet: func(*Config) ([]cloudclient.Barkpark, error) {
				t.Errorf("fleet must not be fetched without a Cloud token")
				return nil, nil
			},
		},
		{
			name: "fleet error",
			cfg: func() *Config {
				c := base()
				c.CloudToken = onbCloudSecret
				return c
			},
			fleet: func(*Config) ([]cloudclient.Barkpark, error) {
				return nil, errors.New("fleet unreachable")
			},
		},
		{
			name: "no matching row",
			cfg: func() *Config {
				c := base()
				c.CloudToken = onbCloudSecret
				return c
			},
			fleet: func(*Config) ([]cloudclient.Barkpark, error) {
				return []cloudclient.Barkpark{{ID: "inst-other", URL: "https://other.barkpark.cloud"}}, nil
			},
		},
		{
			name: "canonical target already a known alias",
			cfg: func() *Config {
				c := base()
				c.CloudToken = onbCloudSecret
				return c
			},
			fleet: func(*Config) ([]cloudclient.Barkpark, error) {
				// Same ID, and its canonical target IS the active local URL → no shadow.
				return []cloudclient.Barkpark{{ID: "inst-gyld", URL: host, Host: "gyldendal.barkpark.cloud"}}, nil
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Cleanup(swapVar(&onboardingListFleet, tc.fleet))
			inst := onboardingInstance(tc.cfg(), manifest.Context{Server: host})
			if inst == nil {
				t.Fatal("onboardingInstance returned nil for an active target")
			}
			if inst.Source != "local" || inst.ID != "inst-gyld" {
				t.Fatalf("identity = %+v, want local inst-gyld", inst)
			}
			if inst.AliasShadow != "" {
				t.Fatalf("alias-shadow advisory = %q, want empty (fail-open)", inst.AliasShadow)
			}
		})
	}
}

// TestWhoamiInstanceTeamFallsBackToCloudTeam proves the fallback half: an entry
// with no stamped owning team (a self-hosted or pre-activation connect) still
// names a team via the active Cloud session (cfg.CloudTeam), so the receipt is
// never blank when a team context exists.
func TestWhoamiInstanceTeamFallsBackToCloudTeam(t *testing.T) {
	const url = "https://api.example.com"
	cfg := &Config{
		Server:    url,
		CloudTeam: "active-team",
		KnownServers: []ServerEntry{
			{Server: url, InstanceID: "inst-x"}, // no Team stamped
		},
	}
	inst := localInstance(cfg, manifest.Context{Server: url})
	if inst == nil {
		t.Fatal("localInstance returned nil for an active target")
	}
	if inst.Team != "active-team" {
		t.Fatalf("instance team = %q, want the cfg.CloudTeam fallback", inst.Team)
	}
}

// ---------------------------------------------------------------------------
// The CLI-freshness leg on the whoami spine (charter D28): cache-mediated and
// NETWORK-FREE. whoami reports the SAME tri-state the doctor renders, but reads
// ONLY the on-disk release cache the doctor refreshes — it must never make the
// uncached 10s HTTP GET on its always-run hot path.
// ---------------------------------------------------------------------------

// TestWhoamiCLIFreshnessIsNetworkFree is the load-bearing proof: with a COLD
// cache and the network release resolver rigged to FAIL LOUDLY if invoked (plus
// an unroutable release base), `bp whoami -o json` still returns sub-second,
// carries the additive `cli` leg as an honest "unreported" pointing at
// `bp doctor`, and leaks no bearer. A whoami that paid the 10s GET would blow the
// deadline and trip the tripwire.
func TestWhoamiCLIFreshnessIsNetworkFree(t *testing.T) {
	withTempConfigHome(t)       // cold cache: nothing written yet
	withCLIVersion(t, "1.14.0") // non-dev, so only the cache could yield a reading

	// Tripwire: whoami must never call the network release resolver.
	t.Cleanup(swapVar(&onboardingLatestRelease, func() (string, error) {
		t.Error("whoami invoked the network release resolver — the freshness leg must read the cache only")
		return "", errors.New("network resolver must not be reached on the whoami path")
	}))
	// Belt-and-suspenders: point the release feed at an unroutable base so any
	// stray resolve would hang on the 10s timeout, not answer instantly.
	t.Setenv("BARKPARK_CLI_RELEASE_BASE", "http://127.0.0.1:1/")

	// Seed a Cloud session whose token must not leak.
	if err := SaveConfig(&Config{CloudURL: "http://127.0.0.1:1", CloudToken: onbCloudSecret, CloudTeam: "gyldendal"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	// An unreachable content target (connection refused is instant) so whoami's
	// tool-call proof is skipped and the run stays fast and focused.
	ctx := manifest.Context{Server: "http://127.0.0.1:1", Token: onbContentSecret, Workspace: "default", Project: "default", Dataset: "production"}

	start := time.Now()
	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runWhoami(out, globals{yes: true}, ctx, tokenProvenance{})
	})
	elapsed := time.Since(start)
	if code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, stdout)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("whoami took %s — the freshness leg must not pay a network round-trip (sub-second expected)", elapsed)
	}
	if strings.Contains(stdout, onbCloudSecret) || strings.Contains(stdout, onbContentSecret) {
		t.Fatalf("whoami spine leaked a bearer token:\n%s", stdout)
	}

	var env struct {
		CLI struct {
			Installed string `json:"installed"`
			Latest    string `json:"latest"`
			Status    string `json:"status"`
			UpToDate  *bool  `json:"up_to_date"`
			Detail    string `json:"detail"`
		} `json:"cli"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal whoami spine: %v\n%s", err, stdout)
	}
	if env.CLI.Status != onbCLIUnreported {
		t.Fatalf("cold-cache cli leg status = %q, want %q", env.CLI.Status, onbCLIUnreported)
	}
	if env.CLI.UpToDate != nil {
		t.Fatalf("cold-cache cli leg up_to_date = %v, want null (no reading)", *env.CLI.UpToDate)
	}
	if !strings.Contains(env.CLI.Detail, "bp doctor") {
		t.Fatalf("cold-cache cli leg detail = %q, want it to name the `bp doctor` refresh remedy", env.CLI.Detail)
	}
}

// TestWhoamiCLIFreshnessColdCacheUnreported: with no cache and a tripwire
// resolver, the leg reports unreported without touching the network. Direct on
// the unit so the read-only contract is pinned without the whoami plumbing.
func TestWhoamiCLIFreshnessColdCacheUnreported(t *testing.T) {
	withTempConfigHome(t)
	withCLIVersion(t, "1.14.0")
	t.Cleanup(swapVar(&onboardingLatestRelease, func() (string, error) {
		t.Error("whoamiCLIFreshness invoked the network release resolver — it must read the cache only")
		return "", errors.New("must not be reached")
	}))

	c := whoamiCLIFreshness()
	if c.Status != onbCLIUnreported || c.UpToDate != nil {
		t.Fatalf("cold cache leg = %+v, want unreported + nil up_to_date", c)
	}
	if !strings.Contains(c.Detail, "bp doctor") {
		t.Fatalf("cold cache detail = %q, want the `bp doctor` remedy", c.Detail)
	}
}

// TestWhoamiCLIFreshnessReadsFreshCache: a fresh cache yields a real reading —
// behind when installed < cached latest, up-to-date when installed >= it.
func TestWhoamiCLIFreshnessReadsFreshCache(t *testing.T) {
	withTempConfigHome(t)

	// Behind: installed 1.14.0, cached latest 1.15.0.
	withCLIVersion(t, "1.14.0")
	if err := writeReleaseCache("1.15.0"); err != nil {
		t.Fatalf("writeReleaseCache: %v", err)
	}
	c := whoamiCLIFreshness()
	if c.Status != onbCLIBehind || c.Latest != "1.15.0" {
		t.Fatalf("behind leg = %+v, want status behind latest 1.15.0", c)
	}
	if c.UpToDate == nil || *c.UpToDate {
		t.Fatalf("behind leg up_to_date = %v, want a taken reading of false", c.UpToDate)
	}

	// Up-to-date: installed now equals the cached latest.
	withCLIVersion(t, "1.15.0")
	c = whoamiCLIFreshness()
	if c.Status != onbCLIUpToDate {
		t.Fatalf("up-to-date leg = %+v, want status up-to-date", c)
	}
	if c.UpToDate == nil || !*c.UpToDate {
		t.Fatalf("up-to-date leg up_to_date = %v, want a taken reading of true", c.UpToDate)
	}
}

// TestWhoamiCLIFreshnessStaleCacheUnreported: a cache older than the TTL is
// treated as absent — an honest unreported, never a day-stale verdict.
func TestWhoamiCLIFreshnessStaleCacheUnreported(t *testing.T) {
	withTempConfigHome(t)
	withCLIVersion(t, "1.14.0")

	path, err := releaseCachePath()
	if err != nil {
		t.Fatalf("releaseCachePath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	stale := releaseCache{Latest: "1.15.0", CheckedAt: time.Now().Add(-releaseCacheTTL - time.Hour)}
	b, _ := json.Marshal(stale)
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatalf("write stale cache: %v", err)
	}

	c := whoamiCLIFreshness()
	if c.Status != onbCLIUnreported || c.UpToDate != nil {
		t.Fatalf("stale cache leg = %+v, want unreported (a stale reading must not become a verdict)", c)
	}
	if !strings.Contains(c.Detail, "bp doctor") {
		t.Fatalf("stale cache detail = %q, want the `bp doctor` remedy", c.Detail)
	}
}

// TestWhoamiCLIFreshnessDevBuildUnreported: a dev build cannot be compared, so
// the leg reports unreported and names the dev remedy — regardless of any cache.
func TestWhoamiCLIFreshnessDevBuildUnreported(t *testing.T) {
	withTempConfigHome(t)
	withCLIVersion(t, "dev")
	if err := writeReleaseCache("1.15.0"); err != nil { // even WITH a fresh cache
		t.Fatalf("writeReleaseCache: %v", err)
	}
	c := whoamiCLIFreshness()
	if c.Status != onbCLIUnreported || c.UpToDate != nil {
		t.Fatalf("dev build leg = %+v, want unreported", c)
	}
	if !strings.Contains(c.Detail, "make cli-install") {
		t.Fatalf("dev build detail = %q, want the dev remedy `git pull && make cli-install`", c.Detail)
	}
}

// TestDoctorRefreshesCacheForWhoami is the composition proof: the network-bearing
// doctor resolves the latest release and writes the cache, and a subsequent
// network-free whoami reads THAT cache to render the same verdict — the two
// surfaces share one truth without whoami ever leaving the process.
func TestDoctorRefreshesCacheForWhoami(t *testing.T) {
	_, ctx, _ := onbTestFixture(t) // swaps onboardingLatestRelease → "1.15.0", cliVersion 1.14.0

	// Cold to start.
	if _, fresh := readReleaseCache(); fresh {
		t.Fatalf("expected a cold cache before the doctor runs")
	}

	// The doctor's freshness leg pays the network cost and refreshes the cache.
	if leg := onboardingCLIFreshness(); leg.Status != onbCLIBehind {
		t.Fatalf("doctor cli leg = %+v, want behind (1.14.0 < 1.15.0)", leg)
	}
	rc, fresh := readReleaseCache()
	if !fresh || rc.Latest != "1.15.0" {
		t.Fatalf("cache after doctor = %+v fresh=%v, want fresh latest 1.15.0", rc, fresh)
	}

	// whoami now renders the same verdict from the cache alone. Rig the resolver
	// as a tripwire to prove whoami does not re-resolve.
	t.Cleanup(swapVar(&onboardingLatestRelease, func() (string, error) {
		t.Error("whoami re-resolved the release over the network — it must read the doctor-refreshed cache")
		return "", errors.New("must not be reached")
	}))
	c := whoamiCLIFreshness()
	if c.Status != onbCLIBehind || c.Latest != "1.15.0" {
		t.Fatalf("whoami leg after doctor refresh = %+v, want behind latest 1.15.0", c)
	}
	_ = ctx
}

// ---------------------------------------------------------------------------
// The dev-build tri-state: this epic's doctrine applied to the CLI's own
// instrument. A dev build cannot be compared against the cli-v* channel, so the
// receipt must report UNREPORTED — never a green it did not earn, and never a
// "behind" false alarm either. These tests assert on the RENDERED bytes (JSON
// and human), so they compile against the pre-change tree too and FAIL on it.
// ---------------------------------------------------------------------------

// TestOnboardingDevBuildFreshnessIsUnreported: the JSON leg for a dev build is
// status "unreported" with a NULL up_to_date. Fail-before on origin/main, which
// emits "up_to_date":true.
func TestOnboardingDevBuildFreshnessIsUnreported(t *testing.T) {
	withCLIVersion(t, "dev")

	b, err := json.Marshal(onboardingCLIFreshness())
	if err != nil {
		t.Fatalf("marshal cli leg: %v", err)
	}
	got := string(b)

	if strings.Contains(got, `"up_to_date":true`) {
		t.Fatalf("a dev build claimed up_to_date:true — a green it cannot earn:\n%s", got)
	}
	if strings.Contains(got, `"up_to_date":false`) {
		t.Fatalf("a dev build claimed up_to_date:false — a false alarm, equally unearned:\n%s", got)
	}
	if !strings.Contains(got, `"up_to_date":null`) {
		t.Fatalf("a dev build must render up_to_date as null (no reading taken):\n%s", got)
	}
	if !strings.Contains(got, `"status":"unreported"`) {
		t.Fatalf("a dev build must carry status \"unreported\":\n%s", got)
	}
	// The detail names the ONE command that fixes it.
	if !strings.Contains(got, "make cli-install") {
		t.Fatalf("the dev-build detail must name the literal remedy `git pull && make cli-install`:\n%s", got)
	}
}

// TestOnboardingDevBuildHumanRenderSaysUnreported: the human receipt marks the
// CLI leg "?" (not ✓, not ✗), names the remedy, and — because the aggregate ok
// deliberately stays true for an unknown leg — the READY verdict itself carries
// the UNREPORTED caveat so nobody reads the green as verified freshness.
func TestOnboardingDevBuildHumanRenderSaysUnreported(t *testing.T) {
	_, ctx, _ := onbTestFixture(t)
	withCLIVersion(t, "dev")

	out, buf, _ := newTestWriter()
	out.output = "table" // the human render
	code := runDoctorOnboarding(out, globals{yes: true}, ctx, []string{"--onboarding"}, tokenProvenance{})
	stdout := buf.String()

	// DECIDED: an unknown leg is not a failure — ok stays true, exit stays 0.
	if code != exitOK {
		t.Fatalf("exit = %d, want 0: an unreported leg must not sink readiness\n%s", code, stdout)
	}
	if strings.Contains(stdout, "✓ CLI") {
		t.Fatalf("a dev build was marked ✓ CLI — a green it cannot earn:\n%s", stdout)
	}
	if strings.Contains(stdout, "✗ CLI") {
		t.Fatalf("a dev build was marked ✗ CLI — a false alarm:\n%s", stdout)
	}
	if !strings.Contains(stdout, "? CLI") {
		t.Fatalf("a dev build must render the CLI leg as \"?\" (no reading taken):\n%s", stdout)
	}
	if !strings.Contains(stdout, "make cli-install") {
		t.Fatalf("the human CLI line must name the literal remedy:\n%s", stdout)
	}
	if !strings.Contains(stdout, "READY") || !strings.Contains(stdout, "UNREPORTED: CLI freshness") {
		t.Fatalf("the READY verdict must name the unreported leg:\n%s", stdout)
	}
}

// TestDevBuildVerdictAgreesAcrossDoctorAndUpgrade: the SAME fact (this binary is
// a dev build) must not produce contradicting verdicts on two surfaces. Both
// `bp doctor --onboarding` and `bp upgrade --check` report "unreported" and both
// exit 0. Fail-before on origin/main, where upgrade --check exits 2 while the
// doctor reports up-to-date and exits 0.
func TestDevBuildVerdictAgreesAcrossDoctorAndUpgrade(t *testing.T) {
	withCLIVersion(t, "dev")

	var doctorLeg struct {
		Status   string `json:"status"`
		UpToDate *bool  `json:"up_to_date"`
	}
	b, _ := json.Marshal(onboardingCLIFreshness())
	if err := json.Unmarshal(b, &doctorLeg); err != nil {
		t.Fatalf("decode doctor cli leg: %v (%s)", err, b)
	}

	upgradeOut, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runUpgrade(out, globals{}, []string{"--check"})
	})
	if code != exitOK {
		t.Fatalf("bp upgrade --check on a dev build = %d, want 0 — the doctor calls the same fact a non-failure\n%s", code, upgradeOut)
	}
	var upgradeLeg struct {
		Status string `json:"status"`
		Behind *bool  `json:"behind"`
	}
	if err := json.Unmarshal([]byte(upgradeOut), &upgradeLeg); err != nil {
		t.Fatalf("decode upgrade --check json: %v (%s)", err, upgradeOut)
	}

	if doctorLeg.Status != upgradeLeg.Status {
		t.Fatalf("surfaces disagree: doctor status %q vs upgrade --check status %q", doctorLeg.Status, upgradeLeg.Status)
	}
	if doctorLeg.Status != "unreported" {
		t.Fatalf("shared status = %q, want \"unreported\"", doctorLeg.Status)
	}
	if doctorLeg.UpToDate != nil || upgradeLeg.Behind != nil {
		t.Fatalf("neither surface may claim a reading: up_to_date=%v behind=%v", doctorLeg.UpToDate, upgradeLeg.Behind)
	}
}
