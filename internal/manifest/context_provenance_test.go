package manifest

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Resolve is the ONLY producer of WorkspaceExplicit/ProjectExplicit, and the
// destroy-tier scope gate in internal/cli is their only consumer. That gate's
// own tests build Context literals, so nothing there can notice if Resolve
// starts reporting every scope as stated — the gate would be silently disarmed
// while every one of its tests stayed green. (Measured: mutating Resolve's
// `stated` to `return true` left the whole cli suite passing.) This file is the
// producer-side half that closes that blind spot.
func TestResolveScopeProvenance(t *testing.T) {
	defs := DefaultDefaults() // Workspace/Project = "default"

	cases := []struct {
		name          string
		flags         map[string]string
		env           apiclient.Config
		active        ActiveContext
		wantWorkspace string
		wantProject   string
		wantWsStated  bool
		wantPrjStated bool
	}{
		{
			name:          "nothing stated anywhere — the baked floor, and it says so",
			wantWorkspace: "default", wantProject: "default",
			wantWsStated: false, wantPrjStated: false,
		},
		{
			name:          "-w/-p flags",
			flags:         map[string]string{FlagWorkspace: "acme", FlagProject: "site"},
			wantWorkspace: "acme", wantProject: "site",
			wantWsStated: true, wantPrjStated: true,
		},
		{
			// THE CASE A VALUE-COMPARISON WOULD BREAK: a workspace genuinely
			// named `default`, named explicitly. It must read as stated.
			name:          "-w default explicitly is STATED, not the floor",
			flags:         map[string]string{FlagWorkspace: "default", FlagProject: "default"},
			wantWorkspace: "default", wantProject: "default",
			wantWsStated: true, wantPrjStated: true,
		},
		{
			name:          "env vars",
			env:           apiclient.Config{Workspace: "envws", Project: "envproj"},
			wantWorkspace: "envws", wantProject: "envproj",
			wantWsStated: true, wantPrjStated: true,
		},
		{
			name:          "saved config / repo file (the active layer)",
			active:        ActiveContext{Workspace: "cfgws", Project: "cfgproj"},
			wantWorkspace: "cfgws", wantProject: "cfgproj",
			wantWsStated: true, wantPrjStated: true,
		},
		{
			name:          "workspace stated, project not — reported independently",
			flags:         map[string]string{FlagWorkspace: "acme"},
			wantWorkspace: "acme", wantProject: "default",
			wantWsStated: true, wantPrjStated: false,
		},
		{
			name:          "project stated, workspace not",
			active:        ActiveContext{Project: "site"},
			wantWorkspace: "default", wantProject: "site",
			wantWsStated: false, wantPrjStated: true,
		},
		{
			// An EMPTY flag is not a statement — it falls through like an absent
			// one, and provenance has to agree with the value that results.
			name:          "empty -w falls through and is NOT stated",
			flags:         map[string]string{FlagWorkspace: ""},
			wantWorkspace: "default", wantProject: "default",
			wantWsStated: false, wantPrjStated: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Resolve(tc.flags, tc.env, tc.active, defs)

			if got.Workspace != tc.wantWorkspace {
				t.Errorf("Workspace = %q, want %q", got.Workspace, tc.wantWorkspace)
			}
			if got.Project != tc.wantProject {
				t.Errorf("Project = %q, want %q", got.Project, tc.wantProject)
			}
			if got.WorkspaceExplicit != tc.wantWsStated {
				t.Errorf("WorkspaceExplicit = %v, want %v", got.WorkspaceExplicit, tc.wantWsStated)
			}
			if got.ProjectExplicit != tc.wantPrjStated {
				t.Errorf("ProjectExplicit = %v, want %v", got.ProjectExplicit, tc.wantPrjStated)
			}
		})
	}
}

// Provenance must agree with the VALUE it describes: whenever a scope reads as
// stated, the value must not be the one the Defaults layer would have supplied
// on its own, and vice versa. This is the invariant that keeps `stated` and
// `pick` from drifting apart as two separate copies of the precedence order.
func TestResolveProvenanceAgreesWithValue(t *testing.T) {
	defs := Defaults{Workspace: "FLOOR-WS", Project: "FLOOR-PRJ"}

	layers := []struct {
		name   string
		flags  map[string]string
		env    apiclient.Config
		active ActiveContext
	}{
		{name: "none"},
		{name: "flag", flags: map[string]string{FlagWorkspace: "a", FlagProject: "b"}},
		{name: "env", env: apiclient.Config{Workspace: "a", Project: "b"}},
		{name: "active", active: ActiveContext{Workspace: "a", Project: "b"}},
	}

	for _, l := range layers {
		t.Run(l.name, func(t *testing.T) {
			got := Resolve(l.flags, l.env, l.active, defs)

			if got.WorkspaceExplicit == (got.Workspace == defs.Workspace) {
				t.Errorf("WorkspaceExplicit=%v but Workspace=%q (floor %q) — provenance disagrees with the value",
					got.WorkspaceExplicit, got.Workspace, defs.Workspace)
			}
			if got.ProjectExplicit == (got.Project == defs.Project) {
				t.Errorf("ProjectExplicit=%v but Project=%q (floor %q) — provenance disagrees with the value",
					got.ProjectExplicit, got.Project, defs.Project)
			}
		})
	}
}
