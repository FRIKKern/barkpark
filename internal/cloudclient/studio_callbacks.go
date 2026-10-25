package cloudclient

// studio_callbacks.go is the client half of `bp barkparks studio-callback` —
// GET/POST/DELETE /v1/barkparks/:id/studio-callbacks. The list is the
// instance's "Sign in with Barkpark Cloud" allowlist: the exact Studio callback
// URLs a sign-in may return to. Reading it needs team membership; changing it
// needs team admin.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
)

// StudioCallbacks is the 200 envelope every studio-callbacks call answers.
type StudioCallbacks struct {
	Raw       []byte   `json:"-"`
	Callbacks []string `json:"studio_callbacks"`
}

// ListStudioCallbacks reads an instance's Studio callback allowlist.
func (c *Client) ListStudioCallbacks(ctx context.Context, barkparkID string) (StudioCallbacks, error) {
	return c.studioCallbacks(ctx, "GET", barkparkID, nil)
}

// AddStudioCallback allows one Studio callback URL (idempotent).
func (c *Client) AddStudioCallback(ctx context.Context, barkparkID, callbackURL string) (StudioCallbacks, error) {
	return c.studioCallbacks(ctx, "POST", barkparkID, map[string]string{"url": callbackURL})
}

// RemoveStudioCallback drops one Studio callback URL (idempotent).
func (c *Client) RemoveStudioCallback(ctx context.Context, barkparkID, callbackURL string) (StudioCallbacks, error) {
	return c.studioCallbacks(ctx, "DELETE", barkparkID, map[string]string{"url": callbackURL})
}

func (c *Client) studioCallbacks(ctx context.Context, method, barkparkID string, body any) (StudioCallbacks, error) {
	status, raw, err := c.do(ctx, method, "/v1/barkparks/"+url.PathEscape(barkparkID)+"/studio-callbacks", true, body)
	if err != nil {
		return StudioCallbacks{}, err
	}
	if !ok(status) {
		return StudioCallbacks{}, cloudError(status, raw)
	}
	var out StudioCallbacks
	if err := json.Unmarshal(raw, &out); err != nil || out.Callbacks == nil {
		return StudioCallbacks{}, fmt.Errorf("studio-callbacks: the control plane answered HTTP %d without a studio_callbacks list", status)
	}
	out.Raw = raw
	return out, nil
}
