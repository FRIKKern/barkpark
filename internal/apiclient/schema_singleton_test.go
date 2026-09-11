package apiclient

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The SDK schema envelope has carried `singleton` since task-567f0fb2429086df,
// which fixed it being WRITE-ONLY on the server: a consumer could set the flag
// and never read back what took. LoadSchemas re-created that defect one layer
// down — its decode struct never declared the field, and `encoding/json` drops
// unknown keys SILENTLY, so `singleton` was discarded before any caller saw it.
//
// This is the arm that reds if the member is removed again. It is a DECODE test,
// not a byte-comparison of our own output: the field names here are the
// SERVER's, so the test fails when the wire shape and the struct drift apart —
// which is the only failure that matters for a field the server owns.
func TestLoadSchemasDecodesSingleton(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"schemas": []map[string]any{
				{"name": "settings", "title": "Settings", "singleton": true},
				{"name": "post", "title": "Post", "singleton": false},
				// A schema that omits the key entirely must decode as false,
				// never as "unknown" — the server normalises nil to false and
				// the client must agree rather than inventing a third state.
				{"name": "legacy", "title": "Legacy"},
			},
		})
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	got, err := c.LoadSchemas()
	if err != nil {
		t.Fatalf("LoadSchemas: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 schemas, got %d", len(got))
	}

	by := map[string]Schema{}
	for _, s := range got {
		by[s.Name] = s
	}

	// The positive arm: without the struct member this is false and the test
	// reds. It is stated first because it is the whole point of the fix.
	if !by["settings"].Singleton {
		t.Errorf("settings: Singleton = false, want true — the server emitted "+
			`"singleton": true and the client dropped it (got %+v)`, by["settings"])
	}

	// The DISCRIMINATING arms. A struct member hard-coded true, or a decode
	// that treats any present key as true, would pass the arm above and fail
	// these — so together they prove the value is READ rather than assumed.
	if by["post"].Singleton {
		t.Errorf(`post: Singleton = true, want false — "singleton": false was on the wire`)
	}
	if by["legacy"].Singleton {
		t.Errorf("legacy: Singleton = true, want false — the key was ABSENT and " +
			"must normalise to false, not to a third state")
	}

	// Non-vacuity control: prove the fixture actually reached the decoder at
	// all. Without this, a LoadSchemas that returned three zero-valued schemas
	// would satisfy both false-arms above and look like a pass.
	if by["settings"].Title != "Settings" || by["post"].Title != "Post" {
		t.Fatalf("control failed: the fixture did not decode (titles %q/%q) — the "+
			"Singleton assertions above were measuring nothing",
			by["settings"].Title, by["post"].Title)
	}
}
