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
