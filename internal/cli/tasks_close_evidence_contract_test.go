package cli

// THE PIN for the close-prose contract (task-dfa5723c433382b3).
//
// A written finding does not fire by itself. The ruling in
// tasks_close_evidence_contract.go is only worth anything if removing it turns
// something red, so this file is the detector: it asserts the predicate, the
// advisory beside a landed close, the ruling's presence in
// `bp task close --help`, and the opt-in refusal arm.
//
// THE MEASUREMENT THE RULING ANSWERS. At origin/main e02933779 on 2026-09-13,
// `bp export --type task` returned 9,584 documents, of which 8,006 are CLOSED
// (lifecycle_status done|cancelled, or content.disposition closed). Of those,
// 2,740 name no path, no symbol and no sha and are scored UNCHECKABLE by
// scripts/closed-row-tree-disagreement-sweep.mjs — 34.2% of the closed
// population. Those rows are recorded as PERMANENTLY UNCHECKABLE and are not
// migrated (ruling §3); the sweep re-derives the count on every run, so the
// number above is a dated reading and not the record.

import (
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// ── the predicate ──────────────────────────────────────────────────────────

// The three anchor classes the ruling names, and the four shapes that look like
// an anchor and are not. Each negative is a class the sweep measured and
// demoted; the predicate must agree with that instrument or the contract is
// teaching a rule the instrument does not enforce.
func TestCloseReasonAnchors_MatchesTheSweepsThreeArms(t *testing.T) {
	checkable := map[string]string{
		"a repo path":                  "fixed in api/lib/barkpark/tasks/close.ex, criteria untouched",
		"an Elixir MFA":                "Barkpark.Tasks.Criteria.merge_gated?/1 now reads the field",
		"a backticked symbol":          "the guard is `merge_gated?` and it is live",
		"a commit sha":                 "landed as 70ff34f9fd on main",
		"a Go path with a line number": "internal/cli/tasks_stamp_cmd.go:711 still carries it",
	}
	for name, reason := range checkable {
		t.Run("CHECKABLE/"+name, func(t *testing.T) {
			if !closeReasonIsCheckable(reason) {
				t.Fatalf("reason %q scored UNCHECKABLE — it names an anchor the ruling accepts; anchors=%v",
					reason, closeReasonAnchors(reason))
			}
		})
	}

	uncheckable := map[string]string{
		"names nothing at all":   "closed as duplicate of the earlier row, nothing shipped",
		"an elided path":         "the fix is in api/lib/.../tenancy.ex",
		"a build artifact path":  "see _build/prod/lib/barkpark/ebin/foo.ex",
		"only a generic symbol":  "UserSocket.id/1 is token-derived",
		"a PR number, not a sha": "superseded by PR 202609011, nothing to do",
	}
	for name, reason := range uncheckable {
		t.Run("UNCHECKABLE/"+name, func(t *testing.T) {
			if closeReasonIsCheckable(reason) {
				t.Fatalf("reason %q scored CHECKABLE — the sweep demotes this class; anchors=%v",
					reason, closeReasonAnchors(reason))
			}
		})
	}
}

// ── the ruling text, where the next writer of a close hits it ──────────────

// THE SPINE OF THE PIN. Strip the ruling from closeContractRuling and this
// reds: `bp task close --help` must carry, in words, what a close has to name
// AND what happens to the rows already closed without it.
func TestTaskCloseHelp_CarriesTheClosePolicyRuling(t *testing.T) {
	out, code := captureExecuteCode(t, []string{"task", "close", "--help"})
	if code != exitOK {
		t.Fatalf("`bp task close --help` exit = %d, want %d; out:\n%s", code, exitOK, out)
	}
	// Each phrase is one load-bearing clause of the ruling. A ruling that says
	// only "name a file" without saying what happens to the 2,740 rows already
	// closed without one is half a ruling, so the disposition is pinned too.
	for _, want := range []string{
		"CLOSE-PROSE CONTRACT",
		"can never be contradicted by the tree",
		"UNCHECKABLE",
		"REPO PATH",
		"SYMBOL",
		"COMMIT SHA",
		"PERMANENTLY UNCHECKABLE",
		"not migrated",
		"BARKPARK_CLOSE_REQUIRE_ANCHOR=1",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("`bp task close --help` does not carry %q — the ruling is not where the next writer of a close will hit it; out:\n%s", want, out)
		}
	}
}

// ── the advisory beside a landed close ─────────────────────────────────────

// A close whose reason names nothing gets told so, ONCE, beside the ✓ — and
// keeps its exit code. The exit-code assertion is as load-bearing as the prose
// one: a contract that reds an existing scripted caller ships a worse defect
// than the one it fixes.
func TestTaskCloseExecute_AnchorlessReasonEarnsAnAdvisoryAndKeepsItsExitCode(t *testing.T) {
	_, hits := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "done", "closed as duplicate of the earlier row, nothing shipped"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d) — the advisory must not change the exit code; out:\n%s", code, exitOK, out)
	}
	if n := atomic.LoadInt32(hits); n == 0 {
		t.Fatalf("the close POST never fired — the advisory arm must not refuse; out:\n%s", out)
	}
	if !strings.Contains(out, "this close is UNCHECKABLE") {
		t.Fatalf("no UNCHECKABLE advisory for a reason that names nothing; out:\n%s", out)
	}
}

// The CONTROL, and it is the half that makes the test above mean anything: an
// anchored reason must stay silent. Without this arm a detector that printed
// the advisory unconditionally would pass.
func TestTaskCloseExecute_AnchoredReasonGetsNoAdvisory(t *testing.T) {
	_, _ = cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "done", "fixed in api/lib/barkpark/tasks/close.ex"})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d); out:\n%s", code, exitOK, out)
	}
	if strings.Contains(out, "this close is UNCHECKABLE") {
		t.Fatalf("the advisory fired on a reason that NAMES a repo path — the predicate is inverted or unconditional; out:\n%s", out)
	}
}

// ── the opt-in refusal (ruling §4) ─────────────────────────────────────────

// Opted in, the refusal happens BEFORE the POST. `hits == 0` is the assertion
// that carries the weight: an opted-in caller must never write a row it is then
// told off for.
func TestTaskCloseExecute_RequireAnchorOptInRefusesBeforeThePost(t *testing.T) {
	t.Setenv("BARKPARK_CLOSE_REQUIRE_ANCHOR", "1")
	st, hits := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "done", "closed as duplicate, nothing shipped"})

	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("close POST fired %d times under BARKPARK_CLOSE_REQUIRE_ANCHOR=1 — the refusal must precede the request; out:\n%s", n, out)
	}
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d); out:\n%s", code, exitValidation, out)
	}
	st.mu.Lock()
	life := st.lifecycle
	st.mu.Unlock()
	if life != "open" {
		t.Fatalf("the store's lifecycle_status moved to %q — the refusal wrote a seal; out:\n%s", life, out)
	}
}

// DEFAULT OFF is the whole reason this shipped as an advisory, so it is pinned
// rather than assumed. With the env var unset an anchorless close LANDS.
func TestTaskCloseExecute_RequireAnchorIsOffByDefault(t *testing.T) {
	if v := os.Getenv("BARKPARK_CLOSE_REQUIRE_ANCHOR"); v != "" {
		t.Fatalf("BARKPARK_CLOSE_REQUIRE_ANCHOR is set to %q in the environment — this test measures the DEFAULT and cannot", v)
	}
	_, hits := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "done", "closed as duplicate, nothing shipped"})

	if code != exitOK || atomic.LoadInt32(hits) == 0 {
		t.Fatalf("an anchorless close did not land by default (exit %d, %d POSTs) — the contract is refusing when it must only advise; out:\n%s",
			code, atomic.LoadInt32(hits), out)
	}
}
