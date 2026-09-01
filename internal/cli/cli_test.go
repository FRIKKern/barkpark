package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
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
			name:     "zero pagination values parse cleanly",
			args:     []string{"doc", "ls", "post", "--limit", "0", "--offset", "0"},
			wantRest: []string{"doc", "ls", "post"},
			check: func(t *testing.T, g globals) {
				if g.limit != 0 || !g.limitSet {
					t.Errorf("limit = %d set=%v", g.limit, g.limitSet)
				}
				if g.offset != 0 || !g.offsetSet {
					t.Errorf("offset = %d set=%v", g.offset, g.offsetSet)
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
		{"-o", "bogus", "doc", "ls"},            // invalid output
		{"--limit", "notanint", "doc"},          // bad int
		{"--limit", "-1", "doc", "ls", "post"},  // negative limit
		{"--offset", "-1", "doc", "ls", "post"}, // negative offset
		{"-s"},                                  // value flag without value
		{"--dry-run=false", "doc", "mutate"},    // inline value on a bool flag
	}
	for _, args := range cases {
		if _, _, err := parseGlobals(args); err == nil {
			t.Errorf("parseGlobals(%v): expected error, got nil", args)
		}
	}
}

// A value-taking global flag (-o, -s, --token, ...) followed by another
// KNOWN global flag must never bind that flag as its value — it must report
// the same "flag needs a value" usage error the end-of-args case reports,
// not a confusing downstream error like invalid --output "-v". Fails before
// the fix: parseGlobals used to consume the following flag as the value,
// surfacing the enum-validation error for -o/--output instead.
func TestParseGlobalsFlagShapedValueRejected(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"-o then -s", []string{"-o", "-s", "doc", "ls"}},
		{"--token then --output", []string{"--token", "--output", "doc", "ls"}},
		{"-s then -v (bool global)", []string{"-s", "-v", "doc", "ls"}},
		{"--limit then --offset", []string{"--limit", "--offset", "doc", "ls"}},
		{"--manifest then --json", []string{"--manifest", "--json", "doc", "ls"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := parseGlobals(tc.args)
			if err == nil {
				t.Fatalf("parseGlobals(%v): expected error, got nil", tc.args)
			}
			if !strings.Contains(err.Error(), "needs a value") {
				t.Errorf("parseGlobals(%v) error = %q, want it to mention \"needs a value\"", tc.args, err.Error())
			}
			if strings.Contains(err.Error(), "invalid --output") {
				t.Errorf("parseGlobals(%v) leaked the downstream enum error: %q", tc.args, err.Error())
			}
		})
	}
}

// A value that merely starts with '-' but is NOT itself a known global flag
// (an unrecognised long flag, a negative-looking string) is still a
// legitimate value and must bind normally rather than being rejected.
func TestParseGlobalsDashShapedNonFlagValueStillBinds(t *testing.T) {
	g, _, err := parseGlobals([]string{"--token", "-abc123", "doc", "ls"})
	if err != nil {
		t.Fatalf("parseGlobals: unexpected error: %v", err)
	}
	if g.token != "-abc123" {
		t.Errorf("token = %q, want -abc123", g.token)
	}
}

// An inline value on the --yes bool flag must be a usage error, never a
// silently-ignored token: `--yes=false` previously set g.yes=true, skipping the
// prod write-guard — the exact opposite of the caller's intent.
func TestParseGlobalsBoolInlineValueRejected(t *testing.T) {
	g, _, err := parseGlobals([]string{"--yes=false", "doc", "mutate"})
	if err == nil {
		t.Fatalf("parseGlobals(--yes=false): expected error, got nil (yes=%v)", g.yes)
	}
	if g.yes {
		t.Errorf("g.yes must not be set when --yes=false errors, got true")
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

	// (a) An empty-string value for a required positional counts as absent and
	// yields the friendly missing-arg error, not a present-but-empty bind that
	// blows up later as an unresolved URL placeholder.
	_, err = bindArgs(*get, []string{"post", ""})
	if err == nil {
		t.Fatalf("empty required doc_id: expected missing-arg error")
	}
	if want := "missing required argument <doc_id> for doc get"; err.Error() != want {
		t.Errorf("empty required error = %q, want %q", err.Error(), want)
	}

	// (b) An empty-string value for an OPTIONAL positional binds as absent — no
	// map key — so downstream consumers (which all guard `ok && v != ""`) see
	// exactly the same shape as if the arg were omitted. Zero wire change.
	optCmd := manifest.Command{
		Noun: "doc",
		Verb: "ls",
		Args: []manifest.Arg{{Name: "type", Required: false}},
	}
	m, err = bindArgs(optCmd, []string{""})
	if err != nil {
		t.Fatalf("empty optional positional: unexpected error %v", err)
	}
	if _, ok := m["type"]; ok {
		t.Errorf("empty optional should be absent, got map %v", m)
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

func TestBuildManifestRequestAuthenticatesNonPublishedPerspective(t *testing.T) {
	m, tree := loadFixtureTree(t)
	baseCtx := manifest.Context{
		Server:  "https://api.barkpark.cloud",
		Dataset: "production",
		Token:   "draft-reader-token",
	}

	for _, verb := range []string{"ls", "query"} {
		verb := verb
		cmd, ok := tree.Lookup("doc", verb)
		if !ok {
			t.Fatalf("doc %s missing", verb)
		}
		cmd.AuthTier = "none"
		cmd.Flags = append(cmd.Flags, manifest.Flag{Name: "perspective", Type: "string"})

		for _, perspective := range []string{"drafts", "raw"} {
			perspective := perspective
			t.Run(verb+"_"+perspective, func(t *testing.T) {
				req, derr := buildManifestRequest(
					globals{}, baseCtx, m, *cmd,
					[]string{"post", "--perspective", perspective},
					false,
				)
				if derr != nil {
					t.Fatalf("buildManifestRequest: %v", derr)
				}
				if got := req.headers["Authorization"]; got != "Bearer draft-reader-token" {
					t.Errorf("Authorization = %q, want bearer for %s perspective", got, perspective)
				}
			})
		}

		t.Run(verb+"_published_stays_public", func(t *testing.T) {
			req, derr := buildManifestRequest(
				globals{}, baseCtx, m, *cmd,
				[]string{"post", "--perspective", "published"},
				false,
			)
			if derr != nil {
				t.Fatalf("buildManifestRequest: %v", derr)
			}
			if got := req.headers["Authorization"]; got != "" {
				t.Errorf("published Authorization = %q, want public request unchanged", got)
			}
		})
	}
}

func TestBuildManifestRequestRejectsNonPublishedPerspectiveWithoutToken(t *testing.T) {
	m, tree := loadFixtureTree(t)
	cmd, ok := tree.Lookup("doc", "ls")
	if !ok {
		t.Fatal("doc ls missing")
	}
	cmd.AuthTier = "none"
	cmd.Flags = append(cmd.Flags, manifest.Flag{Name: "perspective", Type: "string"})

	_, derr := buildManifestRequest(
		globals{},
		manifest.Context{Server: "https://api.barkpark.cloud", Dataset: "production"},
		m,
		*cmd,
		[]string{"post", "--perspective", "drafts"},
		false,
	)
	if derr == nil {
		t.Fatal("drafts perspective without token must fail loudly")
	}
	if !strings.Contains(derr.Error(), "requires an API token") {
		t.Fatalf("error = %q, want requires an API token", derr)
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
		"forbidden_field":     exitAuth, // filter/order on an unreadable field (#571)
		"malformed":           exitUsage,
		"invalid_filter":      exitUsage, // unknown filter operator = malformed request (#570)
		"validation_failed":   exitValidation,
		"invalid_paper":       exitValidation,
		"invalid_op":          exitValidation,
		"rev_mismatch":        exitConflict,
		"precondition_failed": exitConflict,
		"conflict":            exitConflict,
		// Canonical halt envelope (#559/#560) — must map via error.code, not just
		// the bare-string special-case, else it regressed to the exit-1 fallback.
		"halted":          exitConflict,
		"rate_limited":    exitRateLimit,
		"internal_error":  exitServer,
		"totally_unknown": exitGeneric, // fallback
		"":                exitGeneric,
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
		// Canonical envelopes for the codes added when the server moved these off
		// bare-string / fail-open shapes — each must resolve via error.code.
		{"canonical halted", `{"error":{"code":"halted","message":"lifecycle veto"}}`, exitConflict, "halted"},
		{"canonical invalid_filter", `{"error":{"code":"invalid_filter","message":"unknown op"}}`, exitUsage, "invalid_filter"},
		{"canonical forbidden_field", `{"error":{"code":"forbidden_field","message":"unreadable field"}}`, exitAuth, "forbidden_field"},
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

// TestClassifyErrorStatusKeyedNonJSON pins the status-keyed fallback: a non-JSON
// gateway/proxy body (nginx 5xx HTML, plain-text banner) can carry no `code`, so
// classifyError must key the exit bucket off the HTTP status instead of blanket
// exitGeneric — AND cap a huge body so an HTML page never spews to stderr.
func TestClassifyErrorStatusKeyedNonJSON(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   int
	}{
		{"503 gateway html", 503, "<html><body>503 Service Temporarily Unavailable</body></html>", exitServer},
		{"502 bad gateway", 502, "502 Bad Gateway", exitServer},
		{"504 timeout", 504, "upstream timed out", exitServer},
		{"429 plain", 429, "Too Many Requests", exitRateLimit},
		{"401 plain", 401, "Unauthorized", exitAuth},
		{"404 plain", 404, "Not Found", exitNotFound},
		{"400 plain", 400, "Bad Request", exitUsage},
		{"status 0 unknown", 0, "garbage", exitGeneric},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ae := classifyError(tc.status, []byte(tc.body))
			if ae.exit != tc.want {
				t.Errorf("classifyError(%d, %q).exit = %d, want %d", tc.status, tc.body, ae.exit, tc.want)
			}
		})
	}

	// A multi-KB HTML page must be capped, not dumped verbatim.
	big := "<html>" + strings.Repeat("x", 5000) + "</html>"
	ae := classifyError(502, []byte(big))
	if ae.exit != exitServer {
		t.Errorf("big 502 body: exit = %d, want %d", ae.exit, exitServer)
	}
	if r := []rune(ae.message); len(r) > 210 { // 200 + ellipsis + slack
		t.Errorf("body not capped: message is %d runes:\n%s", len(r), ae.message)
	}
	if !strings.HasSuffix(ae.message, "…") {
		t.Errorf("capped message should end with an ellipsis, got: %q", ae.message)
	}

	// A GENUINELY-JSON error must still route via its code AND keep its full
	// message — the cap only ever touches the opaque non-envelope fallback.
	longMsg := strings.Repeat("field is required and must match the pattern; ", 20)
	je := classifyError(422, []byte(`{"error":{"code":"validation_failed","message":"`+longMsg+`"}}`))
	if je.exit != exitValidation {
		t.Errorf("json 422: exit = %d, want %d", je.exit, exitValidation)
	}
	if je.message != longMsg {
		t.Errorf("json error message was truncated:\ngot:  %q\nwant: %q", je.message, longMsg)
	}
}

// TestUsageErrfJSONEnvelope pins the machine-output parity for built-in usage
// errors: under -o json, usageErrf emits a parseable {ok:false,error:{code:
// "usage"}} envelope on stdout (not empty stdout) and suppresses the human
// stderr line + usageHelp; under table, it prints the human line and runs
// usageHelp. Exit is always exitUsage.
func TestUsageErrfJSONEnvelope(t *testing.T) {
	// json mode: parseable envelope on stdout, no human leak, usageHelp skipped.
	var so, se bytes.Buffer
	wj := newWriter(&so, &se)
	wj.output = "json"
	helpRan := false
	code := usageErrf(wj, func() { helpRan = true }, "unknown command %q", "bogus")
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if strings.Contains(se.String(), "bp:") {
		t.Errorf("json path leaked human stderr line:\n%s", se.String())
	}
	if helpRan {
		t.Errorf("usageHelp must be suppressed in machine mode")
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("json stdout is not parseable: %v\n%s", err, so.String())
	}
	if env.OK || env.Error.Code != "usage" || env.Error.Message == "" {
		t.Errorf("bad usage envelope:\n%s", so.String())
	}

	// table mode: human stderr line + usageHelp, nothing on stdout.
	var so2, se2 bytes.Buffer
	wt := newWriter(&so2, &se2)
	wt.output = "table"
	helpRan = false
	_ = usageErrf(wt, func() { helpRan = true }, "unknown command %q", "bogus")
	if !strings.Contains(se2.String(), "bp: unknown command") {
		t.Errorf("table mode should print the human line, got:\n%s", se2.String())
	}
	if !helpRan {
		t.Errorf("table mode should run usageHelp")
	}
	if so2.Len() != 0 {
		t.Errorf("table-mode usage error must not write stdout:\n%s", so2.String())
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
		"fenced_off", "stale_claim", "already_claimed", "not_ready", "doc_changed_since_claim",
		"rate_limited", "unauthorized", "forbidden",
	}
	for _, code := range nonEmpty {
		if h := (apiError{code: code}).hint(); h == "" {
			t.Errorf("hint(%q) = empty, want a suggestion", code)
		}
	}

	// not_ready is split from the stale-epoch bucket: a targeted claim on a task
	// another worker holds (or one that is done/cancelled/blocked) is not a stale
	// claim, so its hint must be its own copy — not the fenced_off/stale one.
	if fenced, notReady := (apiError{code: "fenced_off"}).hint(), (apiError{code: "not_ready"}).hint(); fenced == notReady {
		t.Errorf("not_ready shares the stale-epoch hint %q — it needs its own copy", notReady)
	}
	if h := (apiError{code: "not_ready"}).hint(); !strings.Contains(h, "isn't claimable") {
		t.Errorf("not_ready hint = %q, want the not-claimable copy", h)
	}

	empty := []string{"", "internal_error", "halted", "totally_unknown"}
	for _, code := range empty {
		if h := (apiError{code: code}).hint(); h != "" {
			t.Errorf("hint(%q) = %q, want empty", code, h)
		}
	}

	// The server's per-error hint takes precedence over the local map, and lets a
	// code with NO local case (e.g. a new mfa_required) still surface a hint.
	withServer := apiError{code: "mfa_required", serverHint: "enter your TOTP code and retry"}
	if h := withServer.hint(); h != "enter your TOTP code and retry" {
		t.Errorf("server hint not preferred: hint() = %q", h)
	}
	overrides := apiError{code: "not_found", serverHint: "the bound dataset has no such id"}
	if h := overrides.hint(); h != "the bound dataset has no such id" {
		t.Errorf("server hint should override the local map: hint() = %q", h)
	}
	// No server hint → fall back to the local map (back-compat).
	if h := (apiError{code: "not_found"}).hint(); h == "" || h == "the bound dataset has no such id" {
		t.Errorf("absent server hint should fall back to the local map, got %q", h)
	}
}

func TestClassifyErrorCapturesServerHint(t *testing.T) {
	ae := classifyError(422, []byte(`{"error":{"code":"invalid_code","message":"bad TOTP","hint":"codes expire in 30s — re-read the app"}}`))
	if ae.serverHint != "codes expire in 30s — re-read the app" {
		t.Errorf("classifyError did not capture the envelope hint: %q", ae.serverHint)
	}
	if h := ae.hint(); h != "codes expire in 30s — re-read the app" {
		t.Errorf("hint() should surface the captured server hint, got %q", h)
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
	if !strings.Contains(s, "bp: not found: post xyz") {
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

	// -o json: emit a parseable {ok:false,error:{…}} envelope on STDOUT (not
	// empty stdout + human stderr). This is the manifest error path reaching the
	// same contract the cloud built-ins already use.
	var so3, se3 bytes.Buffer
	wj := newWriter(&so3, &se3)
	wj.output = "json"
	renderError(wj, ae)
	if strings.Contains(se3.String(), "bp:") {
		t.Errorf("json path leaked human stderr line:\n%s", se3.String())
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code      string `json:"code"`
			Message   string `json:"message"`
			RequestID string `json:"request_id"`
			Hint      string `json:"hint"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so3.Bytes(), &env); err != nil {
		t.Fatalf("json stdout is not parseable: %v\n%s", err, so3.String())
	}
	if env.OK {
		t.Errorf("envelope ok must be false:\n%s", so3.String())
	}
	if env.Error.Code != "not_found" || env.Error.RequestID != "req-1" {
		t.Errorf("envelope missing code/request_id:\n%s", so3.String())
	}
	if env.Error.Hint == "" {
		t.Errorf("not_found envelope should carry a hint:\n%s", so3.String())
	}
}

// TestHandleResponseErrorJSONEnvelope drives the full manifest error path
// (handleResponse on a non-2xx body) under -o json and asserts the caller gets a
// parseable {ok:false,error:{code:"not_found"}} envelope on stdout — the bug this
// unifies away was empty stdout that broke `bp doc get missing -o json | jq`.
func TestHandleResponseErrorJSONEnvelope(t *testing.T) {
	body := []byte(`{"error":{"code":"not_found","message":"post xyz","request_id":"req-9"}}`)

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"

	code := handleResponse(w, nil, manifest.Command{}, 404, body)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d", code, exitNotFound)
	}
	if strings.Contains(se.String(), "bp:") {
		t.Errorf("json path leaked human stderr line:\n%s", se.String())
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(so.Bytes(), &env); err != nil {
		t.Fatalf("json stdout is not parseable: %v\n%s", err, so.String())
	}
	if env.OK || env.Error.Code != "not_found" {
		t.Errorf("want ok:false + error.code=not_found, got:\n%s", so.String())
	}

	// table mode keeps the human stderr line and writes nothing to stdout.
	var so2, se2 bytes.Buffer
	wt := newWriter(&so2, &se2)
	wt.output = "table"
	handleResponse(wt, nil, manifest.Command{}, 404, body)
	if so2.Len() != 0 {
		t.Errorf("table mode must not write stdout:\n%s", so2.String())
	}
	if !strings.Contains(se2.String(), "bp: not found: post xyz") {
		t.Errorf("table mode missing human stderr line:\n%s", se2.String())
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

	// An OPTIONAL query-arg that was omitted (absent from the bound arg map) must
	// forward NO param — this is what lets `media.search` run a filter-only browse
	// with no `q` (arg("q", false, …)). bindArgs leaves optional omitted args out
	// of the map; applyQuery must then add nothing (guarded by ok && v != "").
	gotOmitted := applyQuery(base, globals{}, *sq, map[string][]string{}, map[string]string{})
	if gotOmitted != base {
		t.Errorf("omitted optional query-arg: got %q, want %q (no ?q=)", gotOmitted, base)
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

	body, _, ct, err := buildBody(cmd, map[string][]string{}, args)
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
	flat, _, _, _ := buildBody(cmd, map[string][]string{}, args)
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
	cbody, _, _, _ := buildBody(createCmd,
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
	pbody, _, _, _ := buildBody(patchCmd,
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
	corBody, _, _, _ := buildBody(corCmd,
		map[string][]string{"set": {"_id=p1"}}, map[string]string{"type": "post"})
	if want := `{"mutations":[{"createOrReplace":{"_id":"p1","type":"post"}}]}`; string(corBody) != want {
		t.Errorf("create-or-replace body = %s, want %s", corBody, want)
	}

	// `media update a1 --set altText="A cat" --set tags:=["pet"]` → a FLAT PATCH
	// body of just the metadata. media.update has NO SetKey and NO MutationOp, so
	// --set merges flat (not nested/wrapped); `id` is a :id PATH arg so it stays
	// out of the body; `tags:=` sends a typed JSON array. This is exactly what the
	// PATCH /v1/media/:dataset/:id route reads via metadata_params.
	mediaCmd := manifest.Command{
		ID: "media.update", Noun: "media", Verb: "update", Writes: true,
		HTTP: manifest.HTTP{Method: "PATCH", PathTemplate: "/v1/media/:dataset/:id"},
		Args: []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
	}
	mbody, _, _, _ := buildBody(mediaCmd,
		map[string][]string{"set": {"altText=A cat", `tags:=["pet"]`}},
		map[string]string{"id": "a1"})
	if want := `{"altText":"A cat","tags":["pet"]}`; string(mbody) != want {
		t.Errorf("media.update flat body = %s, want %s", mbody, want)
	}
}

// Regression (task-bp-create-drops-long-description): a multi-KB, multi-line
// --set description must be threaded VERBATIM into the create mutation — never
// truncated at the first newline, never capped, never dropped. The reported
// failure was a SILENT drop: `bp doc create task` returned success while the
// stored draft had no description, which the publish wall later misdiagnosed as
// a weak label. This pins the whole CLI create pipeline (splitArgs → bindArgs →
// buildBody) so a large description survives BOTH arg tokenisation and body
// assembly, alongside the typed sibling sets (tags, acceptance_criteria) that
// DID land in the report — a byte-for-byte guard, larger than the 5,783 bytes
// that reproduced it.
func TestBuildBodyDocCreateLongMultilineDescription(t *testing.T) {
	createCmd := manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:  []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
	}

	// Embedded newlines, colons, and a ':=' token — the marker that must NOT
	// flip a plain key=value into a typed set. Sized past the reproduced 5,783 B.
	line := "rationale: a task reason with a colon a:b and a := marker, padding padding padding\n"
	desc := "Hit twice during round nine.\n\n" + strings.Repeat(line, 84)
	if len(desc) <= 5783 {
		t.Fatalf("description must exceed the reproduced 5783 bytes, got %d", len(desc))
	}

	tail := []string{
		"task",
		"--set", "_id=task-x",
		"--set", "title=ReproTitle",
		"--set", "description=" + desc,
		"--set", `tags:=[{"tag":"cli"}]`,
		"--set", `acceptance_criteria:=[{"criterion":"c1","met":false}]`,
	}
	pos, flags, err := splitArgs(createCmd, tail)
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	args, err := bindArgs(createCmd, pos)
	if err != nil {
		t.Fatalf("bindArgs: %v", err)
	}
	body, _, _, err := buildBody(createCmd, flags, args)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}

	var payload struct {
		Mutations []struct {
			Create map[string]any `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	if len(payload.Mutations) != 1 {
		t.Fatalf("mutations = %d, want 1", len(payload.Mutations))
	}
	create := payload.Mutations[0].Create

	got, ok := create["description"].(string)
	if !ok {
		keys := make([]string, 0, len(create))
		for k := range create {
			keys = append(keys, k)
		}
		t.Fatalf("description absent from create body (silent drop) — keys present: %v", keys)
	}
	if got != desc {
		t.Fatalf("description not verbatim: got %d bytes, want %d bytes", len(got), len(desc))
	}
	// The siblings that landed in the report must still land.
	if _, ok := create["tags"].([]any); !ok {
		t.Errorf("tags dropped or mistyped: %#v", create["tags"])
	}
	if _, ok := create["acceptance_criteria"].([]any); !ok {
		t.Errorf("acceptance_criteria dropped or mistyped: %#v", create["acceptance_criteria"])
	}
	if create["type"] != "task" {
		t.Errorf("type = %v, want task", create["type"])
	}
}

func TestBuildBodyDocCreateFileMergeAndDryRun(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "doc.json")
	if err := os.WriteFile(path, []byte(`{"title":"from-file","type":"wrong","nested":{"ok":true}}`), 0o600); err != nil {
		t.Fatalf("write document body: %v", err)
	}

	cmd := manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "file", Type: "file"},
			{Name: "set", Type: "string", Repeatable: true},
		},
	}

	body, _, contentType, err := buildBody(cmd, map[string][]string{
		"file": {path},
		"set":  {"title=first-set", "count:=2", "title=last-set"},
	}, map[string]string{"type": "paper"})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if contentType != "application/json" {
		t.Fatalf("content type = %q, want application/json", contentType)
	}
	if want := `{"mutations":[{"create":{"count":2,"nested":{"ok":true},"title":"last-set","type":"paper"}}]}`; string(body) != want {
		t.Fatalf("request body = %s, want %s", body, want)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if code := dryRun(w, cmd, "https://example.test/v1/data/mutate/production", map[string]string{"Content-Type": contentType}, body); code != exitOK {
		t.Fatalf("dry-run exit = %d, want %d", code, exitOK)
	}
	var preview map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &preview); err != nil {
		t.Fatalf("dry-run JSON: %v\n%s", err, stdout.String())
	}
	mutations := preview["body"].(map[string]any)["mutations"].([]any)
	create := mutations[0].(map[string]any)["create"].(map[string]any)
	if create["title"] != "last-set" || create["type"] != "paper" || create["count"] != float64(2) {
		t.Fatalf("dry-run create body = %#v", create)
	}
}

func TestBuildBodyDocCreateStdinAndUnusedPipe(t *testing.T) {
	cmd := manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		// doc.create's real manifest declares the file flag — the unused-pipe
		// guard only recommends `--file -` for commands that declare it.
		Flags: []manifest.Flag{{Name: "file", Type: "file"}},
	}

	withPipe := func(input string, fn func()) {
		t.Helper()
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatalf("os.Pipe: %v", err)
		}
		if _, err := io.WriteString(w, input); err != nil {
			t.Fatalf("write stdin pipe: %v", err)
		}
		_ = w.Close()
		original := os.Stdin
		os.Stdin = r
		t.Cleanup(func() {
			os.Stdin = original
			_ = r.Close()
		})
		fn()
		os.Stdin = original
		_ = r.Close()
	}

	withPipe(`{"title":"stdin"}`, func() {
		body, _, _, err := buildBody(cmd, map[string][]string{"file": {"-"}}, map[string]string{"type": "paper"})
		if err != nil {
			t.Fatalf("buildBody --file -: %v", err)
		}
		if want := `{"mutations":[{"create":{"title":"stdin","type":"paper"}}]}`; string(body) != want {
			t.Fatalf("stdin request body = %s, want %s", body, want)
		}
	})

	withPipe(`{"title":"ignored"}`, func() {
		_, _, _, err := buildBody(cmd, map[string][]string{}, map[string]string{"type": "paper"})
		if err == nil || !strings.Contains(err.Error(), "piped stdin is unused") || !strings.Contains(err.Error(), "--file -") {
			t.Fatalf("unused piped stdin error = %v", err)
		}
	})

	withPipe(`{"jsonrpc":"2.0","method":"tools/call"}`, func() {
		body, _, _, err := buildBodyWithStdinOwnership(cmd, map[string][]string{}, map[string]string{"type": "paper"}, false)
		if err != nil {
			t.Fatalf("headless body with protocol stdin: %v", err)
		}
		if want := `{"mutations":[{"create":{"type":"paper"}}]}`; string(body) != want {
			t.Fatalf("headless request body = %s, want %s", body, want)
		}

		_, _, _, err = buildBodyWithStdinOwnership(cmd, map[string][]string{"file": {"-"}}, map[string]string{"type": "paper"}, false)
		if err == nil || !strings.Contains(err.Error(), "--file - is unavailable in headless dispatch") {
			t.Fatalf("headless --file - error = %v", err)
		}

		remaining, err := io.ReadAll(os.Stdin)
		if err != nil {
			t.Fatalf("read untouched protocol stdin: %v", err)
		}
		if want := `{"jsonrpc":"2.0","method":"tools/call"}`; string(remaining) != want {
			t.Fatalf("headless dispatch consumed protocol stdin: got %q, want %q", remaining, want)
		}
	})
}

// TestBuildBodyEmptyPipeStdin is the W18-5 regression for the empty-pipe
// false-trip (task-e6bf5dfd3db4caa8): CI `run:` steps, cron, and Makefile
// pipelines hand bp a pipe carrying NO data (`: | bp schema apply --file f`),
// and the unused-stdin guard — whose whole purpose is to stop DATA being
// silently swallowed — must not hard-error when there is no data. A NON-empty
// unused pipe still trips (TestBuildBodyDocCreateStdinAndUnusedPipe above
// stays the unchanged lock for that). The one unacceptable failure mode is a
// BLOCKING read on an open-but-empty pipe with a live writer — every case
// below runs under a watchdog so a regression to a blocking probe fails fast
// instead of hanging the suite.
func TestBuildBodyEmptyPipeStdin(t *testing.T) {
	swapStdin := func(t *testing.T, f *os.File) {
		t.Helper()
		original := os.Stdin
		os.Stdin = f
		t.Cleanup(func() { os.Stdin = original })
	}

	// buildBody must return promptly whether or not the guard fires: the
	// stdin probe has to be a non-blocking readiness/size check, never a read.
	runBuildBody := func(t *testing.T, cmd manifest.Command, flags map[string][]string, args map[string]string) (body []byte, err error) {
		t.Helper()
		done := make(chan struct{})
		go func() {
			defer close(done)
			body, _, _, err = buildBody(cmd, flags, args)
		}()
		select {
		case <-done:
			return body, err
		case <-time.After(5 * time.Second):
			t.Fatal("buildBody blocked on an empty stdin pipe (the probe must be non-blocking, never a read)")
			return nil, nil
		}
	}

	docCreate := manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args: []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "file", Type: "file"},
			{Name: "set", Type: "string", Repeatable: true},
		},
	}
	schemaApply := manifest.Command{
		ID: "schema.apply", Noun: "schema", Verb: "apply", Writes: true,
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/schemas/apply"},
		Flags: []manifest.Flag{{Name: "file", Type: "file"}},
	}

	t.Run("closed empty pipe without --file proceeds", func(t *testing.T) {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatalf("os.Pipe: %v", err)
		}
		_ = w.Close()
		t.Cleanup(func() { _ = r.Close() })
		swapStdin(t, r)

		body, err := runBuildBody(t, docCreate, map[string][]string{}, map[string]string{"type": "paper"})
		if err != nil {
			t.Fatalf("empty pipe must not trip the unused-stdin guard: %v", err)
		}
		if want := `{"mutations":[{"create":{"type":"paper"}}]}`; string(body) != want {
			t.Fatalf("request body = %s, want %s", body, want)
		}
	})

	t.Run("closed empty pipe with --file <path> proceeds", func(t *testing.T) {
		// The live repro this pins: `: | bp schema apply --file f --dry-run`
		// exited 2 on origin/main while `< /dev/null` exited 0 — the same
		// invocation must now build the same body either way.
		path := filepath.Join(t.TempDir(), "schema.json")
		if err := os.WriteFile(path, []byte(`{"name":"post"}`), 0o644); err != nil {
			t.Fatalf("write schema fixture: %v", err)
		}
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatalf("os.Pipe: %v", err)
		}
		_ = w.Close()
		t.Cleanup(func() { _ = r.Close() })
		swapStdin(t, r)

		body, err := runBuildBody(t, schemaApply, map[string][]string{"file": {path}}, nil)
		if err != nil {
			t.Fatalf("empty pipe + --file <path> must not trip the unused-stdin guard: %v", err)
		}
		if want := `{"name":"post"}`; string(body) != want {
			t.Fatalf("request body = %s, want %s", body, want)
		}
	})

	t.Run("open empty pipe with live writer never blocks", func(t *testing.T) {
		// A writer that holds the pipe open but has written nothing yet:
		// missing the unused-stdin warning here is acceptable; blocking is
		// not (runBuildBody's watchdog is the real assertion).
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatalf("os.Pipe: %v", err)
		}
		t.Cleanup(func() { _ = w.Close(); _ = r.Close() })
		swapStdin(t, r)

		if _, err := runBuildBody(t, docCreate, map[string][]string{}, map[string]string{"type": "paper"}); err != nil {
			t.Fatalf("open-but-empty pipe must not error: %v", err)
		}
	})

	t.Run("non-empty pipe on a command without --file trips honestly", func(t *testing.T) {
		// doc.patch's manifest declares flags [set] only — the guard must
		// still trip on real unused data, but must NOT recommend --file,
		// which this command's parser rightly rejects.
		docPatch := manifest.Command{
			ID: "doc.patch", Noun: "doc", Verb: "patch", Writes: true, MutationOp: "patch", SetKey: "set",
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
			Args: []manifest.Arg{
				{Name: "type", Required: true, Type: "string"},
				{Name: "id", Required: true, Type: "string"},
			},
			Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
		}
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatalf("os.Pipe: %v", err)
		}
		if _, err := io.WriteString(w, `{"title":"ignored"}`); err != nil {
			t.Fatalf("write stdin pipe: %v", err)
		}
		_ = w.Close()
		t.Cleanup(func() { _ = r.Close() })
		swapStdin(t, r)

		_, err = runBuildBody(t, docPatch, map[string][]string{"set": {"title=x"}}, map[string]string{"type": "paper", "id": "p1"})
		if err == nil || !strings.Contains(err.Error(), "piped stdin is unused") {
			t.Fatalf("non-empty unused pipe must still trip the guard, got: %v", err)
		}
		if strings.Contains(err.Error(), "--file -") {
			t.Fatalf("guard must not recommend --file for doc patch (manifest declares no file flag): %v", err)
		}
	})
}

// TestBuildBodyNoStdinSinkProceedsOnRedirectedStdin is the gfr-w1-stdin-guard-
// altitude regression (Gyldendal finding #20, "knekker enhver while-read-lokke"):
// a write command that declares NEITHER a file flag nor a mutation_op — task
// close, task next, webhook create, most cloud verbs; 59 of the 72 write
// commands in the served manifest — has NO way to read a request body from
// stdin at all, so a redirected/piped stdin can never be silently swallowed by
// it. The guard used to refuse anyway, which aborts EVERY iteration of
// `while read -r id; do bp task close "$id" …; done < ids.txt` (the loop and bp
// share the same fd 0). On unpatched main this fails with
// "piped stdin is unused and task close does not accept --file".
func TestBuildBodyNoStdinSinkProceedsOnRedirectedStdin(t *testing.T) {
	taskClose := manifest.Command{
		ID: "task.close", Noun: "task", Verb: "close", Writes: true,
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/tasks/:doc_id/close"},
		Args: []manifest.Arg{
			{Name: "id", Required: true, Type: "string"},
			{Name: "worker", Required: true, Type: "string"},
			{Name: "epoch", Required: true, Type: "int"},
		},
		// No file flag, no MutationOp: this command cannot read a body from
		// stdin under ANY flag combination.
	}

	f, err := os.CreateTemp(t.TempDir(), "ids-*.txt")
	if err != nil {
		t.Fatalf("create temp stdin file: %v", err)
	}
	if _, err := io.WriteString(f, "task-aaa\ntask-bbb\ntask-ccc\n"); err != nil {
		t.Fatalf("write temp stdin file: %v", err)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("rewind temp stdin file: %v", err)
	}
	original := os.Stdin
	os.Stdin = f
	t.Cleanup(func() {
		os.Stdin = original
		_ = f.Close()
	})

	body, _, _, err := buildBody(taskClose, map[string][]string{}, map[string]string{"id": "task-aaa", "worker": "w1", "epoch": "1"})
	if err != nil {
		t.Fatalf("a command with no stdin sink must proceed on redirected stdin (nothing could have been swallowed): %v", err)
	}
	if body == nil {
		t.Fatalf("expected a non-nil body for a plain write with no body source")
	}
}

// TestBuildBodyDrainedRegularFileStdinDoesNotTrip is the second half of the
// gfr-w1-stdin-guard-altitude finding: the regular-file arm of
// stdinHasRedirectedInput compared the file's total SIZE against zero, not the
// BYTES REMAINING at the current offset. In a `while read ... done < file`
// loop, bp's stdin fd shares its offset with the shell's own `read` builtin
// (both inherited the same open file description), so by the time a mid-loop
// or post-loop bp write runs, the file may already be fully drained — yet
// info.Size() still reports the original length and the guard still tripped.
// On unpatched main this fails with "piped stdin is unused; pass --file - to
// consume it" even though zero bytes remain to read.
func TestBuildBodyDrainedRegularFileStdinDoesNotTrip(t *testing.T) {
	// docCreate declares a file flag, so buildBody actually consults
	// stdinRedirected here (the no-sink command above never reaches the
	// regular-file size/offset comparison at all).
	docCreate := manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:  []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{{Name: "file", Type: "file"}},
	}

	f, err := os.CreateTemp(t.TempDir(), "drained-*.json")
	if err != nil {
		t.Fatalf("create temp stdin file: %v", err)
	}
	if _, err := io.WriteString(f, `{"title":"already consumed"}`); err != nil {
		t.Fatalf("write temp stdin file: %v", err)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		t.Fatalf("rewind temp stdin file: %v", err)
	}
	// Drain it fully — mimicking the shell's `read` having already consumed
	// every byte before bp's turn on the shared fd.
	if _, err := io.ReadAll(f); err != nil {
		t.Fatalf("drain temp stdin file: %v", err)
	}
	original := os.Stdin
	os.Stdin = f
	t.Cleanup(func() {
		os.Stdin = original
		_ = f.Close()
	})

	body, _, _, err := buildBody(docCreate, map[string][]string{}, map[string]string{"type": "paper"})
	if err != nil {
		t.Fatalf("a fully-drained regular-file stdin must not trip the unused-stdin guard: %v", err)
	}
	if want := `{"mutations":[{"create":{"type":"paper"}}]}`; string(body) != want {
		t.Fatalf("request body = %s, want %s", body, want)
	}
}

// TestMCPStdioWriteIgnoresProtocolPipe is the mutation-sensitive regression for
// the real transport failure found by Team300. A built bp process keeps JSON-RPC
// on stdin while task_next must still reach exactly one loopback backend write.
func TestMCPStdioWriteIgnoresProtocolPipe(t *testing.T) {
	if testing.Short() {
		t.Skip("skips the go-build-and-exec MCP stdio regression in short mode")
	}

	var claimHits int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/data/query/production/paper":
			_, _ = io.WriteString(w, `{"result":[]}`)
		case "/v1/tasks/claim":
			atomic.AddInt32(&claimHits, 1)
			_, _ = io.WriteString(w, `{"ok":false,"reason":"no_ready"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer backend.Close()

	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	bin := filepath.Join(t.TempDir(), "bp")
	build := exec.Command("go", "build", "-o", bin, "./cmd/barkpark")
	build.Dir = root
	build.Env = append(os.Environ(), "CC=/usr/bin/clang")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build bp: %v\n%s", err, out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "mcp", "serve")
	cmd.Env = append(os.Environ(),
		"BARKPARK_MANIFEST="+filepath.Join(root, "docs", "cli", "fixtures", "full-manifest.json"),
		"BARKPARK_API_URL="+backend.URL,
		"BARKPARK_API_TOKEN=task304-stub",
	)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start MCP server: %v", err)
	}

	writeRPC := func(line string) {
		t.Helper()
		if _, err := io.WriteString(stdin, line+"\n"); err != nil {
			t.Fatalf("write MCP frame: %v", err)
		}
	}
	writeRPC(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"task304-test","version":"1"}}}`)
	writeRPC(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	writeRPC(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_next","arguments":{"worker_id":"task304-noop"}}}`)

	dec := json.NewDecoder(stdout)
	var initialize map[string]any
	if err := dec.Decode(&initialize); err != nil {
		t.Fatalf("decode initialize response: %v\nstderr:\n%s", err, stderr.String())
	}
	if initialize["id"] != float64(1) {
		t.Fatalf("initialize response id = %#v", initialize["id"])
	}
	var call map[string]any
	if err := dec.Decode(&call); err != nil {
		t.Fatalf("decode tools/call response: %v\nstderr:\n%s", err, stderr.String())
	}
	encoded, _ := json.Marshal(call)
	if call["id"] != float64(2) || !bytes.Contains(encoded, []byte("no_ready")) || bytes.Contains(encoded, []byte(`"isError":true`)) {
		t.Fatalf("task_next response = %s, want successful no_ready", encoded)
	}
	if got := atomic.LoadInt32(&claimHits); got != 1 {
		t.Fatalf("backend claim hits = %d, want exactly 1", got)
	}

	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("MCP server exit: %v\nstderr:\n%s", err, stderr.String())
	}
	if ctx.Err() != nil {
		t.Fatalf("MCP server timed out: %v", ctx.Err())
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
	body, _, ct, err := buildBody(*wc, map[string][]string{}, map[string]string{"url": "https://hook.example/x"})
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
	body2, _, _, _ := buildBody(*pc, map[string][]string{}, map[string]string{"name": "Marketing"})
	var got2 map[string]any
	if json.Unmarshal(body2, &got2) != nil || got2["name"] != "Marketing" {
		t.Errorf("project-create body = %s, want name field", body2)
	}

	// --set merges over arg-seeded fields.
	body3, _, _, _ := buildBody(*wc, map[string][]string{"set": {"secret=s3cr3t"}}, map[string]string{"url": "https://hook/x"})
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
	body, _, ct, err := buildBody(*claim, map[string][]string{}, claimArgs)
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
	body2, _, _, err := buildBody(*close, map[string][]string{}, closeArgs)
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
	body3, _, _, err := buildBody(*close, map[string][]string{}, closeArgsWithStatus)
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

	// task.close declares the `set` flag (living-values close-out), so the
	// acceptance-criteria met/evidence payload rides the generic typed --set
	// path: --set 'criteria:=[{…}]' must land in the body as a real JSON
	// array (not a string) alongside the positional args — the server merges
	// it into acceptance_criteria atomically with the close.
	if _, ok := splitFlagLookup(*close, "set"); !ok {
		t.Fatal("task close must declare the `set` flag in the manifest fixture")
	}
	setFlags := map[string][]string{"set": {`criteria:=[{"index":0,"met":true,"evidence":"PR #123"}]`}}
	body4, _, _, err := buildBody(*close, setFlags, closeArgs)
	if err != nil {
		t.Fatalf("buildBody task close with --set criteria: %v", err)
	}
	var closeObj4 map[string]any
	if json.Unmarshal(body4, &closeObj4) != nil {
		t.Fatalf("close+criteria body not valid JSON: %s", body4)
	}
	criteria, ok := closeObj4["criteria"].([]any)
	if !ok || len(criteria) != 1 {
		t.Fatalf("close body criteria = %v (want a 1-element JSON array); body = %s", closeObj4["criteria"], body4)
	}
	entry, ok := criteria[0].(map[string]any)
	if !ok || entry["index"] != float64(0) || entry["met"] != true || entry["evidence"] != "PR #123" {
		t.Errorf("close body criteria[0] = %v; body = %s", criteria[0], body4)
	}
	if closeObj4["worker_id"] != "paper-agent" || closeObj4["observed_epoch"] != "42" {
		t.Errorf("--set criteria must merge OVER the positional args, not replace them; body = %s", body4)
	}
}

// TestBuildBodyTaskRelease pins the manifest-only voluntary-unclaim command:
// doc_id is URL-bound, while worker_id + observed_epoch form the generic JSON
// body. No release-specific Go dispatch branch is needed or allowed.
func TestBuildBodyTaskRelease(t *testing.T) {
	m, tree := loadTreeFrom(t, fullManifest)
	release, ok := tree.Lookup("task", "release")
	if !ok {
		t.Fatal("task release missing from full-manifest fixture")
	}
	if release.HTTP.Method != "POST" || release.HTTP.PathTemplate != "/v1/tasks/:doc_id/release" {
		t.Fatalf("task release http = %s %s, want POST /v1/tasks/:doc_id/release", release.HTTP.Method, release.HTTP.PathTemplate)
	}
	if !release.Writes || release.AuthTier != "read" || release.DefaultOutput != "minimal" {
		t.Fatalf("task release contract = writes:%v auth:%q output:%q", release.Writes, release.AuthTier, release.DefaultOutput)
	}

	args := map[string]string{
		"doc_id":         "drafts.task a/b",
		"worker_id":      "paper-agent",
		"observed_epoch": "42",
	}
	body, _, ct, err := buildBody(*release, map[string][]string{}, args)
	if err != nil {
		t.Fatalf("buildBody task release: %v", err)
	}
	if ct != "application/json" {
		t.Errorf("release content-type = %q, want application/json", ct)
	}
	var obj map[string]any
	if err := json.Unmarshal(body, &obj); err != nil {
		t.Fatalf("release body not valid JSON: %v: %s", err, body)
	}
	if obj["worker_id"] != "paper-agent" || obj["observed_epoch"] != "42" {
		t.Errorf("release body = %s, want worker_id + observed_epoch", body)
	}
	if _, leaked := obj["doc_id"]; leaked {
		t.Errorf("path arg doc_id must not appear in release body: %s", body)
	}

	rawURL, err := m.BuildURL(*release, manifest.Context{Server: "http://localhost:4000"}, args)
	if err != nil {
		t.Fatalf("BuildURL task release: %v", err)
	}
	if want := "http://localhost:4000/v1/tasks/drafts.task%20a%2Fb/release"; rawURL != want {
		t.Errorf("task release url = %q, want %q", rawURL, want)
	}

	for _, reason := range []string{"fenced_off", "not_holder", "stale_claim", "not_in_progress:done"} {
		ae := classifyError(409, []byte(`{"ok":false,"reason":"`+reason+`"}`))
		if ae.code != reason || ae.exit == exitOK {
			t.Errorf("release reason %q classified as exit=%d code=%q, want nonzero + exact reason", reason, ae.exit, ae.code)
		}
	}
}

// splitFlagLookup reports whether the command declares the named flag —
// the gate splitArgs enforces before --<name> is accepted on the command line.
func splitFlagLookup(cmd manifest.Command, name string) (manifest.Flag, bool) {
	for _, f := range cmd.Flags {
		if f.Name == name {
			return f, true
		}
	}
	return manifest.Flag{}, false
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
	body, _, ct, err := buildBody(*next, map[string][]string{}, args)
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
	body2, _, _, _ := buildBody(*next, map[string][]string{}, args2)
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

	// Claim-shaped doc (task next / task claim success): doc_id + epoch + rev.
	// The rev is what a close pins to fence its write, so the receipt echoes it.
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"drafts.task-992199","rev":7,"claim":{"worker":"agent-1","ts_iso":"2026-06-10T08:00:00Z","epoch":2}}}`))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-992199 epoch=2 rev=7" {
		t.Errorf("claim receipt = %q, want \"drafts.task-992199 epoch=2 rev=7\"", got)
	}

	// Real API shape: render_doc emits rev as a hex string at the doc top level.
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"drafts.task-3","rev":"a1b2c3","claim":{"worker":"agent-9","epoch":4}}}`))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-3 epoch=4 rev=a1b2c3" {
		t.Errorf("hex-rev claim receipt = %q, want \"drafts.task-3 epoch=4 rev=a1b2c3\"", got)
	}

	// Doc without a claim: just the id line.
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"drafts.task-1","title":"x"}}`))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-1" {
		t.Errorf("no-claim receipt = %q, want \"drafts.task-1\"", got)
	}

	// Release-shaped doc: the claim remains as a monotonic epoch fence but its
	// worker is nil. The generic receipt still prints the new epoch + rev.
	stdout.Reset()
	renderMinimal(w, []byte(`{"ok":true,"doc":{"doc_id":"task-9","rev":"new-rev","claim":{"worker":null,"epoch":8}}}`))
	if got := strings.TrimSpace(stdout.String()); got != "task-9 epoch=8 rev=new-rev" {
		t.Errorf("release receipt = %q, want \"task-9 epoch=8 rev=new-rev\"", got)
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

// TestRenderSuccessWarnings pins the advisory-warnings surface (lvw-t6): a 2xx
// envelope carrying a top-level {"warnings":[…]} string list — e.g. task close
// on a done task with unmet acceptance_criteria — prints each as "warning: …"
// on STDERR for the human shapes (minimal/table), leaving stdout's receipt and
// the exit path untouched. json output does NOT duplicate to stderr (the field
// rides the payload itself). Shape-keyed, never verb-keyed; malformed or
// absent warnings never crash or print.
func TestRenderSuccessWarnings(t *testing.T) {
	payload := `{"ok":true,"doc":{"doc_id":"drafts.task-1"},"warnings":["acceptance_criteria: 1/2 met — closed done with unmet criteria"]}`

	// minimal: receipt on stdout, warning on stderr.
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderSuccess(w, manifest.Command{}, []byte(payload))
	if got := strings.TrimSpace(stdout.String()); got != "drafts.task-1" {
		t.Errorf("minimal stdout = %q, want doc receipt untouched", got)
	}
	if got := stderr.String(); !strings.Contains(got, "warning: acceptance_criteria: 1/2 met") {
		t.Errorf("minimal stderr = %q, want the warning line", got)
	}

	// table: warning also lands on stderr.
	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	w.output = "table"
	renderSuccess(w, manifest.Command{}, []byte(payload))
	if got := stderr.String(); !strings.Contains(got, "warning: acceptance_criteria") {
		t.Errorf("table stderr = %q, want the warning line", got)
	}

	// json: the field rides the payload; stderr stays clean.
	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	w.output = "json"
	renderSuccess(w, manifest.Command{}, []byte(payload))
	if got := stderr.String(); got != "" {
		t.Errorf("json stderr = %q, want empty (no duplication)", got)
	}
	if !strings.Contains(stdout.String(), "warnings") {
		t.Errorf("json stdout should carry the warnings field, got %q", stdout.String())
	}

	// Object-shaped warning (the authoring wall's {code,severity,message} advisory):
	// the code + message render on stderr for the human shapes; a mixed list keeps
	// the bare-string entry too, and an object with no message stays skipped.
	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	w.output = "minimal"
	objPayload := `{"ok":true,"doc":{"doc_id":"t"},"warnings":[` +
		`{"code":"label_norm","severity":"advisory","message":"tags: 5 labels — advisory norm is 2–4"},` +
		`{"severity":"advisory","message":"no code, still surfaced"},` +
		`{"code":"nomsg","severity":"advisory"},` +
		`"plain string advisory"]}`
	renderSuccess(w, manifest.Command{}, []byte(objPayload))
	if got := stderr.String(); !strings.Contains(got, "warning[label_norm]: tags: 5 labels — advisory norm is 2–4") {
		t.Errorf("object warning stderr = %q, want the label_norm line", got)
	}
	if got := stderr.String(); !strings.Contains(got, "warning: no code, still surfaced") {
		t.Errorf("code-less object warning stderr = %q, want the message line", got)
	}
	if got := stderr.String(); !strings.Contains(got, "warning: plain string advisory") {
		t.Errorf("mixed-list bare string stderr = %q, want the string line", got)
	}
	if got := stderr.String(); strings.Contains(got, "nomsg") {
		t.Errorf("message-less object warning must be skipped, got %q", got)
	}

	// No warnings key / non-string entries: nothing printed, nothing crashes.
	for _, p := range []string{
		`{"ok":true,"doc":{"doc_id":"t"}}`,
		`{"ok":true,"doc":{"doc_id":"t"},"warnings":[]}`,
		`{"ok":true,"doc":{"doc_id":"t"},"warnings":[42,null,{"x":1},""]}`,
		`{"ok":true,"doc":{"doc_id":"t"},"warnings":"not-a-list"}`,
	} {
		stdout.Reset()
		stderr.Reset()
		w = newWriter(&stdout, &stderr)
		w.output = "minimal"
		renderSuccess(w, manifest.Command{}, []byte(p))
		if got := stderr.String(); strings.Contains(got, "warning:") {
			t.Errorf("payload %s: stderr = %q, want no warning lines", p, got)
		}
	}
}

// TestRenderSuccessNotices pins the advisory rail-awareness notices surface
// (rail-l1): a claim/close/prime 2xx envelope carrying a top-level
// {"notices":[…]} typed list prints each as "notice: <type> …" on STDERR for
// the human shapes (minimal/table), leaving stdout's receipt and the exit path
// untouched. json output does NOT duplicate to stderr (the field rides the
// payload). Shape-keyed, never verb-keyed; malformed/absent notices never crash.
func TestRenderSuccessNotices(t *testing.T) {
	payload := `{"ok":true,"doc":{"doc_id":"t5"},"rail_rev":"abcd1234abcd1234",` +
		`"notices":[{"type":"blocked_while_claimed","task_id":"t5","blockers":["t9","t12"]},` +
		`{"type":"rail_changed","parent_id":"epic-1","rail_rev":"abcd1234abcd1234"}]}`

	// minimal: receipt on stdout, both notices on stderr.
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderSuccess(w, manifest.Command{}, []byte(payload))
	if got := strings.TrimSpace(stdout.String()); got != "t5" {
		t.Errorf("minimal stdout = %q, want doc receipt untouched", got)
	}
	if got := stderr.String(); !strings.Contains(got, "notice: blocked_while_claimed task=t5 blockers=t9,t12") {
		t.Errorf("minimal stderr = %q, want the blocked_while_claimed line", got)
	}
	if got := stderr.String(); !strings.Contains(got, "notice: rail_changed parent=epic-1 rail_rev=abcd1234abcd1234") {
		t.Errorf("minimal stderr = %q, want the rail_changed line", got)
	}

	// table: notices also land on stderr.
	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	w.output = "table"
	renderSuccess(w, manifest.Command{}, []byte(payload))
	if got := stderr.String(); !strings.Contains(got, "notice: blocked_while_claimed") {
		t.Errorf("table stderr = %q, want the notice line", got)
	}

	// json: the field rides the payload; stderr stays clean.
	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	w.output = "json"
	renderSuccess(w, manifest.Command{}, []byte(payload))
	if got := stderr.String(); got != "" {
		t.Errorf("json stderr = %q, want empty (no duplication)", got)
	}
	if !strings.Contains(stdout.String(), "notices") {
		t.Errorf("json stdout should carry the notices field, got %q", stdout.String())
	}

	// No notices key / malformed entries: nothing printed, nothing crashes.
	for _, p := range []string{
		`{"ok":true,"doc":{"doc_id":"t"}}`,
		`{"ok":true,"doc":{"doc_id":"t"},"notices":[]}`,
		`{"ok":true,"doc":{"doc_id":"t"},"notices":[{"type":""},{"nope":1}]}`,
		`{"ok":true,"doc":{"doc_id":"t"},"notices":"not-a-list"}`,
	} {
		stdout.Reset()
		stderr.Reset()
		w = newWriter(&stdout, &stderr)
		w.output = "minimal"
		renderSuccess(w, manifest.Command{}, []byte(p))
		if got := stderr.String(); strings.Contains(got, "notice:") {
			t.Errorf("payload %s: stderr = %q, want no notice lines", p, got)
		}
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

	rawBody, stream, ct, err := buildBody(*up, map[string][]string{}, map[string]string{"file": fp})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	// Media upload now streams the multipart body via io.Pipe: buildBody returns
	// a nil byte body and a stream reader (never buffered whole in memory).
	if rawBody != nil {
		t.Errorf("media upload returned a buffered byte body, want a stream")
	}
	if stream == nil {
		t.Fatal("media upload did not produce a streaming body")
	}
	body, err := io.ReadAll(stream)
	if err != nil {
		t.Fatalf("read multipart stream: %v", err)
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

// TestBuildBodyFileArgMultipartOnNonMediaRoute is the regression pin for
// task-c005183551c279c0: mediaUploadFileArg used to test whether the route
// PATH TEXT contained the substring "/media" as a proxy for "this command
// uploads a file" — so a manifest-declared file-typed arg on any other route
// (e.g. a plugin's own ingest endpoint) fell through to the JSON body path and
// shipped the file's PATH STRING as a JSON value instead of the file's BYTES
// as multipart/form-data. The server then answers "multipart field \"file\" is
// required" because it received `{"file":"/abs/path/x.csv"}`, not a file part.
//
// The predicate must key off the declared arg's `type: "file"` (what
// media.upload itself declares — see capabilities.ex `arg("file", true,
// "file", …)`), not off spelling in the URL. This command's route
// (/v1/plugins/sheets/import) contains no "/media" substring at all, so it
// is the sharpest possible non-media POST-with-a-file-arg fixture.
func TestBuildBodyFileArgMultipartOnNonMediaRoute(t *testing.T) {
	cmd := manifest.Command{
		ID: "sheets.import", Noun: "sheets", Verb: "import", Writes: true,
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/plugins/sheets/import"},
		Args: []manifest.Arg{
			{Name: "file", Required: true, Type: "file"},
		},
	}

	dir := t.TempDir()
	fp := filepath.Join(dir, "demo.csv")
	if err := os.WriteFile(fp, []byte("a,b\n1,2\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	rawBody, stream, ct, err := buildBody(cmd, map[string][]string{}, map[string]string{"file": fp})
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if rawBody != nil {
		t.Fatalf("file-typed arg on a non-media route sent a JSON body (%s), want a multipart stream", rawBody)
	}
	if stream == nil {
		t.Fatal("file-typed arg on a non-media route did not produce a streaming multipart body")
	}
	body, err := io.ReadAll(stream)
	if err != nil {
		t.Fatalf("read multipart stream: %v", err)
	}
	if !strings.HasPrefix(ct, "multipart/form-data; boundary=") {
		t.Errorf("content type = %q, want multipart/form-data", ct)
	}
	if !bytes.Contains(body, []byte(`name="file"`)) {
		t.Errorf("multipart body missing file field: %s", body)
	}
	if !bytes.Contains(body, []byte("a,b\n1,2")) {
		t.Errorf("multipart body missing file contents")
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
// clearBarkparkEnv unsets the WHOLE env dialect for one test, so a name
// exported on the developer's own machine cannot outrank the fixture under
// assertion. The server and token names are read out of ServerEnvNames /
// TokenEnvNames rather than typed here — axi-b4 added BARKPARK_URL and
// BARKPARK_TOKEN to those lists and this hand-written copy went stale in the
// same commit, which is how the omission was found: on a machine that really
// does export BARKPARK_TOKEN, TestResolveContextRepoFile read the developer's
// live admin token instead of the fixture's "tok-global". Deriving the list
// makes that failure impossible to reintroduce.
func clearBarkparkEnv(t *testing.T) {
	t.Helper()
	keys := append([]string{}, ServerEnvNames...)
	keys = append(keys, TokenEnvNames...)
	keys = append(keys, "BARKPARK_WORKSPACE", "BARKPARK_PROJECT", "BARKPARK_DATASET")
	for _, k := range keys {
		t.Setenv(k, "")
	}
}

func TestResolveContextNamedServer(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	// A .barkpark.json anywhere above the test's cwd would inject a repo layer
	// under the flags being asserted — run from a guaranteed-clean tree.
	t.Chdir(t.TempDir())

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
		{
			name:        "revisions (doc.history)",
			payload:     `{"revisions":[{"id":"rev-9","action":"update","title":"v2","timestamp":"t"}]}`,
			tableHas:    "update",
			wantMinimal: "id: rev-9",
		},
		{
			name:        "secrets (cloud run-secrets)",
			payload:     `{"secrets":[{"name":"STRIPE_KEY","value":"sk_***"}]}`,
			tableHas:    "STRIPE_KEY",
			wantMinimal: "id: STRIPE_KEY", // no id key → name fallback
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
		{"doc.revision", `{"revision":{"id":"rev-1","action":"create","title":"v1"}}`, "create"},
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

	body, _, _, err := buildBody(*wc, map[string][]string{"set": {
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
	_, _, _, err = buildBody(*wc, map[string][]string{"set": {"priority:=three"}}, map[string]string{})
	if err == nil || !strings.Contains(err.Error(), "not valid JSON") {
		t.Errorf("bad := value should error with guidance, got %v", err)
	}
}

// captureExecute runs Execute(args) with os.Stdout+os.Stderr redirected to a
// single pipe and returns the combined output. Both streams matter: usage
// renders to stderr, receipts to stdout.
func captureExecute(t *testing.T, args []string) string {
	t.Helper()
	out, _ := captureExecuteCode(t, args)
	return out
}

// TestExecuteCommandHelpShowsCommandSignature pins the fix for `bp <noun> <verb>
// --help`: it must route to that command's own arg/flag help (usageCommand),
// like git/gh/stripe — NOT the whole noun verb overview (usageNoun).
func TestExecuteCommandHelpShowsCommandSignature(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	out := captureExecute(t, []string{"doc", "get", "--help"})

	// The command signature and its flag block must be present…
	if !strings.Contains(out, "usage: barkpark doc get") {
		t.Errorf("command help missing signature line; got:\n%s", out)
	}
	if !strings.Contains(out, "flags:") {
		t.Errorf("command help missing flags block; got:\n%s", out)
	}
	// …and the full noun verb list (usageNoun's "verbs:" block) must NOT be.
	if strings.Contains(out, "verbs:") {
		t.Errorf("command help leaked the noun verb overview; got:\n%s", out)
	}
}

// TestTinkerHelpDoesNotEnterREPL pins the fix for `bp tinker --help`: it must
// print tinkerHelp and return, not fall through into the readline `tinker>`
// loop (which in an interactive shell traps the user reading stdin).
func TestTinkerHelpDoesNotEnterREPL(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	out := captureExecute(t, []string{"tinker", "--help"})

	// A distinctive tinkerHelp command line must be present…
	if !strings.Contains(out, "mutate <json>") {
		t.Errorf("tinker --help missing command list; got:\n%s", out)
	}
	// …and the REPL prompt must NOT be, proving we never entered the loop.
	if strings.Contains(out, "tinker>") {
		t.Errorf("tinker --help dropped into the REPL; got:\n%s", out)
	}
}

// TestExecuteBareNounHelpShowsVerbList guards the untouched path: a valid noun
// with no verb (or an unknown verb) still falls through to the noun overview.
func TestExecuteBareNounHelpShowsVerbList(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	out := captureExecute(t, []string{"doc", "-h"})
	if !strings.Contains(out, "verbs:") {
		t.Errorf("bare `doc -h` should list the noun's verbs; got:\n%s", out)
	}
}

// captureExecuteCode is captureExecute that also returns Execute's exit code — the
// help-vs-side-effect assertion below needs both the printed help and exit 0.
func captureExecuteCode(t *testing.T, args []string) (string, int) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	origOut, origErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = w, w
	// Drain the pipe CONCURRENTLY with Execute. A single write larger than the OS
	// pipe buffer (as small as ~512 bytes on some hosts; 64 KiB on Linux CI) blocks
	// the writer until a reader drains it — so reading only after Execute returns
	// deadlocks the moment any help text exceeds the buffer (printLoginHelp is
	// ~1952 bytes). The goroutine reads while Execute writes; closing w signals EOF.
	done := make(chan string, 1)
	go func() {
		body, _ := io.ReadAll(r)
		done <- string(body)
	}()
	code := Execute(args)
	os.Stdout, os.Stderr = origOut, origErr
	_ = w.Close()
	body := <-done
	_ = r.Close()
	return string(body), code
}

// TestExecuteBuiltinHelpHonoursGlobalHelp pins the fix for `--help`/`-h` being
// swallowed on CLI-native built-ins: parseGlobals strips -h/--help into g.help,
// but the built-in `switch noun` used to dispatch straight into the command —
// so `bp login --help` fell into an interactive credential prompt, `bp signup
// --help` likewise, and `bp doctor --help` ran the live health gate (a network
// side effect) instead of printing help. Each must now print its own help and
// exit 0, touching neither stdin nor the network.
func TestExecuteBuiltinHelpHonoursGlobalHelp(t *testing.T) {
	cases := []struct {
		noun   string
		header string
	}{
		{"login", "bp login — authenticate to Barkpark Cloud"},
		{"signup", "bp signup — create a Barkpark Cloud account"},
		{"doctor", "bp doctor — run the post-deploy health gate"},
		{"sites", "bp sites — manage hosted websites (Barkpark Cloud, P6)."},
		{"deploy", "bp deploy — enqueue a deployment for a hosted site (Barkpark Cloud)."},
	}
	for _, c := range cases {
		for _, flag := range []string{"--help", "-h"} {
			out, code := captureExecuteCode(t, []string{c.noun, flag})
			if code != exitOK {
				t.Errorf("`bp %s %s` exit = %d, want %d (help must not prompt or hit the network); got:\n%s",
					c.noun, flag, code, exitOK, out)
			}
			if !strings.Contains(out, c.header) {
				t.Errorf("`bp %s %s` did not print its help header %q; got:\n%s",
					c.noun, flag, c.header, out)
			}
		}
	}
}

// --- verbless dispatch on a REAL noun -----------------------------------------

// TestExecuteRealNounFreeTextInfersSoleVerb pins the reported symptom: SIX
// independent agents in one wave typed `bp search "<text>"`, read back
// `unknown command "search" "<text>"`, concluded their bp was too stale to
// search Barkpark, and fell back to grep against standing doctrine. `search` is
// a real manifest noun whose one verb is `query` — so dispatch must never call
// the noun unknown, and (one obvious, non-writing answer) may run it.
func TestExecuteRealNounFreeTextInfersSoleVerb(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)
	// Point at a closed port: the inference is what is under test, not the HTTP
	// round trip, and this keeps the test off any locally-running Barkpark.
	t.Setenv("BARKPARK_API_URL", "http://127.0.0.1:1")

	out, _ := captureExecuteCode(t, []string{"search", "PDS crown proof"})

	// The regression itself: the noun must never be reported as unknown. Match
	// both the human line and the JSON error envelope (which escapes the quotes).
	if strings.Contains(out, `unknown command "search"`) || strings.Contains(out, `unknown command \"search\"`) {
		t.Errorf("real noun `search` reported as an unknown command; got:\n%s", out)
	}
	// …and the corrected command must be named, verbatim and runnable.
	if !strings.Contains(out, "barkpark search query") {
		t.Errorf("output never names `barkpark search query`; got:\n%s", out)
	}
}

// TestExecuteRealNounMultiVerbNamesTheNoun guards the non-inferable half of the
// rule: `doc` has many verbs, so nothing is guessed — but the error must still
// say the NOUN is fine and list the verbs, and still exit 2.
func TestExecuteRealNounMultiVerbNamesTheNoun(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	out, code := captureExecuteCode(t, []string{"doc", "PDS crown proof"})

	if code != exitUsage {
		t.Errorf("usage error exit = %d, want %d", code, exitUsage)
	}
	if strings.Contains(out, `unknown command "doc"`) || strings.Contains(out, `unknown command \"doc\"`) {
		t.Errorf("real noun `doc` reported as an unknown command; got:\n%s", out)
	}
	if !strings.Contains(out, "no verb") || !strings.Contains(out, "known noun") {
		t.Errorf("error does not name the real problem; got:\n%s", out)
	}
}

// TestExecuteUnknownNounStillSuggests is the no-regression guard: a genuinely
// unknown noun keeps its noun-typo suggestion and its exit code, and an
// unrelated word still gets no misleading hint.
func TestExecuteUnknownNounStillSuggests(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	out, code := captureExecuteCode(t, []string{"serach", "query", "x"})
	if code != exitUsage {
		t.Errorf("unknown-noun exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(out, `unknown command \"serach\"`) && !strings.Contains(out, `unknown command "serach"`) {
		t.Errorf("unknown noun lost its unknown-command line; got:\n%s", out)
	}
	// An unknown noun must never be mistaken for the known-noun path.
	if strings.Contains(out, "no verb") {
		t.Errorf("unknown noun took the known-noun error path; got:\n%s", out)
	}

	// The suggestion block itself (usageSuggestNouns) is human-output only, so
	// assert its matcher directly: the typo still resolves, the unrelated word
	// still gets nothing. TestNearestNoun pins the shared table.
	nouns := tree0(t).NounNames()
	if best, ok := nearestNoun("serach", nouns); !ok || best != "search" {
		t.Errorf("nearestNoun(serach) = %q,%v; want search,true", best, ok)
	}
	if best, ok := nearestNoun("zqxwvut", nouns); ok {
		t.Errorf("unrelated word got a misleading suggestion: %q", best)
	}
}

// tree0 loads the full fixture manifest tree for the dispatch tests above.
func tree0(t *testing.T) *manifest.Tree {
	t.Helper()
	_, tr := loadTreeFrom(t, fullManifest)
	return tr
}

// TestSoleReadVerbRule drives the inference predicate directly, including the
// cases the fixture manifest cannot express (a WRITING sole verb).
func TestSoleReadVerbRule(t *testing.T) {
	_, tree := loadTreeFrom(t, fullManifest)

	search, ok := lookupNoun(tree, "search")
	if !ok {
		t.Fatal("search noun missing from the fixture manifest")
	}
	if sole, inferable := soleReadVerb(search, "PDS crown proof"); !inferable || sole.Verb != "query" {
		t.Errorf("soleReadVerb(search, free text) = %v,%v; want query,true", sole, inferable)
	}
	// A near-typo of the sole verb is a mistyped VERB, not an argument — it must
	// fall through to the typo suggestion rather than be forwarded as a query.
	if _, inferable := soleReadVerb(search, "quer"); inferable {
		t.Error("a near-typo of the sole verb must not be inferred as an argument")
	}
	// Flag-shaped and empty tokens are never arguments to an inferred verb.
	for _, typed := range []string{"--json", "-x", ""} {
		if _, inferable := soleReadVerb(search, typed); inferable {
			t.Errorf("soleReadVerb(search, %q) fired; want no inference", typed)
		}
	}

	// Multi-verb noun: never guess across several verbs.
	doc, _ := lookupNoun(tree, "doc")
	if _, inferable := soleReadVerb(doc, "PDS crown proof"); inferable {
		t.Error("multi-verb noun must never infer a verb")
	}

	// A destructive sole verb is suggested, never run.
	destructive := &manifest.TreeNoun{
		Name:  "nuke",
		Verbs: []*manifest.Command{{Noun: "nuke", Verb: "purge", Writes: true}},
	}
	if _, inferable := soleReadVerb(destructive, "everything"); inferable {
		t.Error("a writing sole verb must never be inferred")
	}
	if msg := noVerbMsg(destructive, "nuke", "everything"); !strings.Contains(msg, "barkpark nuke purge everything") {
		t.Errorf("noVerbMsg must name the literal corrected command; got %q", msg)
	}
}

// TestApplyQueryRepeatableFilterEmitsListForm pins the CLI half of Gyldendal
// finding #16: two `--filter` clauses must reach the server as a LIST the API
// AND-composes, not as a duplicate scalar key whose surviving value depends on
// Plug's decode order (the same pair returned 3 rows or 17 depending purely on
// argument order, at 200 OK, with no warning).
//
// MUTATION PROOF: drop the `f.Repeatable && len(vals) > 1` branch in applyQuery
// and the two-value case reds with `filter=…&filter=…` (the ambiguous shape).
func TestApplyQueryRepeatableFilterEmitsListForm(t *testing.T) {
	cmd := manifest.Command{
		Noun: "doc", Verb: "query", Paginated: true,
		Flags: []manifest.Flag{
			{Name: "filter", Type: "string", Repeatable: true},
			{Name: "perspective", Type: "string"},
		},
	}
	base := "https://api.barkpark.cloud/v1/data/query/production/post"

	// Two clauses → the bracket list form, BOTH values preserved and ordered.
	got := applyQuery(base, globals{}, cmd,
		map[string][]string{"filter": {"status=published", "title=Alpha"}},
		map[string]string{})
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("bad url: %v", err)
	}
	q := u.Query()
	if q.Has("filter") {
		t.Errorf("two --filter values must NOT ride as a duplicate scalar key; got %q", got)
	}
	list := q["filter[]"]
	if len(list) != 2 || list[0] != "status=published" || list[1] != "title=Alpha" {
		t.Errorf("both clauses must ride as filter[]; got %q (%v)", got, list)
	}

	// One clause → the plain scalar spelling, unchanged from before.
	gotOne := applyQuery(base, globals{}, cmd,
		map[string][]string{"filter": {"status=published"}}, map[string]string{})
	u1, err := url.Parse(gotOne)
	if err != nil {
		t.Fatalf("bad url: %v", err)
	}
	if u1.Query().Get("filter") != "status=published" || u1.Query().Has("filter[]") {
		t.Errorf("a single --filter must keep the plain scalar form; got %q", gotOne)
	}

	// A NON-repeatable flag is untouched by the list rule (no manifest flag
	// declares repeatable today except set/filter, and only filter is a query param).
	gotNonRep := applyQuery(base, globals{}, cmd,
		map[string][]string{"perspective": {"drafts", "raw"}}, map[string]string{})
	if un, _ := url.Parse(gotNonRep); un.Query().Has("perspective[]") {
		t.Errorf("a non-repeatable flag must not switch to the list form; got %q", gotNonRep)
	}
}

// The fenced_off hint used to name only "lease swept or a blocker/move fenced
// you" — and in the common case NEITHER has happened. `bp task pulse`
// INCREMENTS the claim epoch (measured live 2026-08-24: 3 → 4 across a single
// pulse), so a worker that heartbeats while it works is fenced by its OWN pulse
// and the old copy sent it hunting a cause that did not exist. The trap is
// written up in docs/contracts/roster-reading.md, Trap 7.
func TestFencedOffHintNamesThePulse(t *testing.T) {
	h := (apiError{code: "fenced_off"}).hint()
	if !strings.Contains(h, "pulse") {
		t.Errorf("fenced_off hint = %q, want it to name `bp task pulse` — the usual cause", h)
	}
	if strings.Contains(h, "blocker/move fenced you") {
		t.Errorf("fenced_off hint still carries the misleading copy: %q", h)
	}
	// The claim-race codes keep their own copy on purpose: their epoch moved
	// because someone ELSE acted on the row, so blaming the caller's own pulse
	// would be exactly as wrong as the copy this test retires.
	race := (apiError{code: "stale_claim"}).hint()
	if race == h {
		t.Errorf("stale_claim shares the fenced_off hint %q — the causes differ", race)
	}
	if strings.Contains(race, "pulse") {
		t.Errorf("stale_claim hint = %q, must not blame the caller's own pulse", race)
	}
}

// --- drafts.-addressed public reads ------------------------------------------

// TestBuildManifestRequestAuthenticatesDraftIDOnPublicRead pins the fix for the
// `bp doc get <type> drafts.<id>` false not_found: a tier-`none` read that
// ADDRESSES a draft in the id must carry the bearer, while the same command
// addressing a published id must stay byte-for-byte public.
func TestBuildManifestRequestAuthenticatesDraftIDOnPublicRead(t *testing.T) {
	m, tree := loadFixtureTree(t)
	cmd, ok := tree.Lookup("doc", "get")
	if !ok {
		t.Fatal("doc get missing")
	}
	// The LIVE manifest declares doc.get at auth_tier "none" (the fixture still
	// carries the older "read"); the whole defect lives in that tier.
	cmd.AuthTier = "none"

	ctx := manifest.Context{
		Server:  "https://api.barkpark.cloud",
		Dataset: "production",
		Token:   "draft-reader-token",
	}

	t.Run("drafts_id_carries_bearer", func(t *testing.T) {
		req, derr := buildManifestRequest(
			globals{}, ctx, m, *cmd,
			[]string{"paper", "drafts.l5goc-draft-probe-2"},
			false,
		)
		if derr != nil {
			t.Fatalf("buildManifestRequest: %v", derr)
		}
		if got := req.headers["Authorization"]; got != "Bearer draft-reader-token" {
			t.Errorf("Authorization = %q, want %q - a drafts. id read tokenless can only ever answer not_found",
				got, "Bearer draft-reader-token")
		}
	})

	// NEGATIVE ARM: the published read must not gain a credential. A fix that
	// attaches the bearer unconditionally fails here.
	t.Run("plain_id_stays_public", func(t *testing.T) {
		req, derr := buildManifestRequest(
			globals{}, ctx, m, *cmd,
			[]string{"paper", "l5goc-draft-probe-2"},
			false,
		)
		if derr != nil {
			t.Fatalf("buildManifestRequest: %v", derr)
		}
		if got := req.headers["Authorization"]; got != "" {
			t.Errorf("Authorization = %q, want the published read to stay byte-for-byte public", got)
		}
	})
}

// TestBuildManifestRequestRejectsDraftIDWithoutToken is the row's literal
// acceptance criterion: with no token the CLI must fail with an error that NAMES
// the addressing problem, never let the server answer a bare not_found.
func TestBuildManifestRequestRejectsDraftIDWithoutToken(t *testing.T) {
	m, tree := loadFixtureTree(t)
	cmd, ok := tree.Lookup("doc", "get")
	if !ok {
		t.Fatal("doc get missing")
	}
	cmd.AuthTier = "none"

	_, derr := buildManifestRequest(
		globals{},
		manifest.Context{Server: "https://api.barkpark.cloud", Dataset: "production"},
		m,
		*cmd,
		[]string{"paper", "drafts.l5goc-draft-probe-2"},
		false,
	)
	if derr == nil {
		t.Fatal("a drafts. id without a token must fail loudly, not send an anonymous request that 404s")
	}
	if !strings.Contains(derr.Error(), "drafts. document id requires an API token") {
		t.Errorf("error = %q, want it to name the drafts. addressing problem", derr)
	}
	if !strings.Contains(derr.Error(), "not_found") {
		t.Errorf("error = %q, want it to explain the bare not_found it prevents", derr)
	}
}

// TestDraftIDRequiresAuthIgnoresAuthenticatedTiers is the second negative arm:
// every tier above "none" already attaches the bearer in authHeaders, so the
// guard must stay out of the way there.
func TestDraftIDRequiresAuthIgnoresAuthenticatedTiers(t *testing.T) {
	_, tree := loadFixtureTree(t)
	cmd, ok := tree.Lookup("doc", "get")
	if !ok {
		t.Fatal("doc get missing")
	}
	args := map[string]string{"type": "paper", "doc_id": "drafts.l5goc-draft-probe-2"}

	for _, tier := range []string{"read", "write", "admin", "scoped_admin", "ingest"} {
		c := *cmd
		c.AuthTier = tier
		if draftIDRequiresAuth(c, args) {
			t.Errorf("draftIDRequiresAuth = true for tier %q, want false - authHeaders already attaches the bearer", tier)
		}
	}

	c := *cmd
	c.AuthTier = "none"
	if !draftIDRequiresAuth(c, args) {
		t.Error("draftIDRequiresAuth = false for tier none + a drafts. id, want true")
	}
	if draftIDRequiresAuth(c, map[string]string{"type": "paper", "doc_id": "l5goc-draft-probe-2"}) {
		t.Error("draftIDRequiresAuth = true for a published id, want false")
	}
}
