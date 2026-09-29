package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// taxonomyCloseManifest declares `task.close` so the CLOSE refusals can be
// measured through the real dispatch rather than against the codeExit map.
// The stamp-only manifest cannot do it: a close mints reasons a stamp never
// can (criteria_unmet, invalid_lifecycle), and asserting a table entry is not
// the same as proving the exit code a caller actually receives.
const taxonomyCloseManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.close", "noun": "task", "verb": "close",
      "summary": "close a claimed task",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/close"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"},
        {"name": "observed_epoch", "required": true, "type": "int", "summary": "e"},
        {"name": "lifecycle_status", "required": false, "type": "string", "summary": "s"},
        {"name": "reason", "required": false, "type": "string", "summary": "r"}
      ],
      "flags": [
        {"name": "set", "type": "string", "repeatable": true, "summary": "extra"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// taxonomyClosingServer answers every close POST with the given refusal
// envelope. The shape is the one tasks_controller.ex conflict/3 actually
// sends — {"ok":false,"reason":"<token>","message":"<hint>"} at HTTP 409 —
// NOT a coded {"error":{"code":…}} envelope. Which shape carries the token
// decides which classifyError branch runs, and the two branches have
// DIFFERENT fallbacks for an unknown token (exitUsage vs exitGeneric), so a
// test that guesses the shape measures the wrong number.
func taxonomyClosingServer(t *testing.T, status int, body string) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(taxonomyCloseManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "taxonomy-stub")
}

// closeRefusalExit drives the REAL `bp task close` dispatch against a server
// that refuses with the given token and returns the process exit code.
func closeRefusalExit(t *testing.T, token string) int {
	t.Helper()
	taxonomyClosingServer(t, http.StatusConflict,
		fmt.Sprintf(`{"ok":false,"reason":%q,"message":"refused"}`, token))
	_, code := captureExecuteCode(t, []string{
		"task", "close", "bp-task-x", "w", "1", "done", "summary", "--yes",
	})
	return code
}

// The four close/stamp refusals the PDS-D371 split missed, MEASURED through
// the real `bp task close` dispatch rather than asserted against codeExit.
//
// BEFORE (probe on origin/main ef28c20818, 2026-08-24): all four exited 2 —
// byte-identical to a malformed command line, which is the confusion the 5/6
// split exists to remove. Note this is exit 2 and not exit 1: the tasks
// controller refuses with {"ok":false,"reason":…}, whose classifyError branch
// falls back to exitUsage, so reasoning from exitForCode's exitGeneric
// fallback gives the wrong "before" number.
func TestTaskCloseExit_TheFourMissedRefusalsAreValidation(t *testing.T) {
	for _, token := range []string{
		"criteria_unmet:0,1",
		"invalid_lifecycle:done",
		"sentinel_worker_id:none",
		"merge_gated_criterion",
	} {
		t.Run(token, func(t *testing.T) {
			if got := closeRefusalExit(t, token); got != exitValidation {
				t.Errorf("close refused with %s exited %d, want exitValidation (%d)",
					token, got, exitValidation)
			}
		})
	}
}

// The point of the split is that the two halves DIFFER end to end. A lost
// lease stays retryable (6) while an unmet-criteria close stays permanent (5),
// and neither may collapse back onto the usage code a typo produces.
func TestTaskCloseExit_RetryableAndPermanentRefusalsDiffer(t *testing.T) {
	var lease, criteria int
	t.Run("lost lease is retryable", func(t *testing.T) {
		lease = closeRefusalExit(t, "not_holder:worker-alpha")
		if lease != exitConflict {
			t.Fatalf("not_holder exit = %d, want exitConflict (%d)", lease, exitConflict)
		}
	})
	t.Run("unmet criteria is permanent", func(t *testing.T) {
		criteria = closeRefusalExit(t, "criteria_unmet:0,1")
		if criteria != exitValidation {
			t.Fatalf("criteria_unmet exit = %d, want exitValidation (%d)", criteria, exitValidation)
		}
	})
	if lease == criteria {
		t.Fatalf("a lost lease and an unmet-criteria refusal still share exit %d", lease)
	}
	if criteria == exitUsage {
		t.Fatalf("criteria_unmet is back on exit %d — the malformed-command-line code", exitUsage)
	}
}

// The close-artifact gate (PDS-D291). Two claims, and the second is the one a
// codeExit assertion cannot make: the refusal must reach the caller as
// VALIDATION (5) — not as the exit 2 an unknown {"ok":false,"reason":…} token
// falls back to, which is byte-identical to a malformed command line — and the
// server's hint must reach stderr VERBATIM, because the hint is where the
// ruling lives. A caller who sees only `close_reason_needs_artifact` learns
// that something is missing but never that the row is not done.
func TestTaskCloseExit_CloseReasonNeedsArtifactIsValidationWithTheRulingVerbatim(t *testing.T) {
	const hint = `this row carries ZERO acceptance criteria, and main ruled ` +
		`(task-ce0c0ffff6edde23, 2026-09-02): "a row with ZERO acceptance criteria may close done ` +
		`only when its close_reason names the merged PR number + sha (or the run output) that ` +
		`discharged its title". To close done anyway, on the record: ` +
		`--set close_reason_override="<why it is done with no artifact>".`

	body, err := json.Marshal(map[string]any{
		"ok":      false,
		"reason":  "close_reason_needs_artifact",
		"message": hint,
	})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	taxonomyClosingServer(t, http.StatusConflict, string(body))

	out, code := captureExecuteCode(t, []string{
		"task", "close", "bp-task-x", "w", "1", "done", "shipped it", "--yes",
	})

	if code != exitValidation {
		t.Errorf("close_reason_needs_artifact exited %d, want exitValidation (%d)", code, exitValidation)
	}
	if code == exitUsage {
		t.Errorf("close_reason_needs_artifact landed on exit %d — the malformed-command-line code, "+
			"which means the codeExit row is missing", exitUsage)
	}
	if !strings.Contains(out, hint) {
		t.Errorf("the server's hint did not reach the caller VERBATIM.\n got: %s\nwant substring: %s", out, hint)
	}
}

// THE FIFTH (task-d10d9eb47f2cc5e4, PR #16891's stated residual), and the five
// the coverage arm found beside it.
//
// criteria_raised_on_abandon is the honesty gate refusing a `cancelled` or
// `blocked` close that would RAISE an acceptance criterion's met from false to
// true. It arrived AFTER the 2026-08-24 sweep fixed four siblings, and landed
// on the same exit 2 they had — which is why the durable answer is the arm in
// errors_close_refusal_coverage_test.go and not this list. This test is the
// MEASUREMENT criterion 1 asks for: the number a caller actually receives from
// the real `bp task close` dispatch, not a codeExit row read back to itself.
//
// BEFORE (this branch, with the codeExit rows reverted): exit 2 for all six.
//
// Three of the six (invalid_criteria, evidence_required, observed_rev_required)
// are minted on the STAMP path. They are probed through the close dispatch
// anyway and that measures the right thing: both routes answer through
// tasks_controller conflict/3 with the identical {"ok":false,"reason":…} shape,
// so it is the same classifyError branch and the same table lookup. What the
// probe proves is the branch's fallback, which is the defect.
func TestTaskCloseExit_TheCloseRefusalVocabularyIsNeverUsage(t *testing.T) {
	for _, c := range []struct {
		token string
		want  int
		why   string
	}{
		{"criteria_raised_on_abandon:0,1", exitValidation,
			"a cancel may ABANDON criteria, never assert them; nothing moved under the caller " +
				"and there is no override flag, so the fix is an act outside this request"},
		{"invalid_criteria", exitValidation, "the criteria payload is the wrong shape"},
		{"evidence_required", exitValidation, "a --met stamp with no evidence"},
		{"observed_rev_required", exitValidation, "no live claim to fence against; pin --observed-rev"},
		{"stale_rev", exitConflict, "lost a rev-CAS race — the world moved, re-read and retry"},
		{"unknown_task", exitNotFound, "the row is gone; no retry brings it back"},
	} {
		t.Run(c.token, func(t *testing.T) {
			got := closeRefusalExit(t, c.token)
			if got == exitUsage {
				t.Fatalf("close refused with %s exited %d — the malformed-command-line code, "+
					"which means the codeExit row is missing (%s)", c.token, exitUsage, c.why)
			}
			if got != c.want {
				t.Errorf("close refused with %s exited %d, want %d (%s)", c.token, got, c.want, c.why)
			}
		})
	}
}

// THE QUIET ARM. Bucketing six more tokens is exactly the change that turns an
// honest "unknown" into a confident wrong answer, so the fallback must survive
// intact: a reason nobody has mapped still exits 2 through this same dispatch,
// and the compound-token family lookup must not swallow a stranger just because
// it carries a colon.
func TestTaskCloseExit_UnmappedRefusalsStillFallToUsage(t *testing.T) {
	for _, token := range []string{
		"a_reason_the_server_has_never_minted",
		"a_reason_the_server_has_never_minted:0,1",
		"criteria_raised_on_abandonment", // near-miss: NOT the family name
	} {
		t.Run(token, func(t *testing.T) {
			if got := closeRefusalExit(t, token); got != exitUsage {
				t.Errorf("unmapped reason %s exited %d, want exitUsage (%d) — the fallback "+
					"must survive the backfill", token, got, exitUsage)
			}
		})
	}
}
