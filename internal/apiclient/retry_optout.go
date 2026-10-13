// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"os"
	"strings"
	"sync/atomic"
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
