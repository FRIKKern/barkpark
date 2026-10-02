package cli

// tasks_stamp_persistence_matrix_test.go — THE FOUR-CELL EXIT-vs-PERSISTENCE
// MATRIX for `bp task stamp` (task-d2006c0afd97746a c0).
//
// WHY THE TWO HALVES ARE MEASURED SEPARATELY. The question this row was filed
// against is not "does the stamp work" — it is "can the exit code and the store
// ever DISAGREE?" A verb that reports success while the write did not land is
// the whole defect family, and a test that asserts only the exit code proves
// exactly half of the claim it makes. So every cell below asserts BOTH:
//
//	EXIT       — the code Execute() actually returned, from the real dispatch.
//	PERSISTENCE— read out of the fake store's OWN state after the run, never out
//	             of the CLI's output. The CLI's report is the thing under test;
//	             it cannot also be the instrument that grades it.
//
// WHAT "AGAINST A LIVE SERVER" HONESTLY MEANS HERE. There is no Phoenix in the
// Go CI job, and this tree has no integration build tag that starts one — so
// "live" here is a real HTTP server on loopback (httptest), speaking the real
// wire protocol, driven through the REAL CLI path: parseGlobals → manifest
// dispatch → the actual POST → confirmStampLanded's actual read-back →
// renderStampVerdict's actual verdict. Nothing in internal/cli is stubbed; only
// the far side of the socket is. The fake is a STATE MACHINE, not a canned
// answer: it holds a row, applies the same precondition ladder the server runs
// (check_in_progress → check_holder → check_fencing, `api/lib/barkpark/tasks/
// stamp.ex`) and writes only when the ladder is cleared. A fake that returned
// the finished verdict would test nothing.
//
// WHAT THIS DOES NOT COVER, stated rather than glossed: it does not prove the
// SERVER's ladder — that it really refuses a non-holder, a stale epoch and a
// row with no live claim. That half is pinned in Elixir against a real
// Postgres, in api/test/barkpark/tasks/stamp_test.exs ("a non-holder cannot
// stamp", "a stale epoch is fenced off exactly like close", "a task without a
// live claim is not stampable"). The two halves meet at the wire shape this
// file encodes. Nor does it exercise TLS, auth tiers, or the real router's
// drafts.* fallback — the draft cells model that fallback by ANSWERING as the
// draft twin, which is what the fallback does from the client's side.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// stampMatrixRow is the one row the fake store holds. Its fields are exactly
// the inputs the server's precondition ladder reads.
type stampMatrixRow struct {
	docID     string
	status    string // "published" or "draft" — what the GET reports as answering
	lifecycle string // "open" | "in_progress"
	claimer   string // worker holding the claim ("" = no claim)
	epoch     string // the claim's current fencing epoch
	criteria  []map[string]any
}

// stampMatrixServer is a fake Barkpark with a STORE. It refuses or writes by
// running the ladder over its own state; it never returns a pre-decided answer.
type stampMatrixServer struct {
	mu    sync.Mutex
	row   stampMatrixRow
	posts int
	wrote bool // set only when the ladder cleared and the criterion was written
}

// stampMatrixLadder is the server's precondition order, transcribed. It returns
// the refusal reason, or "" when the write is permitted.
func (s *stampMatrixServer) stampMatrixLadder(worker, epoch string) string {
	switch {
	case s.row.lifecycle != "in_progress":
		return "not_in_progress:" + s.row.lifecycle
	case worker != s.row.claimer:
		return "not_holder"
	case epoch != s.row.epoch:
		return "fenced_off"
	}
	return ""
}

func (s *stampMatrixServer) start(t *testing.T) {
	t.Helper()
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp"):
			s.posts++
			q := stampMergedParams(r)
			if reason := s.stampMatrixLadder(q.Get("worker_id"), q.Get("observed_epoch")); reason != "" {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"` + reason +
					`","message":"the ledger refused this stamp before any write. Nothing was written."}`))
				return
			}
			if idx := q.Get("criterion"); idx == "0" && len(s.row.criteria) > 0 {
				s.row.criteria[0]["met"] = q.Get("met") == "true"
				s.row.criteria[0]["evidence"] = q.Get("evidence")
				s.wrote = true
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"` + s.row.docID + `"}}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			// The drafts.* fallback as the CLIENT sees it: when no published row
			// exists, the row that answers is the draft twin, and it says so in
			// both its doc_id prefix and its status.
			id, status := s.row.docID, s.row.status
			if status == "draft" {
				id = "drafts." + id
			}
			body, _ := json.Marshal(map[string]any{
				"ok": true,
				"doc": map[string]any{
					"doc_id":  id,
					"status":  status,
					"content": map[string]any{"acceptance_criteria": s.row.criteria},
				},
			})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(be.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", be.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-matrix-stub")
}

// persisted reports what the STORE holds, read straight off the fake's state.
// This is the independent half of every cell: the CLI never touches it.
func (s *stampMatrixServer) persisted() (met bool, evidence string, wrote bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, _ := s.row.criteria[0]["met"].(bool)
	ev, _ := s.row.criteria[0]["evidence"].(string)
	return m, ev, s.wrote
}

func stampMatrixCriteria() []map[string]any {
	return []map[string]any{{"criterion": "the suite is green", "met": false, "evidence": ""}}
}

const stampMatrixEvidence = "run output: 7/7 PASS"

func stampMatrixArgs(worker, epoch string) []string {
	return []string{
		"task", "stamp", "bp-task-m", worker, epoch,
		"--criterion", "0", "--met", "--evidence", stampMatrixEvidence,
		"--criterion-text", "the suite is green",
	}
}

// TestTaskStampExitVersusPersistenceMatrix is the regression c0 asks for. Each
// cell names what the EXIT must be and, INDEPENDENTLY, what the store must
// hold. A future change that makes any cell silently succeed — reporting a zero
// exit for a write that did not land, or landing a write a precondition should
// have refused — reds exactly that cell.
func TestTaskStampExitVersusPersistenceMatrix(t *testing.T) {
	cases := []struct {
		cell string
		row  stampMatrixRow
		// what the caller asks
		worker, epoch string
		// the two independent halves
		wantCode      int  // the EXACT exit code, not merely "non-zero"
		wantExit      bool // true = exit 0 (a reported success)
		wantPersisted bool // true = the store really holds the flip
		why           string
	}{
		{
			cell:          "draft-only-open",
			wantCode:      exitConflict,
			row:           stampMatrixRow{docID: "bp-task-m", status: "draft", lifecycle: "open", claimer: "", epoch: "1", criteria: stampMatrixCriteria()},
			worker:        "w",
			epoch:         "1",
			wantExit:      false,
			wantPersisted: false,
			why:           "a row with no live claim is not stampable; the ladder refuses before any write",
		},
		{
			cell:          "nonholder-inprogress",
			wantCode:      exitConflict,
			row:           stampMatrixRow{docID: "bp-task-m", status: "published", lifecycle: "in_progress", claimer: "someone-else", epoch: "1", criteria: stampMatrixCriteria()},
			worker:        "w",
			epoch:         "1",
			wantExit:      false,
			wantPersisted: false,
			why:           "the claim belongs to another worker; a stamp from a non-holder writes nothing",
		},
		{
			cell:          "holder-stale-epoch",
			wantCode:      exitConflict,
			row:           stampMatrixRow{docID: "bp-task-m", status: "published", lifecycle: "in_progress", claimer: "w", epoch: "2", criteria: stampMatrixCriteria()},
			worker:        "w",
			epoch:         "1",
			wantExit:      false,
			wantPersisted: false,
			why:           "the right worker at the WRONG epoch is fenced off — a pulse or re-claim moved the fence under them",
		},
		{
			cell:          "holder-current-epoch",
			wantCode:      exitOK,
			row:           stampMatrixRow{docID: "bp-task-m", status: "published", lifecycle: "in_progress", claimer: "w", epoch: "1", criteria: stampMatrixCriteria()},
			worker:        "w",
			epoch:         "1",
			wantExit:      true,
			wantPersisted: true,
			why:           "the only cell that may report success, and it may do so only because the store really holds the flip",
		},
		{
			// THE DISAGREEMENT CELL. Exit and persistence part company here by
			// DESIGN, and that is the whole reason the two halves are measured
			// apart: the write lands, and the verb still refuses to call it a
			// pass, because it landed on a row no board reads.
			cell:          "draft-only-holder-at-current-epoch",
			wantCode:      exitConflict,
			row:           stampMatrixRow{docID: "bp-task-m", status: "draft", lifecycle: "in_progress", claimer: "w", epoch: "1", criteria: stampMatrixCriteria()},
			worker:        "w",
			epoch:         "1",
			wantExit:      false,
			wantPersisted: true,
			why:           "the draft twin accepts the write; the verdict still refuses the green because no board renders that row",
		},
	}

	for _, c := range cases {
		t.Run(c.cell, func(t *testing.T) {
			s := &stampMatrixServer{row: c.row}
			s.start(t)

			so, se, code := captureExecuteArgv(t, stampMatrixArgs(c.worker, c.epoch)...)

			// HALF ONE — what it REPORTED.
			if code != c.wantCode {
				t.Errorf("EXIT half: exit=%d, want %d — %s\nstdout:\n%s\nstderr:\n%s",
					code, c.wantCode, c.why, so, se)
			}
			if got := code == exitOK; got != c.wantExit {
				t.Errorf("EXIT half: exit=%d (success=%v), want success=%v — %s\nstdout:\n%s\nstderr:\n%s",
					code, got, c.wantExit, c.why, so, se)
			}
			if !c.wantExit && code == exitOK {
				t.Errorf("a refused cell reported exit 0 — this is the silent success the matrix exists to catch")
			}

			// HALF TWO — what the STORE holds, read off the server's own state.
			met, ev, wrote := s.persisted()
			if wrote != c.wantPersisted {
				t.Errorf("PERSISTENCE half: the store wrote=%v, want %v — %s", wrote, c.wantPersisted, c.why)
			}
			if c.wantPersisted {
				if !met || ev != stampMatrixEvidence {
					t.Errorf("PERSISTENCE half: the store holds met=%v evidence=%q, want met=true evidence=%q",
						met, ev, stampMatrixEvidence)
				}
			} else {
				if met || ev != "" {
					t.Errorf("PERSISTENCE half: a refused cell left met=%v evidence=%q in the store — the refusal was not clean",
						met, ev)
				}
			}
			if s.posts != 1 {
				t.Errorf("the verb sent %d stamp POSTs, want exactly 1 — the cell did not exercise the wire it claims to", s.posts)
			}
		})
	}
}

// TestStampDraftOnlyRulingRidesTheRefusalAndTheReceipt is the DETECTOR for the
// c2 ruling (tasks_stamp_draft_ruling.go). The ruling is "keep the write,
// refuse the green", and a ruling that lives only in a commit message does not
// fire — so it must reach the caller on the path it governs, in BOTH output
// shapes, and the KEEP half must be visibly true: the write is still in the
// store after the refusal.
func TestStampDraftOnlyRulingRidesTheRefusalAndTheReceipt(t *testing.T) {
	draftRow := func() stampMatrixRow {
		return stampMatrixRow{docID: "bp-task-m", status: "draft", lifecycle: "in_progress",
			claimer: "w", epoch: "1", criteria: stampMatrixCriteria()}
	}

	// HUMAN shape: the ruling rides the refusal the operator is reading.
	t.Run("human refusal carries the ruling", func(t *testing.T) {
		s := &stampMatrixServer{row: draftRow()}
		s.start(t)
		_, se, code := captureExecuteArgv(t, stampMatrixArgs("w", "1")...)
		if code == exitOK {
			t.Fatalf("the draft path reported success; the ruling refuses the GREEN, not only the silence")
		}
		if !strings.Contains(se, "RULED (task-d2006c0afd97746a)") {
			t.Errorf("the refusal does not carry the recorded ruling — the next caller learns nothing:\nstderr:\n%s", se)
		}
		if !strings.Contains(se, "Drafts stay free; publish is the wall") {
			t.Errorf("the refusal states no REASON a caller can act on:\nstderr:\n%s", se)
		}
		// The KEEP half of the ruling, proven rather than asserted: the write
		// that the CLI just refused to call a pass is still in the store.
		if met, ev, wrote := s.persisted(); !wrote || !met || ev != stampMatrixEvidence {
			t.Errorf("the ruling says the write is KEPT, but the store holds wrote=%v met=%v evidence=%q", wrote, met, ev)
		}
	})

	// MACHINE shape: a scripted caller reads `-o json` and never sees stderr
	// prose, so the ruling rides the receipt's notes as well.
	t.Run("json receipt carries the ruling in notes", func(t *testing.T) {
		s := &stampMatrixServer{row: draftRow()}
		s.start(t)
		so, _, _ := captureExecuteArgv(t, append(stampMatrixArgs("w", "1"), "-o", "json")...)
		doc := decodeOne(t, so)
		stamp, ok := doc["stamp"].(map[string]any)
		if !ok {
			t.Fatalf("no `stamp` receipt on the draft path:\n%s", so)
		}
		if stamp["confirmed"] != false {
			t.Errorf("stamp.confirmed = %v on a draft-only row, want false", stamp["confirmed"])
		}
		notes, _ := stamp["notes"].([]any)
		found := false
		for _, n := range notes {
			if s, _ := n.(string); strings.Contains(s, "RULED (task-d2006c0afd97746a)") {
				found = true
			}
		}
		if !found {
			t.Errorf("the machine receipt carries no ruling note — a scripted caller cannot learn why the write happened: %v", notes)
		}
	})
}
