package cli

import (
	"encoding/json"
	"strings"
	"testing"
)

// `bp token ls` is a generic manifest read: it has no Go struct for a token
// row, so a field the server adds reaches the operator as it is. The server
// added `dataset_bound` to the inventory so an operator can find the tokens a
// workspace-level admin read records or refuses. This pins that the field
// survives JSON output and is shown in the table.
func TestTokenLsCarriesDatasetBound(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)
	h.tokens = `{"tokens":[` +
		`{"id":"ac8ff595-deff-4c51-b251-0d05e8414184","label":"ci-deploy","kind":"api","permissions":["read","write","admin"],"dataset":"production","dataset_bound":true,"role":"admin"},` +
		`{"id":"0b8f5c2e-6d0b-4a51-9c7e-1f3c9d2a4e10","label":"ops","kind":"api","permissions":["read","write","admin"],"dataset":"production","dataset_bound":false,"role":"admin"}` +
		`]}`

	code, stdout, stderr := h.runDestroy(globals{output: "json"}, "token", "ls")
	if code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr:\n%s", code, exitOK, stderr)
	}

	var got struct {
		Tokens []map[string]any `json:"tokens"`
	}
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("token ls -o json is not JSON: %v\n%s", err, stdout)
	}
	if len(got.Tokens) != 2 {
		t.Fatalf("got %d tokens, want 2:\n%s", len(got.Tokens), stdout)
	}
	if got.Tokens[0]["dataset_bound"] != true || got.Tokens[1]["dataset_bound"] != false {
		t.Errorf("dataset_bound did not survive -o json: %v / %v",
			got.Tokens[0]["dataset_bound"], got.Tokens[1]["dataset_bound"])
	}

	code, stdout, stderr = h.runDestroy(globals{output: "table"}, "token", "ls")
	if code != exitOK {
		t.Fatalf("table: exit = %d, want %d; stderr:\n%s", code, exitOK, stderr)
	}
	if !strings.Contains(strings.ToLower(stdout), "dataset_bound") {
		t.Errorf("the table does not show dataset_bound:\n%s", stdout)
	}
}
