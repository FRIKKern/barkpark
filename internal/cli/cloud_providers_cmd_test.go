package cli

// cloud_providers_cmd_test.go proves `bp cloud providers` renders the honest
// capability matrix from the committed fixture: the table lists every declared
// provider with its state / auth / capability marks, azure shows as a planned
// placeholder, and `-o json` emits the machine shape the Console twin consumes.
// No network call — auth is a local credential check (HCLOUD_TOKEN is set so
// hetzner's check is deterministic and never shells out to `hcloud`).

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// runProviders drives runCloudProviders with an in-memory writer.
func runProviders(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	// A present token makes HcloudProvider.HasAuth return true WITHOUT shelling
	// out (it returns early on HCLOUD_TOKEN), so the auth column is deterministic.
	t.Setenv("HCLOUD_TOKEN", "test-token")
	// Clear the Azure service-principal env so azure's auth state is a
	// deterministic "unknown" (—) regardless of the host/CI environment.
	t.Setenv("AZURE_TENANT_ID", "")
	t.Setenv("AZURE_CLIENT_ID", "")
	t.Setenv("AZURE_CLIENT_SECRET", "")
	t.Setenv("AZURE_SUBSCRIPTION_ID", "")
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudProviders(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// TestRunCloudProvidersTable: the DEFAULT matrix lists the shippable providers
// (hetzner + azure, both registered), HIDES the dev-tier fake, shows hetzner's
// true auth state, marks the honest capabilities from the fixture, and prints the
// dev-tier-hidden note.
func TestRunCloudProvidersTable(t *testing.T) {
	stdout, stderr, code := runProviders(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{"PROVIDER", "STATE", "AUTH", "CORE", "CATALOG", "LIFECYCLE", "PAUSE", "LABELS", "hetzner", "azure", "registered"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table missing %q:\n%s", want, stdout)
		}
	}
	// The dev-tier fake is hidden by default (a real operator never picks it).
	if strings.Contains(stdout, "fake") {
		t.Errorf("default matrix must HIDE the dev-tier fake (use --all):\n%s", stdout)
	}
	if !strings.Contains(stdout, "dev-tier provider(s) hidden") {
		t.Errorf("want the honest dev-tier-hidden note:\n%s", stdout)
	}
	// hetzner has a token → auth "yes".
	if !strings.Contains(stdout, "yes") {
		t.Errorf("hetzner should show an authenticated state with a token set:\n%s", stdout)
	}
}

// TestRunCloudProvidersAllRevealsFake: `--all` reveals the dev-tier fake and
// drops the hidden note.
func TestRunCloudProvidersAllRevealsFake(t *testing.T) {
	stdout, stderr, code := runProviders(t, "table", "--all")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "fake") {
		t.Errorf("--all must reveal the dev-tier fake:\n%s", stdout)
	}
	if strings.Contains(stdout, "dev-tier provider(s) hidden") {
		t.Errorf("with --all nothing is hidden, so the note must not print:\n%s", stdout)
	}
}

// providersJSONEnv is the decoded `-o json` shape the Console/SPA reads.
type providersJSONEnv struct {
	Providers []struct {
		Slug          string `json:"slug"`
		Registered    bool   `json:"registered"`
		Tier          string `json:"tier"`
		Authenticated *bool  `json:"authenticated"`
		Capabilities  struct {
			Core      bool `json:"core"`
			Catalog   bool `json:"catalog"`
			Lifecycle bool `json:"lifecycle"`
			Pause     bool `json:"pause"`
			Labels    bool `json:"labels"`
		} `json:"capabilities"`
	} `json:"providers"`
}

// TestRunCloudProvidersJSON: `-o json` (with --all so the fake is included) emits
// {providers:[…]} with the exact per-provider shape the Console/SPA reads, azure
// now REGISTERED with core+labels+pause, and the rows sorted by slug.
func TestRunCloudProvidersJSON(t *testing.T) {
	stdout, _, code := runProviders(t, "json", "--all")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env providersJSONEnv
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("decode json: %v\n%s", err, stdout)
	}
	byslug := map[string]int{}
	for i, p := range env.Providers {
		byslug[p.Slug] = i
	}
	// Sorted by slug: azure, fake, hetzner.
	if len(env.Providers) < 3 || env.Providers[0].Slug != "azure" {
		t.Fatalf("providers not sorted by slug (want azure first): %+v", env.Providers)
	}

	// Hetzner: registered, core+labels only, authenticated true (token set), no tier.
	hz := env.Providers[byslug["hetzner"]]
	if !hz.Registered || !hz.Capabilities.Core || !hz.Capabilities.Labels {
		t.Errorf("hetzner row wrong: %+v", hz)
	}
	if hz.Capabilities.Catalog || hz.Capabilities.Lifecycle || hz.Capabilities.Pause {
		t.Errorf("hetzner claims a capability it does not honour today: %+v", hz.Capabilities)
	}
	if hz.Authenticated == nil || !*hz.Authenticated {
		t.Errorf("hetzner authenticated should be true with a token set: %+v", hz.Authenticated)
	}
	if hz.Tier != "" {
		t.Errorf("hetzner is not dev-tier: %q", hz.Tier)
	}

	// Fake: registered, all capabilities honoured, tier=dev.
	fk := env.Providers[byslug["fake"]]
	if !fk.Registered || !(fk.Capabilities.Core && fk.Capabilities.Catalog && fk.Capabilities.Lifecycle && fk.Capabilities.Pause && fk.Capabilities.Labels) {
		t.Errorf("fake row should be all-true and registered: %+v", fk)
	}
	if fk.Tier != "dev" {
		t.Errorf("fake must be tier=dev: %q", fk.Tier)
	}

	// Azure: REGISTERED (S5 wired it), core+labels+pause honoured, catalog+lifecycle
	// off, authenticated null (no creds in the test env).
	az := env.Providers[byslug["azure"]]
	if !az.Registered {
		t.Errorf("azure must be registered now that S5 wires it: %+v", az)
	}
	if !(az.Capabilities.Core && az.Capabilities.Labels && az.Capabilities.Pause) {
		t.Errorf("azure should honour core+labels+pause: %+v", az.Capabilities)
	}
	if az.Capabilities.Catalog || az.Capabilities.Lifecycle {
		t.Errorf("azure must NOT claim catalog/lifecycle yet: %+v", az.Capabilities)
	}
	if az.Authenticated != nil {
		t.Errorf("azure authenticated must be json null (no creds), got %+v", az.Authenticated)
	}
}

// TestRunCloudProvidersJSONDefaultHidesFake: without --all the dev-tier fake is
// absent from the machine shape too, so a consumer default-view never sees it.
func TestRunCloudProvidersJSONDefaultHidesFake(t *testing.T) {
	stdout, _, code := runProviders(t, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env providersJSONEnv
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("decode json: %v\n%s", err, stdout)
	}
	for _, p := range env.Providers {
		if p.Slug == "fake" {
			t.Errorf("default json must hide the dev-tier fake: %+v", env.Providers)
		}
	}
}

// TestRunCloudProvidersHelp: -h prints usage naming the command and makes no
// network call.
func TestRunCloudProvidersHelp(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloudProviders(w, globals{help: true}, nil); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(sout.String(), "bp cloud providers") {
		t.Fatalf("help must name the command:\n%s", sout.String())
	}
}

// TestRunCloudProvidersRejectsArgs: an unexpected positional is a usage error,
// so a typo never silently no-ops.
func TestRunCloudProvidersRejectsArgs(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloudProviders(w, globals{}, []string{"hetzner"}); code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
}
