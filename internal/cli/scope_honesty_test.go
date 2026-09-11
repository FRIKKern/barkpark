package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The two halves of the scope-honesty contract, proved END TO END through
// buildManifestRequest — the one seam both the CLI dispatch and the headless MCP
// dispatch pass through, so a green here is a green for both surfaces.
//
// Before this change, BOTH cases below produced the SAME flat URL and exit 0:
// `bp -w gyldendal ...` was answered about the default workspace and nothing
// said so.

func scopedPrefixPtr() *string {
	s := "/w/:workspace_slug/p/:project_slug"
	return &s
}

// mirroredCmd mirrors doc.ls in the shipped manifest: a global-tier read with a
// flat template and an ADVERTISED scoped_prefix.
func mirroredCmd() manifest.Command {
	return manifest.Command{
		ID:           "doc.ls",
		Noun:         "doc",
		Verb:         "ls",
		AuthTier:     "none",
		HTTP:         manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"},
		Args:         []manifest.Arg{{Name: "type", Required: true}},
		ScopedPrefix: scopedPrefixPtr(),
	}
}

// unscopableCmd mirrors task.ls: no scope placeholder, no advertised prefix.
func unscopableCmd() manifest.Command {
	return manifest.Command{
		ID:       "task.ls",
		Noun:     "task",
		Verb:     "ls",
		AuthTier: "read",
		HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks"},
	}
}

func scopeCtx(ws, prj string, explicit bool) manifest.Context {
	return manifest.Context{
		Server:            "https://s.example",
		Token:             "t",
		Workspace:         ws,
		Project:           prj,
		Dataset:           "production",
		Output:            "table",
		WorkspaceExplicit: explicit,
		ProjectExplicit:   explicit,
	}
}

// TestStatedScopeReachesTheWireOnAMirroredVerb — the HONEST path. A stated,
// non-floor -w/-p turns the flat URL into the advertised mirror URL, so the
// value the operator typed is visible in the request that goes out.
func TestStatedScopeReachesTheWireOnAMirroredVerb(t *testing.T) {
	m := &manifest.Manifest{}
	cmd := mirroredCmd()

	req, derr := buildManifestRequest(globals{}, scopeCtx("gyldendal", "books", true), m, cmd, []string{"task"}, false)
	if derr != nil {
		t.Fatalf("buildManifestRequest: %v", derr)
	}
	if !strings.HasPrefix(req.url, "https://s.example/w/gyldendal/p/books/v1/data/query/production/task") {
		t.Errorf("url = %q — the stated workspace never reached the wire", req.url)
	}

	// The floor case is unchanged, which is what keeps the blast radius at zero
	// for every invocation that is correct today.
	req, derr = buildManifestRequest(globals{}, scopeCtx("default", "default", true), m, cmd, []string{"task"}, false)
	if derr != nil {
		t.Fatalf("buildManifestRequest at the floor: %v", derr)
	}
	if !strings.HasPrefix(req.url, "https://s.example/v1/data/query/production/task") {
		t.Errorf("floor url = %q, want the unchanged flat path", req.url)
	}
}

// TestStatedScopeIsRefusedOnAnUnscopableVerb — the REFUSED path. There is no URL
// that answers the question, so nothing is sent and the message names the verb
// and the flag.
func TestStatedScopeIsRefusedOnAnUnscopableVerb(t *testing.T) {
	m := &manifest.Manifest{}
	cmd := unscopableCmd()

	req, derr := buildManifestRequest(globals{}, scopeCtx("gyldendal", "books", true), m, cmd, nil, false)
	if derr == nil {
		t.Fatalf("`bp -w gyldendal task ls` was BUILT, url=%q — this is the filed bug: a request that will answer about the default workspace with exit 0", req.url)
	}
	if !derr.withUsage {
		t.Error("the refusal is not usage-shaped — the operator gets no hint about which flag to drop")
	}
	msg := derr.Error()
	for _, want := range []string{"task ls", "-w gyldendal"} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal message does not name %q:\n%s", want, msg)
		}
	}
}

// TestFloorScopeIsNeverRefused — the ambient floor is a deliberate convenience
// and it stays. Every operator's saved context marks the Context explicit, so
// arming on provenance alone would refuse `bp task ls` for everybody.
func TestFloorScopeIsNeverRefused(t *testing.T) {
	m := &manifest.Manifest{}
	for _, tc := range []struct {
		name string
		ctx  manifest.Context
	}{
		{"floor-valued but explicit", scopeCtx("default", "default", true)},
		{"non-floor but never stated", scopeCtx("gyldendal", "books", false)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req, derr := buildManifestRequest(globals{}, tc.ctx, m, unscopableCmd(), nil, false)
			if derr != nil {
				t.Fatalf("refused an invocation that is correct today: %v", derr)
			}
			if want := "https://s.example/v1/tasks"; req.url != want {
				t.Errorf("url = %q, want the unchanged %q", req.url, want)
			}
		})
	}
}

// TestScopeCarryingVerbIsNeitherRefusedNorReRouted — a command whose own path
// reads :workspace_slug already honours -w; touching it would be a regression.
func TestScopeCarryingVerbIsNeitherRefusedNorReRouted(t *testing.T) {
	m := &manifest.Manifest{}
	cmd := manifest.Command{
		ID:       "workspace.project-ls",
		Noun:     "workspace",
		Verb:     "project-ls",
		AuthTier: "read",
		HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/api/workspaces/:workspace_slug/projects"},
	}
	req, derr := buildManifestRequest(globals{}, scopeCtx("gyldendal", "books", true), m, cmd, nil, false)
	if derr != nil {
		t.Fatalf("buildManifestRequest: %v", derr)
	}
	if want := "https://s.example/api/workspaces/gyldendal/projects"; req.url != want {
		t.Errorf("url = %q, want %q", req.url, want)
	}
}

// TestRefusalNamesTheDeclaredReason — the disposition table's Reason is what the
// operator reads, so the refusal must actually quote it rather than a generic
// line. This is what makes the declaration worth writing.
func TestRefusalNamesTheDeclaredReason(t *testing.T) {
	cmd := unscopableCmd()
	d, ok := manifest.ScopeDispositionFor(cmd)
	if !ok || d.Reason == "" {
		t.Fatalf("task.ls has no declared reason (ok=%v) — the manifest-wide enumeration should have caught this", ok)
	}
	msg := refuseUnrepresentableScope(cmd, scopeCtx("gyldendal", "books", true))
	if !strings.Contains(msg, d.Reason) {
		t.Errorf("refusal does not carry the declared reason %q:\n%s", d.Reason, msg)
	}
}

// ── The second door, end to end: `-s <saved-name>` ───────────────────────────
//
// THE DEFECT. resolveContext copies a known server entry's workspace/project/
// dataset into the flags map at FLAG precedence. Once the scope-honesty refusal
// landed, that injected workspace was no longer merely dropped — it was
// REFUSED: `bp -s gyldendal task ready`, with no -w typed anywhere, died with
// "cannot carry -w gyldendal". Nothing the operator can type fixes it; the only
// cure was deleting their own saved entry. It fires exactly where the saved
// entry's workspace DIVERGES from the floor, which is why an owner whose every
// entry says "default" never saw it and a real tenant saw it on every command.
//
// These two tests drive the REAL resolver (resolveContext, reading a real saved
// config off a temp config home) into the REAL build seam (buildManifestRequest),
// so they cover the whole path the operator walks, not a hand-built Context.

// savedEntryConfig writes a config whose ACTIVE scope sits at the floor and
// whose saved `gyldendal` entry carries a divergent one. The split matters: if
// the active layer also said "gyldendal" the refusal would fire for a reason
// this change does not touch, and the test would prove nothing about -s.
func savedEntryConfig(t *testing.T) {
	t.Helper()
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir()) // no .barkpark.json above the test's cwd

	cfg := &Config{
		Server:    "http://localhost:4000",
		Token:     "dev",
		Workspace: "default", Project: "default", Dataset: "production",
		KnownServers: []ServerEntry{{
			Name:      "gyldendal",
			Server:    "https://s.example",
			Token:     "tok-g",
			Workspace: "gyldendal",
			Project:   "books",
			Dataset:   "staging",
		}},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// TestSavedServerEntryScopeIsNotRefused is the fix. `bp -s gyldendal task ls`
// builds the same flat URL it always did and sends it.
//
// It reds if a refusal keys on LayerFlag, on WorkspaceExplicit, or on the value
// diverging from the floor without asking WHO said it — the three designs this
// row exists to rule out.
func TestSavedServerEntryScopeIsNotRefused(t *testing.T) {
	savedEntryConfig(t)

	ctx := resolveContext(globals{server: "gyldendal"})

	// The PRECEDENCE is untouched: the entry's scope still wins over env and the
	// active config, exactly as before. Only the "who said it" label changed.
	if ctx.Workspace != "gyldendal" || ctx.Project != "books" || ctx.Dataset != "staging" {
		t.Fatalf("-s gyldendal scope = %q/%q/%q, want gyldendal/books/staging — the injection's PRECEDENCE must not change",
			ctx.Workspace, ctx.Project, ctx.Dataset)
	}
	if !ctx.WorkspaceExplicit {
		t.Error("WorkspaceExplicit went false — the destroy gate reads it and this change must not disarm that")
	}
	if !ctx.WorkspaceFromServerEntry || !ctx.ProjectFromServerEntry || !ctx.DatasetFromServerEntry {
		// Errorf, not Fatalf: the refusal assertion below is the one that names
		// the operator-visible damage, and a mutation that disarms the mark must
		// print BOTH — the missing signal and the refusal it stops preventing.
		t.Errorf("injection not marked: w=%v p=%v d=%v — cli.go's FindServer branch did not reach AttributeServerEntry",
			ctx.WorkspaceFromServerEntry, ctx.ProjectFromServerEntry, ctx.DatasetFromServerEntry)
	}
	if stated := manifest.StatedScope(ctx); len(stated) != 0 {
		t.Errorf("StatedScope = %v after `bp -s gyldendal` with no -w/-p typed, want empty", stated)
	}

	req, derr := buildManifestRequest(globals{server: "gyldendal"}, ctx, &manifest.Manifest{}, unscopableCmd(), nil, false)
	if derr != nil {
		t.Fatalf("`bp -s gyldendal task ls` was REFUSED: %v\n"+
			"the operator typed no -w; there is no command line that gets past this short of deleting the saved entry", derr)
	}
	if want := "https://s.example/v1/tasks"; req.url != want {
		t.Errorf("url = %q, want the unchanged flat %q", req.url, want)
	}
}

// TestTypedScopeStillRefusesEvenWithASavedEntry is the regression fence. The
// operator who actually types -w must be refused exactly as before — including
// when the same -s entry would have injected the same value. The typed flag is
// in `flags` before the FindServer branch runs, so the branch never marks it.
//
// The env and repo/active layers are covered in the same run: neither goes
// through the injection, so neither may start reading as un-stated.
func TestTypedScopeStillRefusesEvenWithASavedEntry(t *testing.T) {
	savedEntryConfig(t)

	t.Run("typed -w alongside -s", func(t *testing.T) {
		g := globals{server: "gyldendal", workspace: "gyldendal"}
		ctx := resolveContext(g)
		if ctx.WorkspaceFromServerEntry {
			t.Fatal("a TYPED -w was marked as server-entry-injected — the refusal would be disarmed for the case it exists for")
		}
		if stated := manifest.StatedScope(ctx); len(stated) == 0 || stated[0] != "-w" {
			t.Fatalf("StatedScope = %v for a typed -w, want [-w]", stated)
		}
		_, derr := buildManifestRequest(g, ctx, &manifest.Manifest{}, unscopableCmd(), nil, false)
		if derr == nil {
			t.Fatal("`bp -s gyldendal -w gyldendal task ls` was BUILT — the typed case must still refuse")
		}
		msg := derr.Error()
		for _, want := range []string{"task ls", "-w gyldendal"} {
			if !strings.Contains(msg, want) {
				t.Errorf("refusal does not name %q:\n%s", want, msg)
			}
		}
	})

	t.Run("env workspace, no -s", func(t *testing.T) {
		t.Setenv("BARKPARK_WORKSPACE", "gyldendal")
		ctx := resolveContext(globals{})
		if ctx.WorkspaceFromServerEntry {
			t.Fatal("an ENV workspace was marked as server-entry-injected")
		}
		if _, derr := buildManifestRequest(globals{}, ctx, &manifest.Manifest{}, unscopableCmd(), nil, false); derr == nil {
			t.Error("an env-stated divergent workspace stopped refusing — this change must not touch the env layer")
		}
	})

	t.Run("saved active config workspace, no -s", func(t *testing.T) {
		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		cfg.Workspace = "gyldendal"
		if err := SaveConfig(cfg); err != nil {
			t.Fatalf("SaveConfig: %v", err)
		}
		ctx := resolveContext(globals{})
		if ctx.WorkspaceFromServerEntry {
			t.Fatal("the saved ACTIVE workspace was marked as server-entry-injected")
		}
		if _, derr := buildManifestRequest(globals{}, ctx, &manifest.Manifest{}, unscopableCmd(), nil, false); derr == nil {
			t.Error("a saved-config divergent workspace stopped refusing — this change must not touch the active layer")
		}
	})
}
