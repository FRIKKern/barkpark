package cloudclient

// admin_token_rotate.go is the client half of `bp barkparks rotate-admin-token`:
// POST /v1/operator/barkparks/:id/admin-token/rotate
// (cloud/lib/barkpark_cloud/registry/admin_token_rotation.ex). The control
// plane mints a successor on the box, stores it, checks it, and then revokes
// the old token. The response names token ids only, never a secret.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// AdminTokenRotation is the 200 envelope. Raw is the body verbatim for -o json.
// OldTokenStatus is the HTTP status the old token got after the revoke; nil
// when the box did not answer that check. SeatsNotCarried lists the
// workspaces the old token was seated in that the successor is not: the box
// seats a minted token only in the workspace it was minted in.
type AdminTokenRotation struct {
	Raw        []byte `json:"-"`
	BarkparkID string `json:"barkpark_id"`
	Rotated    struct {
		OldTokenID      string   `json:"old_token_id"`
		NewTokenID      string   `json:"new_token_id"`
		Label           string   `json:"label"`
		Workspace       string   `json:"workspace"`
		SeatsNotCarried []string `json:"seats_not_carried"`
		OldTokenStatus  *int     `json:"old_token_status"`
	} `json:"rotated"`
}

// RotateAdminToken asks the control plane to rotate the admin token it holds
// for one instance. Operator only. The control plane makes several box calls
// in the request, so the call gets VerifyTimeout's headroom. A refusal
// surfaces through cloudError.
func (c *Client) RotateAdminToken(ctx context.Context, id string) (AdminTokenRotation, error) {
	rc := *c
	if rc.HTTP == nil {
		rc.HTTP = newHTTPClient(VerifyTimeout)
	}
	status, raw, err := rc.do(ctx, "POST", "/v1/operator/barkparks/"+esc(id)+"/admin-token/rotate", true, nil)
	if err != nil {
		return AdminTokenRotation{}, err
	}
	if !ok(status) {
		return AdminTokenRotation{}, cloudError(status, raw)
	}
	var out AdminTokenRotation
	if err := json.Unmarshal(raw, &out); err != nil {
		return AdminTokenRotation{}, fmt.Errorf("decode rotate response: %w", err)
	}
	if strings.TrimSpace(out.Rotated.NewTokenID) == "" {
		return AdminTokenRotation{}, fmt.Errorf("rotate: the control plane answered HTTP %d without a new token id", status)
	}
	out.Raw = raw
	return out, nil
}
