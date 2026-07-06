package taskboard

import "testing"

// TestCmuxWorkerID pins the four-tier precedence across the full env matrix,
// including empty-string guards (an explicitly-blank var must fall through, not
// yield a broken `cmux-` id). t.Setenv restores every var after each case.
func TestCmuxWorkerID(t *testing.T) {
	// A stable hostname-independent tier-4 expectation: BARKPARK_WORKER_ID unset
	// falls to ResolveWorker() → "tui-<hostname>". We assert the PREFIX for the
	// pure fallthrough case so the test is host-agnostic.
	cases := []struct {
		name    string
		env     map[string]string
		want    string
		wantPfx string // when want == "", assert this prefix instead (tier 4)
	}{
		{
			name: "tier1 BARKPARK_WORKER_ID wins over everything",
			env:  map[string]string{"BARKPARK_WORKER_ID": "hand-set", "CMUX_SURFACE_ID": "srf", "CMUX_WORKSPACE_ID": "ws"},
			want: "hand-set",
		},
		{
			name: "tier2 surface id — the normal path",
			env:  map[string]string{"BARKPARK_WORKER_ID": "", "CMUX_SURFACE_ID": "srf_01H", "CMUX_WORKSPACE_ID": "ws_9"},
			want: "cmux-srf_01H",
		},
		{
			name: "tier3 workspace id when no surface id",
			env:  map[string]string{"BARKPARK_WORKER_ID": "", "CMUX_SURFACE_ID": "", "CMUX_WORKSPACE_ID": "ws_9"},
			want: "cmux-ws_9",
		},
		{
			name:    "tier4 tui-<hostname> outside cmux entirely",
			env:     map[string]string{"BARKPARK_WORKER_ID": "", "CMUX_SURFACE_ID": "", "CMUX_WORKSPACE_ID": ""},
			want:    "",
			wantPfx: "tui-",
		},
		{
			name: "empty surface falls through to workspace (empty-string guard)",
			env:  map[string]string{"BARKPARK_WORKER_ID": "", "CMUX_SURFACE_ID": "", "CMUX_WORKSPACE_ID": "ws_only"},
			want: "cmux-ws_only",
		},
		{
			name: "blank BARKPARK_WORKER_ID does not win — surface takes over",
			env:  map[string]string{"BARKPARK_WORKER_ID": "", "CMUX_SURFACE_ID": "srf_x", "CMUX_WORKSPACE_ID": ""},
			want: "cmux-srf_x",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Clear all three, then apply the case's values, so an ambient
			// CMUX_SURFACE_ID (this test may run inside a real cmux pane!) never
			// leaks in. t.Setenv handles restore.
			t.Setenv("BARKPARK_WORKER_ID", "")
			t.Setenv("CMUX_SURFACE_ID", "")
			t.Setenv("CMUX_WORKSPACE_ID", "")
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			got := CmuxWorkerID()
			if tc.want != "" {
				if got != tc.want {
					t.Errorf("CmuxWorkerID() = %q, want %q", got, tc.want)
				}
				return
			}
			if got[:len(tc.wantPfx)] != tc.wantPfx {
				t.Errorf("CmuxWorkerID() = %q, want prefix %q", got, tc.wantPfx)
			}
		})
	}
}

// TestCmuxWorkerIDConsistentWithResolveWorker guards charter D-note: tier 1 and
// tier 4 agree because ResolveWorker ALSO honors BARKPARK_WORKER_ID first, so a
// hand-set id yields the identical answer whether or not cmux vars are present.
func TestCmuxWorkerIDConsistentWithResolveWorker(t *testing.T) {
	t.Setenv("BARKPARK_WORKER_ID", "explicit-id")
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_WORKSPACE_ID", "")
	if CmuxWorkerID() != ResolveWorker() {
		t.Errorf("CmuxWorkerID()=%q != ResolveWorker()=%q with BARKPARK_WORKER_ID set", CmuxWorkerID(), ResolveWorker())
	}
}
