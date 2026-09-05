package cli

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// wbt-go-task-create-ambiguity: `bp task create` is the ONE bp write with no
// server-assigned id to re-check — on a transport error or a 5xx, the CREATE
// mutation response that would have named the new row's id never arrived (or
// arrived as a failure), so the operator cannot even name a doc_id to go
// looking for. The sibling ledger verbs (stamp/close/pulse) already answer a
// 5xx by re-reading the row at its known id ("a 5xx can hide a write that
// landed"); create has no id to re-read, so its remedy is a title search
// instead. These tests pin that caveat on both ambiguous branches and confirm
// it is withheld on an outright 4xx refusal, where nothing landed.

// withCreateMutationsStub overrides the file-local injection seam for the
// duration of one test and restores the real sender on cleanup.
func withCreateMutationsStub(t *testing.T, fn func(manifest.Context, []map[string]any) (int, []byte, error)) {
	t.Helper()
	orig := sendCreateTaskMutations
	sendCreateTaskMutations = fn
	t.Cleanup(func() { sendCreateTaskMutations = orig })
}

func TestRunTaskCreateTransportErrorCarriesAmbiguityCaveat(t *testing.T) {
	withCreateMutationsStub(t, func(manifest.Context, []map[string]any) (int, []byte, error) {
		return 0, nil, fmt.Errorf("dial tcp: i/o timeout")
	})

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	ctx := manifest.Context{Server: "http://example.invalid", Dataset: "production", Token: "tok"}
	title := "Reindex the search shard before the fleet restarts"
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{title})

	// task-f81c88e2c54f8e57: an ambiguous write no longer shares an exit code
	// with a definite refusal — exit 9 says "sent, answer lost, go READ".
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous", code)
	}
	// In the HUMAN shapes stdout stays byte-empty: the receipt channel must not
	// carry a failure. (The `-o json` envelope lands on stdout instead — pinned
	// in tasks_create_silent_write_test.go.)
	if so.Len() != 0 {
		t.Fatalf("stdout should stay empty on failure in table mode, got %q", so.String())
	}
	got := se.String()
	if !strings.Contains(got, "i/o timeout") {
		t.Fatalf("stderr dropped the underlying transport error: %q", got)
	}
	assertAmbiguityCaveat(t, got, title)
}

func TestRunTaskCreate5xxCarriesAmbiguityCaveat(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
		rw.WriteHeader(http.StatusInternalServerError)
		rw.Write([]byte(`{"error":{"code":"internal_error","message":"the database connection pool is exhausted"}}`))
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	title := "Backfill the media checksum column"
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{title})

	// task-f81c88e2c54f8e57: an ambiguous write no longer shares an exit code
	// with a definite refusal — exit 9 says "sent, answer lost, go READ".
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous", code)
	}
	// In the HUMAN shapes stdout stays byte-empty: the receipt channel must not
	// carry a failure. (The `-o json` envelope lands on stdout instead — pinned
	// in tasks_create_silent_write_test.go.)
	if so.Len() != 0 {
		t.Fatalf("stdout should stay empty on failure in table mode, got %q", so.String())
	}
	got := se.String()
	if !strings.Contains(got, "database connection pool is exhausted") {
		t.Fatalf("stderr dropped the server's error message: %q", got)
	}
	assertAmbiguityCaveat(t, got, title)
}

// A 4xx is the server REFUSING before any commit (validation/auth/conflict/…)
// — nothing landed, so sending the operator off to search for it would be a
// false lead, not a remedy.
func TestRunTaskCreate4xxDoesNotCarryAmbiguityCaveat(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) {
		rw.WriteHeader(http.StatusUnprocessableEntity)
		rw.Write([]byte(`{"error":{"code":"validation_failed","details":{"title":["is required"]}}}`))
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	title := "A title the server rejects anyway"
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{title})

	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric", code)
	}
	got := se.String()
	if !strings.Contains(got, "validation_failed") {
		t.Fatalf("stderr dropped the validation error: %q", got)
	}
	if strings.Contains(got, "ambiguous") || strings.Contains(got, "bp search query") {
		t.Fatalf("a 4xx refusal printed the ambiguity caveat — nothing landed, there is nothing to search for: %q", got)
	}
}

// assertAmbiguityCaveat is the shared shape both ambiguous branches
// (transport error, 5xx) must produce: an explicit statement that the write
// may or may not have landed, plus a copy-pasteable remedy naming the title
// the caller actually supplied.
func assertAmbiguityCaveat(t *testing.T, stderr, title string) {
	t.Helper()
	if !strings.Contains(stderr, "may or may not have been filed") {
		t.Errorf("stderr does not name the ambiguity — no caveat that the write might have landed:\n%s", stderr)
	}
	wantRemedy := fmt.Sprintf("bp search query %q", title)
	if !strings.Contains(stderr, wantRemedy) {
		t.Errorf("stderr does not carry a copy-pasteable remedy with the supplied title (want %q):\n%s", wantRemedy, stderr)
	}
}

// Unchanged success path: the existing create tests already exercise a 2xx
// end-to-end (TestRunTaskCreateReceiptEchoesBornLifecycle et al.) and must
// keep passing byte-for-byte. This test pins that the injection seam itself
// defaults to the real sender, so a successful create still round-trips
// through the genuine HTTP path when no test has overridden it.
func TestSendCreateTaskMutationsDefaultsToRealSender(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-77")
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	status, body, err := sendCreateTaskMutations(ctx, []map[string]any{{"create": map[string]any{"_type": "task", "title": "t"}}})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if status < 200 || status >= 300 {
		t.Fatalf("status = %d, want 2xx", status)
	}
	if !strings.Contains(string(body), "drafts.task-77") {
		t.Fatalf("body = %q, want it to echo the created id", body)
	}
}
