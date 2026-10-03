package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// token_create_elevated_test.go — `bp token create --permissions …write|admin`
// (task-7d4d405e0ee4bcbf). A write or admin set goes to the admin-to-admin mint
// route, never the read-only allowlist; --label/--expires-in/--no-expiry reach
// the body; and the server's named 403 is rendered, not swallowed.

func TestTokenCreateAdminSetGoesToTheElevatedRoute(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusCreated,
		`{"token":"raw-admin","id":"tok-a","label":"laptop-admin","permissions":["read","write","admin"],"dataset":"production","workspace":"gyldendal","expires_at":null}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code := runTokenCreate(w, globals{}, tokenCtx(srv.URL),
		[]string{"--label", "laptop-admin", "--permissions", "read,write,admin", "--no-expiry"})
	if code != exitOK {
		t.Fatalf("exit = %d; stdout=%q stderr=%q", code, so.String(), se.String())
	}
	if path != "/w/gyldendal/p/default/v1/tokens/elevated" {
		t.Errorf("path = %q, want the admin-to-admin mint route", path)
	}
	var sent map[string]any
	if err := json.Unmarshal(body, &sent); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if sent["label"] != "laptop-admin" || sent["no_expiry"] != true {
		t.Errorf("body = %v, want label laptop-admin and no_expiry true", sent)
	}
	if _, has := sent["expires_at"]; has {
		t.Errorf("--no-expiry must not also send expires_at: %v", sent)
	}
	out := so.String()
	for _, want := range []string{"read,write,admin", "expires      never", "raw-admin"} {
		if !strings.Contains(out, want) {
			t.Errorf("receipt does not show %q:\n%s", want, out)
		}
	}
}

func TestTokenCreateReadSetStaysOnTheReadOnlyRoute(t *testing.T) {
	for _, perms := range []string{"read", "public-read", "read,public-read"} {
		if got := tokenMintPath(splitCommaList(perms)); got != "/v1/tokens" {
			t.Errorf("%s → %q, want /v1/tokens", perms, got)
		}
	}
	for _, perms := range []string{"write", "read,write", "admin", "read,write,admin"} {
		if got := tokenMintPath(splitCommaList(perms)); got != "/v1/tokens/elevated" {
			t.Errorf("%s → %q, want /v1/tokens/elevated", perms, got)
		}
	}
}

func TestTokenCreateExpiresInBecomesAnAbsoluteExpiresAt(t *testing.T) {
	args, err := parseTokenCreateArgs([]string{"--label", "x", "--permissions", "read,write", "--expires-in", "90d"}, "production")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	b, err := tokenMintBody(args, now)
	if err != nil {
		t.Fatalf("body: %v", err)
	}
	var sent map[string]any
	_ = json.Unmarshal(b, &sent)
	if sent["expires_at"] != "2027-01-01T12:00:00Z" {
		t.Errorf("expires_at = %v, want now + 90d", sent["expires_at"])
	}
	if _, has := sent["no_expiry"]; has {
		t.Errorf("no_expiry sent without --no-expiry: %v", sent)
	}
}

func TestTokenCreateExpiryFlagRefusals(t *testing.T) {
	for _, tc := range []struct {
		name string
		tail []string
	}{
		{"both lifetimes", []string{"x", "--permissions", "admin", "--expires-in", "30d", "--no-expiry"}},
		{"bad unit", []string{"x", "--permissions", "admin", "--expires-in", "3w"}},
		{"zero", []string{"x", "--permissions", "admin", "--expires-in", "0"}},
		{"valued switch", []string{"x", "--permissions", "admin", "--no-expiry=false"}},
		{"label twice", []string{"x", "--label", "y", "--permissions", "admin"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseTokenCreateArgs(tc.tail, "production"); err == nil {
				t.Errorf("parse accepted %v", tc.tail)
			}
		})
	}
}

func TestTokenCreateGateFiresOnTheNewFlags(t *testing.T) {
	for _, tail := range [][]string{
		{"--label", "x", "--permissions", "admin"},
		{"x", "--no-expiry"},
		{"x", "--expires-in", "30d"},
	} {
		if !tokenCreateGated(tail) {
			t.Errorf("gate did not fire for %v", tail)
		}
	}
}

// The server is the authority: a write token asking for admin gets a named 403,
// and the operator sees the reason and the recovery hint.
func TestTokenCreateRendersTheAdminRequiredRefusal(t *testing.T) {
	var path string
	var body []byte
	srv := mintServer(t, http.StatusForbidden,
		`{"error":{"code":"forbidden","reason":"admin_required","message":"minting a write or admin token needs a token that holds the admin permission; this token holds [\"read\", \"write\"]","hint":"recover one from Barkpark Cloud: bp instance admin-token <instance-id> --install"}}`,
		&path, &body)
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code := runTokenCreate(w, globals{}, tokenCtx(srv.URL), []string{"x", "--permissions", "read,write,admin"})
	if code == exitOK {
		t.Fatalf("exit = 0 on a 403")
	}
	all := so.String() + se.String()
	if !strings.Contains(all, "admin permission") {
		t.Errorf("the refusal did not reach the operator: %q", all)
	}
	if strings.Contains(so.String(), "minted") {
		t.Errorf("printed a mint receipt over a 403: %q", so.String())
	}
}
