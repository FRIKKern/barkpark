package taskboard

import (
	"strings"
	"testing"
)

// ONE row with an oddly-shaped `labels` used to fail the WHOLE list decode,
// so `bp task lint` died outright with
//
//	lint: decode tasks list: json: cannot unmarshal object into Go struct
//	field taskWire.docs.labels of type string
//
// and the board went blank. The shape is real: task-949912e93ee948d4 on
// production carries weighted TAG OBJECTS ({rationale,strength,tag}) in
// labels. Labels was the one per-doc field still typed as []string while
// every neighbour (Priority, Papers, Content, PreviousWorker, ExpiredAt, Now)
// had already been moved to json.RawMessage for exactly this reason — see
// detail_data.go's frozen tolerance contract: "one odd task's content must
// never break the whole list decode".
func TestOneOddLabelsRowDoesNotBreakTheListDecode(t *testing.T) {
	body := `{"docs":[
	  {"doc_id":"good-1","title":"First","labels":["files:internal/cli/","area:cli"]},
	  {"doc_id":"poison","title":"Weighted tags landed in labels","labels":[
	     {"rationale":"a reason long enough to be real","strength":95,"tag":"honest-gates"},
	     {"rationale":"another","strength":61,"tag":"elixir"}]},
	  {"doc_id":"good-2","title":"Third","labels":["area:api"]}
	]}`

	tasks, detail, err := decodeTaskListFull([]byte(body))
	if err != nil {
		t.Fatalf("one odd labels row failed the whole decode: %v", err)
	}
	if len(tasks) != 3 {
		t.Fatalf("got %d tasks, want 3 — a poisoned row must not drop its siblings", len(tasks))
	}
	if detail == nil {
		t.Fatal("no detail index")
	}

	byID := map[string]Task{}
	for _, task := range tasks {
		byID[task.DocID] = task
	}

	// The well-formed rows keep their labels byte-for-byte.
	if got := byID["good-1"].Labels; len(got) != 2 || got[0] != "files:internal/cli/" || got[1] != "area:cli" {
		t.Errorf("good-1 labels = %q, want the two strings unchanged", got)
	}
	if got := byID["good-2"].Labels; len(got) != 1 || got[0] != "area:api" {
		t.Errorf("good-2 labels = %q, want [area:api]", got)
	}

	// The poisoned row RECOVERS what it can: a tag object carries its name in
	// "tag", so that is the label. Dropping the row's labels entirely would
	// lose real data we are holding.
	if got := byID["poison"].Labels; len(got) != 2 || got[0] != "honest-gates" || got[1] != "elixir" {
		t.Errorf("poison labels = %q, want [honest-gates elixir] recovered from the tag objects", got)
	}
	// And the row is otherwise intact.
	if byID["poison"].Title != "Weighted tags landed in labels" {
		t.Errorf("poison row lost its title: %q", byID["poison"].Title)
	}
}

// Every other shape a labels value could take degrades to zero labels for THAT
// row and nothing else — never an error, never a lost sibling.
func TestLabelsShapesAllDegradeLocally(t *testing.T) {
	shapes := []struct {
		name   string
		labels string
		want   []string
	}{
		{"strings", `["a","b"]`, []string{"a", "b"}},
		{"empty list", `[]`, nil},
		{"null", `null`, nil},
		{"tag objects", `[{"tag":"x","strength":9}]`, []string{"x"}},
		{"mixed", `["a",{"tag":"b"},7,null,"c"]`, []string{"a", "b", "c"}},
		{"object with no tag key", `[{"strength":9}]`, nil},
		{"blank tag", `[{"tag":"   "}]`, nil},
		{"numbers", `[1,2]`, nil},
		{"nested lists", `[["a"]]`, nil},
		{"a bare string", `"not-a-list"`, nil},
		{"an object", `{"a":1}`, nil},
		{"a number", `7`, nil},
		{"blank strings dropped", `["","a"," "]`, []string{"a"}},
	}
	for _, s := range shapes {
		t.Run(s.name, func(t *testing.T) {
			body := `{"docs":[{"doc_id":"d1","title":"T","labels":` + s.labels + `}]}`
			tasks, _, err := decodeTaskListFull([]byte(body))
			if err != nil {
				t.Fatalf("labels %s failed the decode: %v", s.labels, err)
			}
			if len(tasks) != 1 {
				t.Fatalf("labels %s produced %d tasks, want 1", s.labels, len(tasks))
			}
			got := tasks[0].Labels
			if len(got) != len(s.want) {
				t.Fatalf("labels %s -> %q, want %q", s.labels, got, s.want)
			}
			for i := range s.want {
				if got[i] != s.want[i] {
					t.Fatalf("labels %s -> %q, want %q", s.labels, got, s.want)
				}
			}
			// The row itself must survive regardless.
			if tasks[0].Title != "T" {
				t.Errorf("labels %s cost the row its title", s.labels)
			}
		})
	}
}

// The envelope fence above this (decodeTaskListFull's Docs pointer check) must
// keep refusing bodies that are not a task list at all — tolerance is
// FIELD-scoped and must not soften the envelope.
func TestLabelsToleranceDoesNotSoftenTheEnvelopeFence(t *testing.T) {
	for _, poison := range []string{`{}`, `{"ok":false,"error":{"code":"nope"}}`, `null`} {
		if _, _, err := decodeTaskListFull([]byte(poison)); err == nil {
			t.Errorf("envelope poison %s decoded without error — the fence was softened", poison)
		} else if !strings.Contains(err.Error(), "decode tasks list") {
			t.Errorf("envelope poison %s gave an unexpected error: %v", poison, err)
		}
	}
	// A legitimately empty board stays a success.
	if _, _, err := decodeTaskListFull([]byte(`{"docs":[]}`)); err != nil {
		t.Errorf("an empty board must stay err=nil, got %v", err)
	}
}
