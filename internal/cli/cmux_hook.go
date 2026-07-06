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
//	                  claimed so the 300s lease expires → task.lease_expired →
//	                  a `↩ resume` in the NEXT strip (already built)
//	other/unknown → no-op
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
	"io"
	"os"
	"path/filepath"
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
// well inside the 300s lease TTL, so a busy agent renews cheaply but not on
// every tool call.
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
	// panic (nil map, bad decode, anything) resolves to a clean exit 0.
	defer func() {
		if r := recover(); r != nil {
			code = exitOK
		}
	}()

	event := ""
	if len(args) > 0 {
		event = args[0]
	}
	dryRun := g.dryRun || hasFlag(args, "--dry-run")
	debug := dryRun || os.Getenv("BP_CMUX_DEBUG") != ""

	dbg := func(format string, a ...any) {
		if debug {
			out.errf("cmux hook %s: "+format, append([]any{event}, a...)...)
		}
	}

	// Drain stdin best-effort (Claude writes the hook JSON there). We key on env,
	// not stdin, so a malformed/empty body is harmless — decode and move on.
	_ = drainHookStdin()

	task := os.Getenv("BARKPARK_TASK")
	if task == "" {
		dbg("no BARKPARK_TASK — this pane owns no task; no-op")
		return exitOK
	}
	worker := taskboard.CmuxWorkerID()

	switch event {
	case "SessionStart":
		hookSessionStart(newHookClient(ctx), task, worker, dryRun, dbg)
	case "PreToolUse":
		hookPreToolUse(newHookClient(ctx), task, worker, dryRun, dbg)
	case "Stop", "SessionEnd":
		hookStopClose(newHookClient(ctx), task, worker, dryRun, dbg)
	default:
		dbg("unhandled event — no-op (cmux's own hook may still act)")
	}
	return exitOK
}

// hookSessionStart claims the pane's task as the derived worker. A re-claim under
// the same worker id renews the lease (new epoch) and is idempotent across
// subagents, so a fresh subagent SessionStart just renews rather than 409ing.
func hookSessionStart(c *apiclient.Client, task, worker string, dryRun bool, dbg func(string, ...any)) {
	if dryRun {
		dbg("would claim %s as %s", task, worker)
		return
	}
	res := taskboard.DoClaim(c, task, worker)
	dbg("%s", res.Message)
	if res.OK {
		// Seed the throttle so the first tool call doesn't immediately re-claim.
		writeRenewStamp(worker, task)
	}
}

// hookPreToolUse renews the lease (re-claim), throttled to ≤1/renewEvery via an
// on-disk stamp. A missing/corrupt stamp fails OPEN (renew now) — renewing more
// often than needed is always safe; the only cost of a missed renew is an
// honest resume, never a hang.
func hookPreToolUse(c *apiclient.Client, task, worker string, dryRun bool, dbg func(string, ...any)) {
	if !renewDue(worker, task) {
		dbg("within throttle window — skip renew")
		return
	}
	if dryRun {
		dbg("would renew (re-claim) %s as %s", task, worker)
		return
	}
	res := taskboard.DoClaim(c, task, worker)
	dbg("renew: %s", res.Message)
	if res.OK {
		writeRenewStamp(worker, task)
	}
}

// hookStopClose is the acceptance-gated close (design §2a). Stop fires at the end
// of EVERY turn, not "the task is done", so we close ONLY on proven acceptance:
// the task carries ≥1 acceptance criterion and every one is met. Anything else
// (unmet, no criteria at all, or unreadable) leaves the claim to lease-expire
// into a resume. To close, re-claim first to observe the LIVE epoch (design §2b:
// no persisted epoch across the separate SessionStart/Stop processes) — a
// re-claim that 409s means someone else holds the lease, so we don't close (no
// theft).
func hookStopClose(c *apiclient.Client, task, worker string, dryRun bool, dbg func(string, ...any)) {
	doc, ok := c.GetPerspective("task", task, "drafts")
	if !ok {
		dbg("task unreadable — can't prove acceptance; leaving claimed → resume")
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
	epoch, _, err := c.TaskClaimN(task, worker)
	if err != nil {
		dbg("re-claim for epoch failed (%v) — not closing (no theft)", err)
		return
	}
	res := taskboard.DoClose(c, task, worker, epoch)
	dbg("close: %s", res.Message)
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
