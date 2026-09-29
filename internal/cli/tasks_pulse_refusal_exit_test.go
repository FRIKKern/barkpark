package cli

// tasks_pulse_refusal_exit_test.go — THE PULSE REFUSAL EXIT-CODE MATRIX
// (task-99524dd65648a572).
//
// THE CLAIM THIS FILE SETTLES. It was reported that `bp task pulse` prints the
// server's full refusal paragraph and then EXITS 0, so a keep-alive loop that
// checks the exit code renews nothing while looking healthy. Measured through
// the real dispatch below, that is FALSE on this tree: every refusal arm exits
// non-zero, and the tasks 409 family (not_holder / not_in_progress:<status>)
// exits 6, distinct from a transport failure (1) and a 5xx (8).
//
// WHY IT IS PINNED ANYWAY. The claim was cheap to believe because nothing
// mechanical contradicted it: the property lived in three places that never met
// — codeExit's `not_holder`/`not_in_progress` rows (internal/cli/errors.go),
// reasonKey's colon split that makes `not_in_progress:done` find the family row,
// and runTaskPulse's early `rc != exitOK && rc != exitServer` return. Drop any
// one of them and the pulse starts reporting a lost claim as a success. The
// cells below fail on exactly that.
//
// WHAT "LIVE" MEANS HERE, and what it does NOT cover. A real HTTP server on
// loopback (httptest) speaking the real wire shapes, driven through the real
// CLI path — parseGlobals → manifest dispatch → the actual POST → the read-back
// → renderPulseVerdict. Nothing inside internal/cli is stubbed; only the far
// side of the socket is. It does NOT prove the SERVER refuses a reaped or
// stolen claim — that half lives in Elixir (api/lib/barkpark/tasks/pulse.ex and
// its tests); the two halves meet at the 409 body shape transcribed below,
// which is what api/lib/barkpark_web/controllers/tasks_controller.ex's
// `conflict(conn, reason, :pulse)` emits.

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// pulseRefusalServer answers the pulse POST with one transcribed refusal (or
// commits, when refuseReason is empty) and always serves the row back on GET.
type pulseRefusalServer struct {
	refuseReason string // "" = the write is permitted
	posts        int32
	nowStored    atomic.Value // string: what the store actually holds
}

func (s *pulseRefusalServer) start(t *testing.T) {
	t.Helper()
	s.nowStored.Store("")
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/pulse"):
			atomic.AddInt32(&s.posts, 1)
			if s.refuseReason != "" {
				// The tasks controller's 409: {"ok":false,"reason":…,"message":…},
				// the message being Params.criteria_hint({:not_in_progress, st}, :pulse).
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"reason":"` + s.refuseReason +
					`","message":"this row is done, not in_progress — a pulse renews a LIVE claim, and this row no longer has one. Nothing was written."}`))
				return
			}
			s.nowStored.Store(r.URL.Query().Get("now"))
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-p"}}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			now := ""
			if v, _ := s.nowStored.Load().(string); v != "" {
				now = `,"now":{"text":"` + v + `","ts":"2026-09-13T10:00:00Z"}`
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-p","status":"published",` +
				`"lifecycle_status":"in_progress","content":{},` +
				`"claim":{"worker":"w","epoch":4` + now + `}}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(be.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalClosePulseManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", be.URL)
	t.Setenv("BARKPARK_API_TOKEN", "pulse-refusal-stub")
}

const pulseRefusalNowLine = "settling the pulse exit code"

// TestTaskPulseRefusalExitsNonZeroWithAConflictCode is the detector. Each cell
// names the EXACT code, never merely "non-zero": the row asks for a refusal to
// be distinguishable from a transport error, and only an exact code proves that.
func TestTaskPulseRefusalExitsNonZeroWithAConflictCode(t *testing.T) {
	cases := []struct {
		name     string
		reason   string
		wantCode int
		why      string
	}{
		{
			name:     "row-moved-not-in-progress",
			reason:   "not_in_progress:done",
			wantCode: exitConflict,
			why:      "the row was closed/reaped under the loop — the compound token finds the codeExit family row through reasonKey's colon split",
		},
		{
			name:     "claim-stolen-not-holder",
			reason:   "not_holder:another-worker",
			wantCode: exitConflict,
			why:      "the live claim belongs to someone else — the refusal the report said exits 0",
		},
		{
			name:     "bare-not-holder",
			reason:   "not_holder",
			wantCode: exitConflict,
			why:      "the uncompounded token must land on the same code as its compound form, or one refusal means two exits",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := &pulseRefusalServer{refuseReason: c.reason}
			s.start(t)

			out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-p", "w", "--now", pulseRefusalNowLine})

			if code == exitOK {
				t.Fatalf("a REFUSED pulse exited 0 — a loop checking the exit code renews nothing and looks healthy; out:\n%s", out)
			}
			if code != c.wantCode {
				t.Fatalf("exit = %d, want %d (%s); out:\n%s", code, c.wantCode, c.why, out)
			}
			if n := atomic.LoadInt32(&s.posts); n != 1 {
				t.Fatalf("pulse POST fired %d times, want 1", n)
			}
			// The machine-readable half, which is the thing a loop should read.
			if !strings.Contains(out, "pulse_receipt confirmed=false reason="+c.reason) {
				t.Errorf("receipt should name the refusal reason beside confirmed=false; got:\n%s", out)
			}
			if strings.Contains(out, "confirmed=true") {
				t.Errorf("a refusal printed confirmed=true; got:\n%s", out)
			}
		})
	}
}

// The CONTROL, and it is the other direction of the same property: the fix must
// not turn a genuinely landed pulse into a non-zero exit. A green here with a
// red above is the only shape that means anything.
func TestTaskPulseSuccessStillExitsZeroAndSaysSoMachineReadably(t *testing.T) {
	s := &pulseRefusalServer{}
	s.start(t)

	out, code := captureExecuteCode(t, []string{"task", "pulse", "bp-task-p", "w", "--now", pulseRefusalNowLine})

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK — the store holds the now-line this invocation sent; out:\n%s", code, out)
	}
	if got, _ := s.nowStored.Load().(string); got != pulseRefusalNowLine {
		t.Fatalf("the STORE holds %q, want %q — the control must be measured off the server's own state", got, pulseRefusalNowLine)
	}
	if !strings.Contains(out, "pulse_receipt confirmed=true epoch=4 exit=0") {
		t.Errorf("a confirmed pulse must carry the machine-readable receipt with the NEW epoch; got:\n%s", out)
	}
	// The prose success signal a loop may still be matching on today. Both
	// success shapes print this line — the 5xx-but-committed wording is an extra
	// PREAMBLE line above it, never an alternative to it — so a matcher on this
	// sentence scores both as success.
	if !strings.Contains(out, "the store holds it") {
		t.Errorf("the human success sentence changed shape; got:\n%s", out)
	}
}
