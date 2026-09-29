package cloudclient

// tokens.go is the control plane's Personal Access Token surface —
// GET/POST/DELETE /v1/tokens — the credential a CI job needs to talk to the
// control plane without a browser.
//
// SESSION-ONLY, ON PURPOSE. All three routes sit behind `Auth.require_user`
// (cloud/lib/barkpark_cloud/web/router.ex), never `require_user_or_pat`: a
// leaked `read` PAT can never mint itself a `root` one. So these three methods
// authenticate with the CLOUD SESSION token `bp login` writes (the RFC 8628
// device flow in device/client.go), not with a PAT. That is the whole mechanism
// behind `bp cloud token` — see docs/contracts/cli-credential-mint.md (CRED-1).
//
// THE PLAINTEXT LEAVES THE SERVER EXACTLY ONCE, in MintPAT's response. Only its
// SHA-256 hash is stored, so it is unrecoverable afterwards: `PAT` (the row
// shape both list and mint return) deliberately has NO plaintext field, and
// MintPAT returns the secret as a SEPARATE return value the caller must handle
// explicitly rather than a struct field that a %+v or a json.Marshal of the row
// would print.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// PATAbilities is the control plane's ability vocabulary
// (`UserToken.@abilities`). `root` and `deploy` are exclusive — the SERVER
// collapses the set (`normalize_abilities/1`), and the CLI does not re-implement
// that rule.
func PATAbilities() []string { return []string{"read", "write", "deploy", "root"} }

// PATExpiryChoices is the bounded expiry menu the control plane accepts
// (`parse_expiry/1`). Any OTHER integer is silently rewritten to the default
// validity, which is why the CLI refuses an off-menu value instead of letting a
// caller believe they got the window they asked for.
func PATExpiryChoices() []int { return []int{7, 30, 60, 90, 365} }

// PAT is one Personal Access Token row as the control plane serializes it
// (`pat_json/1`). It carries NO token_hash and NO plaintext — by construction,
// not by omission: the row is what `bp cloud token ls` prints, and there is no
// field on it that could leak a credential into a terminal or a log.
type PAT struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Abilities  []string `json:"abilities"`
	LastUsedAt string   `json:"last_used_at"`
	ExpiresAt  string   `json:"expires_at"`
	RevokedAt  string   `json:"revoked_at"`
	InsertedAt string   `json:"inserted_at"`
}

// MintPATRequest is the POST /v1/tokens body. ExpiresInDays is a POINTER
// because absent and zero are different instructions: absent means "the server's
// default validity", and 0 means "never expires" (`parse_expiry(0) -> nil`).
type MintPATRequest struct {
	Name          string   `json:"name"`
	Abilities     []string `json:"abilities"`
	ExpiresInDays *int     `json:"expires_in_days,omitempty"`
}

// PATListResult is a read of GET /v1/tokens.
type PATListResult struct {
	PATs []PAT
	// Raw is the `tokens` array verbatim, so `-o json` re-emits the control
	// plane's own bytes rather than a second, drifting definition of the row.
	Raw json.RawMessage
	// DecodeErr is set when the envelope arrived but `tokens` could not be read
	// as the contract's array of rows. An unreadable list is NOT an empty one.
	DecodeErr error
}

// ListPATs reads the caller's Personal Access Tokens, newest first. Needs a
// SESSION token; a PAT bearer gets 401 (the escalation firewall) and surfaces as
// a *CloudRefusal.
func (c *Client) ListPATs(ctx context.Context) (PATListResult, error) {
	status, body, err := c.do(ctx, "GET", "/v1/tokens", true, nil)
	if err != nil {
		return PATListResult{}, err
	}
	if status < 200 || status > 299 {
		return PATListResult{}, cloudError(status, body)
	}
	var env struct {
		Tokens json.RawMessage `json:"tokens"`
	}
	if uerr := json.Unmarshal(body, &env); uerr != nil {
		return PATListResult{Raw: nil, DecodeErr: fmt.Errorf("decode token list: %w", uerr)}, nil
	}
	res := PATListResult{Raw: env.Tokens}
	if len(env.Tokens) > 0 {
		if uerr := json.Unmarshal(env.Tokens, &res.PATs); uerr != nil {
			res.DecodeErr = fmt.Errorf("decode token rows: %w", uerr)
		}
	}
	return res, nil
}

// MintPAT mints one Personal Access Token and returns (plaintext, row, error).
//
// THE PLAINTEXT IS RETURNED SEPARATELY AND ONLY HERE. It is the single moment
// the credential exists outside the server; the caller owns handing it to a
// sink. It is deliberately NOT a field on PAT, so no caller can leak it by
// printing the row.
//
// Refusals keep their evidence: a plain member minting an elevated ability gets
// 403 {"error":"forbidden","required":"admin","scope":"team"} — a *CloudRefusal
// with Required/Scope set, which is how the CLI names the role cap without
// re-implementing it.
func (c *Client) MintPAT(ctx context.Context, req MintPATRequest) (string, PAT, error) {
	status, body, err := c.do(ctx, "POST", "/v1/tokens", true, req)
	if err != nil {
		return "", PAT{}, err
	}
	if status < 200 || status > 299 {
		return "", PAT{}, cloudError(status, body)
	}
	var env struct {
		Token string `json:"token"`
		PAT   PAT    `json:"pat"`
	}
	if uerr := json.Unmarshal(body, &env); uerr != nil {
		// NOTE: the error names the failure, never the body — the body IS the
		// credential on this route.
		return "", PAT{}, fmt.Errorf("decode mint response: %w", uerr)
	}
	if strings.TrimSpace(env.Token) == "" {
		return "", PAT{}, fmt.Errorf("the control plane answered %d with no token — nothing was minted that this client can hand over", status)
	}
	return env.Token, env.PAT, nil
}

// RevokePAT revokes one of the caller's own PATs by id. A wrong-user or
// nonexistent id is the same 404 (no existence leak across users), surfaced as a
// *CloudRefusal with Code "not_found".
func (c *Client) RevokePAT(ctx context.Context, id string) error {
	status, body, err := c.do(ctx, "DELETE", "/v1/tokens/"+esc(id), true, nil)
	if err != nil {
		return err
	}
	if status < 200 || status > 299 {
		return cloudError(status, body)
	}
	return nil
}
