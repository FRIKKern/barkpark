package manifest

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

const fixtureDir = "../../docs/cli/fixtures"

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(fixtureDir, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return body
}

func parseFixture(t *testing.T, name string) *Manifest {
	t.Helper()
	m, err := Parse(readFixture(t, name))
	if err != nil {
		t.Fatalf("parse fixture %s: %v", name, err)
	}
	return m
}

// (a) Parse both fixtures and sanity-check the typed surface.
func TestParseFixtures(t *testing.T) {
	admin := parseFixture(t, "core-manifest.json")
	if admin.ManifestVersion != "1" {
		t.Errorf("admin manifest_version = %q, want \"1\"", admin.ManifestVersion)
	}
	if admin.AuthTier != "admin" {
		t.Errorf("admin auth_tier = %q, want \"admin\"", admin.AuthTier)
	}
	if admin.Server.BaseURL != "https://api.barkpark.cloud" {
		t.Errorf("admin server.base_url = %q", admin.Server.BaseURL)
	}
	if admin.Server.APIVersion == nil || *admin.Server.APIVersion != "1" {
		t.Errorf("admin server.api_version not parsed as pointer to \"1\"")
	}
	if admin.Server.MinCLI == nil || *admin.Server.MinCLI != "1.0.0" {
		t.Errorf("admin server.min_cli not parsed as pointer to \"1.0.0\"")
	}
	if len(admin.Nouns) != 8 {
		t.Errorf("admin nouns = %d, want 8", len(admin.Nouns))
	}
	if len(admin.Commands) != 17 {
		t.Errorf("admin commands = %d, want 17", len(admin.Commands))
	}

	anon := parseFixture(t, "core-manifest-anon.json")
	if anon.AuthTier != "none" {
		t.Errorf("anon auth_tier = %q, want \"none\"", anon.AuthTier)
	}
	if len(anon.Nouns) != 4 {
		t.Errorf("anon nouns = %d, want 4", len(anon.Nouns))
	}
	if len(anon.Commands) != 6 {
		t.Errorf("anon commands = %d, want 6", len(anon.Commands))
	}

	// Optional scoped_prefix is a pointer: present on doc.get, null on
	// workspace.ls.
	tree := admin.Tree()
	if cmd, ok := tree.Lookup("doc", "get"); !ok {
		t.Fatal("admin tree missing doc get")
	} else if cmd.ScopedPrefix == nil || *cmd.ScopedPrefix != "/w/:workspace_slug/p/:project_slug" {
		t.Errorf("doc.get scoped_prefix = %v, want the workspace prefix", cmd.ScopedPrefix)
	}
	if cmd, ok := tree.Lookup("workspace", "ls"); !ok {
		t.Fatal("admin tree missing workspace ls")
	} else if cmd.ScopedPrefix != nil {
		t.Errorf("workspace.ls scoped_prefix = %v, want nil", *cmd.ScopedPrefix)
	}
}

// Parse must reject an unknown field (mirrors schema additionalProperties:false).
func TestParseRejectsUnknownField(t *testing.T) {
	bad := []byte(`{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[],"bogus":true}`)
	if _, err := Parse(bad); err == nil {
		t.Fatal("Parse accepted an unknown top-level field; want error")
	}
}

// Parse must accept the root-only $comment annotation the fixtures carry.
func TestParseAcceptsComment(t *testing.T) {
	ok := []byte(`{"$comment":"hi","manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e","nouns":[],"commands":[]}`)
	m, err := Parse(ok)
	if err != nil {
		t.Fatalf("Parse rejected $comment: %v", err)
	}
	if m.Comment != "hi" {
		t.Errorf("Comment = %q, want \"hi\"", m.Comment)
	}
}

// (b) Tree() from core-manifest.json yields the eight canonical core nouns plus
// the plugin-contributed `task` noun, with their commands; the anon fixture
// yields its read-only subset. The old `rail` noun is gone, and `task` carries
// source "plugin:tasks" (the Tasks plugin lift) — the Tree is a pure function of
// whatever nouns/commands the manifest carries, regardless of provenance.
func TestTreeFromCoreManifest(t *testing.T) {
	admin := parseFixture(t, "core-manifest.json")
	tree := admin.Tree()

	wantNouns := []string{"doc", "media", "plugin", "schema", "search", "task", "webhook", "workspace"}
	if got := tree.NounNames(); !reflect.DeepEqual(got, wantNouns) {
		t.Errorf("admin noun names = %v, want %v", got, wantNouns)
	}

	// Exact verb set per noun, derived from the fixture commands.
	wantVerbs := map[string][]string{
		"doc":       {"get", "ls", "query", "mutate"},
		"schema":    {"get", "apply"},
		"media":     {"ls", "upload"},
		"search":    {"query"},
		"workspace": {"ls", "project-create"},
		"task":      {"ls", "claim"},
		"webhook":   {"ls", "create"},
		"plugin":    {"ls", "settings"},
	}
	assertVerbs(t, tree, wantVerbs)

	// Every command must be reachable via Lookup at its declared (noun, verb).
	for i := range admin.Commands {
		cmd := admin.Commands[i]
		got, ok := tree.Lookup(cmd.Noun, cmd.Verb)
		if !ok {
			t.Errorf("Lookup(%q,%q) missing", cmd.Noun, cmd.Verb)
			continue
		}
		if got.ID != cmd.ID {
			t.Errorf("Lookup(%q,%q).ID = %q, want %q", cmd.Noun, cmd.Verb, got.ID, cmd.ID)
		}
	}

	// Anon read-only subset.
	anon := parseFixture(t, "core-manifest-anon.json")
	anonTree := anon.Tree()
	wantAnonNouns := []string{"doc", "media", "schema", "search"}
	if got := anonTree.NounNames(); !reflect.DeepEqual(got, wantAnonNouns) {
		t.Errorf("anon noun names = %v, want %v", got, wantAnonNouns)
	}
	// Existence-hiding: admin-only nouns/verbs must NOT appear in the anon tree.
	for _, hidden := range []struct{ noun, verb string }{
		{"doc", "mutate"}, {"schema", "apply"}, {"plugin", "settings"},
		{"task", "claim"}, {"webhook", "create"}, {"workspace", "project-create"},
	} {
		if _, ok := anonTree.Lookup(hidden.noun, hidden.verb); ok {
			t.Errorf("anon tree leaked admin command %s %s", hidden.noun, hidden.verb)
		}
	}
	assertVerbs(t, anonTree, map[string][]string{
		"doc":    {"get", "ls", "query"},
		"schema": {"get"},
		"search": {"query"},
		"media":  {"ls"},
	})
}

// TestTreeIsPureFunction proves the tree carries NO hardcoded noun list: a
// synthetic manifest with a made-up noun + command produces a tree containing
// exactly that made-up noun and verb.
func TestTreeIsPureFunction(t *testing.T) {
	syntheticPlugin := "wibble"
	m := &Manifest{
		ManifestVersion: "1",
		Server:          Server{Name: "t", Version: "0", BaseURL: "http://t"},
		AuthTier:        "admin",
		GeneratedAt:     "2026-01-01T00:00:00Z",
		ETag:            "e",
		Nouns: []Noun{
			{Name: "wibble", Summary: "a made-up noun", Plugin: &syntheticPlugin},
		},
		Commands: []Command{
			{
				ID: "wibble.frobnicate", Noun: "wibble", Verb: "frobnicate",
				Summary: "do the thing",
				HTTP:    HTTP{Method: "POST", PathTemplate: "/v1/wibble/:dataset/frob"},
				AuthTier: "write", Args: []Arg{}, Flags: []Flag{},
				Writes: true, DefaultOutput: "minimal",
			},
		},
	}
	tree := m.Tree()
	if got := tree.NounNames(); !reflect.DeepEqual(got, []string{"wibble"}) {
		t.Fatalf("synthetic tree noun names = %v, want [wibble]", got)
	}
	cmd, ok := tree.Lookup("wibble", "frobnicate")
	if !ok {
		t.Fatal("synthetic tree missing wibble frobnicate")
	}
	if cmd.ID != "wibble.frobnicate" {
		t.Errorf("synthetic cmd ID = %q", cmd.ID)
	}
	if tree.Nouns[0].Plugin == nil || *tree.Nouns[0].Plugin != "wibble" {
		t.Errorf("synthetic noun plugin not preserved")
	}
	// A real-noun lookup that the synthetic manifest never declared must miss —
	// confirms there is no baked-in noun set.
	if _, ok := tree.Lookup("doc", "get"); ok {
		t.Error("synthetic tree returned a hardcoded doc.get")
	}
}

func assertVerbs(t *testing.T, tree *Tree, want map[string][]string) {
	t.Helper()
	for noun, verbs := range want {
		node, ok := nounNode(tree, noun)
		if !ok {
			t.Errorf("tree missing noun %q", noun)
			continue
		}
		got := make([]string, 0, len(node.Verbs))
		for _, c := range node.Verbs {
			got = append(got, c.Verb)
		}
		gotSorted := append([]string(nil), got...)
		wantSorted := append([]string(nil), verbs...)
		sort.Strings(gotSorted)
		sort.Strings(wantSorted)
		if !reflect.DeepEqual(gotSorted, wantSorted) {
			t.Errorf("noun %q verbs = %v, want %v", noun, got, verbs)
		}
	}
}

func nounNode(tree *Tree, name string) (*TreeNoun, bool) {
	for _, n := range tree.Nouns {
		if n.Name == name {
			return n, true
		}
	}
	return nil, false
}

// (c) BuildURL fills a template; scoped_prefix is INERT in v1 (flat path) and
// prepended only when ctx.ScopedMirror is true (the deferred mirror, rule #4).
func TestBuildURL(t *testing.T) {
	admin := parseFixture(t, "core-manifest.json")
	tree := admin.Tree()
	ctx := Context{
		Server:    "https://api.barkpark.cloud",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	}

	docGet, _ := tree.Lookup("doc", "get")

	// v1 (ScopedMirror false): scoped_prefix is inert -> FLAT path, no prepend.
	// This is what the live flat API actually serves.
	url, err := admin.BuildURL(*docGet, ctx, map[string]string{"type": "post", "doc_id": "p1"})
	if err != nil {
		t.Fatalf("BuildURL doc.get: %v", err)
	}
	if want := "https://api.barkpark.cloud/v1/data/doc/production/post/p1"; url != want {
		t.Errorf("doc.get (flat v1) url = %q, want %q", url, want)
	}

	// Future (ScopedMirror true): the scoped_prefix hint activates and prepends.
	ctxMirror := ctx
	ctxMirror.ScopedMirror = true
	url, err = admin.BuildURL(*docGet, ctxMirror, map[string]string{"type": "post", "doc_id": "p1"})
	if err != nil {
		t.Fatalf("BuildURL doc.get (mirror): %v", err)
	}
	if want := "https://api.barkpark.cloud/w/acme/p/site/v1/data/doc/production/post/p1"; url != want {
		t.Errorf("doc.get (scoped mirror) url = %q, want %q", url, want)
	}

	// Flat command (scoped_prefix null): workspace.ls — no prefix prepended.
	wsLs, _ := tree.Lookup("workspace", "ls")
	url, err = admin.BuildURL(*wsLs, ctx, nil)
	if err != nil {
		t.Fatalf("BuildURL workspace.ls: %v", err)
	}
	if want := "https://api.barkpark.cloud/api/workspaces"; url != want {
		t.Errorf("workspace.ls url = %q, want %q", url, want)
	}

	// Flat command with an arg placeholder: workspace.project-create.
	projCreate, _ := tree.Lookup("workspace", "project-create")
	url, err = admin.BuildURL(*projCreate, ctx, map[string]string{"workspace_slug": "acme"})
	if err != nil {
		t.Fatalf("BuildURL project-create: %v", err)
	}
	if want := "https://api.barkpark.cloud/api/workspaces/acme/projects"; url != want {
		t.Errorf("project-create url = %q, want %q", url, want)
	}

	// Trailing-slash server base must not double up.
	ctxSlash := ctx
	ctxSlash.Server = "https://api.barkpark.cloud/"
	url, _ = admin.BuildURL(*wsLs, ctxSlash, nil)
	if want := "https://api.barkpark.cloud/api/workspaces"; url != want {
		t.Errorf("trailing-slash url = %q, want %q", url, want)
	}

	// A missing required placeholder is an error, not a malformed URL.
	if _, err := admin.BuildURL(*docGet, ctx, map[string]string{"type": "post"}); err == nil {
		t.Error("BuildURL accepted a missing :doc_id; want error")
	}
}

// (d) Context precedence: flag beats env beats active beats default.
func TestResolvePrecedence(t *testing.T) {
	env := apiclient.Config{
		BaseURL:   "http://env-server:4000",
		Token:     "env-token",
		Workspace: "env-ws",
		Project:   "env-proj",
		Dataset:   "env-ds",
	}
	active := ActiveContext{
		Server:    "http://active-server",
		Workspace: "active-ws",
		Dataset:   "active-ds",
		Output:    "yaml",
	}
	defaults := DefaultDefaults()

	// Flag beats env (and everything below) for dataset.
	flags := map[string]string{FlagDataset: "flag-ds"}
	ctx := Resolve(flags, env, active, defaults)
	if ctx.Dataset != "flag-ds" {
		t.Errorf("dataset: flag should win, got %q", ctx.Dataset)
	}

	// Env beats active + default where no flag is set.
	if ctx.Server != "http://env-server:4000" {
		t.Errorf("server: env should beat active, got %q", ctx.Server)
	}
	if ctx.Workspace != "env-ws" {
		t.Errorf("workspace: env should win, got %q", ctx.Workspace)
	}
	if ctx.Token != "env-token" {
		t.Errorf("token: env should win, got %q", ctx.Token)
	}

	// Active beats default where flag + env are empty (Output has no env field).
	if ctx.Output != "yaml" {
		t.Errorf("output: active should beat default, got %q", ctx.Output)
	}

	// Default wins when flag, env, and active are all empty for that field.
	emptyEnv := apiclient.Config{}
	emptyActive := ActiveContext{}
	ctx2 := Resolve(nil, emptyEnv, emptyActive, defaults)
	if ctx2.Dataset != "production" {
		t.Errorf("dataset: default should be production, got %q", ctx2.Dataset)
	}
	if ctx2.Output != "table" {
		t.Errorf("output: default should be table, got %q", ctx2.Output)
	}
	if ctx2.Workspace != "default" || ctx2.Project != "default" {
		t.Errorf("ws/proj defaults wrong: %q/%q", ctx2.Workspace, ctx2.Project)
	}

	// Active beats default for a field env leaves empty: server, when env empty.
	ctx3 := Resolve(nil, apiclient.Config{}, active, defaults)
	if ctx3.Server != "http://active-server" {
		t.Errorf("server: active should beat default, got %q", ctx3.Server)
	}
}
