package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// destroyManifestJSON is the four-verb slice of the LIVE manifest this gate
// covers, copied field-for-field from what guerrilla.barkpark.cloud serves at
// GET /v1/capabilities (token.ls / token.revoke / workspace.member-ls /
// workspace.member-rm). Both destroy verbs carry the real scoped_prefix, so the
// URLs the fake server sees are the URLs the CLI sends.
const destroyManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [
    {"name": "token", "summary": "Tokens."},
    {"name": "workspace", "summary": "Tenancy."}
  ],
  "commands": [
    {"id":"token.ls","noun":"token","verb":"ls","summary":"Token inventory.",
     "http":{"method":"GET","path_template":"/v1/tokens"},
     "auth_tier":"scoped_admin","args":[],"flags":[],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"token.revoke","noun":"token","verb":"revoke","summary":"Revoke a token.",
     "http":{"method":"DELETE","path_template":"/v1/tokens/:id"},
     "auth_tier":"scoped_admin",
     "args":[{"name":"id","required":true,"type":"string","summary":"Token id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"workspace.member-ls","noun":"workspace","verb":"member-ls","summary":"Roster.",
     "http":{"method":"GET","path_template":"/v1/members"},
     "auth_tier":"scoped_admin","args":[],"flags":[],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"table","scoped_prefix":"/w/:workspace_slug/p/:project_slug"},
    {"id":"workspace.member-rm","noun":"workspace","verb":"member-rm","summary":"Remove a seat.",
     "http":{"method":"DELETE","path_template":"/v1/members/:principal_ref"},
     "auth_tier":"scoped_admin",
     "args":[{"name":"principal_ref","required":true,"type":"string","summary":"E-mail or id."}],
     "flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,
     "default_output":"minimal","scoped_prefix":"/w/:workspace_slug/p/:project_slug"}
  ]
}`

// destroyHarness stands up a fake instance and the parsed manifest pointed at
// it, and records every request path+method the CLI actually sends — the only
// way to prove the DELETE was withheld rather than merely unrendered.
type destroyHarness struct {
	t       *testing.T
	server  *httptest.Server
	m       *manifest.Manifest
	ctx     manifest.Context
	seen    []string
	tokens  string // JSON body served for GET .../v1/tokens
	members string // JSON body served for GET .../v1/members
	status  int    // status for the inventory GETs (0 -> 200)
}

func newDestroyHarness(t *testing.T) *destroyHarness {
	t.Helper()
	h := &destroyHarness{
		t:       t,
		tokens:  `{"tokens":[{"id":"ac8ff595-deff-4c51-b251-0d05e8414184","label":"ci-deploy","kind":"api","permissions":["read","write"],"dataset":"production","role":"admin","revoked_at":null,"expires_at":null}]}`,
		members: `{"members":[{"identity":"pelle@jarl.no","principal_type":"user","role":"owner"}]}`,
	}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		status := h.status
		if status == 0 {
			status = http.StatusOK
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/v1/tokens"):
			w.WriteHeader(status)
			_, _ = w.Write([]byte(h.tokens))
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/v1/members"):
			w.WriteHeader(status)
			_, _ = w.Write([]byte(h.members))
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"revoked":{"id":"ac8ff595-deff-4c51-b251-0d05e8414184"}}`))
		}
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(destroyManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	// The operator STATED this scope (-w acme -p site). Spelling that out is not
	// ceremony: false is the fail-closed zero value, so a Context literal that
	// omits these reads as "scope never stated" and every destroy below refuses.
	// See TestDestroyRefusesAmbientScope, which is that case on purpose.
	h.ctx = manifest.Context{
		Server:            h.server.URL,
		Token:             "tok",
		Workspace:         "acme",
		Project:           "site",
		Dataset:           "production",
		Output:            "json",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
	}
	return h
}

func (h *destroyHarness) lookup(noun, verb string) manifest.Command {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup(noun, verb)
	if !ok {
		h.t.Fatalf("fixture manifest has no %s %s", noun, verb)
	}
	return *cmd
}

// sent reports whether the harness saw the given "METHOD /path" request.
func (h *destroyHarness) sent(want string) bool {
	for _, got := range h.seen {
		if got == want {
			return true
		}
	}
	return false
}

// runDestroy drives the real runCommand — the whole guarded path, not
// confirmDestroy in isolation — so a future edit that moves or drops the gate
// call site reds these tests instead of passing on a bypassed helper.
func (h *destroyHarness) runDestroy(g globals, noun, verb string, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, h.lookup(noun, verb), tail)
	return code, so.String(), se.String()
}

// forceNonTTY pins the non-interactive shape — which is what `go test` already
// has (stdin is /dev/null) and, more to the point, what every CI script has.
// Pinning it explicitly keeps the test honest on a runner that holds a terminal.
func forceNonTTY(t *testing.T) {
	t.Helper()
	prev := destroyStdinIsTTY
	destroyStdinIsTTY = func(io.Reader) bool { return false }
	t.Cleanup(func() { destroyStdinIsTTY = prev })
}

func forceTTYAnswer(t *testing.T, answer string) {
	t.Helper()
	prevTTY, prevIn := destroyStdinIsTTY, destroyStdin
	destroyStdinIsTTY = func(io.Reader) bool { return true }
	destroyStdin = strings.NewReader(answer)
	t.Cleanup(func() { destroyStdinIsTTY, destroyStdin = prevTTY, prevIn })
}

// THE DEFECT. Before this gate, `bp token revoke <id>` against a non-prod
// target sent the DELETE with no prompt, no --yes, and no word about which
// credential was dying. The prod write-guard could not catch it: it is keyed on
// the target being prod, and this harness is 127.0.0.1.
func TestTokenRevokeNonTTYWithoutYesSendsNothing(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, _, stderr := h.runDestroy(globals{}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	if code == exitOK {
		t.Errorf("exit = %d (ok) — an unconfirmed credential destroy must not succeed", code)
	}
	if h.sent("DELETE /w/acme/p/site/v1/tokens/ac8ff595-deff-4c51-b251-0d05e8414184") {
		t.Error("the DELETE was sent without confirmation — the gate did not hold")
	}
	if !strings.Contains(stderr, "--yes") {
		t.Errorf("refusal never names the flag that unblocks it:\n%s", stderr)
	}
}

// The preview is the whole point: an operator must not be asked to approve a
// UUID they cannot see. Every identifying field the inventory carries has to
// reach stderr BEFORE the request goes out.
func TestTokenRevokePreviewNamesTheCredential(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	_, stdout, stderr := h.runDestroy(globals{}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	for _, want := range []string{"ci-deploy", "read,write", "production", "admin"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("preview omits %q — the operator cannot see what dies:\n%s", want, stderr)
		}
	}
	// The preview is diagnostics, not the answer: stdout must stay parseable
	// for `bp token revoke … -o json | jq`.
	if strings.Contains(stdout, "ci-deploy") {
		t.Errorf("preview leaked onto stdout, which must stay machine-clean:\n%s", stdout)
	}
	if !h.sent("GET /w/acme/p/site/v1/tokens") {
		t.Errorf("preview never read the inventory; requests seen: %v", h.seen)
	}
}

// --yes proceeds AND still previews. A script that revokes deliberately still
// gets a record of what it destroyed — the guarantee must not evaporate off-TTY.
func TestTokenRevokeYesProceedsAndStillPreviews(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, _, stderr := h.runDestroy(globals{yes: true}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	if code != exitOK {
		t.Errorf("exit = %d with --yes, want %d", code, exitOK)
	}
	if !h.sent("DELETE /w/acme/p/site/v1/tokens/ac8ff595-deff-4c51-b251-0d05e8414184") {
		t.Errorf("--yes did not reach the API; requests seen: %v", h.seen)
	}
	if !strings.Contains(stderr, "ci-deploy") {
		t.Errorf("--yes silenced the preview — WHAT was destroyed went unrecorded:\n%s", stderr)
	}
}

// Interactive: anything but y/yes aborts, and NOTHING is sent.
func TestTokenRevokeInteractiveAnswers(t *testing.T) {
	cases := []struct {
		name       string
		answer     string
		wantSent   bool
		wantExitOK bool
	}{
		{name: "y", answer: "y\n", wantSent: true, wantExitOK: true},
		{name: "yes", answer: "yes\n", wantSent: true, wantExitOK: true},
		{name: "uppercase Y", answer: "Y\n", wantSent: true, wantExitOK: true},
		{name: "n", answer: "n\n", wantSent: false, wantExitOK: false},
		{name: "bare newline", answer: "\n", wantSent: false, wantExitOK: false},
		{name: "EOF", answer: "", wantSent: false, wantExitOK: false},
		// A near-miss must NOT count as consent.
		{name: "yeah", answer: "yeah\n", wantSent: false, wantExitOK: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newDestroyHarness(t)
			forceTTYAnswer(t, tc.answer)

			code, _, _ := h.runDestroy(globals{}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

			gotSent := h.sent("DELETE /w/acme/p/site/v1/tokens/ac8ff595-deff-4c51-b251-0d05e8414184")
			if gotSent != tc.wantSent {
				t.Errorf("answer %q: DELETE sent = %v, want %v", tc.answer, gotSent, tc.wantSent)
			}
			if (code == exitOK) != tc.wantExitOK {
				t.Errorf("answer %q: exit = %d, wantOK = %v", tc.answer, code, tc.wantExitOK)
			}
		})
	}
}

// The seat destroy is gated on the same terms. Its arg is already readable, so
// what the preview owes the operator is the ROLE — removing an owner and
// removing a member are the same command line.
func TestMemberRmIsGatedAndNamesTheRole(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, _, stderr := h.runDestroy(globals{}, "workspace", "member-rm", "pelle@jarl.no")

	if code == exitOK {
		t.Errorf("exit = %d (ok) — an unconfirmed seat removal must not succeed", code)
	}
	if h.sent("DELETE /w/acme/p/site/v1/members/pelle@jarl.no") {
		t.Error("the DELETE was sent without confirmation — the gate did not hold")
	}
	if !strings.Contains(stderr, "owner") {
		t.Errorf("preview never named the role being removed:\n%s", stderr)
	}
}

// A verb NOT in the registry keeps its old path exactly: no preview read, no
// prompt, no extra request. The gate must cost nothing everywhere else.
func TestNonDestroyVerbIsUntouched(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, _, stderr := h.runDestroy(globals{}, "token", "ls")

	if code != exitOK {
		t.Errorf("exit = %d for token ls, want %d", code, exitOK)
	}
	if strings.Contains(stderr, "about to destroy") {
		t.Errorf("a read verb ran the destroy preview:\n%s", stderr)
	}
	if len(h.seen) != 1 {
		t.Errorf("token ls sent %d requests (%v), want exactly 1", len(h.seen), h.seen)
	}
}

// A preview that cannot resolve must SAY it could not, and must still gate. The
// failure mode this forbids is silence being read as "found it, looks fine".
func TestPreviewFailuresAreNamedAndStillGate(t *testing.T) {
	t.Run("id absent from the inventory", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)

		code, _, stderr := h.runDestroy(globals{}, "token", "revoke", "00000000-0000-0000-0000-000000000000")

		if code == exitOK {
			t.Error("an unresolvable target still succeeded — the gate opened on a failed preview")
		}
		if !strings.Contains(stderr, "no matching row") {
			t.Errorf("preview failure was not named:\n%s", stderr)
		}
	})

	t.Run("inventory read denied", func(t *testing.T) {
		h := newDestroyHarness(t)
		h.status = http.StatusForbidden
		forceNonTTY(t)

		_, _, stderr := h.runDestroy(globals{}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

		if !strings.Contains(stderr, "403") {
			t.Errorf("a denied inventory read was not reported:\n%s", stderr)
		}
	})

	t.Run("server has no sibling list verb", func(t *testing.T) {
		h := newDestroyHarness(t)
		forceNonTTY(t)
		// A stale server that serves the destroy verb but not the inventory.
		var raw map[string]any
		if err := json.Unmarshal([]byte(strings.Replace(destroyManifestJSON, "http://replaced", h.server.URL, 1)), &raw); err != nil {
			t.Fatalf("unmarshal fixture: %v", err)
		}
		var kept []any
		for _, c := range raw["commands"].([]any) {
			if c.(map[string]any)["id"] != "token.ls" {
				kept = append(kept, c)
			}
		}
		raw["commands"] = kept
		trimmed, err := json.Marshal(raw)
		if err != nil {
			t.Fatalf("marshal fixture: %v", err)
		}
		m, err := manifest.Parse(trimmed)
		if err != nil {
			t.Fatalf("parse trimmed fixture: %v", err)
		}
		h.m = m

		_, _, stderr := h.runDestroy(globals{yes: true}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

		if !strings.Contains(stderr, "token ls") {
			t.Errorf("a missing inventory verb was not reported:\n%s", stderr)
		}
	})
}

// --dry-run must stay a pure preview: it prints the request and sends nothing,
// including no confirmation prompt and no inventory read. The gate sits after
// the dry-run branch in runCommand; this pins that ordering.
func TestDryRunSkipsTheDestroyGate(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, _, _ := h.runDestroy(globals{dryRun: true}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	if code != exitOK {
		t.Errorf("--dry-run exit = %d, want %d", code, exitOK)
	}
	if len(h.seen) != 0 {
		t.Errorf("--dry-run made %d requests (%v), want none", len(h.seen), h.seen)
	}
}

// previewScalar must render a LIST, which run.go's scalarString cannot — and
// `permissions` is the field that decides whether revoking this token breaks a
// deploy or a read-only dashboard.
func TestPreviewScalarRendersEveryJSONShape(t *testing.T) {
	cases := []struct {
		name string
		in   any
		want string
	}{
		{"null", nil, ""},
		{"string", "ci-deploy", "ci-deploy"},
		{"list", []any{"read", "write"}, "read,write"},
		{"empty list", []any{}, ""},
		{"bool", true, "true"},
		{"int-valued float", float64(5), "5"},
		{"fractional float", 1.5, "1.5"},
		{"object", map[string]any{"a": float64(1)}, `{"a":1}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := previewScalar(tc.in); got != tc.want {
				t.Errorf("previewScalar(%#v) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// A field the server adds tomorrow must reach the preview, not be dropped by a
// client-side allowlist — the preview's job is to show what is there.
func TestDescribeDestroyRowKeepsUndeclaredFields(t *testing.T) {
	row := map[string]any{
		"label":      "ci-deploy",
		"revoked_at": nil,
		"zzz_new":    "surprise",
		"aaa_new":    "also",
	}
	got := describeDestroyRow(row, []string{"label", "revoked_at"})

	if !strings.HasPrefix(got, "label=ci-deploy") {
		t.Errorf("declared columns lost their order: %q", got)
	}
	if strings.Contains(got, "revoked_at=") {
		t.Errorf("a null rendered as an empty pair: %q", got)
	}
	for _, want := range []string{"aaa_new=also", "zzz_new=surprise"} {
		if !strings.Contains(got, want) {
			t.Errorf("undeclared field %q was dropped: %q", want, got)
		}
	}
	if strings.Index(got, "aaa_new") > strings.Index(got, "zzz_new") {
		t.Errorf("undeclared fields are not sorted, so the line is unstable: %q", got)
	}
}

// ── The scope must be STATED, not inherited ────────────────────────────────
//
// `bp token revoke <id>` with no -w resolved to /w/default/p/default/... and
// sent the DELETE there. The server's cross-tenant rail turns that into a 404
// — but only while `default` is empty or unreachable. On a local instance
// `default` is THE real, populated workspace, which is exactly the shape an
// operator develops against, so the mechanism making the misfire harmless is
// the last remaining layer AND the layer that varies by environment.

// ambient returns the harness context as it looks when the operator stated no
// scope at all: the values are the baked floor, and provenance says so.
func (h *destroyHarness) ambient() manifest.Context {
	c := h.ctx
	c.Workspace, c.Project = "default", "default"
	c.WorkspaceExplicit, c.ProjectExplicit = false, false
	return c
}

func TestDestroyRefusesAmbientScope(t *testing.T) {
	for _, verb := range []struct{ noun, verb, arg, path string }{
		{"token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184",
			"DELETE /w/default/p/default/v1/tokens/ac8ff595-deff-4c51-b251-0d05e8414184"},
		{"workspace", "member-rm", "pelle@jarl.no",
			"DELETE /w/default/p/default/v1/members/pelle@jarl.no"},
	} {
		t.Run(verb.noun+" "+verb.verb, func(t *testing.T) {
			h := newDestroyHarness(t)
			h.ctx = h.ambient()
			forceNonTTY(t)

			code, _, stderr := h.runDestroy(globals{}, verb.noun, verb.verb, verb.arg)

			if code == exitOK {
				t.Errorf("exit = %d (ok) — a destroy with an unstated scope must not succeed", code)
			}
			if h.sent(verb.path) {
				t.Error("the DELETE went to the ambient workspace — the scope gate did not hold")
			}
			// It must refuse BEFORE the preview: with no defensible workspace
			// there is nothing to preview against, and reading an ambient
			// inventory would put credentials on screen nobody asked for.
			if len(h.seen) != 0 {
				t.Errorf("refusal still made %d requests (%v), want none", len(h.seen), h.seen)
			}
			for _, want := range []string{"-w <workspace>", "-p <project>"} {
				if !strings.Contains(stderr, want) {
					t.Errorf("refusal does not name %q — it must say how to proceed:\n%s", want, stderr)
				}
			}
		})
	}
}

// --yes must NOT buy past an unstated scope. --yes answers "do you mean it?";
// it cannot answer "which workspace?", because the operator was never asked.
func TestAmbientScopeRefusalSurvivesYes(t *testing.T) {
	h := newDestroyHarness(t)
	h.ctx = h.ambient()
	forceNonTTY(t)

	code, _, stderr := h.runDestroy(globals{yes: true}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	if code == exitOK {
		t.Errorf("exit = %d — --yes bought past an unstated scope", code)
	}
	if len(h.seen) != 0 {
		t.Errorf("--yes sent %d requests (%v) with no stated scope, want none", len(h.seen), h.seen)
	}
	if !strings.Contains(stderr, "stated scope") {
		t.Errorf("refusal did not name the reason:\n%s", stderr)
	}
}

// PROVENANCE, NOT VALUE. A workspace genuinely NAMED `default` is a real
// workspace, and naming it explicitly must keep working — that is the case a
// `ctx.Workspace == "default"` check would have broken, and the reason the
// provenance flags exist at all.
func TestExplicitlyNamedDefaultWorkspaceIsAllowed(t *testing.T) {
	h := newDestroyHarness(t)
	h.ctx.Workspace, h.ctx.Project = "default", "default"
	h.ctx.WorkspaceExplicit, h.ctx.ProjectExplicit = true, true
	forceNonTTY(t)

	_, _, stderr := h.runDestroy(globals{yes: true}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	if strings.Contains(stderr, "stated scope") {
		t.Errorf("`-w default` was refused as if it were the ambient floor:\n%s", stderr)
	}
	if !h.sent("DELETE /w/default/p/default/v1/tokens/ac8ff595-deff-4c51-b251-0d05e8414184") {
		t.Errorf("an explicitly-named `default` workspace was blocked; requests: %v", h.seen)
	}
}

// One half stated and the other not: name only the half that is missing.
func TestPartialScopeNamesOnlyTheMissingHalf(t *testing.T) {
	h := newDestroyHarness(t)
	h.ctx.ProjectExplicit = false // -w given, -p omitted
	forceNonTTY(t)

	_, _, stderr := h.runDestroy(globals{}, "token", "revoke", "ac8ff595-deff-4c51-b251-0d05e8414184")

	if !strings.Contains(stderr, "-p <project>") {
		t.Errorf("the missing half was not named:\n%s", stderr)
	}
	if strings.Contains(stderr, "-w <workspace>") {
		t.Errorf("a scope that WAS stated was reported missing:\n%s", stderr)
	}
}

// The gate costs non-destroy verbs nothing: a read with no stated scope keeps
// the ambient floor exactly as before. This is the blast-radius pin — if it
// ever reds, the change stopped being destroy-tier-only.
func TestAmbientScopeStillFineForReads(t *testing.T) {
	h := newDestroyHarness(t)
	h.ctx = h.ambient()
	forceNonTTY(t)

	code, stdout, stderr := h.runDestroy(globals{}, "token", "ls")

	if code != exitOK {
		t.Errorf("exit = %d — a READ with an unstated scope must still work, want %d", code, exitOK)
	}
	if strings.Contains(stderr, "stated scope") {
		t.Errorf("the scope gate fired on a read:\n%s", stderr)
	}
	if !strings.Contains(stdout, "ci-deploy") {
		t.Errorf("the read did not answer:\n%s", stdout)
	}
}

// commandReadsPlaceholder must look at the URL the command actually BUILDS —
// the scoped_prefix plus the flat template — since :workspace_slug lives in the
// prefix for every command in the registry. Reading only the flat template
// would find nothing and silently disarm the whole gate.
func TestCommandReadsPlaceholderSeesTheScopedPrefix(t *testing.T) {
	prefix := "/w/:workspace_slug/p/:project_slug"
	scoped := manifest.Command{
		HTTP:         manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/tokens/:id"},
		ScopedPrefix: &prefix,
	}
	if !commandReadsPlaceholder(scoped, "workspace_slug", "workspace", "ws") {
		t.Error("did not see :workspace_slug in the scoped_prefix — the gate would be dead")
	}
	if !commandReadsPlaceholder(scoped, "project_slug", "project", "p") {
		t.Error("did not see :project_slug in the scoped_prefix")
	}

	// A command with no prefix and no scope placeholder reads neither.
	flat := manifest.Command{HTTP: manifest.HTTP{Method: "DELETE", PathTemplate: "/v1/thing/:id"}}
	if commandReadsPlaceholder(flat, "workspace_slug", "workspace", "ws") {
		t.Error("claimed a flat command reads a workspace placeholder it does not have")
	}
}
