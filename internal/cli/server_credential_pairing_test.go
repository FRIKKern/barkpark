package cli

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// server_credential_pairing_test.go — THE BINDING (task-c05d0f7fa7bef688).
//
// THE DECISION THESE TESTS GUARD, in one sentence: a credential that won at the
// ACTIVE layer (the saved config, or the repo file's saved server entry) is
// PAIRED to the server that layer recorded it for, and is withheld — falling to
// the baked dev floor, never to empty — when the resolved server is a different
// host. The reasoning, and what it costs, is written at resolveContextProv's
// "THE BINDING" block, which is where a reader editing the resolver meets it.
//
// WHAT WAS MEASURED BEFORE THE BINDING, live on 2026-09-16, with a local server
// that recorded the Authorization header of every request it received:
//
//	config.json saved for https://guerrilla.barkpark.cloud, token 41 chars
//	bp -s http://127.0.0.1:47391 task ready
//	  -> GET /v1/capabilities?views=1&chat=1  Authorization: Bearer <41 chars>
//	BARKPARK_API_URL=http://127.0.0.1:47391 bp task ready
//	  -> GET /v1/capabilities?views=1&chat=1  Authorization: Bearer <41 chars>
//
// i.e. the saved credential left the machine on the FIRST request — the manifest
// fetch, before any command dispatch — to a host it was never saved for. After
// the binding both arms record 18 chars ("barkpark-dev-token", the public floor)
// and the same run against the server the credential IS saved for still records
// all 41.
//
// TestSavedCredentialIsWithheldFromAMismatchedServer is the INVERSION of the
// characterization test formerly named
// TestResolvedCredentialIsNotBoundToTheResolvedServer (doc_read_optional_auth_test.go),
// which asserted the pre-binding behaviour and was written to go red with
// "EXPECTATION CHANGED" if it ever moved. It moved; the record is kept by
// inverting rather than deleting, and the old name is carried here so a search
// for it lands on its successor.

// authRecorder is a fake Barkpark server that answers /v1/capabilities and the
// doc query route, and records the Authorization header of EVERY request. It is
// deliberately a HEADER recorder and not a string check on bp's output: the
// question is whether a credential reached the wire, and only the wire can
// answer it.
type authRecorder struct {
	*httptest.Server
	mu    sync.Mutex
	auths []string // one entry per request; "" when no header arrived
}

func (a *authRecorder) record(v string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.auths = append(a.auths, v)
}

func (a *authRecorder) seen() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]string, len(a.auths))
	copy(out, a.auths)
	return out
}

// sawCredential reports whether any request carried the given bearer value.
func (a *authRecorder) sawCredential(tok string) bool {
	for _, v := range a.seen() {
		if v == "Bearer "+tok {
			return true
		}
	}
	return false
}

const pairingManifestTemplate = `{
  "manifest_version": "1",
  "etag": "pairing",
  "server": {"name": "test", "base_url": "BASEURL"},
  "auth_tier": "read",
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

func newAuthRecorder() *authRecorder {
	a := &authRecorder{}
	a.Server = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		a.record(req.Header.Get("Authorization"))
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(http.StatusOK)
		if strings.HasPrefix(req.URL.Path, "/v1/capabilities") {
			_, _ = rw.Write([]byte(strings.Replace(pairingManifestTemplate, "BASEURL", a.URL, 1)))
			return
		}
		_, _ = rw.Write([]byte(`{"result":{"documents":[]}}`))
	}))
	return a
}

// savedFor writes a config.json whose ACTIVE server (and matching known_servers
// entry) is `server`, holding `token`. Invented credential values only — nothing
// here authenticates against anything.
func savedFor(t *testing.T, server, token string) {
	t.Helper()
	cfg := &Config{
		Server: server, Token: token,
		Workspace: "default", Project: "default", Dataset: "production",
		KnownServers: []ServerEntry{
			{Server: server, Token: token, Workspace: "default", Project: "default", Dataset: "production"},
		},
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

const (
	pairingSavedToken = "bppat_invented_for_host_a_authenticates_nothing"
	pairingHostA      = "https://guerrilla.barkpark.cloud"
)

// TestSavedCredentialIsWithheldFromAMismatchedServer is the RESOLUTION-level arm
// (aka TestResolvedCredentialIsNotBoundToTheResolvedServer, inverted).
//
// MUTATION PROOF, both directions, run 2026-09-16:
//   - delete the `if srcs.Token == manifest.LayerActive && …` block in
//     resolveContextProv -> the two WITHHELD arms fail, each naming the host pair.
//   - drop the `normalizeServerURL(active.Server) != normalizeServerURL(ctx.Server)`
//     conjunct so the binding fires on EVERY active-layer token -> the CONTROL
//     arm fails. That arm is not optional: a binding that withholds everywhere
//     passes the first arm and silently unauthenticates every command.
func TestSavedCredentialIsWithheldFromAMismatchedServer(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir())
	savedFor(t, pairingHostA, pairingSavedToken)

	// THE CONTROL: on the server the credential WAS saved for it is still sent.
	// Without this arm "the token is withheld" is equally satisfied by "the token
	// is never used", and the test would measure nothing.
	// TWO CONTROLS, because they travel through DIFFERENT layers and only the
	// second is in the binding's line of fire. `-s <saved-name>` resolves through
	// FindServer, which injects the entry's token at FLAG precedence — the binding
	// never looks there. The BARE invocation is the one whose token wins at the
	// ACTIVE layer, so it is the arm that reds when the binding over-fires; a
	// suite carrying only the `-s` control would have passed mutation 2 (the
	// host-mismatch conjunct removed) and measured nothing.
	if ctx := resolveContext(globals{server: pairingHostA}); ctx.Token != pairingSavedToken {
		t.Fatalf("CONTROL FAILED (-s <saved-name>): on its own server (%s) the saved token resolved to %q, "+
			"want the saved one", pairingHostA, ctx.Token)
	}
	if ctx, prov := resolveContextProv(globals{}); ctx.Token != pairingSavedToken || prov.credentialWithheld() {
		t.Fatalf("CONTROL FAILED (bare invocation, active layer): token=%q withheld_from=%q against the saved "+
			"server itself. The binding is over-firing and every authenticated command is now anonymous.",
			ctx.Token, prov.WithheldFrom)
	}

	// A raw -s naming a different host.
	ctx, prov := resolveContextProv(globals{server: "http://unrelated.example"})
	if ctx.Server != "http://unrelated.example" {
		t.Fatalf("server = %q, want the raw URL", ctx.Server)
	}
	if ctx.Token == pairingSavedToken {
		t.Fatalf("BINDING GONE — the credential saved for %s still followed -s http://unrelated.example. "+
			"resolveContextProv's THE BINDING block is the guard; it is not firing.", pairingHostA)
	}
	if ctx.Token != bakedDefaults().Token {
		t.Fatalf("withheld token fell to %q, want the baked floor %q — falling to EMPTY is the false-404 "+
			"shape the decision explicitly rejected", ctx.Token, bakedDefaults().Token)
	}
	if prov.WithheldFrom != pairingHostA {
		t.Fatalf("prov.WithheldFrom = %q, want %q — the notice must name the host the credential belongs to",
			prov.WithheldFrom, pairingHostA)
	}
	if n := prov.withheldNotice(ctx.Server); !strings.Contains(n, pairingHostA) ||
		!strings.Contains(n, "http://unrelated.example") {
		t.Fatalf("withheldNotice = %q, want BOTH hosts named", n)
	}

	// The same through the env layer, which is the dev-flow door.
	t.Setenv("BARKPARK_API_URL", "http://unrelated-env.example")
	viaEnv, envProv := resolveContextProv(globals{})
	if viaEnv.Server != "http://unrelated-env.example" {
		t.Fatalf("env server = %q", viaEnv.Server)
	}
	if viaEnv.Token == pairingSavedToken {
		t.Fatalf("BINDING GONE — the credential saved for %s still followed BARKPARK_API_URL to %s",
			pairingHostA, viaEnv.Server)
	}
	if viaEnv.Token != bakedDefaults().Token || envProv.WithheldFrom != pairingHostA {
		t.Fatalf("env arm: token=%q withheld_from=%q, want the baked floor and %q",
			viaEnv.Token, envProv.WithheldFrom, pairingHostA)
	}
}

// TestExplicitCredentialStillReachesAnyServer is the second half of the decision:
// the binding fires ONLY on the layer that RECORDS a home server. A --token typed
// on this command line, or a BARKPARK_API_TOKEN exported in this shell, is the
// operator pairing the two themselves, and is untouched. Without this arm the
// binding could quietly grow into "bp refuses every credential it did not save",
// which is a different and much larger decision.
func TestExplicitCredentialStillReachesAnyServer(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir())
	savedFor(t, pairingHostA, pairingSavedToken)

	const typed = "invented_typed_pairing_value"
	ctx, prov := resolveContextProv(globals{server: "http://elsewhere.example", token: typed})
	if ctx.Token != typed {
		t.Fatalf("--token to a mismatched host resolved %q, want the typed value — the binding is "+
			"over-firing onto the flag layer", ctx.Token)
	}
	if prov.credentialWithheld() {
		t.Fatalf("a typed --token must never be reported as withheld (from %q)", prov.WithheldFrom)
	}

	t.Setenv("BARKPARK_API_TOKEN", "invented_env_pairing_value")
	envCtx, envProv := resolveContextProv(globals{server: "http://elsewhere.example"})
	if envCtx.Token != "invented_env_pairing_value" || envProv.credentialWithheld() {
		t.Fatalf("BARKPARK_API_TOKEN to a mismatched host: token=%q withheld=%v, want the env value and no withholding",
			envCtx.Token, envProv.credentialWithheld())
	}
}

// TestNoAuthorizationHeaderCarriesASavedCredentialToAMismatchedHost is the WIRE
// arm, and it is the one that answers the question the row actually asks. The
// resolution arms above read a struct field; this one enters through Execute —
// the same path a real invocation takes, manifest fetch included — against a
// server that records the Authorization header of every request it receives, and
// asserts the saved credential appears in NONE of them.
//
// The manifest fetch is the point: it is the FIRST request bp issues and it
// happens before any command dispatch, so a guard that fires anywhere later has
// already leaked. Requests are asserted non-zero so the test cannot pass by the
// server never having been reached.
func TestNoAuthorizationHeaderCarriesASavedCredentialToAMismatchedHost(t *testing.T) {
	t.Run("mismatched host receives no saved credential", func(t *testing.T) {
		withTempConfigHome(t)
		clearBarkparkEnv(t)
		t.Chdir(t.TempDir())
		srv := newAuthRecorder()
		defer srv.Close()
		// Saved for host A; the recorder is a DIFFERENT host.
		savedFor(t, pairingHostA, pairingSavedToken)

		_, stderr, _ := captureExecuteArgv(t, "-s", srv.URL, "doc", "ls", "quiz")

		seen := srv.seen()
		if len(seen) == 0 {
			t.Fatalf("VACUOUS: the recorder received no request at all, so nothing was measured.\nstderr:\n%s", stderr)
		}
		if srv.sawCredential(pairingSavedToken) {
			t.Fatalf("LEAK: the credential saved for %s reached %s — %d request(s) recorded.\nstderr:\n%s",
				pairingHostA, srv.URL, len(seen), stderr)
		}
		if !strings.Contains(stderr, pairingHostA) {
			t.Fatalf("the withholding was SILENT — stderr must name %s before the request goes out.\nstderr:\n%s",
				pairingHostA, stderr)
		}
	})

	t.Run("control: the matching host still receives it", func(t *testing.T) {
		withTempConfigHome(t)
		clearBarkparkEnv(t)
		t.Chdir(t.TempDir())
		srv := newAuthRecorder()
		defer srv.Close()
		// Saved for the recorder itself — the ordinary authenticated flow.
		savedFor(t, srv.URL, pairingSavedToken)

		_, stderr, _ := captureExecuteArgv(t, "doc", "ls", "quiz")

		if len(srv.seen()) == 0 {
			t.Fatalf("VACUOUS control: no request reached the recorder.\nstderr:\n%s", stderr)
		}
		if !srv.sawCredential(pairingSavedToken) {
			t.Fatalf("CONTROL FAILED: the saved credential did NOT reach the server it was saved for (%s). "+
				"The binding is over-firing and every authenticated command is now anonymous.\n"+
				"headers seen: %d\nstderr:\n%s", srv.URL, len(srv.seen()), stderr)
		}
	})
}
