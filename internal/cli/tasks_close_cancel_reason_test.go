package cli

// A `cancelled` close with a BLANK reason (task-650d7844d8fe7199).
//
// MEASURED on the ledger 2026-09-06 ~05:27Z, twice inside one minute, on real
// rows: a scripting fault expanded `$(cat reason.txt)` to the empty string and
//
//	bp task close task-e1920c0a8cd3013b lead-cli 1 cancelled "" --yes
//
// exited 0, printed `✓ the store holds it — lifecycle_status=cancelled`, and
// stored NO close_reason. A cancel is exempt BY NAME from every other
// close-time gate on the server, so its reason is the entire record of why the
// work stopped — and it was the one field a caller could omit.
//
// The SERVER is the authority (Tasks.Close answers `cancel_reason_required` for
// bp, MCP, Studio and raw HTTP alike). These tests pin the LOCAL arm: the same
// refusal, before the round trip, so nothing is written and the operator gets
// the diagnosis in one step.

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// THE SPINE. The assertion that carries the weight is `hits == 0` — the refusal
// must happen BEFORE the POST. Delete refuseBlankCancelReason and the request
// fires and lands.
func TestTaskCloseExecute_BlankCancelReasonIsRefusedLocally(t *testing.T) {
	for name, reason := range map[string]string{
		"empty string":    "",
		"a single space":  " ",
		"tabs and spaces": " \t ",
	} {
		t.Run(name, func(t *testing.T) {
			st, hits := cpTestServer(t, cpHonest)

			out, code := captureExecuteCode(t,
				[]string{"task", "close", "bp-task-x", "w", "1", "cancelled", reason})

			if n := atomic.LoadInt32(hits); n != 0 {
				t.Fatalf("close POST fired %d times — a cancel with a blank reason must be refused BEFORE the request; out:\n%s", n, out)
			}
			if code != exitValidation {
				t.Fatalf("exit = %d, want exitValidation (%d) — the same code the server's cancel_reason_required carries; out:\n%s",
					code, exitValidation, out)
			}
			// It must not have moved the store.
			st.mu.Lock()
			life := st.lifecycle
			st.mu.Unlock()
			if life != "open" {
				t.Fatalf("the store's lifecycle_status moved to %q — the refusal wrote a seal; out:\n%s", life, out)
			}
		})
	}
}

// A reason ARGUMENT that is entirely absent is the same fact as an empty one —
// no reason was given — and must reach the same refusal. Splitting them would
// leave the four-positional form as an open door.
func TestTaskCloseExecute_CancelWithNoReasonArgumentAtAllIsRefused(t *testing.T) {
	_, hits := cpTestServer(t, cpHonest)

	out, code := captureExecuteCode(t, []string{"task", "close", "bp-task-x", "w", "1", "cancelled"})

	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("close POST fired %d times for a cancel with no reason at all; out:\n%s", n, out)
	}
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d); out:\n%s", code, exitValidation, out)
	}
}

// The refusal has to TEACH, or the operator learns only that something is
// missing. Three things must be in it: WHY a cancel is the status this binds
// on, WHERE the reason goes, and that there is no override to reach for.
func TestTaskCloseExecute_BlankCancelRefusalTeachesTheFix(t *testing.T) {
	cpTestServer(t, cpHonest)

	out, _ := captureExecuteCode(t,
		[]string{"task", "close", "bp-task-x", "w", "1", "cancelled", ""})

	for _, want := range []string{
		"EXEMPT BY NAME",
		"FIFTH positional",
		`bp task close bp-task-x w 1 cancelled "<why this work is being abandoned>"`,
		"no override",
		"cancel_reason_required",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("refusal never says %q; got:\n%s", want, out)
		}
	}
}

// THE PERMIT ARMS, and they matter more than the refusal: the blast radius of
// this gate is exactly one path — a cancel that carries no reason. A guard that
// also caught a cancel WITH a reason, a `done` close, or a `blocked` close
// would have replaced the invariant instead of implementing it.
//
// `blocked` in particular: the Studio board drags to blocked through
// Board.restage_plan/4 with no reason and no affordance to type one.
func TestTaskCloseExecute_TheGuardCatchesOnlyTheBlankCancel(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"a cancel WITH a reason", []string{"task", "close", "bp-task-x", "w", "1", "cancelled", "superseded by #16311"}},
		{"a cancel whose reason is one character", []string{"task", "close", "bp-task-x", "w", "1", "cancelled", "x"}},
		{"a blocked close with NO reason", []string{"task", "close", "bp-task-x", "w", "1", "blocked"}},
		{"a blocked close with a blank reason", []string{"task", "close", "bp-task-x", "w", "1", "blocked", ""}},
		{"a done close with NO reason", []string{"task", "close", "bp-task-x", "w", "1", "done"}},
		{"a done close with a blank reason", []string{"task", "close", "bp-task-x", "w", "1", "done", ""}},
		{"an OMITTED seal (defaults to done) with no reason", []string{"task", "close", "bp-task-x", "w", "1"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, hits := cpTestServer(t, cpHonest)

			out, code := captureExecuteCode(t, tc.args)

			if n := atomic.LoadInt32(hits); n != 1 {
				t.Fatalf("%s fired %d POSTs, want 1 — the local guard must not catch it; out:\n%s", tc.name, n, out)
			}
			if code != exitOK {
				t.Fatalf("%s exited %d, want 0; out:\n%s", tc.name, code, out)
			}
		})
	}
}

// The wire token the server answers with must reach the SAME exit code as the
// local refusal, so a retry wrapper cannot tell them apart — which is the
// point: both say "the request is wrong, re-sending it cannot help". The token
// still arrives over the wire on the paths the local guard cannot see (MCP
// task_close, a Studio close, a raw HTTP caller), so this drives it end to end
// with a reason the local guard passes through, and asserts the server's hint —
// where the whole content of the refusal lives — reaches stderr VERBATIM.
func TestTaskCloseExit_CancelReasonRequiredIsValidationWithTheHintVerbatim(t *testing.T) {
	if got := codeExit["cancel_reason_required"]; got != exitValidation {
		t.Fatalf("cancel_reason_required maps to exit %d, want exitValidation (%d) — "+
			"absent from codeExit it falls to the malformed-command-line code", got, exitValidation)
	}

	const hint = `a ` + "`cancelled`" + ` close needs a reason and this one carried none. ` +
		`Pass it as the FIFTH positional. There is no override, on purpose: the escape hatch IS the sentence.`

	body, err := json.Marshal(map[string]any{
		"ok":      false,
		"reason":  "cancel_reason_required",
		"message": hint,
	})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	taxonomyClosingServer(t, http.StatusConflict, string(body))

	out, code := captureExecuteCode(t, []string{
		"task", "close", "bp-task-x", "w", "1", "cancelled", "a reason the local guard lets through", "--yes",
	})

	if code != exitValidation {
		t.Errorf("cancel_reason_required exited %d, want exitValidation (%d)", code, exitValidation)
	}
	if code == exitUsage {
		t.Errorf("cancel_reason_required landed on exit %d — the malformed-command-line code, "+
			"which means the codeExit row is missing", exitUsage)
	}
	if !strings.Contains(out, hint) {
		t.Errorf("the server's hint did not reach the caller VERBATIM.\n got: %s\nwant substring: %s", out, hint)
	}
}
