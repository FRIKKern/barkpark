package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// --- pure-function mutation-proofs -------------------------------------------

// parseStampArgs must NEVER re-index --criterion (the index a builder types is
// the index the server receives) and must strip ONLY the CLI-only
// --merge-gated, forwarding every other token in order. A mutation that
// shifted the index, or that leaked --merge-gated into the forwarded tail
// (which the server does not declare → splitArgs "unknown flag"), reds here.
func TestParseStampArgs_StripsMergeGatedForwardsRestVerbatim(t *testing.T) {
	tail := []string{
		"bp-task-x", "worker-1", "2",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "some row", "--merge-gated",
	}
	sa, forward := parseStampArgs(tail)

	if sa.criterion == nil || *sa.criterion != 3 {
		t.Fatalf("criterion = %v, want 3 (no re-index)", sa.criterion)
	}
	if !sa.met || sa.miss {
		t.Errorf("met/miss = %v/%v, want met", sa.met, sa.miss)
	}
	if sa.criterionText != "some row" {
		t.Errorf("criterionText = %q, want %q", sa.criterionText, "some row")
	}
	if !sa.mergeGated {
		t.Errorf("mergeGated not parsed")
	}
	want := []string{
		"bp-task-x", "worker-1", "2",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "some row",
	}
	if !reflect.DeepEqual(forward, want) {
		t.Errorf("forward = %v\n want %v (only --merge-gated stripped, order kept)", forward, want)
	}
	for _, tok := range forward {
		if tok == "--merge-gated" {
			t.Fatalf("--merge-gated leaked into the forwarded tail")
		}
	}
}

// The `--flag=value` inline spelling must parse identically to the space form.
func TestParseStampArgs_InlineForms(t *testing.T) {
	sa, forward := parseStampArgs([]string{"--criterion=5", "--criterion-text=inline row", "--met=true"})
	if sa.criterion == nil || *sa.criterion != 5 {
		t.Fatalf("criterion = %v, want 5", sa.criterion)
	}
	if sa.criterionText != "inline row" {
		t.Errorf("criterionText = %q, want %q", sa.criterionText, "inline row")
	}
	if !sa.met {
		t.Errorf("--met=true should set met")
	}
	// Nothing CLI-only here → forward is byte-identical to input.
	if !reflect.DeepEqual(forward, []string{"--criterion=5", "--criterion-text=inline row", "--met=true"}) {
		t.Errorf("forward mangled inline tail: %v", forward)
	}
}

// The echo is the whole point of the 0-based decision: it must TRANSLATE the
// 0-based index a script passes into the 1-based position a builder SEES on the
// board, so a 1-vs-0 slip is caught at the stamp. A mutation that dropped the
// translation (printed the raw index as the human number) or shifted it reds.
func TestStampEchoLine_TranslatesZeroToOneBased(t *testing.T) {
	cases := []struct {
		idx      int
		met      bool
		miss     bool
		text     string
		wantSubs []string
	}{
		{idx: 0, met: true, text: "first row", wantSubs: []string{"index 0 (0-based)", "criterion #1", "met", `"first row"`}},
		{idx: 6, met: true, text: "[MERGE-GATED — the lead closes this]", wantSubs: []string{"index 6 (0-based)", "criterion #7", "met"}},
		{idx: 2, miss: true, text: "third row", wantSubs: []string{"index 2 (0-based)", "criterion #3", "miss"}},
	}
	for _, c := range cases {
		idx := c.idx
		line := stampEchoLine(stampArgs{criterion: &idx, met: c.met, miss: c.miss, criterionText: c.text})
		for _, sub := range c.wantSubs {
			if !strings.Contains(line, sub) {
				t.Errorf("echo for idx=%d missing %q; got %q", c.idx, sub, line)
			}
		}
	}
}

// No index → no echo (the manifest dispatch then produces the normal usage error).
func TestStampEchoLine_NoCriterionEmpty(t *testing.T) {
	if got := stampEchoLine(stampArgs{met: true, criterionText: "x"}); got != "" {
		t.Errorf("echo with no criterion = %q, want empty", got)
	}
}

// The MERGE-GATED tripwire: a --met on a lead-owned row without --merge-gated
// is blocked; the override releases it; a --miss never blocks; a plain row is
// untouched. Tolerant of case and of a hyphen or space between the words.
func TestStampMergeGateBlocked(t *testing.T) {
	cases := []struct {
		name string
		sa   stampArgs
		want bool
	}{
		{"met+marker+no override → blocked", stampArgs{met: true, criterionText: "row [MERGE-GATED — the lead closes this]"}, true},
		{"met+marker+override → allowed", stampArgs{met: true, mergeGated: true, criterionText: "row [MERGE-GATED]"}, false},
		{"miss+marker → never blocked", stampArgs{miss: true, criterionText: "row MERGE-GATED"}, false},
		{"met+plain row → allowed", stampArgs{met: true, criterionText: "a normal acceptance criterion"}, false},
		{"lowercase marker still blocks", stampArgs{met: true, criterionText: "row merge-gated by the lead"}, true},
		{"space variant still blocks", stampArgs{met: true, criterionText: "this is MERGE GATED"}, true},
	}
	for _, c := range cases {
		if got := stampMergeGateBlocked(c.sa); got != c.want {
			t.Errorf("%s: blocked = %v, want %v", c.name, got, c.want)
		}
	}
}

// --- Execute-level wiring proofs ---------------------------------------------

// minimalStampManifest is a self-contained manifest carrying ONLY the
// `task stamp` verb (with the D56 --criterion-text flag the shared fixture
// still lacks), so the Execute path can be driven against a fake server without
// depending on the repo-wide fixture.
const minimalStampManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.stamp", "noun": "task", "verb": "stamp", "summary": "stamp",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/stamp"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"},
        {"name": "observed_epoch", "required": true, "type": "int", "summary": "e"}
      ],
      "flags": [
        {"name": "criterion", "type": "int", "summary": "idx"},
        {"name": "criterion-text", "type": "string", "summary": "text"},
        {"name": "met", "type": "bool", "summary": "m"},
        {"name": "evidence", "type": "string", "summary": "ev"},
        {"name": "miss", "type": "bool", "summary": "x"},
        {"name": "note", "type": "string", "summary": "n"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// stampStoreMode decides what the fake Barkpark's STORE does with a stamp it
// answers 200 to. The three modes are the three worlds the read-back has to
// tell apart, and only the first one is a landed write.
type stampStoreMode int

const (
	// stampStoreHonest applies the write, so a second read finds it.
	stampStoreHonest stampStoreMode = iota
	// stampStoreDrops answers 200 with a normal envelope and writes NOTHING —
	// the exact silent non-landing this wave exists to make impossible to
	// report as success.
	stampStoreDrops
	// stampStoreUnreadable answers the POST 200 but fails the read-back, so the
	// verb must report UNCONFIRMED rather than either verdict.
	stampStoreUnreadable
)

// stampTestServer wires a fake Barkpark that counts POSTs to the stamp route,
// SERVES the task back on GET /v1/tasks/:id (the read-back the verb now
// performs), points the CLI at it via a temp manifest file, and returns the hit
// counter. The honest mode records the stamp's query params into its criteria
// store, so the second read finds exactly what was written.
func stampTestServer(t *testing.T) *int32 {
	t.Helper()
	return stampTestServerMode(t, stampStoreHonest)
}

func stampTestServerMode(t *testing.T, mode stampStoreMode) *int32 {
	t.Helper()
	var hits int32
	var mu sync.Mutex
	// The store: index -> the row the server holds. Only what a stamp actually
	// wrote is in here, which is the whole point.
	store := map[int]map[string]any{}

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp"):
			atomic.AddInt32(&hits, 1)
			if mode == stampStoreHonest {
				q := r.URL.Query()
				idx, err := strconv.Atoi(q.Get("criterion"))
				if err == nil {
					mu.Lock()
					row := map[string]any{
						"criterion": q.Get("criterion-text"),
						"met":       q.Get("met") == "true",
						"evidence":  q.Get("evidence"),
					}
					if q.Get("miss") == "true" {
						row["met"] = false
						row["evidence"] = ""
						row["attempts"] = []any{map[string]any{"note": q.Get("note"), "worker": "w"}}
					}
					store[idx] = row
					mu.Unlock()
				}
			}
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			if mode == stampStoreUnreadable {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"store_unreachable"}`))
				return
			}
			mu.Lock()
			// A criteria list long enough to hold every index the tests stamp;
			// an untouched slot is an unmet, empty row — exactly what the store
			// holds when a write is dropped.
			rows := make([]map[string]any, 8)
			for i := range rows {
				if row, ok := store[i]; ok {
					rows[i] = row
					continue
				}
				rows[i] = map[string]any{"criterion": "", "met": false, "evidence": ""}
			}
			mu.Unlock()
			body, _ := json.Marshal(map[string]any{
				"ok":  true,
				"doc": map[string]any{"content": map[string]any{"acceptance_criteria": rows}},
			})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-stub")
	return &hits
}

// The tripwire must fire in the REAL dispatch, refusing BEFORE any POST — a
// mutation that forgot to call the guard from Execute would let the stamp reach
// the server (hits == 1, exit 0), reddening this test.
func TestTaskStampExecute_MergeGatedRefusedBeforeSend(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
	})
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d); out:\n%s", code, exitValidation, out)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("stamp POST fired %d times; the guard must refuse BEFORE sending", n)
	}
	if !strings.Contains(out, "MERGE-GATED") || !strings.Contains(strings.ToLower(out), "refus") {
		t.Errorf("refusal message missing; got:\n%s", out)
	}
}

// --merge-gated releases the tripwire AND must be stripped before dispatch: if
// it leaked to splitArgs the manifest would reject it as an unknown flag (no
// POST, usage exit), so a reaching POST proves both the override and the strip.
func TestTaskStampExecute_OverrideReleasesAndStripsFlag(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1 (override sends; --merge-gated stripped)", n)
	}
	if !strings.Contains(out, "criterion #7") {
		t.Errorf("echo should still translate index 6 → criterion #7; got:\n%s", out)
	}
}

// A plain stamp reaches the server AND emits the translating echo — the
// end-to-end proof that a builder who stamps the criterion they SEE (#3, index
// 2) gets a one-line confirmation naming that exact board position.
func TestTaskStampExecute_EchoTranslatesOnNormalStamp(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "e",
		"--criterion-text", "a normal row",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1", n)
	}
	if !strings.Contains(out, "index 2 (0-based)") || !strings.Contains(out, "criterion #3") {
		t.Errorf("echo did not translate 0-based 2 → board #3; got:\n%s", out)
	}
}

// --- the READ-BACK: `bp task stamp` reports what the STORE says (PDS-D359/D361) ---

// stampVerdictReq is the ONE package-level request fixture the registry's
// renderStampVerdict rows share. It is deliberately never a Backed/Contradicted
// value: the pair must vary on the STORED row, or the gate would be probing an
// echo of ourselves. The ledger-row property (TestLedgerRowsAreProbedWithTheStore)
// mutates this var and requires BOTH halves to move, which is what proves the two
// halves route through the same request rather than two baked-in literals.
var stampVerdictReq = stampRequest{
	docID:    "task-abc",
	index:    2,
	text:     "the gate is green",
	met:      true,
	evidence: "go test ./internal/cli/... ok",
}

// stampStoredBacked is the row a store holds when the stamp LANDED.
func stampStoredBacked() taskboard.CriterionItem {
	return taskboard.CriterionItem{
		Criterion: stampVerdictReq.text,
		Met:       true,
		Evidence:  stampVerdictReq.evidence,
	}
}

// stampStoredContradicted is the row the wish actually observed on a dropped
// write: a 200, a normal envelope, and met:false / evidence:"" in the store.
func stampStoredContradicted() taskboard.CriterionItem {
	return taskboard.CriterionItem{Criterion: stampVerdictReq.text}
}

// The verdict must be read off the STORE. A row that disagrees exits non-zero
// and the message has to name the index, the expected criterion text, and what
// the store actually held — a builder who reads only the last line still learns
// which row failed and why.
func TestRenderStampVerdict_ContradictionNamesIndexExpectedAndFound(t *testing.T) {
	out, buf := stampVerdictWriter()
	code := renderStampVerdict(out, stampVerdictReq, stampStoredContradicted())
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — an unlanded stamp must not report success", code, exitConflict)
	}
	got := buf()
	for _, want := range []string{
		"index 2 (0-based)",               // the index
		"criterion #3",                    // the board position
		`"the gate is green"`,             // the expected criterion text
		"met=false",                       // what the store held
		"evidence <empty>",                // …including the missing evidence
		"met is still FALSE in the store", // the named failure
	} {
		if !strings.Contains(got, want) {
			t.Errorf("verdict missing %q; got:\n%s", want, got)
		}
	}
}

// The confirmed verdict must print the STORED row, not the request — and it
// must exit zero.
func TestRenderStampVerdict_ConfirmedReportsTheStoredRow(t *testing.T) {
	out, buf := stampVerdictWriter()
	code := renderStampVerdict(out, stampVerdictReq, stampStoredBacked())
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK on a landed stamp; out:\n%s", code, buf())
	}
	got := buf()
	if !strings.Contains(got, "met=true") || !strings.Contains(got, "the store holds it") {
		t.Errorf("confirmed verdict should report the stored row; got:\n%s", got)
	}
}

// stampMismatches is the pure comparison the verdict rests on. Each case is a
// real way a write fails to be the write that was asked for.
func TestStampMismatches_EveryUnlandedShape(t *testing.T) {
	base := stampVerdictReq
	cases := []struct {
		name   string
		req    stampRequest
		stored taskboard.CriterionItem
		want   bool
	}{
		{"landed", base, stampStoredBacked(), false},
		{"dropped write", base, stampStoredContradicted(), true},
		{"met flipped but evidence empty", base,
			taskboard.CriterionItem{Criterion: base.text, Met: true}, true},
		{"evidence truncated in transit", base,
			taskboard.CriterionItem{Criterion: base.text, Met: true, Evidence: "go test ./inte"}, true},
		{"wrong row entirely", base,
			taskboard.CriterionItem{Criterion: "a different criterion", Met: true, Evidence: base.evidence}, true},
		{"miss landed", stampRequest{index: 1, miss: true, note: "blocked on deploy"},
			taskboard.CriterionItem{Attempts: []taskboard.CriterionAttempt{{Note: "blocked on deploy"}}}, false},
		{"miss dropped", stampRequest{index: 1, miss: true, note: "blocked on deploy"},
			taskboard.CriterionItem{}, true},
	}
	for _, c := range cases {
		got := stampMismatches(c.req, c.stored)
		if (len(got) > 0) != c.want {
			t.Errorf("%s: mismatches = %v, want any = %v", c.name, got, c.want)
		}
	}
}

// stampVerdictWriter is a table-mode writer plus a reader for everything it
// printed (stdout AND stderr — the contradiction narrates on stderr).
func stampVerdictWriter() (*writer, func() string) {
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "table"
	out.color = false
	return out, func() string { return stdout.String() + stderr.String() }
}

// --- Execute-level: the store is the authority, end to end -------------------

// THE SPINE, proven through the real dispatch: a server that answers the stamp
// 200 with a normal envelope and writes NOTHING must NOT produce exit 0. The
// read-back sees met:false / evidence:"" and the verb exits exitConflict naming
// the row. Delete the read-back and this test goes green-with-exit-0 → red.
func TestTaskStampExecute_DroppedWriteIsNotSuccess(t *testing.T) {
	hits := stampTestServerMode(t, stampStoreDrops)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1", n)
	}
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d) — a stamp the store never took is not a success; out:\n%s",
			code, exitConflict, out)
	}
	for _, want := range []string{"NOT confirmed", "index 2 (0-based)", `"a normal row"`, "met=false"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q; got:\n%s", want, out)
		}
	}
}

// The honest counterpart: a store that TOOK the write confirms it, exit 0, and
// the receipt says the store holds it.
func TestTaskStampExecute_LandedWriteIsConfirmedByTheStore(t *testing.T) {
	stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if !strings.Contains(out, "the store holds it") || !strings.Contains(out, "met=true") {
		t.Errorf("receipt should report the STORED row; got:\n%s", out)
	}
}

// A read-back that cannot reach the store is UNCONFIRMED, never a success:
// "we could not ask" is not "it landed".
func TestTaskStampExecute_UnreadableStoreIsUnconfirmedNotSuccess(t *testing.T) {
	stampTestServerMode(t, stampStoreUnreadable)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if code == exitOK {
		t.Fatalf("exit = 0 on an unverifiable stamp — the verb reported success on an exit code alone; out:\n%s", out)
	}
	if !strings.Contains(out, "NOT confirmed") {
		t.Errorf("output should say the stamp is unconfirmed; got:\n%s", out)
	}
}

// A --miss records an attempt, and the read-back confirms THAT — the honest
// trail is a write too, and a dropped one must not report success either.
func TestTaskStampExecute_MissIsConfirmedByItsAttempt(t *testing.T) {
	stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "3", "--miss", "--note", "blocked on the guerrilla deploy",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK for a landed miss; out:\n%s", code, out)
	}
	if !strings.Contains(out, "attempts=1") {
		t.Errorf("receipt should report the stored attempt trail; got:\n%s", out)
	}
}

// stampRequestOf must resolve the doc id and flags through the SAME splitArgs +
// bindArgs the dispatch uses, so the read-back can never target a different row
// than the POST wrote.
func TestStampRequestOf_ResolvesTheSameTargetAsTheDispatch(t *testing.T) {
	cmd := stampCommandFixture(t)
	req, ok := stampRequestOf(cmd, []string{
		"bp-task-x", "w", "1",
		"--criterion", "4", "--met", "--evidence", "e", "--criterion-text", "row four",
	})
	if !ok {
		t.Fatal("stampRequestOf refused a well-formed stamp tail")
	}
	if req.docID != "bp-task-x" || req.index != 4 || !req.met || req.text != "row four" || req.evidence != "e" {
		t.Fatalf("resolved request = %+v, want doc bp-task-x / index 4 / met / row four / e", req)
	}
	if _, ok := stampRequestOf(cmd, []string{"bp-task-x", "w", "1", "--met"}); ok {
		t.Error("a tail with no --criterion has no specific row to re-read; stampRequestOf must refuse it")
	}
}

// stampCommandFixture parses the minimal manifest and returns its task.stamp
// command — the same declaration the dispatch binds against.
func stampCommandFixture(t *testing.T) manifest.Command {
	t.Helper()
	m, err := manifest.Parse([]byte(minimalStampManifest))
	if err != nil {
		t.Fatalf("parse minimal stamp manifest: %v", err)
	}
	for _, c := range m.Commands {
		if c.Noun == "task" && c.Verb == "stamp" {
			return c
		}
	}
	t.Fatal("minimal manifest declares no task stamp command")
	return manifest.Command{}
}
