package cli

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// THE GATE this file installs (task-d10d9eb47f2cc5e4).
//
// errors_api_parity_test.go pins codeExit against the API's PUBLIC ERROR
// VOCABULARY — Barkpark.Content.Errors.known_codes/0, the union of its @hints
// keys and @public_inline_codes. That gate is real, and it is BLIND to this
// family: a close/stamp refusal is never a Content.Errors code. It is an atom
// minted inside Barkpark.Tasks.Close / Barkpark.Tasks.Stamp, rendered by
// tasks_controller/params.ex reason_to_string/1, and answered by
// tasks_controller.ex conflict/3 as {"ok":false,"reason":"<token>"} — a body
// with no `error` object and no `code` field at all. Nothing in known_codes/0
// can see it, so nothing red when the vocabulary grew.
//
// TestCloseRefusalsAreInvisibleToTheKnownCodesGate below proves that blindness
// rather than asserting it.
//
// WHY AN ARM AND NOT A FIFTH HAND-ADDED ROW. Five reasons have now reached
// users at exit 2 — the malformed-command-line code — one at a time: four were
// swept on 2026-08-24 (criteria_unmet, invalid_lifecycle, sentinel_worker_id,
// merge_gated_criterion) and criteria_raised_on_abandon arrived AFTER that
// sweep, with PR #16891. A sweep fixes the members it can see today; the shape
// to expect is one more every time the server grows a refusal. So the authority
// here is the API's own source, the same way the parity gate does it, and the
// hand-kept part is only the list of reasons that deliberately never reach the
// wire as a reason token.
//
// SCOPE, stated rather than implied: this reads the two modules whose refusals
// the close and stamp routes pass through OPAQUELY — close.ex and stamp.ex —
// because that is where `{:error, …}` becomes a token the controller renders
// without inspecting it. Reasons minted deeper in the call graph (criteria.ex,
// internal.ex, the fences) reach the wire the same way but are not enumerated
// here; they stay covered by the enumerated rows in codeExit and by
// errors_close_taxonomy_test.go's dispatch probes. This arm makes the two
// files that mint the family self-proving, and says plainly what it does not
// reach.

// closeRefusalSourcePaths locates the two API modules by walking up from the
// test's working directory (internal/cli) to the repo root.
func closeRefusalSourcePaths(t *testing.T) []string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for i := 0; i < 8; i++ {
		// WHOLE-PATH literal runs on purpose. scripts/go-path-escape-check.sh
		// resolves a walk-up read from the run of >=3 adjacent string literals,
		// so joining a `tasks` DIRECTORY first and appending the basenames
		// afterwards censuses the read as the bare directory
		// `api/lib/barkpark/tasks` — a path no `…/tasks/**` glob in
		// go-tests.yml on.push.paths can match, which is a red on the ratchet.
		// Naming each file end-to-end makes the census say exactly what
		// go-tests.yml declares: the two .ex files, and nothing wider.
		closePath := filepath.Join(dir, "api", "lib", "barkpark", "tasks", "close.ex")
		stampPath := filepath.Join(dir, "api", "lib", "barkpark", "tasks", "stamp.ex")
		if _, err := os.Stat(closePath); err == nil {
			if _, err := os.Stat(stampPath); err == nil {
				return []string{closePath, stampPath}
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("could not locate api/lib/barkpark/tasks/{close,stamp}.ex above %s", dir)
	return nil
}

// closeRefusalRe matches the two literal shapes the modules mint:
//
//	{:error, :cancel_reason_required}      — a bare atom reason
//	{:error, {:criteria_unmet, indices}}   — a compound reason carrying detail
//
// The compound arm deliberately does not require the closing brace: the tuple's
// payload varies and may wrap a line. Both arms capture only the FAMILY name —
// the part before the ':' on the wire — which is the key reasonKey reduces a
// compound token to and the key codeExit must therefore hold.
//
// THE SEPARATOR IS `\s+`, NOT A LITERAL SPACE, and that is load-bearing
// (task-c674098c50ab054f). `mix format` wraps a tuple whose line exceeds the
// line length, and when it does the atom moves to the NEXT line:
//
//	{:error,
//	 :branch_only_evidence}
//
// A literal-space separator loses that reason entirely, in both directions: a
// NEW reason becomes silently unbucketed (TestCodeExitCoversCloseRefusalVocabulary
// greens while the reason reaches users at exit 2), and an EXISTING one is
// misreported as no longer minted (TestCloseRefusalExclusionsAreLiveReasons reds
// and tells you to delete a LIVE exclusion — correct in sign, wrong in
// diagnosis). Neither is caught by the plausibility floor below, which catches a
// total parse collapse, not one wrapped tuple. close.ex and stamp.ex happen to
// have no wrapped `{:error,` today; 102 lines across api/lib do, 12 of them in
// api/lib/barkpark/tasks/, so one added clause or one longer atom name is all it
// takes. Go's `\s` matches `\n`, which is exactly the whitespace that matters here.
var closeRefusalRe = regexp.MustCompile(`\{:error,\s+\{?:([a-z0-9_]+)`)

// closeRefusalReasons parses the refusal vocabulary out of close.ex + stamp.ex.
// It reads @doc prose as well as code on purpose: both are the module's own
// statement of what it can return, and a documented reason with no bucket is
// the same defect as an undocumented one.
func closeRefusalReasons(t *testing.T) map[string]bool {
	t.Helper()
	reasons := map[string]bool{}
	for _, path := range closeRefusalSourcePaths(t) {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		for _, m := range closeRefusalRe.FindAllStringSubmatch(string(raw), -1) {
			reasons[m[1]] = true
		}
	}

	// PLAUSIBILITY FLOOR, the same reasoning knownAPICodes uses: a parser that
	// stops matching (the modules renamed, the tuple shape reformatted) would
	// hand every assertion below an EMPTY set and green this whole file while
	// measuring nothing. 20 reasons existed when this gate landed; anything
	// under 12 means the PARSE broke, not that the server stopped refusing.
	if len(reasons) < 12 {
		t.Fatalf("parsed only %d refusal reasons from close.ex + stamp.ex — the PARSE is "+
			"broken, not the API. Check the `{:error, :atom}` / `{:error, {:atom, …}}` "+
			"literal shapes in api/lib/barkpark/tasks/{close,stamp}.ex", len(reasons))
	}
	return reasons
}

// closeRefusalNotOnTheWire: reasons close.ex/stamp.ex mint that this gate does
// NOT govern, because they never reach the caller as an
// {"ok":false,"reason":"<token>"} token minted by this family. An entry is a
// decision on the record, not a way to silence the gate: the test below
// requires a non-empty reason and refuses a name the modules no longer mint.
var closeRefusalNotOnTheWire = map[string]string{
	"branch_only_evidence": "never rendered by conflict/3 — tasks_controller.ex has a dedicated " +
		"clause ABOVE the generic {:error, reason} arm that answers it as a 400 bad_request " +
		"carrying Barkpark.Tasks.EvidenceDurability.message() (task-f6fba9a87369ce8e: evidence " +
		"that locates its proof on a BRANCH is a SHAPE refusal, not a state conflict). A 400 is " +
		"already exit 2 by the status rule, which is the right answer for a malformed payload.",
	"not_found": "the generic document-lookup atom, already bucketed in codeExit as a code (exit 4) " +
		"and never minted as a close/stamp reason token: the controller's find_task_by_doc_id " +
		"answers 404 before Tasks.Close is ever called.",
}

// THE GATE: every reason close.ex/stamp.ex can mint is either bucketed in
// codeExit or a NAMED, REASONED exclusion. There is no third state — the third
// state is exit 2, and exit 2 is what a typo produces.
func TestCodeExitCoversCloseRefusalVocabulary(t *testing.T) {
	reasons := closeRefusalReasons(t)

	var unbucketed []string
	for reason := range reasons {
		if _, ok := codeExit[reason]; ok {
			continue
		}
		if _, ok := closeRefusalNotOnTheWire[reason]; ok {
			continue
		}
		unbucketed = append(unbucketed, reason)
	}
	sort.Strings(unbucketed)

	if len(unbucketed) > 0 {
		t.Errorf("%d close/stamp refusal reason(s) have NO exit bucket, so they exit %d "+
			"(usage) — byte-identical to a malformed command line, which is the exact "+
			"confusion the 5/6 split exists to remove:\n  %s\n\n"+
			"Fix the TABLE in internal/cli/errors.go: exitValidation (5) when nothing moved "+
			"under the caller and re-sending the identical request can never succeed, "+
			"exitConflict (6) when the lease/rev/state moved and a re-read then a retry is the "+
			"right reflex. If the reason genuinely never reaches the wire as an "+
			"{\"ok\":false,\"reason\":…} token, add it to closeRefusalNotOnTheWire WITH the reason.",
			len(unbucketed), exitUsage, strings.Join(unbucketed, "\n  "))
	}
}

// An exclusion must name a reason the modules still mint. A stale entry is
// worse than none: it reads as a considered decision while silencing the gate
// for a token that no longer exists, and it would keep silencing it if the name
// were reused for something that DOES reach the wire.
func TestCloseRefusalExclusionsAreLiveReasons(t *testing.T) {
	reasons := closeRefusalReasons(t)
	for reason, why := range closeRefusalNotOnTheWire {
		if !reasons[reason] {
			t.Errorf("closeRefusalNotOnTheWire has %q (%q) but close.ex/stamp.ex no longer "+
				"mint it — delete the stale exclusion", reason, why)
		}
		if strings.TrimSpace(why) == "" {
			t.Errorf("closeRefusalNotOnTheWire[%q] has an empty reason — an unexplained "+
				"exclusion is the drift this gate exists to catch", reason)
		}
	}
}

// THE ANSWER to the question task-d10d9eb47f2cc5e4 said was never established:
// can TestCodeExitCoversKnownAPICodes see this family at all?
//
// It cannot, and this is the control that says so rather than assuming it.
// known_codes/0 is parsed from api/lib/barkpark/content/errors.ex; a close
// refusal is minted in api/lib/barkpark/tasks/*.ex and rendered by
// tasks_controller conflict/3. If a single member of the close/stamp vocabulary
// ever DID appear in known_codes/0, that would make the parity gate a partial
// guard here and this comment a lie — so the test asserts the disjointness
// directly. It also proves the arm above is not redundant: everything it
// governs is invisible to the gate beside it.
func TestCloseRefusalsAreInvisibleToTheKnownCodesGate(t *testing.T) {
	known := knownAPICodes(t)
	reasons := closeRefusalReasons(t)

	// The specimen that motivated the row: criteria_raised_on_abandon arrived
	// with PR #16891 and reached users at exit 2. If the parity gate could see
	// it, it would have red the moment the server grew it.
	if known["criteria_raised_on_abandon"] {
		t.Errorf("criteria_raised_on_abandon IS in known_codes/0 — the parity gate was not " +
			"blind to it after all, and the premise of this file needs re-reading")
	}

	var visible []string
	for reason := range reasons {
		if _, excluded := closeRefusalNotOnTheWire[reason]; excluded {
			// not_found is a Content.Errors code AND a lookup atom; its presence
			// in known_codes/0 says nothing about this family.
			continue
		}
		if known[reason] {
			visible = append(visible, reason)
		}
	}
	sort.Strings(visible)
	if len(visible) > 0 {
		t.Errorf("%d close/stamp refusal reason(s) are ALSO in known_codes/0: %s\n"+
			"The two vocabularies were believed disjoint. If they are not, the parity gate "+
			"partially covers this family and the scope note at the top of this file is wrong.",
			len(visible), strings.Join(visible, ", "))
	}
}
