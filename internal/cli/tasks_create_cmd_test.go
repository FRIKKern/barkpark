package cli

import (
	"reflect"
	"testing"
)

// The two fields the task schema REQUIRES at creation — the whole reason this
// verb exists, since the generic doc-create path omits them. If a refactor ever
// drops a default, these tests fail loudly.
func TestParseTaskCreateArgs_InjectsRequiredDefaults(t *testing.T) {
	body, publish, err := parseTaskCreateArgs([]string{"My task"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if publish {
		t.Errorf("publish should default false")
	}
	if body["kind"] != "task" {
		t.Errorf("kind default = %v, want task", body["kind"])
	}
	if body["lifecycle_status"] != "open" {
		t.Errorf("lifecycle_status default = %v, want open", body["lifecycle_status"])
	}
	if body["title"] != "My task" {
		t.Errorf("positional title = %v, want My task", body["title"])
	}
}

func TestParseTaskCreateArgs_FlagsAndTypedSet(t *testing.T) {
	body, publish, err := parseTaskCreateArgs([]string{
		"--title", "T", "--description", "D",
		"--set", "priority:=3", "--set", "parent_id=goal-1", "--publish",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !publish {
		t.Errorf("--publish should set publish=true")
	}
	if body["title"] != "T" || body["description"] != "D" {
		t.Errorf("title/description = %v/%v", body["title"], body["description"])
	}
	// key:=json sends a typed value — priority must be a number, not "3".
	if got, ok := body["priority"].(float64); !ok || got != 3 {
		t.Errorf("priority = %#v, want number 3", body["priority"])
	}
	if body["parent_id"] != "goal-1" {
		t.Errorf("parent_id = %v, want goal-1 (string)", body["parent_id"])
	}
}

func TestParseTaskCreateArgs_SetOverridesDefault(t *testing.T) {
	body, _, err := parseTaskCreateArgs([]string{"t", "--set", "lifecycle_status=blocked"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if body["lifecycle_status"] != "blocked" {
		t.Errorf("--set should override the default: got %v", body["lifecycle_status"])
	}
}

func TestParseTaskCreateArgs_Errors(t *testing.T) {
	cases := [][]string{
		{"--title"},             // flag needs a value
		{"--set"},               // flag needs a value
		{"--set", "noeq"},       // malformed --set
		{"--set", "x:=notjson"}, // typed set with invalid JSON
		{"--bogus"},             // unknown flag
		{"one", "two"},          // two positionals (second is not the title)
	}
	for _, tc := range cases {
		if _, _, err := parseTaskCreateArgs(tc); err == nil {
			t.Errorf("parseTaskCreateArgs(%v) = nil error, want error", tc)
		}
	}
}

func TestIsProdServer(t *testing.T) {
	prod := []string{"https://api.barkpark.cloud", "https://prod.example.com"}
	nonprod := []string{"http://localhost:4000", "https://guerrilla.barkpark.cloud", "http://127.0.0.1:4000"}
	for _, s := range prod {
		if !isProdServer(s) {
			t.Errorf("isProdServer(%q) = false, want true", s)
		}
	}
	for _, s := range nonprod {
		if isProdServer(s) {
			t.Errorf("isProdServer(%q) = true, want false", s)
		}
	}
}

// The create body carries the required fields flat at top level (never nested
// under content.*), which is the shape the server's mutate contract accepts.
func TestTaskCreateBodyShape(t *testing.T) {
	body, _, _ := parseTaskCreateArgs([]string{"hello"})
	want := map[string]any{"kind": "task", "lifecycle_status": "open", "title": "hello"}
	if !reflect.DeepEqual(body, want) {
		t.Errorf("body = %#v, want %#v", body, want)
	}
}
