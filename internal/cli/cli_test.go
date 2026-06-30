package cli

import (
	"bytes"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

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
			name:     "--version flag, no noun",
			args:     []string{"--version"},
			wantRest: []string{},
			check: func(t *testing.T, g globals) {
				if !g.version {
					t.Error("--version should set g.version")
				}
			},
		},
		{
			name:     "-V short flag",
			args:     []string{"-V"},
			wantRest: []string{},
			check: func(t *testing.T, g globals) {
				if !g.version {
					t.Error("-V should set g.version")
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

// --- humane hints ------------------------------------------------------------

// TestApiErrorHint asserts the additive hint() suggestion is non-empty for the
// codes that have a useful fix and empty for codes (and the unknown fallback)
// that don't. It must NOT perturb the exit ladder — that is pinned separately by
// TestExitForCode / TestClassifyError.
func TestApiErrorHint(t *testing.T) {
	nonEmpty := []string{
		"not_found", "schema_unknown",
		"validation_failed", "invalid_op", "type_mismatch", "duplicate_id",
		"rev_mismatch", "precondition_failed", "conflict",
		"fenced_off", "stale_claim", "already_claimed",
		"rate_limited", "unauthorized", "forbidden",
	}
	for _, code := range nonEmpty {
		if h := (apiError{code: code}).hint(); h == "" {
			t.Errorf("hint(%q) = empty, want a suggestion", code)
		}
	}

	empty := []string{"", "internal_error", "halted", "totally_unknown"}
	for _, code := range empty {
		if h := (apiError{code: code}).hint(); h != "" {
			t.Errorf("hint(%q) = %q, want empty", code, h)
		}
	}
}

// TestParseTinkerLine pins the REPL line splitter: verb + verbatim remainder,
// with the remainder kept intact so a mutate JSON payload with spaces survives.
func TestParseTinkerLine(t *testing.T) {
	cases := []struct {
		line     string
		wantVerb string
		wantRest string
	}{
		{"", "", ""},
		{"   ", "", ""},
		{"schemas", "schemas", ""},
		{"query post", "query", "post"},
		{"doc post p1", "doc", "post p1"},
		{`mutate {"_id":"x","title":"a b c"}`, "mutate", `{"_id":"x","title":"a b c"}`},
		{"  exit  ", "exit", ""},
	}
	for _, tc := range cases {
		verb, rest, err := parseTinkerLine(tc.line)
		if err != nil {
			t.Errorf("parseTinkerLine(%q) error: %v", tc.line, err)
		}
		if verb != tc.wantVerb || rest != tc.wantRest {
			t.Errorf("parseTinkerLine(%q) = (%q,%q), want (%q,%q)", tc.line, verb, rest, tc.wantVerb, tc.wantRest)
		}
	}
}

// TestTinkerMutateBody asserts a bare document is wrapped in a createOrReplace
// mutation, a body already carrying "mutations" passes through verbatim, and
// invalid/empty JSON yields nil.
func TestTinkerMutateBody(t *testing.T) {
	// Bare doc → wrapped.
	got := tinkerMutateBody(`{"_id":"seed-post-1","_type":"post"}`)
	if got == nil {
		t.Fatal("bare doc returned nil")
	}
	var wrapped map[string]any
	if err := json.Unmarshal(got, &wrapped); err != nil {
		t.Fatalf("wrapped body not JSON: %v", err)
	}
	muts, ok := wrapped["mutations"].([]any)
	if !ok || len(muts) != 1 {
		t.Fatalf("wrapped mutations = %v, want one element", wrapped["mutations"])
	}

	// Already-shaped body passes through.
	shaped := `{"mutations":[{"delete":{"id":"x"}}]}`
	if string(tinkerMutateBody(shaped)) != shaped {
		t.Errorf("shaped body should pass through verbatim")
	}

	// Invalid / empty → nil.
	if tinkerMutateBody("") != nil || tinkerMutateBody("not json") != nil {
		t.Errorf("invalid/empty mutate arg should return nil")
	}
}

func TestValidPerspective(t *testing.T) {
	for _, ok := range []string{"published", "drafts", "raw"} {
		if !validPerspective(ok) {
			t.Errorf("validPerspective(%q) = false, want true", ok)
		}
	}
	for _, bad := range []string{"", "Published", "draft", "all", "live"} {
		if validPerspective(bad) {
			t.Errorf("validPerspective(%q) = true, want false", bad)
		}
	}
}

func TestRenderError(t *testing.T) {
	ae := apiError{exit: exitNotFound, code: "not_found", message: "post xyz", requestID: "req-1"}

	// Non-verbose: message + hint only; no code/request_id noise.
	var so, se bytes.Buffer
	renderError(newWriter(&so, &se), ae)
	s := se.String()
	if !strings.Contains(s, "barkpark: not found: post xyz") {
		t.Errorf("missing message line:\n%s", s)
	}
	if !strings.Contains(s, "hint:") {
		t.Errorf("not_found should carry a hint:\n%s", s)
	}
	if strings.Contains(s, "code:") || strings.Contains(s, "request_id:") {
		t.Errorf("non-verbose output must not show code/request_id:\n%s", s)
	}

	// Verbose: adds the machine code + request id for support.
	var so2, se2 bytes.Buffer
	w := newWriter(&so2, &se2)
	w.verbose = true
	renderError(w, ae)
	s2 := se2.String()
	if !strings.Contains(s2, "code: not_found") || !strings.Contains(s2, "request_id: req-1") {
		t.Errorf("verbose output must show code + request_id:\n%s", s2)
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

func TestApplyQueryBoolFlag(t *testing.T) {
	// A set bool query flag (e.g. `count`) rides as `?name=true`; a client-only
	// bool (`all`) never reaches the server; string flags are unaffected.
	cmd := manifest.Command{
		Noun: "doc", Verb: "query", Paginated: true,
		Flags: []manifest.Flag{
			{Name: "count", Type: "bool"},
			{Name: "all", Type: "bool"},
			{Name: "perspective", Type: "string"},
		},
	}
	base := "https://api.barkpark.cloud/v1/data/query/production/post"
	got := applyQuery(base, globals{}, cmd,
		map[string][]string{"count": {"true"}, "all": {"true"}, "perspective": {"drafts"}},
		map[string]string{})

	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("bad url: %v", err)
	}
	q := u.Query()
	if q.Get("count") != "true" {
		t.Errorf("count flag should ride as ?count=true; got %q", got)
	}
	if q.Get("perspective") != "drafts" {
		t.Errorf("string flag dropped; got %q", got)
	}
	if q.Has("all") {
		t.Errorf("client-only `all` must not be forwarded; got %q", got)
	}

	// Unset bool flag → not present.
	got2 := applyQuery(base, globals{}, cmd, map[string][]string{}, map[string]string{})
	if u2, _ := url.Parse(got2); u2.Query().Has("count") {
		t.Errorf("unset count must be absent; got %q", got2)
	}
}

func TestBuildBodyMutationOp(t *testing.T) {
	// A command with MutationOp wraps its body-arg object into the mutate batch
	// shape; the same command without it builds a flat body.
	cmd := manifest.Command{
		ID: "doc.delete", Noun: "doc", Verb: "delete", Writes: true, MutationOp: "delete",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{
			{Name: "type", Required: true, Type: "string"},
			{Name: "id", Required: true, Type: "string"},
		},
	}
	args := map[string]string{"type": "post", "id": "p1"}

	body, ct, err := buildBody(cmd, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	// Go marshals map keys sorted, so the shape is deterministic.
	if want := `{"mutations":[{"delete":{"id":"p1","type":"post"}}]}`; string(body) != want {
		t.Errorf("mutation body = %s, want %s", body, want)
	}
	if ct != "application/json" {
		t.Errorf("content-type = %q", ct)
	}

	cmd.MutationOp = ""
	flat, _, _ := buildBody(cmd, map[string][]string{}, args)
	if want := `{"id":"p1","type":"post"}`; string(flat) != want {
		t.Errorf("flat body (no MutationOp) = %s, want %s", flat, want)
	}

	// `doc create post --set title=New` → the `type` arg + --set fields merge
	// flat into the create mutation (id auto-generated server-side).
	createCmd := manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
	}
	cbody, _, _ := buildBody(createCmd,
		map[string][]string{"set": {"title=New"}}, map[string]string{"type": "post"})
	if want := `{"mutations":[{"create":{"title":"New","type":"post"}}]}`; string(cbody) != want {
		t.Errorf("create body = %s, want %s", cbody, want)
	}

	// `doc patch post p1 --set title=Updated` → SetKey nests the fields under
	// `set`: {patch: {id, type, set: {…}}} (not a flat merge like create).
	patchCmd := manifest.Command{
		ID: "doc.patch", Noun: "doc", Verb: "patch", Writes: true, MutationOp: "patch", SetKey: "set",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{
			{Name: "type", Required: true, Type: "string"},
			{Name: "id", Required: true, Type: "string"},
		},
	}
	pbody, _, _ := buildBody(patchCmd,
		map[string][]string{"set": {"title=Updated"}}, map[string]string{"type": "post", "id": "p1"})
	if want := `{"mutations":[{"patch":{"id":"p1","set":{"title":"Updated"},"type":"post"}}]}`; string(pbody) != want {
		t.Errorf("patch body = %s, want %s", pbody, want)
	}

	// `doc create-or-replace post --set _id=p1` → flat merge wrapped under the
	// op (same mechanism, a different op string — the upsert verb).
	corCmd := manifest.Command{
		ID: "doc.create-or-replace", Noun: "doc", Verb: "create-or-replace", Writes: true,
		MutationOp: "createOrReplace",
		HTTP:       manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:       []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
	}
	corBody, _, _ := buildBody(corCmd,
		map[string][]string{"set": {"_id=p1"}}, map[string]string{"type": "post"})
	if want := `{"mutations":[{"createOrReplace":{"_id":"p1","type":"post"}}]}`; string(corBody) != want {
		t.Errorf("create-or-replace body = %s, want %s", corBody, want)
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

// TestBuildBodyTaskClaimClose asserts that task.claim and task.close build
// request bodies containing the required worker_id (and observed_epoch for
// close), and that the optional lifecycle_status is included only when supplied.
// doc_id is a path placeholder, so it must NOT appear in the body.
func TestBuildBodyTaskClaimClose(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	claim, ok := tree.Lookup("task", "claim")
	if !ok {
		t.Fatal("task claim missing from full-manifest fixture")
	}
	close, ok := tree.Lookup("task", "close")
	if !ok {
		t.Fatal("task close missing from full-manifest fixture")
	}

	// task claim <doc_id> <worker_id> — doc_id is the path arg, worker_id is body.
	claimArgs := map[string]string{"doc_id": "bd-a1b2.2.3", "worker_id": "paper-agent"}
	body, ct, err := buildBody(*claim, map[string][]string{}, claimArgs)
	if err != nil {
		t.Fatalf("buildBody task claim: %v", err)
	}
	if ct != "application/json" {
		t.Errorf("claim content-type = %q, want application/json", ct)
	}
	var claimObj map[string]any
	if json.Unmarshal(body, &claimObj) != nil {
		t.Fatalf("claim body not valid JSON: %s", body)
	}
	if claimObj["worker_id"] != "paper-agent" {
		t.Errorf("claim body worker_id = %v, want paper-agent; body = %s", claimObj["worker_id"], body)
	}
	if _, leaked := claimObj["doc_id"]; leaked {
		t.Errorf("path arg doc_id must not appear in claim body: %s", body)
	}

	// task close <doc_id> <worker_id> <observed_epoch> — all body args except doc_id.
	closeArgs := map[string]string{"doc_id": "bd-a1b2.2.3", "worker_id": "paper-agent", "observed_epoch": "42"}
	body2, _, err := buildBody(*close, map[string][]string{}, closeArgs)
	if err != nil {
		t.Fatalf("buildBody task close: %v", err)
	}
	var closeObj map[string]any
	if json.Unmarshal(body2, &closeObj) != nil {
		t.Fatalf("close body not valid JSON: %s", body2)
	}
	if closeObj["worker_id"] != "paper-agent" {
		t.Errorf("close body worker_id = %v; body = %s", closeObj["worker_id"], body2)
	}
	if closeObj["observed_epoch"] != "42" {
		t.Errorf("close body observed_epoch = %v; body = %s", closeObj["observed_epoch"], body2)
	}
	if _, leaked := closeObj["doc_id"]; leaked {
		t.Errorf("path arg doc_id must not appear in close body: %s", body2)
	}
	if _, present := closeObj["lifecycle_status"]; present {
		t.Errorf("omitted lifecycle_status must not appear in close body: %s", body2)
	}

	// Optional lifecycle_status is included when supplied as a positional arg.
	closeArgsWithStatus := map[string]string{"doc_id": "bd-a1b2.2.3", "worker_id": "paper-agent", "observed_epoch": "42", "lifecycle_status": "done"}
	body3, _, err := buildBody(*close, map[string][]string{}, closeArgsWithStatus)
	if err != nil {
		t.Fatalf("buildBody task close with status: %v", err)
	}
	var closeObj3 map[string]any
	if json.Unmarshal(body3, &closeObj3) != nil {
		t.Fatalf("close+status body not valid JSON: %s", body3)
	}
	if closeObj3["lifecycle_status"] != "done" {
		t.Errorf("close+status body lifecycle_status = %v; body = %s", closeObj3["lifecycle_status"], body3)
	}
}

// TestBuildBodyTaskNext asserts that task.next (the queue-based atomic claim,
// POST /v1/tasks/claim — no path placeholders) puts worker_id in the body, has
// no doc_id at all, and includes the optional phase_id only when supplied. It
// also pins the URL: /v1/tasks/claim verbatim, nothing interpolated.
func TestBuildBodyTaskNext(t *testing.T) {
	m, tree := loadTreeFrom(t, fullManifest)

	next, ok := tree.Lookup("task", "next")
	if !ok {
		t.Fatal("task next missing from full-manifest fixture")
	}
	if next.HTTP.Method != "POST" || next.HTTP.PathTemplate != "/v1/tasks/claim" {
		t.Fatalf("task next http = %s %s, want POST /v1/tasks/claim", next.HTTP.Method, next.HTTP.PathTemplate)
	}

	// bp task next w1 → body {"worker_id":"w1"}.
	args, err := bindArgs(*next, []string{"w1"})
	if err != nil {
		t.Fatalf("bindArgs task next: %v", err)
	}
	body, ct, err := buildBody(*next, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody task next: %v", err)
	}
	if ct != "application/json" {
		t.Errorf("next content-type = %q, want application/json", ct)
	}
	var obj map[string]any
	if json.Unmarshal(body, &obj) != nil {
		t.Fatalf("next body not valid JSON: %s", body)
	}
	if obj["worker_id"] != "w1" {
		t.Errorf("next body worker_id = %v, want w1; body = %s", obj["worker_id"], body)
	}
	if _, present := obj["doc_id"]; present {
		t.Errorf("task next must not carry doc_id: %s", body)
	}
	if _, present := obj["phase_id"]; present {
		t.Errorf("omitted phase_id must not appear in body: %s", body)
	}

	// Missing required worker_id is a bind error, not a silent empty body.
	if _, err := bindArgs(*next, []string{}); err == nil {
		t.Error("bindArgs accepted missing required worker_id; want error")
	}

	// bp task next w1 ph-1 → phase_id included.
	args2, err := bindArgs(*next, []string{"w1", "ph-1"})
	if err != nil {
		t.Fatalf("bindArgs task next with phase: %v", err)
	}
	body2, _, _ := buildBody(*next, map[string][]string{}, args2)
	var obj2 map[string]any
	_ = json.Unmarshal(body2, &obj2)
	if obj2["phase_id"] != "ph-1" {
		t.Errorf("next body phase_id = %v, want ph-1; body = %s", obj2["phase_id"], body2)
	}

	// The URL is the verbatim flat route — no placeholders to fill.
	ctx := manifest.Context{Server: "http://localhost:4000"}
	url, err := m.BuildURL(*next, ctx, args)
	if err != nil {
		t.Fatalf("BuildURL task next: %v", err)
	}
	if want := "http://localhost:4000/v1/tasks/claim"; url != want {
		t.Errorf("task next url = %q, want %q", url, want)
	}
}

// TestRenderMinimalOkFalse pins the empty-queue receipt: the tasks queue-claim
// returns {"ok":false,"reason":"no_ready"} with HTTP 200, which rides the 2xx
// success path. Minimal output must surface the reason token — NOT the bare
// "ok" receipt, which would be indistinguishable from a successful claim.
func TestRenderMinimalOkFalse(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"

	renderMinimal(w, []byte(`{"ok":false,"reason":"no_ready"}`))
	if got := strings.TrimSpace(stdout.String()); got != "no_ready" {
		t.Errorf("minimal ok:false output = %q, want no_ready", got)
	}

	// ok:false with no reason still must not print "ok".
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":false}`))
	if got := strings.TrimSpace(stdout.String()); got != "not ok" {
		t.Errorf("minimal ok:false (no reason) output = %q, want \"not ok\"", got)
	}

	// ok:true WITHOUT a doc keeps today's bare-ok receipt path untouched.
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true}`))
	if got := strings.TrimSpace(stdout.String()); got != "ok" {
		t.Errorf("minimal ok:true (no doc) output = %q, want ok", got)
	}
}

// TestRenderMinimalDocReceipt pins the claim-shaped success receipt: a 2xx
// {"ok":true,"doc":{…}} body prints the doc's identifying line instead of a
// bare "ok" — the caller needs the doc_id (and the fencing epoch, when the doc
// carries a claim) to act on what it just claimed. Shape-keyed: no task
// special-casing anywhere in the renderer.
func TestRenderMinimalDocReceipt(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"

	// Claim-shaped doc (task next / task claim success): doc_id + epoch.
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"drafts.task-992199","rev":7,"claim":{"worker":"agent-1","ts_iso":"2026-06-10T08:00:00Z","epoch":2}}}`))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-992199 epoch=2" {
		t.Errorf("claim receipt = %q, want \"drafts.task-992199 epoch=2\"", got)
	}

	// Doc without a claim: just the id line.
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"drafts.task-1","title":"x"}}`))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-1" {
		t.Errorf("no-claim receipt = %q, want \"drafts.task-1\"", got)
	}

	// Doc with a claim that lacks an epoch: id only, no dangling "epoch=".
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"drafts.task-2","claim":{"worker":"a1"}}}`))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-2" {
		t.Errorf("claim-without-epoch receipt = %q, want \"drafts.task-2\"", got)
	}

	// Doc with no recognisable id falls through to the generic receipt ("ok").
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"title":"anonymous"}}`))
	if got := strings.TrimSpace(stdout.String()); got != "ok" {
		t.Errorf("id-less doc receipt = %q, want fall-through ok", got)
	}

	// A doc whose only id key is "id" (no doc_id) still receipts.
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"id":"3f1c0d4e"}}`))
	if got := strings.TrimSpace(stdout.String()); got != "3f1c0d4e" {
		t.Errorf("id-fallback receipt = %q, want \"3f1c0d4e\"", got)
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

// --- -s name resolution ------------------------------------------------------

// clearBarkparkEnv unsets the BARKPARK_* vars so resolveContext reads purely from
// the seeded config + flags (env would otherwise win and mask the test).
func clearBarkparkEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{"BARKPARK_API_URL", "BARKPARK_SERVER", "BARKPARK_API_TOKEN", "BARKPARK_WORKSPACE", "BARKPARK_PROJECT", "BARKPARK_DATASET"} {
		t.Setenv(k, "")
	}
}

func TestResolveContextNamedServer(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)

	cfg := &Config{
		Server:    "http://localhost:4000",
		Token:     "dev",
		Workspace: "default", Project: "default", Dataset: "production",
		KnownServers: []ServerEntry{
			{Server: "http://localhost:4000", Token: "dev", Workspace: "default", Project: "default", Dataset: "production"},
			{Name: "cloud", Server: "https://api.barkpark.cloud", Token: "tok-cloud", Workspace: "default", Project: "default", Dataset: "staging"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	// -s cloud → resolves URL + carries token + scope.
	ctx := resolveContext(globals{server: "cloud"})
	if ctx.Server != "https://api.barkpark.cloud" {
		t.Errorf("-s cloud server = %q, want the cloud URL", ctx.Server)
	}
	if ctx.Token != "tok-cloud" {
		t.Errorf("-s cloud token = %q, want carried token", ctx.Token)
	}
	if ctx.Dataset != "staging" {
		t.Errorf("-s cloud dataset = %q, want staging", ctx.Dataset)
	}

	// -s local (derived name) → resolves the unnamed localhost entry.
	if ctx := resolveContext(globals{server: "local"}); ctx.Server != "http://localhost:4000" {
		t.Errorf("-s local server = %q, want localhost", ctx.Server)
	}

	// Explicit -d overrides the named server's saved dataset (precedence).
	if ctx := resolveContext(globals{server: "cloud", dataset: "production"}); ctx.Dataset != "production" {
		t.Errorf("explicit -d should win, got %q", ctx.Dataset)
	}

	// Explicit --token overrides the named server's saved token.
	if ctx := resolveContext(globals{server: "cloud", token: "override"}); ctx.Token != "override" {
		t.Errorf("explicit --token should win, got %q", ctx.Token)
	}

	// An unknown -s value is treated as a raw URL (today's behaviour).
	if ctx := resolveContext(globals{server: "https://raw.example.com"}); ctx.Server != "https://raw.example.com" {
		t.Errorf("unknown -s should pass through as raw URL, got %q", ctx.Server)
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

// TestRenderListEnvelopes pins the list-envelope unwrap across the API's three
// row keys — query "documents", tasks "docs", media "assets". Before this,
// table output crammed the whole array into one key/value cell and minimal
// printed a bare "ok" (valid output, zero information). Minimal must print
// exactly ONE id line per row, preferring the actionable key: _id (documents),
// doc_id (task rows — their "id" is the row uuid; every task verb takes
// doc_id), then id (media assets).
func TestRenderListEnvelopes(t *testing.T) {
	cases := []struct {
		name     string
		payload  string
		wantIDs  []string
		tableHas string
	}{
		{
			name:     "documents",
			payload:  `{"documents":[{"_id":"p1","title":"A"},{"_id":"drafts.p2","title":"B"}],"count":2}`,
			wantIDs:  []string{"id: p1", "id: drafts.p2"},
			tableHas: "p1",
		},
		{
			name:     "task docs prefer doc_id over row uuid",
			payload:  `{"ok":true,"docs":[{"id":"11111111-0000-0000-0000-000000000000","doc_id":"drafts.task-1","title":"T"}]}`,
			wantIDs:  []string{"id: drafts.task-1"},
			tableHas: "drafts.task-1",
		},
		{
			name:     "media assets",
			payload:  `{"assets":[{"id":"asset-uuid-1","filename":"a.png"}],"count":1}`,
			wantIDs:  []string{"id: asset-uuid-1"},
			tableHas: "a.png",
		},
		{
			// ?count=true → the table footer surfaces the full match total.
			name:     "count flag adds a total footer line",
			payload:  `{"documents":[{"_id":"p1","title":"A"}],"count":1,"total":247}`,
			wantIDs:  []string{"id: p1"},
			tableHas: "total: 247",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = "minimal"
			renderMinimal(w, []byte(tc.payload))
			got := strings.TrimSpace(stdout.String())
			want := strings.Join(tc.wantIDs, "\n")
			if got != want {
				t.Errorf("minimal output = %q, want %q", got, want)
			}

			var tout, terr bytes.Buffer
			tw := newWriter(&tout, &terr)
			tw.output = "table"
			renderTable(tw, []byte(tc.payload))
			ts := tout.String()
			if !strings.Contains(ts, tc.tableHas) {
				t.Errorf("table output missing %q:\n%s", tc.tableHas, ts)
			}
			if strings.Contains(ts, `[{"`) {
				t.Errorf("table output still crams the row array into a cell:\n%s", ts)
			}
		})
	}
}

// TestRenderListEnvelopesAdmin pins table rendering for the admin/tenancy list
// commands — workspace.ls, workspace.project-ls, schema.ls, webhook.ls,
// plugin.ls, share.ls. Each carries its rows under its own envelope key; a key
// missing from listEnvelopeKeys made renderTable fall through to renderKV and
// cram the whole array into ONE cell (valid output, zero information). Each case
// asserts the table surfaces a row value AND does not stringify the array into a
// cell (`[{"`).
func TestRenderListEnvelopesAdmin(t *testing.T) {
	cases := []struct {
		name        string
		payload     string
		tableHas    string
		wantMinimal string // one id line per row; name/scope cover the id-less admin rows
	}{
		{
			name:        "workspaces",
			payload:     `{"workspaces":[{"id":"w1","slug":"acme","name":"Acme"}]}`,
			tableHas:    "acme",
			wantMinimal: "id: w1",
		},
		{
			name:        "projects (alongside a workspace object)",
			payload:     `{"workspace":{"slug":"acme"},"projects":[{"id":"p1","slug":"blog","name":"Blog"}]}`,
			tableHas:    "blog",
			wantMinimal: "id: p1",
		},
		{
			name:        "schemas (alongside datasetSchemaHash)",
			payload:     `{"schemas":[{"name":"post","title":"Post"}],"datasetSchemaHash":"abc123"}`,
			tableHas:    "post",
			wantMinimal: "id: post", // no id key → name fallback
		},
		{
			name:        "webhooks",
			payload:     `{"webhooks":[{"id":"wh1","url":"https://example.com/hook"}]}`,
			tableHas:    "wh1",
			wantMinimal: "id: wh1",
		},
		{
			name:        "plugins",
			payload:     `{"plugins":[{"name":"onixedit","enabled":true}]}`,
			tableHas:    "onixedit",
			wantMinimal: "id: onixedit", // no id key → name fallback
		},
		{
			name:        "shares (alongside active)",
			payload:     `{"shares":[{"scope":"acme/blog/production","surfaces":"docs"}],"active":true}`,
			tableHas:    "acme/blog/production",
			wantMinimal: "id: acme/blog/production", // no id key → scope fallback
		},
		{
			name:        "collections (media.collections)",
			payload:     `{"collections":[{"id":"c1","title":"Brand","kind":"folder"}],"count":1}`,
			tableHas:    "Brand",
			wantMinimal: "id: c1",
		},
		{
			name:        "hits (media.collection-assets, alongside collectionId/total)",
			payload:     `{"collectionId":"c1","hits":[{"_id":"a1","url":"https://cdn/a1.png"}],"total":1}`,
			tableHas:    "a1",
			wantMinimal: "id: a1",
		},
		{
			name:        "backlinks (doc.backlinks, alongside count)",
			payload:     `{"backlinks":[{"from_doc_id":"art-1","title":"Refs Target","type":"article"}],"count":1}`,
			tableHas:    "Refs Target",
			wantMinimal: "id: art-1", // no _id/id key → from_doc_id fallback
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var tout, terr bytes.Buffer
			tw := newWriter(&tout, &terr)
			tw.output = "table"
			renderTable(tw, []byte(tc.payload))
			ts := tout.String()
			if !strings.Contains(ts, tc.tableHas) {
				t.Errorf("table output missing %q:\n%s", tc.tableHas, ts)
			}
			if strings.Contains(ts, `[{"`) {
				t.Errorf("table output still crams the row array into a cell:\n%s", ts)
			}

			var mout, merr bytes.Buffer
			mw := newWriter(&mout, &merr)
			mw.output = "minimal"
			renderMinimal(mw, []byte(tc.payload))
			ms := strings.TrimSpace(mout.String())
			if ms != tc.wantMinimal {
				t.Errorf("minimal output = %q, want %q", ms, tc.wantMinimal)
			}
		})
	}
}

// TestRenderSingleObjectEnvelope pins that a single-object GET ({webhook: {...}},
// {schema: {...}}) renders the inner object's fields rather than cramming the
// object into one "webhook"/"schema" cell. Without the unwrap, renderKV
// stringifies the object (`{"`), so its fields are invisible — the same "valid
// output, zero information" failure as the list-envelope case, for single reads.
func TestRenderSingleObjectEnvelope(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		has     string
	}{
		{"webhook.get", `{"webhook":{"id":"w1","url":"https://x.test/hook"}}`, "https://x.test/hook"},
		{"schema.get (with _schemaVersion meta)", `{"_schemaVersion":1,"schema":{"name":"post","title":"Post"}}`, "post"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out, errb bytes.Buffer
			w := newWriter(&out, &errb)
			w.output = "table"
			renderTable(w, []byte(tc.payload))
			s := out.String()
			if !strings.Contains(s, tc.has) {
				t.Errorf("table output missing %q:\n%s", tc.has, s)
			}
			if strings.Contains(s, `{"`) {
				t.Errorf("object crammed into a cell (not unwrapped):\n%s", s)
			}
		})
	}
}

// TestCellStringRuneSafeTruncation pins that a long nested-value cell is capped
// on a RUNE boundary, not a byte one. Byte slicing (s[:57]) would split a
// multibyte rune and emit invalid UTF-8 — a stray � in the table.
func TestCellStringRuneSafeTruncation(t *testing.T) {
	// JSON of this is `{"title":"øøø…"}` — well over 60 runes, every ø is 2 bytes,
	// and with this key the 57th byte lands MID-rune (verified: the old s[:57]
	// byte slice produces invalid UTF-8 here, so this case is protective).
	nested := map[string]any{"title": strings.Repeat("ø", 80)}
	s := cellString(nested)

	if !utf8.ValidString(s) {
		t.Errorf("cellString emitted invalid UTF-8 (rune split): %q", s)
	}
	if !strings.HasSuffix(s, "...") {
		t.Errorf("expected truncation marker, got %q", s)
	}
	if n := utf8.RuneCountInString(s); n != 60 { // 57 runes + "..."
		t.Errorf("truncated to %d runes, want 60", n)
	}
}

// TestRenderTableRuneWidth pins that column widths are measured in display runes,
// not bytes — a Norwegian title must not over-pad its column. "Håndbok" is 7
// runes / 8 bytes, so the separator under it is 7 dashes, not 8.
func TestRenderTableRuneWidth(t *testing.T) {
	payload := `{"documents":[{"_id":"p1","title":"Håndbok"}]}`
	var out, errb bytes.Buffer
	w := newWriter(&out, &errb)
	w.output = "table"
	renderTable(w, []byte(payload))
	s := out.String()

	if !utf8.ValidString(s) {
		t.Errorf("table output is not valid UTF-8: %q", s)
	}
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected header + separator, got: %q", s)
	}
	// Separator (line 2) = id column dashes + "  " + title column dashes.
	// Rune width: _id col = 3 ("_id" > "p1"), title col = 7 ("Håndbok"). Total
	// dashes = 10. A byte width would make the title column 8 → 11 dashes.
	if dashes := strings.Count(lines[1], "-"); dashes != 10 {
		t.Errorf("separator has %d dashes, want 10 (rune width); bytes give 11: %q", dashes, lines[1])
	}
}

// TestRenderMinimalWorkspaceProjectSlug pins the create receipts: the -w/-p
// globals take SLUGS, so {"workspace":{…}}/{"project":{…}} must print the
// slug — a bare "ok" forced a second call just to learn the handle.
func TestRenderMinimalWorkspaceProjectSlug(t *testing.T) {
	for payload, want := range map[string]string{
		`{"workspace":{"id":"u1","name":"Spike","slug":"spike"}}`:       "workspace: spike",
		`{"project":{"id":"u2","name":"agents-v2","slug":"agents-v2"}}`: "project: agents-v2",
	} {
		var stdout, stderr bytes.Buffer
		w := newWriter(&stdout, &stderr)
		w.output = "minimal"
		renderMinimal(w, []byte(payload))
		if got := strings.TrimSpace(stdout.String()); got != want {
			t.Errorf("minimal %s = %q, want %q", payload, got, want)
		}
	}
}

// Typed --set (httpie's := convention, 2026-06-12): key:=raw-json sends the
// JSON value verbatim — the server's patch path merges with no coercion, so
// `--set priority=3` stores the STRING "3" (task validators 422 it). Plain
// key=value stays a string; type is the caller's explicit choice, never
// sniffed from the value.
func TestBuildBodyTypedSet(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)
	wc, _ := tree.Lookup("webhook", "create")

	body, _, err := buildBody(*wc, map[string][]string{"set": {
		"priority:=3",
		"featured:=true",
		"tags:=[\"a\",\"b\"]",
		"note=42",
	}}, map[string]string{})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("parse body: %v", err)
	}
	if v, ok := got["priority"].(float64); !ok || v != 3 {
		t.Errorf("priority = %#v, want the JSON number 3", got["priority"])
	}
	if v, ok := got["featured"].(bool); !ok || !v {
		t.Errorf("featured = %#v, want the JSON boolean true", got["featured"])
	}
	if arr, ok := got["tags"].([]any); !ok || len(arr) != 2 || arr[0] != "a" {
		t.Errorf("tags = %#v, want a real array", got["tags"])
	}
	// Plain = stays a string even when the value looks numeric.
	if got["note"] != "42" {
		t.Errorf("note = %#v, want the string \"42\"", got["note"])
	}

	// Invalid JSON after := errors with guidance instead of sending garbage.
	_, _, err = buildBody(*wc, map[string][]string{"set": {"priority:=three"}}, map[string]string{})
	if err == nil || !strings.Contains(err.Error(), "not valid JSON") {
		t.Errorf("bad := value should error with guidance, got %v", err)
	}
}
