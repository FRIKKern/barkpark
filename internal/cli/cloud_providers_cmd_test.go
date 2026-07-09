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
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudProviders(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// TestRunCloudProvidersTable: the matrix lists hetzner (registered) and azure
// (planned), shows hetzner's true auth state, marks the honest capabilities from
// the fixture, and prints the planned-provider note.
func TestRunCloudProvidersTable(t *testing.T) {
	stdout, stderr, code := runProviders(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{"PROVIDER", "STATE", "AUTH", "CORE", "CATALOG", "LIFECYCLE", "PAUSE", "LABELS", "hetzner", "fake", "azure", "registered", "planned"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table missing %q:\n%s", want, stdout)
		}
	}
	// hetzner has a token → auth "yes"; azure is planned → the note explains it.
	if !strings.Contains(stdout, "yes") {
		t.Errorf("hetzner should show an authenticated state with a token set:\n%s", stdout)
	}
	if !strings.Contains(stdout, "planned providers") {
		t.Errorf("want the honest planned-provider note below the table:\n%s", stdout)
	}
}

// TestRunCloudProvidersJSON: `-o json` emits {providers:[…]} with the exact
// per-provider shape the Console/SPA reads, and the rows are sorted by slug.
func TestRunCloudProvidersJSON(t *testing.T) {
	stdout, _, code := runProviders(t, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env struct {
		Providers []struct {
			Slug          string `json:"slug"`
			Registered    bool   `json:"registered"`
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

	// Hetzner: registered, core+labels only, authenticated true (token set).
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

	// Fake: registered, all capabilities honoured.
	fk := env.Providers[byslug["fake"]]
	if !fk.Registered || !(fk.Capabilities.Core && fk.Capabilities.Catalog && fk.Capabilities.Lifecycle && fk.Capabilities.Pause && fk.Capabilities.Labels) {
		t.Errorf("fake row should be all-true and registered: %+v", fk)
	}

	// Azure: planned (not registered), all-false, authenticated null (unknown).
	az := env.Providers[byslug["azure"]]
	if az.Registered {
		t.Errorf("azure must be planned (not registered) in this slice: %+v", az)
	}
	if az.Capabilities.Core || az.Capabilities.Catalog || az.Capabilities.Lifecycle || az.Capabilities.Pause || az.Capabilities.Labels {
		t.Errorf("azure placeholder must be all-false: %+v", az.Capabilities)
	}
	if az.Authenticated != nil {
		t.Errorf("azure authenticated must be json null (unknown), got %+v", az.Authenticated)
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
