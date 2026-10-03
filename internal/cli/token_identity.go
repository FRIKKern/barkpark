package cli

// token_identity.go — what the server says about the bearer token
// (GET /v1/tokens/current, task-7d4d405e0ee4bcbf).
//
// A token can hold `admin` and still answer 403 `not_a_member` on every
// workspace route: permissions and workspace seats are separate axes
// (docs/auth.md). The seats are what decides where a token can go, so
// `bp whoami` prints them, and `bp instance admin-token` reads the bootstrap
// credential's home workspace from the same route.

import (
	"encoding/json"
	"fmt"
	"strings"
)

// tokenMembership is one workspace seat the token holds.
type tokenMembership struct {
	WorkspaceID   string `json:"workspace_id"`
	WorkspaceSlug string `json:"workspace_slug"`
	Role          string `json:"role"`
}

// tokenIdentity is the 200 body of GET /v1/tokens/current. The secret and its
// hash are never part of it.
type tokenIdentity struct {
	Token struct {
		ID          string   `json:"id"`
		Label       string   `json:"label"`
		Permissions []string `json:"permissions"`
		ExpiresAt   any      `json:"expires_at"`
		WorkspaceID string   `json:"workspace_id"`
		Workspace   string   `json:"workspace"`
	} `json:"token"`
	Memberships []tokenMembership `json:"memberships"`
}

// fetchTokenIdentity asks server who token is. Any non-200 is an error naming
// the status: an older server without the route answers 404, a dead token 401.
func fetchTokenIdentity(server, token string) (*tokenIdentity, error) {
	u := strings.TrimRight(server, "/") + "/v1/tokens/current"
	headers := map[string]string{"Authorization": "Bearer " + token}
	status, body, err := doRequest("GET", u, headers, nil)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("GET /v1/tokens/current answered HTTP %d", status)
	}
	var id tokenIdentity
	if err := json.Unmarshal(body, &id); err != nil || id.Token.ID == "" {
		return nil, fmt.Errorf("GET /v1/tokens/current returned an unreadable body")
	}
	if id.Memberships == nil {
		id.Memberships = []tokenMembership{}
	}
	return &id, nil
}

// membershipsJSON is the whoami `memberships` value: the seats as
// {id, workspace, role}, in the server's order.
func membershipsJSON(ms []tokenMembership) []map[string]string {
	out := make([]map[string]string, 0, len(ms))
	for _, m := range ms {
		out = append(out, map[string]string{"id": m.WorkspaceID, "workspace": m.WorkspaceSlug, "role": m.Role})
	}
	return out
}

// membershipsLine is the whoami human line for the seats.
func membershipsLine(ms []tokenMembership) string {
	if len(ms) == 0 {
		return "seats:     none — this token is a member of no workspace, so every /w/<workspace>/… route answers 403 not_a_member"
	}
	parts := make([]string, 0, len(ms))
	for _, m := range ms {
		parts = append(parts, fmt.Sprintf("%s (%s)", m.WorkspaceSlug, m.Role))
	}
	return "seats:     " + strings.Join(parts, ", ")
}
