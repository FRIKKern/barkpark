package cloudclient

// adopt.go is the client half of `bp barkparks adopt` — POST /v1/barkparks/adopt
// (cloud/lib/barkpark_cloud/registry/adoption.ex). It attaches an already-running
// box to the caller's team. The box admin token in the request proves control
// and is used by the control plane for three requests only; the control plane
// mints and stores its OWN credential and never echoes either token, so nothing
// this file decodes can hold a secret.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// AdoptRequest is the POST body. AdminToken is the caller's admin token on the
// box: it travels to the control plane once and is never stored there.
type AdoptRequest struct {
	Name       string `json:"name"`
	Slug       string `json:"slug"`
	URL        string `json:"url"`
	Host       string `json:"host"`
	AdminToken string `json:"admin_token"`
}

// AdoptStep is one thing the control plane armed (or could not) on the box.
type AdoptStep struct {
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

// AdoptResult is the 201 envelope. Raw is the body verbatim for -o json.
type AdoptResult struct {
	Raw      []byte   `json:"-"`
	Barkpark Barkpark `json:"barkpark"`
	Adopted  struct {
		Workspace       string               `json:"workspace"`
		CredentialID    string               `json:"credential_id"`
		CredentialLabel string               `json:"credential_label"`
		Armed           map[string]AdoptStep `json:"armed"`
	} `json:"adopted"`
}

// AdoptBarkpark attaches an existing box. The control plane probes the box
// synchronously (capabilities, token identity, a mint, a self-update read), so
// the call gets VerifyTimeout's headroom. A refusal surfaces through cloudError
// (a *CloudRefusal carrying the server's `error` code and `detail`).
func (c *Client) AdoptBarkpark(ctx context.Context, req AdoptRequest) (AdoptResult, error) {
	rc := *c
	if rc.HTTP == nil {
		rc.HTTP = newHTTPClient(VerifyTimeout)
	}
	status, raw, err := rc.do(ctx, "POST", "/v1/barkparks/adopt", true, req)
	if err != nil {
		return AdoptResult{}, err
	}
	if !ok(status) {
		return AdoptResult{}, cloudError(status, raw)
	}
	var out AdoptResult
	if err := json.Unmarshal(raw, &out); err != nil {
		return AdoptResult{}, fmt.Errorf("decode adopt response: %w", err)
	}
	// The receipt's claim is "this row now exists": a 2xx that names no row
	// (a proxy page, an empty body) must not read as an attached box.
	if strings.TrimSpace(out.Barkpark.ID) == "" {
		return AdoptResult{}, fmt.Errorf("adopt: the control plane answered HTTP %d without a barkpark id — check `bp barkparks` before retrying", status)
	}
	out.Raw = raw
	return out, nil
}
