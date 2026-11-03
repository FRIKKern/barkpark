package cloudclient

// token_seat_restore.go is the client half of `bp barkparks repair-token-seats`:
// POST /v1/operator/barkparks/:id/token-seats/restore
// (cloud/lib/barkpark_cloud/registry/token_seat_restore.ex). The control plane
// asks the box, with the admin token it holds, to give a token back the
// workspace seats its revoked predecessor held. The box decides what may be
// restored. The response names token ids, slugs and roles, never a secret.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// TokenSeatRestoreRequest is the body. TokenID empty means the admin token
// Cloud holds. Workspaces empty means every seat a predecessor held. Apply
// false is a dry run.
type TokenSeatRestoreRequest struct {
	TokenID    string   `json:"token,omitempty"`
	Workspaces []string `json:"workspaces"`
	Apply      bool     `json:"apply"`
}

// TokenSeatRestorePlan is the box's answer. Restore lists the seats the box
// writes (or would write, on a dry run); Refused lists the workspaces no
// revoked predecessor held. Applied is true only when the box wrote.
type TokenSeatRestorePlan struct {
	TokenID      string   `json:"token_id"`
	Predecessors []string `json:"predecessors"`
	Restore      []struct {
		Workspace string `json:"workspace"`
		Role      string `json:"role"`
		FromToken string `json:"from_token"`
	} `json:"restore"`
	Already []string `json:"already"`
	Refused []struct {
		Workspace string `json:"workspace"`
		Reason    string `json:"reason"`
	} `json:"refused"`
	Applied bool `json:"applied"`
}

// TokenSeatRestore is the 200 envelope. Raw is the body verbatim for -o json.
type TokenSeatRestore struct {
	Raw        []byte               `json:"-"`
	BarkparkID string               `json:"barkpark_id"`
	Plan       TokenSeatRestorePlan `json:"restore"`
}

// RestoreTokenSeats asks the control plane to restore a token's seats on one
// instance. Operator only. A refusal surfaces through cloudError; a 409
// seat_not_held_before carries the box's plan in its body.
func (c *Client) RestoreTokenSeats(ctx context.Context, id string, req TokenSeatRestoreRequest) (TokenSeatRestore, error) {
	rc := *c
	if rc.HTTP == nil {
		rc.HTTP = newHTTPClient(VerifyTimeout)
	}
	if req.Workspaces == nil {
		req.Workspaces = []string{}
	}
	status, raw, err := rc.do(ctx, "POST", "/v1/operator/barkparks/"+esc(id)+"/token-seats/restore", true, req)
	if err != nil {
		return TokenSeatRestore{}, err
	}
	if !ok(status) {
		return TokenSeatRestore{}, cloudError(status, raw)
	}
	var out TokenSeatRestore
	if err := json.Unmarshal(raw, &out); err != nil {
		return TokenSeatRestore{}, fmt.Errorf("decode token-seats restore response: %w", err)
	}
	if strings.TrimSpace(out.Plan.TokenID) == "" {
		return TokenSeatRestore{}, fmt.Errorf("token-seats restore: the control plane answered HTTP %d without a token id", status)
	}
	out.Raw = raw
	return out, nil
}
