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
