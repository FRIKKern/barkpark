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
	"os"
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

	// The lease block is read from the live task doc when this pane owns one.
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
		doc, ok := client.GetPerspective("task", task, "drafts")
		if !ok {
			st.ServerUnreachable = true
		} else {
			st.hydrateLease(doc)
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

	// Lease block (populated from the task doc when readable).
	HasClaim     bool
	ClaimWorker  string
	ClaimEpoch   int
	Lifecycle    string
	ClaimedAtISO string
	ExpiresISO   string
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
		return exitOK
	}
	out.outf("%-10s%s", "task", st.Task)
	switch {
	case st.ServerUnreachable:
		out.outf("%-10s%s", "claim", "(server unreachable — cannot read lease)")
	case st.HasClaim:
		expires := dashIfEmpty(st.ExpiresISO)
		if left, ok := timeLeft(st.ExpiresISO); ok {
			expires = st.ExpiresISO + " (" + left + " left)"
		}
		out.outf("%-10sheld by %s · epoch %d · claimed %s · expires %s",
			"claim", dashIfEmpty(st.ClaimWorker), st.ClaimEpoch, dashIfEmpty(st.ClaimedAtISO), expires)
	default:
		out.outf("%-10s%s", "claim", "(no live claim on this task)")
	}
	if st.Lifecycle != "" {
		out.outf("%-10s%s", "lifecycle", st.Lifecycle)
	}
	return exitOK
}

func emitCmuxStatusJSON(out *writer, st cmuxStatus) int {
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
		"has_claim":          st.HasClaim,
		"claim_worker":       st.ClaimWorker,
		"claim_epoch":        st.ClaimEpoch,
		"claimed_at":         st.ClaimedAtISO,
		"expires_at":         st.ExpiresISO,
		"lifecycle":          st.Lifecycle,
	}
	if out.output == "yaml" {
		out.renderYAML(payload)
	} else {
		out.renderJSON(payload)
	}
	return exitOK
}

// timeLeft renders the human "2m41s" remaining until an RFC3339 expiry, false
// when the timestamp is empty/unparseable or already past.
func timeLeft(expiresISO string) (string, bool) {
	if expiresISO == "" {
		return "", false
	}
	t, err := time.Parse(time.RFC3339, expiresISO)
	if err != nil {
		return "", false
	}
	d := time.Until(t)
	if d <= 0 {
		return "", false
	}
	return d.Round(time.Second).String(), true
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
	out.outf("Worker id is `cmux-$CMUX_SURFACE_ID` (pane-stable), overridable by")
	out.outf("BARKPARK_TASK names the task a pane owns. Run `bp cmux install` to wire it up.")
}

func printCmuxStatusHelp(out *writer) {
	out.outf("usage: bp cmux status [-o json|yaml]")
	out.outf("")
	out.outf("Print this pane's cmux worker id, its owned task (BARKPARK_TASK), and that")
	out.outf("task's live claim/lease state. Read-only — never mutates. Degrades honestly")
	out.outf("outside a cmux pane, with no task, or when the server is unreachable.")
}
