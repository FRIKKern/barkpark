package bootstrap

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// instanceForbiddenBody is the BYTES the instance answers a non-admin mint with.
// POST /w/<ws>/p/<proj>/v1/tokens sits behind the :scoped_admin pipeline, whose
// RequireWorkspaceRole plug halts with Errors.to_envelope({:error, :forbidden})
// — code/message from Errors.build/1, hint from the code-keyed @hints table,
// request_id stamped by Errors.stamp/2. It carries NO required/scope keys: that
// grammar belongs to the CLOUD control plane's POST /v1/tokens (Auth.forbidden),
// a different server this client never calls.
const instanceForbiddenBody = `{"error":{"code":"forbidden","message":"token lacks required permission",` +
	`"hint":"Use a token with write/admin permission that is a member of this workspace.",` +
	`"request_id":"F-abc123"}}`

func mintAgainst(t *testing.T, status int, body string) error {
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
	c := Client{BaseURL: srv.URL, AdminToken: "bp_admin_test", HTTPClient: srv.Client()}
	tok, err := c.mintReadToken(context.Background(), srv.URL+"/w/acme/p/default", "production")
	if err == nil {
		t.Fatalf("mintReadToken on HTTP %d returned token %q and nil error", status, tok)
	}
	return err
}

// TestMintReadTokenRendersForbiddenSentence: a 403 from the mint renders the
// instance's own refusal sentence — message plus the hint that names the role
// the gate wanted — not the raw JSON envelope.
func TestMintReadTokenRendersForbiddenSentence(t *testing.T) {
	err := mintAgainst(t, http.StatusForbidden, instanceForbiddenBody)
	want := "status 403: forbidden: token lacks required permission — " +
		"Use a token with write/admin permission that is a member of this workspace."
	if err.Error() != want {
		t.Errorf("mint 403 rendered\n  %q\nwant\n  %q", err.Error(), want)
	}
}

// TestMintReadTokenNonForbiddenUnchanged is the control: a refusal that is not
// the forbidden envelope renders exactly as before (raw status + snippet).
func TestMintReadTokenNonForbiddenUnchanged(t *testing.T) {
	cases := []struct {
		status int
		body   string
		want   string
	}{
		{http.StatusInternalServerError, "upstream connect error", "status 500: upstream connect error"},
		{
			http.StatusUnprocessableEntity,
			`{"error":{"code":"validation_failed","message":"label is required and must be a non-empty string"}}`,
			`status 422: {"error":{"code":"validation_failed","message":"label is required and must be a non-empty string"}}`,
		},
	}
	for _, tc := range cases {
		if got := mintAgainst(t, tc.status, tc.body).Error(); got != tc.want {
			t.Errorf("HTTP %d rendered %q, want %q", tc.status, got, tc.want)
		}
	}
}
