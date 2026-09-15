package cli

// tasks_claim_path_test.go — A CLAIM READ THAT LANDED ON THE WRONG SHAPE MUST
// REFUSE, NOT ANSWER "NOBODY HOLDS THIS".
//
// THE DEFECT THIS EXISTS FOR, measured 2026-09-15 on origin/main
// 7bc83e643b1ef4b53c1845be24eb54eee00ca9ac against the live store:
//
//	$ bp task ls --status in_progress -o json
//	rows ............................................ 25
//	.claim.worker non-null      (TRUE path) ......... 25
//	.doc.claim.worker non-null  (the get path) ......  0
//	rows carrying a `doc` key .......................   0
//
// 25 of 25 live claims read as absent, and nothing warned, because a missing
// key is not an error in any language these readers are written in. A uniform
// verdict is the signature of a broken instrument, and this one FAILS TOWARD A
// WRITE: "unclaimed" is the precondition for a release or a re-claim, so the
// sweep built on it steals rows another lane is working. This campaign's
// coordinator issued a fleet-wide order on that reading and retracted it.
//
// WHY NOT THE `task get` REMEDY. tasks_get_misread.go plants a `_misread`
// sentinel AT the wrong path. Transplanted here, that means giving a flat row a
// `doc` key it does not have — and presence-of-`doc` is the discriminator nine
// of this repo's own readers use to tell the two shapes apart (enumerated in
// tasks_claim_path.go's header, `scripts/ledger/claim-health.sh:92` and
// `scripts/lib/landed_open_report.py:100` among them). The sentinel would fix a
// hypothetical jq reader by corrupting nine real ones. So the wrong SHAPE
// refuses instead of the wrong PATH being made loud.
//
// WHAT IS ASSERTED HERE.
//
//  1. c2 — the guard cannot pass vacuously: a non-zero row count is asserted,
//     and empty input, invalid JSON, a missing/non-list rows key, a `bp doc ls`
//     payload (keyed `documents`), and a zero-row page all REFUSE with
//     ErrReadyPageUnreadable / `CANNOT READ:` rather than reporting zero claims.
//  2. c3 — SYMMETRY AS A PREDICATE OVER THE VERB SET, not a hand-listed pair:
//     for EVERY verb in taskReadShapes(), its own fixture yields a verdict, and
//     EVERY other verb's shape applied to that fixture REFUSES and names it.
//     The fixture table is asserted to cover the shape map exactly, so a fifth
//     read shape cannot be added silently — the test reds naming the verb.
//  3. The POSITIVE CONTROL: the pre-fix reading — plain path-walking, no
//     refusal — is run over the same fixtures and required to produce the
//     silent uniform NOCLAIM. If it ever stops doing so, these assertions are
//     vacuous and that test reds instead of this file going quietly green.

import (
	"bytes"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// taskClaimFixtures is a payload per read verb, each a reduced but SHAPE-EXACT
// slice of what that verb really answered on 2026-09-15, and each carrying at
// least one LIVE CLAIM — a fixture with nobody on it would satisfy every
// assertion below for the wrong reason and prove nothing about the misread.
func taskClaimFixtures() map[string]string {
	return map[string]string{
		// `bp task get <id> -o json` — ONE row, nested under `doc`.
		taskGetCommandID: `{"ok":true,"doc":{
			"doc_id":"task-798c0080cab955a3","lifecycle_status":"in_progress",
			"claim":{"epoch":2,"worker":"lead-studio-10","ts_iso":"2026-09-06T00:49:27Z"},
			"content":{"description":"a live claimed row"}}}`,

		// `bp task ls --status in_progress -o json` — FLAT rows under `docs`.
		// Note the `content` key: the full view carries one, and it does NOT
		// hold the claim. `.content.claim` is a THIRD wrong path, and it is the
		// one scripts/ledger/claim-health.sh:92 actually reads (0 of 25 live).
		taskLsCommandID: `{"ok":true,"page":{"limit":25},"docs":[
			{"doc_id":"task-1","title":"one","lifecycle_status":"in_progress",
			 "claim":{"epoch":1,"worker":"cli-r18-w8","ts_iso":"2026-09-15T00:00:00Z"},
			 "content":{"description":"no claim in here"}},
			{"doc_id":"task-2","title":"two","lifecycle_status":"in_progress",
			 "claim":{"epoch":3,"worker":"lead-cli-r18","ts_iso":"2026-09-15T00:01:00Z"},
			 "content":{"description":"nor here"}}]}`,

		// `bp task ready -o json` — FLAT rows under `docs`, and a ready row with
		// nobody on it OMITS `claim` ENTIRELY. Both arms are present on purpose:
		// key-absent is NOT the same fact as worker-null, and a reader that
		// conflates them cannot tell "unclaimed" from "wrong path".
		taskReadyCommandID: `{"ok":true,"page":{"limit":25},"docs":[
			{"doc_id":"task-3","title":"three","priority":0,"criteria_met":1,"criteria_total":3},
			{"doc_id":"task-4","title":"four","priority":1,
			 "claim":{"epoch":1,"worker":"probe-opus-r13","ts_iso":"2026-09-15T00:02:00Z"}}]}`,

		// `bp task prime -o json` — THE THIRD SHAPE. Flat rows like ls, but
		// under `in_progress` and `ready`, with NO `docs` key at all: a reader
		// generalised from `ready` reads zero rows out of it.
		taskPrimeCommandID: `{"ok":true,"worker":"cli-r18-w8","counts":{"open":4},
			"in_progress":[{"doc_id":"task-5","title":"five",
			 "claim":{"epoch":2,"worker":"cli-r18-w8","ts_iso":"2026-09-15T00:03:00Z"}}],
			"ready":[{"doc_id":"task-6","title":"six","priority":0}]}`,
	}
}

// ---------------------------------------------------------------------------
// c3 — THE SYMMETRY, AS A PREDICATE OVER THE VERB SET
// ---------------------------------------------------------------------------

// TestTaskClaimFixturesCoverEveryReadShape is what keeps criterion 3 from
// decaying into the enumeration it forbids. An enumeration is a snapshot; this
// asserts the fixture table and the shape map are the SAME SET, so adding a
// fifth read shape without a fixture reds here, by name, before it can escape
// the symmetry test below.
func TestTaskClaimFixturesCoverEveryReadShape(t *testing.T) {
	shapes := taskReadShapes()
	fixtures := taskClaimFixtures()

	for id := range shapes {
		if _, ok := fixtures[id]; !ok {
			t.Errorf("read shape %q has NO fixture: it escapes the symmetry test entirely, which is exactly how a third shape (task.prime) went unnoticed", id)
		}
	}
	for id := range fixtures {
		if _, ok := shapes[id]; !ok {
			t.Errorf("fixture %q names no read shape: either the shape was dropped from taskReadShapes() or the id is a typo, and a typo'd fixture asserts nothing", id)
		}
	}
	if len(shapes) < 3 {
		t.Fatalf("taskReadShapes() carries %d verbs; the measured set is at least three distinct shapes (get, ls/ready, prime) and a smaller map means one was lost", len(shapes))
	}
}

// TestTaskClaimPathSymmetryHoldsForEveryVerb is criterion 3's lock. For EVERY
// verb: its own shape reads its own payload and finds the live claim, and every
// OTHER verb's shape — whenever that shape looks for different rows — REFUSES
// on it and names the true owner. Written over the map, so removing a verb's
// coverage reds here naming which verb lost it.
//
// MUTATION ARM (run and recorded in the task report): delete any entry from
// taskReadShapes() and this test reds with "read shape ... has NO fixture" /
// "fixture ... names no read shape" naming that verb; make two shapes share a
// rows key and the cross-refusal for that pair stops being asserted, which the
// sameRowsKeys accounting below reports as a skip rather than a silent pass.
func TestTaskClaimPathSymmetryHoldsForEveryVerb(t *testing.T) {
	shapes := taskReadShapes()
	fixtures := taskClaimFixtures()

	crossRefusals := 0
	for id, shape := range shapes {
		raw := []byte(fixtures[id])

		// ARM 1 — the verb reads ITS OWN payload and gets a verdict with a
		// claim in it. Without this the refusals below are satisfiable by a
		// reader that refuses everything.
		report, err := readTaskClaims(raw, id, shape)
		if err != nil {
			t.Errorf("%s cannot read its OWN payload: %v", id, err)
			continue
		}
		if report.Rows == 0 {
			t.Errorf("%s read its own payload as ZERO rows", id)
		}
		if report.Claimed == 0 {
			t.Errorf("%s found NO claim in its own fixture; the fixture models an unclaimed page and proves nothing about a claim misread", id)
		}

		// ARM 2 — every OTHER verb's shape, applied to this payload, REFUSES.
		for otherID, other := range shapes {
			if otherID == id || sameRowsKeys(shape, other) {
				continue
			}
			got, err := readTaskClaims(raw, otherID, other)
			if err == nil {
				t.Errorf("%s's shape read %s's payload and ANSWERED (%d rows, %d claimed) instead of refusing — this is the 25-of-25 silent NOCLAIM, reproduced",
					otherID, id, got.Rows, got.Claimed)
				continue
			}
			if !errors.Is(err, ErrReadyPageUnreadable) {
				t.Errorf("%s's shape over %s's payload refused with the wrong error type %T: %v", otherID, id, err, err)
			}
			if !strings.HasPrefix(err.Error(), "CANNOT READ") {
				t.Errorf("%s's shape over %s's payload: refusal does not lead with the CANNOT READ token: %q", otherID, id, err)
			}
			// The refusal has to ROUTE, not merely decline: it names the verb
			// the payload really came from and where ITS claims live.
			if !strings.Contains(err.Error(), id) {
				t.Errorf("%s's shape over %s's payload does not name %s as the true owner: %q", otherID, id, id, err)
			}
			for _, path := range shape.ClaimPaths() {
				if !strings.Contains(err.Error(), path) {
					t.Errorf("%s's shape over %s's payload does not name the true claim path %s: %q", otherID, id, path, err)
				}
			}
			crossRefusals++
		}
	}
	if crossRefusals == 0 {
		t.Fatal("NOT ONE cross-shape refusal was asserted — every pair was skipped as same-shape, so this test measured nothing")
	}
	t.Logf("cross-shape refusals asserted: %d over %d verbs", crossRefusals, len(shapes))
}

func sameRowsKeys(a, b taskReadShape) bool {
	if len(a.RowsKeys) != len(b.RowsKeys) || a.SingleRow != b.SingleRow {
		return false
	}
	x := append([]string(nil), a.RowsKeys...)
	y := append([]string(nil), b.RowsKeys...)
	sort.Strings(x)
	sort.Strings(y)
	return strings.Join(x, "|") == strings.Join(y, "|")
}

// TestTaskClaimPathHelpNamesEveryVerbsPath is criterion 3's documentation arm,
// read out of the SAME producer the reader uses. Each read verb's --help states
// its own claim path and disclaims the paths that belong to the others, so the
// human who would otherwise guess `.doc.claim` on a ready page is told before
// they run it.
func TestTaskClaimPathHelpNamesEveryVerbsPath(t *testing.T) {
	shapes := taskReadShapes()
	for id, shape := range shapes {
		var stdout, stderr bytes.Buffer
		cmd := manifest.Command{ID: id, Noun: "task", Verb: strings.TrimPrefix(id, "task.")}
		usageCommand(newWriter(&stdout, &stderr), cmd)
		help := stderr.String()

		for _, path := range shape.ClaimPaths() {
			if !strings.Contains(help, path) {
				t.Errorf("`bp %s --help` never names its own claim path %s:\n%s", strings.ReplaceAll(id, ".", " "), path, help)
			}
		}
		for otherID, other := range shapes {
			if otherID == id || sameClaimPaths(shape, other) {
				continue
			}
			for _, path := range other.ClaimPaths() {
				if !strings.Contains(help, path) {
					t.Errorf("`bp %s --help` does not disclaim %s's path %s, so the reader who guesses it is not warned:\n%s",
						strings.ReplaceAll(id, ".", " "), otherID, path, help)
				}
			}
		}
		if stdout.Len() != 0 {
			t.Errorf("%s help wrote to stdout; it must stay on stderr so -o json remains one document: %q", id, stdout.String())
		}
	}
}

// ---------------------------------------------------------------------------
// c2 — THE GUARD CANNOT PASS VACUOUSLY
// ---------------------------------------------------------------------------

// TestTaskClaimReadRefusesEveryUnreadablePayload is criterion 2's lock. Every
// failure this class produces is a command that SUCCEEDED, so a reader that
// answers "0 claims" on an empty or unparseable payload reproduces the very
// defect it exists to catch. Each case must return ErrReadyPageUnreadable with
// the `CANNOT READ:` token and a ZERO-VALUE report — never a verdict.
//
// MUTATION ARM (recorded in the task report): the `documents` and the empty-page
// cases are the two the criterion names by hand; both are here and both refuse.
func TestTaskClaimReadRefusesEveryUnreadablePayload(t *testing.T) {
	lsShape := taskReadShapes()[taskLsCommandID]
	getShape := taskReadShapes()[taskGetCommandID]

	cases := []struct {
		name    string
		id      string
		shape   taskReadShape
		body    string
		mustSay string
	}{
		{"empty input", taskLsCommandID, lsShape, "", "empty"},
		{"invalid JSON", taskLsCommandID, lsShape, "<html>502 gateway</html>", "not a JSON object"},
		{"envelope is a list", taskLsCommandID, lsShape, `[{"doc_id":"task-1"}]`, "not a JSON object"},
		{"no rows key at all", taskLsCommandID, lsShape, `{"ok":true}`, "none of the row keys"},
		// The `bp doc ls` payload the criterion names: keyed `documents`, so a
		// pager keyed on `docs` writes zero rows and exits 0.
		{"a bp doc ls payload", taskLsCommandID, lsShape,
			`{"ok":true,"documents":[{"_id":"doc-1"},{"_id":"doc-2"}]}`, "`documents`"},
		{"docs is not a list", taskLsCommandID, lsShape, `{"ok":true,"docs":{"doc_id":"task-1"}}`, "not a list"},
		// The empty page the criterion names.
		{"docs carries zero rows", taskLsCommandID, lsShape, `{"ok":true,"docs":[]}`, "ZERO rows"},
		{"a row is not an object", taskLsCommandID, lsShape, `{"ok":true,"docs":["task-1"]}`, "not an object"},
		{"prime with both lists empty", taskPrimeCommandID, taskReadShapes()[taskPrimeCommandID],
			`{"ok":true,"in_progress":[],"ready":[]}`, "ZERO rows"},
		{"get handed a list", taskGetCommandID, getShape, `{"ok":true,"doc":[{"doc_id":"task-1"}]}`, "not the single object"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			report, err := readTaskClaims([]byte(tc.body), tc.id, tc.shape)
			if err == nil {
				t.Fatalf("ANSWERED instead of refusing: %+v — a verdict over an unreadable payload is byte-identical to a page where nobody holds anything", report)
			}
			if !errors.Is(err, ErrReadyPageUnreadable) {
				t.Errorf("refusal is not ErrReadyPageUnreadable (%T): %v", err, err)
			}
			if !strings.HasPrefix(err.Error(), "CANNOT READ") {
				t.Errorf("refusal does not lead with the CANNOT READ token: %q", err)
			}
			if !strings.Contains(err.Error(), tc.mustSay) {
				t.Errorf("refusal does not say why (%q missing): %q", tc.mustSay, err)
			}
			if report.Rows != 0 || report.Claimed != 0 || report.ClaimKeyPresent != 0 {
				t.Errorf("a refusal returned a non-zero report, which a caller ignoring the error would read as a verdict: %+v", report)
			}
		})
	}
}

// TestTaskClaimReadCountsPresenceApartFromHolder pins the distinction the whole
// defect turns on: a ready row with NOBODY on it OMITS `claim`, so key-absence
// is not evidence of a wrong path on a flat page, and worker-null is not the
// same fact as key-absent. Conflating them is what makes a wrong-path zero and
// an honest zero look alike.
func TestTaskClaimReadCountsPresenceApartFromHolder(t *testing.T) {
	shape := taskReadShapes()[taskReadyCommandID]
	report, err := readTaskClaims([]byte(taskClaimFixtures()[taskReadyCommandID]), taskReadyCommandID, shape)
	if err != nil {
		t.Fatal(err)
	}
	if report.Rows != 2 {
		t.Fatalf("rows = %d, want 2", report.Rows)
	}
	if report.ClaimKeyPresent != 1 {
		t.Errorf("ClaimKeyPresent = %d, want 1: the unclaimed ready row OMITS the key entirely", report.ClaimKeyPresent)
	}
	if report.Claimed != 1 {
		t.Errorf("Claimed = %d, want 1", report.Claimed)
	}
	if len(report.Workers) != 1 || report.Workers[0] != "probe-opus-r13" {
		t.Errorf("Workers = %v, want [probe-opus-r13]", report.Workers)
	}
}

// ---------------------------------------------------------------------------
// THE POSITIVE CONTROL
// ---------------------------------------------------------------------------

// TestTaskClaimGuardIsNotBlind runs the PRE-FIX reading — a plain path walk with
// no refusal, which is what every jq one-liner and every hand-rolled parser
// does — over the same fixtures, and REQUIRES it to produce the silent uniform
// NOCLAIM. If it ever stops doing so (the fixtures drift, the walk breaks), the
// assertions above are vacuous and this reds instead.
func TestTaskClaimGuardIsNotBlind(t *testing.T) {
	fixtures := taskClaimFixtures()

	// The measured incident, reproduced: `.doc.claim.worker` over a flat ls page.
	for _, id := range []string{taskLsCommandID, taskReadyCommandID} {
		rows := flatRows(t, fixtures[id], "docs")
		if len(rows) == 0 {
			t.Fatalf("%s fixture has no docs rows — the control measured nothing", id)
		}
		nonNull := 0
		for _, row := range rows {
			if walkString(row, "doc", "claim", "worker") != "" {
				nonNull++
			}
		}
		if nonNull != 0 {
			t.Fatalf("%s: the get-shaped path .doc.claim.worker answered on %d rows — the control can no longer see the defect, so every refusal asserted above is vacuous", id, nonNull)
		}
		// And the TRUE path does answer, or the fixture is simply an unclaimed
		// page and the zero above means nothing.
		trueHits := 0
		for _, row := range rows {
			if walkString(row, "claim", "worker") != "" {
				trueHits++
			}
		}
		if trueHits == 0 {
			t.Fatalf("%s: the TRUE path .claim.worker answered on ZERO rows too — the fixture is unclaimed, so the uniform zero is honest and models nothing", id)
		}
		t.Logf("%s: .doc.claim.worker -> %d/%d rows (the silent misread); .claim.worker -> %d/%d (the truth)",
			id, nonNull, len(rows), trueHits, len(rows))
	}

	// And the mirror: a ready-shaped `.docs[]` walk over a `task prime` payload
	// reads ZERO rows out of a page that carries a live claim — the third shape
	// escaping a two-verb enumeration, which is why c3 is a predicate.
	primeRows := flatRows(t, fixtures[taskPrimeCommandID], "docs")
	if len(primeRows) != 0 {
		t.Fatalf("`docs` resolved on a task prime payload (%d rows); the third-shape control no longer models the escape", len(primeRows))
	}
	held := flatRows(t, fixtures[taskPrimeCommandID], "in_progress")
	if len(held) == 0 || walkString(held[0], "claim", "worker") == "" {
		t.Fatal("the task prime fixture carries no live claim under in_progress — the zero above is honest and proves nothing")
	}
}

func flatRows(t *testing.T, body, key string) []map[string]any {
	t.Helper()
	var env map[string]any
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}
	list, _ := env[key].([]any)
	out := make([]map[string]any, 0, len(list))
	for _, entry := range list {
		if row, ok := entry.(map[string]any); ok {
			out = append(out, row)
		}
	}
	return out
}

// walkString is the hand-rolled path walk under test — the shape of every jq
// one-liner and every `row["doc"]["claim"]["worker"]` this defect was measured
// through. A missing key answers "", exactly as a null would.
func walkString(row map[string]any, path ...string) string {
	cur := any(row)
	for _, key := range path {
		obj, ok := cur.(map[string]any)
		if !ok {
			return ""
		}
		cur = obj[key]
	}
	s, _ := cur.(string)
	return s
}

// ---------------------------------------------------------------------------
// THE ADVISORY — stdout stays byte-identical
// ---------------------------------------------------------------------------

// TestTaskClaimAdvisoryBlastRadius pins the one production caller. It speaks on
// stderr, only on machine output of a flat read verb whose page carries a LIVE
// claim, and never anywhere else — an unconditional line on a verb the fleet
// calls every few seconds is noise the fleet learns to ignore.
func TestTaskClaimAdvisoryBlastRadius(t *testing.T) {
	fixtures := taskClaimFixtures()
	cases := []struct {
		name       string
		id         string
		status     int
		machineOut bool
		body       string
		wantLine   bool
	}{
		{"ls, machine out, a live claim", taskLsCommandID, 200, true, fixtures[taskLsCommandID], true},
		{"ready, machine out, a live claim", taskReadyCommandID, 200, true, fixtures[taskReadyCommandID], true},
		{"prime, machine out, a live claim", taskPrimeCommandID, 200, true, fixtures[taskPrimeCommandID], true},
		{"the human table", taskLsCommandID, 200, false, fixtures[taskLsCommandID], false},
		{"not a 2xx", taskLsCommandID, 404, true, fixtures[taskLsCommandID], false},
		{"another verb", "doc.ls", 200, true, fixtures[taskLsCommandID], false},
		{"task get is single-row and already sentinel-covered", taskGetCommandID, 200, true, fixtures[taskGetCommandID], false},
		{"nobody on the page", taskReadyCommandID, 200, true, `{"ok":true,"docs":[{"doc_id":"task-3"}]}`, false},
		{"an unreadable page never speaks", taskLsCommandID, 200, true, `<html>502</html>`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			cmd := manifest.Command{ID: tc.id, Noun: "task", Verb: strings.TrimPrefix(tc.id, "task.")}
			emitTaskClaimPathAdvisory(out, cmd, tc.status, tc.machineOut, []byte(tc.body))

			spoke := strings.Contains(stderr.String(), "CLAIMED")
			if spoke != tc.wantLine {
				t.Errorf("advisory spoke = %v, want %v: %q", spoke, tc.wantLine, stderr.String())
			}
			if stdout.Len() != 0 {
				t.Errorf("the advisory wrote to STDOUT, so `-o json` is no longer one document: %q", stdout.String())
			}
			if tc.wantLine && !strings.Contains(stderr.String(), ".doc.claim") {
				t.Errorf("the advisory does not name the wrong path readers actually use: %q", stderr.String())
			}
		})
	}
}
