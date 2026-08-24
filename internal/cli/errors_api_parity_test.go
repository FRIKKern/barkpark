package cli

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// THE GATE this row exists to install (task-2a774c5536503306).
//
// `codeExit` keys the CLI's process exit code on the envelope `code` string and
// NEVER on the HTTP status (the contract-spine rule at the top of errors.go).
// That rule is safe ONLY while codeExit is a SUPERSET of what the API can emit.
// It silently stopped being one: 61 of the API's 81 public codes were absent,
// so every one of them exited 1 (generic), and `mfa_required` — a 401 the JS
// SDK classifies correctly as an auth failure — looked to a shell script
// exactly like a network timeout.
//
// It drifted because nothing pinned the two vocabularies together. There ARE
// contract tests pinning `known_codes/0` against the OpenAPI enum and against
// docs/api-v1.md §9, and a reverse test pinning that every emitted code is a
// member. There was NO test pinning it against the CLI. `codeExit` mirrored the
// DOC's per-code table, so every code the API grew after that table was written
// was invisible here.
//
// This test reads the API's own source as the authority. It is deliberately not
// a hand-kept list: a hand-kept list is the thing that drifted.

// apiErrorsSourcePath locates api/lib/barkpark/content/errors.ex by walking up
// from the test's working directory (internal/cli) to the repo root.
func apiErrorsSourcePath(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for i := 0; i < 8; i++ {
		candidate := filepath.Join(dir, "api", "lib", "barkpark", "content", "errors.ex")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("could not locate api/lib/barkpark/content/errors.ex above %s", dir)
	return ""
}

var (
	// `"code" =>` inside the @hints map.
	hintKeyRe = regexp.MustCompile(`"([a-z0-9_]+)"\s*=>`)
	// A bare `"code"` string inside the @public_inline_codes MapSet list.
	inlineCodeRe = regexp.MustCompile(`"([a-z0-9_]+)"`)
)

// sliceBetween returns the source between `open` and the first line that is
// exactly `close` (at the module attribute's indentation), i.e. one attribute's
// literal. It returns "" when the anchor is absent, and the caller's
// plausibility floor turns that into a LOUD failure rather than a green zero.
func sliceBetween(src, open, close string) string {
	i := strings.Index(src, open)
	if i < 0 {
		return ""
	}
	rest := src[i+len(open):]
	j := strings.Index(rest, close)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

// knownAPICodes parses `Barkpark.Content.Errors.known_codes/0` out of the API
// source: the union of the @hints keys and @public_inline_codes.
func knownAPICodes(t *testing.T) map[string]bool {
	t.Helper()
	raw, err := os.ReadFile(apiErrorsSourcePath(t))
	if err != nil {
		t.Fatalf("read errors.ex: %v", err)
	}
	src := string(raw)

	codes := map[string]bool{}
	for _, m := range hintKeyRe.FindAllStringSubmatch(sliceBetween(src, "@hints %{", "\n  }"), -1) {
		codes[m[1]] = true
	}
	for _, m := range inlineCodeRe.FindAllStringSubmatch(
		sliceBetween(src, "@public_inline_codes MapSet.new([", "])"), -1) {
		codes[m[1]] = true
	}

	// PLAUSIBILITY FLOOR. A parser that stops matching (an attribute renamed, a
	// formatter changing the closing indentation) would otherwise hand every
	// assertion below an EMPTY set and green the whole file while measuring
	// nothing — the vacuous-green trap this repo has been bitten by. 81 codes
	// existed when this gate landed; anything under 60 means the parse broke,
	// not that the API shrank by a quarter.
	if len(codes) < 60 {
		t.Fatalf("parsed only %d codes from errors.ex — the PARSE is broken, not the API. "+
			"Check the @hints / @public_inline_codes anchors in "+
			"api/lib/barkpark/content/errors.ex", len(codes))
	}
	return codes
}

// The gate: every public API code must be bucketed here, or be a NAMED and
// REASONED exclusion. There is no third state — "nobody noticed" is what this
// test abolishes.
func TestCodeExitCoversKnownAPICodes(t *testing.T) {
	known := knownAPICodes(t)

	var unregistered []string
	for code := range known {
		if _, ok := codeExit[code]; ok {
			continue
		}
		if _, ok := codeExitNotWireBucketable[code]; ok {
			continue
		}
		unregistered = append(unregistered, code)
	}
	sort.Strings(unregistered)

	if len(unregistered) > 0 {
		t.Errorf("%d API error code(s) in known_codes/0 have NO exit bucket, so they "+
			"exit 1 (generic) — indistinguishable from a network timeout:\n  %s\n\n"+
			"Fix the TABLE, not the reader: add each to codeExit in internal/cli/errors.go "+
			"with the bucket its HTTP status implies (400->usage, 401/403->auth, 404->not-found, "+
			"409/412->conflict, 402/413/422->validation, 429->rate-limit, 5xx->server). If a code "+
			"genuinely cannot be bucketed on the wire, add it to codeExitNotWireBucketable WITH "+
			"the reason.",
			len(unregistered), strings.Join(unregistered, "\n  "))
	}
}

// An exclusion must be a real code. A stale entry here is worse than none: it
// looks like a considered decision while silencing the gate for a token the API
// no longer emits, and it would keep silencing it if the name were ever reused.
func TestCodeExitExclusionsAreLiveAPICodes(t *testing.T) {
	known := knownAPICodes(t)
	for code, reason := range codeExitNotWireBucketable {
		if !known[code] {
			t.Errorf("codeExitNotWireBucketable has %q (%q) but it is NOT in known_codes/0 — "+
				"delete the stale exclusion", code, reason)
		}
		if strings.TrimSpace(reason) == "" {
			t.Errorf("codeExitNotWireBucketable[%q] has an empty reason — an unexplained "+
				"exclusion is the drift this gate exists to catch", code)
		}
	}
}

// A code cannot be both bucketed and excluded — that reads as a decision made
// twice, in opposite directions, and the map lookup order would decide which
// one wins.
func TestCodeExitAndExclusionsAreDisjoint(t *testing.T) {
	for code := range codeExitNotWireBucketable {
		if exit, ok := codeExit[code]; ok {
			t.Errorf("%q is in BOTH codeExit (exit %d) and codeExitNotWireBucketable", code, exit)
		}
	}
}

// The row's own motivating table, asserted end to end through exitForCode.
// These are the cases where the CLI and the JS SDK gave DIFFERENT answers to
// the SAME response — the SDK was right in every one.
func TestCodeExitAgreesWithSDKClassification(t *testing.T) {
	cases := []struct {
		code string
		want int
		why  string
	}{
		{"mfa_required", exitAuth, "401; SDK: BarkparkAuthError. A script branching on exit 3 to re-auth never fired"},
		{"mfa_enrolment_required", exitAuth, "403; SDK: BarkparkAuthError"},
		{"workspace_suspended", exitAuth, "403; SDK: BarkparkAuthError"},
		{"webhook_not_found", exitNotFound, "404; SDK: BarkparkNotFoundError"},
		{"event_not_found", exitNotFound, "404; SDK: BarkparkNotFoundError"},
		{"label_spine", exitValidation, "422; SDK: BarkparkValidationError"},
		{"unknown_tag", exitValidation, "422; SDK: BarkparkValidationError"},
		{"invalid_paper_structure", exitValidation, "422; SDK: BarkparkValidationError"},
		{"invalid_epic_paper_quality", exitValidation, "422; SDK: BarkparkValidationError"},
		{"unsupported_media_type", exitValidation, "422; SDK: BarkparkValidationError"},
		{"payload_too_large", exitValidation, "413; a retry of the same body can never succeed"},
		{"duplicate_task", exitConflict, "409; SDK: BarkparkConflictError"},
		{"duplicate_of", exitConflict, "409; SDK: BarkparkConflictError"},
		{"idempotency_key_in_use", exitConflict, "409; SDK: BarkparkConflictError"},
		{"schema_has_documents", exitConflict, "409; SDK: BarkparkConflictError"},
		{"workspace_slug_conflict", exitConflict, "409; SDK: BarkparkConflictError"},
		{"import_constraint_violation", exitConflict, "409; SDK: BarkparkConflictError"},
		{"blob_path_conflict", exitConflict, "409; SDK: BarkparkConflictError"},
		{"storage_unavailable", exitServer, "503; the one class where retry IS the right reflex"},
		{"runtime_capacity", exitServer, "503"},
		{"deploy_runner_unavailable", exitServer, "503"},
		{"insufficient_disk_space", exitServer, "507"},
		{"import_failed", exitServer, "500"},
	}
	for _, c := range cases {
		if got := exitForCode(c.code); got != c.want {
			t.Errorf("exitForCode(%q) = %d, want %d (%s)", c.code, got, c.want, c.why)
		}
	}
}

// THE NEGATIVE ARM. Backfilling a table is exactly the change that quietly
// turns "unknown" into a confident wrong answer, so the fallback must survive:
// a code nobody maps still exits 1, and the ambiguous-status codes stay there
// ON PURPOSE rather than being handed a bucket the API cannot justify.
func TestUnmappedAndAmbiguousCodesStillFallToGeneric(t *testing.T) {
	if got := exitForCode("a_code_the_api_has_never_emitted"); got != exitGeneric {
		t.Errorf("unknown code exit = %d, want exitGeneric (%d) — the fallback must survive "+
			"the backfill", got, exitGeneric)
	}
	// One code, two statuses, two retryability contracts. Handing these a bucket
	// would be a false certainty: exit 8 spins a wrapper forever on the
	// permanent arm, exit 5 abandons a recoverable one.
	for _, code := range []string{"export_failed", "invalid_mode", "session_unavailable"} {
		if got := exitForCode(code); got != exitGeneric {
			t.Errorf("exitForCode(%q) = %d, want exitGeneric (%d) — this code is "+
				"status-ambiguous in the API and must NOT be given a bucket until the "+
				"API disambiguates it", code, got, exitGeneric)
		}
	}
}

// The pre-existing buckets must not have moved. A backfill that reshuffles the
// 20 codes that already worked has traded a silent under-report for a silent
// regression.
func TestBackfillDidNotMoveExistingBuckets(t *testing.T) {
	for code, want := range map[string]int{
		"not_found":         exitNotFound,
		"schema_unknown":    exitNotFound,
		"share_expired":     exitNotFound,
		"unauthorized":      exitAuth,
		"forbidden":         exitAuth,
		"forbidden_field":   exitAuth,
		"cors_forbidden":    exitAuth,
		"csrf_required":     exitAuth,
		"no_team":           exitGeneric,
		"malformed":         exitUsage,
		"invalid_filter":    exitUsage,
		"validation_failed": exitValidation,
		"rev_mismatch":      exitConflict,
		"conflict":          exitConflict,
		"halted":            exitConflict,
		"rate_limited":      exitRateLimit,
		"internal_error":    exitServer,
	} {
		if got := exitForCode(code); got != want {
			t.Errorf("exitForCode(%q) = %d, want %d — a pre-existing bucket MOVED", code, got, want)
		}
	}
}
