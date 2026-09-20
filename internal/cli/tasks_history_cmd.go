package cli

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

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

	// Events is the SECOND store: mutation_events, which is where the task
	// verbs (claim / pulse / close / release / stamp) record themselves. They
	// write no revision at all, so a verdict computed from Revisions alone is
	// structurally blind to every task mutation — the defect of
	// task-3b0be19ef722afef.
	//
	// NIL means no events read was part of this report, which is itself an
	// UNMEASURED and the ONLY shape in which the exit code may ignore this
	// store. A non-nil outcome whose Read is false is a MEASURED FAILURE and
	// exits non-zero, exactly like a failed revision read: now that the feed
	// is load-bearing for the verdict, swallowing its fault would render an
	// instrument fault as "no caller found".
	Events *eventsOutcome
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

	rep := fetchHistoryAndEvents(
		clientRevisionSource{client},
		httpTaskEventSource{server: ctx.Server, token: ctx.Token, dataset: ctx.Dataset},
		docID, limit,
	)
	return renderTaskHistory(out, docID, rep)
}

// fetchHistoryAndEvents reads BOTH stores. It always attaches a non-nil
// Events outcome — a history that quietly skipped the events feed would be
// the original defect wearing the fix's name, and
// TestFetchHistoryAndEventsAlwaysAttemptsTheEventsFeed reds if it stops.
func fetchHistoryAndEvents(revs revisionSource, evs taskEventSource, docID string, limit int) historyReport {
	rep := fetchHistory(revs, docID, limit)
	rep.Events = fetchTaskEvents(evs, docID, limit)
	return rep
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

// timelineEntry is one mutation, from whichever store answered for it. The two
// stores are DISJOINT in practice — the revision store holds create/publish/
// update, mutation_events additionally holds task.claimed / task.closed /
// task.pulse / task.criterion — so the merged list is the first view of this
// row that is actually the whole mutation set.
type timelineEntry struct {
	When   time.Time
	What   string
	Rev    string
	Source string
	Attr   attribution
}

// buildTimeline merges the two stores, newest first.
//
// A revision and an event that share a `rev` are the SAME mutation seen twice,
// and the events side is the only one that ever carries a caller today. So an
// event UPGRADES a revision that the revision store left NOT STAMPED — and it
// can only ever upgrade: an event whose own caller is UNMEASURED never
// downgrades a revision the revision store answered, and never turns an
// UNMEASURED into an ANSWERED-EMPTY.
//
// An event with no matching revision is a mutation the old reader could not
// see AT ALL. It is appended, not dropped: dropping it is what made
// `bp task history` report UNMEASURED about a claim the server had stamped.
func buildTimeline(revs []apiclient.Revision, ev *eventsOutcome) []timelineEntry {
	entries := make([]timelineEntry, 0, len(revs))
	byRev := map[string]int{}
	for _, r := range revs {
		e := timelineEntry{
			When:   r.Timestamp,
			What:   r.Action,
			Rev:    shortRev(r.Rev),
			Source: "revision",
			Attr:   classifyAttribution(r),
		}
		entries = append(entries, e)
		if r.Rev != nil && *r.Rev != "" {
			byRev[*r.Rev] = len(entries) - 1
		}
	}

	if ev != nil && ev.Read {
		for _, e := range ev.Events {
			a := classifyEventAttribution(e)
			revKey := ""
			if e.Rev != nil {
				revKey = *e.Rev
			}
			if i, ok := byRev[revKey]; ok && revKey != "" {
				if entries[i].Attr.State == attrNotStamped && a.State != attrNotStamped {
					entries[i].Attr = a
					entries[i].Source = "revision+events"
				}
				continue
			}
			entries = append(entries, timelineEntry{
				When:   e.At,
				What:   e.Event,
				Rev:    shortRev(e.Rev),
				Source: "events",
				Attr:   a,
			})
		}
	}

	sort.SliceStable(entries, func(i, j int) bool { return entries[i].When.After(entries[j].When) })
	return entries
}

// renderTaskHistory prints the timeline and returns the exit code. Pure over
// historyReport, so every arm — either store failing, either store answering —
// is drivable by a test with no network.
func renderTaskHistory(out *writer, docID string, rep historyReport) int {
	if !rep.Read {
		// MEASURED FAILURE, and it exits non-zero. The store was asked and did
		// not answer; printing an empty timeline here would manufacture an
		// absence out of an instrument fault.
		out.errf("TASK HISTORY %s — MEASURED FAILURE: the revision store was asked and did not answer.", docID)
		out.errf("  fault: %s", rep.Fault)
		out.errf("  NOTHING is claimed about this row's mutation history. This is not an empty history;")
		out.errf("  it is a read that failed, and the two must never render the same.")
		return exitGeneric
	}

	// THE EVENTS FEED IS LOAD-BEARING. It is where the task verbs record who
	// mutated the row, so a verdict computed without it is the defect this
	// command was just fixed for. A failed events read therefore fails the
	// COMMAND — it does not degrade to "no caller found", which would be
	// byte-identical to a row nobody ever stamped.
	if rep.Events != nil && !rep.Events.Read {
		out.errf("TASK HISTORY %s — MEASURED FAILURE: the mutation_events feed was asked and did not answer.", docID)
		out.errf("  fault: %s", rep.Events.Fault)
		out.errf("  The revision store DID answer, but that store records no task.claimed/task.closed and")
		out.errf("  carries no caller, so no verdict about WHO is available without this feed. Rendering one")
		out.errf("  anyway would report an instrument fault as an absence of attribution.")
		return exitGeneric
	}

	entries := buildTimeline(rep.Revisions, rep.Events)

	if out.machineOut() {
		return emitHistoryJSON(out, docID, entries, rep.Events)
	}

	out.outf("TASK HISTORY — %s", docID)
	if len(entries) == 0 {
		out.outf("")
		// Name WHICH stores answered. "Both" over a report that never asked
		// the events feed would be the same manufactured confidence this
		// command exists to refuse.
		if rep.Events != nil {
			out.outf("Both stores ANSWERED and recorded no mutations for this row.")
		} else {
			out.outf("The revision store ANSWERED and recorded no mutations for this row.")
		}
		out.outf("  MEASURED empty — distinct from a read that failed, which exits non-zero.")
		return exitOK
	}
	out.outf("%d mutation(s), newest first. Each line: when · what · rev · store · WHO, as the store answered it.", len(entries))
	out.outf("")

	notStamped := 0
	for _, e := range entries {
		if e.Attr.State == attrNotStamped {
			notStamped++
		}
		out.outf("  %s  %-14s  rev=%s  [%s]", e.When.UTC().Format("2006-01-02T15:04:05Z"), e.What, e.Rev, e.Source)
		out.outf("      who: %s%s", e.Attr.State, renderAttributionFields(e.Attr))
	}

	out.outf("")
	renderIdentityVerdict(out, len(entries), notStamped)
	if rep.Events != nil && rep.Events.HasMore {
		out.outf("")
		out.outf("PARTIAL EVENTS PAGE: the events feed reported has_more — this row has MORE mutations than")
		out.outf("  were read. Raise --limit; a short list here is not evidence that nothing else happened.")
	}
	return exitOK
}

// renderAttributionFields appends the columns the store actually returned, or
// the reason there are none. The NOT STAMPED wording says UNMEASURED out loud:
// the reader must not be able to read a blank column as "no agent".
func renderAttributionFields(a attribution) string {
	if len(a.Fields) == 0 {
		return " — UNMEASURED: the store recorded no actor for this mutation"
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
		out.outf("AGENT IDENTITY: UNMEASURED on %d of %d mutation(s) read.", notStamped, total)
		out.outf("  BOTH stores were asked — the revision store's actor columns AND the mutation_events")
		out.outf("  caller block — and neither carried an actor for any mutation on this row. That is what")
		out.outf("  UNMEASURED means here: the stores recorded no actor, which is NOT 'nobody'.")
	case notStamped > 0:
		out.outf("AGENT IDENTITY: PARTIAL — %d of %d mutation(s) carry no actor at all (UNMEASURED);", notStamped, total)
		out.outf("  the rest were answered by a store and are shown above.")
	default:
		out.outf("AGENT IDENTITY: every one of the %d mutation(s) read was answered by a store.", total)
	}
	out.outf("")
	out.outf("NOT SHOWN, on purpose: content.claim.worker. That string is written by the client whose")
	out.outf("  mutations are being audited, so it is a self-report, never attribution. Printing it in")
	out.outf("  an agent column would manufacture the identity this command just measured as absent.")
	out.outf("  The `caller` block above is DIFFERENT: the server stamps it from the authenticated")
	out.outf("  request, not from a string the caller typed.")
	out.outf("")
	// NAME THE SOURCES. This timeline is the union of two disjoint stores, and
	// the per-line [store] tag says which one answered for each mutation.
	out.outf("SOURCES: the revision store (GET /v1/data/history) for create/publish/update, AND the")
	out.outf("  mutation_events feed (GET /v1/tasks/events?payload=true) for task.claimed, task.closed,")
	out.outf("  task.pulse, task.criterion, task.lease_renewed — the task verbs write NO revision, so")
	out.outf("  before this view read them a claim looked like a mutation that never happened.")
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

func emitHistoryJSON(out *writer, docID string, entries []timelineEntry, ev *eventsOutcome) int {
	items := make([]map[string]any, 0, len(entries))
	notStamped := 0
	for _, e := range entries {
		if e.Attr.State == attrNotStamped {
			notStamped++
		}
		items = append(items, map[string]any{
			"action":             e.What,
			"timestamp":          e.When.UTC(),
			"rev":                e.Rev,
			"source":             e.Source,
			"attribution_state":  e.Attr.State.String(),
			"attribution_fields": e.Attr.Fields,
		})
	}
	payload := map[string]any{
		"doc_id":                   docID,
		"read":                     true,
		"count":                    len(items),
		"mutations":                items,
		"agent_identity_absent_on": notStamped,
		"agent_identity_verdict":   identityVerdict(len(items), notStamped),
		"claim_worker_shown":       false,
	}
	// STATE WHETHER THE SECOND STORE WAS READ. A consumer that cannot tell
	// "the events feed said no caller" from "the events feed was never asked"
	// is back at the defect, one layer up.
	if ev == nil {
		payload["events_read"] = nil
	} else {
		payload["events_read"] = ev.Read
		payload["events_count"] = len(ev.Events)
		payload["events_has_more"] = ev.HasMore
	}
	out.renderJSON(payload)
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
	out.outf("  The per-mutation timeline for one task row, read from BOTH stores that record")
	out.outf("  mutations: the revision store (create/publish/update) and the mutation_events")
	out.outf("  feed (task.claimed, task.closed, task.pulse, task.criterion). The task verbs")
	out.outf("  write no revision at all, so the second feed is where a claim or a close lives.")
	out.outf("")
	out.outf("  Each entry reports WHO as the answering store answered it: STAMPED,")
	out.outf("  ANSWERED-EMPTY, or NOT STAMPED (UNMEASURED — the stores recorded no actor,")
	out.outf("  which is NOT 'nobody'). A [store] tag on each line says which one answered.")
	out.outf("")
	out.outf("  EITHER read failing exits non-zero and says which store faulted; a fault is")
	out.outf("  never rendered as an empty timeline or as an absence of attribution.")
	out.outf("  content.claim.worker is deliberately NOT shown — it is a client self-report,")
	out.outf("  not server attribution. The event `caller` block IS server-stamped.")
}
