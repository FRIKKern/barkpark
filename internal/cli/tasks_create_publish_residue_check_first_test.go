package cli

// When the publish MAY have landed, the residue must not call the row a draft
// only, and must not offer `bp doc delete` before the person has looked
// (#26844 review, rev26733). `bp doc delete task <id>` deletes the PUBLISHED
// task too (Content.delete_document), so "DRAFT ONLY … OR delete it" after a
// publish that landed is a way to lose a real task.

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// checkFirst asserts the residue text never claims DRAFT ONLY and never offers
// the delete before the `bp task get` check.
func checkFirst(t *testing.T, label, text, bareID string) {
	t.Helper()
	if strings.Contains(text, "DRAFT ONLY") {
		t.Errorf("%s: claims DRAFT ONLY though the publish may have landed:\n%s", label, text)
	}
	get := strings.Index(text, "bp task get "+bareID)
	if get < 0 {
		t.Errorf("%s: does not say to check with bp task get %s first:\n%s", label, bareID, text)
	}
	if del := strings.Index(text, "bp doc delete"); del >= 0 && (get < 0 || del < get) {
		t.Errorf("%s: offers bp doc delete before the check:\n%s", label, text)
	}
}

func TestMaybePublishedResidueChecksBeforeOfferingDelete(t *testing.T) {
	for _, class := range []string{
		residuePublishAmbiguousTransport,
		residuePublishAmbiguousServerFault,
		residuePublishResultUnreadable,
		residuePublishResendKeyRefused,
		residuePublishResendRefused,
	} {
		var so, se bytes.Buffer
		renderTaskCreateResidue(&writer{stdout: &so, stderr: &se}, class, "drafts.task-970", "task-970")
		checkFirst(t, class, se.String(), "task-970")
	}
}

func TestMaybePublishedResidueEndToEnd(t *testing.T) {
	_, _, stderr, _ := runScriptedPublish(t, [2]string{"500", fault500}, [2]string{"422", keyReused422})
	checkFirst(t, "publish 500 then 422", stderr, "task-950")
}

// A publish the server definitively refused, whose discard then failed, IS a
// draft only: that residue keeps its words.
func TestDiscardFailedResidueStillSaysDraftOnly(t *testing.T) {
	var so, se bytes.Buffer
	renderTaskCreateResidue(&writer{stdout: &so, stderr: &se}, residueDiscardFailed, "drafts.task-971", "task-971")
	if !strings.Contains(se.String(), "DRAFT ONLY") {
		t.Fatalf("the discard_failed residue lost its DRAFT ONLY line:\n%s", se.String())
	}
}

// The MCP task_create tool shares the remedy: a publish that errored in
// transport or answered 5xx may have landed; a 4xx did not.
func TestMCPPublishFailureRemedyChecksFirstWhenItMayHaveLanded(t *testing.T) {
	checkFirst(t, "mcp transport", mcpPublishFailureRemedy(0, errors.New("eof"), "drafts.task-972", "task-972"), "task-972")
	checkFirst(t, "mcp 500", mcpPublishFailureRemedy(500, nil, "drafts.task-972", "task-972"), "task-972")

	if got := mcpPublishFailureRemedy(422, nil, "drafts.task-972", "task-972"); !strings.Contains(got, "DRAFT ONLY") {
		t.Fatalf("a refused (4xx) MCP publish lost its DRAFT ONLY remedy:\n%s", got)
	}
}

const notFound404 = `{"error":{"code":"not_found","message":"document not found"}}`

// #26844 review round 3: attempt 1 committed (the publish removed the draft)
// and answered 500, so the resend's publish answered not_found. A 4xx on a
// RESEND is not a definite refusal: an earlier attempt may have published. On
// 4387843e60 this discarded, then printed DRAFT ONLY and offered the delete.
func TestTaskCreatePublishNotFoundOnAResendKeepsTheDraftAndChecksFirst(t *testing.T) {
	code, so, se, kinds := runScriptedPublish(t, [2]string{"500", fault500}, [2]string{"404", notFound404})
	for _, k := range kinds {
		if k == "discardDraft" {
			t.Fatalf("discardDraft was sent after a resend's 4xx; an earlier attempt may have published: %v", kinds)
		}
	}
	if code != exitAmbiguous {
		t.Fatalf("exit = %d, want exitAmbiguous (%d)\nstdout=%s\nstderr=%s", code, exitAmbiguous, so, se)
	}
	checkFirst(t, "publish 500 then 404", se, "task-950")
}

// Pin: a 4xx on the FIRST publish send is still a definite refusal, and the
// draft this run created is discarded as before.
func TestTaskCreatePublishNotFoundOnTheFirstSendStillDiscards(t *testing.T) {
	code, _, _, kinds := runScriptedPublish(t, [2]string{"404", notFound404})
	if code == exitAmbiguous {
		t.Fatalf("a first-send 4xx was called ambiguous")
	}
	discarded := false
	for _, k := range kinds {
		discarded = discarded || k == "discardDraft"
	}
	if !discarded {
		t.Fatalf("a first-send 4xx no longer discards the draft: %v", kinds)
	}
}
