package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// ─── THE LABEL/CRITERIA DISAGREEMENT (task-4dca6c8453fb1f7c) ─────────────────
//
// THE MEASURED SHAPE. `bp task landed` writes `landed:pr-NNNNN@sha` onto a row
// and leaves `acceptance_criteria` untouched, so the ledger asserts two
// contradictory things at once. Measured against guerrilla 2026-09-05: 21 of
// 1,658 `bp task ready` rows carried a `landed:pr-*` label and NINE were at ZERO
// criteria met.
//
// WHAT THE FILING GOT WRONG, and why these tests sit on the CLIENT. The filing's
// clause "nothing reconciles the two" reads as if the server had no reconciler.
// It has one: `Barkpark.Tasks.Landed.criterion_update/5` flips ONE criterion
// behind four guards (index out of range, already met, not merge-shaped,
// demands a demonstration) plus the `files_overlap` check. All of it is opt-in
// behind a `criterion` index that the Go client never computed and never sent.
// The door was built; no caller knocked. So the fix is a RESOLUTION, not a new
// permit — and every test below asserts the resolution and never the permit.
//
// THE ARITY RULE IS THE SAFETY ARGUMENT: exactly one candidate is sent, zero
// lands without and says so, more than one sends NONE and names them. A client
// that picked the first would be adjudicating, which is the mistake
// tasks_landed_cmd_test.go records as measured-refuted.

// landedCrit is one acceptance_criteria entry the fake row serves. mergeGate and
// mergeDischarges are TRI-STATE on purpose — absent is the state that selects
// the prose arm, and collapsing it to a bool would erase the case the resolution
// turns on.
type landedCrit struct {
	text            string
	met             bool
	mergeGate       *bool
	mergeDischarges *bool
}

// landedCriterionCapture records every landing POST, in order, so a test can
// assert BOTH what was attempted and what was recorded after a refusal.
type landedCriterionCapture struct {
	mu      sync.Mutex
	queries []string
	// declineCode, when non-empty, makes the FIRST POST carrying a criterion
	// fail with that server code — the shape of `criterion_update/5` aborting
	// the whole write, which is why the landing must be re-sent without it.
	declineCode string
	declined    bool
	reads       int
}

func (c *landedCriterionCapture) posts() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.queries...)
}

func landedCriterionServer(t *testing.T, crits []landedCrit) *landedCriterionCapture {
	t.Helper()
	cap := &landedCriterionCapture{}

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/landed"):
			cap.mu.Lock()
			cap.queries = append(cap.queries, r.URL.RawQuery)
			decline := cap.declineCode != "" && !cap.declined && strings.Contains(r.URL.RawQuery, "criterion=")
			if decline {
				cap.declined = true
			}
			cap.mu.Unlock()
			if decline {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusConflict)
				_, _ = fmt.Fprintf(w, `{"ok":false,"error":{"code":%q,"message":"refused"}}`, cap.declineCode)
				return
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-x"}}`))

		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/v1/tasks/bp-task-x"):
			cap.mu.Lock()
			cap.reads++
			cap.mu.Unlock()
			items := make([]map[string]any, 0, len(crits))
			for _, c := range crits {
				it := map[string]any{"criterion": c.text, "met": c.met}
				if c.mergeGate != nil {
					it["merge_gate"] = *c.mergeGate
				}
				if c.mergeDischarges != nil {
					it["merge_discharges"] = *c.mergeDischarges
				}
				items = append(items, it)
			}
			body, _ := json.Marshal(map[string]any{
				"ok": true,
				"doc": map[string]any{
					"doc_id":  "bp-task-x",
					"status":  "published",
					"content": map[string]any{"acceptance_criteria": items},
				},
			})
			_, _ = w.Write(body)

		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalLandedManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "landed-stub")
	return cap
}

func landWithNote(t *testing.T, extra ...string) (string, int) {
	t.Helper()
	args := append([]string{
		"task", "landed", "bp-task-x",
		"--commit", "a1b2c3d", "--pr", "15560",
		"--note", "PR #15560 merged to main as a1b2c3d",
	}, extra...)
	return captureExecuteCode(t, args)
}

// THE ONE-CANDIDATE CASE — the defect's cure, and the mutation target. Remove
// the index resolution from landWithResolvedCriterion and this reds on the
// missing `criterion=1`: the landing goes out exactly as it did before, label
// written and every criterion still met:false.
func TestTaskLanded_SendsTheOneMergeShapedCriterionIndex(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "The reconciler is proven by test, red-without and green-with"},
		{text: "PR merged to main and the ledger agrees with the label", mergeGate: boolPtr(true)},
	})

	out, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d); out:\n%s", code, exitOK, out)
	}

	posts := cap.posts()
	if len(posts) != 1 {
		t.Fatalf("landing POSTed %d times, want 1; queries = %v", len(posts), posts)
	}
	if !strings.Contains(posts[0], "criterion=1") {
		t.Fatalf("the landing went out WITHOUT the resolved criterion index (query = %q).\n"+
			"That is the measured defect: the label is written, every criterion stays met:false, and the row reads as untouched work.\nout:\n%s", posts[0], out)
	}
	if !strings.Contains(out, "criterion index 1") {
		t.Errorf("the run never SAID which criterion it flipped; out:\n%s", out)
	}
}

// ZERO CANDIDATES — the landing still lands, and the silence is broken. A run
// that said nothing here would read as "the criteria were considered", which is
// the same collapse the row is about.
func TestTaskLanded_NoMergeShapedCriterionLandsAndSaysSo(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "A decision is recorded before code"},
		{text: "The nine measured rows are triaged one by one"},
	})

	out, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d); out:\n%s", code, exitOK, out)
	}
	posts := cap.posts()
	if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
		t.Fatalf("queries = %v, want exactly one landing with NO criterion — nothing on this row is merge-shaped", posts)
	}
	if !strings.Contains(out, "no UNMET merge-shaped acceptance criterion") {
		t.Errorf("the run flipped nothing and did not say so; out:\n%s", out)
	}
}

// MORE THAN ONE — send NONE and name them. Picking the first would be the client
// adjudicating on the lead's behalf.
func TestTaskLanded_AmbiguousCriteriaSendNoneAndNameThem(t *testing.T) {
	// BOTH candidates carry the FLAG. Before task-b40af0580ec7deb6 index 0 was
	// a candidate on its wording alone; it no longer is, so a fixture that left
	// it unflagged would now present ONE candidate and this test would silently
	// stop exercising the ambiguity arm — a green with no subject.
	cap := landedCriterionServer(t, []landedCrit{
		{text: "MERGE-GATED: the lead closes this on merge", mergeGate: boolPtr(true)},
		{text: "A decision is recorded before code"},
		{text: "PR merged to main", mergeGate: boolPtr(true)},
	})

	out, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d); out:\n%s", code, exitOK, out)
	}
	posts := cap.posts()
	if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
		t.Fatalf("queries = %v, want ONE landing with NO criterion — two candidates is the lead's choice, not the client's", posts)
	}
	for _, want := range []string{"--criterion 0", "--criterion 2"} {
		if !strings.Contains(out, want) {
			t.Errorf("the run did not name the candidate %q for the operator to type; out:\n%s", want, out)
		}
	}
}

// AN EXPLICIT --criterion IS THE CALLER'S. The wrapper never overrides a value a
// human typed — the same rule --commit follows.
func TestTaskLanded_ExplicitCriterionIsPassedThroughUntouched(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "PR merged to main", mergeGate: boolPtr(true)},
		{text: "A decision is recorded before code"},
	})

	out, code := landWithNote(t, "--criterion", "1")
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d); out:\n%s", code, exitOK, out)
	}
	posts := cap.posts()
	if len(posts) != 1 || !strings.Contains(posts[0], "criterion=1") {
		t.Fatalf("queries = %v, want the TYPED criterion=1 — resolution must not overwrite a value the caller chose", posts)
	}
	if cap.reads != 0 {
		t.Errorf("the row was read %d times for a criterion the caller already supplied", cap.reads)
	}
}

// THE MERGE-GATE VETO. An explicit "merge_gate": false outranks wording that
// would otherwise match — the same direction Tasks.Landed.merge_shaped?/1 reads
// it, so a row whose author declared NOT-A-GATE is never resolved into a flip.
func TestTaskLanded_ExplicitMergeGateFalseVetoesTheWording(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "PR merged to main is mentioned here, but this is not a gate", mergeGate: boolPtr(false)},
	})

	_, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
		t.Fatalf("queries = %v — an explicit merge_gate:false must never be resolved into a flip", posts)
	}
}

// THE DEMONSTRATION VETO. Merge-shaped is not merge-DISCHARGED: a criterion whose
// own text demands a demo cannot be sealed by a merge, and the client must not
// send an index the server is certain to refuse.
func TestTaskLanded_DemonstrationWordingIsNotACandidate(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "MERGE-GATED — the lead closes this, and only on the DEMO, with the run shown", mergeGate: boolPtr(true)},
	})

	_, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
		t.Fatalf("queries = %v — a criterion demanding a demonstration is the LEAD's, and the server refuses it (criterion_demands_demonstration)", posts)
	}
}

// AN ALREADY-MET CRITERION IS NOT A CANDIDATE — a landing notice never overwrites
// somebody's proof, and the client must not even ask.
func TestTaskLanded_AlreadyMetCriterionIsNotResolved(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "PR merged to main", mergeGate: boolPtr(true), met: true},
	})

	_, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
		t.Fatalf("queries = %v — a met criterion carries someone's evidence; a landing must not offer to replace it", posts)
	}
}

// THE SERVER REMAINS THE FENCE. criterion_update/5 shares one transaction with
// the content write, so a refused criterion aborts the WHOLE landing. The
// resolution must therefore RECOVER: name the guard, re-send without the index,
// and exit 0 because the landing itself succeeded.
func TestTaskLanded_ServerRefusalIsReportedAndTheLandingStillLands(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "PR merged to main", mergeGate: boolPtr(true)},
	})
	cap.declineCode = "criterion_demands_demonstration"

	out, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d) — the LANDING succeeded; a declined criterion must not fail the verb.\nout:\n%s", code, exitOK, out)
	}
	posts := cap.posts()
	if len(posts) != 2 {
		t.Fatalf("landing POSTed %d times, want 2 (the refused attempt, then the landing alone); queries = %v", len(posts), posts)
	}
	if !strings.Contains(posts[0], "criterion=0") {
		t.Errorf("the first POST did not carry the resolved index (query = %q)", posts[0])
	}
	if strings.Contains(posts[1], "criterion=") {
		t.Errorf("the retry still carried a criterion (query = %q) — the guard refused it and the landing must go without", posts[1])
	}
	if !strings.Contains(out, "criterion_demands_demonstration") {
		t.Errorf("the refusal's own code never reached the operator; out:\n%s", out)
	}
	if !strings.Contains(out, "demands a demonstration") {
		t.Errorf("the guard was named by code and not in words; out:\n%s", out)
	}
}

// NO --note, NO RESOLUTION. The note IS the evidence the server writes onto the
// criterion and is required with --criterion, so resolving an index without one
// could only manufacture a refusal.
func TestTaskLanded_WithoutANoteNothingIsResolved(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "PR merged to main", mergeGate: boolPtr(true)},
	})

	_, code := captureExecuteCode(t, []string{"task", "landed", "bp-task-x", "--commit", "a1b2c3d"})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	if cap.reads != 0 {
		t.Errorf("the row was read %d times for a landing that carries no evidence sentence", cap.reads)
	}
	posts := cap.posts()
	if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
		t.Fatalf("queries = %v, want one landing with no criterion", posts)
	}
}

// THE POLARITY, PINNED — and the one place task-4dca6c8453fb1f7c's c2 and this
// code disagree, made MECHANICAL instead of only written down.
//
// c2 asks for "a criterion carrying merge_gate:true is NOT flipped by this
// verb". The server reads that field the OTHER way: `Tasks.Landed.merge_shaped?/1`
// returns the explicit flag verbatim, so `merge_gate: true` is merge-SHAPED and
// therefore flippable (subject only to `merge_discharges?/1`), and it is an
// explicit `false` that VETOES. This client mirrors the server, so an explicit
// `merge_gate: true` IS resolved into a flip.
//
// SETTLED 2026-09-17 (task-573618865e3c2b3f): main ruled KEEP — an explicit
// `merge_gate: true` stays flippable, c2 is not implemented as written, and the
// per-row `merge_discharges: false` from #16619 is the fence instead. So this is
// no longer a pin on an OPEN question; it is a pin on a decided one, and the
// ruling with its by-id row list lives in tasks_landed_polarity_fence_test.go.
//
// The 2026-09-13 figure this comment used to carry (two of nine rows, one of
// them task-dd37cc248363e633 index 2) is SUPERSEDED — that row is no longer a
// candidate at all. Re-measured 2026-09-17 over 1451 rows: 11 resolvable, 7 of
// them field-arm-only. Do not re-quote either number; run
// TestMeasureLandedCandidatesOverCorpus against a fresh corpus cut.
//
// This test exercises the FIELD arm through a criterion that is ALSO marker-
// worded, so it cannot distinguish the two arms on its own — that separation is
// what the two independently mutation-proved tests in
// tasks_landed_polarity_fence_test.go exist for.
func TestTaskLanded_ExplicitMergeGateTrueIsTheCandidate(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "OpsController maps {:error, :replay_unavailable} to 503 with the retry-after hint"},
		{text: "If docs/openapi.json enumerates /ops error codes, it carries replay_unavailable"},
		{text: "MERGE-GATED: merged to main with the Elixir gate green; evidence = PR number + merge sha.", mergeGate: boolPtr(true)},
	})

	_, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 || !strings.Contains(posts[0], "criterion=2") {
		t.Fatalf("queries = %v — an explicit merge_gate:true is MERGE-SHAPED on the server "+
			"(Tasks.Landed.merge_shaped?/1 returns the flag verbatim; only an explicit false vetoes), "+
			"so index 2 is the candidate. If this now reds because the polarity was deliberately "+
			"inverted to satisfy task-4dca6c8453fb1f7c's c2, say so in the PR and re-measure the nine rows: "+
			"the inversion leaves the cure reaching ONE of them.", posts)
	}
}
