package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The property these tests pin (pds-bl-merge-gate-key-unimplemented): the Stop
// hook's unattended close must never step past an EXTERNAL gate — a criterion
// the row's author declared `"merge_gate": true`, which no builder may stamp and
// which only a real merge (close.ex's `autostamp_merge_gate/6`, the
// `reconcile_merge_gate/3` webhook bridge, or `bp task landed`) flips to met.
//
// The hook holds that line WITHOUT naming merge_gate anywhere: `acceptanceAllMet`
// requires the JSON literal true on EVERY entry, so a declared-but-unmerged gate
// is `met:false` and the close never fires. That is a real guarantee and it was
// never tested — `git grep -n merge_gate -- internal/cli/cmux_hook.go` had 0 hits
// before this file, so nothing red if a future edit taught the hook to skip,
// discount, or count-as-met the very criteria the policy exists to respect.
//
// MUTATION THAT REDS THIS FILE: teach `acceptanceAllMet` to ignore merge-gated
// entries (`if it.MergeGate { continue }`) or to count them met. Interpretation
// (a) in the filing — "the hook must SKIP merge_gate criteria when computing
// completion" — IS that mutation, and it inverts the policy: skipping a gate
// makes an unmerged task close SOONER, not later.

// mgCrit is one acceptance criterion as the fake server serves it. merge_gate is
// omitted from the wire when false, matching real rows: the flag is opt-in and
// most criteria carry no such key at all.
type mgCrit struct {
	Text      string
	Met       bool
	MergeGate bool
}

func (c mgCrit) wire() map[string]any {
	m := map[string]any{"criterion": c.Text, "met": c.Met}
	if c.MergeGate {
		m["merge_gate"] = true
	}
	return m
}

// mgRec records what the merge-gate fake server was asked to do. closes is the
// only number that matters: a task whose external gate is unsatisfied must
// produce ZERO close requests, so the row stays nonterminal on the server.
type mgRec struct {
	closes int
	claims int
	gets   int
}

// newMergeGateServer serves the hook's three endpoints against a fixed criteria
// list. Every close it is asked for LANDS — so a `closes == 0` verdict can only
// come from the hook declining to ask, never from the server refusing. That is
// the asymmetry that keeps these tests non-vacuous: a hook that ignored the gate
// would get a clean 200 and the assertion would red.
func newMergeGateServer(t *testing.T, crits []mgCrit) (*httptest.Server, *mgRec) {
	t.Helper()
	rec := &mgRec{}
	wire := make([]map[string]any, 0, len(crits))
	for _, c := range crits {
		wire = append(wire, c.wire())
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case strings.HasSuffix(p, "/claim"):
			rec.claims++
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":7}}}`))
		case strings.HasSuffix(p, "/close"):
			rec.closes++
			_, _ = w.Write([]byte(`{"ok":true,"doc":{}}`))
		case strings.Contains(p, "/v1/data/doc/") && strings.Contains(p, "/task/"):
			rec.gets++
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{
				"_id":                 "task-mg",
				"rev":                 "r-mg-1",
				"lifecycle_status":    "in_progress",
				"acceptance_criteria": wire,
			}})
		default:
			t.Errorf("unexpected request: %s %s", r.Method, p)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

func runMergeGateStop(t *testing.T, server string) (stdout, stderr string, code int) {
	t.Helper()
	ctx := hookHarness(t, server, "task-mg", "SMG", `{}`)
	t.Setenv("BP_CMUX_DEBUG", "1")
	var so, se bytes.Buffer
	code = runCmuxHook(&writer{stdout: &so, stderr: &se, output: "table"}, globals{}, *ctx, []string{"Stop"})
	return so.String(), se.String(), code
}

// THE GATE HOLDS. Every ordinary criterion met, ONE declared merge gate unmet:
// the task must stay nonterminal — no close request on the wire at all.
func TestHookStopLeavesADeclaredMergeGateNonterminal(t *testing.T) {
	srv, rec := newMergeGateServer(t, []mgCrit{
		{Text: "the mechanism ships", Met: true},
		{Text: "the mutation-sensitive test lands", Met: true},
		{Text: "PR merged to main (LEAD closes this on merge)", Met: false, MergeGate: true},
	})
	so, se, code := runMergeGateStop(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the hook's cardinal contract)", code)
	}
	if so != "" {
		t.Errorf("hook wrote to stdout: %q (must be empty)", so)
	}
	if rec.closes != 0 {
		t.Fatalf("closes = %d, want 0 — an unsatisfied merge_gate criterion must keep the task nonterminal; this server LANDS every close it is asked for, so any count above zero is the hook asking", rec.closes)
	}
	if rec.claims != 0 {
		t.Errorf("claims = %d, want 0 — the gate must be judged from the acceptance read, before any epoch write", rec.claims)
	}
	if !strings.Contains(se, "acceptance not proven") {
		t.Errorf("diagnostic channel = %q, want the unmet-criteria no-op line", se)
	}
}

// THE CONTROL. The SAME shape with no external gate declared closes. Without
// this arm, a hook that never closed anything would pass the test above.
func TestHookStopClosesWhenNoExternalGateIsDeclared(t *testing.T) {
	srv, rec := newMergeGateServer(t, []mgCrit{
		{Text: "the mechanism ships", Met: true},
		{Text: "the mutation-sensitive test lands", Met: true},
	})
	_, _, code := runMergeGateStop(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if rec.closes != 1 {
		t.Fatalf("closes = %d, want 1 — a task with no external gate still follows the accepted completion policy", rec.closes)
	}
}

// THE GATE OPENS. The merge landed, so the autostamp flipped the gated criterion
// to met — and only then may the hook close. This is the arm that proves the
// policy is "excluded from automatic completion UNTIL the external event", not
// "merge-gated tasks can never auto-close".
func TestHookStopClosesOnceTheMergeGateIsSatisfied(t *testing.T) {
	srv, rec := newMergeGateServer(t, []mgCrit{
		{Text: "the mechanism ships", Met: true},
		{Text: "PR merged to main (LEAD closes this on merge)", Met: true, MergeGate: true},
	})
	_, _, code := runMergeGateStop(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if rec.closes != 1 {
		t.Fatalf("closes = %d, want 1 — a merge_gate criterion the merge autostamp already flipped is met like any other", rec.closes)
	}
}

// crownCriteria builds the shape of pds-w1-crown-proof: eleven ordinary criteria
// carrying run evidence, plus one "PR merged to main" criterion. `declared`
// decides whether that last criterion carries the `merge_gate: true` flag or is
// fenced by PROSE ALONE, which is how the real crown row was written.
func crownCriteria(declared, gateMet bool) []mgCrit {
	crits := make([]mgCrit, 0, 12)
	for i := 0; i < 11; i++ {
		crits = append(crits, mgCrit{Text: "crown rung evidence, run_id=5abf6afd", Met: true})
	}
	crits = append(crits, mgCrit{
		Text:      "PR merged to main (LEAD closes this criterion on merge). MERGE-GATED — DO NOT STAMP EARLY (PDS-D163).",
		Met:       gateMet,
		MergeGate: declared,
	})
	return crits
}

// THE CROWN, FENCED BY PROSE ONLY — the filing's reproduction, still true.
// pds-w1-crown-proof's criterion 10 says "MERGE-GATED — DO NOT STAMP EARLY" in
// its TEXT and carries no `merge_gate` key (verified on the live row: 12 of 12
// criteria have keys criterion/evidence/met and nothing else). A row shaped that
// way, once something stamps that criterion met, closes on the next Stop. The
// hook is not the guard here and this test does not pretend otherwise: the guard
// for a prose-marked gate is the STAMP door, where `Criteria.merge_gated?/1` is
// flag-OR-PROSE and refuses a builder `--met` with `merge_gated_criterion`
// unless `--merge-gated <reason>` is typed. This test pins the residual so it is
// documented rather than assumed away.
func TestHookStopClosesAProseOnlyCrownGate(t *testing.T) {
	srv, rec := newMergeGateServer(t, crownCriteria(false, true))
	_, _, code := runMergeGateStop(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if rec.closes != 1 {
		t.Fatalf("closes = %d, want 1 — a prose-only MERGE-GATED criterion stamped met is indistinguishable from any other met criterion at the hook; the flag is what makes it mechanical", rec.closes)
	}
}

// THE CROWN, DECLARED — the fix, on the same shape. Eleven rungs green and the
// twelfth criterion carrying `merge_gate: true` and still unmerged: the row stays
// nonterminal through Stop after Stop. This is the arm the crown row should have
// had, and the one sentence that turns PDS-D163's prose fence into a mechanism.
func TestHookStopHoldsADeclaredCrownGate(t *testing.T) {
	srv, rec := newMergeGateServer(t, crownCriteria(true, false))
	_, _, code := runMergeGateStop(t, srv.URL)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if rec.closes != 0 {
		t.Fatalf("closes = %d, want 0 — 11 rungs met and one declared merge_gate unmerged must NOT terminate the crown", rec.closes)
	}
	// A second Stop must not drift: the gate is a property of the row, not a
	// one-shot suppression the hook could forget.
	_, _, _ = runMergeGateStop(t, srv.URL)
	if rec.closes != 0 {
		t.Fatalf("closes = %d after a second Stop, want 0", rec.closes)
	}
}
