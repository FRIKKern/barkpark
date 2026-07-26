package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
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

// Regression (task-bp-create-drops-long-description): the builtin `bp task
// create` --set parser (applyTaskSet) and its --description flag must also carry
// a multi-KB, multi-line description VERBATIM — no newline truncation, no drop —
// past the 5,783 bytes that reproduced the report.
func TestParseTaskCreateArgs_LongMultilineDescription(t *testing.T) {
	line := "rationale: a task reason with a colon a:b and a := marker, padding padding padding\n"
	desc := "Hit twice during round nine.\n\n" + strings.Repeat(line, 84)
	if len(desc) <= 5783 {
		t.Fatalf("description must exceed the reproduced 5783 bytes, got %d", len(desc))
	}

	// via --set description=<big>
	viaSet, _, err := parseTaskCreateArgs([]string{"t", "--set", "description=" + desc})
	if err != nil {
		t.Fatalf("--set path: %v", err)
	}
	if got, _ := viaSet["description"].(string); got != desc {
		t.Fatalf("--set description not verbatim: got %d bytes, want %d", len(got), len(desc))
	}

	// via --description <big>
	viaFlag, _, err := parseTaskCreateArgs([]string{"t", "--description", desc})
	if err != nil {
		t.Fatalf("--description path: %v", err)
	}
	if got, _ := viaFlag["description"].(string); got != desc {
		t.Fatalf("--description not verbatim: got %d bytes, want %d", len(got), len(desc))
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

// tlv-s6 (TLV charter D14): the create receipt echoes the lifecycle_status the
// task was born with — a birth-as-considering must be visible, never silently
// assumed "open". Runs the real runTaskCreate against a stub mutate endpoint.
func TestRunTaskCreateReceiptEchoesBornLifecycle(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if strings.Contains(req.URL.Path, "/v1/data/mutate") {
			io.WriteString(rw, `{"results":[{"id":"drafts.task-9"}]}`)
			return
		}
		rw.WriteHeader(http.StatusNotFound)
	}))
	defer ts.Close()

	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	cases := []struct {
		name string
		tail []string
		want string
	}{
		{"default open", []string{"a task"}, "open"},
		{"born considering", []string{"a task", "--set", "lifecycle_status=considering"}, "considering"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var so, se bytes.Buffer
			w := &writer{stdout: &so, stderr: &se, output: "json"}
			if code := runTaskCreate(w, globals{yes: true}, ctx, tc.tail); code != exitOK {
				t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
			}
			var receipt struct {
				ID              string `json:"id"`
				Draft           string `json:"draft"`
				Status          string `json:"status"`
				LifecycleStatus string `json:"lifecycle_status"`
			}
			if err := json.Unmarshal(so.Bytes(), &receipt); err != nil {
				t.Fatalf("receipt did not parse: %v (%q)", err, so.String())
			}
			if receipt.ID != "task-9" || receipt.Draft != "drafts.task-9" || receipt.Status != "draft" {
				t.Fatalf("receipt = %+v, want id task-9 / draft drafts.task-9 / status draft", receipt)
			}
			if receipt.LifecycleStatus != tc.want {
				t.Fatalf("receipt.lifecycle_status = %q, want %q", receipt.LifecycleStatus, tc.want)
			}
		})
	}
}

// The human (non-machine) receipt line names the born lifecycle too.
func TestRunTaskCreateHumanReceiptNamesLifecycle(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		io.WriteString(rw, `{"results":[{"id":"drafts.task-3"}]}`)
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	tail := []string{"a task", "--set", "lifecycle_status=considering"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, tail); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	if got := so.String(); !strings.Contains(got, "lifecycle considering") {
		t.Fatalf("human receipt %q does not name the born lifecycle", got)
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

func TestEnsureTaskPortableBrief(t *testing.T) {
	body := map[string]any{
		"title":       "Ship the reader",
		"description": "**Why:** humans must scan it.",
		"acceptance_criteria": []any{
			map[string]any{"criterion": "PortableDoc renders in the task TUI"},
		},
	}
	ensureTaskPortableBrief(body)
	brief, ok := body["brief"].(map[string]any)
	if !ok || brief["version"] != 1 {
		t.Fatalf("brief = %#v, want PortableDoc v1", body["brief"])
	}
	blocks, _ := brief["blocks"].([]any)
	if len(blocks) != 4 {
		t.Fatalf("blocks = %d, want criteria then purpose pairs", len(blocks))
	}
	if blocks[0].(map[string]any)["id"] != "criteria" || blocks[1].(map[string]any)["id"] != "criteria-list" {
		t.Fatalf("criteria are not the first brief section: %#v", blocks)
	}
	if blocks[1].(map[string]any)["type"] != "list" {
		t.Fatalf("criteria are not a TUI-supported list: %#v", blocks[1])
	}
	purpose := blocks[3].(map[string]any)["content"].([]any)[0].(map[string]any)["value"]
	if strings.Contains(purpose.(string), "**") {
		t.Fatalf("purpose retained Markdown markers: %q", purpose)
	}
	for _, block := range blocks {
		id, _ := block.(map[string]any)["id"].(string)
		if id == "state" || id == "state-callout" || id == "done" || id == "done-list" || id == "done-copy" {
			t.Fatalf("brief retained deprecated generated block %q", id)
		}
	}
}

func TestEnsureTaskPortableBriefPreservesExplicitBrief(t *testing.T) {
	explicit := map[string]any{"version": float64(1), "blocks": []any{map[string]any{"type": "heading"}}}
	body := map[string]any{"title": "t", "brief": explicit}
	ensureTaskPortableBrief(body)
	if !reflect.DeepEqual(body["brief"], explicit) {
		t.Fatalf("explicit brief was replaced: %#v", body["brief"])
	}
}
