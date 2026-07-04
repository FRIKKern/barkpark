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
type ActionResult struct {
	OK      bool
	Message string
}

// DoClaim claims docID for worker over POST /v1/tasks/:doc_id/claim. On success
// the returned fencing epoch is echoed back so the caller can hold it for the
// matching close (the epoch is the CAS token). A 409 (already claimed / stale
// claim / resource conflict) or any transport failure comes back as OK:false
// with the server's reason humanised — never a silent success, never a retry.
func DoClaim(c *apiclient.Client, docID, worker string) ActionResult {
	epoch, err := c.TaskClaim(docID, worker)
	if err != nil {
		return ActionResult{OK: false, Message: "claim failed: " + humanizeReason(err)}
	}
	return ActionResult{OK: true, Message: fmt.Sprintf("claimed as %s · epoch %d", worker, epoch)}
}

// DoClose closes docID for worker over POST /v1/tasks/:doc_id/close, fencing on
// epoch — the epoch DoClaim observed at claim time (observed_epoch in the
// request body). If the row moved under us the server returns fenced_off /
// stale_claim on a 409 and this reports OK:false with that honest reason; only a
// clean close reports OK:true.
func DoClose(c *apiclient.Client, docID, worker string, epoch int) ActionResult {
	if err := c.TaskClose(docID, worker, epoch); err != nil {
		return ActionResult{OK: false, Message: "close rejected: " + humanizeReason(err)}
	}
	return ActionResult{OK: true, Message: fmt.Sprintf("closed · epoch %d", epoch)}
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
// (cmd/barkpark/tui-mutations.go) — copied rather than imported because
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
