package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp workspace member-add` on an UNCONFIRMED account: the server reclaims it
// (owner ruling #7) and says so with an `account_reclaimed` warning
// (task-f583460d431d195c). The operator must SEE that line, or the next
// "my password stopped working" reads as a bug. A plain seat prints none.
func TestMemberAddReclaimedWarningReachesStderr(t *testing.T) {
	reclaimed := `{"member":{"principal_type":"user","identity":"ed@example.com","role":"member"},` +
		`"reclaimed":true,"warnings":[{"code":"account_reclaimed","severity":"warning",` +
		`"message":"this email's account was never confirmed, so it was reclaimed before seating (owner ruling #7): its password was replaced and every session signed out. No email was sent. The user signs in with a password reset or a magic link."}]}`

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderSuccess(w, manifest.Command{}, []byte(reclaimed))
	if got := stderr.String(); !strings.Contains(got, "warning[account_reclaimed]: ") ||
		!strings.Contains(got, "password was replaced") {
		t.Errorf("reclaimed member-add stderr = %q, want the account_reclaimed line", got)
	}

	stdout.Reset()
	stderr.Reset()
	w = newWriter(&stdout, &stderr)
	w.output = "minimal"
	renderSuccess(w, manifest.Command{}, []byte(`{"member":{"principal_type":"user","identity":"new@example.com","role":"member"}}`))
	if got := stderr.String(); strings.Contains(got, "account_reclaimed") {
		t.Errorf("a plain seat must print no reclaim warning, got %q", got)
	}
}
