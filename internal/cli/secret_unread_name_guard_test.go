package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// secretManifestJSON is the slice of the LIVE manifest this guard needs, copied
// field-for-field from api/lib/barkpark/plugins/capabilities.ex (the four
// `secret.*` core_cmd blocks): the flat PUT /v1/secrets/:name and the scoped
// PUT /w/:ws/p/:proj/v1/secrets/:name, plus the masked `ls` as a NON-write
// control on the same noun.
const secretManifestJSON = `{
  "manifest_version": "1",
  "etag": "test",
  "server": {"name": "test", "base_url": "http://replaced"},
  "nouns": [{"name": "secret", "summary": "Cloud run-secrets."}],
  "commands": [
    {"id":"secret.ls","noun":"secret","verb":"ls","summary":"List run-secret names with masked values.",
     "http":{"method":"GET","path_template":"/v1/secrets"},
     "auth_tier":"admin","args":[],"flags":[],
     "writes":false,"batch":false,"paginated":false,"dry_run":false,"default_output":"table"},
    {"id":"secret.set","noun":"secret","verb":"set","summary":"Set or rotate a run-secret value.",
     "http":{"method":"PUT","path_template":"/v1/secrets/:name"},
     "auth_tier":"admin",
     "args":[{"name":"name","required":true,"type":"string","summary":"Secret name."},
             {"name":"value","required":true,"type":"string","summary":"Secret value."}],
     "flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"},
    {"id":"secret.scoped-set","noun":"secret","verb":"scoped-set","summary":"Set or rotate a workspace-scoped run-secret value.",
     "http":{"method":"PUT","path_template":"/w/:workspace_slug/p/:project_slug/v1/secrets/:name"},
     "auth_tier":"scoped_admin",
     "args":[{"name":"name","required":true,"type":"string","summary":"Secret name."},
             {"name":"value","required":true,"type":"string","summary":"Secret value."}],
     "flags":[],
     "writes":true,"batch":false,"paginated":false,"dry_run":false,"default_output":"minimal"}
  ]
}`

// secretHarness stands up a fake instance and records METHOD + path of every
// request the CLI actually sends. The recorded WIRE is the assertion: the
// refusal's whole promise is that no PUT goes out, which is a fact about the
// wire and never about the text on stderr.
type secretHarness struct {
	t      *testing.T
	server *httptest.Server
	m      *manifest.Manifest
	ctx    manifest.Context
	seen   []string
}

func newSecretHarness(t *testing.T) *secretHarness {
	t.Helper()
	h := &secretHarness{t: t}
	h.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.seen = append(h.seen, r.Method+" "+r.URL.Path)
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"secret":{"name":"x","value":"********tail"}}`))
	}))
	t.Cleanup(h.server.Close)

	body := strings.Replace(secretManifestJSON, "http://replaced", h.server.URL, 1)
	m, err := manifest.Parse([]byte(body))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	h.m = m
	h.ctx = manifest.Context{
		Server:    h.server.URL,
		Token:     "tok",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
		// NOT explicit: `bp secret set` refuses an explicitly-typed -w/-p on the
		// FLAT /v1/secrets route (that refusal is a different, pre-existing guard).
		// The slugs stay populated so the scoped-set path_template still renders.
		WorkspaceExplicit: false,
		ProjectExplicit:   false,
	}
	return h
}

// writes reports every non-GET request the CLI sent. A guard that fires before
// the write leaves this empty, whatever it printed.
func (h *secretHarness) writes() []string {
	var out []string
	for _, s := range h.seen {
		if !strings.HasPrefix(s, "GET ") {
			out = append(out, s)
		}
	}
	return out
}

func (h *secretHarness) run(verb string, tail ...string) (code int, stdout, stderr string) {
	h.t.Helper()
	cmd, ok := h.m.Tree().Lookup("secret", verb)
	if !ok {
		h.t.Fatalf("fixture manifest has no secret %s", verb)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	g := globals{yes: true}
	w.applyGlobals(g)
	code = runCommand(w, g, h.ctx, h.m, *cmd, tail)
	return code, so.String(), se.String()
}

// TestSecretSetAnthropicKeyIsRefusedBeforeTheWrite is the RED-ON-REVERSION arm.
// Delete the guardUnreadSecretName call in run.go (or empty
// envOnlySecretConsumers) and this fails twice over: the exit drops to 0 and a
// `PUT /v1/secrets/anthropic_api_key` appears on the wire — the exact inert
// write task-512394bf1706afde measured on guerrilla.
func TestSecretSetAnthropicKeyIsRefusedBeforeTheWrite(t *testing.T) {
	for _, spelling := range []string{"anthropic_api_key", "ANTHROPIC_API_KEY", "anthropic-api-key"} {
		t.Run(spelling, func(t *testing.T) {
			h := newSecretHarness(t)
			code, _, stderr := h.run("set", spelling, "sk-ant-not-a-real-key")

			if code != exitValidation {
				t.Errorf("exit = %d, want exitValidation (%d) — the write must be REFUSED, not stored", code, exitValidation)
			}
			if got := h.writes(); len(got) != 0 {
				t.Errorf("the CLI sent %v — a refused secret write must reach the wire ZERO times", got)
			}
			// The refusal has to be actionable: it names the env var, the file
			// the operator edits, and the restart that makes it live.
			for _, want := range []string{"ANTHROPIC_API_KEY", ".env", "restart", storeUnreadSecretFlag} {
				if !strings.Contains(stderr, want) {
					t.Errorf("refusal does not name %q — an operator cannot act on it:\n%s", want, stderr)
				}
			}
			// Never echo the value back.
			if strings.Contains(stderr, "sk-ant-not-a-real-key") {
				t.Errorf("refusal echoed the secret VALUE:\n%s", stderr)
			}
		})
	}
}

// TestSecretScopedSetAnthropicKeyIsRefused proves the guard is keyed on the
// ROUTE, not on a verb list: the scoped door carries a workspace/project prefix
// and is covered by the same check with no per-verb code.
func TestSecretScopedSetAnthropicKeyIsRefused(t *testing.T) {
	h := newSecretHarness(t)
	code, _, stderr := h.run("scoped-set", "anthropic_api_key", "sk-ant-not-a-real-key")
	if code != exitValidation {
		t.Errorf("scoped-set exit = %d, want %d", code, exitValidation)
	}
	if got := h.writes(); len(got) != 0 {
		t.Errorf("scoped-set sent %v — want zero writes", got)
	}
	if !strings.Contains(stderr, "ANTHROPIC_API_KEY") {
		t.Errorf("scoped refusal does not name the env var:\n%s", stderr)
	}
}

// TestSecretSetReadNameStillWrites is the QUIET arm. `ingest_token` is the ONE
// name a resolver reads back out of the store (Barkpark.Secrets.ingest_token/0),
// so it must go through untouched — a guard that refuses everything would be a
// different, worse bug.
func TestSecretSetReadNameStillWrites(t *testing.T) {
	for _, name := range []string{"ingest_token", "jarl-admin-token", "STRIPE_KEY"} {
		t.Run(name, func(t *testing.T) {
			h := newSecretHarness(t)
			code, _, stderr := h.run("set", name, "value-not-a-real-secret")
			if code != exitOK {
				t.Errorf("exit = %d, want 0 — %q is not an env-only name:\n%s", code, name, stderr)
			}
			got := h.writes()
			if len(got) != 1 || !strings.HasPrefix(got[0], "PUT ") {
				t.Errorf("wire = %v, want exactly one PUT", got)
			}
		})
	}
}

// TestSecretSetStoreUnreadOptsIn proves the escape hatch: the operator who
// wants the vault row anyway gets it, and is TOLD nothing reads it rather than
// being left with a silent green receipt.
func TestSecretSetStoreUnreadOptsIn(t *testing.T) {
	h := newSecretHarness(t)
	code, _, stderr := h.run("set", "anthropic_api_key", "sk-ant-not-a-real-key", storeUnreadSecretFlag)
	if code != exitOK {
		t.Errorf("exit = %d, want 0 with %s:\n%s", code, storeUnreadSecretFlag, stderr)
	}
	got := h.writes()
	if len(got) != 1 || !strings.HasPrefix(got[0], "PUT ") {
		t.Errorf("wire = %v, want exactly one PUT once the opt-in was given", got)
	}
	if !strings.Contains(stderr, "nothing on the instance reads it back") {
		t.Errorf("opt-in path went quiet — it must still say the row is inert:\n%s", stderr)
	}
}

// TestEnvOnlySecretConsumersCoversEverySourceKeyVar is the DRIFT check, and the
// reason envOnlySecretConsumers is a table rather than a hand-written literal
// nobody revisits: it greps the api/ tree for every `System.get_env("*_API_KEY")`
// and fails if one is missing from the table. Add a provider key to the app and
// this test names it before the next operator finds the dead write.
func TestEnvOnlySecretConsumersCoversEverySourceKeyVar(t *testing.T) {
	root := repoRootForSecretGuard(t)
	if root == "" {
		t.Skip("api/ tree not present (packaged build) — nothing to drift against")
	}
	re := regexp.MustCompile(`System\.get_env\("([A-Z0-9_]*_API_KEY)"\)`)
	found := map[string]string{}
	err := filepath.Walk(filepath.Join(root, "api", "lib"), func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".ex") {
			return nil
		}
		b, rerr := os.ReadFile(path)
		if rerr != nil {
			return nil
		}
		for _, mm := range re.FindAllSubmatch(b, -1) {
			found[string(mm[1])] = path
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk api/lib: %v", err)
	}
	// A control on the control: an empty key set would make every assertion
	// below vacuously true, so prove the grep found something first.
	if len(found) == 0 {
		t.Fatalf("grep found ZERO System.get_env(\"*_API_KEY\") in api/lib — the drift check is measuring nothing")
	}
	for keyVar, where := range found {
		if _, ok := envOnlySecretConsumers[keyVar]; !ok {
			t.Errorf("%s is read from the ENVIRONMENT (%s) but is absent from envOnlySecretConsumers — "+
				"`bp secret set %s` would store a row nothing reads and this guard would let it",
				keyVar, where, strings.ToLower(keyVar))
		}
	}
}

// repoRootForSecretGuard walks up from the test's working directory to the
// module root (the directory holding go.mod).
func repoRootForSecretGuard(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "api", "lib")); err == nil {
				return dir
			}
			return ""
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ""
}
