package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE DEFECT this file pins (gfr-bl-bp-auth-me-drops-saved-token).
//
// `bp auth me`, run seconds after a `bp whoami` that printed
// auth_tier:admin/token_present:true, answered:
//
//	authentication required — set BARKPARK_API_TOKEN or run: bp setup --target
//	connect --server <url> --token <token>
//
// The filing read that as "bp dropped the saved token". It did not: curl with
// the SAME bppat_ token gets the same 401, because GET /v1/auth/me sits behind
// require_user — a login SESSION, not a bearer. The server says exactly that in
// the envelope ("a valid login session is required"), and errorMessage() threw
// it away: `case "unauthorized":` returned a CONSTANT regardless of e.message.
//
// So the one fact that explained the refusal was dropped and replaced with
// advice the caller had already followed. That is the defect: a refusal must
// never name a remedy the caller already applied, and must never overwrite the
// server's account of which gate refused.

// unauthorizedManifestJSON declares auth.me on the route the live manifest uses,
// so the refusal travels the REAL dispatch path (runCommand → handleResponse →
// renderError) rather than a hand-called renderer. auth_tier `read` makes
// authHeaders attach the bearer, which is the whole premise of the assertion
// below: the token WAS sent.
const unauthorizedManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "auth", "summary": "Auth."}],
  "commands": [
    {"id":"auth.me","noun":"auth","verb":"me","summary":"Who am I.",
     "http":{"method":"GET","path_template":"/v1/auth/me"},
     "auth_tier":"read",
     "args":[],"flags":[],"writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"}
  ]
}`

// sessionRequiredBody is the live shape of the refusal, taken from
// guerrilla.barkpark.cloud: a canonical envelope whose message names the gate.
const sessionRequiredBody = `{"error":{"code":"unauthorized","message":"a valid login session is required","request_id":"req-abc"}}`

// TestUnauthorizedRefusalKeepsServerMessage is the end-to-end lock, in BOTH
// output shapes: with a token on the wire, a 401 render carries the server's
// own message and never tells the caller to go obtain a credential.
//
// RED before the fix in both shapes: the rendered message was the constant, so
// "a valid login session is required" was absent and "set BARKPARK_API_TOKEN"
// was present (twice — errorMessage and the code-keyed hint).
func TestUnauthorizedRefusalKeepsServerMessage(t *testing.T) {
	for _, output := range []string{"json", "table"} {
		t.Run(output, func(t *testing.T) {
			var sawAuth string
			srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
				sawAuth = req.Header.Get("Authorization")
				rw.Header().Set("Content-Type", "application/json")
				rw.WriteHeader(http.StatusUnauthorized)
				_, _ = rw.Write([]byte(sessionRequiredBody))
			}))
			defer srv.Close()

			m, err := manifest.Parse([]byte(strings.Replace(unauthorizedManifestJSON, "http://replaced", srv.URL, 1)))
			if err != nil {
				t.Fatalf("parse fixture manifest: %v", err)
			}
			cmd, ok := m.Tree().Lookup("auth", "me")
			if !ok {
				t.Fatalf("fixture manifest has no auth me")
			}

			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			g := globals{yes: true, output: output, outputSet: true}
			w.applyGlobals(g)
			ctx := manifest.Context{Server: srv.URL, Dataset: "production", Token: "bppat_saved_token"}
			code := runCommand(w, g, ctx, m, *cmd, nil)

			t.Logf("exit=%d stdout=%q stderr=%q", code, so.String(), se.String())
			if code != exitAuth {
				t.Fatalf("exit = %d, want exitAuth (%d)", code, exitAuth)
			}
			// Non-vacuity: the premise of the whole assertion is that a
			// credential reached the server. If it did not, "go get a token"
			// would be honest advice and this test would prove nothing.
			if !strings.HasPrefix(sawAuth, "Bearer bppat_") {
				t.Fatalf("no bearer reached the server (Authorization=%q) — the test cannot speak to a token-holder's refusal", sawAuth)
			}

			rendered := so.String() + se.String()
			if !strings.Contains(rendered, "a valid login session is required") {
				t.Errorf("the render dropped the server's message:\n%s", rendered)
			}
			for _, forbidden := range []string{"set BARKPARK_API_TOKEN", "bp setup --target connect"} {
				if strings.Contains(rendered, forbidden) {
					t.Errorf("a 401 answered to a token-holder still says %q:\n%s", forbidden, rendered)
				}
			}
			if output == "json" {
				var env struct {
					OK    bool `json:"ok"`
					Error struct {
						Code    string `json:"code"`
						Message string `json:"message"`
						Hint    string `json:"hint"`
					} `json:"error"`
				}
				if err := json.Unmarshal(so.Bytes(), &env); err != nil {
					t.Fatalf("stdout is not the JSON envelope (%v):\n%s", err, so.String())
				}
				if env.Error.Code != "unauthorized" {
					t.Errorf("error.code = %q, want unauthorized", env.Error.Code)
				}
				if !strings.Contains(env.Error.Message, "a valid login session is required") {
					t.Errorf("error.message = %q, want the server's message", env.Error.Message)
				}
				if env.Error.Hint == "" {
					t.Errorf("error.hint is empty — a refusal still owes a next step")
				}
			}
		})
	}
}

// TestUnauthorizedMessageAndHintSplitOnCredential pins the three cases at the
// unit seam, including the one that must NOT change: with no credential on the
// wire, "go set a token" is the right answer and stays byte-identical.
func TestUnauthorizedMessageAndHintSplitOnCredential(t *testing.T) {
	// 1. No credential, no server message: the historical copy, unchanged.
	bare := apiError{code: "unauthorized"}
	if got := bare.errorMessage(); got != "authentication required — set BARKPARK_API_TOKEN or run: bp setup --target connect --server <url> --token <token>" {
		t.Errorf("no-credential message changed: %q", got)
	}
	if got := bare.hint(); !strings.Contains(got, "set BARKPARK_API_TOKEN") {
		t.Errorf("no-credential hint = %q, want the get-a-token advice", got)
	}

	// 2. A credential WAS sent and the server named the gate: its words win,
	// and neither line names the remedy already applied.
	named := apiError{code: "unauthorized", message: "a valid login session is required", credentialSent: true}
	if got := named.errorMessage(); !strings.Contains(got, "a valid login session is required") {
		t.Errorf("message = %q, want the server's words", got)
	}
	for _, line := range []string{named.errorMessage(), named.hint()} {
		for _, forbidden := range []string{"set BARKPARK_API_TOKEN", "bp setup --target connect"} {
			if strings.Contains(line, forbidden) {
				t.Errorf("token-holder line %q still says %q", line, forbidden)
			}
		}
	}
	if named.hint() == "" {
		t.Errorf("token-holder hint is empty — the refusal owes a next step")
	}

	// 3. A credential was sent and the server said nothing: no message to
	// carry, but "go get a token" is still the wrong advice.
	silent := apiError{code: "unauthorized", credentialSent: true}
	for _, line := range []string{silent.errorMessage(), silent.hint()} {
		if strings.Contains(line, "set BARKPARK_API_TOKEN") {
			t.Errorf("silent-401 line to a token-holder still says set BARKPARK_API_TOKEN: %q", line)
		}
	}

	// 4. The server's own hint still outranks everything (unchanged ranking).
	withServer := apiError{code: "unauthorized", credentialSent: true, serverHint: "log in with the browser flow"}
	if got := withServer.hint(); got != "log in with the browser flow" {
		t.Errorf("serverHint no longer wins: %q", got)
	}
}
