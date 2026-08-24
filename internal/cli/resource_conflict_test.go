package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// liveResourceConflictBody is the 409 body guerrilla.barkpark.cloud actually
// sends, captured verbatim. Every assertion in this file is measured against
// THIS shape — the holder key is `doc_id`, and `conflicts` is a TOP-LEVEL
// sibling of `reason`, not a member of an `error` object, which is why the
// canonical envelope branch in classifyError never saw it.
const liveResourceConflictBody = `{"ok":false,"reason":"resource_conflict","conflicts":[{"worker":"build-lane-j","doc_id":"task-4b338a4dbe90d44d","resources":["internal/cli/run.go"]}]}`

// TestClassifyErrorKeepsTheConflictHolders: the remedy the server computed must
// survive classification. Before this, `bp task claim … -o json` printed
//
//	{"error":{"code":"resource_conflict","message":"resource_conflict"},"ok":false}
//
// over the body above — the holder row, the worker and the overlapping path all
// dropped by the client AFTER the server had already worked them out, and after
// docs/cli/error-exit-table.md:110 had promised for months that
// "`resource_conflict` carries `conflicts[]` naming the holders".
func TestClassifyErrorKeepsTheConflictHolders(t *testing.T) {
	ae := classifyError(http.StatusConflict, []byte(liveResourceConflictBody))
	if ae.code != "resource_conflict" || ae.exit != exitConflict {
		t.Fatalf("code/exit = %q/%d, want resource_conflict/%d", ae.code, ae.exit, exitConflict)
	}
	if ae.details == nil {
		t.Fatal("details is nil — the conflicts array was dropped, which is the whole bug")
	}
	var got struct {
		Conflicts []struct {
			DocID     string   `json:"doc_id"`
			Worker    string   `json:"worker"`
			Resources []string `json:"resources"`
		} `json:"conflicts"`
	}
	if err := json.Unmarshal(ae.details, &got); err != nil {
		t.Fatalf("details is not the {conflicts:[…]} payload: %v (%s)", err, ae.details)
	}
	if len(got.Conflicts) != 1 {
		t.Fatalf("conflicts = %+v, want exactly the one holder the server named", got.Conflicts)
	}
	c := got.Conflicts[0]
	if c.DocID != "task-4b338a4dbe90d44d" || c.Worker != "build-lane-j" ||
		len(c.Resources) != 1 || c.Resources[0] != "internal/cli/run.go" {
		t.Errorf("holder = %+v, want the row, worker and path verbatim", c)
	}
}

// TestClassifyErrorLeavesOtherReasonsByteIdentical: topLevelConflicts is keyed
// on the PRESENCE of a non-empty conflicts array, so every other ok:false reason
// must classify exactly as before. A details that appears where none did would
// change the -o json envelope for six unrelated task refusals.
func TestClassifyErrorLeavesOtherReasonsByteIdentical(t *testing.T) {
	for _, body := range []string{
		`{"ok":false,"reason":"not_ready"}`,
		`{"ok":false,"reason":"fenced_off"}`,
		`{"ok":false,"reason":"stale_claim","message":"epoch 3 is stale"}`,
		`{"ok":false,"reason":"resource_conflict","conflicts":[]}`,
		`{"ok":false,"reason":"resource_conflict"}`,
	} {
		if ae := classifyError(http.StatusConflict, []byte(body)); ae.details != nil {
			t.Errorf("%s produced details %s, want none", body, ae.details)
		}
	}
}

// TestResourceConflictLinesPairTheThreeTokens: the human channel must pair the
// row, the worker and the paths on ONE line each. The generic sorted rendering
// prints the array as a single compact-JSON blob under a `conflicts:` key, which
// buries exactly the three tokens the caller has to act on.
func TestResourceConflictLinesPairTheThreeTokens(t *testing.T) {
	ae := classifyError(http.StatusConflict, []byte(liveResourceConflictBody))
	lines := detailLinesForCode(ae.code, ae.details)
	if len(lines) != 1 {
		t.Fatalf("lines = %q, want exactly one holder line", lines)
	}
	for _, want := range []string{"task-4b338a4dbe90d44d", "build-lane-j", "internal/cli/run.go"} {
		if !strings.Contains(lines[0], want) {
			t.Errorf("holder line %q is missing %q", lines[0], want)
		}
	}
}

// TestResourceConflictLinesFallBackOnAnUncontractedShape: same discipline as the
// two publish-wall siblings — a payload whose shape is not the contracted one
// falls back to the generic key:value lines rather than printing nothing. A
// silently empty render would be a worse lie than an ugly one.
func TestResourceConflictLinesFallBackOnAnUncontractedShape(t *testing.T) {
	lines := detailLinesForCode("resource_conflict", json.RawMessage(`{"conflicts":"not-an-array"}`))
	if len(lines) == 0 {
		t.Fatal("an uncontracted payload rendered NOTHING; want the generic fallback")
	}
	if !strings.Contains(strings.Join(lines, "\n"), "not-an-array") {
		t.Errorf("the fallback dropped the payload: %q", lines)
	}
}

// TestResourceConflictHintNamesTheRemedyAndRefusesTheWrongOne: the hint has to
// say the thing a `not_ready` hint must NOT say. A re-claim under your own
// worker id renews a lease and does nothing at all to a fence held by another
// row, so pointing at it here would be the "true but unactionable" refusal.
func TestResourceConflictHintNamesTheRemedyAndRefusesTheWrongOne(t *testing.T) {
	h := apiError{code: "resource_conflict"}.hint()
	if h == "" {
		t.Fatal("resource_conflict has no hint")
	}
	for _, want := range []string{"--resources", "hand off", "does NOT clear it"} {
		if !strings.Contains(h, want) {
			t.Errorf("hint %q is missing %q", h, want)
		}
	}
	// The server's own hint still wins where it sends one.
	if got := (apiError{code: "resource_conflict", serverHint: "server says"}).hint(); got != "server says" {
		t.Errorf("hint = %q, want the server's envelope hint to take precedence", got)
	}
}

// --- the claim wrapper must stand down on a resource_conflict ------------

// resourceConflictClaimServer is claimTestServer's sibling: the POST refuses
// with the LIVE resource_conflict body, and the read-back answers with an
// apparently-open, unheld row — which is exactly what the store legitimately
// holds, because the fence lives on a DIFFERENT row.
func resourceConflictClaimServer(t *testing.T) *int32 {
	t.Helper()
	var readBacks int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/claim"):
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(liveResourceConflictBody))
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/v1/data/doc/"):
			atomic.AddInt32(&readBacks, 1)
			body, _ := json.Marshal(map[string]any{"result": map[string]any{
				"_id": "task-x", "lifecycle_status": "open", "claim": nil,
			}})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalClaimManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "claim-stub")
	return &readBacks
}

// TestTaskClaimExecute_ResourceConflictDoesNotMisdiagnose is the sharp end.
//
// runTaskClaim fires on rc == exitConflict, and exit 6 is the WHOLE task
// claim/close contention row. Its read-back explains the reasons that are about
// the TARGET row's claim; resource_conflict is not one of them. So it read the
// target back, correctly found no holder, and announced:
//
//	"the store shows NO holder and an apparently-open row — this does not match
//	 a real conflict; likely the server-side predicate defect … not a legitimate
//	 refusal"
//
// over a refusal that was legitimate and whose holder the server had named in
// the same response. Measured live at rc=6 on both channels. Telling an operator
// that a working fence is a known server bug is worse than saying nothing.
func TestTaskClaimExecute_ResourceConflictDoesNotMisdiagnose(t *testing.T) {
	readBacks := resourceConflictClaimServer(t)
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict (%d); out:\n%s", code, exitConflict, out)
	}
	if n := atomic.LoadInt32(readBacks); n != 0 {
		t.Errorf("the claim-state read-back fired %d times on a resource_conflict; it explains a different refusal", n)
	}
	for _, banned := range []string{
		"does not match a real conflict",
		"not a legitimate refusal",
		"diagnosis: read-back",
	} {
		if strings.Contains(out, banned) {
			t.Errorf("output still carries the misdiagnosis %q:\n%s", banned, out)
		}
	}
	for _, want := range []string{"task-4b338a4dbe90d44d", "build-lane-j", "internal/cli/run.go"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not name %q — the remedy the server sent:\n%s", want, out)
		}
	}
}

// TestTaskClaimExecute_NotReadyStillDiagnoses is the CONTROL for the stand-down
// above: the wrapper must keep explaining the refusal it WAS built for. Gating
// on the code, not on "any exit 6", is what keeps both true at once.
func TestTaskClaimExecute_NotReadyStillDiagnoses(t *testing.T) {
	claimTestServer(t, map[string]any{
		"_id": "task-x", "lifecycle_status": "open",
		"claim": map[string]any{"worker": "other-worker", "epoch": 3},
	})
	out, code := captureExecuteCode(t, []string{"task", "claim", "task-x", "me"})
	if code != exitConflict {
		t.Fatalf("exit = %d, want exitConflict; out:\n%s", code, out)
	}
	if !strings.Contains(out, "diagnosis: read-back") || !strings.Contains(out, "held live by other-worker") {
		t.Errorf("the not_ready diagnosis was lost with the resource_conflict stand-down:\n%s", out)
	}
}
