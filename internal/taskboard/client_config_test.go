package taskboard

import "testing"

// task-e4cbf4cd9f672c33: the board closes through the apiclient Run builds,
// so the session headers resolved by the CLI must survive the mapping.
func TestClientConfigCarriesSessionHeaders(t *testing.T) {
	got := clientConfig(Config{BaseURL: "http://x", Token: "t", SessionKey: "k", SessionDoc: "session-x"})
	if got.SessionKey != "k" || got.SessionDoc != "session-x" || got.BaseURL != "http://x" || got.Token != "t" {
		t.Fatalf("clientConfig dropped a field: %+v", got)
	}
}
