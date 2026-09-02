package taskboard

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// openURL launches the OS browser on a URL. It is a package-level var (the
// browserOpener seam idiom) so the 'o' reducer's tests observe the launch
// without spawning a real browser. taskboard must NOT import internal/cli
// (that would be an import cycle: cli imports taskboard), so the per-OS exec
// pattern is copied verbatim from internal/cli/cloud_open_cmd.go openInBrowser.
// It Start()s the helper (never Wait) so the pane never freezes on the launch.
var openURL = func(url string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", url).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	default:
		return exec.Command("xdg-open", url).Start()
	}
}

// ActionResult is the outcome of a board act verb (claim/close). OK reports
// whether the mutation landed; Message is a single short human sentence the
// status line renders verbatim — a confirmation on success ("claimed as
// tui-mbp · epoch 4") or the server's honest refusal on failure ("close
// rejected: stale epoch (task moved)"). It NEVER reports OK for a request the
// server declined; the epoch-CAS fencing is the server's, and this layer only
// translates its verdict.
//
// Role is an OPTIONAL strip-color override: RoleNeutral (the zero value) means
// "let the reducer pick the default" (RoleOK on success, RoleDanger on failure);
// a non-zero Role wins. It exists so a landed claim that ALSO carries a
// rail-awareness notice can paint warn/info instead of the plain green — the
// notice is the point of the color, not the success.
type ActionResult struct {
	OK      bool
	Message string
	Role    Role
	// Epoch is the fencing epoch the server wrote, on the verbs that write one
	// (DoClaim). It is the same number Message renders, carried as data so a
	// caller that must HOLD the epoch — the cmux hook stamps it for the close
	// that runs in a later process — does not have to parse the sentence back
	// apart. Zero on every failure and on verbs that write no epoch.
	Epoch int
	// Help is the server's help[] next-command templates the claim/close 2xx
	// envelope carried (charter D18) — parity with the CLI's stderr help: lines so
	// the board/hook no longer silently drops them. It rides the struct as
	// structured data; foldHelp surfaces the PRIMARY template inline in the
	// one-line status strip (the whole set stays available on the field, and on the
	// CLI stderr path). Empty when the server sent none.
	Help []string
}

// DoClaim claims docID for worker over POST /v1/tasks/:doc_id/claim. On success
// the returned fencing epoch is echoed back so the caller can hold it for the
// matching close (the epoch is the CAS token). A 409 (already claimed / stale
// claim / resource conflict) or any transport failure comes back as OK:false
// with the server's reason humanised — never a silent success, never a retry.
func DoClaim(c *apiclient.Client, docID, worker string) ActionResult {
	epoch, notices, help, err := c.TaskClaimN(docID, worker)
	if err != nil {
		return ActionResult{OK: false, Message: "claim failed: " + humanizeReason(err)}
	}
	res := ActionResult{OK: true, Message: fmt.Sprintf("claimed as %s · epoch %d", worker, epoch), Epoch: epoch}
	return foldHelp(withTopNotice(res, notices), help)
}

// DoClose closes docID for worker over POST /v1/tasks/:doc_id/close, fencing on
// epoch — the epoch DoClaim observed at claim time (observed_epoch in the
// request body). If the row moved under us the server returns fenced_off /
// stale_claim on a 409 and this reports OK:false with that honest reason; only a
// clean close reports OK:true.
// DoCloseRev is DoClose with an optional observed_rev strict-CAS guard (charter
// D82). The cmux Stop hook passes the freshly-read rev so an agent that marked
// its OWN acceptance criteria met — a legitimate post-claim change that trips
// the work-digest fence — still closes; empty rev falls through to DoClose.
func DoCloseRev(c *apiclient.Client, docID, worker string, epoch int, observedRev string) ActionResult {
	if observedRev == "" {
		return DoClose(c, docID, worker, epoch)
	}
	notices, help, err := c.TaskCloseRevN(docID, worker, epoch, observedRev)
	if err != nil {
		if msg, ok := resyncGuidance(err); ok {
			return ActionResult{OK: false, Message: msg, Role: RoleDanger}
		}
		return ActionResult{OK: false, Message: "close rejected: " + humanizeReason(err)}
	}
	res := ActionResult{OK: true, Message: fmt.Sprintf("closed · epoch %d", epoch)}
	return foldHelp(withTopNotice(res, notices), help)
}

func DoClose(c *apiclient.Client, docID, worker string, epoch int) ActionResult {
	notices, help, err := c.TaskCloseN(docID, worker, epoch)
	if err != nil {
		// The two recoverable fence reasons get actionable resync guidance instead
		// of the bare humanised reason: they tell the worker the concrete next
		// keypress (c to renew, or enter to re-read) rather than a dead-end refusal.
		if msg, ok := resyncGuidance(err); ok {
			return ActionResult{OK: false, Message: msg, Role: RoleDanger}
		}
		return ActionResult{OK: false, Message: "close rejected: " + humanizeReason(err)}
	}
	res := ActionResult{OK: true, Message: fmt.Sprintf("closed · epoch %d", epoch)}
	return foldHelp(withTopNotice(res, notices), help)
}

// withTopNotice folds the single most important rail-awareness notice into a
// SUCCESS result's strip line and colors it: blocked_while_claimed (your held
// task just gained a blocker) paints warn, rail_changed (the parent rail moved)
// paints info. Only ONE is shown — the strip is one line — and blocked outranks
// rail_changed. No known notice leaves the plain green confirmation untouched.
func withTopNotice(res ActionResult, notices []apiclient.TaskNotice) ActionResult {
	n, ok := topNotice(notices)
	if !ok {
		return res
	}
	switch n.Type {
	case "blocked_while_claimed":
		res.Message += " · blocked while claimed: " + n.TaskID
		res.Role = RoleWarn
	case "rail_changed":
		res.Message += " · rail changed: " + n.ParentID
		res.Role = RoleInfo
	}
	return res
}

// foldHelp records the server's help[] next-command templates on the result AND
// surfaces the PRIMARY one inline in the one-line status strip (charter D18 — the
// board/hook used to drop help entirely). Only help[0] is inlined: after a claim
// that is the pulse template, the single most useful next step; the full set
// stays on res.Help for a caller that wants it, and the CLI stderr path prints
// them all. Empty help leaves the message untouched. The strip truncates on
// width, so a long template never breaks layout — it clips like any other reason.
func foldHelp(res ActionResult, help []string) ActionResult {
	res.Help = help
	for _, h := range help {
		if h != "" {
			res.Message += " · next: " + h
			break
		}
	}
	return res
}

// topNotice picks the highest-priority notice to surface on the one-line strip:
// a blocked_while_claimed always outranks a rail_changed (a new blocker on your
// work is more urgent than a parent-rail move). Returns false when the list
// holds neither known shape (an unknown future notice is ignored, not guessed).
func topNotice(notices []apiclient.TaskNotice) (apiclient.TaskNotice, bool) {
	var rail *apiclient.TaskNotice
	for i := range notices {
		switch notices[i].Type {
		case "blocked_while_claimed":
			return notices[i], true
		case "rail_changed":
			if rail == nil {
				rail = &notices[i]
			}
		}
	}
	if rail != nil {
		return *rail, true
	}
	return apiclient.TaskNotice{}, false
}

// resyncGuidance maps the two close-time fence reasons a fresh re-read recovers
// to actionable strip copy. fenced_off means the row changed under your claim (a
// blocker/move landed, or the lease was swept+reclaimed) — a re-claim under your
// own worker id renews the lease (new epoch), so press c then x again.
// doc_changed_since_claim means the brief itself changed — reopen to re-read it,
// then close. Any other reason returns false and falls through to humanizeReason.
func resyncGuidance(err error) (string, bool) {
	switch strings.TrimSpace(strings.ToLower(err.Error())) {
	case "fenced_off":
		return "fenced off — the task changed under you (blocker/move/sweep); press c to renew, then x again", true
	case "doc_changed_since_claim":
		return "the brief changed since your claim — reopen the task (enter) to re-read, then close again", true
	}
	return "", false
}

// humanizeReason turns the server's contract reason string (surfaced verbatim by
// apiclient.taskPost) or a transport error into a short honest phrase. Known
// reasons get a plain-words gloss; anything unrecognised is passed through
// verbatim-ish (trimmed) so we never swallow a message we don't understand.
func humanizeReason(err error) string {
	// Transport failures arrive as *url.Error, whose Error() spells the whole
	// request ('Post "http://…/claim": dial tcp …: connect: connection
	// refused') — hopeless on a narrow status line. Keep the honest root cause
	// ("connection refused", "no such host"), drop the plumbing.
	var uerr *url.Error
	if errors.As(err, &uerr) {
		if uerr.Timeout() {
			return "server timeout"
		}
		return "server unreachable (" + rootCause(uerr).Error() + ")"
	}
	raw := strings.TrimSpace(err.Error())
	switch strings.ToLower(raw) {
	case "fenced_off":
		return "stale epoch (task moved)"
	case "stale_claim":
		return "claim moved under us (stale)"
	case "resource_conflict":
		return "resource conflict — files held by another task"
	case "already_claimed":
		return "already claimed by another worker"
	case "not_ready":
		return "task is not ready"
	case "no_ready":
		return "nothing ready to claim"
	case "blocked_by_unsatisfied_deps":
		return "blocked by unsatisfied dependencies"
	case "not_found", "task not found":
		return "task not found"
	}
	if raw == "" {
		return "unknown error"
	}
	return raw
}

// rootCause walks the Unwrap chain to the innermost error — the short truth a
// wrapped transport error buries ("connection refused" under url.Error →
// net.OpError → os.SyscallError).
func rootCause(err error) error {
	for {
		next := errors.Unwrap(err)
		if next == nil {
			return err
		}
		err = next
	}
}

// ResolveWorker computes the board's task-claim worker id: BARKPARK_WORKER_ID
// when set, else "tui-<hostname>", else "tui-unknown" when the hostname is
// unreadable. This mirrors the desk TUI's workerIdentity convention
// (cmd/barkpark/tui_mutations.go) — copied rather than imported because
// cmd/barkpark is package main and cannot be depended on.
func ResolveWorker() string {
	if v := os.Getenv("BARKPARK_WORKER_ID"); v != "" {
		return v
	}
	host, err := os.Hostname()
	if err != nil || host == "" {
		return "tui-unknown"
	}
	return "tui-" + host
}

// StudioTaskURL builds a best-effort deep link that opens the task document in
// Studio. Tasks have no dedicated Studio page — they open as documents in the
// native StudioLive document route (`/studio/:dataset/:type/:doc_id`, the same
// shape the OnixEdit book editor was folded into; see
// api/lib/barkpark_web/router.ex). We only hold baseURL + docID here, so we use
// the conventional defaults (production dataset, `task` type); Studio resolves
// the session scope on open. The link is advisory — the board never blocks on
// it. Returns "" when baseURL or docID is empty (no link rather than a broken
// one). Any scheme (http/https) and a trailing slash on baseURL are handled.
func StudioTaskURL(baseURL, docID string) string {
	base := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if base == "" || docID == "" {
		return ""
	}
	return base + "/studio/production/task/" + url.PathEscape(docID)
}
