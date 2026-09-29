package provisioner

import "testing"

// TestSupportParseMint_BareIDOnlyInsideSupportTokenWrapper pins
// pdf-w1-tokenid-orphan-reconcile c1: a bare "id" is the token id ONLY inside a
// support_token-shaped wrapper. Anywhere else it may name something unrelated
// (a request id, a doc id) and would satisfy the blank-id guard with the WRONG
// id — a fleet_token_id that revokes nothing — so it is refused (tokenID "").
func TestSupportParseMint_BareIDOnlyInsideSupportTokenWrapper(t *testing.T) {
	for _, tc := range []struct {
		name   string
		body   string
		wantID string
	}{
		{"live shape: top-level token_id", `{"token":"sup-tok","token_id":"tid-1","name":"helper"}`, "tid-1"},
		{"support_token wrapper with bare id", `{"support_token":{"token":"sup-tok","id":"tid-2"}}`, "tid-2"},
		{"token_id in any wrapper", `{"data":{"token":"sup-tok","token_id":"tid-3"}}`, "tid-3"},
		{"REFUSED: top-level bare id (e.g. a request id)", `{"token":"sup-tok","id":"req-123"}`, ""},
		{"REFUSED: data wrapper bare id", `{"data":{"token":"sup-tok","id":"doc-9"}}`, ""},
		{"REFUSED: doc wrapper bare id", `{"doc":{"token":"sup-tok","id":"doc-9"}}`, ""},
		{"REFUSED: token wrapper bare id", `{"token":{"value":"sup-tok","id":"x-1"}}`, ""},
		{"token_id wins over an unrelated top-level id", `{"id":"req-1","token":"sup-tok","token_id":"tid-4"}`, "tid-4"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tok, id := supportParseMint([]byte(tc.body))
			if tok != "sup-tok" {
				t.Fatalf("token = %q, want sup-tok", tok)
			}
			if id != tc.wantID {
				t.Fatalf("tokenID = %q, want %q", id, tc.wantID)
			}
		})
	}
}
