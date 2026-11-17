package cli

// task-9fe039cf44a67b2d (#26844 round-3 review). The server's publish reads the
// draft FIRST and answers not_found when it is gone; every wall (duplicate_of,
// the quality wall) runs after that read. So a WALL refusal on a publish resend
// proves attempt 1 did not publish: it is a definite refusal and keeps its own
// code, its resume block and the discard. Only not_found and the refusals made
// before the handler runs (401/403/429) stay may-have-landed.

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const duplicateOfOther422 = `{"error":{"code":"duplicate_of","message":"this document near-duplicates an already-published document","details":{"duplicate_of":"task-other-1","similar":[{"id":"task-other-1","similarity":0.9}]}}}`

func sentDiscard(kinds []string) bool {
	for _, k := range kinds {
		if k == "discardDraft" {
			return true
		}
	}
	return false
}

func TestTaskCreatePublishWallRefusalOnAResendIsARefusalJSON(t *testing.T) {
	code, so, se, kinds := runScriptedPublish(t, [2]string{"500", fault500}, [2]string{"422", duplicateOfOther422})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d)\nstdout=%s\nstderr=%s", code, exitGeneric, so, se)
	}
	var env struct {
		Error struct {
			Code    string `json:"code"`
			Details struct {
				DuplicateOf string `json:"duplicate_of"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(so), &env); err != nil {
		t.Fatalf("stdout is not one envelope: %v\n%s", err, so)
	}
	if env.Error.Code != "duplicate_of" {
		t.Fatalf("error.code = %q, want duplicate_of\n%s", env.Error.Code, so)
	}
	if env.Error.Details.DuplicateOf != "task-other-1" {
		t.Fatalf("details.duplicate_of = %q, want task-other-1\n%s", env.Error.Details.DuplicateOf, so)
	}
	if !sentDiscard(kinds) {
		t.Fatalf("the draft was not discarded after a definite wall refusal: %v", kinds)
	}
}

func TestTaskCreatePublishWallRefusalOnAResendPrintsTheResumeBlock(t *testing.T) {
	noResendSleep(t)
	ts, kinds := publishScriptDoor(t, [2]string{"500", fault500}, [2]string{"422", duplicateOfOther422})
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A publish whose resend met the wall", "--publish"))

	if code != exitGeneric {
		t.Fatalf("exit = %d, want exitGeneric (%d)\nstderr=%s", code, exitGeneric, se.String())
	}
	if !strings.Contains(se.String(), "THE ROW ALREADY EXISTS: task-other-1") {
		t.Fatalf("the resume block is missing:\n%s", se.String())
	}
	if strings.Contains(se.String(), "may have landed") {
		t.Fatalf("a wall refusal was called may-have-landed:\n%s", se.String())
	}
	if !sentDiscard(kinds()) {
		t.Fatalf("the draft was not discarded: %v", kinds())
	}
}

// Pins: not_found and the pre-handler refusals stay may-have-landed on a resend.
func TestTaskCreatePublishResendStillAmbiguousForNotFoundAndPreHandlerRefusals(t *testing.T) {
	for _, step := range [][2]string{
		{"404", notFound404},
		{"401", `{"error":{"code":"unauthorized","message":"token expired"}}`},
		{"403", `{"error":{"code":"forbidden","message":"no"}}`},
		{"429", `{"error":{"code":"rate_limited","message":"slow down"}}`},
	} {
		code, so, se, kinds := runScriptedPublish(t, [2]string{"500", fault500}, step)
		if code != exitAmbiguous {
			t.Errorf("%s: exit = %d, want exitAmbiguous\nstdout=%s\nstderr=%s", step[0], code, so, se)
		}
		if sentDiscard(kinds) {
			t.Errorf("%s: discarded the draft of a publish that may have landed: %v", step[0], kinds)
		}
	}
}

// #26871 review: the definite set is CLOSED. On a resend only the named wall
// codes are definite; 402, an unknown code, anything else may have landed.
func TestTaskCreatePublishResendOutsideTheWallListMayHaveLanded(t *testing.T) {
	for _, step := range [][2]string{
		{"402", `{"error":{"code":"quota_exceeded","message":"quota exceeded"}}`},
		{"422", `{"error":{"code":"a_rule_this_binary_predates","message":"refused"}}`},
	} {
		code, so, se, kinds := runScriptedPublish(t, [2]string{"500", fault500}, step)
		if code != exitAmbiguous {
			t.Errorf("%s: exit = %d, want exitAmbiguous\nstdout=%s\nstderr=%s", step[1], code, so, se)
		}
		if sentDiscard(kinds) {
			t.Errorf("%s: discarded the draft of a publish that may have landed: %v", step[1], kinds)
		}
		checkFirst(t, step[1], se, "task-950")
	}
}

// Any attempt: a discard that answers not_found proves there is no draft, so
// the row is not DRAFT ONLY. The publish may have landed: check first, exit 9.
func TestTaskCreateDiscardFindingNoDraftChecksFirst(t *testing.T) {
	notFoundDiscard := [2]string{"404", notFound404}
	quota := [2]string{"402", `{"error":{"code":"quota_exceeded","message":"quota exceeded"}}`}
	wall := [2]string{"422", `{"error":{"code":"unknown_tag","message":"unknown tag"}}`}
	for _, c := range []struct {
		output  string
		refusal [2]string
	}{{"json", quota}, {"", quota}, {"json", wall}, {"", wall}} {
		output := c.output
		noResendSleep(t)
		ts, _ := publishScriptDoorDiscard(t, notFoundDiscard, c.refusal)
		var so, se bytes.Buffer
		w := &writer{stdout: &so, stderr: &se, output: output}
		ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
		code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A refused publish whose discard found nothing", "--publish"))
		if code != exitAmbiguous {
			t.Errorf("output %q: exit = %d, want exitAmbiguous\nstdout=%s\nstderr=%s", output, code, so.String(), se.String())
		}
		checkFirst(t, "output "+output, se.String(), "task-950")
		// rev26733 wording: the publish was REFUSED and the discard found
		// nothing, so the headline says that, not "WAS SENT and may have landed".
		if !strings.Contains(se.String(), "the publish was refused, and no draft is left") {
			t.Errorf("output %q: does not say the publish was refused and no draft is left:\n%s", output, se.String())
		}
		if strings.Contains(se.String(), "may have landed") {
			t.Errorf("output %q: a refused publish is called may-have-landed:\n%s", output, se.String())
		}
	}
}

// task-0d38c8d05932db8f: a non-duplicate refusal whose discard GENUINELY fails
// (500) leaves a real draft: residue discard_failed, exit 1, both shapes. Red
// under a mutant that sends every non-duplicate discard failure to
// publish_discard_found_nothing.
func TestTaskCreateNonDuplicateRefusalWithDiscard500IsResidue(t *testing.T) {
	wall := [2]string{"422", `{"error":{"code":"unknown_tag","message":"unknown tag"}}`}
	for _, output := range []string{"json", ""} {
		noResendSleep(t)
		ts, _ := publishScriptDoorDiscard(t, [2]string{"500", fault500}, wall)
		var so, se bytes.Buffer
		w := &writer{stdout: &so, stderr: &se, output: output}
		ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
		code := runTaskCreate(w, globals{yes: true}, ctx, createArgs("A refused publish whose discard failed", "--publish"))
		if code != exitGeneric {
			t.Errorf("output %q: exit = %d, want exitGeneric\nstdout=%s\nstderr=%s", output, code, so.String(), se.String())
		}
		got := se.String() + so.String()
		if !strings.Contains(got, residueDiscardFailed) {
			t.Errorf("output %q: residue %s not named:\nstdout=%s\nstderr=%s", output, residueDiscardFailed, so.String(), se.String())
		}
		if strings.Contains(got, ambiguityPublishDiscardFoundNothing) {
			t.Errorf("output %q: a real leftover draft was reported as found-nothing", output)
		}
	}
}
