package cli

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// tasks_history_cmd.go — `bp task history <doc-id>`: the CLI half of the
// flight recorder's P3 row (task-b3045c0a79510f28, epic task-b55fafd148bb2578
// criterion 4).
//
// ====================== WHAT THIS COMMAND IS ALLOWED TO CLAIM ================
//
// The row's title pairs two halves: server-stamped agent identity on every task
// mutation, and a `bp task history` that shows the per-agent timeline. Only the
// SECOND half is CLI work, and the first half DOES NOT EXIST YET. Measured
// against the live production ledger on 2026-09-17:
//
//	bp doc history task <a real row>   -> every revision carries
//	                                      actor_kind/actor_id/actor_label/
//	                                      actor_user_id = null
//	bp task events <a claimed+closed row> -> every event object is exactly
//	                                      {at, doc_id, event, id, rev};
//	                                      no worker, no epoch, no actor
//
// So a history view written today can render a TRAIL, and it cannot render an
// AGENT. The one thing it must not do is make the gap look like data. That is
// the whole design constraint: this command reports what the store holds and
// says UNMEASURED for what the store cannot answer.
//
// ============================ THE THREE-STATE LAW ============================
//
// The epic's law — nil is UNMEASURED, false only from a source that answered —
// binds this reader twice.
//
// Per revision:
//
//	NOT STAMPED     Every actor column came back null. The store was never told
//	                who made this mutation. UNMEASURED. This is NOT "nobody".
//	ANSWERED-EMPTY  A column is present and empty. The store answered, and its
//	                answer was nothing. MEASURED, and printed DIFFERENTLY from
//	                NOT STAMPED — collapsing the two tells a reader the ledger
//	                asserted "no agent" when it was never asked.
//	STAMPED         A column carries a value. MEASURED identity; show it.
//
// Per command:
//
//	A FAILED READ IS NEVER AN EMPTY TIMELINE. A transport or non-200 failure
//	exits non-zero and says a measured failure occurred. A successful read of
//	zero revisions exits 0 and says the store ANSWERED with none. Printing
//	"0 revisions" over a 500 is the flight recorder's worst failure mode: an
//	absence manufactured by the instrument, indistinguishable from a real one.
//
// ===================== WHY content.claim.worker IS NOT SHOWN =================
//
// The row DOES carry a worker string, at content.claim.worker. It is not
// attribution and this command refuses to print it as such: it is written by
// the client whose mutations are being audited, from a value that client chose,
// and it can be any string a caller types. Rendering it in an "agent" column
// would manufacture precisely the server-stamped identity the epic says does
// not exist yet — the most tempting wrong answer available to this file.

// attributionState is which of the three answers the store gave about WHO made
// one mutation.
type attributionState int

const (
	// attrNotStamped — every actor column is null. UNMEASURED.
	attrNotStamped attributionState = iota
	// attrAnsweredEmpty — a column is present and empty. MEASURED nothing.
	attrAnsweredEmpty
	// attrStamped — a column carries a value. MEASURED identity.
	attrStamped
)

func (s attributionState) String() string {
	switch s {
	case attrAnsweredEmpty:
		return "ANSWERED-EMPTY"
	case attrStamped:
		return "STAMPED"
	default:
		return "NOT STAMPED"
	}
}

// attribution is one revision's WHO, as the store answered it.
type attribution struct {
	State attributionState
	// Fields are the columns that came back non-null, in a stable order,
	// rendered name=value. An empty value is shown as name="" so an
	// ANSWERED-EMPTY reads as an answer rather than as a missing line.
	Fields []string
}

// classifyAttribution is the split this whole command exists for. Deleting it
// — or collapsing its two absences into one — must red a test; see
// TestAttributionSplitsTheTwoAbsences and
// TestHistoryAttributionRedsWhenTheSplitIsCollapsed.
func classifyAttribution(rev apiclient.Revision) attribution {
	cols := []struct {
		name string
		val  *string
	}{
		{"actor_kind", rev.ActorKind},
		{"actor_id", rev.ActorID},
		{"actor_label", rev.ActorLabel},
		{"actor_user_id", rev.ActorUserID},
	}

	var a attribution
	anyPresent := false
	anyValued := false
	for _, c := range cols {
		if c.val == nil {
			// The column was never written. Contributes NOTHING — in
			// particular it does not contribute an "empty" answer.
			continue
		}
		anyPresent = true
		if *c.val != "" {
			anyValued = true
		}
		a.Fields = append(a.Fields, fmt.Sprintf("%s=%q", c.name, *c.val))
	}

	switch {
	case anyValued:
		a.State = attrStamped
	case anyPresent:
		a.State = attrAnsweredEmpty
	default:
		a.State = attrNotStamped
	}
	return a
}

// revisionSource is the store, injected. The failure this reader exists to
// report — a server that answers null — cannot be asked of the real network
// inside a unit test, and neither can a read that fails. Without injection the
// three-state split has no arm that reds when it is deleted.
type revisionSource interface {
	Revisions(typeName, docID string, limit int) ([]apiclient.Revision, error)
}

type clientRevisionSource struct{ c *apiclient.Client }

func (s clientRevisionSource) Revisions(typeName, docID string, limit int) ([]apiclient.Revision, error) {
	return s.c.History(typeName, docID, limit)
}

// historyReport is the measured result of one read: either the store answered
// (Read true, Revisions possibly empty) or it did not (Read false, Fault set).
// There is no third shape, and an unread store never produces a revision list.
type historyReport struct {
	Read      bool
	Fault     string
	Revisions []apiclient.Revision
}

const defaultHistoryLimit = 50

// runTaskHistory is the builtin entry point: `bp task history <doc-id> [--limit N]`.
func runTaskHistory(out *writer, g globals, ctx manifest.Context, tail []string) int {
	if g.help {
		printTaskHistoryHelp(out)
		return exitOK
	}

	docID, limit, err := parseHistoryArgs(tail)
	if err != nil {
		return usageErrf(out, func() { printTaskHistoryHelp(out) }, "%v", err)
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
		// "drafts" for the same reason `bp task resume` picks it: a task row's
		// live state lives in the draft overlay.
		Perspective: "drafts",
	})

	rep := fetchHistory(clientRevisionSource{client}, docID, limit)
	return renderTaskHistory(out, docID, rep)
}

// fetchHistory asks the store once. A failure NEVER yields a revision list —
// the zero-value Revisions stays nil and Read stays false, so no renderer
// downstream can mistake an unread store for an empty one.
func fetchHistory(src revisionSource, docID string, limit int) historyReport {
	revs, err := src.Revisions("task", docID, limit)
	if err != nil {
		return historyReport{Fault: err.Error()}
	}
	return historyReport{Read: true, Revisions: revs}
}

// renderTaskHistory prints the timeline and returns the exit code. Pure over
// historyReport, so both the read-failed and the read-succeeded arms are
// drivable by a test with no network.
func renderTaskHistory(out *writer, docID string, rep historyReport) int {
	if !rep.Read {
		// MEASURED FAILURE, and it exits non-zero. The store was asked and did
		// not answer; printing an empty timeline here would manufacture an
		// absence out of an instrument fault.
		out.errf("TASK HISTORY %s — MEASURED FAILURE: the store was asked and did not answer.", docID)
		out.errf("  fault: %s", rep.Fault)
		out.errf("  NOTHING is claimed about this row's mutation history. This is not an empty history;")
		out.errf("  it is a read that failed, and the two must never render the same.")
		return exitGeneric
	}

	// Newest-first is what the server returns; sort defensively so the
	// rendering does not inherit an ordering accident from the transport.
	revs := append([]apiclient.Revision(nil), rep.Revisions...)
	sort.SliceStable(revs, func(i, j int) bool { return revs[i].Timestamp.After(revs[j].Timestamp) })

	if out.machineOut() {
		return emitHistoryJSON(out, docID, revs)
	}

	out.outf("TASK HISTORY — %s", docID)
	if len(revs) == 0 {
		out.outf("")
		out.outf("The store ANSWERED and recorded no revisions for this row.")
		out.outf("  MEASURED empty — distinct from a read that failed, which exits non-zero.")
		return exitOK
	}
	out.outf("%d revision(s), newest first. Each line: when · what · rev · WHO, as the store answered it.", len(revs))
	out.outf("")

	notStamped := 0
	for _, r := range revs {
		a := classifyAttribution(r)
		if a.State == attrNotStamped {
			notStamped++
		}
		out.outf("  %s  %-10s  rev=%s", r.Timestamp.UTC().Format("2006-01-02T15:04:05Z"), r.Action, shortRev(r.Rev))
		out.outf("      who: %s%s", a.State, renderAttributionFields(a))
	}

	out.outf("")
	renderIdentityVerdict(out, len(revs), notStamped)
	return exitOK
}

// renderAttributionFields appends the columns the store actually returned, or
// the reason there are none. The NOT STAMPED wording says UNMEASURED out loud:
// the reader must not be able to read a blank column as "no agent".
func renderAttributionFields(a attribution) string {
	if len(a.Fields) == 0 {
		return " — UNMEASURED: the store recorded no actor column for this mutation"
	}
	return " — " + strings.Join(a.Fields, " ")
}

// renderIdentityVerdict states the server half's status FROM WHAT WAS JUST
// MEASURED on these rows, never from a hardcoded sentence. If a future server
// starts stamping identity, this footer changes on its own.
// identityVerdict is the one-word measured call, shared by the human footer and
// the machine envelope so the two surfaces cannot disagree about what was read.
func identityVerdict(total, notStamped int) string {
	switch {
	case total == 0:
		return "NO REVISIONS"
	case notStamped == total:
		return "UNMEASURED"
	case notStamped > 0:
		return "PARTIAL"
	default:
		return "ANSWERED"
	}
}

func renderIdentityVerdict(out *writer, total, notStamped int) {
	switch {
	case notStamped == total:
		out.outf("AGENT IDENTITY: UNMEASURED on %d of %d revision(s) read.", notStamped, total)
		out.outf("  The store stamps no server-side agent identity on task mutations, so this timeline")
		out.outf("  shows WHAT changed and WHEN, and cannot show WHO. That is the epic's server half")
		out.outf("  (api/), not a gap in this command.")
	case notStamped > 0:
		out.outf("AGENT IDENTITY: PARTIAL — %d of %d revision(s) carry no actor column at all (UNMEASURED);", notStamped, total)
		out.outf("  the rest were answered by the store and are shown above.")
	default:
		out.outf("AGENT IDENTITY: every one of the %d revision(s) read was answered by the store.", total)
	}
	out.outf("")
	out.outf("NOT SHOWN, on purpose: content.claim.worker. That string is written by the client whose")
	out.outf("  mutations are being audited, so it is a self-report, never attribution. Printing it in")
	out.outf("  an agent column would manufacture the identity this command just measured as absent.")
	out.outf("")
	// NAME THE SOURCE, because this timeline is NOT the whole mutation set. The
	// revision store records document revisions (create/publish/...), while
	// mutation_events additionally carries task.claimed / task.pulse /
	// task.criterion / task.lease_renewed. On a real claimed-and-closed row
	// measured 2026-09-17 that was 2 revisions against 30 events. A reader told
	// "here is the timeline" without being told which store answered would read
	// the 28 missing events as mutations that never happened.
	out.outf("SOURCE: the revision store (GET /v1/data/history). The mutation_events stream")
	out.outf("  (`bp task events <id>`) carries ADDITIONAL event kinds this view does not read —")
	out.outf("  task.claimed, task.pulse, task.criterion, task.lease_renewed. A short list here is")
	out.outf("  therefore not evidence that nothing else happened to this row.")
}

// shortRev renders the three-state `rev` column: nil is history written before
// the column existed, and says so rather than printing an empty field.
func shortRev(rev *string) string {
	if rev == nil {
		return "(unmeasured)"
	}
	if *rev == "" {
		return `""`
	}
	if len(*rev) > 12 {
		return (*rev)[:12]
	}
	return *rev
}

func emitHistoryJSON(out *writer, docID string, revs []apiclient.Revision) int {
	entries := make([]map[string]any, 0, len(revs))
	notStamped := 0
	for _, r := range revs {
		a := classifyAttribution(r)
		if a.State == attrNotStamped {
			notStamped++
		}
		entries = append(entries, map[string]any{
			"id":                 r.ID,
			"action":             r.Action,
			"status":             r.Status,
			"timestamp":          r.Timestamp.UTC(),
			"rev":                r.Rev,
			"attribution_state":  a.State.String(),
			"attribution_fields": a.Fields,
		})
	}
	out.renderJSON(map[string]any{
		"doc_id":                   docID,
		"read":                     true,
		"count":                    len(revs),
		"revisions":                entries,
		"agent_identity_absent_on": notStamped,
		"agent_identity_verdict":   identityVerdict(len(revs), notStamped),
		"claim_worker_shown":       false,
	})
	return exitOK
}

func parseHistoryArgs(tail []string) (string, int, error) {
	docID := ""
	limit := defaultHistoryLimit
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		switch {
		case a == "--limit" || strings.HasPrefix(a, "--limit="):
			var val string
			if strings.HasPrefix(a, "--limit=") {
				val = strings.TrimPrefix(a, "--limit=")
			} else {
				if i+1 >= len(tail) {
					return "", 0, fmt.Errorf("flag --limit needs a value")
				}
				val = tail[i+1]
				i++
			}
			n, err := strconv.Atoi(val)
			if err != nil || n < 1 {
				return "", 0, fmt.Errorf("invalid --limit %q (want a positive integer)", val)
			}
			limit = n
		case strings.HasPrefix(a, "-"):
			return "", 0, fmt.Errorf("unknown flag %q (history accepts --limit N)", a)
		default:
			if docID != "" {
				return "", 0, fmt.Errorf("takes ONE doc-id (got %q and %q)", docID, a)
			}
			docID = strings.TrimSpace(a)
		}
	}
	if docID == "" {
		return "", 0, fmt.Errorf("needs a doc-id")
	}
	return docID, limit, nil
}

func printTaskHistoryHelp(out *writer) {
	out.outf("usage: barkpark task history <doc-id> [--limit N]")
	out.outf("")
	out.outf("  The per-mutation timeline for one task row, read from the revision store.")
	out.outf("  Each entry reports WHO as the store answered it: STAMPED, ANSWERED-EMPTY, or")
	out.outf("  NOT STAMPED (UNMEASURED — the store recorded no actor, which is NOT 'nobody').")
	out.outf("")
	out.outf("  A read that FAILS exits non-zero and says so; it is never rendered as an empty")
	out.outf("  timeline. content.claim.worker is deliberately NOT shown — it is a client")
	out.outf("  self-report, not server attribution.")
}
