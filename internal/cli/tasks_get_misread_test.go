package cli

// tasks_get_misread_test.go — A WRONG FIELD PATH MUST NOT ANSWER CONFIDENTLY.
//
// THE DEFECT THIS EXISTS FOR. Measured 2026-09-06 on a live claimed row. A lead
// relaunching after a death was under a standing order: "do NOT blanket
// re-claim; re-claim only what claim-health shows lapsed". It read the row with
// `bp task get <id> -o json` and a parser walking `.doc.content.claim`. That
// answered null. Null there reads EXACTLY like a lapsed claim — the precise
// condition the order says to remediate by re-claiming. The claim was in fact
// healthy at epoch 2 with an extended lease. A re-claim would have bumped the
// epoch under a live pulse loop, and would have stolen the row outright had the
// holder's id differed.
//
// The sibling misread is `.doc.content.criteria`: also null, because the
// criteria live at `.doc.content.acceptance_criteria` keyed `criterion` (not
// `text`). Null there reads as A ROW WITH NO CRITERIA and invites a
// criteria-free close.
//
// WHY THE WRONG GUESS IS THE NATURAL ONE. The envelope duplicates five fields at
// both `doc.X` and `doc.content.X`, and the two a triager reads FIRST —
// lifecycle_status and priority — are among them. Both paths answer, so the
// reader learns "task fields live under content", and that lesson is wrong for
// exactly the two most dangerous fields in the document. Nothing warns: a
// missing key is not an error in any language these parsers are written in.
//
// WHAT IS ASSERTED HERE.
//
//	1. Both wrong reads are DISTINGUISHABLE — non-null, not a claim, not a
//	   criteria list — and each names the true path in its `_misread` text.
//	2. The TRUE paths are untouched, byte for byte, by the annotation.
//	3. The CLI never overwrites a server field: a body that already answers at
//	   content.claim keeps the server's value.
//	4. The blast radius is one verb and the machine shapes: another command, a
//	   non-2xx, the human table, and an unparseable body all come back verbatim.
//	5. The help NAMES every path this file plants, plus `-o json` and the
//	   `criterion` key (criterion c1), read out of the SAME producer the
//	   sentinels come from, so help and behaviour cannot drift.
//
// THE POSITIVE CONTROL. TestTaskGetMisreadGuardIsNotBlind runs the pre-fix
// behaviour — the raw server body, with annotateTaskGetMisreads NOT applied —
// through the same predicate the assertions use, and requires it to be judged
// UNSAFE. If the predicate ever stops being able to see the defect, that test
// reds instead of this file going quietly green.

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// taskGetCmd is the command under test: the real manifest id, never a
// look-alike, because the annotation is keyed on the id and nothing else.
func taskGetCmd() manifest.Command {
	return manifest.Command{ID: taskGetCommandID, Noun: "task", Verb: "get"}
}

// liveClaimedRowBody is the SHAPE the server really answers with, reduced to the
// fields this file reasons about: the claim only at doc.claim, the criteria only
// at doc.content.acceptance_criteria keyed `criterion`, and lifecycle_status and
// priority duplicated at BOTH levels — the duplication that teaches the wrong
// lesson in the first place.
const liveClaimedRowBody = `{
  "ok": true,
  "doc": {
    "doc_id": "task-798c0080cab955a3",
    "lifecycle_status": "in_progress",
    "priority": 1,
    "claim": {"epoch": 2, "worker": "lead-studio-10", "ts_iso": "2026-09-06T00:49:27Z"},
    "criteria_progress": {"met": 0, "total": 3},
    "content": {
      "lifecycle_status": "in_progress",
      "priority": 1,
      "description": "a live claimed row",
      "acceptance_criteria": [
        {"criterion": "the first criterion", "met": false, "evidence": ""},
        {"criterion": "the second criterion", "met": false, "evidence": ""}
      ]
    }
  }
}`

// readsAsUnclaimed is the DANGEROUS reading, spelled as a predicate: a parser
// walking .doc.content.claim concludes "nobody holds this row" and re-claims.
// It is exactly what a `claim is None` / `.claim == null` test does.
func readsAsUnclaimed(t *testing.T, body []byte) bool {
	t.Helper()
	v, ok := contentField(t, body, "claim")
	return !ok || v == nil
}

// readsAsCriteriaFree is the sibling dangerous reading: a parser walking
// .doc.content.criteria concludes "this row has no acceptance criteria" and
// closes it, or stamps against a criterion whose text it never read.
func readsAsCriteriaFree(t *testing.T, body []byte) bool {
	t.Helper()
	v, ok := contentField(t, body, "criteria")
	if !ok || v == nil {
		return true
	}
	list, isList := v.([]any)
	return isList && len(list) == 0
}

// contentField walks .doc.content.<key> on a rendered body.
func contentField(t *testing.T, body []byte, key string) (any, bool) {
	t.Helper()
	var env map[string]any
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("body is not JSON: %v\n%s", err, body)
	}
	doc, ok := env["doc"].(map[string]any)
	if !ok {
		t.Fatalf("body has no doc object:\n%s", body)
	}
	content, ok := doc["content"].(map[string]any)
	if !ok {
		t.Fatalf("body has no doc.content object:\n%s", body)
	}
	v, present := content[key]
	return v, present
}

func TestTaskGetWrongPathsAreDistinguishable(t *testing.T) {
	raw := []byte(liveClaimedRowBody)
	got := annotateTaskGetMisreads(taskGetCmd(), 200, true, raw)

	if readsAsUnclaimed(t, got) {
		t.Fatalf(".doc.content.claim still reads as UNCLAIMED — the misread that nearly stole a live row:\n%s", got)
	}
	if readsAsCriteriaFree(t, got) {
		t.Fatalf(".doc.content.criteria still reads as A ROW WITH NO CRITERIA:\n%s", got)
	}

	// Distinguishable is not enough on its own: the sentinel has to SAY where
	// the real value is, or the reader is merely confused instead of misled.
	claim, _ := contentField(t, got, "claim")
	claimObj, ok := claim.(map[string]any)
	if !ok {
		t.Fatalf(".doc.content.claim sentinel is not an object: %T", claim)
	}
	msg, _ := claimObj[taskMisreadKey].(string)
	if !strings.Contains(msg, ".doc.claim") {
		t.Errorf("claim sentinel does not name the true path .doc.claim: %q", msg)
	}
	// The fields a claim reader walks INTO must be loud too, not another null:
	// `.doc.content.claim.epoch` was the second half of the measured misread.
	for _, deep := range []string{"epoch", "worker", "ts_iso"} {
		s, isStr := claimObj[deep].(string)
		if !isStr || !strings.Contains(s, "WRONG PATH") {
			t.Errorf(".doc.content.claim.%s = %#v; want a WRONG PATH string, never a null or a plausible value", deep, claimObj[deep])
		}
	}

	criteria, _ := contentField(t, got, "criteria")
	critObj, ok := criteria.(map[string]any)
	if !ok {
		t.Fatalf(".doc.content.criteria sentinel is not an object (a list would be mistakable for real criteria): %T", criteria)
	}
	cmsg, _ := critObj[taskMisreadKey].(string)
	for _, want := range []string{"acceptance_criteria", "criterion"} {
		if !strings.Contains(cmsg, want) {
			t.Errorf("criteria sentinel does not name %q: %q", want, cmsg)
		}
	}
}

func TestTaskGetAnnotationLeavesTheTruePathsExact(t *testing.T) {
	raw := []byte(liveClaimedRowBody)
	got := annotateTaskGetMisreads(taskGetCmd(), 200, true, raw)

	var before, after map[string]any
	if err := json.Unmarshal(raw, &before); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(got, &after); err != nil {
		t.Fatal(err)
	}
	beforeDoc := before["doc"].(map[string]any)
	afterDoc := after["doc"].(map[string]any)

	for _, key := range []string{"claim", "criteria_progress", "doc_id", "lifecycle_status", "priority"} {
		if !jsonEqual(t, beforeDoc[key], afterDoc[key]) {
			t.Errorf("doc.%s changed: %#v -> %#v", key, beforeDoc[key], afterDoc[key])
		}
	}
	beforeContent := beforeDoc["content"].(map[string]any)
	afterContent := afterDoc["content"].(map[string]any)
	for key, want := range beforeContent {
		if !jsonEqual(t, want, afterContent[key]) {
			t.Errorf("doc.content.%s changed: %#v -> %#v", key, want, afterContent[key])
		}
	}
	// And nothing was planted beyond the two documented paths.
	for key := range afterContent {
		if _, wasThere := beforeContent[key]; wasThere {
			continue
		}
		if _, documented := taskGetMisreadPaths()[key]; !documented {
			t.Errorf("undocumented key planted under doc.content: %q", key)
		}
	}
}

func jsonEqual(t *testing.T, a, b any) bool {
	t.Helper()
	ab, err := json.Marshal(a)
	if err != nil {
		t.Fatal(err)
	}
	bb, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	return bytes.Equal(ab, bb)
}

func TestTaskGetAnnotationNeverOverwritesAServerField(t *testing.T) {
	// If the server ever starts answering at content.claim, ITS value wins. A
	// CLI that clobbered a real server field would be a worse lie than the null.
	body := []byte(`{"ok":true,"doc":{"content":{"claim":{"epoch":7,"worker":"real"}}}}`)
	got := annotateTaskGetMisreads(taskGetCmd(), 200, true, body)
	claim, _ := contentField(t, got, "claim")
	obj, ok := claim.(map[string]any)
	if !ok {
		t.Fatalf("claim is not an object: %T", claim)
	}
	if _, planted := obj[taskMisreadKey]; planted {
		t.Fatalf("the CLI overwrote a server-provided content.claim: %#v", obj)
	}
	if obj["worker"] != "real" {
		t.Errorf("server claim value lost: %#v", obj)
	}
}

func TestTaskGetAnnotationBlastRadius(t *testing.T) {
	raw := []byte(liveClaimedRowBody)
	cases := []struct {
		name       string
		cmd        manifest.Command
		status     int
		machineOut bool
		body       []byte
	}{
		{"another verb", manifest.Command{ID: taskLsCommandID, Noun: "task", Verb: "ls"}, 200, true, raw},
		{"doc get", manifest.Command{ID: "doc.get", Noun: "doc", Verb: "get"}, 200, true, raw},
		{"human table", taskGetCmd(), 200, false, raw},
		{"not a 2xx", taskGetCmd(), 404, true, raw},
		{"body is not JSON", taskGetCmd(), 200, true, []byte("<html>gateway</html>")},
		{"body has no doc", taskGetCmd(), 200, true, []byte(`{"ok":true}`)},
		{"doc.content is not an object", taskGetCmd(), 200, true, []byte(`{"ok":true,"doc":{"content":"x"}}`)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := annotateTaskGetMisreads(tc.cmd, tc.status, tc.machineOut, tc.body)
			if !bytes.Equal(got, tc.body) {
				t.Errorf("body changed where it must not:\n before: %s\n  after: %s", tc.body, got)
			}
		})
	}
}

// TestTaskGetHelpNamesEveryMisreadPath is criterion c1's lock. It reads the help
// block that `bp task get --help` actually renders (through usageCommand, the
// same function the binary calls) and requires it to answer the three questions
// a reader of this envelope has: how do I get machine-readable output, where is
// the claim, and where are the criteria — including that entries are keyed
// `criterion`. Every path this file PLANTS must be named, so a new sentinel
// cannot be added without documenting it.
func TestTaskGetHelpNamesEveryMisreadPath(t *testing.T) {
	var stdout, stderr bytes.Buffer
	usageCommand(newWriter(&stdout, &stderr), taskGetCmd())
	help := stderr.String()

	for _, want := range []string{
		"-o json",
		".doc.claim",
		".doc.content.acceptance_criteria",
		"criterion",
	} {
		if !strings.Contains(help, want) {
			t.Errorf("bp task get --help never mentions %q:\n%s", want, help)
		}
	}
	// Every planted wrong path is named in the help, by its full path.
	for key := range taskGetMisreadPaths() {
		if !strings.Contains(help, ".doc.content."+key) {
			t.Errorf("help does not name the planted wrong path .doc.content.%s:\n%s", key, help)
		}
	}
	if stdout.Len() != 0 {
		t.Errorf("help wrote to stdout; it must stay on stderr so -o json remains one document: %q", stdout.String())
	}
}

// TestTaskGetMisreadGuardIsNotBlind is the POSITIVE CONTROL for criterion c2.
// It runs the PRE-FIX behaviour — the raw server body, the annotation not
// applied — through the same two predicates the assertions above use, and
// requires both to judge it UNSAFE. If a future refactor makes those predicates
// stop seeing the defect (say the fixture drifts, or `readsAsUnclaimed` starts
// answering false for everything), this reds rather than letting the whole file
// pass vacuously.
func TestTaskGetMisreadGuardIsNotBlind(t *testing.T) {
	raw := []byte(liveClaimedRowBody)

	if !readsAsUnclaimed(t, raw) {
		t.Fatal("the pre-fix body was NOT judged to read as unclaimed — the predicate has gone blind, so every pass above is vacuous")
	}
	if !readsAsCriteriaFree(t, raw) {
		t.Fatal("the pre-fix body was NOT judged to read as criteria-free — the predicate has gone blind, so every pass above is vacuous")
	}
	// And the fixture really is a claimed row with criteria, at the TRUE paths:
	// a fixture that had neither would satisfy the predicates for the wrong
	// reason, and prove nothing about the misread.
	var env map[string]any
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatal(err)
	}
	doc := env["doc"].(map[string]any)
	if _, ok := doc["claim"].(map[string]any); !ok {
		t.Fatal("fixture has no doc.claim — it is not a claimed row, so the misread it models is not the measured one")
	}
	crit, ok := doc["content"].(map[string]any)["acceptance_criteria"].([]any)
	if !ok || len(crit) == 0 {
		t.Fatal("fixture has no doc.content.acceptance_criteria — the criteria misread it models is not the measured one")
	}
}
