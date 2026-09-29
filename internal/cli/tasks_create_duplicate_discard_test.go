package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// task-9a97e96c35fba472 — a duplicate_of publish refusal whose draft the SERVER
// already removed is not residue.
//
// On a publish refused as duplicate_of the server deletes the refused draft
// itself (Lifecycle.discard_refused_duplicate_draft/5, re-run after the batch
// rollback by Mutations.compensating_discard/4) and says so in the refusal
// message. bp's own follow-up discardDraft then answers 404 not_found. Before
// this change bp read that 404 as a failed cleanup and printed residue
// discard_failed / draft_discarded false next to the server's "was discarded".
// The api half (task_create_publish_duplicate_leaves_no_row_test.exs) proves no
// row remains.

// dupRefusalBody is the shape the server sends: 409, code duplicate_of, the
// incumbent under details.duplicate_of, and the discard sentence appended by
// Lifecycle.annotate_discard/2.
const dupRefusalBody = `{"error":{"code":"duplicate_of","message":"publish refused: near-duplicate of task-999. ` +
	`The refused draft drafts.task-801 was discarded, so this publish left nothing behind; ` +
	`the published document named above is the surviving copy.","details":{"duplicate_of":"task-999"}}}`

func runCreateShape(t *testing.T, shape, server string) (int, string, string) {
	t.Helper()
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: shape}
	ctx := manifest.Context{Server: server, Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{yes: true}, ctx, []string{
		"a near-duplicate the server refuses",
		"--description", "the server refuses the publish as duplicate_of and removes the draft itself",
		"--set", `tags:=[{"tag":"cli","strength":80,"rationale":"a registered tag, so the client wall lets this through"}]`,
		"--publish",
	})
	return code, so.String(), se.String()
}

type createRefusalDetails struct {
	Discarded    *bool  `json:"draft_discarded"`
	DiscardError string `json:"discard_error"`
	Residue      string `json:"residue"`
	DuplicateOf  string `json:"duplicate_of"`
}

func decodeCreateRefusalDetails(t *testing.T, stdout string) createRefusalDetails {
	t.Helper()
	env := decodeWallEnvelope(t, "task create --publish (duplicate_of)", []byte(stdout))
	var d createRefusalDetails
	if err := json.Unmarshal(env.Error.Details, &d); err != nil {
		t.Fatalf("details does not parse: %v (%s)", err, env.Error.Details)
	}
	if d.Discarded == nil {
		t.Fatalf("details carries no draft_discarded key: %s", env.Error.Details)
	}
	return d
}

// THE DRAFT IS ALREADY GONE: duplicate_of refusal, then the discard 404s
// not_found. Both output shapes must say the draft is discarded and name no
// residue.
func TestCreatePublishDuplicateDraftAlreadyDiscardedByServerIsNotResidue(t *testing.T) {
	for _, shape := range []string{"json", ""} {
		t.Run("output="+shape, func(t *testing.T) {
			led := &createPublishRefusalLedger{
				createdDraftID: "drafts.task-801",
				publishStatus:  http.StatusConflict,
				publishBody:    dupRefusalBody,
				refuseDiscard:  true, // the server's own 404 not_found
			}
			srv := led.serve(t)

			code, stdout, stderr := runCreateShape(t, shape, srv.URL)
			t.Logf("exit=%d\nstdout=%s\nstderr=%s", code, stdout, stderr)
			if code != exitGeneric {
				t.Fatalf("exit = %d, want exitGeneric (%d) — the publish was still refused", code, exitGeneric)
			}
			// Precondition: the follow-up discard was actually sent and 404'd, so
			// a pass below cannot come from an arm that never reached it.
			if len(led.discarded) != 1 || led.discarded[0] != "task-801" {
				t.Fatalf("discardDraft calls = %v, want exactly [task-801]", led.discarded)
			}
			if strings.Contains(stdout+stderr, "residue") {
				t.Errorf("a draft the server already discarded was reported as residue")
			}
			if strings.Contains(stdout+stderr, "document not found") {
				t.Errorf("the server's already-gone 404 was surfaced as a discard failure")
			}
			if shape == "json" {
				d := decodeCreateRefusalDetails(t, stdout)
				if !*d.Discarded {
					t.Errorf("draft_discarded = false beside the server's \"was discarded\"")
				}
				if d.DiscardError != "" || d.Residue != "" {
					t.Errorf("discard_error=%q residue=%q, want both absent", d.DiscardError, d.Residue)
				}
				if d.DuplicateOf != "task-999" {
					t.Errorf("duplicate_of = %q, want task-999", d.DuplicateOf)
				}
				return
			}
			if !strings.Contains(stderr, "the refused publish left NO draft behind") {
				t.Errorf("the human arm does not say the draft is gone:\n%s", stderr)
			}
			if strings.Contains(stderr, "bp doc delete task task-801") {
				t.Errorf("the human arm tells the caller to dispose of a draft that does not exist:\n%s", stderr)
			}
		})
	}
}

// A GENUINE DISCARD FAILURE IS STILL RESIDUE. Two arms, each in both shapes:
// the refusal was duplicate_of but the discard failed for another reason (500),
// and the discard 404'd after a refusal that is NOT duplicate_of (no server-side
// discard happened, so a 404 is not the known already-gone answer).
func TestCreatePublishGenuineDiscardFailureIsStillResidue(t *testing.T) {
	arms := []struct {
		name          string
		publishStatus int
		publishBody   string
		discardStatus int
		discardBody   string
	}{
		{"duplicate_of then 500", http.StatusConflict, dupRefusalBody,
			http.StatusInternalServerError, `{"error":{"code":"internal_error","message":"boom"}}`},
		{"non-duplicate then 404", http.StatusUnprocessableEntity, wallUnknownTagPublishBody, 0, ""},
	}
	for _, arm := range arms {
		for _, shape := range []string{"json", ""} {
			t.Run(arm.name+"/output="+shape, func(t *testing.T) {
				led := &createPublishRefusalLedger{
					createdDraftID: "drafts.task-802",
					publishStatus:  arm.publishStatus,
					publishBody:    arm.publishBody,
					refuseDiscard:  true,
					discardStatus:  arm.discardStatus,
					discardBody:    arm.discardBody,
				}
				srv := led.serve(t)

				code, stdout, stderr := runCreateShape(t, shape, srv.URL)
				if code != exitGeneric {
					t.Fatalf("exit = %d, want exitGeneric (%d)", code, exitGeneric)
				}
				if len(led.discarded) != 1 {
					t.Fatalf("discardDraft calls = %v, want 1", led.discarded)
				}
				if shape == "json" {
					d := decodeCreateRefusalDetails(t, stdout)
					if *d.Discarded {
						t.Errorf("draft_discarded = true on a genuine discard failure")
					}
					if d.Residue != residueDiscardFailed || d.DiscardError == "" {
						t.Errorf("residue=%q discard_error=%q, want %q and a reason", d.Residue, d.DiscardError, residueDiscardFailed)
					}
					return
				}
				if !strings.Contains(stderr, "residue["+residueDiscardFailed+"]") {
					t.Errorf("a genuine discard failure was not named as residue:\n%s", stderr)
				}
				if !strings.Contains(stderr, "bp doc delete task task-802") {
					t.Errorf("the surviving draft has no disposal remedy:\n%s", stderr)
				}
			})
		}
	}
}
