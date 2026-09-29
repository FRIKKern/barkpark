package taskboard

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// wirelog.go is the board's BYTE COUNTER, landed rather than re-patched.
//
// task-1ca34359dc0805df's first acceptance criterion is a measurement — "an
// idle board pulls under 10 MB of /v1/tasks in 60 seconds, measured with the
// same instrumented byte counters and pty harness" — and until now those
// counters were a throwaway diff a worker applied, measured with, and threw
// away. That makes the number unreproducible by the next reader: nobody can
// re-run the measurement without first re-deriving the instrument, and an
// instrument re-derived per round is an instrument nobody checks.
//
// So the counter ships. It is OFF unless BARKPARK_TASKBOARD_WIRELOG names a
// file, it writes one tab-separated line per SUCCESSFUL snapshot fetch —
//
//	<RFC3339Nano ts>\t<path, query stripped>\t<body bytes>\t<limit=N, or "">
//
// The FOURTH column exists because the third could not answer the question the
// criterion actually asks. The board's cheap incremental head page and its
// ~11 MB exhaustive page are BOTH `/v1/tasks`, and stripping the query — which
// the second column must do, or a cursor walk scatters across thousands of
// distinct keys — collapses them into one row of the tally. So "did the
// incremental re-list arm?" was unanswerable from the log that exists to answer
// it, and a reader had to infer it from body size. The `limit` param is the
// discriminator the code already spells in one place (headPageLimitToken = 50
// vs taskListLimitToken = 1000), so the log records it verbatim.
//
// — and it never touches the fetch's own return path: a logging failure is
// dropped, because a measurement must not be able to fail the thing it
// measures. Query strings are stripped so a cursor-paged walk aggregates under
// one key (/v1/tasks) instead of scattering across thousands of cursor tokens.
//
// Read it with:
//
//	awk -F'\t' '{n[$2]++; b[$2]+=$3} END{for (p in n) printf "%s n=%d bytes=%d\n", p, n[p], b[p]}'
//
// or, splitting the corpus GET by page size:
//
//	awk -F'\t' '{k=$2" "$4; n[k]++; b[k]+=$3} END{for (p in n) printf "%s n=%d bytes=%d\n", p, n[p], b[p]}'
type wireLogger struct {
	mu sync.Mutex
	f  *os.File
}

var (
	wireLogOnce sync.Once
	wireLog     *wireLogger
)

// wireLogPathEnv is the single switch. Unset (or empty) means the counter does
// not exist: no file is opened and recordWire returns on its first branch.
const wireLogPathEnv = "BARKPARK_TASKBOARD_WIRELOG"

func wireLogger_() *wireLogger {
	wireLogOnce.Do(func() {
		dest := strings.TrimSpace(os.Getenv(wireLogPathEnv))
		if dest == "" {
			return
		}
		f, err := os.OpenFile(dest, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			// A measurement that cannot open its file measures nothing, but it
			// must not break the board it was pointed at.
			return
		}
		wireLog = &wireLogger{f: f}
	})
	return wireLog
}

// recordWire notes one successful fetch. Callers pass the raw path (with query)
// and the decoded body length.
func recordWire(path string, n int) {
	w := wireLogger_()
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	fmt.Fprintf(w.f, "%s\t%s\t%d\t%s\n", time.Now().UTC().Format(time.RFC3339Nano), wireLogKey(path), n, wireLogLimit(path))
}

// wireLogKey is the aggregation key: the path with its query string removed, so
// /v1/tasks?limit=50&cursor=<token> and /v1/tasks?limit=1000 are the same row
// in the tally. Without this a cursor walk emits one distinct key per page and
// the tally the criterion asks for cannot be computed at all.
func wireLogKey(path string) string {
	if i := strings.IndexByte(path, '?'); i >= 0 {
		return path[:i]
	}
	return path
}

// wireLogLimit is the fourth column: the request's own `limit` param, verbatim,
// spelled as `limit=<v>` so the column is self-describing in a log a human
// reads. A path with no limit (the events poll, prime) yields the empty string
// rather than a placeholder — an absent param is not a value, and writing one
// would put a number in the log that no request carried.
func wireLogLimit(path string) string {
	i := strings.IndexByte(path, '?')
	if i < 0 {
		return ""
	}
	for _, kv := range strings.Split(path[i+1:], "&") {
		if v, ok := strings.CutPrefix(kv, "limit="); ok {
			return "limit=" + v
		}
	}
	return ""
}
