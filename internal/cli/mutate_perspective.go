package cli

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE TRAP THIS CLOSES (spd-doc-mutate-rev-reads-as-success). `bp doc mutate`
// and `bp doc patch` write the DRAFT lens; `bp task get`, `/v1/data/doc`, the
// board and the queue all read the PUBLISHED lens. Every mutate 2xx mints a
// fresh transaction rev, so the receipt — which was exactly one line, `rev:
// <hash>` — reads identically for a write that changed the shared ledger and
// for one that parked on a draft twin nobody serves. A changed rev is the
// universal "it worked" signal; two consecutive raw unsets returned two fresh
// revs while the target keys stayed present on a re-read, and the dispatch
// brief that reported them called the mechanism "verified".
//
// THE FACTS ARE ALREADY IN THE ENVELOPE — this costs ZERO extra requests. Every
// mutation result carries the rendered document envelope, whose reserved keys
// (Barkpark.Content.Envelope, api/lib/barkpark/content/envelope.ex) include:
//
//	_draft       — true when the written doc_id is a `drafts.` twin
//	_publishedId — the bare id a publish would land on
//	_type        — the type both `bp doc publish` args need
//
// So the perspective line is DERIVED, never re-read. A read-after-write would
// have been a second round trip AND a second lie surface (it can race a
// concurrent publish); the envelope cannot.
//
// The FORK half — a patch that names a BARE published id and therefore mints or
// merges onto a draft twin — is a SEPARATE server-side fact, added by #15851
// (api/lib/barkpark/content/mutations.ex, warn_on_published_fork/2) as two
// advisory codes on the mutate success envelope:
//
//	patch.forked_published — no draft existed; this patch MINTED the twin
//	patch.stale_draft_base — a draft ALREADY existed; the merge base was IT,
//	                         not the published row the caller just read
//
// emitWarnings (run.go) already prints those messages verbatim — but only in
// `minimal` and `table`, and only when the server chose to warn. This emitter is
// the complement: it fires in EVERY output shape, on EVERY mutate/patch 2xx, and
// says which lens moved even when there is no warning at all (the reported
// reproduction: a `--file` batch addressing `drafts.<id>` directly warns about
// nothing, because nothing forked — and still must not read as a ledger edit).
// When a fork code IS present it adds one line naming the fork and the remedy,
// so the two facts sit together rather than the fork riding a bare `rev:`.
//
// STDERR IN EVERY SHAPE, like emitTaskRuling and emitPublishCiteAdvisory: `-o
// json` stays ONE byte-identical document (the same facts are in it, under
// results[].document._draft and warnings[]), the exit code never moves, and a
// pipeline reading stdout sees nothing new.

// mutatePerspectiveVerbs is the pair of manifest verbs whose receipt this
// emitter annotates. Verb-keyed on purpose, unlike emitWarnings: the line makes
// a claim about the DRAFT/PUBLISHED split, which is only true of the doc
// mutation path. `doc publish` is deliberately absent — publishing is the act
// that MAKES the published row change, and its receipt is not the trap.
var mutatePerspectiveVerbs = map[string]bool{
	"doc mutate": true,
	"doc patch":  true,
}

func isMutatePerspectiveCmd(cmd manifest.Command) bool {
	return mutatePerspectiveVerbs[cmd.Noun+" "+cmd.Verb]
}

// mutateResult is the slice of one entry of the mutate envelope's `results`
// array this emitter reads. Everything else in the entry (the full echoed
// document body) is ignored.
type mutateResult struct {
	ID        string `json:"id"`
	Operation string `json:"operation"`
	Document  struct {
		Draft       *bool  `json:"_draft"`
		PublishedID string `json:"_publishedId"`
		Type        string `json:"_type"`
	} `json:"document"`
}

// mutateResults decodes results[] from a mutate 2xx body, tolerating BOTH
// shapes the CLI sees: the bare controller body `{transactionId, results, …}`
// and the `{"result": {…}}` envelope other endpoints wrap in. Returns nil for
// any body that is not one of those — this emitter is silent on anything it
// does not positively understand.
func mutateResults(respBody []byte) []mutateResult {
	var env struct {
		Results []mutateResult `json:"results"`
	}
	if json.Unmarshal(respBody, &env) == nil && len(env.Results) > 0 {
		return env.Results
	}
	if json.Unmarshal(unwrapResult(respBody), &env) == nil {
		return env.Results
	}
	return nil
}

// mutateForkCodes returns the fork advisory codes present on the envelope, in
// emission order, deduped. #15851's two codes only; an unrelated advisory
// (patch.content_nested, the tag walls) is not a fork and is left to
// emitWarnings.
func mutateForkCodes(respBody []byte) []string {
	body := respBody
	var env struct {
		Warnings []struct {
			Code string `json:"code"`
		} `json:"warnings"`
	}
	if json.Unmarshal(body, &env) != nil || len(env.Warnings) == 0 {
		if json.Unmarshal(unwrapResult(respBody), &env) != nil {
			return nil
		}
	}
	var out []string
	seen := map[string]bool{}
	for _, w := range env.Warnings {
		switch w.Code {
		case "patch.forked_published", "patch.stale_draft_base":
			if !seen[w.Code] {
				seen[w.Code] = true
				out = append(out, w.Code)
			}
		}
	}
	return out
}

// publishRemedy is the exact command that makes a draft write visible, or ""
// when the envelope did not carry enough to name it (a redacted or unusual
// echo). A remedy is never guessed: half a command line is worse than none.
func publishRemedy(r mutateResult) string {
	id := r.Document.PublishedID
	if id == "" {
		id = strings.TrimPrefix(r.ID, "drafts.")
	}
	if r.Document.Type == "" || id == "" {
		return ""
	}
	return fmt.Sprintf("bp doc publish %s %s", r.Document.Type, id)
}

// mutatePerspectiveLines builds the advisory lines for one mutate 2xx body.
// Pure and separately testable: the emitter below is only the stderr plumbing.
func mutatePerspectiveLines(respBody []byte) []string {
	results := mutateResults(respBody)
	if len(results) == 0 {
		return nil
	}

	var lines []string
	seen := map[string]bool{}
	add := func(s string) {
		if s != "" && !seen[s] {
			seen[s] = true
			lines = append(lines, s)
		}
	}

	anyDraft := false
	for _, r := range results {
		// The discriminator is the server's own `_draft`, not a prefix guess on
		// the id. A missing `_draft` is UNKNOWN, not false: stay silent for that
		// result rather than assert "published document changed" about a body
		// that never said so.
		if r.Document.Draft == nil {
			continue
		}
		if *r.Document.Draft {
			anyDraft = true
			id := r.ID
			if remedy := publishRemedy(r); remedy != "" {
				add(fmt.Sprintf(
					"DRAFT updated (%s): the published row is UNCHANGED until you run `%s`",
					id, remedy))
			} else {
				add(fmt.Sprintf(
					"DRAFT updated (%s): the published row is UNCHANGED until this draft is published",
					id))
			}
			continue
		}
		add(fmt.Sprintf("published document changed: %s", r.ID))
	}

	// The fork line rides the draft verdict, never replaces it: the operator
	// needs BOTH "this went to a draft" and "…because the id you named was the
	// published one". Only emitted when at least one result really is a draft —
	// a warning without a draft result would be the server contradicting itself,
	// and this emitter reports the envelope, it does not adjudicate it.
	if anyDraft {
		for _, code := range mutateForkCodes(respBody) {
			switch code {
			case "patch.forked_published":
				add("FORKED the published row: you named a published id, so this patch minted a NEW draft twin — the edit is invisible to every canonical reader until it is published")
			case "patch.stale_draft_base":
				add("FORKED onto an EXISTING draft: the merge base was that draft, not the published row you read — it may carry stale fields (lifecycle_status among them) that this write now inherits and a publish would carry forward")
			}
		}
	}

	return lines
}

// emitMutatePerspective prints the draft-versus-published verdict for a `doc
// mutate` / `doc patch` 2xx. Advisory only: stderr in every output shape, exit
// code untouched, stdout untouched. Silent for every other verb and for any
// body whose results do not declare `_draft`.
func emitMutatePerspective(out *writer, cmd manifest.Command, respBody []byte) {
	if !isMutatePerspectiveCmd(cmd) {
		return
	}
	for _, line := range mutatePerspectiveLines(respBody) {
		out.errf("%s", line)
	}
}
