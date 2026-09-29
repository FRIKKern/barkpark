package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

// vercelInstanceForbiddenBody is the instance's real 403 for a non-admin mint
// (RequireWorkspaceRole → Errors.to_envelope({:error, :forbidden}) + stamp/2).
// No required/scope keys: those ride the CLOUD plane's POST /v1/tokens, not the
// instance's scoped /w/<ws>/p/<proj>/v1/tokens that quick-setup calls.
const vercelInstanceForbiddenBody = `{"error":{"code":"forbidden","message":"token lacks required permission",` +
	`"hint":"Use a token with write/admin permission that is a member of this workspace.",` +
	`"request_id":"F-abc123"}}`

func vercelMintAgainst(t *testing.T, status int, body string) error {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/w/acme/p/default/v1/tokens" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	tok, err := vercelMintReadToken(w, srv.URL+"/w/acme/p/default", "production", "bp_admin_test", "acme")
	if err == nil {
		t.Fatalf("vercelMintReadToken on HTTP %d returned token %q and nil error", status, tok)
	}
	return err
}

// TestVercelMintReadTokenRendersForbiddenSentence: the 403 keeps the server's
// hint — the sentence naming the role the gate wanted — instead of stopping at
// "forbidden: token lacks required permission".
func TestVercelMintReadTokenRendersForbiddenSentence(t *testing.T) {
	err := vercelMintAgainst(t, http.StatusForbidden, vercelInstanceForbiddenBody)
	want := "mint token: status 403: forbidden: token lacks required permission — " +
		"Use a token with write/admin permission that is a member of this workspace."
	if err.Error() != want {
		t.Errorf("mint 403 rendered\n  %q\nwant\n  %q", err.Error(), want)
	}
}

// TestVercelMintReadTokenNonForbiddenUnchanged is the control: a non-forbidden
// refusal — even one whose envelope carries a hint — renders exactly as before.
func TestVercelMintReadTokenNonForbiddenUnchanged(t *testing.T) {
	body := `{"error":{"code":"validation_failed","message":"label is required and must be a non-empty string",` +
		`"hint":"re-run with a label"}}`
	got := vercelMintAgainst(t, http.StatusUnprocessableEntity, body).Error()
	want := "mint token: status 422: label is required and must be a non-empty string"
	if got != want {
		t.Errorf("HTTP 422 rendered %q, want %q", got, want)
	}
}
