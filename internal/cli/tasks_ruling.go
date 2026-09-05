package cli

// tasks_ruling.go — THE RULING LINE.
//
// A ruling already made on a row lives at `content.disposition` +
// `content.disposition_reason` (`bp task stage` writes the pair on EVERY
// target, so the field is common, and PDS-D306 named it the DURABLE venue for
// a park/adjudication reason). Until this file, nothing in the claim/dispatch
// path showed it: `bp task claim` echoed the fencing epoch, the lease line and
// the server's help[] templates and said nothing about the ruling; `bp task
// get` buried it inside the `doc` object beside forty other keys, which in
// human (table) mode renders as ONE truncated cell.
//
// Measured harm (lead-security-3r, 2026-09-03): a row carrying "RULED by
// team-lead, 2026-09-02 … declare it unsupported, with the refusal SURFACED"
// still read as an open decision in its title and acceptance_criteria, so a
// worker was dispatched to draft ruling options for a decision made a day
// earlier and found the ruling by accident in the raw JSON, after the analysis
// was done.
//
// THE INVARIANT: a claimer cannot miss a ruling the row already carries.
//
// Rendering rules, all of them deliberate:
//
//   - The claim/next line rides STDERR in EVERY output mode, from runCommand's
//     post-2xx hook beside emitHelpHints/emitClaimLease — the one site proven
//     to fire regardless of output shape. stdout stays a single parseable
//     document under -o json/yaml, where the machine consumer reads
//     doc.content.disposition_reason itself.
//   - The prefix is a SHOUT, not "help: ". The whole defect was a ruling that
//     read like boilerplate, so the line must not be confusable with the
//     server's next-command templates.
//   - Read from the response the CLI ALREADY has. `Params.render_doc/2`'s
//     :full view carries `content` verbatim on the claim, next and get
//     envelopes, so no second network call is spent.
//   - Absent or empty → print NOTHING. A row with no ruling has a
//     byte-identical receipt to the one it had before this file.

import (
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/mattn/go-runewidth"
)

// rulingBannerPrefix heads the claim/next line. Deliberately NOT "help: " and
// not "notice: " — those two prefixes are what a dispatching agent has learned
// to skim past, and this line exists precisely because a ruling that reads like
// boilerplate gets skimmed.
const rulingBannerPrefix = "!! THIS ROW CARRIES A RULING: "

// rulingLoudCommands are the verbs whose 2xx receipt shouts a recorded ruling.
// Keyed on the manifest command id, not on the envelope shape: EVERY task
// envelope carries `doc.content`, so a shape-keyed hook would repeat the banner
// on pulse, stamp, close and get — and `task get` renders the ruling in place
// (rulingHeaderLines) rather than as a claim-time shout.
var rulingLoudCommands = map[string]bool{
	"task.claim": true,
	"task.next":  true,
}

// taskRuling is the recorded adjudication a task row carries. Strings only: a
// non-string (or absent) disposition/disposition_reason decodes to "" and is
// treated as ABSENT, never rendered as a Go zero value.
type taskRuling struct {
	Title       string
	Disposition string
	Reason      string
}

// hasReason reports whether the row carries a ruling REASON — the thing a
// claimer must not miss. A bare `disposition` with no reason is a lifecycle
// label the board already shows and earns no shout.
func (r taskRuling) hasReason() bool { return r.Reason != "" }

// rulingFromEnvelope decodes the response doc's title + content ruling fields,
// looking first at the raw body (the tasks endpoints emit flat envelopes) and
// then inside a {"result": …} wrapper — the same two-shape walk helpEntries and
// leaseFromEnvelope do.
func rulingFromEnvelope(body []byte) (taskRuling, bool) {
	if r, ok := rulingOf(body); ok {
		return r, true
	}
	return rulingOf(unwrapResult(body))
}

func rulingOf(body []byte) (taskRuling, bool) {
	var env struct {
		Doc struct {
			Title   string `json:"title"`
			Content struct {
				Disposition string `json:"disposition"`
				Reason      string `json:"disposition_reason"`
			} `json:"content"`
		} `json:"doc"`
	}
	if json.Unmarshal(body, &env) != nil {
		return taskRuling{}, false
	}
	r := taskRuling{
		Title:       strings.TrimSpace(env.Doc.Title),
		Disposition: strings.TrimSpace(env.Doc.Content.Disposition),
		Reason:      strings.TrimSpace(env.Doc.Content.Reason),
	}
	if r.Disposition == "" && r.Reason == "" {
		return taskRuling{}, false
	}
	return r, true
}

// emitTaskRuling prints the claim-time ruling line for a claim/next 2xx that
// carried one. Silent for every other verb and for every row with no recorded
// reason.
func emitTaskRuling(out *writer, cmd manifest.Command, respBody []byte) {
	if !rulingLoudCommands[cmd.ID] {
		return
	}
	r, ok := rulingFromEnvelope(respBody)
	if !ok || !r.hasReason() {
		return
	}
	out.errf("%s%s", rulingBannerPrefix, r.Reason)
	if r.Disposition != "" {
		out.errf("   disposition=%s — this decision is ALREADY MADE; re-read the row before you build to it", r.Disposition)
	}
}

// rulingHeaderKeys are the header's column labels; the widest one sets the pad
// so the block aligns with itself (renderKV measures its own keys separately).
var rulingHeaderKeys = []string{"title", "disposition", "disposition_reason"}

// emitTaskGetRulingHeader is the `bp task get` half: in the HUMAN (table)
// rendering only, print the row's title and — directly under it — the recorded
// disposition and disposition_reason, ABOVE the key/value dump where the whole
// `doc` object collapses into one truncated cell.
//
// It fires only for task.get, only in the table arm of renderSuccess (so
// -o json / -o yaml / -o minimal stdout is byte-identical to before), and only
// when the row actually carries a ruling — a row with none renders exactly as
// it always has.
func emitTaskGetRulingHeader(out *writer, cmd manifest.Command, payload []byte) {
	if cmd.ID != "task.get" {
		return
	}
	r, ok := rulingFromEnvelope(payload)
	if !ok {
		return
	}
	width := 0
	for _, k := range rulingHeaderKeys {
		if n := runewidth.StringWidth(k); n > width {
			width = n
		}
	}
	// The title leads so the ruling has something to sit UNDER; a row whose
	// title the envelope omitted still gets its ruling, headed by an honest
	// "(untitled)" rather than a blank line pretending to be one.
	title := r.Title
	if title == "" {
		title = "(untitled)"
	}
	out.outf("%s  %s", runewidth.FillRight("title", width), title)
	if r.Disposition != "" {
		out.outf("%s  %s", runewidth.FillRight("disposition", width), r.Disposition)
	}
	if r.Reason != "" {
		out.outf("%s  %s", runewidth.FillRight("disposition_reason", width), r.Reason)
	}
	out.outf("")
}
