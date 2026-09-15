package taskboard

// INSTRUMENTATION ONLY — NOT SHIPPED. Applied identically to the before and
// after arms so the two byte counts come from the same counter.

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

var (
	instrMu    sync.Mutex
	instrCalls = map[string]int{}
	instrBytes = map[string]int64{}
	instrPath  = os.Getenv("BP_TB_METRICS")
)

func instrRecord(path string, n int) {
	if instrPath == "" {
		return
	}
	bucket := path
	if i := strings.IndexByte(bucket, '?'); i >= 0 {
		bucket = bucket[:i]
	}
	instrMu.Lock()
	instrCalls[bucket]++
	instrBytes[bucket] += int64(n)
	var b strings.Builder
	for k := range instrCalls {
		fmt.Fprintf(&b, "%s n=%d bytes=%d\n", k, instrCalls[k], instrBytes[k])
	}
	instrMu.Unlock()
	if traceF != nil {
		traceMu.Lock()
		fmt.Fprintf(traceF, "%7.2f %9d %s\n", time.Since(traceT0).Seconds(), n, path)
		traceMu.Unlock()
	}
	_ = os.WriteFile(instrPath, []byte(b.String()), 0o644)
}

func init() {
	if p := os.Getenv("BP_TB_TRACE"); p != "" {
		traceF, _ = os.Create(p)
	}
}

var traceF *os.File
var traceMu sync.Mutex
var traceT0 = time.Now()
