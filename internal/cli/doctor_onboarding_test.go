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

	r := buildOnboardingReceipt(globals{yes: true}, ctx)

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
		return runDoctorOnboarding(out, globals{yes: true}, ctx, []string{"--onboarding"})
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
	r := buildOnboardingReceipt(globals{yes: true}, ctx)

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
		return runWhoami(out, globals{yes: true}, ctx)
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

// TestOnboardingInstancePrefersLocalOffline is the D15 offline win: when the
// active target's saved ServerEntry carries the stamped InstanceID (wave-2
// slice-1), onboardingInstance resolves the identity from local config ALONE
// (Source "local") and NEVER reaches the cross-team fleet — so the doctor receipt
// names the instance offline, round-trip-free. A Cloud token is deliberately
// present so the fleet branch WOULD fire if local-first were broken; the
// fail-if-called fake is the tripwire proving it does not.
func TestOnboardingInstancePrefersLocalOffline(t *testing.T) {
	const server = "https://gyldendal.barkpark.cloud"
	const alias = "https://cms.gyldendal.no"

	cfg := &Config{
		Server:     server,
		CloudToken: onbCloudSecret, // HasCloudToken() → true: the fleet branch is armed
		CloudTeam:  "active-team",
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
	if fleetCalls != 0 {
		t.Fatalf("fleet seam invoked %d time(s), want 0 — the offline path must not touch the network", fleetCalls)
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
	code := runDoctorOnboarding(out, globals{yes: true}, ctx, []string{"--onboarding"})
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
