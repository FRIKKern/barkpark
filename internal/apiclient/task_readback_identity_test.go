package apiclient

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The read-back must be able to NAME the row it read (pds-w43).
//
// GET /v1/tasks/:doc_id falls back to the `drafts.` twin when no published row
// exists for the id, so an id that names a board row to the caller can be
// answered by a draft the board never shows. The server has always sent both
// signals — Params.render_doc emits `doc_id` and `status` — and the decode here
// used to be exactly `{ok, reason, doc:{content}}`, dropping both on the floor.
// A read-back that cannot say which row answered cannot support any claim about
// the board.

func TestTaskGetContentCarriesTheAnsweringRowIdentity(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// The shape the API actually sends for a draft-only row: the caller
		// asked for `task-abc`, the DRAFT twin answered.
		_, _ = io.WriteString(w, `{"ok":true,"doc":{
			"doc_id":"drafts.task-abc",
			"status":"draft",
			"content":{"acceptance_criteria":[{"criterion":"c","met":true}]}
		}}`)
	}))
	defer srv.Close()

	rb, err := New(Config{BaseURL: srv.URL}).TaskGetContent("task-abc")
	if err != nil {
		t.Fatalf("TaskGetContent: %v", err)
	}
	if rb.DocID != "drafts.task-abc" {
		t.Errorf("DocID = %q, want %q — the read-back cannot name the row it read", rb.DocID, "drafts.task-abc")
	}
	if rb.Status != "draft" {
		t.Errorf("Status = %q, want %q", rb.Status, "draft")
	}
	if len(rb.Content) == 0 {
		t.Errorf("Content was dropped while adding the identity fields")
	}
	if !rb.IsDraft() {
		t.Errorf("IsDraft() = false on a drafts. doc_id with status draft")
	}
}

// TestTaskReadbackIsDraft pins the classifier's exact boundary, including the
// one case it must NOT claim: an envelope carrying neither field has told us
// nothing about which row answered, and nothing is not evidence of a draft.
func TestTaskReadbackIsDraft(t *testing.T) {
	cases := []struct {
		name string
		rb   TaskReadback
		want bool
	}{
		{"published board row", TaskReadback{DocID: "task-abc", Status: "published"}, false},
		{"drafts. prefix", TaskReadback{DocID: "drafts.task-abc", Status: "published"}, true},
		{"status not published", TaskReadback{DocID: "task-abc", Status: "draft"}, true},
		{"both signals", TaskReadback{DocID: "drafts.task-abc", Status: "draft"}, true},
		{"server named nothing", TaskReadback{}, false},
		{"doc_id only, no status", TaskReadback{DocID: "task-abc"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.rb.IsDraft(); got != tc.want {
				t.Errorf("IsDraft() = %v, want %v for %+v", got, tc.want, tc.rb)
			}
		})
	}
}
