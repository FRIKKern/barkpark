package cli

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const fixtureManifest = "../../docs/cli/fixtures/core-manifest.json"

func loadFixtureTree(t *testing.T) (*manifest.Manifest, *manifest.Tree) {
	t.Helper()
	body, err := os.ReadFile(filepath.Clean(fixtureManifest))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	m, err := manifest.Parse(body)
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
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

	// flat read (workspace ls has no scoped_prefix) -> no token required.
	wls, _ := tree.Lookup("workspace", "ls")
	if h := authHeaders(*wls, ctx); h["Authorization"] != "" {
		t.Errorf("flat read should not force token: %v", h)
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
