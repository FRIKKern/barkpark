package cli

// cmux_hook.go — `bp cmux hook <event>`: the fail-safe Claude Code hook adapter
// (task-TUI epic, wave 14). It runs ALONGSIDE cmux's own `cmux claude-hook`
// (we ADD, never replace). Each Claude hook event maps to one bp task action
// keyed on BARKPARK_TASK (the task this pane owns) + CmuxWorkerID() (the
// pane-stable worker):
//
//	SessionStart  → claim  (renewal-safe: re-claim under the same worker renews)
//	PreToolUse    → pulse  (renew + now-line), throttled ≤1/renewEvery via an
//	                on-disk stamp. NOT a re-claim: a claim renews SILENTLY and
//	                would take the row back if the lease had lapsed, while a
//	                pulse is holder-only, emits task.pulse, and carries a
//	                bounded now-line so an active pane is VISIBLE on the board
//	                instead of merely un-expired.
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

// renewEvery is the PreToolUse renew throttle: at most one pulse per window,
// well inside the server lease TTL (leaseTTLFloor), so a busy agent renews
// cheaply but not on every tool call.
const renewEvery = 60 * time.Second

// leaseTTLFloor is the server lease TTL the hook assumes when deciding whether
// a stamped epoch can still be live: BARKPARK_TASK_LEASE_TTL_SECONDS's default,
// 2700s. It is a FLOOR, not a mirror — the hook never reads the server's
// setting, so it must assume the SHORTEST lease it could be running against. An
// operator who raised the TTL only makes this conservative: the hook re-claims
// for a fresh epoch slightly earlier than it had to. An operator who LOWERED it
// costs one fenced close that falls back to the re-claim (hookStopClose), never
// a wrong close.
const leaseTTLFloor = 2700 * time.Second

// nowLineMax bounds the pulse now-line the hook composes. The server caps `now`
// at 500 bytes and answers a longer one with a 400, not a truncation — so the
// bound lives HERE, well under that, and the composed line is built from a
// closed vocabulary (see hookNowLine) rather than trimmed after the fact.
const nowLineMax = 160

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
	// not stdin, so a malformed/empty body is harmless — it decodes to the zero
	// value and hookNowLine degrades to a generic line. The ONLY thing read out
	// of it is the pulse's now-line vocabulary (tool_name + the cwd basename);
	// session_id and transcript_path are never sent anywhere.
	hookIn := drainHookStdin()

	if task == "" {
		dbg("no BARKPARK_TASK — this pane owns no task; no-op")
		return exitOK
	}

	switch event {
	case "SessionStart":
		hookSessionStart(newHookClient(ctx), task, worker, dryRun, dbg, fail)
	case "PreToolUse":
		hookPreToolUse(newHookClient(ctx), task, worker, hookNowLine(hookIn), dryRun, dbg, fail)
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
	// Seed the throttle so the first tool call doesn't immediately pulse, and
	// record the epoch this claim wrote (see renewStamp.LastEpoch).
	writeRenewStamp(worker, task, res.Epoch)
	// A healthy claim clears any stale breadcrumb: the last-error is present iff
	// the MOST RECENT hook action failed, so a recovered bridge reads clean.
	clearHookBreadcrumb(worker)
}

// hookPreToolUse renews the lease with a PULSE, throttled to ≤1/renewEvery via
// an on-disk stamp. A missing/corrupt stamp fails OPEN (pulse now) — renewing
// more often than needed is always safe; the only cost of a missed renew is an
// honest resume, never a hang.
//
// WHY A PULSE AND NOT A RE-CLAIM. Both renew the lease and both bump the epoch,
// so the lifetime arithmetic is unchanged. What changes is what the renewal
// MEANS on the other end:
//
//   - A pulse is visible. It writes content.claim.now (this pane's bounded
//     now-line) and emits a task.pulse mutation_event, so a board can say what
//     an active pane is doing. A bare re-claim renews in total silence — the
//     row looks identical before and after, which is exactly the "in_progress
//     means held, not observed" gap this closes.
//   - A pulse is holder-only. Tasks.Pulse refuses a lost lease with
//     :not_holder; Claim's fall-through would silently RE-CLAIM a reaped row
//     with a fresh work_digest, taking it back from whoever the sweeper freed
//     it for and swallowing any brief edit made in between.
//
// nowLine is already sanitized and bounded by hookNowLine; this function never
// composes one from raw hook input.
func hookPreToolUse(c *apiclient.Client, task, worker, nowLine string, dryRun bool, dbg, fail func(string, ...any)) {
	if !renewDue(worker, task) {
		dbg("within throttle window — skip pulse")
		return
	}
	if dryRun {
		dbg("would pulse %s as %s with now-line %q", task, worker, nowLine)
		return
	}
	epoch, help, err := c.TaskPulse(task, worker, nowLine)
	if err != nil {
		// not_holder is the honest shape of "this pane no longer owns the row"
		// (reaped / released / closed / stolen). It is a breadcrumb, NOT an
		// escalation to a re-claim: taking the row back is precisely the theft
		// the pulse verb exists to refuse.
		fail("PreToolUse pulse failed: %s", err.Error())
		return
	}
	for _, h := range help {
		if h != "" {
			dbg("help: %s", h)
		}
	}
	dbg("pulse: now-line %q · epoch %d", nowLine, epoch)
	writeRenewStamp(worker, task, epoch)
	clearHookBreadcrumb(worker)
}

// hookNowLine composes the pulse's now-line from the Claude hook context, under
// a closed vocabulary: the tool about to run and the basename of the working
// directory, each sanitized to [A-Za-z0-9._-] and length-capped, assembled into
// a fixed sentence. Anything that does not survive the filter is DROPPED, not
// escaped — the line degrades to a shorter true sentence rather than carrying
// unknown bytes to the server.
//
// What is deliberately NOT in it: session_id, transcript_path (or any transcript
// content), tool arguments, environment, and file contents. The now-line lands
// in content.claim.now, which every board reader can see; a heartbeat is not a
// channel for anything the pane happens to be holding. The cwd is reduced to its
// BASENAME for the same reason — "barkpark" is the useful half of an absolute
// path, and the rest is the operator's directory layout.
func hookNowLine(in hookInput) string {
	tool := sanitizeHookToken(in.ToolName)
	dir := ""
	if in.CWD != "" {
		if base := filepath.Base(in.CWD); base != "." && base != string(filepath.Separator) {
			dir = sanitizeHookToken(base)
		}
	}
	var line string
	switch {
	case tool != "" && dir != "":
		line = "cmux pane: running " + tool + " in " + dir
	case tool != "":
		line = "cmux pane: running " + tool
	case dir != "":
		line = "cmux pane: working in " + dir
	default:
		// Malformed, empty, or field-less hook context. The pulse still has to
		// carry SOMETHING (the server requires a non-empty now), and "active" is
		// the most it can honestly claim.
		line = "cmux pane: active"
	}
	if len(line) > nowLineMax {
		line = line[:nowLineMax]
	}
	return line
}

// sanitizeHookToken reduces one hook-context token to a safe, bounded fragment:
// ASCII letters, digits, '.', '_' and '-' survive; everything else (spaces,
// quotes, control bytes, path separators, any non-ASCII) is dropped. The cap is
// per-token so no single field can dominate the composed line.
func sanitizeHookToken(s string) string {
	const maxToken = 48
	var b strings.Builder
	for _, r := range s {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' ||
			r == '.' || r == '_' || r == '-' {
			b.WriteRune(r)
		}
		if b.Len() >= maxToken {
			break
		}
	}
	return b.String()
}

// hookStopClose is the acceptance-gated close (design §2a). Stop fires at the end
// of EVERY turn, not "the task is done", so we close ONLY on proven acceptance:
// the task carries ≥1 acceptance criterion and every one is met. Anything else
// (unmet, no criteria at all, or unreadable) leaves the claim to lease-expire
// into a resume.
//
// WHERE THE CLOSE'S EPOCH COMES FROM. Design §2b said there is no persisted
// epoch across the separate SessionStart/Stop processes, so the close re-claimed
// to observe a live one. There IS one now: every renewal stamps the epoch it
// wrote (renewStamp.LastEpoch), and PreToolUse renews by PULSE, which returns
// the fresh epoch on the same round trip it was already making. So:
//
//	stamp vouches  → close on the stamped epoch. No re-claim, and therefore no
//	                 epoch bump spent purely to learn a number this pane was
//	                 already told.
//	stamp silent   → re-claim for the live epoch, exactly as before (no stamp,
//	                 a stale one, a foreign one, or an unwritable state dir).
//	stamp WRONG    → the server says fenced_off; re-claim for the live epoch and
//	                 close again. The cache costs one refused round trip in that
//	                 case and never a wrong close.
//
// The re-claim keeps its second job in both fallbacks: a 409 there means someone
// else holds the lease, so we do not close (no theft).
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
		dbg("would close %s as %s on the epoch the last renewal stamped, re-claiming for a live one only if that stamp cannot vouch", task, worker)
		return
	}
	epoch, cached := stampedEpoch(worker, task)
	if cached {
		dbg("close: closing on the epoch the last renewal stamped (%d) — no re-claim, so no epoch bump is spent to learn it", epoch)
	} else {
		var err error
		if epoch, err = hookReclaimEpoch(c, task, worker, dbg); err != nil {
			fail("Stop: re-claim for epoch failed (%v) — not closing (no theft)", err)
			return
		}
	}
	if ok, fenced := hookCloseAtEpoch(c, task, worker, epoch, dbg, fail); ok || !fenced || !cached {
		// Landed, or refused for a reason a fresh epoch cannot fix, or refused on
		// an epoch that was already the live one. hookCloseAtEpoch has already
		// reported every failure it saw; there is nothing left to try.
		return
	}
	// The stamped epoch was stale after all: something else renewed this claim
	// inside the lease window. That is exactly the case the cache is allowed to
	// lose — pay the re-claim now and close on the live epoch.
	dbg("close: the stamped epoch %d is no longer live (the server fenced the close) — re-claiming for the live epoch and closing again", epoch)
	live, err := hookReclaimEpoch(c, task, worker, dbg)
	if err != nil {
		fail("Stop: re-claim after a fenced close failed (%v) — not closing (no theft)", err)
		return
	}
	_, _ = hookCloseAtEpoch(c, task, worker, live, dbg, fail)
}

// hookReclaimEpoch re-claims to observe the LIVE fencing epoch, surfacing the
// envelope's advisory rail-awareness notices + help[] every other claim surface
// renders (charter D18) on the diagnostic channel. The hook's CARDINAL contract
// forbids stdout and gates diagnostics behind debug, so they go through dbg — a
// blocker that landed on this task (or the next-step templates) is a breadcrumb
// for `BP_CMUX_DEBUG`, never a line on the agent's turn.
func hookReclaimEpoch(c *apiclient.Client, task, worker string, dbg func(string, ...any)) (int, error) {
	epoch, notices, help, err := c.TaskClaimN(task, worker)
	if err != nil {
		return 0, err
	}
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
	return epoch, nil
}

// hookCloseAtEpoch is the close itself, at one given epoch. ok reports whether
// the close landed; fenced reports whether the refusal was the server's epoch
// fence (fenced_off / stale_claim), which is the ONE refusal a fresh epoch can
// fix — the caller retries on a re-claimed epoch when the one it used came from
// the stamp cache. Every failure is reported here (fail → breadcrumb), including
// the fenced one, so a retry that lands clears the breadcrumb and a retry that
// is not attempted still leaves a trace.
func hookCloseAtEpoch(c *apiclient.Client, task, worker string, epoch int, dbg, fail func(string, ...any)) (ok, fenced bool) {
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
		return true, false
	}
	if !isDocChangedSinceClaim(cerr) {
		// Reported here either way. When it was the EPOCH fence the caller may
		// still retry on a re-claimed epoch — a breadcrumb that a landing retry
		// then clears is the right trade against a fenced close leaving no trace
		// at all when no retry is available.
		fail("Stop: close failed: %s", cerr.Error())
		return false, isFencedOff(cerr)
	}
	// The brief CHANGED under this claim. Say so — naming the server's own
	// reason, whose suffix carries the changed field — then take D82's bypass.
	dbg("close: the brief changed under this claim (server refused with %s) — the work-digest fence blocked the close; re-closing through the observed_rev CAS (D82), which SKIPS that fence", cerr.Error())
	rev := ""
	if fresh, gotFresh := c.GetPerspective("task", task, "drafts"); gotFresh {
		rev = docRev(fresh)
	}
	if rev == "" {
		// Without a current rev there is no sanctioned bypass, and a rev-less
		// retry would only repeat the 409. Leave it claimed → resume, which is
		// the honest direction, and breadcrumb WHY.
		fail("Stop: the brief changed under this claim and the current rev is unreadable — not closing; re-read the task and close with observed_rev")
		return false, false
	}
	res := taskboard.DoCloseRev(c, task, worker, epoch, rev)
	if !res.OK {
		// No fenced retry off this arm: DoCloseRev hands back a humanised
		// sentence, not the server's reason code, so "the epoch was stale" is
		// not distinguishable here from "the rev was". Guessing would risk a
		// second write on a refusal a fresh epoch cannot fix.
		fail("Stop: close failed after the brief changed under the claim: %s", res.Message)
		return false, false
	}
	dbg("close (through the observed_rev bypass): %s", res.Message)
	clearHookBreadcrumb(worker)
	return true, false
}

// isFencedOff reports whether a close refusal is the server's EPOCH fence —
// the one refusal a freshly re-claimed epoch can fix. Both codes the server
// uses for it count: fenced_off (the observed_epoch is not the current one) and
// stale_claim (the row moved under the claim). It matches the code with the
// same colon-suffix tolerance as isDocChangedSinceClaim, and ONLY those codes,
// so no other refusal — not_holder, a transport failure, the work-digest fence
// — can ever be answered by re-claiming and closing again.
func isFencedOff(err error) bool {
	if err == nil {
		return false
	}
	reason := strings.ToLower(strings.TrimSpace(err.Error()))
	for _, code := range []string{"fenced_off", "stale_claim"} {
		if reason == code || strings.HasPrefix(reason, code+":") {
			return true
		}
	}
	return false
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

// renewStamp is the on-disk PreToolUse throttle record (design §2c) AND the
// hook's only memory across its separate one-shot processes.
//
// LastEpoch is the fencing epoch the LAST renewal wrote — the claim's on
// SessionStart, the pulse's on PreToolUse. It exists because a pulse BUMPS the
// epoch (Tasks.Pulse.apply_pulse, exactly like Claim.do_renew), so by the time
// Stop runs, the epoch SessionStart saw is stale by however many pulses the
// turn made. Without this field the close has no epoch at all and must re-claim
// to learn one; with it, the close spends no write to find out what the last
// write already told this pane. It is a CACHE, not an authority — hookStopClose
// still falls back to the re-claim whenever the stamp cannot vouch for it.
type renewStamp struct {
	Worker        string `json:"worker"`
	Task          string `json:"task"`
	LastRenewUnix int64  `json:"last_renew_unix"`
	LastEpoch     int    `json:"last_epoch"`
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

// readRenewStamp loads the (worker,task) stamp. ok=false when it is absent,
// unreadable, malformed, or written for a DIFFERENT pane/task — the path is
// hashed from (worker,task), but a hash collision or a hand-edited file must not
// be allowed to hand one pane another pane's epoch, so the identity is
// re-checked against the file's own contents. Panic-guarded like every other
// state read on the hook path.
func readRenewStamp(worker, task string) (renewStamp, bool) {
	defer func() { _ = recover() }()
	var s renewStamp
	p, err := cmuxStampPath(worker, task)
	if err != nil {
		return s, false
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return s, false
	}
	if json.Unmarshal(data, &s) != nil {
		return renewStamp{}, false
	}
	if s.Worker != worker || s.Task != task {
		return renewStamp{}, false
	}
	return s, true
}

// renewDue reports whether a PreToolUse pulse is warranted. It fails OPEN
// (pulse now) on any read/parse trouble — a missing stamp (first tool call after
// a claim seeds it), a corrupt stamp, or an unreadable config dir all return
// true, because over-renewing is safe and under-renewing only risks a resume.
func renewDue(worker, task string) bool {
	s, ok := readRenewStamp(worker, task)
	if !ok {
		return true
	}
	return time.Since(time.Unix(s.LastRenewUnix, 0)) >= renewEvery
}

// stampedEpoch returns the epoch the last renewal wrote for this (worker,task),
// and whether it can still be trusted as the LIVE one.
//
// The freshness bound is leaseTTLFloor, not renewEvery: a stamp inside the
// shortest lease the hook could be running against still describes a lease that
// cannot have been reaped, so the epoch it names is the one no other renewal has
// had cause to bump. Past that floor the lease may have expired and been
// re-claimed by someone else, and a stale epoch would close on a lease this pane
// no longer holds — so the stamp stops vouching and the close re-claims instead.
//
// It is never AUTHORITATIVE: a concurrent pulse or claim from elsewhere can bump
// the epoch inside the window without touching this file. That case lands as a
// fenced_off close, which hookStopClose answers by re-claiming for the live
// epoch and closing again. The cache buys the common path a write; it never buys
// a wrong close.
func stampedEpoch(worker, task string) (int, bool) {
	s, ok := readRenewStamp(worker, task)
	if !ok || s.LastEpoch <= 0 {
		return 0, false
	}
	if time.Since(time.Unix(s.LastRenewUnix, 0)) >= leaseTTLFloor {
		return 0, false
	}
	return s.LastEpoch, true
}

// writeRenewStamp records now() as the last renew for (worker,task), together
// with the fencing epoch that renewal wrote. Best-effort: a write failure just
// means the next PreToolUse renews again and the close re-claims for its epoch
// (both safe). A non-positive epoch is stored as-is and stampedEpoch declines
// it — an unknown epoch must read as "no cached epoch", never as epoch 0.
func writeRenewStamp(worker, task string, epoch int) {
	p, err := cmuxStampPath(worker, task)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return
	}
	data, err := json.Marshal(renewStamp{
		Worker:        worker,
		Task:          task,
		LastRenewUnix: time.Now().Unix(),
		LastEpoch:     epoch,
	})
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
