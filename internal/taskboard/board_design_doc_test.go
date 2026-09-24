package taskboard

import "testing"

// THE CONSUMER HALF OF task-cf0395706361aa2e (task-190780ed9852f2de).
//
// `?view=board` deletes `content`, so `content.design_doc` — the input the
// paper→tasks inversion (DrivenTasks → FramePaper) reads — used to be
// unrecoverable from a board card: `has_paper` collapsed it into one bit. The
// api now sends the slug as `content_digest.design_doc`. These tests decode a
// board list exactly as the live poll does and ask the inversion FramePaper
// renders from (program.go: RenderPaperFrame(ps, DrivenTasks(...))).
const boardListDesignDoc = `{"docs": [
  {"doc_id": "drafts.task-dd", "title": "names the paper only via design_doc",
   "lifecycle_status": "open",
   "content_digest": {"design_doc": "drafts.board-dd-paper", "has_paper": true}},
  {"doc_id": "task-papers", "title": "names the paper via papers[]",
   "lifecycle_status": "open", "papers": ["board-dd-paper"],
   "content_digest": {"has_paper": true}},
  {"doc_id": "task-none", "title": "names no paper (control)",
   "lifecycle_status": "open",
   "content_digest": {"has_paper": false}},
  {"doc_id": "task-other", "title": "names a DIFFERENT paper (control)",
   "lifecycle_status": "open",
   "content_digest": {"design_doc": "some-other-paper", "has_paper": true}}
]}`

func drivenIDs(t *testing.T, body, slug string) map[string]bool {
	t.Helper()
	tasks, details, err := decodeTaskListFull([]byte(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(tasks) != 4 {
		t.Fatalf("precondition: decoded %d tasks, want 4", len(tasks))
	}
	got := map[string]bool{}
	for _, tk := range DrivenTasks(tasks, details, slug) {
		got[tk.DocID] = true
	}
	return got
}

func TestBoardCardDesignDocFeedsPaperInversion(t *testing.T) {
	got := drivenIDs(t, boardListDesignDoc, "board-dd-paper")
	// The papers[] path already worked before this change — the positive
	// control that the inversion ran at all over these decoded rows.
	if !got["task-papers"] {
		t.Fatalf("control: task naming the paper via papers[] is not listed; got %v", got)
	}
	if !got["drafts.task-dd"] {
		t.Fatalf("FramePaper under-lists: a board card whose content_digest.design_doc names the paper is not driven by it; got %v", got)
	}
	if got["task-none"] || got["task-other"] {
		t.Fatalf("a card with no/other design_doc is listed for the paper; got %v", got)
	}
	if len(got) != 2 {
		t.Fatalf("want exactly 2 driven tasks, got %v", got)
	}
	// The drafts. spelling on either side collapses, as on the full view.
	if got := drivenIDs(t, boardListDesignDoc, "drafts.board-dd-paper"); !got["drafts.task-dd"] || len(got) != 2 {
		t.Fatalf("drafts.-spelled slug lookup: got %v", got)
	}
}

// PaperRefs (the detail pane's paper list) reads the same field.
func TestBoardCardDesignDocInPaperRefs(t *testing.T) {
	tasks, details, err := decodeTaskListFull([]byte(boardListDesignDoc))
	if err != nil || len(tasks) != 4 {
		t.Fatalf("decode: %v (%d tasks)", err, len(tasks))
	}
	if refs := details["drafts.task-dd"].PaperRefs(); len(refs) != 1 || bareID(refs[0]) != "board-dd-paper" {
		t.Fatalf("PaperRefs on the design_doc-only card = %v, want [board-dd-paper]", refs)
	}
	if refs := details["task-none"].PaperRefs(); refs != nil {
		t.Fatalf("control: PaperRefs on a card with no paper = %v, want nil", refs)
	}
}

// On the full view `content` is present and wins; the digest (absent there
// anyway) must never override a stored content.design_doc.
func TestFullViewDesignDocUnchanged(t *testing.T) {
	body := `{"docs": [{"doc_id": "task-full", "title": "x", "lifecycle_status": "open",
	  "content": {"design_doc": "full-paper"},
	  "content_digest": {"design_doc": "digest-paper"}}]}`
	_, details, err := decodeTaskListFull([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if got := details["task-full"].DesignDoc; got != "full-paper" {
		t.Fatalf("DesignDoc = %q, want content's %q", got, "full-paper")
	}
}
