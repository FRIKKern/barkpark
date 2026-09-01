package cli

import (
	"strings"
	"testing"
)

// THE USER-VISIBLE PAYLOAD OF THE CONSOLIDATION.
//
// The census found five of eight decoders never declared `hint`, so a refusal
// could arrive with its remedy stripped — the server said what to do and the
// CLI dropped that sentence on the floor. This file pins the surfaces where
// that is now fixed, using the hint text the server actually composes.
//
// It also pins, deliberately and by name, the one user-visible surface where
// the hint is STILL not printed, so the omission stays a recorded decision
// rather than becoming a silent regression the next reader has to rediscover.

// A real not_ready refusal: api/lib/barkpark/content/errors.ex registers a
// hint for this code, and it is the sentence that unsticks the caller.
const notReadyBody = `{"error":{"code":"not_ready",` +
	`"message":"the task isn't claimable",` +
	`"hint":"re-claim with your own worker id to renew the lease"}}`

// bp doctor's task_ready probe reported the CODE and dropped the remedy — it
// named the fault and withheld the fix.
func TestDoctorReadyLineCarriesTheRemedy(t *testing.T) {
	got := summarizeReadyResult([]byte(notReadyBody), false)
	if !strings.Contains(got, "not_ready") {
		t.Errorf("lost the code:\n%s", got)
	}
	if !strings.Contains(got, "re-claim with your own worker id") {
		t.Errorf("the doctor line names the fault and withholds the server's fix:\n%s", got)
	}
	// A refusal with no hint stays exactly as terse as it was.
	terse := summarizeReadyResult([]byte(`{"error":{"code":"forbidden"}}`), false)
	if terse != "task_ready returned forbidden" {
		t.Errorf("a hintless refusal changed shape: %q", terse)
	}
}

// The webhook proxy's upstream detail is the ONLY thing an operator sees about
// an instance's refusal, so dropping the upstream's own remedy leaves them a
// fault with no next step.
func TestWebhookUpstreamDetailCarriesTheRemedy(t *testing.T) {
	got := upstreamDetail([]byte(notReadyBody))
	if !strings.Contains(got, "the task isn't claimable") {
		t.Errorf("lost the message:\n%s", got)
	}
	if !strings.Contains(got, "re-claim with your own worker id") {
		t.Errorf("the upstream detail withholds the server's fix:\n%s", got)
	}
	// Message-only upstream envelopes are unchanged.
	plain := upstreamDetail([]byte(`{"error":{"code":"c","message":"just a message"}}`))
	if plain != "just a message" {
		t.Errorf("a hintless upstream detail changed shape: %q", plain)
	}
	// A non-envelope detail still falls through to its own handling.
	if got := upstreamDetail(nil); got != "(no detail)" {
		t.Errorf("empty detail = %q, want \"(no detail)\"", got)
	}
}

// `bp task create`'s dedup refusal — the one that was unappealable.
func TestTaskCreateRefusalCarriesTheRemedy(t *testing.T) {
	got := mutateErrorMessage(409, []byte(notReadyBody))
	if !strings.Contains(got, "hint: re-claim with your own worker id") {
		t.Errorf("task create dropped the server's remedy:\n%s", got)
	}
}

// THE RECORDED EXCEPTION. apiclient.humanAPIError feeds a ONE-LINE TUI status
// bar; its display budget (a 200-rune clamp) is pinned by its own test and is
// an owner decision, not an envelope decision. The shared parser exposes the
// hint — apierr.Envelope.HintLine() — so surfacing it there is a one-line
// change whenever that owner call is made. Until then this test states the
// omission out loud, so nobody reads the consolidation as having covered it.
func TestTuiStatusBarHintIsAKnownGap(t *testing.T) {
	// classifyError, the CLI's own refusal path, DOES carry the hint — the
	// contrast is the point: this is a surface decision, not a parser gap.
	ae := classifyError(409, []byte(notReadyBody))
	if ae.serverHint != "re-claim with your own worker id to renew the lease" {
		t.Errorf("the CLI refusal path lost the hint it has always carried: %q", ae.serverHint)
	}
}
