package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestNoRetryIsAGlobalFlag(t *testing.T) {
	g, rest, err := parseGlobals([]string{"doc", "query", "post", "--no-retry", "-o", "json"})
	if err != nil {
		t.Fatal(err)
	}
	if !g.noRetry {
		t.Fatal("--no-retry did not set globals.noRetry")
	}
	if len(rest) != 3 {
		t.Fatalf("rest = %q: --no-retry leaked to the command runner", rest)
	}
	found := false
	for _, f := range completionGlobals {
		if f == "--no-retry" {
			found = true
		}
	}
	if !found {
		t.Error("--no-retry is missing from completionGlobals")
	}
}

// With --no-retry a throttled manifest dispatch reaches the server once and
// exits 7 (rate_limited) with the server's envelope, instead of being retried
// underneath a caller that backs off on its own.
func TestNoRetrySendsAThrottledReadOnce(t *testing.T) {
	apiclient.SetNoRetry(true)
	t.Cleanup(func() { apiclient.SetNoRetry(false) })

	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Retry-After", "1")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"code":"rate_limited","message":"too many requests","details":{"retry_after":1}}}`))
	}))
	t.Cleanup(srv.Close)

	cmd := docQueryCommand()
	m := &manifest.Manifest{Commands: []manifest.Command{cmd}}
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{output: "json", outputSet: true, noRetry: true}
	out.applyGlobals(g)

	start := time.Now()
	code := runCommand(out, g, manifest.Context{Server: srv.URL, Dataset: "production"}, m, cmd, []string{"post"})
	if code != exitRateLimit {
		t.Fatalf("exit = %d, want %d (rate_limited); stderr=%q", code, exitRateLimit, stderr.String())
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("server hits = %d, want 1", got)
	}
	if time.Since(start) > 900*time.Millisecond {
		t.Fatalf("took %s: the 1s Retry-After was waited out", time.Since(start))
	}
}

// The task ledger write retry also stands down: one send, no read-back.
func TestNoRetrySendsALedgerWriteOnce(t *testing.T) {
	t.Setenv("BARKPARK_NO_RETRY", "1")
	sends, readbacks := 0, 0
	lw := &ledgerWrite{
		verb:   "close",
		sleep:  func(time.Duration) {},
		notify: func(string) {},
		readback: func() ledgerLandedVerdict {
			readbacks++
			return ledgerLandedVerdict{state: ledgerLandedNo}
		},
		send: func() (int, []byte, string, http.Header, error) {
			sends++
			return 503, []byte(`{"ok":false}`), "application/json", nil, nil
		},
	}
	status, _, _, _ := sendLedgerWrite(&manifestRequest{ledger: lw})
	if status != 503 {
		t.Fatalf("status = %d, want the 503 handed back", status)
	}
	if sends != 1 || readbacks != 0 {
		t.Fatalf("sends=%d readbacks=%d, want 1 and 0", sends, readbacks)
	}
}
