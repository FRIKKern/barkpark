package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE DEFECT this file pins (task-621bcf889e730f4c).
//
// Measured 2026-09-11 against guerrilla.barkpark.cloud with
// BARKPARK_TOKEN=not-a-real-token:
//
//	GET /v1/capabilities            <- Authorization: Bearer not-a-real-token
//	                                   200, auth_tier "none"
//	GET /w/…/v1/data/query/production/task?limit=1
//	                                <- NO Authorization header at all
//	                                   200, a full shaped listing; bp exits 0
//
// The same query WITH the garbage bearer is 401 server-side. So a credential
// the server would refuse was laundered into an anonymous 200 and rc=0, and
// every "read something, rc=0 ⇒ my token works" preflight inherited it.
//
// The mechanism is authHeaders' `case "none": // send nothing` — the live
// manifest declares doc.ls/doc.get/doc.query/search.query at auth_tier "none",
// so bp deliberately withheld a bearer it was holding. The floor is right for a
// caller with NO credential; it is wrong for one who has configured a token.
//
// Fixture manifest: doc.ls on the real route, at the real command tier "none".
// The MANIFEST-level auth_tier is the CALLER tier the server echoes — it is the
// discriminator for the second half of the fix, so each test sets it.
const refusedCredManifestTemplate = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "auth_tier": "CALLERTIER",
  "nouns": [{"name": "doc", "summary": "Docs."}],
  "commands": [
    {"id":"doc.ls","noun":"doc","verb":"ls","summary":"List documents.",
     "http":{"method":"GET","path_template":"/v1/data/query/:dataset/:type"},
     "auth_tier":"none",
     "args":[{"name":"type","required":true,"type":"string","in":"path"}],
     "flags":[{"name":"limit","type":"int"}],
     "writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"}
  ]
}`

type refusedCredServer struct {
	*httptest.Server
	queryHits int
	lastAuth  string
	sawHeader bool
}

// newRefusedCredServer stands in for guerrilla on the query route: it records
// whether an Authorization header arrived and answers 200 with a shaped page.
func newRefusedCredServer() *refusedCredServer {
	s := &refusedCredServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		s.queryHits++
		s.lastAuth = req.Header.Get("Authorization")
		_, s.sawHeader = req.Header["Authorization"]
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(http.StatusOK)
		_, _ = rw.Write([]byte(`{"result":{"documents":[{"_id":"task-1","_type":"task","title":"a row"}]}}`))
	}))
	return s
}

func refusedCredManifest(t *testing.T, baseURL, callerTier string) *manifest.Manifest {
	t.Helper()
	raw := strings.Replace(refusedCredManifestTemplate, "http://replaced", baseURL, 1)
	raw = strings.Replace(raw, "CALLERTIER", callerTier, 1)
	m, err := manifest.Parse([]byte(raw))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	return m
}

func refusedCredRun(t *testing.T, m *manifest.Manifest, srvURL, token string) (int, string) {
	t.Helper()
	cmd, ok := m.Tree().Lookup("doc", "ls")
	if !ok {
		t.Fatalf("fixture manifest has no doc ls")
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true, output: "json", outputSet: true}
	w.applyGlobals(g)
	ctx := manifest.Context{Server: srvURL, Dataset: "production", Workspace: "w", Project: "p", Token: token}
	code := runCommand(w, g, ctx, m, *cmd, []string{"task"})
	return code, so.String() + se.String()
}

// TestQueryReadCarriesConfiguredBearer is THE DETECTOR for the fix's first half.
// A token the server ACCEPTED (caller tier admin) must still ride the tier-"none"
// query read. RED on origin/main: authHeaders' `case "none"` sent nothing, so the
// server saw no Authorization header at all.
func TestQueryReadCarriesConfiguredBearer(t *testing.T) {
	srv := newRefusedCredServer()
	defer srv.Close()

	m := refusedCredManifest(t, srv.URL, "admin")
	code, rendered := refusedCredRun(t, m, srv.URL, "bppat_good_token")

	t.Logf("exit=%d Authorization=%q header_present=%v out=%s", code, srv.lastAuth, srv.sawHeader, rendered)
	if srv.queryHits != 1 {
		t.Fatalf("query hits = %d, want 1 — the read never reached the server", srv.queryHits)
	}
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (an accepted token must not break the public read)", code)
	}
	if !srv.sawHeader {
		t.Fatalf("the /v1/data/query read went out with NO Authorization header while a token was configured — a refused credential would be laundered into an anonymous 200")
	}
	if srv.lastAuth != "Bearer bppat_good_token" {
		t.Fatalf("Authorization = %q, want %q", srv.lastAuth, "Bearer bppat_good_token")
	}
}

// TestRefusedCredentialIsNotAnonymity is the second half: when
// /v1/capabilities resolved auth_tier "none" for a PRESENT token — the server
// saying "I do not know this credential" — the read refuses BY NAME instead of
// falling through to an anonymous 200. The server must not be touched at all.
func TestRefusedCredentialIsNotAnonymity(t *testing.T) {
	srv := newRefusedCredServer()
	defer srv.Close()

	m := refusedCredManifest(t, srv.URL, "none")
	code, rendered := refusedCredRun(t, m, srv.URL, "not-a-real-token")

	t.Logf("exit=%d out=%s", code, rendered)
	if srv.queryHits != 0 {
		t.Fatalf("query hits = %d, want 0 — a refused credential must not produce a read at all", srv.queryHits)
	}
	if code != exitAuth {
		t.Fatalf("exit = %d, want exitAuth (%d)", code, exitAuth)
	}
	if !strings.Contains(rendered, "refused") || !strings.Contains(rendered, "auth_tier") {
		t.Fatalf("the refusal does not name the refused credential:\n%s", rendered)
	}
}

// TestTokenlessReadStaysAnonymous is THE CONTROL for the test above. Without the
// control the refusal could simply be "tier none never reads", which would break
// every genuinely anonymous caller — the public floor this fix must preserve.
func TestTokenlessReadStaysAnonymous(t *testing.T) {
	srv := newRefusedCredServer()
	defer srv.Close()

	m := refusedCredManifest(t, srv.URL, "none")
	code, rendered := refusedCredRun(t, m, srv.URL, "")

	t.Logf("exit=%d Authorization=%q header_present=%v out=%s", code, srv.lastAuth, srv.sawHeader, rendered)
	if srv.queryHits != 1 {
		t.Fatalf("query hits = %d, want 1 — a tokenless caller must still read published documents", srv.queryHits)
	}
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 for an anonymous published read", code)
	}
	if srv.sawHeader {
		t.Fatalf("a tokenless invocation sent Authorization=%q", srv.lastAuth)
	}
	if !strings.Contains(rendered, "task-1") {
		t.Fatalf("the anonymous read returned no documents:\n%s", rendered)
	}
}
