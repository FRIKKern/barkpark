package cli

// tasks_stamp_receipt_test.go — the two things a MACHINE caller of
// `bp task stamp` could not learn from its output:
//
//  1. WHETHER THE STAMP LANDED, under -o json. The verb has read the row back
//     since PDS-D359, but the verdict rode progressf — stderr under a machine
//     output shape — while stdout carried the POST's envelope. Measured on main
//     before this change: a stamp the store DROPPED printed `{"ok":true}` on
//     stdout and exited exitConflict. Every caller that parses stdout (and that
//     is what -o json is FOR) read the transport's answer and called it a done.
//
//  2. WHICH DETECTOR refused a merge-gated criterion. `merge_gated?/1` has two
//     arms — the `merge_gate` flag, and a prose fallback that runs only when the
//     key is ABSENT — and the server's hint must hedge between them because it
//     is written once for all rows. The row itself settles it in one read, and
//     the answer changes the remedy: a flagged row is a real gate, an unflagged
//     one is UNDER-DECLARED and closable by nobody until it is patched.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// stampReceiptServer is a fake Barkpark whose STORE is fixed up front, so a
// test can pin exactly what the read-back finds. stampOK decides whether the
// POST is a 200 that writes (the honest world) or the 409 merge-gate refusal.
type stampReceiptServer struct {
	// criteria is the acceptance_criteria list the GET hands back, verbatim.
	criteria []map[string]any
	// applyStamp records the POST into criteria when true; when false the POST
	// answers 200 and writes NOTHING (the dropped-write world).
	applyStamp bool
	// refuse, when set, makes the POST answer that 409 reason instead.
	refuse string
	posts  int32
}

func (s *stampReceiptServer) start(t *testing.T) {
	t.Helper()
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp"):
			atomic.AddInt32(&s.posts, 1)
			if s.refuse != "" {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"` + s.refuse +
					`","message":"this criterion is a MERGE GATE - the LEAD closes it when the PR merges. Nothing was written."}`))
				return
			}
			if s.applyStamp {
				q := r.URL.Query()
				if idx := q.Get("criterion"); idx == "0" {
					s.criteria[0]["met"] = q.Get("met") == "true"
					s.criteria[0]["evidence"] = q.Get("evidence")
				}
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-r"},"help":["bp task close bp-task-r w 1 done"]}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			body, _ := json.Marshal(map[string]any{
				"ok": true,
				"doc": map[string]any{
					"doc_id":  "bp-task-r",
					"status":  "published",
					"content": map[string]any{"acceptance_criteria": s.criteria},
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
	t.Setenv("BARKPARK_API_TOKEN", "stamp-receipt-stub")
}

func plainRow() []map[string]any {
	return []map[string]any{{"criterion": "the suite is green", "met": false, "evidence": ""}}
}

func stampJSONArgs() []string {
	return []string{
		"task", "stamp", "bp-task-r", "w", "1",
		"--criterion", "0", "--met", "--evidence", "run output",
		"--criterion-text", "the suite is green", "-o", "json",
	}
}

// decodeOne fails loudly unless stdout is EXACTLY one JSON object — the whole
// contract of -o json, and the thing a second emitted document would break.
func decodeOne(t *testing.T, stdout string) map[string]any {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(stdout))
	var doc map[string]any
	if err := dec.Decode(&doc); err != nil {
		t.Fatalf("stdout is not a JSON object: %v\ngot:\n%s", err, stdout)
	}
	var extra any
	if err := dec.Decode(&extra); err == nil {
		t.Fatalf("stdout carried MORE than one document — a scripted caller parses the first and misses the rest:\n%s", stdout)
	}
	return doc
}

// A LANDED stamp: the single stdout document says confirmed, and it says it
// from the READ-BACK (met/evidence come off the stored row).
func TestTaskStampJSONReceiptConfirmsALandedStamp(t *testing.T) {
	s := &stampReceiptServer{criteria: plainRow(), applyStamp: true}
	s.start(t)

	so, se := captureStreams(t, stampJSONArgs())
	doc := decodeOne(t, so)
	if doc["ok"] != true {
		t.Fatalf("ok = %v, want true on a landed stamp; stdout:\n%s\nstderr:\n%s", doc["ok"], so, se)
	}
	stamp, ok := doc["stamp"].(map[string]any)
	if !ok {
		t.Fatalf("the receipt carries no `stamp` block — a caller still has only the POST's word:\n%s", so)
	}
	if stamp["confirmed"] != true {
		t.Errorf("stamp.confirmed = %v, want true; got %v", stamp["confirmed"], stamp)
	}
	if stamp["criterion_index"] != float64(0) || stamp["criterion_number"] != float64(1) {
		t.Errorf("receipt lost the 0-based/1-based pair: %v", stamp)
	}
	stored, _ := stamp["stored"].(map[string]any)
	if stored["met"] != true || stored["evidence_bytes"] == float64(0) {
		t.Errorf("stamp.stored does not describe the row the store holds: %v", stored)
	}
	if probs, _ := stamp["problems"].([]any); len(probs) != 0 {
		t.Errorf("a confirmed stamp reported problems: %v", probs)
	}
	// The envelope the dispatch produced is still there — the receipt is MERGED
	// into it, never a replacement that drops the server's own fields.
	if _, present := doc["help"]; !present {
		t.Errorf("the merge dropped the server envelope's own fields:\n%s", so)
	}
}

// THE DEFECT ITSELF. The store drops the write, the verb already knew it (exit
// exitConflict, the human verdict on stderr) — and stdout said `{"ok":true}`.
// The mutation that reverts the merge reds here: `ok` goes back to the POST's
// answer while the exit code says conflict.
func TestTaskStampJSONReceiptRefusesToSayOKOnADroppedStamp(t *testing.T) {
	s := &stampReceiptServer{criteria: plainRow(), applyStamp: false}
	s.start(t)

	so, se := captureStreams(t, stampJSONArgs())
	doc := decodeOne(t, so)
	if doc["ok"] != false {
		t.Fatalf("stdout said ok=%v on a stamp the store does NOT hold — the transport is still speaking for the ledger; stdout:\n%s\nstderr:\n%s", doc["ok"], so, se)
	}
	stamp, ok := doc["stamp"].(map[string]any)
	if !ok {
		t.Fatalf("no `stamp` block on the failing path:\n%s", so)
	}
	if stamp["confirmed"] != false {
		t.Errorf("stamp.confirmed = %v, want false", stamp["confirmed"])
	}
	probs, _ := stamp["problems"].([]any)
	if len(probs) == 0 {
		t.Errorf("a NOT-confirmed receipt must say what disagreed: %v", stamp)
	}
	if stored, _ := stamp["stored"].(map[string]any); stored["met"] != false {
		t.Errorf("stamp.stored should report the unmet row the store holds: %v", stored)
	}
}

// A REFUSAL the server made before any commit: nothing was read back, so the
// error envelope must pass through byte-for-byte — no invented `stamp` block,
// no rewritten `ok`. The capture must never author a claim it did not earn.
func TestTaskStampJSONPassesARefusalThroughUntouched(t *testing.T) {
	s := &stampReceiptServer{criteria: plainRow(), refuse: "merge_gated_criterion"}
	s.start(t)

	so, _ := captureStreams(t, stampJSONArgs())
	doc := decodeOne(t, so)
	if doc["ok"] != false {
		t.Errorf("a refusal envelope should stay ok:false, got %v", doc["ok"])
	}
	if _, present := doc["stamp"]; present {
		t.Errorf("nothing was read back, so the receipt must not carry a stamp verdict:\n%s", so)
	}
}

// The human shapes are UNCHANGED: the verdict stays the primary stdout line and
// no JSON leaks into it. A capture armed for every output shape would red here.
func TestTaskStampHumanOutputIsUnchangedByTheCapture(t *testing.T) {
	s := &stampReceiptServer{criteria: plainRow(), applyStamp: true}
	s.start(t)

	args := stampJSONArgs()
	so, _ := captureStreams(t, append(args[:len(args)-2], "-o", "table"))
	if !strings.Contains(so, "the store holds it") {
		t.Fatalf("the human verdict left stdout:\n%s", so)
	}
	if strings.Contains(so, `"stamp"`) {
		t.Errorf("machine receipt leaked into the human view:\n%s", so)
	}
}

// ─── WHICH DETECTOR FIRED ───────────────────────────────────────────────────

func mergeGateRefusalArgs() []string {
	return []string{
		"task", "stamp", "bp-task-r", "w", "1",
		"--criterion", "0", "--met", "--evidence", "run output",
		"--criterion-text", "[MERGE-GATED] PR merged to main",
	}
}

// FLAG ARM: the row declares itself a gate. The refusal must say so — there is
// no prose false positive to argue about and no wording change can lift it.
func TestTaskStampMergeGateRefusalNamesTheFlagDetector(t *testing.T) {
	flag := true
	s := &stampReceiptServer{
		criteria: []map[string]any{{
			"criterion": "[MERGE-GATED] PR merged to main", "met": false,
			"evidence": "", "merge_gate": flag,
		}},
		refuse: "merge_gated_criterion",
	}
	s.start(t)

	_, se := captureStreams(t, mergeGateRefusalArgs())
	if !strings.Contains(se, "DETECTOR: the merge_gate FLAG") {
		t.Fatalf("the refusal did not name the detector that fired; stderr:\n%s", se)
	}
	if strings.Contains(se, "PROSE fallback") {
		t.Errorf("a flagged row was blamed on the prose arm; stderr:\n%s", se)
	}
	// It must NOT offer the patch remedy: this row's shape is already right.
	if strings.Contains(se, "UNDER-DECLARED") {
		t.Errorf("a declared gate was called under-declared; stderr:\n%s", se)
	}
}

// PROSE ARM — the state `bp task create` files by default. The row carries NO
// `merge_gate` key, so the guard matched the WORDING, and that same row is
// invisible to the lead's close-time autostamp: closable by nobody. The
// refusal has to name the arm AND the patch.
func TestTaskStampMergeGateRefusalNamesTheProseDetectorAndThePatch(t *testing.T) {
	s := &stampReceiptServer{
		criteria: []map[string]any{{
			"criterion": "[MERGE-GATED] PR merged to main", "met": false, "evidence": "",
		}},
		refuse: "merge_gated_criterion",
	}
	s.start(t)

	_, se := captureStreams(t, mergeGateRefusalArgs())
	if !strings.Contains(se, "DETECTOR: the PROSE fallback") {
		t.Fatalf("the refusal did not name the prose arm; stderr:\n%s", se)
	}
	if !strings.Contains(se, `carries NO "merge_gate" key`) {
		t.Errorf("the refusal did not say the FLAG is absent; stderr:\n%s", se)
	}
	if !strings.Contains(se, "UNDER-DECLARED") {
		t.Errorf("the refusal did not say the row's shape disagrees with its words; stderr:\n%s", se)
	}
	if !strings.Contains(se, "bp doc patch task bp-task-r") {
		t.Errorf("the refusal named no way to patch the row; stderr:\n%s", se)
	}
	if !strings.Contains(se, `"merge_gate": true`) || !strings.Contains(se, `"merge_gate": false`) {
		t.Errorf("the remedy must offer BOTH declarations (real gate / mere mention); stderr:\n%s", se)
	}
}

// A refusal that is NOT the merge gate must not grow a detector line — the
// explainer is keyed on the reason code, not on the presence of a marker.
func TestTaskStampOtherRefusalsGetNoDetectorLine(t *testing.T) {
	s := &stampReceiptServer{criteria: plainRow(), refuse: "criteria_mismatch"}
	s.start(t)

	_, se := captureStreams(t, mergeGateRefusalArgs())
	if strings.Contains(se, "DETECTOR:") {
		t.Errorf("a non-merge-gate refusal got a merge-gate detector line; stderr:\n%s", se)
	}
}

// The tri-state read is the diagnosis: absent is NOT false. Collapsing them
// would report a `merge_gate: false` row (an explicit NOT-A-GATE) as the
// under-declared case and hand the author a patch it does not need.
func TestStoredMergeGateFlagIsThreeValued(t *testing.T) {
	s := &stampReceiptServer{criteria: []map[string]any{
		{"criterion": "flagged", "merge_gate": true},
		{"criterion": "denied", "merge_gate": false},
		{"criterion": "absent"},
	}}
	s.start(t)
	c := taskReadbackClient(manifest.Context{
		Server: os.Getenv("BARKPARK_API_URL"),
		Token:  os.Getenv("BARKPARK_API_TOKEN"),
	})

	for i, want := range []string{"true", "false", "absent"} {
		got, text, err := storedMergeGateFlag(c, "bp-task-r", i)
		if err != nil {
			t.Fatalf("index %d: %v", i, err)
		}
		switch {
		case want == "absent" && got != nil:
			t.Errorf("index %d: absent key decoded as %v", i, *got)
		case want == "true" && (got == nil || !*got):
			t.Errorf("index %d: merge_gate:true decoded as %v", i, got)
		case want == "false" && (got == nil || *got):
			t.Errorf("index %d: merge_gate:false decoded as %v", i, got)
		}
		if text == "" {
			t.Errorf("index %d: the criterion text did not come back", i)
		}
	}
	if _, _, err := storedMergeGateFlag(c, "bp-task-r", 9); err == nil {
		t.Errorf("an out-of-range index must be an honest error, not a verdict")
	}
	if _, _, err := storedMergeGateFlag(c, "bp-task-r", -1); err == nil {
		t.Errorf("a negative index must be an honest error")
	}
}
