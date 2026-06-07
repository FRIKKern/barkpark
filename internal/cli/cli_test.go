package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const fixtureManifest = "../../docs/cli/fixtures/core-manifest.json"
const fullManifest = "../../docs/cli/fixtures/full-manifest.json"

func loadFixtureTree(t *testing.T) (*manifest.Manifest, *manifest.Tree) {
	t.Helper()
	return loadTreeFrom(t, fixtureManifest)
}

func loadTreeFrom(t *testing.T, path string) (*manifest.Manifest, *manifest.Tree) {
	t.Helper()
	body, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		t.Fatalf("read fixture %s: %v", path, err)
	}
	m, err := manifest.Parse(body)
	if err != nil {
		t.Fatalf("parse fixture %s: %v", path, err)
	}
	return m, m.Tree()
}

// --- global flag parsing -----------------------------------------------------

func TestParseGlobals(t *testing.T) {
	tests := []struct {
		name     string
		args     []string
		wantRest []string
		check    func(t *testing.T, g globals)
	}{
		{
			name:     "flags before noun",
			args:     []string{"-o", "json", "doc", "ls", "post"},
			wantRest: []string{"doc", "ls", "post"},
			check: func(t *testing.T, g globals) {
				if g.output != "json" || !g.outputSet {
					t.Errorf("output = %q set=%v, want json/true", g.output, g.outputSet)
				}
			},
		},
		{
			name:     "flags after noun interleave",
			args:     []string{"doc", "ls", "post", "-o", "json"},
			wantRest: []string{"doc", "ls", "post"},
			check: func(t *testing.T, g globals) {
				if g.output != "json" {
					t.Errorf("output = %q, want json", g.output)
				}
			},
		},
		{
			name:     "json shorthand sets output",
			args:     []string{"--json", "doc", "ls", "post"},
			wantRest: []string{"doc", "ls", "post"},
			check: func(t *testing.T, g globals) {
				if g.output != "json" || !g.jsonOut {
					t.Errorf("json shorthand: output=%q jsonOut=%v", g.output, g.jsonOut)
				}
			},
		},
		{
			name:     "equals form",
			args:     []string{"--server=https://x", "doc", "ls", "post"},
			wantRest: []string{"doc", "ls", "post"},
			check: func(t *testing.T, g globals) {
				if g.server != "https://x" {
					t.Errorf("server = %q", g.server)
				}
			},
		},
		{
			name:     "pagination flags",
			args:     []string{"doc", "ls", "post", "--limit", "10", "--offset", "5", "--all"},
			wantRest: []string{"doc", "ls", "post"},
			check: func(t *testing.T, g globals) {
				if g.limit != 10 || !g.limitSet {
					t.Errorf("limit = %d set=%v", g.limit, g.limitSet)
				}
				if g.offset != 5 || !g.offsetSet {
					t.Errorf("offset = %d set=%v", g.offset, g.offsetSet)
				}
				if !g.all {
					t.Errorf("all not set")
				}
			},
		},
		{
			name:     "command-local flag passes through",
			args:     []string{"doc", "get", "post", "p2", "--perspective", "drafts"},
			wantRest: []string{"doc", "get", "post", "p2", "--perspective", "drafts"},
			check:    func(t *testing.T, g globals) {},
		},
		{
			name:     "dry-run and yes bools",
			args:     []string{"doc", "mutate", "--dry-run", "--yes"},
			wantRest: []string{"doc", "mutate"},
			check: func(t *testing.T, g globals) {
				if !g.dryRun || !g.yes {
					t.Errorf("dryRun=%v yes=%v", g.dryRun, g.yes)
				}
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			g, rest, err := parseGlobals(tc.args)
			if err != nil {
				t.Fatalf("parseGlobals error: %v", err)
			}
			if !equalStrings(rest, tc.wantRest) {
				t.Errorf("rest = %v, want %v", rest, tc.wantRest)
			}
			tc.check(t, g)
		})
	}
}

func TestParseGlobalsErrors(t *testing.T) {
	cases := [][]string{
		{"-o", "bogus", "doc", "ls"},   // invalid output
		{"--limit", "notanint", "doc"}, // bad int
		{"-s"},                         // value flag without value
	}
	for _, args := range cases {
		if _, _, err := parseGlobals(args); err == nil {
			t.Errorf("parseGlobals(%v): expected error, got nil", args)
		}
	}
}

// --- command resolution ------------------------------------------------------

func TestCommandResolution(t *testing.T) {
	_, tree := loadFixtureTree(t)

	if cmd, ok := tree.Lookup("doc", "ls"); !ok {
		t.Fatal("doc ls not found")
	} else if cmd.ID != "doc.ls" || cmd.HTTP.Method != "GET" {
		t.Errorf("doc ls = %+v", cmd)
	}

	if cmd, ok := tree.Lookup("doc", "mutate"); !ok {
		t.Fatal("doc mutate not found")
	} else if !cmd.Writes {
		t.Errorf("doc mutate should be a write")
	}

	if _, ok := tree.Lookup("doc", "frobnicate"); ok {
		t.Errorf("unknown verb resolved")
	}
	if _, ok := tree.Lookup("nope", "ls"); ok {
		t.Errorf("unknown noun resolved")
	}
}

func TestBindArgs(t *testing.T) {
	_, tree := loadFixtureTree(t)
	get, _ := tree.Lookup("doc", "get")

	m, err := bindArgs(*get, []string{"post", "p2"})
	if err != nil {
		t.Fatalf("bindArgs: %v", err)
	}
	if m["type"] != "post" || m["doc_id"] != "p2" {
		t.Errorf("bound args = %v", m)
	}

	if _, err := bindArgs(*get, []string{"post"}); err == nil {
		t.Errorf("missing required doc_id: expected error")
	}
	if _, err := bindArgs(*get, []string{"post", "p2", "extra"}); err == nil {
		t.Errorf("too many args: expected error")
	}
}

func TestSplitArgs(t *testing.T) {
	_, tree := loadFixtureTree(t)
	get, _ := tree.Lookup("doc", "get")

	pos, flags, err := splitArgs(*get, []string{"post", "p2", "--perspective", "drafts"})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	if !equalStrings(pos, []string{"post", "p2"}) {
		t.Errorf("pos = %v", pos)
	}
	if got := flags["perspective"]; len(got) != 1 || got[0] != "drafts" {
		t.Errorf("perspective flag = %v", got)
	}

	if _, _, err := splitArgs(*get, []string{"post", "--bogus", "x"}); err == nil {
		t.Errorf("unknown flag: expected error")
	}
}

// --- auth tiering ------------------------------------------------------------

func TestAuthHeaders(t *testing.T) {
	_, tree := loadFixtureTree(t)
	ctx := manifest.Context{Token: "tok"}

	// read with scoped_prefix -> token attached (server fails closed otherwise).
	ls, _ := tree.Lookup("doc", "ls")
	if h := authHeaders(*ls, ctx); h["Authorization"] != "Bearer tok" {
		t.Errorf("scoped read should carry token: %v", h)
	}

	// write -> token attached.
	mut, _ := tree.Lookup("doc", "mutate")
	if h := authHeaders(*mut, ctx); h["Authorization"] != "Bearer tok" {
		t.Errorf("write should carry token: %v", h)
	}

	// scoped_admin -> NEVER preflight-refused; token IS attached (rule #2).
	pc, _ := tree.Lookup("workspace", "project-create")
	if pc.AuthTier != "scoped_admin" {
		t.Fatalf("fixture changed: project-create tier = %q", pc.AuthTier)
	}
	if h := authHeaders(*pc, ctx); h["Authorization"] != "Bearer tok" {
		t.Errorf("scoped_admin should carry token (no client refuse): %v", h)
	}

	// FLAT read (workspace ls has no scoped_prefix) -> token IS attached now.
	// The server's OptionalToken / RequireWritePermission read gate needs the
	// bearer for auth-required reads like /api/workspaces; an OptionalToken
	// public read simply ignores it. Sending it regardless is the fix.
	wls, _ := tree.Lookup("workspace", "ls")
	if wls.AuthTier != "read" {
		t.Fatalf("fixture changed: workspace ls tier = %q, want read", wls.AuthTier)
	}
	if h := authHeaders(*wls, ctx); h["Authorization"] != "Bearer tok" {
		t.Errorf("flat read should carry token when present: %v", h)
	}

	// none -> never carries a token, even when one is present.
	none := manifest.Command{ID: "x.public", AuthTier: "none", HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"}}
	if h := authHeaders(none, ctx); h["Authorization"] != "" {
		t.Errorf("none tier must not send a token: %v", h)
	}

	// No token in context -> no Authorization header for an auth tier.
	if h := authHeaders(*wls, manifest.Context{}); h["Authorization"] != "" {
		t.Errorf("no token -> no auth header: %v", h)
	}
}

// --- exit-code mapping -------------------------------------------------------

func TestExitForCode(t *testing.T) {
	cases := map[string]int{
		"not_found":           exitNotFound,
		"schema_unknown":      exitNotFound,
		"share_expired":       exitNotFound,
		"unauthorized":        exitAuth,
		"forbidden":           exitAuth,
		"cors_forbidden":      exitAuth,
		"csrf_required":       exitAuth,
		"malformed":           exitUsage,
		"validation_failed":   exitValidation,
		"invalid_paper":       exitValidation,
		"invalid_op":          exitValidation,
		"rev_mismatch":        exitConflict,
		"precondition_failed": exitConflict,
		"conflict":            exitConflict,
		"rate_limited":        exitRateLimit,
		"internal_error":      exitServer,
		"totally_unknown":     exitGeneric, // fallback
		"":                    exitGeneric,
	}
	for code, want := range cases {
		if got := exitForCode(code); got != want {
			t.Errorf("exitForCode(%q) = %d, want %d", code, got, want)
		}
	}
}

func TestClassifyError(t *testing.T) {
	cases := []struct {
		name string
		body string
		want int
		code string
	}{
		{"canonical not_found", `{"error":{"code":"not_found","message":"document not found","request_id":"r1"}}`, exitNotFound, "not_found"},
		{"canonical forbidden", `{"error":{"code":"forbidden","message":"token lacks required permission"}}`, exitAuth, "forbidden"},
		{"canonical validation", `{"error":{"code":"validation_failed","message":"bad"}}`, exitValidation, "validation_failed"},
		{"canonical rev_mismatch", `{"error":{"code":"rev_mismatch"}}`, exitConflict, "rev_mismatch"},
		{"bare halted string", `{"error":"halted","reason":"lifecycle veto"}`, exitConflict, "halted"},
		{"bare not_found string", `{"ok":false,"error":"not_found","id":"x"}`, exitNotFound, "not_found"},
		{"bare invalid string", `{"error":"invalid"}`, exitUsage, "invalid"},
		{"ok-false reason", `{"ok":false,"reason":"invalid_edge"}`, exitUsage, "invalid_edge"},
		{"message-only no code", `{"error":{"message":"from and to are required"}}`, exitUsage, ""},
		{"message-only not-found text", `{"error":{"message":"synonym not found"}}`, exitNotFound, ""},
		{"unrecognized body", `garbage`, exitGeneric, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ae := classifyError(0, []byte(tc.body))
			if ae.exit != tc.want {
				t.Errorf("classifyError(%s).exit = %d, want %d", tc.name, ae.exit, tc.want)
			}
			if tc.code != "" && ae.code != tc.code {
				t.Errorf("classifyError(%s).code = %q, want %q", tc.name, ae.code, tc.code)
			}
		})
	}
}

// --- prod heuristic ----------------------------------------------------------

func TestIsProd(t *testing.T) {
	m, _ := loadFixtureTree(t)
	if !isProd(manifest.Context{Server: "https://api.barkpark.cloud"}, m) {
		t.Errorf("prod fixture should be prod")
	}

	// A localhost target must NOT be prod even with a prod-named manifest.
	if isProd(manifest.Context{Server: "http://localhost:4000"}, &manifest.Manifest{
		Server: manifest.Server{Name: "dev", BaseURL: "http://localhost:4000"},
	}) {
		t.Errorf("localhost should not be prod")
	}
}

// --- plugins-on manifest -----------------------------------------------------

// TestPluginTreeFromFullManifest asserts that the command tree built from the
// plugins-ON manifest surfaces the plugin nouns AND their verbs with zero
// CLI-side code — the tree is a pure function of the manifest.
func TestPluginTreeFromFullManifest(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	// Plugin nouns must appear as top-level tree nodes, tagged with their plugin.
	wantPluginNouns := map[string]string{
		"bulldocs": "bulldocs",
		"onixedit": "onixedit",
	}
	for noun, wantPlugin := range wantPluginNouns {
		n, ok := lookupNoun(tree, noun)
		if !ok {
			t.Errorf("plugin noun %q missing from tree", noun)
			continue
		}
		if n.Plugin == nil || *n.Plugin != wantPlugin {
			t.Errorf("noun %q plugin tag = %v, want %q", noun, n.Plugin, wantPlugin)
		}
	}

	// Each plugin noun's verbs must resolve through Tree.Lookup.
	wantVerbs := map[string][]string{
		"bulldocs": {"publish", "patch", "intents", "intent-processed"},
		"onixedit": {"export"},
	}
	for noun, verbs := range wantVerbs {
		for _, verb := range verbs {
			cmd, ok := tree.Lookup(noun, verb)
			if !ok {
				t.Errorf("%s %s not found in tree", noun, verb)
				continue
			}
			if cmd.Noun != noun || cmd.Verb != verb {
				t.Errorf("%s %s resolved to %s %s", noun, verb, cmd.Noun, cmd.Verb)
			}
		}
	}

	// Core nouns must still be present alongside the plugin nouns.
	for _, core := range []string{"doc", "schema", "media", "search"} {
		if _, ok := lookupNoun(tree, core); !ok {
			t.Errorf("core noun %q missing from full manifest tree", core)
		}
	}
}

// TestIngestAuthHeader asserts an ingest-tier command (bulldocs writes) sends
// the ingest secret on the Authorization: Bearer header — NOT the bearer api
// token — and prefers BARKPARK_INGEST_TOKEN over PAPERFLOW_INGEST_TOKEN over
// the resolved api token.
func TestIngestAuthHeader(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	pub, ok := tree.Lookup("bulldocs", "publish")
	if !ok {
		t.Fatal("bulldocs publish missing")
	}
	if pub.AuthTier != "ingest" {
		t.Fatalf("fixture changed: bulldocs publish tier = %q, want ingest", pub.AuthTier)
	}

	ctx := manifest.Context{Token: "api-bearer-tok"}

	t.Run("BARKPARK_INGEST_TOKEN wins", func(t *testing.T) {
		t.Setenv("BARKPARK_INGEST_TOKEN", "bp-ingest")
		t.Setenv("PAPERFLOW_INGEST_TOKEN", "pf-ingest")
		h := authHeaders(*pub, ctx)
		if h["Authorization"] != "Bearer bp-ingest" {
			t.Errorf("Authorization = %q, want Bearer bp-ingest", h["Authorization"])
		}
		if _, leaked := h["X-Ingest-Secret"]; leaked {
			t.Errorf("legacy X-Ingest-Secret header must not be sent: %v", h)
		}
	})

	t.Run("PAPERFLOW_INGEST_TOKEN fallback", func(t *testing.T) {
		t.Setenv("BARKPARK_INGEST_TOKEN", "")
		t.Setenv("PAPERFLOW_INGEST_TOKEN", "pf-ingest")
		h := authHeaders(*pub, ctx)
		if h["Authorization"] != "Bearer pf-ingest" {
			t.Errorf("Authorization = %q, want Bearer pf-ingest", h["Authorization"])
		}
	})

	t.Run("ingest secret is NOT the api bearer token", func(t *testing.T) {
		t.Setenv("BARKPARK_INGEST_TOKEN", "distinct-ingest")
		t.Setenv("PAPERFLOW_INGEST_TOKEN", "")
		h := authHeaders(*pub, ctx)
		if h["Authorization"] == "Bearer api-bearer-tok" {
			t.Errorf("ingest command must not send the api bearer token")
		}
		if h["Authorization"] != "Bearer distinct-ingest" {
			t.Errorf("Authorization = %q, want Bearer distinct-ingest", h["Authorization"])
		}
	})
}

// TestShortFileFlag asserts the -f short form aliases --file for a command that
// declares a file flag (bulldocs patch), and that batch payload binds the same
// way through both forms.
func TestShortFileFlag(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	patch, ok := tree.Lookup("bulldocs", "patch")
	if !ok {
		t.Fatal("bulldocs patch missing")
	}

	pos, flags, err := splitArgs(*patch, []string{"my-slug", "-f", "ops.json"})
	if err != nil {
		t.Fatalf("splitArgs -f: %v", err)
	}
	if !equalStrings(pos, []string{"my-slug"}) {
		t.Errorf("pos = %v, want [my-slug]", pos)
	}
	if got := flags["file"]; len(got) != 1 || got[0] != "ops.json" {
		t.Errorf("-f bound file = %v, want [ops.json]", got)
	}

	// Long form binds identically.
	_, flags2, err := splitArgs(*patch, []string{"my-slug", "--file", "ops.json"})
	if err != nil {
		t.Fatalf("splitArgs --file: %v", err)
	}
	if got := flags2["file"]; len(got) != 1 || got[0] != "ops.json" {
		t.Errorf("--file bound file = %v, want [ops.json]", got)
	}

	// An unknown short flag is rejected, not silently swallowed.
	if _, _, err := splitArgs(*patch, []string{"my-slug", "-z", "x"}); err == nil {
		t.Error("unknown short flag -z: expected error")
	}
}

// --- query-arg + body-arg behaviour ------------------------------------------

// TestApplyQueryArg asserts a declared positional arg that is NOT a path
// placeholder (search.query `q` against /v1/data/search/:dataset) lands in the
// query string, while a placeholder arg (doc.get `type`/`doc_id`) does not.
func TestApplyQueryArg(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	sq, ok := tree.Lookup("search", "query")
	if !ok {
		t.Fatal("search query missing")
	}
	base := "https://api.barkpark.cloud/v1/data/search/production"
	got := applyQuery(base, globals{}, *sq, map[string][]string{}, map[string]string{"q": "headless"})
	if got != base+"?q=headless" {
		t.Errorf("search q query = %q, want %q", got, base+"?q=headless")
	}

	// A path-placeholder arg must NOT leak into the query string.
	dg, _ := tree.Lookup("doc", "get")
	base2 := "https://api.barkpark.cloud/v1/data/doc/production/post/p1"
	got2 := applyQuery(base2, globals{}, *dg, map[string][]string{}, map[string]string{"type": "post", "doc_id": "p1"})
	if got2 != base2 {
		t.Errorf("path args must not become query: got %q", got2)
	}
}

// TestArgLocation exercises the path/query/body inference and the explicit
// arg.In override.
func TestArgLocation(t *testing.T) {
	read := manifest.Command{HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/search/:dataset"}}
	if loc := read.ArgLocation(manifest.Arg{Name: "q"}); loc != "query" {
		t.Errorf("non-path read arg = %q, want query", loc)
	}
	if loc := read.ArgLocation(manifest.Arg{Name: "dataset"}); loc != "path" {
		t.Errorf("placeholder arg = %q, want path", loc)
	}
	write := manifest.Command{Writes: true, HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/webhooks/:dataset"}}
	if loc := write.ArgLocation(manifest.Arg{Name: "url"}); loc != "body" {
		t.Errorf("non-path write arg = %q, want body", loc)
	}
	// Explicit hint wins over inference.
	if loc := write.ArgLocation(manifest.Arg{Name: "url", In: "query"}); loc != "query" {
		t.Errorf("explicit in=query = %q, want query", loc)
	}
}

// TestBuildBodyFromArgs asserts declared body-location args seed the JSON body
// (webhook.create url=…, workspace.project-create name=…), --set merges over
// them, and --file overrides everything.
func TestBuildBodyFromArgs(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	wc, ok := tree.Lookup("webhook", "create")
	if !ok {
		t.Fatal("webhook create missing")
	}
	body, ct, err := buildBody(*wc, map[string][]string{}, map[string]string{"url": "https://hook.example/x"})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if ct != "application/json" {
		t.Errorf("content type = %q", ct)
	}
	var got map[string]any
	if json.Unmarshal(body, &got) != nil || got["url"] != "https://hook.example/x" {
		t.Errorf("webhook body = %s, want url field", body)
	}

	pc, _ := tree.Lookup("workspace", "project-create")
	body2, _, _ := buildBody(*pc, map[string][]string{}, map[string]string{"name": "Marketing"})
	var got2 map[string]any
	if json.Unmarshal(body2, &got2) != nil || got2["name"] != "Marketing" {
		t.Errorf("project-create body = %s, want name field", body2)
	}

	// --set merges over arg-seeded fields.
	body3, _, _ := buildBody(*wc, map[string][]string{"set": {"secret=s3cr3t"}}, map[string]string{"url": "https://hook/x"})
	var got3 map[string]any
	_ = json.Unmarshal(body3, &got3)
	if got3["url"] != "https://hook/x" || got3["secret"] != "s3cr3t" {
		t.Errorf("merged body = %s, want url+secret", body3)
	}
}

// TestBuildBodyMediaMultipart asserts media.upload serialises the file as
// multipart/form-data with a "file" form field, not a JSON body.
func TestBuildBodyMediaMultipart(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	up, ok := tree.Lookup("media", "upload")
	if !ok {
		t.Fatal("media upload missing")
	}

	dir := t.TempDir()
	fp := filepath.Join(dir, "photo.jpg")
	if err := os.WriteFile(fp, []byte("JPEGBYTES"), 0o600); err != nil {
		t.Fatal(err)
	}

	body, ct, err := buildBody(*up, map[string][]string{}, map[string]string{"file": fp})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if !strings.HasPrefix(ct, "multipart/form-data; boundary=") {
		t.Errorf("content type = %q, want multipart/form-data", ct)
	}
	if !bytes.Contains(body, []byte(`name="file"`)) {
		t.Errorf("multipart body missing file field: %s", body)
	}
	if !bytes.Contains(body, []byte("JPEGBYTES")) {
		t.Errorf("multipart body missing file contents")
	}
	if !bytes.Contains(body, []byte(`filename="photo.jpg"`)) {
		t.Errorf("multipart body missing filename")
	}
}

// TestClassifyTaskNotFound covers the regression: a tasks {"ok":false,
// "reason":"not_found","message":"task not found"} response must map to exit 4
// (not found), NOT the blanket exit 2 the ok-false branch used to apply.
func TestClassifyTaskNotFound(t *testing.T) {
	ae := classifyError(404, []byte(`{"message":"task not found","ok":false,"reason":"not_found"}`))
	if ae.exit != exitNotFound {
		t.Errorf("task not_found exit = %d, want %d (not found)", ae.exit, exitNotFound)
	}
	if ae.code != "not_found" {
		t.Errorf("code = %q, want not_found", ae.code)
	}
	if msg := ae.errorMessage(); !strings.Contains(msg, "not found") {
		t.Errorf("message = %q, want a not-found phrasing", msg)
	}

	// The add-edge validation shape stays on exit 2 (unknown reason -> usage).
	ae2 := classifyError(422, []byte(`{"ok":false,"reason":"invalid_edge"}`))
	if ae2.exit != exitUsage {
		t.Errorf("invalid_edge exit = %d, want %d (usage)", ae2.exit, exitUsage)
	}
}

// --- helpers -----------------------------------------------------------------

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
