package cloudclient

// tokens_test.go pins the /v1/tokens client. The load-bearing arm is
// TestMintPATRowCarriesNoPlaintext: the PAT ROW must have no field that can hold
// the secret, so no caller can leak it by printing a row it legitimately has.
// Add `Token string \`json:"token"\`` to PAT and it reds.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fixtureSecret is an invented string, not a credential. It is only ever
// compared against — it authenticates nothing anywhere.
const fixtureSecret = "bpc_pat_FIXTURE-ONLY-NEVER-A-REAL-CREDENTIAL"

const mintBody = `{"token":"` + fixtureSecret + `","pat":{"id":"pat-1","name":"ci-key",` +
	`"abilities":["write"],"last_used_at":null,"expires_at":"2026-10-16T00:00:00Z",` +
	`"revoked_at":null,"inserted_at":"2026-09-16T00:00:00Z"}}`

func tokenServer(t *testing.T, status int, body string, capture *http.Request, bodyOut *[]byte) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if capture != nil {
			*capture = *r
		}
		if bodyOut != nil {
			*bodyOut, _ = io.ReadAll(r.Body)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return &Client{BaseURL: srv.URL, Token: "sess-abc", HTTP: srv.Client()}
}

// TestMintPATRowCarriesNoPlaintext: the secret comes back as its OWN return
// value, and marshalling the row it came with cannot reproduce it.
func TestMintPATRowCarriesNoPlaintext(t *testing.T) {
	c := tokenServer(t, 201, mintBody, nil, nil)

	plaintext, pat, err := c.MintPAT(context.Background(), MintPATRequest{Name: "ci-key", Abilities: []string{"write"}})
	if err != nil {
		t.Fatalf("MintPAT: %v", err)
	}
	if plaintext != fixtureSecret {
		t.Fatalf("the plaintext return value did not carry the minted credential")
	}
	raw, merr := json.Marshal(pat)
	if merr != nil {
		t.Fatalf("marshal row: %v", merr)
	}
	if strings.Contains(string(raw), fixtureSecret) {
		t.Fatalf("the PAT ROW serializes the plaintext — any caller printing a row leaks the credential: %s", raw)
	}
	if pat.ID != "pat-1" || pat.Name != "ci-key" || pat.ExpiresAt != "2026-10-16T00:00:00Z" {
		t.Fatalf("row decoded wrong: %+v", pat)
	}
}

// TestMintPATSendsSessionBearerToTheRightRoute: session-backed (CRED-1), on the
// session-only route.
func TestMintPATSendsSessionBearerToTheRightRoute(t *testing.T) {
	var got http.Request
	var body []byte
	c := tokenServer(t, 201, mintBody, &got, &body)

	days := 30
	if _, _, err := c.MintPAT(context.Background(), MintPATRequest{Name: "n", Abilities: []string{"read"}, ExpiresInDays: &days}); err != nil {
		t.Fatalf("MintPAT: %v", err)
	}
	if got.Method != "POST" || got.URL.Path != "/v1/tokens" {
		t.Fatalf("hit %s %s, want POST /v1/tokens", got.Method, got.URL.Path)
	}
	if got.Header.Get("Authorization") != "Bearer sess-abc" {
		t.Fatalf("the session bearer did not ride the mint: %q", got.Header.Get("Authorization"))
	}
	var sent map[string]any
	if err := json.Unmarshal(body, &sent); err != nil {
		t.Fatalf("body: %v (%s)", err, body)
	}
	if sent["expires_in_days"] != float64(30) {
		t.Fatalf("expires_in_days = %v, want 30", sent["expires_in_days"])
	}
}

// TestMintPATOmitsExpiryWhenUnset: a nil ExpiresInDays must not serialize as 0,
// which the plane reads as "never expires" — the opposite of "use your default".
func TestMintPATOmitsExpiryWhenUnset(t *testing.T) {
	var body []byte
	c := tokenServer(t, 201, mintBody, nil, &body)

	if _, _, err := c.MintPAT(context.Background(), MintPATRequest{Name: "n"}); err != nil {
		t.Fatalf("MintPAT: %v", err)
	}
	var sent map[string]any
	_ = json.Unmarshal(body, &sent)
	if _, has := sent["expires_in_days"]; has {
		t.Fatalf("an unset expiry serialized as %v — the plane would read 0 as `never`", sent["expires_in_days"])
	}
}

// TestMintPATRoleCapRefusalKeepsEvidence: the 403 arrives as a typed refusal
// carrying required/scope, which is what lets the CLI name the role cap (CRED-3)
// without re-implementing it.
func TestMintPATRoleCapRefusalKeepsEvidence(t *testing.T) {
	c := tokenServer(t, 403, `{"error":"forbidden","required":"admin","scope":"team"}`, nil, nil)

	_, _, err := c.MintPAT(context.Background(), MintPATRequest{Name: "n", Abilities: []string{"root"}})
	if err == nil {
		t.Fatalf("a 403 decoded as success")
	}
	ref, ok := err.(*CloudRefusal)
	if !ok {
		t.Fatalf("err is %T, want *CloudRefusal", err)
	}
	if ref.HTTPStatus != 403 || ref.Required != "admin" || ref.Scope != "team" {
		t.Fatalf("refusal lost its evidence: %+v", ref)
	}
}

// TestMintPATTokenlessSuccessIsAnError: a 2xx with no `token` means nothing was
// handed over. Returning ("", row, nil) would let a caller write an empty
// credential file and call it a success.
func TestMintPATTokenlessSuccessIsAnError(t *testing.T) {
	c := tokenServer(t, 201, `{"pat":{"id":"pat-1"}}`, nil, nil)

	plaintext, _, err := c.MintPAT(context.Background(), MintPATRequest{Name: "n"})
	if err == nil {
		t.Fatalf("a token-less 201 decoded as a successful mint (plaintext %q)", plaintext)
	}
}

// TestListPATsDecodesAndKeepsRaw: rows decode, and the verbatim array survives
// for the -o json path.
func TestListPATsDecodesAndKeepsRaw(t *testing.T) {
	c := tokenServer(t, 200, `{"tokens":[{"id":"pat-1","name":"ci","abilities":["read"]}]}`, nil, nil)

	res, err := c.ListPATs(context.Background())
	if err != nil {
		t.Fatalf("ListPATs: %v", err)
	}
	if res.DecodeErr != nil {
		t.Fatalf("DecodeErr: %v", res.DecodeErr)
	}
	if len(res.PATs) != 1 || res.PATs[0].ID != "pat-1" {
		t.Fatalf("rows: %+v", res.PATs)
	}
	if !strings.HasPrefix(strings.TrimSpace(string(res.Raw)), "[") {
		t.Fatalf("Raw did not keep the array bytes: %s", res.Raw)
	}
}

// TestListPATsUnreadableRowsAreNotAnEmptyList: a `tokens` object (not the
// contract's array) sets DecodeErr and leaves PATs empty — the caller must be
// able to tell "could not read" from "none".
func TestListPATsUnreadableRowsAreNotAnEmptyList(t *testing.T) {
	c := tokenServer(t, 200, `{"tokens":{"pat-1":{}}}`, nil, nil)

	res, err := c.ListPATs(context.Background())
	if err != nil {
		t.Fatalf("ListPATs: %v", err)
	}
	if res.DecodeErr == nil {
		t.Fatalf("an object under `tokens` decoded as a clean empty list")
	}
}

// TestRevokePATPathAndNotFound.
func TestRevokePATPathAndNotFound(t *testing.T) {
	var got http.Request
	c := tokenServer(t, 200, `{"ok":true}`, &got, nil)
	if err := c.RevokePAT(context.Background(), "pat 1/x"); err != nil {
		t.Fatalf("RevokePAT: %v", err)
	}
	if got.Method != "DELETE" || !strings.HasPrefix(got.URL.Path, "/v1/tokens/") {
		t.Fatalf("hit %s %s", got.Method, got.URL.Path)
	}
	// r.URL.Path is the DECODED path, so the escaping is only visible on the
	// WIRE form: an unescaped id would put a real `/` there and address a
	// different route entirely.
	if !strings.Contains(got.URL.EscapedPath(), "%2F") {
		t.Fatalf("the id was interpolated unescaped (%s) — a slash in an id would corrupt the route", got.URL.EscapedPath())
	}

	c2 := tokenServer(t, 404, `{"error":"not_found"}`, nil, nil)
	err := c2.RevokePAT(context.Background(), "nope")
	ref, ok := err.(*CloudRefusal)
	if !ok || ref.HTTPStatus != 404 {
		t.Fatalf("404 surfaced as %T %v", err, err)
	}
}
