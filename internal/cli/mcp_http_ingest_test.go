package cli

// mcp_http_ingest_test.go — the AMBIENT INGEST boundary of `bp mcp serve --http`
// (task ve-bl-mcp-http-ingest-ambient).
//
// mcp_http_test.go already proves the api bearer is forward-through and that no
// ambient API token rides a remote caller's request. `auth_tier: ingest` is the
// tier that escaped that proof, because its credential never came from ctx.Token
// in the first place: ingestSecret (run.go) read BARKPARK_INGEST_TOKEN /
// PAPERFLOW_INGEST_TOKEN directly out of the process environment, AFTER
// newMCPHTTPHandler had scrubbed the process token and installed the caller's.
// So a remote caller presenting NO credential had its request signed with the
// serving process's ingest secret and the write was performed — a confused
// deputy, measured against a running `bp mcp serve --http` before the fix.
//
// Three obligations, one per test below:
//
//  1. DENY: ambient ingest secret in the environment + a caller with no
//     credential ⇒ the secret never leaves the process on any request, and the
//     downstream ingest is NEVER PERFORMED. Proven by a backend that counts
//     ingests only after its own auth gate — not by reading the tool's text.
//  2. ALLOW: a caller that presents the ingest credential itself is served, and
//     it arrives verbatim. The fix must be quiet on the legitimate path.
//  3. LOCAL UNCHANGED: an operator-local Context (AmbientCredentialsOK, what
//     ResolveWithSources produces for a plain `bp bulldocs ingest`) still reads
//     the env var. The boundary is the remote transport, not the CLI.

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpIngestManifest declares one `auth_tier: ingest` command — the shape every
// bulldocs.*, session.* and sheets.* verb has in the live manifest. doc.get
// rides along so the paper-resource template registers exactly as in production.
const mcpIngestManifest = `{
  "manifest_version": "1",
  "server": {"name": "test", "version": "0", "base_url": "http://x"},
  "auth_tier": "admin",
  "generated_at": "now",
  "etag": "e",
  "nouns": [{"name": "bulldocs", "summary": "papers"}, {"name": "doc", "summary": "docs"}],
  "commands": [
    {"id":"bulldocs.ingest","noun":"bulldocs","verb":"ingest","summary":"ingest a paper","http":{"method":"POST","path_template":"/v1/plugins/bulldocs/papers"},"auth_tier":"ingest","args":[{"name":"slug","required":true,"type":"string","summary":"slug"}],"flags":[],"writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"json"},
    {"id":"doc.get","noun":"doc","verb":"get","summary":"get","http":{"method":"GET","path_template":"/v1/data/doc/:dataset/:type/:doc_id"},"auth_tier":"read","args":[{"name":"type","required":true,"type":"string","summary":"t"},{"name":"doc_id","required":true,"type":"string","summary":"i"}],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

const (
	// The serving PROCESS's own ingest secret. Invented; authenticates nothing
	// anywhere. It must never appear on a request the process makes on a remote
	// caller's behalf.
	mcpAmbientIngestSecret = "AMBIENT-INGEST-SECRET-MUST-NEVER-BE-SENT"
	// The credential a legitimate caller presents for itself.
	mcpCallerIngestSecret = "caller-presented-ingest-credential"
)

// mcpIngestBackend is the stub Barkpark ingest route. Like the production
// RequireIngestToken plug, AUTH IS THE FIRST GATE: an unauthorised request is
// refused before any handler logic, so `performed` can only move for a request
// that actually carried the secret. That counter — not any string in the tool
// result — is what "the ingest never happened" is asserted against.
type mcpIngestBackend struct {
	mu        sync.Mutex
	auths     []string // Authorization header of every request seen ("" = absent)
	performed int      // ingests that got PAST the auth gate
}

func (b *mcpIngestBackend) snapshot() ([]string, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.auths...), b.performed
}

func (b *mcpIngestBackend) handler() http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		auth := req.Header.Get("Authorization")
		b.mu.Lock()
		b.auths = append(b.auths, auth)
		b.mu.Unlock()

		// BOTH secrets are VALID ingest credentials here, and that is the point:
		// on the real server the process's own BARKPARK_INGEST_TOKEN is a working
		// ingest token, so a stub that refused it would make `performed == 0`
		// true for the wrong reason and the deny assertion would measure nothing.
		// Modelled this way, `performed` moves iff SOME valid ingest credential
		// reached the route — which is exactly the question the deny path asks.
		if auth != "Bearer "+mcpCallerIngestSecret && auth != "Bearer "+mcpAmbientIngestSecret {
			rw.WriteHeader(http.StatusUnauthorized)
			io.WriteString(rw, `{"error":{"code":"unauthorized","message":"invalid or missing ingest token"}}`)
			return
		}
		b.mu.Lock()
		b.performed++
		b.mu.Unlock()
		io.WriteString(rw, `{"ok":true,"ingested":true}`)
	})
}

// newMCPIngestStack stands up the production stack with an ambient ingest secret
// planted in the environment — the exact deployment the row describes (a unit
// file that exports BARKPARK_INGEST_TOKEN) — and a base context resolved the way
// an operator's own would be (AmbientCredentialsOK true), so the test measures
// newMCPHTTPHandler's withdrawal of it rather than a context that never had it.
func newMCPIngestStack(t *testing.T) (*mcpIngestBackend, string) {
	t.Helper()
	t.Setenv("BARKPARK_INGEST_TOKEN", mcpAmbientIngestSecret)
	t.Setenv("PAPERFLOW_INGEST_TOKEN", "")

	backend := &mcpIngestBackend{}
	api := httptest.NewServer(backend.handler())
	t.Cleanup(api.Close)

	m, err := manifest.Parse([]byte(mcpIngestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	base := manifest.Context{
		Server:               api.URL,
		Token:                mcpHTTPAmbientToken,
		Dataset:              "production",
		AmbientCredentialsOK: true,
	}

	handler, err := newMCPHTTPHandler(newWriter(io.Discard, io.Discard), globals{}, base, m, "all", nil)
	if err != nil {
		t.Fatalf("newMCPHTTPHandler: %v", err)
	}
	front := httptest.NewServer(handler)
	t.Cleanup(front.Close)
	return backend, front.URL
}

func callIngestTool(t *testing.T, cs *mcp.ClientSession) *mcp.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "bp_bulldocs_ingest",
		Arguments: map[string]any{"slug": "a-paper"},
	})
	if err != nil {
		t.Fatalf("CallTool bp_bulldocs_ingest: %v", err)
	}
	return res
}

// TestMCPHTTPIngestDeniesAmbientProcessSecret is the deny-path proof. A remote
// caller presenting NO credential invokes the ingest-tier bridge tool while the
// serving process holds an ingest secret in its environment. Before the fix the
// downstream saw `Bearer <process secret>` and performed the write.
//
// REVERT ARM: restore the env-first lookup in ingestSecret (drop the
// ctx.AmbientCredentialsOK guard) and this test fails on BOTH assertions — the
// process secret appears in the recorded Authorization headers, and performed
// goes to 1.
func TestMCPHTTPIngestDeniesAmbientProcessSecret(t *testing.T) {
	backend, endpoint := newMCPIngestStack(t)
	cs := connectMCPHTTPClient(t, endpoint, "") // no Authorization header at all

	res := callIngestTool(t, cs)

	auths, performed := backend.snapshot()

	// THE load-bearing assertion: the ingest never happened. This is read off the
	// backend's own post-auth-gate counter, so it cannot be satisfied by a tool
	// result that merely looks like a refusal.
	if performed != 0 {
		t.Fatalf("downstream PERFORMED %d ingest(s) for a caller that presented no credential — the process ingest secret was lent out (auths=%q)", performed, auths)
	}
	// And the secret itself never left the process, on any request.
	for _, a := range auths {
		if strings.Contains(a, mcpAmbientIngestSecret) {
			t.Fatalf("the process's ambient ingest secret rode a remote caller's request: Authorization=%q", a)
		}
		if strings.Contains(a, mcpHTTPAmbientToken) {
			t.Fatalf("the process's ambient api token rode a remote caller's request: Authorization=%q", a)
		}
	}
	// The downstream 401 comes back as the tool result, so the caller is told
	// plainly rather than silently served.
	if res == nil || !res.IsError {
		t.Fatalf("expected the downstream refusal as an isError tool result, got %+v", res)
	}
	// Control on the control: the request DID reach the backend (so "performed==0"
	// is a refusal, not a test that measured nothing).
	if len(auths) == 0 {
		t.Fatalf("no downstream request was made at all — performed==0 proves nothing about the deny path")
	}
}

// TestMCPHTTPIngestForwardsCallerSuppliedSecret is the quiet-on-the-legitimate-
// path arm. A caller that HOLDS the ingest credential presents it as its own
// bearer; it must arrive verbatim and the ingest must be performed. This is what
// stops the deny arm from being satisfiable by simply breaking ingest tools.
func TestMCPHTTPIngestForwardsCallerSuppliedSecret(t *testing.T) {
	backend, endpoint := newMCPIngestStack(t)
	cs := connectMCPHTTPClient(t, endpoint, mcpCallerIngestSecret)

	res := callIngestTool(t, cs)

	auths, performed := backend.snapshot()
	if performed != 1 {
		t.Fatalf("a caller presenting the ingest credential itself was not served: performed=%d, auths=%q", performed, auths)
	}
	for _, a := range auths {
		if a != "Bearer "+mcpCallerIngestSecret {
			t.Fatalf("caller's own credential was not forwarded verbatim: Authorization=%q", a)
		}
	}
	if res == nil || res.IsError {
		t.Fatalf("authorized ingest returned an error result: %+v", res)
	}
}

// TestIngestSecretAmbientGate pins the gate itself at the unit it lives in, in
// both directions — so the rule is legible without standing a server up.
//
//   - An operator-local context (what ResolveWithSources produces) still reads
//     BARKPARK_INGEST_TOKEN, then the legacy PAPERFLOW_INGEST_TOKEN: a plain
//     `bp bulldocs ingest …` on a developer's laptop is byte-identical.
//   - A context WITHOUT that right — a per-request remote build, or any Context
//     literal, since false is the zero value — never consults the environment and
//     can only use the credential the request carried.
func TestIngestSecretAmbientGate(t *testing.T) {
	t.Setenv("BARKPARK_INGEST_TOKEN", "env-primary-secret")
	t.Setenv("PAPERFLOW_INGEST_TOKEN", "env-legacy-secret")

	local := manifest.Context{Token: "request-bearer", AmbientCredentialsOK: true}
	if got := ingestSecret(local); got != "env-primary-secret" {
		t.Fatalf("operator-local ingest lookup changed: got %q, want the env secret", got)
	}

	remote := manifest.Context{Token: "request-bearer"} // zero value = no ambient right
	if got := ingestSecret(remote); got != "request-bearer" {
		t.Fatalf("a context with no ambient right reached the environment: got %q, want the request's own credential", got)
	}

	// With no credential on the request either, there is nothing to send — the
	// fail-closed floor, not a silent substitution.
	if got := ingestSecret(manifest.Context{}); got != "" {
		t.Fatalf("credential-less remote request resolved a secret from somewhere: %q", got)
	}

	// The legacy var is gated too, not just the primary one.
	t.Setenv("BARKPARK_INGEST_TOKEN", "")
	if got := ingestSecret(manifest.Context{Token: "request-bearer"}); got != "request-bearer" {
		t.Fatalf("PAPERFLOW_INGEST_TOKEN escaped the gate: got %q", got)
	}
	if got := ingestSecret(manifest.Context{Token: "request-bearer", AmbientCredentialsOK: true}); got != "env-legacy-secret" {
		t.Fatalf("legacy env fallback lost for an operator-local context: got %q", got)
	}
}

// TestResolveGrantsAmbientCredentials pins the one place the right is granted:
// an operator-local resolution. If this ever stops being true, every ingest-tier
// `bp` command silently loses its env credential, so the grant is asserted where
// it is made rather than inferred from the commands that depend on it.
func TestResolveGrantsAmbientCredentials(t *testing.T) {
	ctx := manifest.Resolve(map[string]string{}, apiclient.Config{}, manifest.ActiveContext{}, manifest.DefaultDefaults())
	if !ctx.AmbientCredentialsOK {
		t.Fatalf("ResolveWithSources no longer grants ambient credentials — every local `bp` ingest command loses its env secret")
	}
}
