package cli

// cmux_cmd.go — `bp cmux <verb>`: the CMUX × Barkpark bridge builtin (task-TUI
// epic, wave 14). A CLIENT-SIDE builtin intercepted in cli.go before manifest
// dispatch, exactly like `bp tasks` / `bp task frontier` — the `cmux` noun is
// not in the capabilities manifest, so this intercept shadows nothing and no
// server/API change is needed. runCmux switches on the sub-verb:
//
//	bp cmux hook <event> [--dry-run]                   → cmux_hook.go (the adapter)
//	bp cmux dispatch [--max N] [--proven-only] [--dry-run] → cmux_dispatch.go
//	bp cmux install [--print]                          → the hooks block + shell line
//	bp cmux status [-o json]                            → this pane's worker/task/lease
//
// The wish: a cmux pane that IS a Barkpark worker — claim its task on
// SessionStart, renew the lease while working, close on proven acceptance, and
// `bp cmux dispatch` turns the frontier into launched panes.

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// runCmux dispatches `bp cmux <verb> …`. args is everything after the `cmux`
// noun (args[0] = the sub-verb). The hook path is the ONLY one bound by the
// cardinal fail-safe contract (it never returns non-zero); the others are
// ordinary read/print commands.
func runCmux(out *writer, g globals, ctx manifest.Context, args []string) int {
	verb := ""
	if len(args) > 0 {
		verb = args[0]
	}
	rest := args
	if len(args) > 0 {
		rest = args[1:]
	}

	switch verb {
	case "hook":
		// The Claude Code hook adapter. ALWAYS exits 0 — a hook must never break
		// the agent (design §7). rest[0] is the event name.
		return runCmuxHook(out, g, ctx, rest)
	case "dispatch":
		return runCmuxDispatch(out, g, ctx, rest)
	case "install":
		return runCmuxInstall(out, g, rest)
	case "status":
		return runCmuxStatus(out, g, ctx, rest)
	case "", "-h", "--help":
		printCmuxHelp(out)
		if verb == "" {
			return exitUsage
		}
		return exitOK
	default:
		if g.help {
			printCmuxHelp(out)
			return exitOK
		}
		out.userErr("unknown cmux verb %q", verb)
		printCmuxHelp(out)
		return exitUsage
	}
}

// runCmuxStatus prints this pane's identity and its owned task's live lease
// (design §6). Read-only; never mutates. Honest degradation lines when the pane
// is outside cmux, owns no task, or the server is unreachable.
func runCmuxStatus(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		printCmuxStatusHelp(out)
		return exitOK
	}

	worker := taskboard.CmuxWorkerID()
	surface := os.Getenv("CMUX_SURFACE_ID")
	task := os.Getenv("BARKPARK_TASK")

	st := cmuxStatus{
		Worker:    worker,
		Surface:   surface,
		Workspace: os.Getenv("CMUX_WORKSPACE_ID"),
		Tab:       os.Getenv("CMUX_TAB_ID"),
		Panel:     os.Getenv("CMUX_PANEL_ID"),
		Task:      task,
		InCmux:    surface != "",
	}

	// A dead bridge leaves a last-error breadcrumb; surface it (silent when none).
	// Read on worker alone so a claim that never landed (task set, claim failed)
	// still shows its error.
	if bc, ok := readHookBreadcrumb(worker); ok {
		st.HasLastError = true
		st.LastErrorEvent = bc.Event
		st.LastErrorMsg = bc.Error
		st.LastErrorTask = bc.Task
		st.LastErrorUnix = bc.Unix
	}

	// The lease block is read from the live task doc when this pane owns one.
	// GetPerspectiveResult disambiguates a genuine 404 (task typo / wrong id)
	// from an unreachable server — collapsing both would misdiagnose the bridge.
	if task != "" {
		client := apiclient.New(apiclient.Config{
			BaseURL:     ctx.Server,
			Token:       ctx.Token,
			Workspace:   ctx.Workspace,
			Project:     ctx.Project,
			Dataset:     ctx.Dataset,
			Perspective: "drafts",
			Timeout:     4 * time.Second,
		})
		doc, outcome := client.GetPerspectiveResult("task", task, "drafts")
		switch outcome {
		case apiclient.DocReadOK:
			st.hydrateLease(doc)
		case apiclient.DocReadNotFound:
			st.TaskNotFound = true
		default:
			st.ServerUnreachable = true
		}
	}

	if out.machineOut() {
		return emitCmuxStatusJSON(out, st)
	}
	return renderCmuxStatus(out, st)
}

// cmuxStatus is the resolved status view.
type cmuxStatus struct {
	Worker            string
	Surface           string
	Workspace         string
	Tab               string
	Panel             string
	Task              string
	InCmux            bool
	ServerUnreachable bool
	TaskNotFound      bool // 404 on the task read — disambiguated from unreachable

	// Lease block (populated from the task doc when readable).
	HasClaim     bool
	ClaimWorker  string
	ClaimEpoch   int
	Lifecycle    string
	ClaimedAtISO string
	ExpiresISO   string

	// Last swallowed-hook-failure breadcrumb (gated by HasLastError).
	HasLastError   bool
	LastErrorEvent string
	LastErrorMsg   string
	LastErrorTask  string
	LastErrorUnix  int64
}

// hydrateLease reads the claim + lifecycle off the task envelope's flattened
// top-level fields (content.claim / lifecycle_status).
func (st *cmuxStatus) hydrateLease(doc apiclient.Doc) {
	st.Lifecycle = doc.ContentString("lifecycle_status")
	if epoch, ok := doc.ClaimEpoch(); ok {
		st.HasClaim = true
		st.ClaimEpoch = epoch
	}
	if raw, ok := doc.Extra["claim"]; ok {
		var c struct {
			Worker    string `json:"worker"`
			TsISO     string `json:"ts_iso"`
			ExpiredAt string `json:"expired_at"`
		}
		if json.Unmarshal(raw, &c) == nil {
			st.ClaimWorker = c.Worker
			st.ClaimedAtISO = c.TsISO
			st.ExpiresISO = c.ExpiredAt
		}
	}
}

func renderCmuxStatus(out *writer, st cmuxStatus) int {
	out.outf("%-10s%s", "worker", st.Worker)
	if !st.InCmux {
		out.outf("%-10s%s", "surface", "(not in a cmux pane — CMUX_SURFACE_ID unset)")
	} else {
		out.outf("%-10s%s   workspace %s · tab %s · panel %s",
			"surface", st.Surface, dashIfEmpty(st.Workspace), dashIfEmpty(st.Tab), dashIfEmpty(st.Panel))
	}
	if st.Task == "" {
		out.outf("%-10s%s", "task", "(this pane owns no task — BARKPARK_TASK unset)")
		renderLastError(out, st)
		return exitOK
	}
	out.outf("%-10s%s", "task", st.Task)
	switch {
	case st.ServerUnreachable:
		out.outf("%-10s%s", "claim", "(server unreachable — cannot read lease)")
	case st.TaskNotFound:
		out.outf("%-10s%s", "claim", "(task not found — no document with this id)")
	case st.HasClaim:
		out.outf("%-10s%s", "claim", st.claimHealth())
	default:
		out.outf("%-10s%s", "claim", "(no live claim on this task)")
	}
	if st.Lifecycle != "" {
		out.outf("%-10s%s", "lifecycle", st.Lifecycle)
	}
	renderLastError(out, st)
	return exitOK
}

// renderLastError prints the last swallowed-hook-failure breadcrumb, silent when
// none exists — the one line that makes a dead bridge diagnosable.
func renderLastError(out *writer, st cmuxStatus) {
	if !st.HasLastError {
		return
	}
	suffix := ""
	if st.LastErrorUnix > 0 {
		suffix = " (" + humanAgo(st.LastErrorUnix) + " ago)"
	}
	event := st.LastErrorEvent
	if event == "" {
		event = "hook"
	}
	out.outf("%-10s%s: %s%s", "last-err", event, st.LastErrorMsg, suffix)
}

// claimHealth renders the live-lease line from claim.ts_iso + the configured
// lease TTL. Remaining is APPROXIMATE — the client sees neither the server clock
// nor its exact TTL config, only the documented default (2700s) or the
// BARKPARK_TASK_LEASE_TTL_SECONDS override — so it is marked with ~ and "approx".
// The old expired_at-keyed countdown is gone: the sweeper writes expired_at ONLY
// when it reaps a dead lease, so a live claim never carried one to count down.
func (st cmuxStatus) claimHealth() string {
	base := fmt.Sprintf("held by %s · epoch %d", dashIfEmpty(st.ClaimWorker), st.ClaimEpoch)
	age, ok := ageSince(st.ClaimedAtISO)
	if !ok {
		return base + " · claimed —"
	}
	ttl := time.Duration(leaseTTLSeconds()) * time.Second
	remain := (ttl - age).Round(time.Second)
	if remain > 0 {
		return fmt.Sprintf("%s · claimed %s ago · ~%s left (approx · ttl %s)",
			base, age.Round(time.Second), remain, ttl)
	}
	return fmt.Sprintf("%s · claimed %s ago · lease likely expired (past ~%s ttl)",
		base, age.Round(time.Second), ttl)
}

func emitCmuxStatusJSON(out *writer, st cmuxStatus) int {
	ttl := leaseTTLSeconds()
	payload := map[string]any{
		"ok":                 true,
		"worker":             st.Worker,
		"in_cmux":            st.InCmux,
		"surface":            st.Surface,
		"workspace":          st.Workspace,
		"tab":                st.Tab,
		"panel":              st.Panel,
		"task":               st.Task,
		"server_unreachable": st.ServerUnreachable,
		"task_not_found":     st.TaskNotFound,
		"has_claim":          st.HasClaim,
		"claim_worker":       st.ClaimWorker,
		"claim_epoch":        st.ClaimEpoch,
		"claimed_at":         st.ClaimedAtISO,
		"expires_at":         st.ExpiresISO,
		"lifecycle":          st.Lifecycle,
		"lease_ttl_seconds":  ttl,
	}
	// Honest lease health from ts_iso + the TTL default (approximate; see
	// claimHealth). Emitted only when the claim timestamp is parseable.
	if age, ok := ageSince(st.ClaimedAtISO); ok {
		payload["claimed_age_seconds"] = int(age.Seconds())
		payload["approx_remaining_seconds"] = ttl - int(age.Seconds())
	}
	if st.HasLastError {
		le := map[string]any{
			"event": st.LastErrorEvent,
			"error": st.LastErrorMsg,
			"task":  st.LastErrorTask,
			"unix":  st.LastErrorUnix,
		}
		if st.LastErrorUnix > 0 {
			le["age_seconds"] = int(time.Since(time.Unix(st.LastErrorUnix, 0)).Seconds())
		}
		payload["last_error"] = le
	}
	if out.output == "yaml" {
		out.renderYAML(payload)
	} else {
		out.renderJSON(payload)
	}
	return exitOK
}

// leaseTTLSeconds is the server lease TTL the client assumes for the approximate
// remaining-lease display: the BARKPARK_TASK_LEASE_TTL_SECONDS override when set
// to a positive integer, else the documented server default of 2700s
// (config.exs :task_lease_ttl_seconds; TtlSweeper @default_ttl_seconds).
func leaseTTLSeconds() int {
	if v := strings.TrimSpace(os.Getenv("BARKPARK_TASK_LEASE_TTL_SECONDS")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 2700
}

// ageSince returns the elapsed time since an RFC3339 timestamp (clamped at 0 for
// a future stamp), false when empty or unparseable.
func ageSince(iso string) (time.Duration, bool) {
	if iso == "" {
		return 0, false
	}
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return 0, false
	}
	d := time.Since(t)
	if d < 0 {
		d = 0
	}
	return d, true
}

// humanAgo renders the age of a unix timestamp as "2m41s" (clamped at 0).
func humanAgo(unix int64) string {
	d := time.Since(time.Unix(unix, 0))
	if d < 0 {
		d = 0
	}
	return d.Round(time.Second).String()
}

func dashIfEmpty(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return s
}

func printCmuxHelp(out *writer) {
	out.outf("usage: bp cmux <hook|dispatch|install|status> …")
	out.outf("")
	out.outf("The CMUX × Barkpark bridge: a cmux pane that IS a Barkpark worker. Its")
	out.outf("Claude Code hooks claim the pane's task on SessionStart, renew the lease")
	out.outf("while working, and close it on proven acceptance; `bp cmux dispatch` turns")
	out.outf("the dispatch frontier into launched agent panes.")
	out.outf("")
	out.outf("verbs:")
	out.outf("  hook <event>   the Claude Code hook adapter (SessionStart/PreToolUse/Stop/")
	out.outf("                 SessionEnd) — always exits 0, never breaks the agent")
	out.outf("  dispatch       spawn the frontier into fresh cmux agent panes")
	out.outf("  install        print the settings.json hook block + worker-id shell line")
	out.outf("  status         this pane's worker id, owned task, and lease state")
	out.outf("")
	out.outf("Worker id is `%s` (pane-stable), overridable by BARKPARK_WORKER_ID.", taskboard.CmuxSurfaceExport)
	out.outf("BARKPARK_TASK names the task a pane owns. Run `bp cmux install` to wire it up.")
}

func printCmuxStatusHelp(out *writer) {
	out.outf("usage: bp cmux status [-o json|yaml]")
	out.outf("")
	out.outf("Print this pane's cmux worker id, its owned task (BARKPARK_TASK), and that")
	out.outf("task's live claim/lease state. Read-only — never mutates. Degrades honestly")
	out.outf("outside a cmux pane, with no task, or when the server is unreachable.")
}
