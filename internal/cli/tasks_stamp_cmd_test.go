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

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// --- pure-function mutation-proofs -------------------------------------------

// parseStampArgs must NEVER re-index --criterion (the index a builder types is
// the index the server receives), and must route --merge-gated by whether the
// SERVER declares it: forwarded when it does (the server owns the refusal and
// needs to see the override), stripped when it does not (an undeclared token
// fails splitArgs as "unknown flag"). Every OTHER token passes in order. A
// mutation that shifted the index, or that got the routing backwards, reds here.
func TestParseStampArgs_MergeGatedRoutedByDeclaration(t *testing.T) {
	tail := []string{
		"bp-task-x", "worker-1", "2",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "some row", "--merge-gated",
	}
	base := []string{
		"bp-task-x", "worker-1", "2",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "some row",
	}

	for _, c := range []struct {
		name     string
		declared bool
		want     []string
	}{
		{"server declares it → forwarded", true, append(append([]string{}, base...), "--merge-gated")},
		{"legacy server → stripped", false, base},
	} {
		sa, forward := parseStampArgs(tail, c.declared)

		if sa.criterion == nil || *sa.criterion != 3 {
			t.Fatalf("%s: criterion = %v, want 3 (no re-index)", c.name, sa.criterion)
		}
		if !sa.met || sa.miss {
			t.Errorf("%s: met/miss = %v/%v, want met", c.name, sa.met, sa.miss)
		}
		if sa.criterionText != "some row" {
			t.Errorf("%s: criterionText = %q, want %q", c.name, sa.criterionText, "some row")
		}
		if !sa.mergeGated {
			t.Errorf("%s: mergeGated not parsed", c.name)
		}
		if !reflect.DeepEqual(forward, c.want) {
			t.Errorf("%s: forward = %v\n want %v", c.name, forward, c.want)
		}
	}
}

// commandDeclaresFlag is the capability probe the routing above turns on.
func TestCommandDeclaresFlag(t *testing.T) {
	cmd := manifest.Command{Flags: []manifest.Flag{{Name: "met"}, {Name: "merge-gated"}}}
	if !commandDeclaresFlag(cmd, "merge-gated") {
		t.Error("declared flag reported missing")
	}
	if commandDeclaresFlag(cmd, "nope") {
		t.Error("undeclared flag reported present")
	}
	if commandDeclaresFlag(manifest.Command{}, "merge-gated") {
		t.Error("empty command must declare nothing")
	}
}

// The `--flag=value` inline spelling must parse identically to the space form.
func TestParseStampArgs_InlineForms(t *testing.T) {
	sa, forward := parseStampArgs([]string{"--criterion=5", "--criterion-text=inline row", "--met=true"}, true)
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

// The LEGACY client-side tripwire (reached only against a server that does not
// declare --merge-gated): a --met on a lead-owned row without the override is
// blocked; the override releases it; a --miss never blocks; a plain row is
// untouched. Frozen on purpose — it must keep matching what old servers
// assumed. The live predicate is Barkpark.Tasks.Criteria.merge_gated?/1.
func TestStampMergeGateFallback(t *testing.T) {
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
		if got := stampMergeGateFallback(c.sa); got != c.want {
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
        {"name": "note", "type": "string", "summary": "n"},
        {"name": "merge-gated", "type": "bool", "summary": "lead only"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// legacyStampManifest is minimalStampManifest WITHOUT the --merge-gated flag —
// a server that predates the server-side merge-gate guard. Against it the CLI
// must fall back to its historical client-side tripwire and strip the flag,
// because forwarding an undeclared token fails splitArgs as "unknown flag".
var legacyStampManifest = strings.Replace(
	minimalStampManifest,
	`,
        {"name": "merge-gated", "type": "bool", "summary": "lead only"}`,
	"",
	1,
)

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
	// stampStore500Landed answers the POST with a 500 (exitServer) but — the
	// doctrine this mode exists to prove — the write STILL COMMITS, so the
	// read-back must find it and report the truth over the transport error.
	stampStore500Landed
	// stampStore500Absent answers the POST with a 500 AND writes nothing: the
	// ordinary "the server genuinely failed" case, which must still read exitServer
	// after the read-back confirms the row is empty.
	stampStore500Absent
	// stampStore500Unreadable answers the POST with a 500 AND fails the
	// read-back too: neither call can confirm anything, so the more specific
	// exitServer the POST already reported must survive rather than downgrading
	// to the generic unconfirmed bucket.
	stampStore500Unreadable
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

// stampTestServerLegacy is stampTestServer against a manifest that does NOT
// declare --merge-gated — the pre-guard server the CLI must still protect.
func stampTestServerLegacy(t *testing.T) *int32 {
	t.Helper()
	return stampTestServerWith(t, stampStoreHonest, legacyStampManifest, nil)
}

func stampTestServerMode(t *testing.T, mode stampStoreMode) *int32 {
	t.Helper()
	return stampTestServerWith(t, mode, minimalStampManifest, nil)
}

// stampTestServerQuery is stampTestServer that also records the raw query
// string of the stamp POST, so a test can assert WHICH flags reached the wire.
func stampTestServerQuery(t *testing.T, sink *string) *int32 {
	t.Helper()
	return stampTestServerWith(t, stampStoreHonest, minimalStampManifest, sink)
}

func stampTestServerWith(t *testing.T, mode stampStoreMode, manifestJSON string, querySink *string) *int32 {
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
			if querySink != nil {
				mu.Lock()
				*querySink = r.URL.RawQuery
				mu.Unlock()
			}
			if mode == stampStoreHonest || mode == stampStore500Landed {
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
			if mode == stampStore500Landed || mode == stampStore500Absent || mode == stampStore500Unreadable {
				// The write (if this mode commits one) already happened above —
				// exactly the "a 500 can hide a write that landed" doctrine: the
				// transaction commits, then the RESPONSE fails.
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":{"code":"internal_error","message":"boom"}}`))
				return
			}
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			if mode == stampStoreUnreadable || mode == stampStore500Unreadable {
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
	if err := os.WriteFile(mf, []byte(manifestJSON), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-stub")
	return &hits
}

// LEGACY SERVER (no --merge-gated in the manifest): the client-side tripwire
// must still fire in the REAL dispatch, refusing BEFORE any POST — a mutation
// that forgot to call the fallback from Execute would let the stamp reach the
// server (hits == 1, exit 0), reddening this test. This is the arm that keeps
// the rollout from ever leaving the gate unguarded.
func TestTaskStampExecute_LegacyServerRefusesBeforeSend(t *testing.T) {
	hits := stampTestServerLegacy(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
	})
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d); out:\n%s", code, exitValidation, out)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("stamp POST fired %d times; the fallback must refuse BEFORE sending", n)
	}
	if !strings.Contains(out, "MERGE-GATED") || !strings.Contains(strings.ToLower(out), "refus") {
		t.Errorf("refusal message missing; got:\n%s", out)
	}
}

// LEGACY SERVER: --merge-gated releases the fallback AND must be stripped
// before dispatch — if it leaked to splitArgs the old manifest would reject it
// as an unknown flag (no POST, usage exit), so a reaching POST proves both.
func TestTaskStampExecute_LegacyServerOverrideReleasesAndStrips(t *testing.T) {
	hits := stampTestServerLegacy(t)
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

// MODERN SERVER: the CLI must NOT adjudicate the gate itself. The marker in
// --criterion-text is no longer grounds for a client-side refusal, because the
// text is only what the CALLER typed while the verdict depends on the STORED
// criterion's merge_gate field — so the stamp must REACH the server, which
// refuses (or allows) on the authoritative row. A mutation that kept the old
// unconditional client-side tripwire reds here with hits == 0.
func TestTaskStampExecute_ModernServerDefersVerdictToServer(t *testing.T) {
	hits := stampTestServer(t)
	_, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
	})
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1 — the server owns the merge-gate verdict (exit %d)", n, code)
	}
}

// MODERN SERVER: --merge-gated must ride the POST, not be swallowed. The server
// cannot honour an override it never receives, so a mutation that kept
// stripping the flag would silently turn every lead close into a refusal —
// caught here by its absence from the query the fake server saw.
func TestTaskStampExecute_ModernServerForwardsOverride(t *testing.T) {
	var gotQuery string
	hits := stampTestServerQuery(t, &gotQuery)
	_, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK", code)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1", n)
	}
	if !strings.Contains(gotQuery, "merge-gated=true") {
		t.Errorf("--merge-gated did not reach the server; query was %q", gotQuery)
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

// stampReadbackPublished is the row IDENTITY every pre-existing verdict case
// assumes: the read-back landed on the published board row. It is held fixed so
// those cases keep probing what the store HOLDS; the draft case below varies
// this half instead.
func stampReadbackPublished() apiclient.TaskReadback {
	return apiclient.TaskReadback{DocID: stampVerdictReq.docID, Status: "published"}
}

// The verdict must be read off the STORE. A row that disagrees exits non-zero
// and the message has to name the index, the expected criterion text, and what
// the store actually held — a builder who reads only the last line still learns
// which row failed and why.
func TestRenderStampVerdict_ContradictionNamesIndexExpectedAndFound(t *testing.T) {
	out, buf := stampVerdictWriter()
	code := renderStampVerdict(out, stampVerdictReq, stampStoredContradicted(), stampReadbackPublished(), exitOK)
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
	code := renderStampVerdict(out, stampVerdictReq, stampStoredBacked(), stampReadbackPublished(), exitOK)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK on a landed stamp; out:\n%s", code, buf())
	}
	got := buf()
	if !strings.Contains(got, "met=true") || !strings.Contains(got, "the store holds it") {
		t.Errorf("confirmed verdict should report the stored row; got:\n%s", got)
	}
}

// A landed row overrides a 5xx from the POST: the read-back is the truth, not
// the transport error. This is the "a 500 can hide a write that landed"
// doctrine — a mutation that kept exitServer here (ignored origRC on the
// landed branch) would report a real write as a failure.
func TestRenderStampVerdict_LandedOverridesA5xx(t *testing.T) {
	out, buf := stampVerdictWriter()
	code := renderStampVerdict(out, stampVerdictReq, stampStoredBacked(), stampReadbackPublished(), exitServer)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — a confirmed-landed row is a success regardless of what the POST answered; out:\n%s", code, buf())
	}
	got := buf()
	if !strings.Contains(got, "despite the POST answering a server error") {
		t.Errorf("landed-despite-5xx verdict should explain the surprising resurrection; got:\n%s", got)
	}
	if !strings.Contains(got, "the store holds it") || !strings.Contains(got, "met=true") {
		t.Errorf("verdict should still report the stored row; got:\n%s", got)
	}
}

// A confirmed-absent row after a 5xx still exits exitConflict (the store, not
// the transport, decides "landed" — see the read-back's own doctrine), and
// carries no false "despite a 5xx" claim since nothing landed.
func TestRenderStampVerdict_ConfirmedAbsentAfter5xxStillConflict(t *testing.T) {
	out, buf := stampVerdictWriter()
	code := renderStampVerdict(out, stampVerdictReq, stampStoredContradicted(), stampReadbackPublished(), exitServer)
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, buf())
	}
	if strings.Contains(buf(), "despite the POST answering a server error") {
		t.Errorf("a genuinely-absent row must not claim it landed despite the 5xx; got:\n%s", buf())
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

// THE 5xx DOCTRINE, proven through the real dispatch: a server that answers
// the stamp POST with a 500 but ALREADY COMMITTED the write must not report
// failure — the read-back finds it and the verb exits 0. Delete the
// rc==exitServer arm in runTaskStamp and this goes red (rc stops at 8, no
// read-back ever fires, "the store holds it" never appears).
func TestTaskStampExecute_ServerErrorThatLandedIsConfirmedSuccess(t *testing.T) {
	stampTestServerMode(t, stampStore500Landed)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the read-back confirmed the write landed despite the 5xx; out:\n%s", code, out)
	}
	if !strings.Contains(out, "the store holds it") || !strings.Contains(out, "despite the POST answering a server error") {
		t.Errorf("receipt should name both the landed row AND the surprising 5xx it survived; got:\n%s", out)
	}
}

// The honest counterpart: a 500 whose write genuinely never landed must still
// report failure — and now as a STORE-CONFIRMED absence (exitConflict), not a
// bare unconfirmed transport error.
func TestTaskStampExecute_ServerErrorThatDidNotLandStaysAFailure(t *testing.T) {
	stampTestServerMode(t, stampStore500Absent)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if code == exitOK {
		t.Fatalf("exit = 0 on a stamp the store confirms never landed; out:\n%s", out)
	}
	if !strings.Contains(out, "NOT confirmed") {
		t.Errorf("output should say the stamp was not confirmed by the store; got:\n%s", out)
	}
}

// A 5xx WHOSE read-back also fails must keep the more specific exitServer
// code, not collapse to the generic exitGeneric bucket the plain-2xx path
// uses — the POST already named a real server failure, and the failed
// read-back adds no new information to override that.
func TestTaskStampExecute_ServerErrorAndUnreadableStoreKeepsExitServer(t *testing.T) {
	stampTestServerMode(t, stampStore500Unreadable)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if code != exitServer {
		t.Fatalf("exit = %d, want exitServer (%d) preserved from the POST; out:\n%s", code, exitServer, out)
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

// --- the read-back must NAME the row it read (pds-w43) ---
//
// GET /v1/tasks/:doc_id falls back to the `drafts.` twin when no published row
// exists (tasks_controller.ex find_task_by_doc_id), and `bp task create --yes`
// produces exactly such a draft-only row at rc=0. The read-back therefore found
// the criterion it had just written, on the draft, and printed the green
// verdict — while `bp doc get task <id>` answered not_found and no board ever
// showed the row. The value landed somewhere nobody reads.
//
// These cases vary the row IDENTITY while holding the STORED row fixed at the
// one that would otherwise earn a green, so nothing but the identity can be
// producing the refusal.

// TestRenderStampVerdict_DraftRowRefusesTheGreen is the row's core assertion: a
// perfect stamp on a draft twin must exit non-zero and say so.
func TestRenderStampVerdict_DraftRowRefusesTheGreen(t *testing.T) {
	cases := []struct {
		name     string
		readback apiclient.TaskReadback
		wantIn   string
	}{
		{
			name:     "drafts. doc_id",
			readback: apiclient.TaskReadback{DocID: "drafts." + stampVerdictReq.docID, Status: "published"},
			wantIn:   "drafts." + stampVerdictReq.docID,
		},
		{
			name:     "status is not published",
			readback: apiclient.TaskReadback{DocID: stampVerdictReq.docID, Status: "draft"},
			wantIn:   `status "draft"`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, buf := stampVerdictWriter()

			// stampStoredBacked() is the row that earns a green when the identity
			// is a published one — see TestRenderStampVerdict above. Only the
			// identity differs here.
			code := renderStampVerdict(out, stampVerdictReq, stampStoredBacked(), tc.readback, exitOK)

			if code == exitOK {
				t.Fatalf("a stamp confirmed only on a DRAFT exited 0 — the board will never show it; output:\n%s", buf())
			}
			got := buf()
			if !strings.Contains(got, tc.wantIn) {
				t.Errorf("the receipt does not name the row it read (want %q); got:\n%s", tc.wantIn, got)
			}
			if !strings.Contains(got, "DRAFT") {
				t.Errorf("the receipt does not say the row is a draft; got:\n%s", got)
			}
		})
	}
}

// TestRenderStampVerdict_PublishedRowStillGreens is the negative arm. Widening
// the refusal until it swallows the ordinary success would trade a false green
// for a false red, so the published identity must stay a clean exit 0.
func TestRenderStampVerdict_PublishedRowStillGreens(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderStampVerdict(out, stampVerdictReq, stampStoredBacked(), stampReadbackPublished(), exitOK)

	if code != exitOK {
		t.Fatalf("a landed stamp on the PUBLISHED row exited %d, want 0; output:\n%s", code, buf())
	}
}

// TestRenderStampVerdict_UnnamedRowIsNotCalledADraft pins the honesty limit: a
// server that sends neither doc_id nor status has told us nothing about which
// row answered, and "nothing" is not evidence of a draft. Asserting a draft
// here would be the same overclaim in the other direction.
func TestRenderStampVerdict_UnnamedRowIsNotCalledADraft(t *testing.T) {
	out, buf := stampVerdictWriter()

	code := renderStampVerdict(out, stampVerdictReq, stampStoredBacked(), apiclient.TaskReadback{}, exitOK)

	if code != exitOK {
		t.Fatalf("an unnamed row was treated as a draft (exit %d) — an absent field is unknown, not a verdict; output:\n%s", code, buf())
	}
}

// ─── THE WITHDRAWAL (D745, wave 62) ────────────────────────────────────────
//
// `--withdraw` is the verb that LOWERS a met flag when review refutes the
// proof. Its read-back verdict cannot be the same as `--met`'s: a withdrawal
// "lands" only when the store shows met FALSE and carries the signed record.
// A withdrawal whose lock stayed up is precisely the defect the verb exists to
// end — twelve criteria on the live ledger read MET today with the correction
// visible only as prose inside their own evidence.

func TestParseStampArgsReadsWithdraw(t *testing.T) {
	sa, forward := parseStampArgs([]string{
		"t1", "w", "3", "--criterion", "0",
		"--criterion-text", "gate passes", "--withdraw", "--note", "review refuted it",
	}, true)
	if !sa.withdraw {
		t.Fatalf("--withdraw not parsed: %+v", sa)
	}
	if sa.met || sa.miss {
		t.Fatalf("--withdraw must not read as met/miss: %+v", sa)
	}
	// Every token is forwarded, order preserved — the wrapper never re-indexes.
	if len(forward) != 10 {
		t.Fatalf("forward should carry every token, got %d: %v", len(forward), forward)
	}
}

func TestStampEchoLineNamesTheLowering(t *testing.T) {
	idx := 2
	line := stampEchoLine(stampArgs{criterion: &idx, withdraw: true, criterionText: "gate passes"})
	if !strings.Contains(line, "WITHDRAW") {
		t.Fatalf("the echo must say the lock is going DOWN before the write: %q", line)
	}
	if !strings.Contains(line, "criterion #3") {
		t.Fatalf("the 0→1 based translation must survive on the withdraw path: %q", line)
	}
}

// The merge-gate legacy tripwire must NOT fire on a withdrawal: lowering a
// gate's lock cannot fabricate a done before the PR exists, which is the only
// harm that tripwire guards. If this ever reds, a reviewer has been blocked
// from correcting a merge gate on an old server.
func TestStampMergeGateFallbackIgnoresWithdrawals(t *testing.T) {
	sa := stampArgs{withdraw: true, criterionText: "[MERGE-GATED — the lead closes this] PR merged"}
	if stampMergeGateFallback(sa) {
		t.Fatal("a withdrawal must never be refused by the merge-gate tripwire")
	}
}

func TestStampMismatchesWithdrawVerdict(t *testing.T) {
	req := stampRequest{index: 0, withdraw: true, note: "review: the gate ran on the wrong branch"}

	landed := taskboard.CriterionItem{
		Criterion: "gate passes",
		Met:       false,
		// The original proof is STILL THERE — that is the append-only guarantee,
		// and the read-back must not treat its presence as a failure.
		Evidence: "42 tests green",
		Withdrawals: []taskboard.CriterionWithdrawal{{
			Note:               "review: the gate ran on the wrong branch",
			Worker:             "reviewer",
			SupersededEvidence: "42 tests green",
		}},
	}
	if got := stampMismatches(req, landed); len(got) != 0 {
		t.Fatalf("a landed withdrawal must be clean, got %v", got)
	}

	// THE CASE THAT MATTERS: the reason was recorded but the lock stayed UP.
	// That is the live defect — a board reading MET with the correction buried.
	lockStillUp := landed
	lockStillUp.Met = true
	got := stampMismatches(req, lockStillUp)
	if len(got) == 0 {
		t.Fatal("a withdrawal that left met TRUE must NOT be reported as landed")
	}
	if !strings.Contains(strings.Join(got, " "), "still TRUE") {
		t.Fatalf("the verdict must name the un-lowered lock, got %v", got)
	}

	// Lowered, but unsigned: no record says who withdrew it or why.
	unsigned := taskboard.CriterionItem{Criterion: "gate passes", Met: false, Evidence: "42 tests green"}
	if got := stampMismatches(req, unsigned); len(got) == 0 {
		t.Fatal("a withdrawal with no recorded reason must not read as landed")
	}
}

func TestStoredCriterionSummaryFlagsAWithdrawnRow(t *testing.T) {
	s := storedCriterionSummary(taskboard.CriterionItem{
		Criterion:   "gate passes",
		Met:         false,
		Evidence:    "42 tests green",
		Withdrawals: []taskboard.CriterionWithdrawal{{Note: "refuted"}},
	})
	// The evidence on a withdrawn row is the SUPERSEDED proof. A receipt that
	// printed it without saying so would read as a current claim.
	if !strings.Contains(s, "WITHDRAWN") || !strings.Contains(s, "superseded") {
		t.Fatalf("the receipt must mark a withdrawn row and re-frame its evidence: %q", s)
	}
}
