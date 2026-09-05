package cli

// tasks_create_ambiguous_write.go — THE ANSWER THAT NEVER ARRIVED.
//
// task-f81c88e2c54f8e57: `bp task create … --publish --yes` printed nothing,
// exited non-zero, and the row was on the ledger; the operator's retry was then
// refused as a duplicate of the row the first call had silently created. Four
// occurrences in one day across two lanes.
//
// THE SILENT PATH, NAMED. Every failure arm of runTaskCreate spoke only through
// out.userErr / out.errf — stderr. Not one of them reached renderErrorEnvelope,
// which is how every OTHER refusal in this CLI honours the `-o json` contract
// (usageErrHintf, errors.go:854; useErrorDetailed, errors.go:610). So in the
// machine shapes — the shape a script gets, and the shape `bp` resolves for a
// non-TTY caller — stdout carried NOTHING while the exit code said "failed" and
// the server said "committed". A caller reading stdout, which is the documented
// machine channel, saw an empty stream and an exit code it could not classify.
//
// TWO THINGS ARE FIXED HERE, AND THEY ARE DIFFERENT THINGS:
//
//  1. The channel: every ambiguous arm now emits the canonical
//     {"ok":false,"error":{…}} envelope on stdout in json/yaml, AND says the
//     same thing on stderr in every shape. The human line is printed in machine
//     mode too, deliberately — stdout stays a single parseable document, and the
//     one failure a person must never miss is the one that may have written.
//  2. The verdict: the exit code is exitAmbiguous (9), distinct from every
//     definite refusal, because the correct next move is a READ and not a retry.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// ambiguousWriteCode is the envelope `code` every ambiguous-write arm reports.
// Deliberately NOT one of the server's codes: no server ever raises it, and
// borrowing one would make "we never heard back" indistinguishable from a
// refusal the server actually pronounced.
const ambiguousWriteCode = "write_ambiguous"

// The ambiguity classes. The two publish-leg names are the SAME strings as the
// residue classes in tasks_create_cmd.go on purpose — a caller who sees
// residue[publish_ambiguous_transport] on stderr and class
// "publish_ambiguous_transport" in the JSON envelope is looking at one event,
// not two.
const (
	// ambiguityCreateAnswerLost: the CREATE request left and no response came
	// back. This is the worst shape in the set — the create mutation is exactly
	// the call that was supposed to hand back the new row's id, so there is no
	// id to re-read and the only handle is the title.
	ambiguityCreateAnswerLost = "create_answer_lost"
	// ambiguityCreateServerFault: the CREATE answered 5xx, which can hide a
	// write that committed before the failure.
	ambiguityCreateServerFault = "create_server_fault"
	// ambiguityCreateResultUnreadable: the CREATE answered 2xx and echoed no
	// usable id. The row is on the server; this process cannot name it.
	ambiguityCreateResultUnreadable = "create_result_unreadable"
)

// taskCreateAmbiguityClasses maps each class to the sentence that says what is
// unknown. Closed set, iterated by TestTaskCreateAmbiguityClassesAreEnumerated
// so a future arm cannot be added without a name and a why.
var taskCreateAmbiguityClasses = map[string]string{
	ambiguityCreateAnswerLost:          "the create request was sent and no response came back — it may have committed",
	ambiguityCreateServerFault:         "the create answered a server fault, which can hide a write that committed before the failure",
	ambiguityCreateResultUnreadable:    "the create answered 2xx but echoed no id — the row exists and this process cannot name it",
	residuePublishAmbiguousTransport:   "the publish request was sent and no response came back — it may have committed",
	residuePublishAmbiguousServerFault: "the publish answered a server fault, which can hide a write that committed before the failure",
	residuePublishResultUnreadable:     "the publish answered 2xx but echoed no record, so whether a published twin exists is unknown",
}

// ambiguousWrite is one ambiguous outcome, fully described.
type ambiguousWrite struct {
	// class is one of the constants above.
	class string
	// docID is the BARE id to re-read, "" when no id ever came back (the create
	// leg). Never guessed: an id this process did not receive is not written
	// here.
	docID string
	// title is the caller's supplied title — the ONLY handle when docID is "".
	title string
	// detail is the underlying transport error or server message, verbatim.
	detail string
	// leg names which request was in flight ("create" / "publish"), for the
	// human line.
	leg string
}

// checkCommand is the ONE command the operator should run next. An id beats a
// search every time, so it is preferred whenever this process actually received
// one.
func (a ambiguousWrite) checkCommand() string {
	if id := strings.TrimPrefix(a.docID, "drafts."); id != "" {
		return "bp task get " + id
	}
	return fmt.Sprintf("bp search query %q", a.title)
}

// renderAmbiguousWrite is the single seam every ambiguous `bp task create`
// outcome funnels through. It ALWAYS speaks on stderr (in every output shape),
// and in json/yaml it ALSO emits the canonical error envelope on stdout — the
// half that was missing and that made this failure invisible to every scripted
// caller. Returns exitAmbiguous.
func renderAmbiguousWrite(out *writer, a ambiguousWrite) int {
	why := taskCreateAmbiguityClasses[a.class]
	if why == "" {
		why = "unclassified"
	}
	leg := a.leg
	if leg == "" {
		leg = "write"
	}
	check := a.checkCommand()

	msg := fmt.Sprintf("task create: the %s request WAS SENT and may have landed — %s", leg, why)

	// stderr, unconditionally. The stdout envelope below is the machine
	// channel; this is the one a person reads, and a write that may have
	// committed is not a thing to hide behind an output flag.
	out.userErr("%s: %s", msg, a.detail)
	out.errf("  ambiguous[%s]: the task may or may not have been filed — do NOT blind-retry, a retry lands a second row or is refused as a duplicate of the first.", a.class)
	if id := strings.TrimPrefix(a.docID, "drafts."); id != "" {
		out.errf("  doc_id: %s", id)
	} else {
		out.errf("  doc_id: unknown — the create response that would have named it never arrived; the title is the only handle.")
	}
	out.errf("  check with: %s", check)

	details, _ := json.Marshal(map[string]any{
		"class":         a.class,
		"sent":          true,
		"landed":        "unknown",
		"doc_id":        strings.TrimPrefix(a.docID, "drafts."),
		"title":         a.title,
		"check_command": check,
		"detail":        a.detail,
	})
	renderErrorEnvelopeDetailed(out, ambiguousWriteCode, msg+": "+a.detail, "", "check with: "+check, details)
	return exitAmbiguous
}

// ── The retry, made survivable ────────────────────────────────────────────
//
// The second half of the defect: once an ambiguous first attempt has landed a
// row, the operator's natural retry meets the dedup wall
// (api/lib/barkpark/content/errors.ex:741 → 409 `duplicate_of`, details
// {duplicate_of, similar, advise}). That refusal NAMES the incumbent, and the
// CLI printed it as one more line in a generic details blob — indistinguishable
// from a fresh "somebody else already filed this" conflict. It is not: on this
// path the incumbent is the caller's OWN row, from the attempt they were never
// told about, and the right move is to resume it, not to re-file it.

// incumbentTaskID pulls the surviving row's id out of a dedup refusal body:
// details.duplicate_of (a bare id string) first, then the first named `similar`
// candidate. Returns "" when the refusal names nothing — a resume block with no
// id to resume is worse than none.
func incumbentTaskID(body []byte) string {
	env, ok := apierr.Parse(body)
	if !ok || len(env.Details) == 0 {
		return ""
	}
	var d struct {
		DuplicateOf string `json:"duplicate_of"`
	}
	if json.Unmarshal(env.Details, &d) == nil && d.DuplicateOf != "" {
		return strings.TrimPrefix(d.DuplicateOf, "drafts.")
	}
	similar, _ := env.Candidates()
	for _, c := range similar {
		if c.ID != "" {
			return strings.TrimPrefix(c.ID, "drafts.")
		}
	}
	return ""
}

// renderDuplicateResume turns a dedup refusal into a resume. It names the
// surviving id, says WHY it is probably the caller's own row, and gives the
// exact commands for both readings — resume it, or (only if the caller is sure)
// declare it distinct. Reports whether it printed anything.
func renderDuplicateResume(out *writer, id string) bool {
	if id == "" {
		return false
	}
	out.errf("  THE ROW ALREADY EXISTS: %s", id)
	out.errf("  if a previous attempt of yours ended ambiguously (exit %d), this IS that row — not a fresh conflict, and nothing new needs filing.", exitAmbiguous)
	out.errf("  resume it:            bp task get %s", id)
	out.errf("  publish it in place:  %s", taskPublishCommand(id))
	out.errf("  only if it is genuinely a different task:  bp task create … --set 'distinct_from:=[\"%s\"]'", id)
	return true
}

// duplicateResumeDetails is the machine half of the block above.
func duplicateResumeDetails(id string) json.RawMessage {
	d, _ := json.Marshal(map[string]any{
		"duplicate_of":    id,
		"resume_command":  "bp task get " + id,
		"publish_command": taskPublishCommand(id),
	})
	return d
}

// renderTaskCreateRefusal is the DEFINITE half of the split: the server
// evaluated the request and said no, before any commit. Nothing landed, so
// there is nothing to go looking for — but two things were still missing here.
//
//   - Under `-o json` this arm printed nothing on stdout either. A refusal is
//     not ambiguous, but it is not invisible: the machine channel gets the
//     server's own code, message and details verbatim.
//   - A `duplicate_of` refusal names the incumbent, and after an ambiguous
//     earlier attempt that incumbent is the caller's OWN row. It is rendered as
//     a resume, and the exit code becomes exitConflict — "the world already
//     holds this" — instead of the undifferentiated exit 1 a duplicate shared
//     with every other refusal.
func renderTaskCreateRefusal(out *writer, leg string, status int, body []byte) int {
	out.userErr("task create: %s", mutateErrorMessage(status, body))

	id := incumbentTaskID(body)
	renderDuplicateResume(out, id)

	code, message := "refused", mutateErrorMessage(status, body)
	var details json.RawMessage
	if env, ok := apierr.Parse(body); ok {
		if env.Code != "" {
			code = env.Code
		}
		if env.Message != "" {
			message = env.Message
		}
		details = env.Details
	}
	if id != "" {
		details = duplicateResumeDetails(id)
	}
	hint := ""
	if id != "" {
		hint = "resume the existing row: bp task get " + id
	}
	renderErrorEnvelopeDetailed(out, code, leg+": "+message, "", hint, details)

	if id != "" {
		return exitConflict
	}
	return exitGeneric
}
