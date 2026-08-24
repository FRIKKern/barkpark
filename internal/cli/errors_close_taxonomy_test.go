package cli

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
