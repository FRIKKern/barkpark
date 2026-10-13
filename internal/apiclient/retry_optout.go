// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// TURNING THE AUTOMATIC RETRIES OFF.
//
// bp retries a throttled request (429) up to four times and a transient
// internal_error 500 on a read up to three times. That is the right default
// for a person at a terminal. It is wrong for a caller that paces itself: an
// importer that already sleeps on Retry-After and counts its own attempts gets
// its waits multiplied by the retries underneath it, and cannot tell how long
// one bp call will take. The twin import hit exactly this
// (task-33e5b203e987650c).
//
// So a caller can ask for every request to be sent ONCE: the global flag
// `--no-retry` (SetNoRetry) or the environment variable BARKPARK_NO_RETRY=1.
// Either one turns off this package's transport retries (the 429 and the 500
// paths), the cloud client's 429 retry, the manifest fetch's one 429 re-ask and
// the task ledger write retry. The response, 429 or 5xx, is handed back as the
// server sent it, so the exit code (7 for rate_limited, 8 for a 5xx) and the
// envelope's retry_after tell the caller what to do next.
//
// The default stays retrying. Both switches are opt-in.

// noRetryEnv is the environment spelling. Any value other than "", "0",
// "false" or "no" turns retries off, so BARKPARK_NO_RETRY=1 and
// BARKPARK_NO_RETRY=true both work and BARKPARK_NO_RETRY=0 means "retry".
const noRetryEnv = "BARKPARK_NO_RETRY"

var noRetryFlag atomic.Bool

// SetNoRetry records the `--no-retry` global flag for this process. The CLI
// calls it once per invocation with the parsed flag; false never overrides
// the environment variable.
func SetNoRetry(on bool) {
	noRetryFlag.Store(on)
}

// RetryDisabled reports whether the caller asked for every request to be sent
// once, by flag or by environment.
func RetryDisabled() bool {
	if noRetryFlag.Load() {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(os.Getenv(noRetryEnv))) {
	case "", "0", "false", "no":
		return false
	}
	return true
}

// ParseRetryAfter reads a Retry-After header value in both forms RFC 9110
// allows: delay-seconds ("3", and "1.5" for the servers that send a fraction)
// and an HTTP-date ("Wed, 21 Oct 2026 07:28:00 GMT"). It returns the wait in
// seconds. A date in the past is a wait of zero. An unparseable value reports
// false, and the caller treats it as no header at all.
//
// Barkpark's own rate-limit plugs send seconds. A proxy or CDN in front of an
// instance may send the date form, and reading it as "no header" would replace
// the server's wait with our one-second default.
func ParseRetryAfter(v string) (float64, bool) {
	return parseRetryAfterAt(v, time.Now())
}

func parseRetryAfterAt(v string, now time.Time) (float64, bool) {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0, false
	}
	if n, err := strconv.ParseFloat(v, 64); err == nil {
		return n, true
	}
	t, err := http.ParseTime(v)
	if err != nil {
		return 0, false
	}
	d := t.Sub(now)
	if d < 0 {
		return 0, true
	}
	return d.Seconds(), true
}
