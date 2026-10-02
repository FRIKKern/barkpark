package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// OPTIONAL-AUTH POLICY FOR THE PUBLIC READ VERBS (hq-doc-get-auth-tier-gap).
//
// doc.get / doc.ls / doc.query — and search.query, their fourth sibling — are
// declared `auth_tier: "none"` by the live server
// (api/lib/barkpark/plugins/capabilities.ex, core_commands/0). "none" is the
// CALLER FLOOR, not a prohibition: the route answers an anonymous caller, and it
// answers an authenticated one BETTER. The policy these tests pin, in one
// sentence each:
//
//  1. A configured credential RIDES every one of these reads, at the default
//     published perspective as much as at drafts/raw. Withholding it is what made
//     a `visibility: "private"` schema 404 to an admin — an authorization gap
//     that renders as an absence, indistinguishable from "the row is gone".
//  2. A caller with NO credential still sends NO Authorization header. The
//     published public read stays byte-for-byte what it was, and private
//     existence stays hidden by the SERVER, which is the only place an
//     existence-hiding floor can live.
//  3. The server, never the client, owns the verdict on a credential it does not
//     like: an invalid or foreign token keeps its 401/403/404 exactly as sent.
//     The one client-side refusal (refused_credential.go) fires only on the
//     server's own /v1/capabilities verdict, and it refuses LOUDLY rather than
//     laundering a refused token into an anonymous 200.
//
// MEASURED LIVE, 2026-09-15, one id
// (mediaAsset/asset-22050157-5c91-4d5d-b90d-969df6fbb92a) on
// guerrilla.barkpark.cloud, GET /v1/data/doc/production/mediaAsset/<id>:
//
//	no Authorization header       -> 404 {"error":{"code":"not_found",…}}
//	Bearer <this operator's token> -> 200 {"result":{…"_type":"mediaAsset"…}}
//	Bearer bppat_0000…0000 (foreign) -> 401 {"error":{"code":"unauthorized",…}}
//	Bearer not-a-real-token        -> 401 {"error":{"code":"unauthorized",…}}
//
// The 200 arm is the POSITIVE CONTROL for the 404 arm: same id, same route, same
// dataset, same perspective — so the 404 cannot be a wrong-slug artifact. No
// fixture was created or left behind; the row is pre-existing (created
// 2026-08-08) and was only read.
//
// TestPrivateSchemaReadIsAuthorizationShaped below reproduces exactly that
// four-arm shape hermetically, so the contract has a gate that runs in CI.

// docReadLiveShape returns doc.get / doc.ls / doc.query as the LIVE server
// publishes them — `auth_tier: "none"` with a declared `perspective` flag
// defaulting to published. It is hand-built, like searchQueryLiveShape, because
// docs/cli/fixtures/core-manifest.json predates the shape: it still carries all
// three at tier "read", and doc.ls/doc.query with no perspective flag at all, so
// a fixture-driven test of this contract would be vacuous.
func docReadLiveShape(id string) manifest.Command {
	perspective := manifest.Flag{Name: "perspective", Type: "string", Default: "published"}
	switch id {
	case "doc.get":
		return manifest.Command{
			ID: "doc.get", Noun: "doc", Verb: "get",
			HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:doc_id"},
			AuthTier: "none",
			Args: []manifest.Arg{
				{Name: "type", Required: true, Type: "string", In: "path"},
				{Name: "doc_id", Required: true, Type: "string", In: "path"},
			},
			Flags:         []manifest.Flag{perspective},
			DefaultOutput: "table",
		}
	case "doc.ls":
		return manifest.Command{
			ID: "doc.ls", Noun: "doc", Verb: "ls",
			HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"},
			AuthTier: "none",
			Args:     []manifest.Arg{{Name: "type", Required: true, Type: "string", In: "path"}},
			Flags: []manifest.Flag{
				{Name: "limit", Type: "int", Default: 100},
				{Name: "offset", Type: "int", Default: 0},
				perspective,
			},
			Paginated: true, DefaultOutput: "table",
		}
	case "doc.query":
		return manifest.Command{
			ID: "doc.query", Noun: "doc", Verb: "query",
			HTTP:     manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"},
			AuthTier: "none",
			Args:     []manifest.Arg{{Name: "type", Required: true, Type: "string", In: "path"}},
			Flags: []manifest.Flag{
				{Name: "filter", Type: "string", Repeatable: true},
				{Name: "limit", Type: "int", Default: 100},
				{Name: "offset", Type: "int", Default: 0},
				perspective,
			},
			Paginated: true, DefaultOutput: "table",
		}
	}
	panic("docReadLiveShape: unknown id " + id)
}

// docReadTails is the argument tail per verb, minus any --perspective.
var docReadTails = map[string][]string{
	"doc.get":   {"quiz", "quiz-private-1"},
	"doc.ls":    {"quiz"},
	"doc.query": {"quiz"},
}

// TestDocReadsAttachConfiguredBearerAtEveryPerspective is the request-builder
// arm of the fix (policy 1). Existing coverage proves it for search.query
// (perspective_search_test.go) and for doc.ls end-to-end
// (refused_credential_test.go); this extends it to all THREE doc read verbs and
// to the perspective axis at once, which is the product the row names.
//
// RED on the pre-fix tree: authHeaders' `case "none": // send nothing` returned
// an empty header map for the published and absent-flag arms, so
// req.headers["Authorization"] was "".
func TestDocReadsAttachConfiguredBearerAtEveryPerspective(t *testing.T) {
	m, _ := loadFixtureTree(t)
	ctx := manifest.Context{
		Server:  "https://guerrilla.barkpark.cloud",
		Dataset: "production",
		Token:   "bppat_admin_token",
	}

	for _, id := range []string{"doc.get", "doc.ls", "doc.query"} {
		cmd := docReadLiveShape(id)
		base := docReadTails[id]
		for _, perspective := range []string{"", "published", "drafts", "raw"} {
			name := id + "/" + perspective
			if perspective == "" {
				name = id + "/absent"
			}
			t.Run(name, func(t *testing.T) {
				tail := append([]string{}, base...)
				if perspective != "" {
					tail = append(tail, "--perspective", perspective)
				}
				req, derr := buildManifestRequest(globals{}, ctx, m, cmd, tail, false)
				if derr != nil {
					t.Fatalf("buildManifestRequest(%v): %v", tail, derr)
				}
				if got := req.headers["Authorization"]; got != "Bearer bppat_admin_token" {
					t.Fatalf(
						"%s went out with Authorization=%q, want the configured bearer. "+
							"A tokenless read of a visibility:private schema is a 404 the caller "+
							"cannot tell from a deleted row.",
						name, got,
					)
				}
			})
		}
	}
}

// TestDocReadsTokenlessPublishedStaysByteCompatible is THE CONTROL for the test
// above (policy 2). Without it, "attach the bearer" would also be satisfied by
// "tier none always authenticates", which has no anonymous caller left and would
// be a worse bug than the one being fixed: it would hand a credential to a route
// that never needed one.
//
// It asserts the strong form — not merely "Authorization is empty" but that the
// tokenless request is byte-identical to the token-present one in URL, method,
// body and every OTHER header. Only the Authorization key may differ.
func TestDocReadsTokenlessPublishedStaysByteCompatible(t *testing.T) {
	m, _ := loadFixtureTree(t)
	authed := manifest.Context{Server: "https://guerrilla.barkpark.cloud", Dataset: "production", Token: "bppat_admin_token"}
	anon := authed
	anon.Token = ""

	for _, id := range []string{"doc.get", "doc.ls", "doc.query"} {
		cmd := docReadLiveShape(id)
		for _, perspective := range []string{"", "published"} {
			name := id + "/absent"
			if perspective != "" {
				name = id + "/" + perspective
			}
			t.Run(name, func(t *testing.T) {
				tail := append([]string{}, docReadTails[id]...)
				if perspective != "" {
					tail = append(tail, "--perspective", perspective)
				}
				aReq, derr := buildManifestRequest(globals{}, authed, m, cmd, tail, false)
				if derr != nil {
					t.Fatalf("authed buildManifestRequest: %v", derr)
				}
				nReq, derr := buildManifestRequest(globals{}, anon, m, cmd, tail, false)
				if derr != nil {
					t.Fatalf("tokenless buildManifestRequest: %v", derr)
				}
				if got, ok := nReq.headers["Authorization"]; ok {
					t.Fatalf("%s tokenless request carries Authorization=%q — there is no credential to send", name, got)
				}
				if nReq.url != aReq.url {
					t.Fatalf("%s tokenless URL %q != authed URL %q", name, nReq.url, aReq.url)
				}
				if nReq.method != aReq.method {
					t.Fatalf("%s tokenless method %q != authed %q", name, nReq.method, aReq.method)
				}
				if !bytes.Equal(nReq.body, aReq.body) {
					t.Fatalf("%s tokenless body differs from authed body", name)
				}
				for k, v := range aReq.headers {
					if k == "Authorization" {
						continue
					}
					if nReq.headers[k] != v {
						t.Fatalf("%s header %q: tokenless %q != authed %q", name, k, nReq.headers[k], v)
					}
				}
				for k := range nReq.headers {
					if _, ok := aReq.headers[k]; !ok {
						t.Fatalf("%s tokenless request invented header %q", name, k)
					}
				}
			})
		}
	}
}

// privateSchemaServer models the SERVER half of the contract — the only place an
// existence-hiding floor can correctly live. It answers ONE id and keys purely on
// the credential it was shown, reproducing the four arms measured live against
// guerrilla (see the header comment).
type privateSchemaServer struct {
	*httptest.Server
	hits int
}

const (
	privateDocID    = "quiz-private-1"
	privateGoodTok  = "bppat_admin_token"
	privateOtherTok = "bppat_0000000000000000000000000000000000000000"
)

func newPrivateSchemaServer() *privateSchemaServer {
	s := &privateSchemaServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		s.hits++
		rw.Header().Set("Content-Type", "application/json")
		switch req.Header.Get("Authorization") {
		case "":
			// The false-404: a visibility:private schema hides EXISTENCE from an
			// anonymous caller. Indistinguishable from a deleted row — which is
			// the whole defect when the client withholds a token it holds.
			rw.WriteHeader(http.StatusNotFound)
			_, _ = rw.Write([]byte(`{"error":{"code":"not_found","message":"document not found"}}`))
		case "Bearer " + privateGoodTok:
			rw.WriteHeader(http.StatusOK)
			_, _ = rw.Write([]byte(`{"result":{"_id":"` + privateDocID + `","_type":"quiz","title":"a private row"}}`))
		default:
			// Invalid or foreign: the SERVER's verdict, surfaced as sent.
			rw.WriteHeader(http.StatusUnauthorized)
			_, _ = rw.Write([]byte(`{"error":{"code":"unauthorized","message":"missing or invalid token"}}`))
		}
	}))
	return s
}

// privateSchemaManifestTemplate carries doc.get on the real route at the real
// command tier "none". The TOP-LEVEL auth_tier is the caller tier the server
// echoed for this credential and is set per-arm: "admin" whenever the credential
// is one the server accepted, so refusedCredentialRefusal (which fires only on a
// server "none" verdict for a PRESENT token) stays out of the way.
const privateSchemaManifestTemplate = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "auth_tier": "CALLERTIER",
  "nouns": [{"name": "doc", "summary": "Docs."}],
  "commands": [
    {"id":"doc.get","noun":"doc","verb":"get","summary":"Fetch one document.",
     "http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","in":"path"},
             {"name":"doc_id","required":true,"type":"string","in":"path"}],
     "flags":[{"name":"perspective","type":"string","default":"published"}],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

func privateSchemaRun(t *testing.T, srvURL, callerTier, token string) (int, string) {
	t.Helper()
	raw := strings.Replace(privateSchemaManifestTemplate, "http://replaced", srvURL, 1)
	raw = strings.Replace(raw, "CALLERTIER", callerTier, 1)
	m, err := manifest.Parse([]byte(raw))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	cmd, ok := m.Tree().Lookup("doc", "get")
	if !ok {
		t.Fatalf("fixture manifest has no doc get")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true, output: "json", outputSet: true}
	w.applyGlobals(g)
	ctx := manifest.Context{Server: srvURL, Dataset: "production", Workspace: "w", Project: "p", Token: token}
	code := runCommand(w, g, ctx, m, *cmd, []string{"quiz", privateDocID})
	return code, so.String() + se.String()
}

// TestPrivateSchemaReadIsAuthorizationShaped is the hermetic reproduction of the
// live four-arm measurement (policy 1 + 2 + 3). All four arms read the SAME id
// on the SAME route, so the 404 arm cannot pass for a wrong-slug artifact: the
// authorized arm is its positive control and returns the row.
//
// RED on the pre-fix tree: the "authorized" arm sent no Authorization header, so
// it took the 404 branch — byte-identical to the anonymous arm. That identity IS
// the defect.
func TestPrivateSchemaReadIsAuthorizationShaped(t *testing.T) {
	// ARM 1 — POSITIVE CONTROL: authorized, same id, the row comes back.
	t.Run("authorized_returns_the_row", func(t *testing.T) {
		srv := newPrivateSchemaServer()
		defer srv.Close()
		code, out := privateSchemaRun(t, srv.URL, "admin", privateGoodTok)
		t.Logf("exit=%d hits=%d out=%s", code, srv.hits, out)
		if srv.hits != 1 {
			t.Fatalf("hits = %d, want 1", srv.hits)
		}
		if code != exitOK {
			t.Fatalf("exit = %d, want 0 — an authorized read of a private schema must succeed:\n%s", code, out)
		}
		if !strings.Contains(out, privateDocID) || !strings.Contains(out, "a private row") {
			t.Fatalf("the authorized read returned no row:\n%s", out)
		}
	})

	// ARM 2 — the false-404 without a credential, on the SAME id the control
	// just read successfully. Existence hiding is the SERVER's, and it stays.
	t.Run("anonymous_sees_a_false_404", func(t *testing.T) {
		srv := newPrivateSchemaServer()
		defer srv.Close()
		code, out := privateSchemaRun(t, srv.URL, "none", "")
		t.Logf("exit=%d hits=%d out=%s", code, srv.hits, out)
		if srv.hits != 1 {
			t.Fatalf("hits = %d, want 1 — the anonymous read must still be SENT", srv.hits)
		}
		if code == exitOK {
			t.Fatalf("exit = 0 — an anonymous caller must not see a private row:\n%s", out)
		}
		if !strings.Contains(out, "not_found") {
			t.Fatalf("the anonymous arm is not the server's not_found:\n%s", out)
		}
		if strings.Contains(out, "a private row") {
			t.Fatalf("PRIVATE CONTENT LEAKED to an anonymous caller:\n%s", out)
		}
	})

	// ARM 3 — a foreign token keeps the SERVER's 401. Not laundered into an
	// anonymous 200, and not rewritten by the client into a 404 either.
	t.Run("foreign_token_keeps_server_owned_401", func(t *testing.T) {
		srv := newPrivateSchemaServer()
		defer srv.Close()
		code, out := privateSchemaRun(t, srv.URL, "admin", privateOtherTok)
		t.Logf("exit=%d hits=%d out=%s", code, srv.hits, out)
		if srv.hits != 1 {
			t.Fatalf("hits = %d, want 1", srv.hits)
		}
		if code != exitAuth {
			t.Fatalf("exit = %d, want exitAuth (%d):\n%s", code, exitAuth, out)
		}
		if !strings.Contains(out, "unauthorized") {
			t.Fatalf("the foreign-token arm does not carry the server's verdict:\n%s", out)
		}
	})

	// ARM 4 — an invalid token the SERVER already told us about at
	// /v1/capabilities (caller tier "none" with a token present) is refused
	// client-side, one round trip earlier, and the read is never sent.
	t.Run("server_refused_credential_never_reads", func(t *testing.T) {
		srv := newPrivateSchemaServer()
		defer srv.Close()
		code, out := privateSchemaRun(t, srv.URL, "none", "not-a-real-token")
		t.Logf("exit=%d hits=%d out=%s", code, srv.hits, out)
		if srv.hits != 0 {
			t.Fatalf("hits = %d, want 0 — a refused credential must not read at all", srv.hits)
		}
		if code != exitAuth {
			t.Fatalf("exit = %d, want exitAuth (%d):\n%s", code, exitAuth, out)
		}
	})
}

// TestResolvedCredentialIsNotBoundToTheResolvedServer — INVERTED, NOT DELETED,
// and this block is the record of why it moved.
//
// It was a CHARACTERIZATION test: hq-doc-get-auth-tier-gap asked for proof that
// no credential is sent to a mismatched resolved server "under the existing
// context rules", and what it measured on 2026-09-15 was that THERE WERE NO SUCH
// RULES — Server and Token were picked by two independent precedence walks with
// nothing comparing them, so a credential saved for guerrilla followed any host
// a raw `-s` or BARKPARK_API_URL named. It asserted that behaviour and was
// written to fail with "EXPECTATION CHANGED" if it ever moved.
//
// task-c05d0f7fa7bef688 moved it. The gap was reproduced live on 2026-09-16
// against a header-recording server (the saved credential left on the FIRST
// request, /v1/capabilities, before any dispatch), the decision was taken to
// BIND a saved credential to the server it was saved for, and the assertions are
// now inverted — a withholding assertion plus both over-fire controls — under the
// name that describes the guarantee that now exists:
//
//	TestSavedCredentialIsWithheldFromAMismatchedServer
//	TestExplicitCredentialStillReachesAnyServer
//	TestNoAuthorizationHeaderCarriesASavedCredentialToAMismatchedHost
//
// all in internal/cli/server_credential_pairing_test.go, which carries the
// measurement, the decision, and the mutation proofs. Searching for the old name
// lands here, and here points at its successor; nothing about what was measured
// is lost.

// TestNoCLIInvocationResolvesAnEmptyToken records the second half of the same
// finding, and it is why the byte-compatible tokenless path above is a CODE
// contract rather than an observable CLI behaviour.
//
// bakedDefaults() is the lowest-precedence floor and it is NOT empty: it supplies
// Token "barkpark-dev-token". manifest.ResolveWithSources' pick() only falls
// through to that floor when every layer above is empty, and nothing ABOVE can
// set the token to the empty string — `--token ""` is dropped by resolveContext
// (`if g.token != ""`), and an empty env var is skipped by firstEnv. So an
// entirely unconfigured `bp doc get …` against a remote server sends
// `Authorization: Bearer barkpark-dev-token` to that server, and can never make
// the anonymous published request the tokenless arms above describe.
//
// Measured 2026-09-15: with XDG_CONFIG_HOME pointed at an empty directory and
// every BARKPARK_* var unset, `bp --server https://guerrilla.barkpark.cloud
// --token "" doc get mediaAsset <id>` exited with the refused-credential error
// naming guerrilla — i.e. the baked dev token was presented to production.
//
// Like the test above, this asserts CURRENT behaviour. If an anonymous mode is
// ever added (an empty baked token, or an explicit --anonymous), this test goes
// red and should be inverted.
//
// THE DECISION ON THIS ONE, task-c05d0f7fa7bef688, is CHANGE NOTHING — recorded
// here so the absence of a change is not mistaken for an oversight. Its sibling
// (the server<->credential binding) shipped; this did not, because they are
// different questions. The binding stops a SECRET reaching a host it was not
// issued for. This test is about the baked floor, `barkpark-dev-token`, which is
// a public well-known constant seeded by the `demo` profile (docs/auth.md §Dev
// token) — sending it discloses nothing. Making it empty means inventing an
// ANONYMOUS CLI tier: a contract change across every tier-"none" verb, `bp
// whoami`, and the refused-credential path, not a resolver tweak. Note that the
// binding deliberately withholds DOWN TO this floor rather than to empty,
// precisely so it does not decide this question by accident.
//
// So this stays a characterization test, asserting current behaviour, and keeps
// its "EXPECTATION CHANGED" red for whoever takes the anonymous-mode decision.
func TestNoCLIInvocationResolvesAnEmptyToken(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir())

	for _, g := range []globals{
		{},
		{token: ""},
		{server: "https://guerrilla.barkpark.cloud"},
		{server: "https://guerrilla.barkpark.cloud", token: ""},
	} {
		ctx := resolveContext(g)
		if ctx.Token == "" {
			t.Fatalf("EXPECTATION CHANGED — globals %+v resolved an EMPTY token. "+
				"An anonymous CLI mode now exists; invert this test and wire the tokenless "+
				"byte-compatible path to it.", g)
		}
		if ctx.Token != bakedDefaults().Token {
			t.Fatalf("globals %+v resolved token %q, want the baked floor %q", g, ctx.Token, bakedDefaults().Token)
		}
	}
}
