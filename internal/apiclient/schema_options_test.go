package apiclient

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A select field's `options` ships in two live shapes: the canonical flat
// ["a","b"] array (field_inputs.ex, seeds/demo.ex, tasks/schema.ex) and the
// tickets plugin's object form {"list":["a","b"]}. Before parseOptions, the
// struct field was a strict `[]string`, so the object shape made encoding/json
// abort the ENTIRE schemas decode — taking down TUI boot (main.go), the scope
// switcher (selector.go), and paper resolution (paper_cmd.go), all of which
// call LoadSchemas. This pins that a single object-shaped field decodes to its
// flat list instead of failing the whole fetch.
func TestLoadSchemasTolerantOptions(t *testing.T) {
	// The exact guerrilla ticket schema shape that triggered the outage:
	// the `status` field carries options as {"list": [...]}.
	fixture := `{
		"schemas": [
			{
				"name": "ticket", "title": "Support ticket",
				"fields": [
					{"name": "subject", "type": "string", "title": "Subject"},
					{"name": "status", "type": "select", "title": "Status",
					 "options": {"list": ["open", "answered", "closed"]},
					 "readOnly": true}
				]
			},
			{
				"name": "post", "title": "Post",
				"fields": [
					{"name": "state", "type": "select", "title": "State",
					 "options": ["draft", "published", "archived"]},
					{"name": "junk", "type": "select", "title": "Junk",
					 "options": {"nope": true}},
					{"name": "body", "type": "text", "title": "Body"}
				]
			}
		]
	}`

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(fixture))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	got, err := c.LoadSchemas()
	if err != nil {
		// This is the regression the outage hit: one object-shaped options
		// field aborting LoadSchemas for every schema.
		t.Fatalf("LoadSchemas must tolerate object-shaped options, got error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d schemas, want 2", len(got))
	}

	// The object-shaped ticket.status flattens to its list.
	status := fieldByName(t, got[0], "status")
	if want := []string{"open", "answered", "closed"}; !equalStrings(status.Options, want) {
		t.Errorf("ticket.status options = %v, want %v (object {list:[..]} must flatten)", status.Options, want)
	}

	// The canonical flat shape is unchanged.
	state := fieldByName(t, got[1], "state")
	if want := []string{"draft", "published", "archived"}; !equalStrings(state.Options, want) {
		t.Errorf("post.state options = %v, want %v (flat list unchanged)", state.Options, want)
	}

	// An unrecognized shape degrades to nil, never an error.
	if junk := fieldByName(t, got[1], "junk"); junk.Options != nil {
		t.Errorf("post.junk options = %v, want nil (unknown shape degrades)", junk.Options)
	}
}

// parseOptions unit contract: both live shapes flatten, everything else → nil.
func TestParseOptions(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{"flat list", `["a","b","c"]`, []string{"a", "b", "c"}},
		{"object list", `{"list":["open","answered","closed"]}`, []string{"open", "answered", "closed"}},
		{"empty flat", `[]`, []string{}},
		{"absent", ``, nil},
		{"null", `null`, nil},
		{"scalar", `"nope"`, nil},
		{"object no list key", `{"nope":true}`, nil},
		{"object non-string list", `{"list":[1,2]}`, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var raw json.RawMessage
			if tc.in != "" {
				raw = json.RawMessage(tc.in)
			}
			got := parseOptions(raw)
			if !equalStrings(got, tc.want) {
				t.Errorf("parseOptions(%s) = %v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

func fieldByName(t *testing.T, s Schema, name string) Field {
	t.Helper()
	for _, f := range s.Fields {
		if f.Name == name {
			return f
		}
	}
	t.Fatalf("schema %q has no field %q", s.Name, name)
	return Field{}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
