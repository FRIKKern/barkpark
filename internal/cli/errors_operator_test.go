package cli

import (
	"strings"
	"testing"
)

// A 403 from RequirePlatformOperator carries `required: platform_operator`.
// Older servers send the generic forbidden message and a hint telling the
// caller to use a workspace member token, which cannot pass the operator gate.
func TestOperatorRefusalOldServerGetsOperatorHint(t *testing.T) {
	body := []byte(`{"error":{"code":"forbidden","message":"token lacks required permission","hint":"Use a token with write/admin permission that is a member of this workspace.","required":"platform_operator"}}`)
	ae := classifyErrorBody(403, body)

	if ae.exit != exitAuth {
		t.Fatalf("exit = %d, want %d", ae.exit, exitAuth)
	}
	if got := ae.errorMessage(); got != "forbidden: platform operator access required" {
		t.Fatalf("message = %q", got)
	}
	h := ae.hint()
	if strings.Contains(h, "member of this workspace") {
		t.Fatalf("hint still points at a workspace member token: %q", h)
	}
	for _, want := range []string{"BARKPARK_OPERATOR_TOKEN_IDS", "BARKPARK_OPERATOR_EMAILS", "bp token ls"} {
		if !strings.Contains(h, want) {
			t.Fatalf("hint %q does not name %s", h, want)
		}
	}
}

// A current server names the caller's own token id in its hint. Keep it.
func TestOperatorRefusalKeepsServerHintNamingTheTokenID(t *testing.T) {
	serverHint := "This route needs platform operator access. To grant it, add this token's id 0b4c-id to BARKPARK_OPERATOR_TOKEN_IDS, or add the token owner's email to BARKPARK_OPERATOR_EMAILS, then restart the server."
	body := []byte(`{"error":{"code":"forbidden","message":"platform operator access required","hint":"` + serverHint + `","required":"platform_operator"}}`)
	ae := classifyErrorBody(403, body)

	if got := ae.hint(); got != serverHint {
		t.Fatalf("hint = %q, want the server's", got)
	}
	if got := ae.errorMessage(); got != "forbidden: platform operator access required" {
		t.Fatalf("message = %q", got)
	}
}

// Control: a plain forbidden without `required` is untouched.
func TestPlainForbiddenIsUnchanged(t *testing.T) {
	body := []byte(`{"error":{"code":"forbidden","message":"token lacks required permission","hint":"Use a token with write/admin permission that is a member of this workspace."}}`)
	ae := classifyErrorBody(403, body)

	if got := ae.errorMessage(); got != "forbidden: token lacks required permission" {
		t.Fatalf("message = %q", got)
	}
	if !strings.Contains(ae.hint(), "member of this workspace") {
		t.Fatalf("hint changed: %q", ae.hint())
	}
}
