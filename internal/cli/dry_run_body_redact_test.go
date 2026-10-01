package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A dry-run preview masks credential VALUES in the request body the way it
// already masks credential headers (r2-lane-b Go secret-exposure audit): `bp
// secret set <name> <value> --dry-run` used to print the secret verbatim.
const dryRunSecretFixture = "FIXTURE-SECRET-VALUE-NEVER-PRINTED"

func dryRunOutput(t *testing.T, cmd manifest.Command, body string, output string) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = output
	if code := dryRun(out, cmd, "https://x.example/v1/secrets/k", map[string]string{"Authorization": "Bearer fixture"}, []byte(body)); code != exitOK {
		t.Fatalf("dryRun exit %d", code)
	}
	return stdout.String() + stderr.String()
}

func TestDryRunMasksSecretValueInBody(t *testing.T) {
	secretSet := manifest.Command{ID: "secret.set", Noun: "secret", Verb: "set", HTTP: manifest.HTTP{Method: "PUT"}}
	for _, mode := range []string{"", "json"} {
		got := dryRunOutput(t, secretSet, `{"value":"`+dryRunSecretFixture+`"}`, mode)
		if strings.Contains(got, dryRunSecretFixture) {
			t.Fatalf("mode %q: dry-run printed the secret value:\n%s", mode, got)
		}
		if !strings.Contains(got, "****") {
			t.Fatalf("mode %q: the masked value should still be shown as ****:\n%s", mode, got)
		}
	}

	// Any command: a nested token/password/api_key field is masked; ordinary fields stay.
	doc := manifest.Command{ID: "doc.create", Noun: "doc", Verb: "create", HTTP: manifest.HTTP{Method: "POST"}}
	got := dryRunOutput(t, doc, `{"title":"Hello","config":{"api_key":"`+dryRunSecretFixture+`","read_token":"`+dryRunSecretFixture+`"}}`, "")
	if strings.Contains(got, dryRunSecretFixture) {
		t.Fatalf("dry-run printed a nested credential:\n%s", got)
	}
	if !strings.Contains(got, "Hello") {
		t.Fatalf("ordinary body fields must stay visible:\n%s", got)
	}

	// A doc's plain `value` field is not a secret outside the secret noun, and a
	// body with nothing to mask is byte-identical.
	plain := `{"value":"visible"}`
	if string(redactBody(doc, []byte(plain))) != plain {
		t.Fatalf("a non-secret body changed: %s", redactBody(doc, []byte(plain)))
	}
}

func TestVercelTokenHintNeverPrintsTheToken(t *testing.T) {
	tok := "bp_read_FIXTURE_abcd"
	if h := vercelTokenHint(tok); strings.Contains(h, "FIXTURE") || !strings.HasSuffix(h, "abcd") {
		t.Fatalf("hint %q must name only the last four characters", h)
	}
	if vercelTokenHint("ab") != "****" {
		t.Fatalf("a short token must be fully masked")
	}
}
