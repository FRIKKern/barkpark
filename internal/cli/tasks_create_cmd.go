package cli

// tasks_create_cmd.go — `bp task create`: file a NEW task document. A CLI
// built-in intercepted before manifest dispatch (the manifest `task` noun
// carries no `create` verb — the Tasks plugin declares only the eight
// lifecycle/read verbs, ls/ready/prime/get/claim/close/next/move). Task
// creation otherwise rides the GENERIC document mutate path (`bp doc create
// task`), which does NOT know the task schema's two required fields — so a bare
// `bp doc create task --set title=…` 422s with
// `kind: is required · lifecycle_status: is required`. This verb is the
// ergonomic, contract-correct front door: it injects the required defaults
// `kind:"task"` + `lifecycle_status:"open"` (both overridable via --set),
// requires a non-empty title (well-formedness — the server's authoring gate
// hard-stops title-only-empty anyway), and sends the SAME create mutation the
// server's `/v1/data/mutate/<dataset>` contract accepts.
//
// No server change and no manifest change: it composes the one mutate endpoint
// the doc path already uses, so the two never drift on the task contract.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// runTaskCreate handles `bp task create [<title>] [--title <t>]
// [--description <d>] [--set k=v]… [--publish]`. It returns the process exit
// code. Honors the global --dry-run (print the request, do not send), --yes
// (skip the prod write-guard), and -o json/yaml (structured receipt).
func runTaskCreate(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskCreateHelp(out)
		return exitOK
	}

	body, publish, err := parseTaskCreateArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printTaskCreateHelp(out) }, "%v", err)
	}

	// Well-formedness: a task with no title is the one thing the server's
	// authoring quality gate hard-stops, and an empty-title task is unusable in
	// every board/queue view. Reject it here with a friendly message rather than
	// round-tripping to a 409/422.
	//
	// title is kept (not re-derived) past this point: it is the one thing the
	// operator can search on if the CREATE mutation below answers ambiguously —
	// this write gets no server-assigned id back on a timeout or 5xx, so the
	// title is the only handle a re-check remedy has to offer.
	title, _ := body["title"].(string)
	if strings.TrimSpace(title) == "" {
		return usageErrf(out, func() { printTaskCreateHelp(out) },
			"a task needs a non-empty title (pass it positionally, via --title, or --set title=…)")
	}
	ensureTaskPortableBrief(body)

	// THE PUBLISH WALL, MOVED IN FRONT OF THE WRITE. `--publish` is
	// create-then-publish, and the server's wall runs on the SECOND mutation — so
	// a row that cannot clear it used to land the DRAFT anyway and exit non-zero,
	// leaving the unclaimable `drafts.task-N` phantom the caller had just been
	// told was "created". The pure half (label_spine) runs here, above the
	// --dry-run branch so a dry run validates too; the registry half (unknown_tag)
	// needs one read and runs below, still before anything is created.
	if publish {
		if ref := checkLabelSpineLocal(body); ref != nil {
			return renderPublishWallRefusal(out, ref)
		}
	}

	// The create mutation the server's mutate contract accepts. `_type` names the
	// schema; the required task fields + title/description/any --set overrides ride
	// flat at top level (the task write contract: fields are top-level, never
	// nested under content.*).
	createOp := map[string]any{"_type": "task"}
	for k, v := range body {
		createOp[k] = v
	}
	mutations := []map[string]any{{"create": createOp}}

	if g.dryRun {
		return taskCreateDryRun(out, ctx, mutations, publish)
	}

	// Prod write-guard parity with the manifest write path: a write against a
	// prod-looking target needs confirmation unless --yes, or unless the server
	// itself advertises production:false on /v1/meta (absence stays fail-closed).
	// Deliberately NOT confirmProdWrite: this path hard-aborts non-interactively.
	if isProdServer(ctx.Server) && !g.yes && !serverDeclaredNonProd(ctx.Server) {
		out.userErr("prod write to %s needs confirmation — re-run with --yes", ctx.Server)
		return exitGeneric
	}

	// E3, the half that needs a read: every weighted tag must ALREADY be a
	// published type:tag doc. This is the wall that turns a well-meaning retry
	// ("plausible tag names") into a SECOND phantom, so it is checked here — the
	// last point at which refusing still costs the server nothing.
	if publish {
		ref, blind := checkTagRegistry(ctx, body)
		if ref != nil {
			return renderPublishWallRefusal(out, ref)
		}
		if blind {
			// FAIL CLOSED, AND SAY SO. This branch used to print a note and
			// create anyway ("a blind client must not veto a legitimate
			// publish"). That reasoning weighs a refused legitimate publish
			// against a phantom draft, and the phantom is the one that costs
			// somebody else money: an unreadable registry under fleet load is
			// exactly the state in which the server's own unknown_tag wall then
			// refuses the publish, stranding the draft — and the caller, told
			// only that a check "did not run", retries with re-guessed tag
			// names and strands another. Six of the 23 stranded rows on the rail
			// were minted by that loop (dr-bl-w6-phantom-draft-twins-accumulate-
			// on-the-rail). Proceeding blind is a coin flip whose losing side
			// writes a row nobody can claim, so this refuses BEFORE the create,
			// with a named code and the ways out.
			//
			// The blast radius is bounded by checkTagRegistry itself: `blind` is
			// only ever true when the body carries weighted tags AND the read was
			// non-authoritative. A create with no tags never reaches here.
			return renderTagRegistryUnreadableRefusal(out, body)
		}
	}

	// ONE KEY BASE PER INVOCATION, SPLIT PER LEG. Minted here — after every
	// refusal that can be pronounced without a write, so a run that never sends
	// never burns one. The publish follow-up derives its own key from the same
	// base: the plug hashes (key, token, method, PATH) and NOT the body, and both
	// legs POST the same path, so sharing one key would replay the create's
	// response and the publish would silently never run (legKey says this at
	// length, tasks_create_idempotency.go).
	idemBase := newIdempotencyKey()

	httpStatus, respBody, _, err := sendMutationsIdempotent(sendCreateTaskMutations, ctx, mutations, legKey(idemBase, "create"))
	if err != nil {
		// TRANSPORT ERROR (the DBConnection-under-fleet-load class, run.go's 30s
		// client timeout being the common trigger): the request may never have
		// reached the server, or may have landed and the RESPONSE was what got
		// lost — either way this is the one bp write with no server-assigned id
		// to re-check, because the create mutation is exactly the call that was
		// supposed to hand one back. The sibling ledger verbs (stamp/close/pulse)
		// answer a 5xx by re-reading the row at its known id; create has no id to
		// re-read, so the remedy is a search on the title the caller supplied.
		//
		// task-f81c88e2c54f8e57: this used to speak on stderr ONLY, so under
		// `-o json` the whole event was invisible — empty stdout, exit 1, row on
		// the ledger. renderAmbiguousWrite owns both channels and the distinct
		// exit code now.
		return renderAmbiguousWrite(out, ambiguousWrite{
			class: ambiguityCreateAnswerLost, leg: "create", title: title,
			detail: err.Error(),
		})
	}
	if httpStatus < 200 || httpStatus >= 300 {
		if httpStatus >= 500 {
			// 5xx: the server answered, but a 500-class response can still hide a
			// write that committed before the failure — "a 5xx can hide a write
			// that landed" is the same doctrine stamp/close/pulse already apply on
			// their read-back branch. create has no id to re-read, so the remedy
			// is the same title search as the transport-error branch.
			return renderAmbiguousWrite(out, ambiguousWrite{
				class: ambiguityCreateServerFault, leg: "create", title: title,
				detail: mutateErrorMessage(httpStatus, respBody),
			})
		}
		// 4xx (validation/auth/not_found/conflict/…): the server REFUSED before
		// any commit, so nothing landed and there is nothing to go hunting for —
		// printing the ambiguity caveat here would send the operator searching
		// for a write that was never attempted.
		return renderTaskCreateRefusal(out, "create", httpStatus, respBody)
	}
	// THE AUTHORING ADVISORIES, WHICH THIS VERB USED TO DROP ON THE FLOOR.
	// The mutate SUCCESS envelope may carry `warnings: [{code,severity,message}]`
	// — `Barkpark.Content.Warnings.drain/0` folds in whatever the task quality
	// gate collected while the batch applied, and the one that matters most here
	// is `merge_gate_unflagged`: a criterion that OPENS with the MERGE-GATED
	// marker but carries no `"merge_gate": true`. That row is UNDER-DECLARED —
	// `bp task stamp --met` refuses it on the prose fallback while the lead's
	// close-time autostamp, which keys on the FLAG alone, never flips it — so the
	// criterion can be closed by nobody. The plugin that raises it says the bp CLI
	// prints it (`emitWarnings`), and on the manifest dispatch path it does; but
	// `bp task create` is a BUILT-IN that composes /v1/data/mutate itself and went
	// from `sendCreateTaskMutations` straight to the receipt, so on the one path
	// that FILES criteria the warning reached nobody. Collected here, rendered by
	// renderTaskCreated.
	warnings := mutateWarnings(respBody)

	// WRITE-FENCE EXEMPTION (builtinWriteCensus, dispCannotLie): nothing below
	// renders without a SERVER-GENERATED id out of results[0], and the publish
	// arm repeats the same requirement on its own response. That is the fence's
	// own discriminator plus a field check, not a status.
	created, ok := firstMutationRecord(respBody)
	if !ok {
		// A 2xx WITH NO ID IS NOT A REFUSAL. The server accepted the mutation and
		// said so; what is missing is the echo that would let this process name
		// the row. Reporting it as a plain error told the caller "it failed" about
		// a write that almost certainly succeeded — the same lie, one status code
		// later. It is an ambiguity with a title handle, like the transport arm.
		return renderAmbiguousWrite(out, ambiguousWrite{
			class: ambiguityCreateResultUnreadable, leg: "create", title: title,
			detail: "the mutate response carried no usable id",
		})
	}

	// The server hands back a "drafts.<type>-<n>" id; the BARE published id (used
	// by publish/get) is that with the "drafts." prefix stripped.
	draftID := created.id
	bareID := strings.TrimPrefix(draftID, "drafts.")

	// The record the receipt speaks for. Publishing writes a SECOND record (the
	// published twin), and that is the one the receipt then describes, so the
	// publish response's document replaces the draft's.
	record := created

	if publish {
		// Publish is a second mutation over the same scoped-mutate endpoint; the
		// server's Content.publish_document derives the drafts. twin from the bare
		// id. A publish failure still leaves the draft in place — the pre-flight
		// above pre-empts the two walls a client can know about, and what reaches
		// here is the residue (duplicate_of, a registry we could not read, a rule
		// this binary predates). The draft is NOT deleted: it holds the caller's
		// authored title/description/criteria and the refusal is usually one edit
		// from clearing. It is NAMED instead — renderOrphanedDraftRemedy prints the
		// `drafts.` id, the consequence, and both exits.
		pubOp := map[string]any{"publish": map[string]any{"id": bareID, "type": "task"}}
		pStatus, pBody, _, pErr := sendMutationsIdempotent(sendTaskMutations, ctx, []map[string]any{pubOp}, legKey(idemBase, "publish"))
		if pErr != nil {
			// RESIDUE, NOT DEBRIS TO SWEEP. A transport error means the publish
			// may have LANDED and only the response was lost, so discarding here
			// could throw away the draft twin of a row that is already on the
			// board. The class is named instead (see taskCreateResidueClasses).
			//
			// Unlike the create leg, this one KNOWS the id — the create response
			// named it seconds ago — so the caller gets `bp task get <id>` rather
			// than a title search.
			code := renderAmbiguousWrite(out, ambiguousWrite{
				class: residuePublishAmbiguousTransport, leg: "publish", docID: bareID,
				title: title, detail: pErr.Error(),
			})
			renderTaskCreateResidue(out, residuePublishAmbiguousTransport, draftID, bareID)
			return code
		}
		if pStatus < 200 || pStatus >= 300 {
			if pStatus >= 500 {
				// Same ambiguity as the create path's 5xx arm: a server fault can
				// hide a publish that committed before the failure. Not discarded.
				code := renderAmbiguousWrite(out, ambiguousWrite{
					class: residuePublishAmbiguousServerFault, leg: "publish", docID: bareID,
					title: title, detail: mutateErrorMessage(pStatus, pBody),
				})
				renderTaskCreateResidue(out, residuePublishAmbiguousServerFault, draftID, bareID)
				return code
			}
			// UNDER -o json/yaml THE REFUSAL IS THE ANSWER, and it goes to
			// STDOUT as one envelope. The human arm below prints the refusal,
			// the duplicate resume, and then the discard's own outcome as
			// separate stderr blocks; a machine caller cannot be handed three
			// documents (json.load reads the FIRST value and stops), so the
			// discard runs QUIETLY first and its outcome rides inside the one
			// envelope's details as draft_discarded/discard_error. Exit code is
			// unchanged: exitGeneric, exactly what discardCreatedTaskDraft
			// returns on every one of its arms.
			if code, machine := renderCreatePublishRefusalEnvelope(out, ctx, pStatus, pBody, draftID, bareID); machine {
				return code
			}
			out.userErr("task create: created %s but publish failed: %s", draftID, mutateErrorMessage(pStatus, pBody))
			// A duplicate_of refusal on the PUBLISH leg names the incumbent, and
			// after an ambiguous earlier attempt that incumbent is the caller's
			// own row. Say so before the draft is discarded below, so the exit is
			// a resume instruction and not a dead end.
			renderDuplicateResume(out, incumbentTaskID(pBody))
			// A 4xx IS a refusal: the server evaluated the wall (duplicate_of,
			// invalid_epic_paper_quality, dedup_unavailable, a rule this binary
			// predates) and committed nothing. The draft this run created seconds
			// ago is therefore the WHOLE row — no published twin exists — so it is
			// discarded in the same run rather than left as a phantom the caller
			// must be talked through disposing of. This is `bp doc discard-draft`
			// on a never-published document, i.e. the guard's --delete-unpublished
			// semantics (discard_draft_guard.go): here the absence of a twin is not
			// probed but KNOWN, because this process created the draft.
			return discardCreatedTaskDraft(out, ctx, draftID, bareID)
		}
		// PDS wave 48: "published" used to be asserted here off the 2xx alone.
		// It is now read off the record the publish mutation returned, so a
		// publish that did not produce a published twin cannot print one.
		published, pok := firstMutationRecord(pBody)
		if !pok {
			// The last of the six ambiguous arms, and the subtlest: a 2xx with no
			// record. It already said the right sentence — it just said it on
			// stderr only, at the same exit code as a definite refusal.
			code := renderAmbiguousWrite(out, ambiguousWrite{
				class: residuePublishResultUnreadable, leg: "publish", docID: bareID,
				title: title, detail: "the publish response carried no result",
			})
			renderTaskCreateResidue(out, residuePublishResultUnreadable, draftID, bareID)
			return code
		}
		record = published
		// The publish mutation re-runs the same before_save gate, so it can raise
		// the same advisory again; dedupeMutateWarnings keeps one copy of each.
		warnings = append(warnings, mutateWarnings(pBody)...)
	}

	if !publish {
		// THE DRAFT-FIRST NAG. `bp task create` defaults to a draft while the MCP
		// `task_create` tool defaults publish TRUE — 17 of the 23 rows stranded on
		// the rail were planner-filed sub-tasks created here and never published,
		// by callers who had no idea the two front doors disagree. One line, on
		// stderr so the stdout receipt (human and -o json) is unchanged byte for
		// byte, said unconditionally on the no---publish path rather than off the
		// server-echoed on_board (which is silent whenever the server echoes no
		// _draft — the one shape where the caller most needs telling).
		out.errf("%s", taskDraftFirstNotice(bareID))
	}

	return renderTaskCreated(out, draftID, record, dedupeMutateWarnings(warnings))
}

// taskDraftFirstNotice is the one line a draft-first create owes its caller:
// what the row is NOT (on the board, on `bp task ready` as a published pair)
// and the one command that changes it. taskPublishCommand owns the spelling —
// `task` has no publish verb, so this must never say `bp task publish`.
func taskDraftFirstNotice(bareID string) string {
	return "note: created as a DRAFT — not on the board and not in `bp task ready` as a pair; publish with: " + taskPublishCommand(bareID)
}

// THE RESIDUE SET. Every state in which `bp task create --publish` can end
// without the draft it wrote being either published or discarded. It is a
// CLOSED, NAMED list rather than a catch-all sentence, because the caller who
// finds a `drafts.` row on the queue needs to know which of these produced it —
// and because a future arm added without a name here reds
// TestTaskCreateResidueSetIsEnumerated.
const (
	// residuePublishAmbiguousTransport: the publish request never came back. The
	// publish may have landed; discarding could destroy the draft twin of a
	// published row.
	residuePublishAmbiguousTransport = "publish_ambiguous_transport"
	// residuePublishAmbiguousServerFault: the publish answered 5xx, which can
	// hide a write that committed before the failure.
	residuePublishAmbiguousServerFault = "publish_ambiguous_server_fault"
	// residuePublishResultUnreadable: the publish answered 2xx but echoed no
	// record, so whether a published twin exists is unknown.
	residuePublishResultUnreadable = "publish_result_unreadable"
	// residueDiscardFailed: the publish was definitively refused and the discard
	// that would have cleaned up was itself refused or unreachable.
	residueDiscardFailed = "discard_failed"
)

// taskCreateResidueClasses maps each residue name to why the draft is still
// there. Iterated by the test that asserts the set is closed.
var taskCreateResidueClasses = map[string]string{
	residuePublishAmbiguousTransport:   "the publish request never came back, so it may have landed — discarding could destroy the draft twin of a row that IS on the board",
	residuePublishAmbiguousServerFault: "the publish answered a server fault, which can hide a write that committed before the failure",
	residuePublishResultUnreadable:     "the publish answered 2xx but echoed no record, so whether a published twin exists is unknown",
	residueDiscardFailed:               "the publish was refused and the follow-up discard could not be performed",
}

// renderTaskCreateResidue names the residue class on stderr and then prints the
// existing orphaned-draft remedy. Naming the class first is the point: "a draft
// was left" is a fact, and the class says WHY it was left rather than cleaned
// up, which is the difference between a caller who retries into a second
// phantom and one who re-reads the row.
func renderTaskCreateResidue(out *writer, class, draftID, bareID string) {
	why := taskCreateResidueClasses[class]
	if why == "" {
		why = "unclassified"
	}
	out.errf("  residue[%s]: the draft was NOT discarded — %s.", class, why)
	renderOrphanedDraftRemedy(out, draftID, bareID)
}

// discardCreatedTaskDraft removes the draft this run just created, after the
// server definitively REFUSED to publish it. It sends the same `discardDraft`
// mutation `bp doc discard-draft` rides (Content.Mutations apply_one
// "discardDraft" -> Content.discard_draft), which on a never-published document
// deletes the row — the behaviour discard_draft_guard.go exists to stop a human
// from stumbling into blind. It is correct HERE precisely because the guard's
// three-state question is already answered: this process created the draft
// moments ago and the publish that would have minted its twin was refused, so
// the twin is known-absent rather than probed-absent.
//
// Returns the process exit code: non-zero either way (the create --publish did
// not do what was asked), but the two paths differ in what is left on the
// server, and both say which.
func discardCreatedTaskDraft(out *writer, ctx manifest.Context, draftID, bareID string) int {
	if why := discardCreatedTaskDraftQuiet(ctx, bareID); why != "" {
		out.errf("  %s", why)
		renderTaskCreateResidue(out, residueDiscardFailed, draftID, bareID)
		return exitGeneric
	}
	out.errf("  discarded %s — the refused publish left NO draft behind (nothing to claim, nothing on the queue).", draftID)
	out.errf("  nothing was kept: re-file with the refusal above fixed, e.g. bp task create --publish …")
	return exitGeneric
}

// discardCreatedTaskDraftQuiet is the MUTATION half of discardCreatedTaskDraft
// with no rendering at all: it returns "" when the draft is gone, and otherwise
// the one sentence saying why it is still there. It exists because the two
// output shapes need the same side effect and DIFFERENT renderings — stderr
// prose for a human, a `discard_error` key inside one JSON envelope for a
// script — and doing the discard in two places is how the two drift.
func discardCreatedTaskDraftQuiet(ctx manifest.Context, bareID string) string {
	op := map[string]any{"discardDraft": map[string]any{"id": bareID, "type": "task"}}
	status, body, err := sendTaskMutations(ctx, []map[string]any{op}, "")
	switch {
	case err != nil:
		return fmt.Sprintf("the follow-up discard never reached the server (%v)", err)
	case status < 200 || status >= 300:
		return "the follow-up discard was refused: " + mutateErrorMessage(status, body)
	}
	return ""
}

// renderCreatePublishRefusalEnvelope is the -o json/yaml answer to a publish leg
// the server definitively REFUSED (a 4xx: the publish wall's unknown_tag /
// label_spine / duplicate_of, or any rule this binary predates). It performs the
// same cleanup the human path does — the draft this run created seconds ago is
// the whole row, so it is discarded — and then writes ONE envelope to stdout
// carrying the server's own code, message, hint and details, plus the four
// client-side facts a caller cannot get from the server's body: which draft was
// created, which bare id it would have become, whether the cleanup succeeded,
// and the incumbent id when the refusal was a duplicate.
//
// The second return says whether the machine shape was taken at all; false means
// the caller must print its human block, unchanged.
func renderCreatePublishRefusalEnvelope(out *writer, ctx manifest.Context, status int, body []byte, draftID, bareID string) (int, bool) {
	if out.output != "json" && out.output != "yaml" {
		return 0, false
	}
	ae := classifyError(status, body)
	discardErr := discardCreatedTaskDraftQuiet(ctx, bareID)

	payload := map[string]any{
		"draft_id":        draftID,
		"task_id":         bareID,
		"draft_discarded": discardErr == "",
	}
	if discardErr != "" {
		payload["discard_error"] = discardErr
		payload["residue"] = residueDiscardFailed
	}
	if incumbent := incumbentTaskID(body); incumbent != "" {
		payload["duplicate_of"] = incumbent
	}
	if d := normalizeDetails(ae.details); d != nil {
		payload["server_details"] = d
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		raw = nil
	}
	msg := "task create: created " + draftID + " but publish failed: " + ae.errorMessage()
	renderErrorEnvelopeDetailed(out, ae.code, msg, ae.requestID, ae.hint(), json.RawMessage(raw))
	return exitGeneric, true
}

// renderTagRegistryUnreadableRefusal is the fail-closed answer to a tag registry
// this client could not read. It refuses BEFORE the create, so it carries the
// same "nothing was created" guarantee renderPublishWallRefusal does, and it is
// exitUsage for the same reason: no request was sent.
func renderTagRegistryUnreadableRefusal(out *writer, body map[string]any) int {
	if renderErrorEnvelopeDetailed(out, tagRegistryUnreadableCode,
		"task create --publish: refused before writing anything — the tag registry could not be read, so the tags on this row could NOT be checked",
		"",
		"nothing was created — no draft was left behind. Retry once `"+tagRegistryCommand+"` works, or file it as a draft now (`bp task create …` without --publish) and publish when the read works.",
		tagRegistryUnreadableDetails(body)) {
		return exitUsage
	}
	out.userErr("task create --publish: refused before writing anything — the tag registry could not be read, so the tags on this row could NOT be checked")
	out.errf("  code:  %s", tagRegistryUnreadableCode)
	if names := wallTagNames(body); len(names) > 0 {
		out.errf("  tags:  %s", strings.Join(names, ", "))
	}
	out.errf("  why:   every weighted tag must ALREADY be a published type:tag doc. Publishing blind is how a stranded `drafts.` row gets minted: the server refuses the publish and the draft stays.")
	out.errf("  fix:   retry once the registry read works —")
	out.errf("           %s   # the live vocabulary", tagRegistryCommand)
	out.errf("         or file it as a draft now and publish when the read works —")
	out.errf("           bp task create …            # without --publish")
	out.errf("           bp doc publish task <id> --yes")
	out.errf("  nothing was created — no draft was left behind.")
	return exitUsage
}

// tagRegistryUnreadableDetails is the machine payload for the fail-closed
// registry refusal: the tag names that could NOT be checked. A caller cannot
// re-derive them from the exit code, and they are exactly the list to re-check
// once the registry read works.
func tagRegistryUnreadableDetails(body map[string]any) json.RawMessage {
	names := wallTagNames(body)
	if len(names) == 0 {
		return nil
	}
	raw, err := json.Marshal(map[string]any{"unchecked_tags": names})
	if err != nil {
		return nil
	}
	return json.RawMessage(raw)
}

// tagRegistryUnreadableCode names the refusal. It is deliberately NOT one of the
// server's wall codes (label_spine / unknown_tag / duplicate_of / …): no server
// ever raises it, and borrowing one of theirs would make a client-side "we could
// not ask" indistinguishable from a server-side "we asked and the answer was no".
const tagRegistryUnreadableCode = "tag_registry_unreadable"

// wallTagNames lists the weighted tag names on body, for the refusal above. A
// malformed tags field yields nothing — the spine check upstream owns that
// complaint and this line is only ever decoration.
func wallTagNames(body map[string]any) []string {
	tags, ref := wallTagEntries(body)
	if ref != nil {
		return nil
	}
	names := make([]string, 0, len(tags))
	for _, entry := range tags {
		if name, ok := entry["tag"].(string); ok && name != "" {
			names = append(names, name)
		}
	}
	return names
}

// taskCreateRecord is the record the SERVER persisted for one mutation:
// results[].document, which the API builds with Envelope.render(doc, schema,
// caller) from the row it just wrote (PDS-D313 class A2 — a persisted-record
// echo). The create receipt reads every claim off this and never off the
// locally-built request map.
type taskCreateRecord struct {
	// id is the document id the server assigned — the echoed record's _id when
	// it carried one, else the mutation result's id.
	id string
	// draft is the record's _draft, and hasDraft says whether the server echoed
	// it at all. An un-echoed _draft is reported as unconfirmed, never guessed.
	draft    bool
	hasDraft bool
	// lifecycle is the record's stored lifecycle_status ("" when the server
	// echoed none).
	lifecycle string
}

// firstMutationRecord decodes the first result of a raw mutate response,
// including the document the server echoed back
// ({"results":[{"id":"drafts.task-N","document":{…}}]}). It reports false when
// the body does not decode or carries no usable id — the two cases in which
// nothing about the write can be claimed.
func firstMutationRecord(body []byte) (taskCreateRecord, bool) {
	var parsed struct {
		Results []struct {
			ID       string `json:"id"`
			Document *struct {
				ID        string  `json:"_id"`
				Draft     *bool   `json:"_draft"`
				Lifecycle *string `json:"lifecycle_status"`
			} `json:"document"`
		} `json:"results"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return taskCreateRecord{}, false
	}
	if len(parsed.Results) == 0 {
		return taskCreateRecord{}, false
	}
	r := parsed.Results[0]
	rec := taskCreateRecord{id: r.ID}
	if r.Document != nil {
		if r.Document.ID != "" {
			rec.id = r.Document.ID
		}
		if r.Document.Draft != nil {
			rec.draft, rec.hasDraft = *r.Document.Draft, true
		}
		if r.Document.Lifecycle != nil {
			rec.lifecycle = *r.Document.Lifecycle
		}
	}
	return rec, rec.id != ""
}

// renderTaskCreated is the create receipt, and it is PURE: the id, the
// publication status and the born lifecycle are all read off `rec` — the record
// the SERVER persisted — so a server that stored something else prints
// something else. `draftID` is the id the create mutation returned and is
// carried only so the machine receipt keeps naming the draft twin.
//
// tlv-s6 (TLV charter D14) put the born lifecycle in the receipt so a
// birth-as-considering is visible instead of silently assumed "open". PDS wave
// 48 fixed WHERE it comes from: it used to be `body["lifecycle_status"]`, the
// locally-built REQUEST map, under a comment claiming it was "the body value the
// server accepted". Since the CLI itself defaults that field into the request,
// the printed value could never disagree with what was sent — a tautology no
// test could have caught. A field the server did not echo is now reported as
// unknown rather than filled in from what we asked for.
// `warnings` are the server's authoring advisories for this write (see
// mutateWarnings). They are printed to stderr in EVERY output shape and also
// ride the machine receipt's `warnings` field. That is a deliberate divergence
// from renderSuccess, which shows advisories only in the human shapes and leaves
// json/yaml consumers to read the field: an advisory saying the row's WORDS and
// its SHAPE disagree describes a criterion that no verb will ever be able to
// close, and a scripted filer that does not know to look for a new field is
// exactly the caller that stranded four rows this way.
func renderTaskCreated(out *writer, draftID string, rec taskCreateRecord, warnings []mutateWarning) int {
	bareID := strings.TrimPrefix(rec.id, "drafts.")

	for _, w := range warnings {
		if w.Code != "" {
			out.errf("warning[%s]: %s", w.Code, w.Message)
			continue
		}
		out.errf("warning: %s", w.Message)
	}

	status := "unconfirmed"
	if rec.hasDraft {
		status = "published"
		if rec.draft {
			status = "draft"
		}
	}

	onBoard := rec.hasDraft && !rec.draft

	if out.machineOut() {
		receipt := map[string]any{
			"id":               bareID,
			"status":           status,
			"lifecycle_status": nil,
			// pds-bl-task-create-draft-at-rc0 — THE FIELD A SCRIPT CAN BRANCH ON.
			// `status` already said "draft", and it was still misread, because
			// `lifecycle_status: "open"` sits beside it and "open" is the BOARD's
			// word for ready. on_board answers the only question a caller of a
			// verb named "create the task" is actually asking.
			"on_board": onBoard,
		}
		// task-ee33b6f088b35bdb — THE RECEIPT NAMED A DOCUMENT THAT DOES NOT
		// EXIST. `draft` was emitted unconditionally off the CREATE leg's id, so
		// a SUCCESSFUL `--publish` printed
		// {"draft":"drafts.task-N","status":"published","on_board":true} — and
		// publishing CONSUMES the draft, so `bp doc get task drafts.task-N
		// --perspective raw` on that very id answers not_found (run against
		// guerrilla on the probe row task-ccd184a652f95f76). Every other field
		// here descends from the record the server PERSISTED (PDS wave 48); this
		// one descended from a leg whose document no longer existed by the time
		// the line was printed.
		//
		// It is the create path's own sin one field over: a TRUE-LOOKING LINE
		// pointing somewhere empty. A caller sweeping orphan drafts reads
		// `draft` and files `bp doc discard-draft` against a phantom; a caller
		// stashing it as the handle to its own row keeps an id that resolves to
		// nothing. The key is emitted only when the draft is KNOWN to exist —
		// that is exactly `rec.draft` on an echoed `_draft` (the same evidence
		// `status` and `on_board` are read off), never inferred from the create
		// leg and never guessed when the server echoed no `_draft` at all.
		if rec.hasDraft && rec.draft {
			receipt["draft"] = draftID
		}
		if len(warnings) > 0 {
			receipt["warnings"] = warnings
		}
		if rec.lifecycle != "" {
			receipt["lifecycle_status"] = rec.lifecycle
		}
		if !onBoard {
			receipt["publish_command"] = taskPublishCommand(bareID)
		}
		out.renderJSON(receipt)
		return exitOK
	}

	statusText := status
	if !rec.hasDraft {
		statusText = "publication unconfirmed — the server echoed no _draft"
	}
	bornText := "unknown — the server echoed no lifecycle_status"
	if rec.lifecycle != "" {
		bornText = rec.lifecycle
	}
	out.outf("created task %s (%s, lifecycle %s)", bareID, statusText, bornText)
	// pds-bl-task-create-draft-at-rc0 — A TRUE LINE THAT CARRIED NO REMEDY.
	// The line above always said "draft" and it was still trusted, which is the
	// whole finding: it states a fact and never says what the fact COSTS. A row
	// left as a draft is on nobody's board — `bp task ready` cannot return it
	// and no worker can claim it — and the receipt named neither that
	// consequence nor the one command that fixes it. The `lifecycle open`
	// half-sentence beside it actively pulls the other way, because "open" is
	// the BOARD's word for ready.
	//
	// A LABEL, NOT A REFUSAL, AND NOT A SILENT PUBLISH. `--yes` is the shared
	// prod-write global every write verb takes ("skip the prod confirmation");
	// teaching it to publish here would make its meaning verb-dependent
	// everywhere else. And create-then-patch-then-publish is a supported,
	// used workflow — it is the only way to file a row that needs registered
	// weighted tags to clear the publish wall — so a non-zero exit would red
	// every script that does the right thing. The row's own criterion allows
	// exactly this: refuse, OR label at a non-success shape.
	for _, line := range taskDraftRemedyLines(bareID, onBoard) {
		out.outf("%s", line)
	}
	return exitOK
}

// taskPublishCommand is the ONE command that puts a created draft on the board.
// It is `bp doc publish`, not `bp task publish`: `task` has no publish verb
// (ls, ready, prime, events, get, claim, close, release, stamp, next, move,
// stage, pulse), so a remedy naming a `bp task publish` would send the reader
// to a usage error. Derived here once so the CLI receipt, the JSON receipt and
// the MCP receipt cannot drift on what they tell people to run.
func taskPublishCommand(bareID string) string {
	return "bp doc publish task " + bareID + " --yes"
}

// taskDraftRemedyLines is what a receipt owes a person when the row it just
// reported is NOT on the board: what the state costs, and how to leave it.
// Empty when the row IS on the board — a remedy for a problem the caller does
// not have is noise.
func taskDraftRemedyLines(bareID string, onBoard bool) []string {
	if onBoard {
		return nil
	}
	return []string{
		"  NOT ON THE BOARD — a draft is invisible to `bp task ready` and cannot be claimed.",
		"  publish it:  " + taskPublishCommand(bareID),
		"  or create it published next time:  bp task create --publish …",
	}
}

// ensureTaskPortableBrief makes a TUI-readable PortableDoc brief an invariant
// of both ergonomic task-create paths. An explicit valid brief wins; otherwise
// the document is composed only from facts already present in the request.
func ensureTaskPortableBrief(body map[string]any) {
	if brief, ok := body["brief"].(map[string]any); ok {
		switch brief["version"] {
		case 1, float64(1):
			return
		}
	}
	title, _ := body["title"].(string)
	description, _ := body["description"].(string)
	description = strings.TrimSpace(strings.NewReplacer("**", "", "__", "", "`", "").Replace(description))
	if description == "" {
		description = "Complete the work described by “" + strings.TrimSpace(title) + "” and record verifiable evidence."
	}
	blocks := make([]any, 0, 4)
	if items := taskCriterionTexts(body["acceptance_criteria"]); len(items) > 0 {
		blocks = append(blocks,
			map[string]any{"id": "criteria", "type": "heading", "level": 2, "text": "Criteria"},
			map[string]any{"id": "criteria-list", "type": "list", "ordered": false, "items": items},
		)
	}
	blocks = append(blocks,
		map[string]any{"id": "purpose", "type": "heading", "level": 2, "text": "Purpose"},
		map[string]any{"id": "purpose-copy", "type": "paragraph", "content": []any{map[string]any{"type": "text", "value": description}}},
	)
	body["brief"] = map[string]any{"version": 1, "blocks": blocks}
}

func taskCriterionTexts(value any) []any {
	list, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]any, 0, len(list))
	for _, item := range list {
		if row, ok := item.(map[string]any); ok {
			if text, ok := row["criterion"].(string); ok && strings.TrimSpace(text) != "" {
				out = append(out, strings.TrimSpace(text))
			}
		}
	}
	return out
}

// sendTaskMutations POSTs a mutate batch to /v1/data/mutate/<dataset> and
// returns the raw HTTP status + response body, never rendering. It is the
// headless send primitive for the task-create path: runTaskCreate calls it to
// file the {create:{_type:task}} mutation (and then the follow-up publish), and
// the MCP task_create tool calls it to file a task headlessly and hand the raw
// response body back to the client verbatim. It rides the same scoped mutate
// endpoint + bearer auth apiclient.MutateResults uses, over the CLI's shared
// 30s doRequest transport (the same budget every manifest write gets), so the
// two never drift on the task write contract. Writes nothing to stdout.
// sendCreateTaskMutations is the injection seam for the CREATE mutation only
// (the publish follow-up below still calls sendTaskMutations directly — its
// ambiguity story already has a known bareID to point at, per this task's
// brief). Tests override this file-local variable to simulate a transport
// error or a 5xx without touching the shared sendTaskMutations helper, which
// the MCP task_create tool also calls.
//
// idempotencyKey, when non-empty, rides as the Idempotency-Key header the
// mutate door honours (tasks_create_idempotency.go). Empty means "no key" —
// the pre-existing behaviour for every caller that has no invocation-scoped key
// to spend.
var sendCreateTaskMutations keyedMutationSender = sendTaskMutations

func sendTaskMutations(ctx manifest.Context, mutations []map[string]any, idempotencyKey string) (int, []byte, error) {
	endpoint := apiclient.ScopedURL(ctx.Server, ctx.Workspace, ctx.Project, "/v1/data/mutate/"+ctx.Dataset)
	body, err := json.Marshal(map[string]any{"mutations": mutations})
	if err != nil {
		return 0, nil, err
	}
	headers := map[string]string{"Content-Type": "application/json"}
	if ctx.Token != "" {
		headers["Authorization"] = "Bearer " + ctx.Token
	}
	if idempotencyKey != "" {
		headers[idempotencyHeader] = idempotencyKey
	}
	return doRequest("POST", endpoint, headers, body)
}

// firstMutationID pulls the first result id out of a raw mutate response
// ({"results":[{"id":"drafts.task-N",…}]}). The create mutation carries no _id,
// so the server generates one and returns it here — that id is how the caller
// publishes/selects the new task. A body that fails to decode (or carries no
// result) returns "",false.
func firstMutationID(body []byte) (string, bool) {
	var out struct {
		Results []struct {
			ID string `json:"id"`
		} `json:"results"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", false
	}
	if len(out.Results) == 0 {
		return "", false
	}
	return out.Results[0].ID, out.Results[0].ID != ""
}

// mutateErrorMessage turns a non-2xx mutate response into a one-line human
// message, mirroring apiclient.humanAPIError so the raw-bytes task-create path
// keeps the same "validation_failed — kind: is required · …" feedback the
// apiclient path produced. Unknown shapes fall back to the clamped body verbatim
// so nothing is ever swallowed.
// THIS IS THE SITE THAT PROVED THE FORK. It declared
//
//	Details map[string][]string `json:"details"`
//
// a guess at validation_failed's ONE shape. encoding/json rejects the whole
// document on a single field mismatch, so the server's duplicate_task 409 —
// whose details is {"similar":[{id,…}],"advise":[]} — failed to unmarshal and
// took code, message AND hint down with it, dropping the caller to the clamped
// raw body below. The clamp then cut mid-`hint`, which is exactly where the id
// lives. The refusal told the caller to pass distinct_from: ["<id>"] while
// withholding the id, and was therefore unappealable.
//
// It now reads through internal/apierr like every other surface, and renders
// the two things the old decoder threw away: the server's hint, and the
// candidate ids the refusal's own remedy demands.
func mutateErrorMessage(status int, body []byte) string {
	if env, ok := apierr.Parse(body); ok {
		lines := dedupCandidateLines(env)

		// Summary() appends the GENERIC details rendering, which for a dedup
		// refusal is the whole candidate array as compact JSON. When we are
		// about to print those same candidates as readable id-leading lines,
		// the blob is noise that buries them — so take the bare message here
		// and let the lines below carry the payload. Every other refusal still
		// gets the full Summary(), because for those the details ARE the
		// detail and there is no second rendering.
		msg := env.Summary()
		if len(lines) > 0 {
			msg = env.Message
			if msg == "" {
				msg = env.Code
			}
		}
		if h := env.HintLine(); h != "" {
			msg += "\n  hint: " + h
		}
		if len(lines) > 0 {
			msg += "\n  " + strings.Join(lines, "\n  ")
		}
		// SERVER FAULT (5xx): print the request_id. The registered hint for
		// `internal_error` is "Retry shortly; if it persists, report the
		// request_id to the API operator" — a remedy that names an identifier
		// this renderer used to drop, which is the SAME unappealable shape the
		// dedup 409 above was fixed for, reproduced on the fault arm. It matters
		// most in the worst case: when the server declines to name the fault at
		// all (a bare `unknown error`, which MutateController still renders via
		// Errors.build/1's catch-all), the request_id is the ONLY handle the
		// caller has, and a create failure with no handle reports on its exit
		// code alone.
		//
		// Deliberately 5xx-only. A 4xx refusal already names WHICH field, WHICH
		// row, WHICH id (validation_failed, duplicate_task), so the caller can
		// act without an operator; adding the id there would be noise on every
		// well-named refusal.
		if status >= 500 && env.RequestID != "" {
			msg += "\n  request_id: " + env.RequestID
		}
		return msg
	}
	// Unknown shape. Do NOT truncate: the body is the only diagnosis left, and
	// the old 200-rune clamp cut it precisely when it mattered most.
	return fmt.Sprintf("error %d: %s", status, strings.TrimSpace(string(body)))
}

// dedupCandidateLines renders a dedup refusal's near-match rows one per line,
// id FIRST, then the exact flag spelling that appeals the refusal. A refusal
// that names an action must show that action's input.
func dedupCandidateLines(env apierr.Envelope) []string {
	similar, advise := env.Candidates()
	var lines []string
	for _, c := range similar {
		if s := c.Line("matches"); s != "" {
			lines = append(lines, s)
		}
	}
	for _, c := range advise {
		if s := c.Line("related"); s != "" {
			lines = append(lines, s)
		}
	}
	if len(lines) > 0 {
		lines = append(lines, `pass --set 'distinct_from:=["<id>"]' with the id above to confirm yours is genuinely different`)
	}
	return lines
}

// parseTaskCreateArgs folds the positional title + flags into the create body
// (kind/lifecycle_status defaulted, title/description convenience flags, and
// --set overrides in the doc-create key=value / key:=json convention) and
// returns whether --publish was requested.
func parseTaskCreateArgs(tail []string) (map[string]any, bool, error) {
	// Defaults the task schema requires; --set (or --title/--description) wins.
	body := map[string]any{
		"kind":             "task",
		"lifecycle_status": "open",
	}
	publish := false

	takeValue := func(i int, flag, inline string, hasInline bool) (string, int, error) {
		if hasInline {
			return inline, i, nil
		}
		if i+1 >= len(tail) {
			return "", i, fmt.Errorf("flag %s needs a value", flag)
		}
		return tail[i+1], i + 1, nil
	}

	for i := 0; i < len(tail); i++ {
		a := tail[i]
		key, inline, hasInline := a, "", false
		if eq := strings.IndexByte(a, '='); eq >= 0 && strings.HasPrefix(a, "--") {
			key, inline, hasInline = a[:eq], a[eq+1:], true
		}

		switch {
		case a == "--publish":
			publish = true
		case key == "--title":
			v, ni, err := takeValue(i, "--title", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			body["title"] = v
			i = ni
		case key == "--description":
			v, ni, err := takeValue(i, "--description", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			body["description"] = v
			i = ni
		case key == "--execution-policy":
			v, ni, err := takeValue(i, "--execution-policy", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			policy, err := parseTaskExecutionPolicyJSON([]byte(v))
			if err != nil {
				return nil, false, fmt.Errorf("--execution-policy: %w", err)
			}
			body["execution_policy"] = policy
			i = ni
		case key == "--set":
			v, ni, err := takeValue(i, "--set", inline, hasInline)
			if err != nil {
				return nil, false, err
			}
			if err := applyTaskSet(body, v); err != nil {
				return nil, false, err
			}
			i = ni
		case !strings.HasPrefix(a, "-"):
			// A bare positional is the title (first one wins; a second is an error
			// so a typo'd flag is not silently swallowed as the title).
			if _, ok := body["title"]; ok {
				if t, _ := body["title"].(string); t != "" {
					return nil, false, fmt.Errorf("unexpected extra argument %q (title already set)", a)
				}
			}
			body["title"] = a
		default:
			return nil, false, fmt.Errorf("unknown flag %q (task create accepts --title, --description, --execution-policy JSON, --set k=v, --publish)", a)
		}
	}
	return body, publish, nil
}

// parseTaskExecutionPolicyJSON is the CLI/MCP-side mirror of the server's
// strict v1 advisory allowlist. It rejects unsafe/unknown fields before a
// request is sent and returns a canonical object safe to embed in JSON.
func parseTaskExecutionPolicyJSON(raw []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var policy map[string]any
	if err := dec.Decode(&policy); err != nil {
		return nil, fmt.Errorf("must be a JSON object: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("must contain exactly one JSON object")
		}
		return nil, fmt.Errorf("invalid trailing JSON: %w", err)
	}
	if policy == nil {
		return nil, fmt.Errorf("must be a JSON object")
	}

	allowed := map[string]bool{
		"version": true, "agent_type": true, "model": true,
		"reasoning_effort": true, "resource_class": true,
	}
	for key := range policy {
		if !allowed[key] {
			return nil, fmt.Errorf("field %q is not allowed in execution_policy version 1", key)
		}
	}

	version, ok := policy["version"].(json.Number)
	if !ok || version.String() != "1" {
		return nil, fmt.Errorf("version is required and must be integer 1")
	}
	policy["version"] = json.Number("1")

	for _, field := range []struct {
		name string
		max  int
	}{{"agent_type", 64}, {"model", 128}} {
		if value, exists := policy[field.name]; exists {
			s, ok := value.(string)
			if !ok {
				return nil, fmt.Errorf("%s must be a string when set", field.name)
			}
			s = strings.TrimSpace(s)
			if s == "" || len(s) > field.max {
				return nil, fmt.Errorf("%s must be non-blank and at most %d bytes", field.name, field.max)
			}
			policy[field.name] = s
		}
	}

	if err := validateTaskPolicyEnum(policy, "reasoning_effort", []string{"minimal", "low", "medium", "high", "xhigh"}); err != nil {
		return nil, err
	}
	if err := validateTaskPolicyEnum(policy, "resource_class", []string{"light", "standard", "heavy"}); err != nil {
		return nil, err
	}

	return policy, nil
}

func validateTaskPolicyEnum(policy map[string]any, field string, allowed []string) error {
	value, exists := policy[field]
	if !exists {
		return nil
	}
	s, ok := value.(string)
	if !ok {
		return fmt.Errorf("%s must be a string when set", field)
	}
	for _, candidate := range allowed {
		if s == candidate {
			return nil
		}
	}
	return fmt.Errorf("%s must be one of %s", field, strings.Join(allowed, ", "))
}

// applyTaskSet merges one --set token into body, using the doc-create typing
// convention: `key:=json` sends a TYPED value (e.g. --set priority:=3 → number,
// --set 'labels:=["x"]' → array), plain `key=value` stays a string. Task
// validators reject a string where they want a number, so the typed form is the
// caller's explicit escape hatch — type is never sniffed from the value.
func applyTaskSet(body map[string]any, kv string) error {
	if eq := strings.Index(kv, ":="); eq >= 0 && !strings.Contains(kv[:eq], "=") {
		var typed any
		if err := json.Unmarshal([]byte(kv[eq+2:]), &typed); err != nil {
			return fmt.Errorf("invalid --set %q: %q is not valid JSON (key:=value sends raw JSON; use key=value for strings)", kv, kv[eq+2:])
		}
		body[kv[:eq]] = typed
		return nil
	}
	eq := strings.IndexByte(kv, '=')
	if eq < 0 {
		return fmt.Errorf("invalid --set %q (want key=value, or key:=json for typed values)", kv)
	}
	body[kv[:eq]] = kv[eq+1:]
	return nil
}

// taskCreateDryRun prints the resolved mutate request without sending, matching
// the manifest write path's --dry-run degradation notice.
func taskCreateDryRun(out *writer, ctx manifest.Context, mutations []map[string]any, publish bool) int {
	out.errf("dry-run: client-side preview only (server validate-only not available)")
	out.errf("POST %s/v1/data/mutate/%s", ctx.Server, ctx.Dataset)
	out.errf("Authorization: Bearer ****")
	out.errf("Content-Type: application/json")
	out.errf("")
	raw, _ := json.Marshal(map[string]any{"mutations": mutations})
	out.outf("%s", string(raw))
	if publish {
		out.errf("(then publish the created draft to collapse it to published)")
	}
	return exitOK
}

// isProdServer mirrors run.go's isProd URL heuristic for the builtin write path
// (which has no manifest to read m.Server.Name from). FAIL CLOSED, matching
// isProd's flip (onb-backlog-isprod-custom-host-write-confirm): any host that
// is not provably local IS prod. Both twins now collapse onto the ONE pinned
// exact-host classifier (isLocalHost, run.go) — the former hand-copied
// substring body left this builtin write path fail-open on hosts like
// localhost.evil.com even after run.go was fixed. --yes and a
// server-advertised production:false (/v1/meta) are the only ways past the
// guard.
func isProdServer(server string) bool {
	return !isLocalHost(server)
}

func printTaskCreateHelp(out *writer) {
	out.outf(`usage: bp task create [<title>] [flags]
  File a new task. Injects the task schema's required kind="task" and
  lifecycle_status="open" defaults, so you only supply the title (and any
  optional fields). By default the task is created as a DRAFT — not on the
  board, and not in "bp task ready" as a published pair — and bp task create
  says so on stderr with the one command that fixes it. --publish collapses it
  to published in the same call.

  ASYMMETRY, ON PURPOSE: the MCP task_create tool defaults publish TRUE while
  this CLI verb defaults it FALSE (draft-first). An agent filing through MCP
  gets a board-visible row; a script filing through bp task create gets a
  draft unless it passes --publish. Rows filed here and never published are the
  documented source of unclaimable drafts.task-N residue on the queue.

arguments:
  title            The task title (or pass --title / --set title=…).

flags:
  --title <t>      Task title.
	  --description <d> Task description.
	  --execution-policy <json>
	                   Strict advisory v1 policy object (agent_type, model,
	                   reasoning_effort, resource_class).
	  --set <k=v>      Extra field (repeatable; k:=json for typed values, e.g.
                   --set priority:=3, --set 'labels:=["infra"]',
                   --set parent_id=my-goal). Overrides the injected defaults.
                   Acceptance criteria are typed JSON too, and the ONE flag
                   does both — it writes the array AND generates the brief's
                   Criteria section from it, e.g.
                     --set 'acceptance_criteria:=[{"criterion":"gates green","met":false,"evidence":""}]'
  --publish        Publish the new task immediately (draft → published).
                   A PUBLISHED row must clear the publish wall, so --publish
                   also requires --description (20+ chars) and 1-12 weighted
                   tags, e.g.
                     --set 'tags:=[{"tag":"cli","strength":80,"rationale":"20+ chars saying why"}]'
                   Strengths are integers 1-100 and must all be DISTINCT, and
                   every tag must ALREADY be a registered (published) type:tag
                   document — you cannot invent one here. List the vocabulary
                   with: bp doc ls tag --all . A row that cannot clear the wall
                   is refused BEFORE anything is created, and if the registry
                   itself cannot be read the publish is refused too
                   (tag_registry_unreadable) rather than written blind. A
                   refusal the server can only raise AFTER the create (e.g.
                   duplicate_of) discards the just-created draft in the same
                   run — so a failed --publish never leaves a draft behind
                   except in the named residue cases it prints
                   (residue[<class>]: … ), which are the ones where the publish
                   may actually have landed.

write globals: --dry-run (print the request, don't send) · --yes (skip the
prod confirmation) · -o json (structured receipt)

reading it back: a new task (and any --set/patch) writes the DRAFT. Read it
with the drafts. prefix — bp doc get task drafts.<id> --perspective raw. A bare
bp doc get task <id> reads the PUBLISHED perspective and 404s (or shows the
pre-write row) for an unpublished draft: that draft-vs-published asymmetry is
why a successful write can look like it "read back unchanged" until you publish.`)
}

// mutateWarning is ONE advisory off a mutate success envelope. The wire carries
// two shapes and both are real: the authoring wall's {code,severity,message}
// objects (Barkpark.Content.Warnings) and bare strings from older emitters —
// emitWarnings already renders both, so the decode here tolerates both too
// rather than inventing a narrower contract on the same field.
type mutateWarning struct {
	Code     string `json:"code,omitempty"`
	Severity string `json:"severity,omitempty"`
	Message  string `json:"message"`
}

// mutateWarnings decodes the top-level {"warnings":[…]} of a mutate response.
// A body that does not decode, carries no warnings, or carries message-less
// entries yields nothing: an advisory with no message is not renderable and
// inventing text for it would be worse than silence. Never an error — a
// warning is advisory by construction and must never change what the caller
// concludes about the WRITE.
func mutateWarnings(body []byte) []mutateWarning {
	var env struct {
		Warnings []any `json:"warnings"`
	}
	if json.Unmarshal(body, &env) != nil {
		return nil
	}
	var out []mutateWarning
	for _, w := range env.Warnings {
		switch v := w.(type) {
		case string:
			if v != "" {
				out = append(out, mutateWarning{Message: v})
			}
		case map[string]any:
			msg, _ := v["message"].(string)
			if msg == "" {
				continue
			}
			code, _ := v["code"].(string)
			sev, _ := v["severity"].(string)
			out = append(out, mutateWarning{Code: code, Severity: sev, Message: msg})
		}
	}
	return out
}

// dedupeMutateWarnings keeps the first occurrence of each (code, message). A
// `--publish` create runs the same before_save gate twice — once for the draft,
// once for the published twin — so the same advisory arrives twice and printing
// it twice reads as two separate problems.
func dedupeMutateWarnings(in []mutateWarning) []mutateWarning {
	if len(in) < 2 {
		return in
	}
	seen := make(map[[2]string]bool, len(in))
	out := make([]mutateWarning, 0, len(in))
	for _, w := range in {
		k := [2]string{w.Code, w.Message}
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, w)
	}
	return out
}
