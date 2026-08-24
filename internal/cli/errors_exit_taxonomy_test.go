package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// The stamp/close refusal vocabulary splits by RETRYABILITY (PDS-D371):
//
//	exit 6 — the world moved under you: re-read / re-claim, then retry.
//	exit 5 — the request itself is wrong: retrying it verbatim can never work.
//
// Before this table every one of these landed on exit 2, the SAME code a
// malformed `--met --miss` command line produces, so a retry wrapper could not
// tell a lost lease from a typo. Every token is tested in BOTH the bare and the
// compound `<reason>:<detail>` spelling the server actually mints
// (tasks_controller/params.ex reason_to_string/1).
func TestExitTaxonomy_StampRefusalsSplitByRetryability(t *testing.T) {
	cases := []struct {
		reason string
		want   int
	}{
		// Lease / state moved — retryable after a re-claim or re-read.
		{"not_holder", exitConflict},
		{"not_holder:worker-alpha", exitConflict},
		{"not_in_progress", exitConflict},
		{"not_in_progress:open", exitConflict},
		{"doc_changed_since_claim", exitConflict},
		{"doc_changed_since_claim:brief", exitConflict},
		{"claimed_has_worker", exitConflict},
		{"claimed_has_worker:worker-beta", exitConflict},
		// Request is wrong — never retryable as sent.
		{"criteria_mismatch", exitValidation},
		{"criteria_mismatch:3", exitValidation},
		{"criteria_index_out_of_range", exitValidation},
		{"criteria_index_out_of_range:9", exitValidation},
		{"criterion_text_required", exitValidation},
		{"criterion_text_required:0", exitValidation},
		{"note_required", exitValidation},
		{"note_required:miss", exitValidation},
		{"illegal_transition", exitValidation},
		{"illegal_transition:done", exitValidation},
	}
	for _, c := range cases {
		body := []byte(fmt.Sprintf(`{"ok":false,"reason":%q}`, c.reason))
		if got := classifyError(409, body).exit; got != c.want {
			t.Errorf("classifyError({ok:false,reason:%q}) exit = %d, want %d", c.reason, got, c.want)
		}
		// The same token in the canonical coded envelope must agree — one token,
		// one exit code, whatever shape carried it.
		coded := []byte(fmt.Sprintf(`{"error":{"code":%q,"message":"refused"}}`, c.reason))
		if got := classifyError(422, coded).exit; got != c.want {
			t.Errorf("classifyError({error:{code:%q}}) exit = %d, want %d", c.reason, got, c.want)
		}
		if got := exitForCode(c.reason); got != c.want {
			t.Errorf("exitForCode(%q) = %d, want %d", c.reason, got, c.want)
		}
	}
}

// The three shapes the server uses for the SAME token must agree. The cloud
// router (cloud/lib/barkpark_cloud/web/router.ex) emits a BARE-STRING
// {"error":"illegal_transition"}, which used to bucket default:exitUsage
// without ever consulting the code table — so one token meant exit 2 from one
// host and exit 5 from another.
func TestExitTaxonomy_BareStringAgreesWithCodedEnvelope(t *testing.T) {
	shapes := map[string][]byte{
		"bare-string":      []byte(`{"error":"illegal_transition"}`),
		"ok-false reason":  []byte(`{"ok":false,"reason":"illegal_transition"}`),
		"coded envelope":   []byte(`{"error":{"code":"illegal_transition","message":"stage refused"}}`),
		"bare-string:comp": []byte(`{"error":"not_in_progress:open"}`),
	}
	want := map[string]int{
		"bare-string":      exitValidation,
		"ok-false reason":  exitValidation,
		"coded envelope":   exitValidation,
		"bare-string:comp": exitConflict,
	}
	for name, body := range shapes {
		if got := classifyError(422, body).exit; got != want[name] {
			t.Errorf("%s shape exit = %d, want %d", name, got, want[name])
		}
	}
}

// reasonKey splits at the FIRST ':' and nowhere else, and an unknown token
// still falls through to the documented fallbacks (exitGeneric for a coded
// envelope, exitUsage for the ok:false / bare-string shapes) rather than being
// swept into a bucket by a too-eager prefix match.
func TestExitTaxonomy_ReasonKeyAndUnknownFallbacks(t *testing.T) {
	if got := reasonKey("not_holder:worker:with:colons"); got != "not_holder" {
		t.Errorf("reasonKey split at the wrong colon: %q", got)
	}
	if got := reasonKey("plain"); got != "plain" {
		t.Errorf("reasonKey mangled a bare token: %q", got)
	}
	// criteria_unmet USED to be pinned here as deliberately unknown. It is now
	// in the table (exit 5) along with invalid_lifecycle, sentinel_worker_id
	// and merge_gated_criterion — the four the D371 split missed. The pin is
	// INVERTED rather than deleted so the family lookup that reaches them
	// through reasonKey stays covered by the test that once denied it.
	for _, token := range []string{
		"criteria_unmet:1,2", "invalid_lifecycle:done",
		"sentinel_worker_id:none", "merge_gated_criterion",
	} {
		e, known := lookupExit(token)
		if !known {
			t.Errorf("lookupExit(%q) is unknown — it must resolve through the table", token)
		}
		if e != exitValidation {
			t.Errorf("lookupExit(%q) = %d, want exitValidation (%d)", token, e, exitValidation)
		}
	}
	if got := exitForCode("some_code_nobody_maps"); got != exitGeneric {
		t.Errorf("unknown coded error exit = %d, want exitGeneric (%d)", got, exitGeneric)
	}
	if got := classifyError(422, []byte(`{"ok":false,"reason":"invalid_edge"}`)).exit; got != exitUsage {
		t.Errorf("invalid_edge exit = %d, want exitUsage (%d) — historical add-edge shape", got, exitUsage)
	}
	if got := classifyError(422, []byte(`{"error":"who_knows"}`)).exit; got != exitUsage {
		t.Errorf("unknown bare-string exit = %d, want exitUsage (%d)", got, exitUsage)
	}
	// The codes that already had a bucket must not move.
	for reason, want := range map[string]int{
		"fenced_off":  exitConflict,
		"stale_claim": exitConflict,
		"not_found":   exitNotFound,
		"not_ready":   exitConflict,
	} {
		if got := exitForCode(reason); got != want {
			t.Errorf("exitForCode(%q) = %d, want %d (pre-existing bucket moved)", reason, got, want)
		}
	}
}

const taxonomyStampManifest = `{
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

// taxonomyRefusingServer answers every stamp POST with the given 409/422
// refusal envelope, so a test can drive the REAL `bp task stamp` dispatch and
// read the process exit code the classifier produced.
func taxonomyRefusingServer(t *testing.T, status int, body string) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(taxonomyStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "taxonomy-stub")
}

// END-TO-END through the real dispatch: a lease you LOST and a command line you
// typed WRONG must no longer share exit 2. Both arms drive the actual
// `bp task stamp` path; each fake server answers with the envelope the real
// tasks controller sends for that case (`not_holder:<worker>` 409, and the
// `invalid_stamp` 422 params.ex:825 mints for `--met --miss`).
func TestTaskStampExit_LostLeaseAndBadCommandLineDiffer(t *testing.T) {
	stamp := []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "0", "--met", "--evidence", "e", "--criterion-text", "a row",
	}
	var lostLease, badArgs int
	t.Run("lost lease", func(t *testing.T) {
		taxonomyRefusingServer(t, http.StatusConflict, `{"ok":false,"reason":"not_holder:worker-alpha"}`)
		_, lostLease = captureExecuteCode(t, stamp)
		if lostLease != exitConflict {
			t.Fatalf("not_holder exit = %d, want exitConflict (%d)", lostLease, exitConflict)
		}
	})
	t.Run("bad command line", func(t *testing.T) {
		taxonomyRefusingServer(t, http.StatusUnprocessableEntity,
			`{"ok":false,"reason":"invalid_stamp","message":"pass exactly one of --met / --miss, not both"}`)
		_, badArgs = captureExecuteCode(t, append(append([]string{}, stamp...), "--miss"))
		if badArgs != exitUsage {
			t.Fatalf("malformed --met --miss exit = %d, want exitUsage (%d)", badArgs, exitUsage)
		}
	})
	if badArgs == lostLease {
		t.Fatalf("a lost lease and a malformed command line still share exit %d", badArgs)
	}
}

// The server-side payload guards keep exit 5 through the real dispatch, so a
// wrapper reading only the exit code learns "do not retry this request".
func TestTaskStampExit_PayloadGuardsAreValidation(t *testing.T) {
	for _, reason := range []string{"criterion_text_required", "criteria_mismatch", "illegal_transition"} {
		t.Run(reason, func(t *testing.T) {
			body, _ := json.Marshal(map[string]any{"ok": false, "reason": reason})
			taxonomyRefusingServer(t, http.StatusUnprocessableEntity, string(body))
			_, code := captureExecuteCode(t, []string{
				"task", "stamp", "bp-task-x", "w", "1",
				"--criterion", "0", "--met", "--evidence", "e", "--criterion-text", "a row",
			})
			if code != exitValidation {
				t.Errorf("%s exit = %d, want exitValidation (%d)", reason, code, exitValidation)
			}
		})
	}
}
