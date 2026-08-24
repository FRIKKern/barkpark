package cli

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
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

// ---------------------------------------------------------------------------
// THE COMPLETENESS ARM (pds-w33-bl-publish-wall-codes-exit-1).
//
// TestCodeExitAgreesWithSDKClassification above is an ENUMERATED table, and an
// enumerated table drifts — that is the same failure this whole file exists to
// end, one level up. It was already drifting: it covered seven of the eight
// publish-wall codes and silently omitted `quota_exceeded`, so setting that
// code to exitServer (8) — the RETRY bucket, on a 402 that no retry can ever
// clear — passed the entire suite green. Coverage caught nothing because the
// code still HAD a bucket; only its value was wrong, and nothing asserted the
// value.
//
// This test derives the expected value instead of listing it. The authority is
// the same one the rest of the file uses: the API's own source. errors.ex
// states each code's HTTP status as a literal, and docs/cli/error-exit-table.md
// fixes the mapping from status to bucket ("Bucket by the status the emitter
// actually returns, never by the code's name: 400 → 2, 401/403 → 3, 404 → 4,
// 409/412 → 6, 402/413/422 → 5, 429 → 7, 5xx → 8"). Composing the two yields
// the contracted exit code for every code whose status is readable, with no
// hand-kept list to fall behind.
//
// It is deliberately NOT total: only the codes `Errors.build/1` emits carry a
// status literal here (29 of the 84 in known_codes/0). The rest are
// @public_inline_codes, emitted by controllers whose status lives at the call
// site. Those stay covered by the enumerated table and by the coverage gate.
// This arm makes the derivable majority self-proving and says plainly which
// codes it does not reach, rather than looking total and being partial.

// apiStatusRe and apiCodeRe read `code: "x"` / `status: 404` literals out of
// the Elixir source. `build/1` writes them either on one line
// (`%{code: "not_found", message: …, status: 404}`) or spread over a multi-line
// map, so the scan below handles both.
var (
	apiCodeRe   = regexp.MustCompile(`code: "([a-z0-9_]+)"`)
	apiStatusRe = regexp.MustCompile(`status: (\d+)`)
)

// apiCodeStatuses maps each code errors.ex emits to the HTTP status it emits it
// with. A code seen at TWO different statuses is a hard failure, not a silent
// pick: the doc's own ruling is that such a token must be SPLIT in the API
// (export_failed → export_transport_failed/export_build_failed, and two more),
// because no single exit code can be honest about both arms.
func apiCodeStatuses(t *testing.T) map[string]int {
	t.Helper()
	raw, err := os.ReadFile(apiErrorsSourcePath(t))
	if err != nil {
		t.Fatalf("read errors.ex: %v", err)
	}
	lines := strings.Split(string(raw), "\n")

	seen := map[string]map[int]bool{}
	for i, line := range lines {
		for _, m := range apiCodeRe.FindAllStringSubmatch(line, -1) {
			code := m[1]
			status := 0
			if sm := apiStatusRe.FindStringSubmatch(line); sm != nil {
				status, _ = strconv.Atoi(sm[1])
			} else {
				// Multi-line map literal: scan forward to this entry's status,
				// stopping at the next `code:` so we never borrow a sibling's.
				for j := i + 1; j < len(lines) && j < i+8; j++ {
					if apiCodeRe.MatchString(lines[j]) {
						break
					}
					if sm := apiStatusRe.FindStringSubmatch(lines[j]); sm != nil {
						status, _ = strconv.Atoi(sm[1])
						break
					}
				}
			}
			if status == 0 {
				continue
			}
			if seen[code] == nil {
				seen[code] = map[int]bool{}
			}
			seen[code][status] = true
		}
	}

	out := map[string]int{}
	for code, statuses := range seen {
		if len(statuses) > 1 {
			var got []int
			for s := range statuses {
				got = append(got, s)
			}
			sort.Ints(got)
			t.Errorf("errors.ex emits %q at %v — one code, two statuses, two "+
				"retryability contracts. No exit code can be honest about both "+
				"(8 spins a retry wrapper forever on the permanent arm; 5 abandons "+
				"a recoverable one). SPLIT THE TOKEN in the API, one code per arm, "+
				"the way export_failed and session_unavailable were split — do not "+
				"pick a winner here.", code, got)
			continue
		}
		for s := range statuses {
			out[code] = s
		}
	}

	// PLAUSIBILITY FLOOR, same reasoning as knownAPICodes: a parser that stops
	// matching would hand the loop below an EMPTY map and green it while
	// measuring nothing. 29 codes carried a status literal when this landed.
	if len(out) < 20 {
		t.Fatalf("parsed only %d code→status pairs from errors.ex — the PARSE is "+
			"broken, not the API. Check the `code:`/`status:` literal shapes in "+
			"api/lib/barkpark/content/errors.ex", len(out))
	}
	return out
}

// statusBucket is docs/cli/error-exit-table.md's contracted status→exit rule,
// transcribed. It is the MAINTAINER's rule for choosing a bucket once; the CLI
// itself still reads only error.code at runtime, never the status.
func statusBucket(status int) (int, bool) {
	switch {
	case status >= 500:
		return exitServer, true
	case status == 400:
		return exitUsage, true
	case status == 401, status == 403:
		return exitAuth, true
	case status == 404, status == 410:
		return exitNotFound, true
	case status == 409, status == 412:
		return exitConflict, true
	case status == 402, status == 413, status == 422:
		return exitValidation, true
	case status == 429:
		return exitRateLimit, true
	}
	return 0, false
}

// codeExitStatusRuleExceptions: codes whose contracted exit DELIBERATELY differs
// from what their status implies, each with the reason the doc gives. An entry
// here is a decision on the record, not a way to silence the gate — the test
// requires a non-empty reason, and asserts the exception's value just as
// strictly as it asserts the rule.
var codeExitStatusRuleExceptions = map[string]struct {
	exit   int
	reason string
}{
	"forbidden_field": {
		exit: exitAuth,
		reason: "422 on the wire but semantically an authorization failure — the caller " +
			"filtered or ordered over a field its token may not read. docs/cli/error-exit-table.md " +
			"lists it at exit 3 explicitly, noting it 'keys on code, not the 422': the remedy is a " +
			"different token, not a different payload, so the validation bucket would send a " +
			"script to fix the wrong thing.",
	},
}

// THE GATE: for every API code whose status errors.ex states, the CLI's exit
// code must be the one the doc's status rule contracts — or a NAMED exception.
// This is what the enumerated table could not do: it proves the value for every
// derivable code, including ones nobody remembered to list.
func TestCodeExitMatchesAPIStatusBucket(t *testing.T) {
	known := knownAPICodes(t)
	statuses := apiCodeStatuses(t)

	checked := 0
	for code, status := range statuses {
		if !known[code] {
			// Emitted internally but not part of the public vocabulary; the
			// coverage gate does not require a bucket for it either.
			continue
		}
		if _, excluded := codeExitNotWireBucketable[code]; excluded {
			continue
		}

		want, ok := statusBucket(status)
		if !ok {
			t.Errorf("errors.ex emits %q at HTTP %d, which docs/cli/error-exit-table.md's "+
				"status rule does not cover. Extend statusBucket AND the doc together — "+
				"an uncovered status is a contract hole, not a test gap.", code, status)
			continue
		}

		why := "its emitter answers " + strconv.Itoa(status)
		if exc, isException := codeExitStatusRuleExceptions[code]; isException {
			if strings.TrimSpace(exc.reason) == "" {
				t.Errorf("codeExitStatusRuleExceptions[%q] has an empty reason — an "+
					"unexplained exception is exactly the drift this gate exists to catch", code)
			}
			want = exc.exit
			why = "it is a NAMED exception to the status rule: " + exc.reason
		}

		if got := exitForCode(code); got != want {
			t.Errorf("exitForCode(%q) = %d, want %d — %s.\n\n"+
				"Fix the bucket in codeExit (internal/cli/errors.go), or — if the "+
				"difference is deliberate — add %q to codeExitStatusRuleExceptions WITH "+
				"the reason. Do not edit this test to match the code.",
				code, got, want, why, code)
		}
		checked++
	}

	// A second floor: the loop above must actually have asserted something. If
	// known_codes and the status scan ever stop overlapping, `checked` collapses
	// to 0 and every assertion becomes unreachable — green, and worthless.
	if checked < 20 {
		t.Errorf("only %d codes were value-checked (expected ~29) — known_codes/0 and the "+
			"errors.ex status literals have stopped overlapping, so this gate is no longer "+
			"measuring the thing it claims to measure", checked)
	}
}

// An exception must be a real, still-derivable code. A stale entry silences the
// rule for a token that no longer needs silencing — and would keep silencing it
// if the name were ever reused for something the rule SHOULD govern.
func TestCodeExitStatusExceptionsAreLive(t *testing.T) {
	statuses := apiCodeStatuses(t)
	for code := range codeExitStatusRuleExceptions {
		if _, ok := statuses[code]; !ok {
			t.Errorf("codeExitStatusRuleExceptions has %q but errors.ex no longer states a "+
				"status for it — delete the stale exception", code)
		}
	}
}
