package cli

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// THE DEFECT THIS RETIRES (task-f91736adabf14e13).
//
// Three API error codes were emitted at TWO different HTTP statuses with
// OPPOSITE retryability contracts:
//
//	export_failed        503 workspace bundle export (retryable by design)
//	                     422 sheets xlsx build       (permanent)
//	invalid_mode         422 workspace bundle-import mode
//	                     400 site-deploy mode        (two unrelated features)
//	session_unavailable  503 sheets session crash loop (retry-after: 2)
//	                     422 sheets session could not start
//
// The CLI keys its exit code on the envelope `code` string and NEVER on the
// HTTP status — a deliberate contract rule, so one token cannot mean two exits
// depending on which shape carried it. These three broke that rule's premise:
// no single exit is honest about both arms. Exit 8 (server) tells a retry
// wrapper to retry, spinning forever on the permanent arm; exit 5 (validation)
// tells it to give up, abandoning a recoverable bundle export. So they were
// parked at exit 1 in codeExitNotWireBucketable — true ("unknown") but a
// placeholder, not a resolution.
//
// The fix is in the API and it is a SPLIT, not a re-status: each arm gets its
// own code, so the token carries one meaning. These tests pin that outcome from
// both sides.

// retiredAmbiguousCodes must never come back — not in codeExit (which would
// manufacture a false certainty) and not in the exclusions map (which would be
// re-parking a defect the API has already fixed).
var retiredAmbiguousCodes = []string{"export_failed", "invalid_mode", "session_unavailable"}

func TestRetiredAmbiguousCodesAreGoneFromBothTables(t *testing.T) {
	for _, code := range retiredAmbiguousCodes {
		if exit, ok := codeExit[code]; ok {
			t.Errorf("%q is back in codeExit (exit %d) — it answered two statuses with opposite "+
				"retryability, so no single exit can be honest about it; split it in the API instead",
				code, exit)
		}
		if reason, ok := codeExitNotWireBucketable[code]; ok {
			t.Errorf("%q is back in codeExitNotWireBucketable (%q) — the API split it, so it should "+
				"no longer exist as a wire code at all", code, reason)
		}
	}
}

// Each replacement carries EXACTLY ONE meaning, so it buckets by retryability:
// the transient arm to exitServer (a wrapper may retry), the permanent arm to
// exitValidation (a wrapper must not).
func TestSplitCodesBucketByRetryability(t *testing.T) {
	want := map[string]int{
		"export_transport_failed": exitServer,     // 503, bundle export transport
		"session_restarting":      exitServer,     // 503 + retry-after, session crash loop
		"export_build_failed":     exitValidation, // 422, xlsx build — permanent
		"session_start_failed":    exitValidation, // 422, session could not start
		"invalid_import_mode":     exitValidation, // 422, bundle-import mode
		"invalid_deploy_mode":     exitValidation, // 400, site-deploy mode
	}

	for code, wantExit := range want {
		got, ok := codeExit[code]
		if !ok {
			t.Errorf("%q missing from codeExit — a split arm that is not bucketed exits 1, which is "+
				"exactly the placeholder the split was meant to remove", code)
			continue
		}
		if got != wantExit {
			t.Errorf("codeExit[%q] = %d, want %d", code, got, wantExit)
		}
	}

	// The two arms of each pair must not agree — an identical exit would mean
	// the split bought nothing.
	pairs := [][2]string{
		{"export_transport_failed", "export_build_failed"},
		{"session_restarting", "session_start_failed"},
	}
	for _, p := range pairs {
		if codeExit[p[0]] == codeExit[p[1]] {
			t.Errorf("%q and %q share exit %d — the split exists precisely because one arm is "+
				"retryable and the other is not", p[0], p[1], codeExit[p[0]])
		}
	}
}

// The API must no longer EMIT the retired tokens, and must register every
// replacement in known_codes/0 (otherwise the parity gate cannot see them).
func TestAPISourceNoLongerEmitsRetiredCodes(t *testing.T) {
	// apiErrorsSourcePath (errors_api_parity_test.go) already walks up to the
	// repo root to find api/lib/barkpark/content/errors.ex; reuse it rather
	// than hand-keeping a second path walker.
	root := strings.TrimSuffix(apiErrorsSourcePath(t), "/api/lib/barkpark/content/errors.ex")

	for _, code := range retiredAmbiguousCodes {
		for _, lit := range []string{`code: "` + code + `"`, `, "` + code + `"`} {
			if hits := grepAPILib(t, root, lit); len(hits) > 0 {
				t.Errorf("api/lib still emits the retired code %q as %s:\n  %s",
					code, lit, strings.Join(hits, "\n  "))
			}
		}
	}

	known := knownAPICodes(t)
	for code := range map[string]struct{}{
		"export_transport_failed": {}, "export_build_failed": {},
		"invalid_import_mode": {}, "invalid_deploy_mode": {},
		"session_restarting": {}, "session_start_failed": {},
	} {
		if _, ok := known[code]; !ok {
			t.Errorf("%q is not in known_codes/0 — an unregistered code is invisible to the "+
				"OpenAPI enum and to the codeExit parity gate", code)
		}
	}
}

func grepAPILib(t *testing.T, root, literal string) []string {
	t.Helper()
	var hits []string
	libDir := root + "/api/lib"
	err := walkExFiles(libDir, func(path string, body []byte) {
		for i, line := range strings.Split(string(body), "\n") {
			if strings.Contains(line, literal) {
				hits = append(hits, path[len(root)+1:]+":"+strconv.Itoa(i+1))
			}
		}
	})
	if err != nil {
		t.Fatalf("walk %s: %v", libDir, err)
	}
	return hits
}

func walkExFiles(dir string, fn func(path string, body []byte)) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		p := dir + "/" + e.Name()
		if e.IsDir() {
			if err := walkExFiles(p, fn); err != nil {
				return err
			}
			continue
		}
		if !strings.HasSuffix(e.Name(), ".ex") {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		fn(p, b)
	}
	return nil
}
