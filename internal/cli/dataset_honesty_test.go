package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The -d half of the scope-honesty contract, proved END TO END through the REAL
// resolver (resolveContext, reading a real saved config / repo file / env off a
// temp home) into the REAL build seam (buildManifestRequest) — the one seam both
// the CLI dispatch and the headless MCP dispatch pass through.
//
// Before this change, EVERY case below produced the same flat URL and exit 0:
// `bp -d staging task ready` was answered from the production ledger and nothing
// said so.
//
// The two directions are asserted on ONE fixture on purpose. A refusal test that
// runs on a different config than the no-false-refusal test proves neither, and
// a config whose ambient dataset already diverges is exactly the shape that
// makes a presence-keyed build look green.

// datasetFixture is the shared fixture: an active config pinned to the
// DefaultDefaults() FLOOR, plus a saved `gyldendal` entry carrying a divergent
// dataset. The split is what makes the two directions separable — if the active
// layer also said "staging", a refusal would fire for a reason this change does
// not touch and the test would prove nothing about -d.
func datasetFixture(t *testing.T) {
	t.Helper()
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir()) // no .barkpark.json above the test's cwd unless a case writes one

	cfg := &Config{
		Server:    "https://s.example",
		Token:     "dev",
		Workspace: "default", Project: "default", Dataset: "production",
		KnownServers: []ServerEntry{{
			Name:      "gyldendal",
			Server:    "https://s.example",
			Token:     "tok-g",
			Workspace: "default",
			Project:   "default",
			Dataset:   "staging",
		}},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// datasetUnscopableCmd mirrors task.ready in the shipped manifest: no :dataset
// placeholder, no declared `dataset` flag, and (unlike task.events) no way for a
// typed -d to reach the wire.
func datasetUnscopableCmd() manifest.Command {
	return manifest.Command{
		ID:       "task.ready",
		Noun:     "task",
		Verb:     "ready",
		AuthTier: "read",
		HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/ready"},
	}
}

// datasetCarryingCmd mirrors doc.ls: the dataset is a path segment, so -d
// already reaches the wire and must be neither refused nor altered.
func datasetCarryingCmd() manifest.Command {
	return manifest.Command{
		ID:       "doc.ls",
		Noun:     "doc",
		Verb:     "ls",
		AuthTier: "none",
		HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"},
		Args:     []manifest.Arg{{Name: "type", Required: true}},
	}
}

// ── c1: the refusal ──────────────────────────────────────────────────────────

// TestTypedDatasetIsRefusedOnADatasetlessVerb is THE criterion-1 check. There is
// no URL that answers the question, so nothing is sent, and the message names
// the command AND the dataset the operator typed.
func TestTypedDatasetIsRefusedOnADatasetlessVerb(t *testing.T) {
	datasetFixture(t)

	g := globals{dataset: "staging", datasetSet: true}
	ctx := resolveContext(g)
	if ctx.Dataset != "staging" {
		t.Fatalf("resolved dataset = %q, want staging — the fixture is wrong before the refusal is tested", ctx.Dataset)
	}
	if !manifest.StatedDataset(ctx) {
		t.Fatalf("StatedDataset = false for a typed `-d staging` — the refusal cannot fire and the assertion below would be vacuous")
	}

	req, derr := buildManifestRequest(g, ctx, &manifest.Manifest{}, datasetUnscopableCmd(), nil, false)
	if derr == nil {
		t.Fatalf("`bp -d %s task ready` was BUILT, url=%q — this is the filed bug: the typed dataset %q is "+
			"nowhere in that URL, so the request will answer from the %q ledger with exit 0",
			ctx.Dataset, req.url, ctx.Dataset, manifest.DefaultDefaults().Dataset)
	}
	if !derr.withUsage {
		t.Error("the refusal is not usage-shaped — the operator gets no hint about which flag to drop")
	}
	msg := derr.Error()
	for _, want := range []string{"task ready", "-d staging"} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal message does not name %q:\n%s", want, msg)
		}
	}
	t.Logf("refusal text: %s", msg)
}

// TestDatasetRefusalNamesTheDeclaredReason — the disposition table's Reason is
// what the operator reads, so the refusal must quote it rather than a generic
// line. This is what makes writing the declaration worth anything.
func TestDatasetRefusalNamesTheDeclaredReason(t *testing.T) {
	cmd := datasetUnscopableCmd()
	d, found := manifest.DatasetDispositionFor(cmd)
	if !found || d.Reason == "" {
		t.Fatalf("task.ready has no declared dataset reason (found=%v) — the manifest-wide enumeration should have caught this", found)
	}
	ctx := manifest.Context{Server: "https://s.example", Dataset: "staging", DatasetTyped: true}
	msg := refuseUnrepresentableDataset(cmd, ctx)
	if !strings.Contains(msg, d.Reason) {
		t.Errorf("refusal does not carry the declared reason %q:\n%s", d.Reason, msg)
	}
}

// TestWorkspaceRefusalWinsWhenBothApply pins the reporting order. Both axes can
// be unrepresentable on the same invocation; the -w/-p refusal is the one shown,
// because a dropped -w answers about another TENANT while a dropped -d answers
// about another dataset inside the workspace already named.
func TestWorkspaceRefusalWinsWhenBothApply(t *testing.T) {
	ctx := manifest.Context{
		Server:            "https://s.example",
		Workspace:         "gyldendal",
		Project:           "books",
		Dataset:           "staging",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
		DatasetTyped:      true,
	}
	msg := refuseUnrepresentableScope(datasetUnscopableCmd(), ctx)
	if !strings.Contains(msg, "-w gyldendal") {
		t.Errorf("the more severe -w/-p refusal was not the one reported:\n%s", msg)
	}
}

// ── c2: NO FALSE REFUSAL, on the same fixture ────────────────────────────────

// TestAmbientDatasetIsNeverRefused is THE criterion-2 check, and the one that
// reds if anyone re-keys this on presence or on a DatasetExplicit that any layer
// above Defaults can set.
//
// Every subtest drives the REAL resolver, so each names a layer an operator
// actually has: a saved `-s` entry, a repo .barkpark.json, a BARKPARK_DATASET,
// the saved active config. None of them is a claim about THIS invocation, and
// none may change a single byte of the request.
//
// The last subtest is the floor case: a config pinned to DefaultDefaults() must
// be untouched even when it is explicit at every layer at once.
func TestAmbientDatasetIsNeverRefused(t *testing.T) {
	const wantURL = "https://s.example/v1/tasks/ready"

	for _, tc := range []struct {
		name  string
		setup func(t *testing.T) globals
		why   string
	}{
		{
			name: "saved -s entry dataset",
			setup: func(t *testing.T) globals {
				return globals{server: "gyldendal"}
			},
			why: "`bp -s gyldendal task ready` — the operator typed no -d; there is no command line " +
				"that gets past a refusal here short of deleting their own saved entry",
		},
		{
			name: "repo .barkpark.json dataset",
			setup: func(t *testing.T) globals {
				dir := t.TempDir()
				writeRepoFile(t, dir, `{"server":"https://s.example","dataset":"staging"}`)
				t.Chdir(dir)
				return globals{}
			},
			why: "a repo context file is a standing preference for everyone who cds into that repo",
		},
		{
			name: "BARKPARK_DATASET",
			setup: func(t *testing.T) globals {
				t.Setenv("BARKPARK_DATASET", "staging")
				return globals{}
			},
			why: "an exported env var is the normal state of a development machine",
		},
		{
			name: "saved active config dataset",
			setup: func(t *testing.T) globals {
				cfg, err := LoadConfig()
				if err != nil {
					t.Fatalf("LoadConfig: %v", err)
				}
				cfg.Dataset = "staging"
				if err := SaveConfig(cfg); err != nil {
					t.Fatalf("SaveConfig: %v", err)
				}
				return globals{}
			},
			why: "`bp config set dataset staging` is a supported thing to do and must not brick every flat command",
		},
		{
			name: "config pinned to the DefaultDefaults() floor",
			setup: func(t *testing.T) globals {
				return globals{dataset: "production", datasetSet: true}
			},
			why: "even a TYPED -d naming the floor changes nothing about the request, so refusing it is a refusal for nothing",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			datasetFixture(t)
			g := tc.setup(t)
			ctx := resolveContext(g)

			if manifest.StatedDataset(ctx) {
				t.Errorf("StatedDataset = true (dataset %q, typed=%v, from-entry=%v) — %s",
					ctx.Dataset, ctx.DatasetTyped, ctx.DatasetFromServerEntry, tc.why)
			}

			req, derr := buildManifestRequest(g, ctx, &manifest.Manifest{}, datasetUnscopableCmd(), nil, false)
			if derr != nil {
				t.Fatalf("REFUSED an invocation that is correct today: %v\n%s", derr, tc.why)
			}
			if req.url != wantURL {
				t.Errorf("url = %q, want the unchanged %q", req.url, wantURL)
			}
		})
	}
}

// TestDatasetCarryingVerbIsNeitherRefusedNorAltered — a command whose own path
// reads :dataset already honours -d; touching it would be a regression. This is
// the direction a fail-CLOSED sweep breaks: it is the 95-command majority of the
// live surface.
func TestDatasetCarryingVerbIsNeitherRefusedNorAltered(t *testing.T) {
	datasetFixture(t)

	g := globals{dataset: "staging", datasetSet: true}
	ctx := resolveContext(g)
	req, derr := buildManifestRequest(g, ctx, &manifest.Manifest{}, datasetCarryingCmd(), []string{"task"}, false)
	if derr != nil {
		t.Fatalf("`bp -d staging doc ls task` was REFUSED: %v — the dataset is a segment of its own URL", derr)
	}
	if want := "https://s.example/v1/data/query/staging/task"; req.url != want {
		t.Errorf("url = %q, want %q — the typed dataset must reach the wire unchanged", req.url, want)
	}
}

// TestDatasetTypedAgreesWithTheGlobalTypedBit is the cross-check between the two
// independent "was it typed" facts the CLI now holds: globals.datasetSet, which
// parseGlobals sets from argv, and Context.DatasetTyped, which
// ResolveWithSources derives from the winning layer. They answer the same
// question by different routes, and a build where they disagree has one of the
// two lying — the refusal would then fire on a command line the forwarding
// logic considers unflagged, or vice versa.
func TestDatasetTypedAgreesWithTheGlobalTypedBit(t *testing.T) {
	for _, g := range []globals{
		{dataset: "staging", datasetSet: true},
		{dataset: "production", datasetSet: true},
		{},
	} {
		t.Run(g.dataset+"/"+boolWord(g.datasetSet), func(t *testing.T) {
			datasetFixture(t)
			ctx := resolveContext(g)
			if ctx.DatasetTyped != g.datasetSet {
				t.Errorf("Context.DatasetTyped = %v but globals.datasetSet = %v for dataset %q — "+
					"the refusal and the query forwarding disagree about whether -d was typed",
					ctx.DatasetTyped, g.datasetSet, g.dataset)
			}
		})
	}
}

func boolWord(b bool) string {
	if b {
		return "typed"
	}
	return "ambient"
}
