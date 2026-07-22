package manifest

import "testing"

// strPtr returns a pointer to s — the scoped_prefix field is *string (nil = no
// hint), so the table below needs addressable literals.
func strPtr(s string) *string { return &s }

// TestBuildURLScopedTierComposition pins the auth_tier-keyed scoped_prefix
// composition (bp-token-create-scoped-prefix-404). The rule: a command whose
// auth_tier is scoped_admin/scoped_read has its route mounted ONLY under
// /w/:ws/p/:project, so BuildURL composes the prefix NOW; a global-tier command
// (none/read/write/admin) keeps serving its flat path_template today, its
// scoped_prefix a future-mirror hint that stays inert until ctx.ScopedMirror.
//
// Every core command that ships a non-nil scoped_prefix is audited here (one row
// per capabilities.ex core_cmd carrying scoped_prefix), so a future command that
// picks the wrong tier — or a regression that flips the gate back to
// ScopedMirror-only — trips this table. The token.create row is the mutation
// canary: revert url.go to the old `ctx.ScopedMirror &&` gate and this row
// alone fails (flat /v1/tokens instead of the composed scoped path).
func TestBuildURLScopedTierComposition(t *testing.T) {
	m := &Manifest{}
	ctx := Context{
		Server:    "https://api.barkpark.cloud",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	}
	scopedHint := "/w/:workspace_slug/p/:project_slug"

	cases := []struct {
		name     string
		tier     string
		method   string
		template string
		prefix   *string
		args     map[string]string
		want     string
	}{
		// ── scoped tier: route exists ONLY under the prefix → COMPOSE now ──
		{
			// The bug this slice fixes: bp token create.
			name:     "token.create (scoped_admin) composes",
			tier:     "scoped_admin",
			method:   "POST",
			template: "/v1/tokens",
			prefix:   strPtr(scopedHint),
			want:     "https://api.barkpark.cloud/w/acme/p/site/v1/tokens",
		},
		{
			// Forward-guard: a future scoped_read command composes identically.
			name:     "hypothetical scoped_read composes",
			tier:     "scoped_read",
			method:   "GET",
			template: "/v1/data/private/:dataset",
			prefix:   strPtr(scopedHint),
			want:     "https://api.barkpark.cloud/w/acme/p/site/v1/data/private/production",
		},

		// ── global tiers carrying scoped_prefix: FUTURE mirror hint, stay FLAT ──
		{
			name:     "doc.get (none) stays flat",
			tier:     "none",
			method:   "GET",
			template: "/v1/data/doc/:dataset/:type/:doc_id",
			prefix:   strPtr(scopedHint),
			args:     map[string]string{"type": "post", "doc_id": "p1"},
			want:     "https://api.barkpark.cloud/v1/data/doc/production/post/p1",
		},
		{
			name:     "doc.backlinks (read) stays flat",
			tier:     "read",
			method:   "GET",
			template: "/v1/data/backlinks/:dataset/:id",
			prefix:   strPtr(scopedHint),
			args:     map[string]string{"id": "p1"},
			want:     "https://api.barkpark.cloud/v1/data/backlinks/production/p1",
		},
		{
			name:     "doc.mutate (write) stays flat",
			tier:     "write",
			method:   "POST",
			template: "/v1/data/mutate/:dataset",
			prefix:   strPtr(scopedHint),
			want:     "https://api.barkpark.cloud/v1/data/mutate/production",
		},
		{
			name:     "schema.apply (admin) stays flat",
			tier:     "admin",
			method:   "POST",
			template: "/v1/schemas/:dataset",
			prefix:   strPtr(scopedHint),
			want:     "https://api.barkpark.cloud/v1/schemas/production",
		},
		{
			name:     "media.upload (write) stays flat",
			tier:     "write",
			method:   "POST",
			template: "/v1/media/:dataset/upload",
			prefix:   strPtr(scopedHint),
			want:     "https://api.barkpark.cloud/v1/media/production/upload",
		},

		// ── scoped tier but NO prefix: self-scoping route, never composed ──
		{
			// workspace.project-create is scoped_admin yet carries no
			// scoped_prefix — it self-scopes via :workspace_slug in its own
			// path. A nil prefix is never prepended, regardless of tier.
			name:     "workspace.project-create (scoped_admin, nil prefix) stays flat",
			tier:     "scoped_admin",
			method:   "POST",
			template: "/api/workspaces/:workspace_slug/projects",
			prefix:   nil,
			args:     map[string]string{"workspace_slug": "acme"},
			want:     "https://api.barkpark.cloud/api/workspaces/acme/projects",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cmd := Command{
				ID:           tc.name,
				AuthTier:     tc.tier,
				HTTP:         HTTP{Method: tc.method, PathTemplate: tc.template},
				ScopedPrefix: tc.prefix,
			}
			got, err := m.BuildURL(cmd, ctx, tc.args)
			if err != nil {
				t.Fatalf("BuildURL(%s): %v", tc.name, err)
			}
			if got != tc.want {
				t.Errorf("BuildURL(%s)\n  got  %q\n  want %q", tc.name, got, tc.want)
			}
		})
	}
}

// TestBuildURLScopedMirrorStillComposesFlatTiers proves the future full-mirror
// path is untouched by the tier fix: when ctx.ScopedMirror is true, even a
// global-tier command composes its scoped_prefix (the whole-server mirror day).
func TestBuildURLScopedMirrorStillComposesFlatTiers(t *testing.T) {
	m := &Manifest{}
	ctx := Context{
		Server:       "https://api.barkpark.cloud",
		Workspace:    "acme",
		Project:      "site",
		Dataset:      "production",
		ScopedMirror: true,
	}
	cmd := Command{
		ID:           "doc.get",
		AuthTier:     "none",
		HTTP:         HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:doc_id"},
		ScopedPrefix: strPtr("/w/:workspace_slug/p/:project_slug"),
	}
	got, err := m.BuildURL(cmd, ctx, map[string]string{"type": "post", "doc_id": "p1"})
	if err != nil {
		t.Fatalf("BuildURL: %v", err)
	}
	want := "https://api.barkpark.cloud/w/acme/p/site/v1/data/doc/production/post/p1"
	if got != want {
		t.Errorf("mirror doc.get\n  got  %q\n  want %q", got, want)
	}
}

// TestIsScopedTier locks the tier classifier: exactly the two per-workspace-role
// tiers compose; every global tier and any unknown string does not.
func TestIsScopedTier(t *testing.T) {
	compose := []string{"scoped_admin", "scoped_read"}
	flat := []string{"none", "read", "write", "admin", "ingest", "", "scoped", "SCOPED_ADMIN"}
	for _, tier := range compose {
		if !isScopedTier(tier) {
			t.Errorf("isScopedTier(%q) = false, want true", tier)
		}
	}
	for _, tier := range flat {
		if isScopedTier(tier) {
			t.Errorf("isScopedTier(%q) = true, want false", tier)
		}
	}
}
