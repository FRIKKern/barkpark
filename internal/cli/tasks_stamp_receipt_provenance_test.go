package cli

// tasks_stamp_receipt_provenance_test.go — WHERE THE "✓ the store holds it"
// LINE GETS ITS NUMBERS FROM (task-66f1afe806025f65).
//
// THE QUESTION THE ROW ASKS. `bp task stamp` prints
//
//	✓ the store holds it — criterion index N (#N+1 as boards number them): met=true  evidence NNN bytes …
//
// and a campaign's worth of "I read the stamp back" claims rest on that one
// line. If it were rendered from the REQUEST, it would be a restatement of
// intent wearing the costume of a receipt. Reading the code answers it:
// renderStampVerdict takes `stored taskboard.CriterionItem` and hands it to
// storedCriterionSummary, which reads stored.Met / len(stored.Evidence); that
// value is produced by confirmStampLanded → taskboard.FetchCriterion →
// apiclient.Client.TaskGetContent, a SECOND GET against /v1/tasks/:doc_id. The
// request appears in the verdict only as the "expected" half of a
// contradiction.
//
// WHY THAT READING NEEDS A TEST ANYWAY. Reading is a claim about today's tree.
// The existing suite proves the verdict refuses a DROPPED write
// (TestTaskStampExecute_DroppedWriteIsNotSuccess) — but on every GREEN path in
// that suite the request and the store carry byte-identical values, so a
// mutation that rendered the green line from `req` instead of `stored` would
// print the same numbers and stay green there. This file closes that gap with
// a green in which the two sources DISAGREE NUMERICALLY, so the printed byte
// count discriminates between them.
//
// THE SEAM. stampMismatches compares evidence with strings.TrimSpace on both
// sides, so a server that NORMALISES evidence by trimming it accepts the write,
// the verdict greens — and len(stored.Evidence) != len(req.evidence). That is a
// reachable green whose receipt can only be right if it was rendered from the
// returned document.
//
// NAMED MUTATION → RED (both arms were run):
//   - storedCriterionSummary reading len(req.evidence): reds
//     TestStampGreenReceiptCountsTheSTOREDEvidenceNotTheSent.
//   - deleting the read-back and greening off the POST: reds
//     TestStampReceiptRefusesAReturnedDocumentThatDidNotChange.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// stampProvenanceServer is a fake Barkpark whose store NORMALISES what it is
// given: it trims the evidence before storing it, and it can be told to accept
// the POST while leaving the row untouched. Both behaviours are things a real
// server can do, and both make the request and the store disagree — which is
// the only condition under which the receipt's source is observable.
type stampProvenanceServer struct {
	mu sync.Mutex
	// drop, when true, answers the POST ok:true and writes NOTHING: the
	// success-shaped response over a row that did not change.
	drop bool
	// rows is the store, indexed the way acceptance_criteria is.
	rows []map[string]any
}

func (s *stampProvenanceServer) start(t *testing.T) {
	t.Helper()
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp"):
			if !s.drop {
				q := stampMergedParams(r)
				if idx, err := strconv.Atoi(q.Get("criterion")); err == nil && idx >= 0 && idx < len(s.rows) {
					ctext := q.Get("criterion_text")
					if ctext == "" {
						ctext = q.Get("criterion-text")
					}
					s.mu.Lock()
					s.rows[idx] = map[string]any{
						"criterion": ctext,
						"met":       q.Get("met") == "true",
						// THE NORMALISATION: the store keeps the trimmed text,
						// not the bytes it was handed.
						"evidence": strings.TrimSpace(q.Get("evidence")),
					}
					s.mu.Unlock()
				}
			}
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			s.mu.Lock()
			body, _ := json.Marshal(map[string]any{
				"ok": true,
				"doc": map[string]any{
					"doc_id":  "bp-task-p",
					"status":  "published",
					"content": map[string]any{"acceptance_criteria": s.rows},
				},
			})
			s.mu.Unlock()
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
	t.Setenv("BARKPARK_API_TOKEN", "stamp-provenance-stub")
}

func stampProvenanceRows() []map[string]any {
	rows := make([]map[string]any, 4)
	for i := range rows {
		rows[i] = map[string]any{"criterion": "", "met": false, "evidence": ""}
	}
	return rows
}

const (
	// The request carries padding; the store keeps the trimmed text. 10 bytes
	// stored, 16 sent — the two numbers a receipt can be rendered from.
	stampProvenanceSent   = "   gate green   "
	stampProvenanceStored = "gate green"
)

func stampProvenanceArgs(extra ...string) []string {
	return append([]string{
		"task", "stamp", "bp-task-p", "w", "1",
		"--criterion", "2", "--met", "--evidence", stampProvenanceSent,
		"--criterion-text", "a normal row",
	}, extra...)
}

// TestStampGreenReceiptCountsTheSTOREDEvidenceNotTheSent is the provenance
// guard, and it is the arm the existing suite did not have: a GREEN in which
// the request and the returned document disagree on the one number the receipt
// prints. It passes only if the line was rendered from the document the store
// handed back.
func TestStampGreenReceiptCountsTheSTOREDEvidenceNotTheSent(t *testing.T) {
	if len(stampProvenanceStored) == len(stampProvenanceSent) {
		t.Fatalf("the fixture does not discriminate: stored and sent are both %d bytes", len(stampProvenanceStored))
	}
	s := &stampProvenanceServer{rows: stampProvenanceRows()}
	s.start(t)

	out, code := captureExecuteCode(t, stampProvenanceArgs())
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — a trimmed-but-equal evidence is a landed write; out:\n%s", code, out)
	}
	if !strings.Contains(out, "the store holds it") {
		t.Fatalf("no success receipt to inspect; out:\n%s", out)
	}
	wantStored := "evidence " + strconv.Itoa(len(stampProvenanceStored)) + " bytes"
	if !strings.Contains(out, wantStored) {
		t.Errorf("the receipt does not print the STORED byte count %q — it was not rendered from the returned document; out:\n%s",
			wantStored, out)
	}
	notWant := "evidence " + strconv.Itoa(len(stampProvenanceSent)) + " bytes"
	if strings.Contains(out, notWant) {
		t.Errorf("the receipt printed the REQUEST's byte count %q — the line is a restatement of intent, not a receipt; out:\n%s",
			notWant, out)
	}
}

// The machine half: a scripted caller branches on stamp.stored.evidence_bytes,
// so that number carries the same provenance obligation as the prose.
func TestStampJSONReceiptStoredBytesComeFromTheReturnedDocument(t *testing.T) {
	s := &stampProvenanceServer{rows: stampProvenanceRows()}
	s.start(t)

	so, _, code := captureExecuteArgv(t, append(stampProvenanceArgs(), "-o", "json")...)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; stdout:\n%s", code, so)
	}
	doc := decodeOne(t, so)
	stamp, ok := doc["stamp"].(map[string]any)
	if !ok {
		t.Fatalf("no `stamp` receipt on stdout:\n%s", so)
	}
	if stamp["confirmed"] != true {
		t.Fatalf("stamp.confirmed = %v, want true", stamp["confirmed"])
	}
	stored, ok := stamp["stored"].(map[string]any)
	if !ok {
		t.Fatalf("the receipt carries no `stored` block: %v", stamp)
	}
	got, _ := stored["evidence_bytes"].(float64)
	if int(got) != len(stampProvenanceStored) {
		t.Errorf("stamp.stored.evidence_bytes = %d, want %d (the STORE's bytes; the request sent %d)",
			int(got), len(stampProvenanceStored), len(stampProvenanceSent))
	}
}

// TestStampReceiptRefusesAReturnedDocumentThatDidNotChange pins the refusal
// half on the exact shape this row was filed against: a success-shaped POST
// over a criterion the returned document does not carry. The refusal must NAME
// the criterion index in both numberings — a refusal that names nothing leaves
// the caller re-reading the wrong row.
func TestStampReceiptRefusesAReturnedDocumentThatDidNotChange(t *testing.T) {
	s := &stampProvenanceServer{rows: stampProvenanceRows(), drop: true}
	s.start(t)

	out, code := captureExecuteCode(t, stampProvenanceArgs())
	if code == exitOK {
		t.Fatalf("exit 0 over a document whose criterion did not change — the receipt is not reading the returned document; out:\n%s", out)
	}
	if code != exitConflict {
		t.Errorf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	if strings.Contains(out, "✓ the store holds it") {
		t.Fatalf("a success receipt over an unchanged row; out:\n%s", out)
	}
	for _, want := range []string{
		"NOT confirmed",
		"index 2 (0-based)",
		"criterion #3",
		"met is still FALSE in the store",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the refusal does not carry %q; out:\n%s", want, out)
		}
	}
}
