package cli

// cmux_hook.go — `bp cmux hook <event>`: the fail-safe Claude Code hook adapter
// (task-TUI epic, wave 14). It runs ALONGSIDE cmux's own `cmux claude-hook`
// (we ADD, never replace). Each Claude hook event maps to one bp task action
// keyed on BARKPARK_TASK (the task this pane owns) + CmuxWorkerID() (the
// pane-stable worker):
//
//	SessionStart  → claim  (renewal-safe: re-claim under the same worker renews)
//	PreToolUse    → renew  (re-claim), throttled ≤1/renewEvery via an on-disk stamp
//	Stop/SessionEnd → close IFF every acceptance criterion is met, else LEAVE it
//	                  claimed so the server lease TTL expires → task.lease_expired
//	                  → a `↩ resume` in the NEXT strip (already built). That TTL is
//	                  the server's BARKPARK_TASK_LEASE_TTL_SECONDS (default 2700s).
//	other/unknown → no-op
//
// Fail-safe is NOT fail-invisible: every swallowed failure also drops a small
// last-error breadcrumb next to the renew stamp (writeHookBreadcrumb), so a dead
// bridge is diagnosable via `bp cmux status` even though the hook itself stays
// silent. The breadcrumb write is best-effort and panic-guarded — it can never
// change the exit code, touch stdout, or re-panic out of the top-level recover.
//
// CARDINAL fail-safe contract (design §7): a hook must NEVER break the agent.
// EVERY path exits 0 (incl a panic → recover → 0); NOTHING is written to stdout
// (diagnostics go to stderr, and only under --dry-run or BP_CMUX_DEBUG); the
// network is bounded (~4s) so a hung server never stalls a turn; a missing
// BARKPARK_TASK / unreadable task / unreachable server / malformed stdin all
// resolve to a silent no-op. The acceptance gate treats "can't read the task"
// as "can't prove acceptance" → leave claimed (the honest, resume-erring
// direction: a false resume is cheap, a false close strands unfinished work).

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// Test seams (package vars so unit tests can inject a fake stdin, a temp state
// dir, and a short network timeout without touching the process environment).
var (
	hookStdin     io.Reader              = os.Stdin
	userConfigDir func() (string, error) = os.UserConfigDir
	hookTimeout   time.Duration          = 4 * time.Second
)

// renewEvery is the PreToolUse renew throttle: at most one re-claim per window,
// well inside the server lease TTL (BARKPARK_TASK_LEASE_TTL_SECONDS, default
// 2700s), so a busy agent renews cheaply but not on every tool call.
const renewEvery = 60 * time.Second

// newHookClient builds the bounded, drafts-reading apiclient the hook acts
// through. The short Timeout (hookTimeout) is the fail-safe backstop: a hung
// server is treated as a no-op rather than stalling the agent's turn.
func newHookClient(ctx manifest.Context) *apiclient.Client {
	return apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts", // the acceptance gate reads uncommitted met=true edits
		Timeout:     hookTimeout,
	})
}

// runCmuxHook is the hook entrypoint. It ALWAYS returns exitOK — the whole point
// is that a hook error can never abort or stall the agent's turn. args is the
// tail after `cmux hook` (args[0] = the Claude event name).
func runCmuxHook(out *writer, g globals, ctx manifest.Context, args []string) (code int) {
	// A top-level recover is the last line of the fail-safe contract: even a
	// panic (nil map, bad decode, anything) resolves to a clean exit 0. It also
	// drops a best-effort breadcrumb so a crash-looping hook is still
	// diagnosable — the write is panic-guarded, so it can never re-panic here.
	// Armed FIRST, before ANY derivation, so no statement in this function runs
	// outside the recover.
	var event, task, worker string
	defer func() {
		if r := recover(); r != nil {
			writeHookBreadcrumb(event, worker, task, fmt.Sprintf("panic: %v", r))
			code = exitOK
		}
	}()

	if len(args) > 0 {
		event = args[0]
	}
	task = os.Getenv("BARKPARK_TASK")
	worker = taskboard.CmuxWorkerID()

	dryRun := g.dryRun || hasFlag(args, "--dry-run")
	debug := dryRun || os.Getenv("BP_CMUX_DEBUG") != ""

	dbg := func(format string, a ...any) {
		if debug {
			out.errf("cmux hook %s: "+format, append([]any{event}, a...)...)
		}
	}
	// fail records a swallowed failure: it logs to stderr under debug (like dbg)
	// AND leaves the last-error breadcrumb `bp cmux status` surfaces. NEVER writes
	// stdout and NEVER changes the exit code — the breadcrumb is the only trace.
	fail := func(format string, a ...any) {
		msg := fmt.Sprintf(format, a...)
		if debug {
			out.errf("cmux hook %s: %s", event, msg)
		}
		writeHookBreadcrumb(event, worker, task, msg)
	}

	// Drain stdin best-effort (Claude writes the hook JSON there). We key on env,
	// not stdin, so a malformed/empty body is harmless — decode and move on.
	_ = drainHookStdin()

	if task == "" {
		dbg("no BARKPARK_TASK — this pane owns no task; no-op")
		return exitOK
	}

	switch event {
	case "SessionStart":
		hookSessionStart(newHookClient(ctx), task, worker, dryRun, dbg, fail)
	case "PreToolUse":
		hookPreToolUse(newHookClient(ctx), task, worker, dryRun, dbg, fail)
	case "Stop", "SessionEnd":
		hookStopClose(newHookClient(ctx), task, worker, dryRun, dbg, fail)
	default:
		dbg("unhandled event — no-op (cmux's own hook may still act)")
	}
	return exitOK
}

// hookSessionStart claims the pane's task as the derived worker. A re-claim under
// the same worker id renews the lease (new epoch) and is idempotent across
// subagents, so a fresh subagent SessionStart just renews rather than 409ing.
func hookSessionStart(c *apiclient.Client, task, worker string, dryRun bool, dbg, fail func(string, ...any)) {
	if dryRun {
		dbg("would claim %s as %s", task, worker)
		return
	}
	res := taskboard.DoClaim(c, task, worker)
	if !res.OK {
		fail("SessionStart claim failed: %s", res.Message)
		return
	}
	dbg("%s", res.Message)
	// Seed the throttle so the first tool call doesn't immediately re-claim.
	writeRenewStamp(worker, task)
	// A healthy claim clears any stale breadcrumb: the last-error is present iff
	// the MOST RECENT hook action failed, so a recovered bridge reads clean.
	clearHookBreadcrumb(worker)
}

// hookPreToolUse renews the lease (re-claim), throttled to ≤1/renewEvery via an
// on-disk stamp. A missing/corrupt stamp fails OPEN (renew now) — renewing more
// often than needed is always safe; the only cost of a missed renew is an
// honest resume, never a hang.
func hookPreToolUse(c *apiclient.Client, task, worker string, dryRun bool, dbg, fail func(string, ...any)) {
	if !renewDue(worker, task) {
		dbg("within throttle window — skip renew")
		return
	}
	if dryRun {
		dbg("would renew (re-claim) %s as %s", task, worker)
		return
	}
	res := taskboard.DoClaim(c, task, worker)
	if !res.OK {
		fail("PreToolUse renew failed: %s", res.Message)
		return
	}
	dbg("renew: %s", res.Message)
	writeRenewStamp(worker, task)
	clearHookBreadcrumb(worker)
}

// hookStopClose is the acceptance-gated close (design §2a). Stop fires at the end
// of EVERY turn, not "the task is done", so we close ONLY on proven acceptance:
// the task carries ≥1 acceptance criterion and every one is met. Anything else
// (unmet, no criteria at all, or unreadable) leaves the claim to lease-expire
// into a resume. To close, re-claim first to observe the LIVE epoch (design §2b:
// no persisted epoch across the separate SessionStart/Stop processes) — a
// re-claim that 409s means someone else holds the lease, so we don't close (no
// theft).
func hookStopClose(c *apiclient.Client, task, worker string, dryRun bool, dbg, fail func(string, ...any)) {
	doc, ok := c.GetPerspective("task", task, "drafts")
	if !ok {
		// A read failure (server down / gone) blocked the close — a genuine
		// failure worth a breadcrumb, not the honest unmet-criteria no-ops below.
		fail("Stop: task unreadable — can't prove acceptance; leaving claimed → resume")
		return
	}
	total, allMet := acceptanceAllMet(doc)
	if total == 0 {
		dbg("no acceptance criteria — can't prove doneness; leaving claimed → resume")
		return
	}
	if !allMet {
		dbg("acceptance not proven (criteria unmet); leaving claimed → resume")
		return
	}
	if dryRun {
		dbg("would re-claim %s for the live epoch, then close as %s", task, worker)
		return
	}
	epoch, notices, help, err := c.TaskClaimN(task, worker)
	if err != nil {
		fail("Stop: re-claim for epoch failed (%v) — not closing (no theft)", err)
		return
	}
	// The re-claim carries the same advisory rail-awareness notices + help[] every
	// other claim surface now renders (charter D18). The hook's CARDINAL contract
	// forbids stdout and gates diagnostics behind debug, so surface them through
	// dbg — a blocker that landed on this task (or the next-step templates) is a
	// breadcrumb for `BP_CMUX_DEBUG`, never a line on the agent's turn.
	for _, n := range notices {
		if n.Type != "" {
			dbg("notice: %s", n.Type)
		}
	}
	for _, h := range help {
		if h != "" {
			dbg("help: %s", h)
		}
	}
	// THE FENCE IS ARMED FIRST, AND THE BYPASS IS NEVER SILENT.
	//
	// The agent marking its own acceptance criteria met is a LEGITIMATE
	// post-claim change, but it trips the server's work-digest fence
	// (doc_changed_since_claim) — and the renewal above keeps the claim-time
	// digest, so the renewal cannot clear it. D82's answer is observed_rev:
	// strict full-rev CAS is the server's sanctioned bypass (close.ex
	// short-circuits check_work_digest whenever observed_rev is non-nil), and
	// the worker match already prevents theft.
	//
	// That ruling STANDS — but sending observed_rev unconditionally made the
	// hook the ONE closer the fence never protects, and made it invisible when
	// the brief moved under the claim (someone rewriting a criterion out of
	// band looks exactly like the agent ticking its own boxes). So: close with
	// the fence ARMED. When the brief did not move, that close lands and NO
	// bypass is used at all. Only a doc_changed_since_claim refusal opens the
	// bypass, and only after the drift is NAMED on the diagnostic channel (the
	// hook's CARDINAL contract forbids stdout, so dbg is the venue) together
	// with the server's own reason, which suffixes the changed field.
	//
	// Cost, stated honestly: the drifted path now spends one extra round trip
	// (close → 409 → fresh GET → close) while the undrifted path spends one
	// FEWER (no fresh-rev GET at all). The server is the only authority on
	// whether the brief moved — the hook holds nothing it could compare.
	closeNotices, closeHelp, cerr := c.TaskCloseN(task, worker, epoch)
	if cerr == nil {
		for _, n := range closeNotices {
			if n.Type != "" {
				dbg("notice: %s", n.Type)
			}
		}
		for _, h := range closeHelp {
			if h != "" {
				dbg("help: %s", h)
			}
		}
		dbg("close: closed · epoch %d (work-digest fence held — no observed_rev bypass needed)", epoch)
		clearHookBreadcrumb(worker)
		return
	}
	if !isDocChangedSinceClaim(cerr) {
		fail("Stop: close failed: %s", cerr.Error())
		return
	}
	// The brief CHANGED under this claim. Say so — naming the server's own
	// reason, whose suffix carries the changed field — then take D82's bypass.
	dbg("close: the brief changed under this claim (server refused with %s) — the work-digest fence blocked the close; re-closing through the observed_rev CAS (D82), which SKIPS that fence", cerr.Error())
	rev := ""
	if fresh, ok := c.GetPerspective("task", task, "drafts"); ok {
		rev = docRev(fresh)
	}
	if rev == "" {
		// Without a current rev there is no sanctioned bypass, and a rev-less
		// retry would only repeat the 409. Leave it claimed → resume, which is
		// the honest direction, and breadcrumb WHY.
		fail("Stop: the brief changed under this claim and the current rev is unreadable — not closing; re-read the task and close with observed_rev")
		return
	}
	res := taskboard.DoCloseRev(c, task, worker, epoch, rev)
	if !res.OK {
		fail("Stop: close failed after the brief changed under the claim: %s", res.Message)
		return
	}
	dbg("close (through the observed_rev bypass): %s", res.Message)
	clearHookBreadcrumb(worker)
}

// isDocChangedSinceClaim reports whether a close refusal is the server's
// work-digest fence. The reason arrives VERBATIM from the envelope and may
// carry a colon-suffixed field list ("doc_changed_since_claim:brief"), so this
// matches the code, never the whole string — and it matches ONLY that code, so
// every other refusal (fenced_off, stale_claim, a transport failure) still
// takes the honest fail path instead of silently escalating to a strict-CAS
// close.
func isDocChangedSinceClaim(err error) bool {
	if err == nil {
		return false
	}
	reason := strings.ToLower(strings.TrimSpace(err.Error()))
	return reason == "doc_changed_since_claim" || strings.HasPrefix(reason, "doc_changed_since_claim:")
}

// docRev pulls the document rev out of the flattened envelope (the doc API
// returns "rev"; "_rev" is tolerated for forward-compat). Empty when absent.
func docRev(doc apiclient.Doc) string {
	for _, k := range []string{"rev", "_rev"} {
		raw, ok := doc.Extra[k]
		if !ok {
			continue
		}
		var v string
		if json.Unmarshal(raw, &v) == nil && v != "" {
			return v
		}
	}
	return ""
}

// acceptanceAllMet decodes content.acceptance_criteria (flattened onto the
// envelope top level) and reports the count and whether EVERY entry is met.
// Mirrors the server's tolerance contract: met is true ONLY for the JSON literal
// true (absent/false/other → not met). Zero criteria → (0,false): a task with no
// criteria can never be PROVEN done on a turn boundary.
func acceptanceAllMet(doc apiclient.Doc) (total int, allMet bool) {
	raw, ok := doc.Extra["acceptance_criteria"]
	if !ok {
		return 0, false
	}
	var items []struct {
		Met bool `json:"met"`
	}
	if err := json.Unmarshal(raw, &items); err != nil {
		return 0, false
	}
	if len(items) == 0 {
		return 0, false
	}
	for _, it := range items {
		if !it.Met {
			return len(items), false
		}
	}
	return len(items), true
}

// hookInput is the Claude hook JSON on stdin. We drain it to be a well-behaved
// hook; our actions key on env, so the fields are captured only for debug.
type hookInput struct {
	SessionID      string `json:"session_id"`
	CWD            string `json:"cwd"`
	TranscriptPath string `json:"transcript_path"`
	ToolName       string `json:"tool_name"`
}

func drainHookStdin() hookInput {
	var in hookInput
	if hookStdin == nil {
		return in
	}
	data, err := io.ReadAll(io.LimitReader(hookStdin, 1<<20))
	if err != nil || len(data) == 0 {
		return in
	}
	_ = json.Unmarshal(data, &in) // best-effort: malformed → zero value, never an error out
	return in
}

// renewStamp is the on-disk PreToolUse throttle record (design §2c).
type renewStamp struct {
	Worker        string `json:"worker"`
	Task          string `json:"task"`
	LastRenewUnix int64  `json:"last_renew_unix"`
}

// cmuxStampPath is {UserConfigDir}/barkpark/cmux/<sha1(worker\x00task)>.json —
// one stamp per (worker,task) pair so distinct panes never collide.
func cmuxStampPath(worker, task string) (string, error) {
	base, err := userConfigDir()
	if err != nil || base == "" {
		return "", errors.New("no user config dir")
	}
	sum := sha1.Sum([]byte(worker + "\x00" + task))
	return filepath.Join(base, "barkpark", "cmux", hex.EncodeToString(sum[:])+".json"), nil
}

// renewDue reports whether a PreToolUse renew is warranted. It fails OPEN
// (renew now) on any read/parse trouble — a missing stamp (first tool call after
// a claim seeds it), a corrupt stamp, or an unreadable config dir all return
// true, because over-renewing is safe and under-renewing only risks a resume.
func renewDue(worker, task string) bool {
	p, err := cmuxStampPath(worker, task)
	if err != nil {
		return true
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return true
	}
	var s renewStamp
	if json.Unmarshal(data, &s) != nil {
		return true
	}
	return time.Since(time.Unix(s.LastRenewUnix, 0)) >= renewEvery
}

// writeRenewStamp records now() as the last renew for (worker,task). Best-effort:
// a write failure just means the next PreToolUse renews again (safe).
func writeRenewStamp(worker, task string) {
	p, err := cmuxStampPath(worker, task)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return
	}
	data, err := json.Marshal(renewStamp{Worker: worker, Task: task, LastRenewUnix: time.Now().Unix()})
	if err != nil {
		return
	}
	_ = os.WriteFile(p, data, 0o644)
}

// hookBreadcrumb is the last-error trace a swallowed hook failure leaves behind
// so a dead bridge is diagnosable in one `bp cmux status`. It lives beside the
// renew stamp in the cmux state dir, one file per worker (pane), overwritten by
// each new failure and REMOVED by the next healthy action — so its presence
// means "the most recent hook action failed", nothing older.
type hookBreadcrumb struct {
	Event  string `json:"event"`
	Error  string `json:"error"`
	Worker string `json:"worker"`
	Task   string `json:"task"`
	Unix   int64  `json:"unix"`
}

// cmuxLastErrorPath is {UserConfigDir}/barkpark/cmux/lasterr-<sha1(worker)>.json.
// The `lasterr-` prefix + a worker-only hash keep it distinct from the renew
// stamp's <sha1(worker\x00task)>.json in the same directory.
func cmuxLastErrorPath(worker string) (string, error) {
	base, err := userConfigDir()
	if err != nil || base == "" {
		return "", errors.New("no user config dir")
	}
	sum := sha1.Sum([]byte("lasterr\x00" + worker))
	return filepath.Join(base, "barkpark", "cmux", "lasterr-"+hex.EncodeToString(sum[:])+".json"), nil
}

// writeHookBreadcrumb records a swallowed failure. Best-effort AND panic-guarded:
// it MUST NOT change the exit code, touch stdout, or re-panic — the top-level
// recover calls it, so an unwritable/panicking state dir has to resolve here to a
// silent no-op rather than escaping the recover.
func writeHookBreadcrumb(event, worker, task, errMsg string) {
	defer func() { _ = recover() }()
	p, err := cmuxLastErrorPath(worker)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return
	}
	data, err := json.Marshal(hookBreadcrumb{
		Event:  event,
		Error:  errMsg,
		Worker: worker,
		Task:   task,
		Unix:   time.Now().Unix(),
	})
	if err != nil {
		return
	}
	_ = os.WriteFile(p, data, 0o644)
}

// clearHookBreadcrumb removes a worker's breadcrumb after a healthy action, so a
// recovered bridge stops reporting a stale error. Best-effort + panic-guarded.
func clearHookBreadcrumb(worker string) {
	defer func() { _ = recover() }()
	p, err := cmuxLastErrorPath(worker)
	if err != nil {
		return
	}
	_ = os.Remove(p)
}

// readHookBreadcrumb loads a worker's last-error breadcrumb for `bp cmux status`.
// Reports ok=false when absent, unreadable, malformed, or empty-error — the
// status path stays silent when there is nothing honest to show. Panic-guarded
// so a hostile state dir degrades to (zero,false) rather than crashing status.
func readHookBreadcrumb(worker string) (hookBreadcrumb, bool) {
	defer func() { _ = recover() }()
	var bc hookBreadcrumb
	p, err := cmuxLastErrorPath(worker)
	if err != nil {
		return bc, false
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return bc, false
	}
	if json.Unmarshal(data, &bc) != nil || bc.Error == "" {
		return hookBreadcrumb{}, false
	}
	return bc, true
}

// hasFlag reports whether flag appears verbatim in args (for the defensive
// tail-side --dry-run check; --dry-run is also a global, so g.dryRun usually
// already carries it).
func hasFlag(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}
