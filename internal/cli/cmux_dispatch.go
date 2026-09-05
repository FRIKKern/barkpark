package cli

// cmux_dispatch.go — `bp cmux dispatch [--max N] [--proven-only] [--dry-run]`:
// turn the wave-13 dispatch frontier into launched cmux agent panes (task-TUI
// epic, wave 14, design §4). It reads the SHARED taskboard.Frontier model
// (IMPORTED, never a second interference model) and, per non-colliding pick,
// spawns a fresh cmux workspace running an agent with BARKPARK_TASK set. The new
// pane derives its OWN BARKPARK_WORKER_ID from its freshly-injected
// CMUX_SURFACE_ID (via the install shell-line), so its SessionStart hook claims
// the task — closing the loop. Worker id is NOT passed at dispatch: the surface
// does not exist until cmux creates the pane.
//
// Safety spine: --dry-run PRINTS the launch plan and spawns/mutates nothing, and
// is the DEFAULT when `cmux` is absent from $PATH (you cannot spawn what isn't
// installed). Only with cmux on PATH AND --dry-run off do we exec the spawns
// (.Start, never Wait — the panes live independently; a spawn failure on one
// pick logs to stderr and continues the batch).

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// cmuxLookPath and cmuxSpawn are seams the tests override so dispatch's
// PATH-detection and spawn behavior are asserted without a real cmux binary.
var (
	cmuxLookPath = func() (string, bool) {
		p, err := exec.LookPath("cmux")
		return p, err == nil
	}
	// cmuxSpawn launches ONE agent pane. It returns an error the caller logs;
	// the default execs `cmux new-workspace …` and Start()s it (never Wait).
	cmuxSpawn = defaultCmuxSpawn
)

func runCmuxDispatch(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		printCmuxDispatchHelp(out)
		return exitOK
	}

	claimFlag := hasFlag(args, "--claim")
	// --claim is a dispatch-local flag, not a frontier knob — strip it before the
	// frontier parser (which rejects unknowns) so --claim composes with --max /
	// --proven-only.
	fargs := stripFlag(args, "--claim")
	opts, err := parseFrontierFlags(fargs) // reuse `bp task frontier`'s --max/--proven-only parser
	if err != nil {
		return usageErrf(out, func() { printCmuxDispatchHelp(out) }, "%v", err)
	}
	dryRunFlag := g.dryRun || hasFlag(args, "--dry-run")

	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts", // tasks are drafts, exactly like the frontier verb
	})

	snap, details, err := taskboard.FetchSnapshotFull(client)
	if err != nil {
		return fetchSnapshotErr(out, "dispatch", err)
	}

	now := time.Now().UTC()
	board := taskboard.BuildBoard(snap, taskboard.RepoContext{}, now)
	// The ONE interference model — imported, never reimplemented (design §4).
	picks := taskboard.Frontier(snap, details, board.Now, now, opts)

	// Dry-run is forced when cmux is absent: you cannot spawn what isn't
	// installed, so we degrade to printing the plan and say so honestly.
	cmuxPath, cmuxPresent := cmuxLookPath()
	dryRun := dryRunFlag || !cmuxPresent

	cwd, _ := os.Getwd()

	// Header: the honest capacity + the mode we're about to run in.
	mode := "spawning"
	switch {
	case dryRunFlag:
		mode = "dry-run (--dry-run)"
	case !cmuxPresent:
		mode = "dry-run (cmux not on PATH)"
	}
	claimTag := ""
	if claimFlag {
		claimTag = " · claim-before-spawn"
	}
	out.outf("DISPATCH · %d pick(s) · %s%s", len(picks), mode, claimTag)
	if cmuxPresent {
		out.outf("cmux: %s", cmuxPath)
	}

	if len(picks) == 0 {
		out.outf("(no ready tasks — nothing to dispatch)")
		return exitOK
	}

	spawned, failed, skipped := 0, 0, 0
	for _, p := range picks {
		id := taskboard.BareID(p.Task.DocID)

		// --claim: win the ledger lease BEFORE spawning, so the pane never races
		// its own SessionStart claim against a sibling. A pick lost to another
		// worker (a lost race or a file-scope conflict) is NOT spawned — its holder
		// is named instead. Claiming is a mutation, so it is suppressed under
		// dry-run (which spawns nothing anyway).
		worker, epoch := "", 0
		if claimFlag && !dryRun {
			w := dispatchClaimWorkerID(id)
			resources := sortedFiles(taskboard.FilesOf(p.Task))
			// WRITE-FENCE EXEMPTION (builtinWriteCensus, dispCannotLie): the
			// claim receipt is the server's own ok:true + claim.epoch>0; see
			// runTaskNextFrontier for the same argument at length.
			outcome, err := client.TaskClaimResources(p.Task.DocID, w, resources)
			if err != nil {
				// Transport failure or a won claim with no fencing epoch — hard, but
				// one bad pick never aborts the batch (design §7).
				out.userErr("dispatch: claim %s failed: %v", id, err)
				failed++
				continue
			}
			if !outcome.OK {
				out.outf("↷ skipped %s (%s)%s", id, outcome.Reason, claimHolderSuffix(outcome.Conflicts))
				skipped++
				continue
			}
			worker, epoch = w, outcome.Epoch
			// Dispatch --claim bypasses runCommand, so the server's help[] next-command
			// templates and rail-awareness notices — decoded on the outcome — would be
			// dropped without this. Surface them to stderr (the house pattern), one
			// line each, so the lead sees a blocker on the freshly-claimed task and the
			// next-step commands the pane will run (charter D18).
			emitTaskNoticeLines(out, outcome.Notices)
			emitTaskHelpLines(out, outcome.Help)
		}

		cmd := cmuxCommandText(id, taskPrompt(p))
		if claimFlag {
			// Export the observed lease (worker + epoch) into the pane so its
			// SessionStart hook RENEWS the same lease instead of re-claiming.
			cmd = cmuxCommandTextClaimed(id, worker, epoch, taskPrompt(p))
		}
		plan := cmuxInvocation(id, cwd, cmd)

		if dryRun {
			out.outf("%s", plan)
			continue
		}
		if err := cmuxSpawn(id, cwd, cmd); err != nil {
			// One bad surface never aborts the batch (design §7).
			out.userErr("dispatch: spawn %s failed: %v", id, err)
			failed++
			continue
		}
		if claimFlag {
			out.outf("↑ spawned %s  worker=%s  epoch=%d", id, worker, epoch)
		} else {
			out.outf("↑ spawned %s", id)
		}
		spawned++
	}

	if !dryRun {
		out.outf("dispatched %d pane(s)%s%s", spawned, failedSuffix(failed), skippedSuffix(skipped))
	}
	return exitOK
}

// dispatchClaimWorkerID is the worker id the lead claims a pick under when
// pre-claiming for a pane (--claim). It lives in the cmux- namespace and is
// exported into the pane as BARKPARK_WORKER_ID (tier-1 of CmuxWorkerID), so the
// pane's SessionStart re-claim RENEWS this exact lease rather than colliding.
func dispatchClaimWorkerID(bareID string) string {
	return taskboard.CmuxWorkerPrefix + "dispatch-" + bareID
}

// claimHolderSuffix names who holds the contested files of a skipped pick.
func claimHolderSuffix(conflicts []apiclient.TaskConflict) string {
	h := holderText(conflicts)
	if h == "" {
		return ""
	}
	return " — held by " + h
}

func skippedSuffix(skipped int) string {
	if skipped == 0 {
		return ""
	}
	return " · " + strconv.Itoa(skipped) + " skipped"
}

func failedSuffix(failed int) string {
	if failed == 0 {
		return ""
	}
	return " · " + strconv.Itoa(failed) + " failed"
}

// taskPrompt is the minimal launch prompt (design §4). The agent gets the task
// in env (BARKPARK_TASK) and its worker id from its own surface, so the prompt
// only has to point it at the work and name the auto-close contract. One line so
// it survives being typed into the new pane's shell as a `--command`.
func taskPrompt(p taskboard.Pick) string {
	area := "unset"
	if len(p.Areas) > 0 {
		area = strings.Join(p.Areas, ",")
	}
	id := taskboard.BareID(p.Task.DocID)
	title := strings.ReplaceAll(p.Task.Title, "\n", " ")
	// Apostrophe-free by design so the single-quoted --command in the dry-run
	// plan stays readable (a nested single-quote escapes to an unreadable run).
	return "You own Barkpark task " + id + ": \"" + title + "\". " +
		"Run `bp task show " + id + "` for the brief and acceptance criteria; do the work, " +
		"and mark each acceptance criterion met via `bp task` as you satisfy it. " +
		"When every criterion is met, the pane Stop hook closes the task automatically; " +
		"if you stop with criteria unmet it lease-expires into a resume. " +
		"Stay within this task surface (area: " + area + ")."
}

// cmuxCommandText is the shell line typed into the spawned pane: BARKPARK_TASK
// set inline (the pane derives BARKPARK_WORKER_ID from its own surface id via the
// install shell-line) then `claude '<prompt>'`. The prompt is single-quoted with
// embedded single-quotes escaped so it survives the shell verbatim.
func cmuxCommandText(bareID, prompt string) string {
	return "BARKPARK_TASK=" + bareID + " claude " + shellSingleQuote(prompt)
}

// cmuxCommandTextClaimed is cmuxCommandText for a PRE-CLAIMED pick (--claim): it
// additionally exports the observed lease — BARKPARK_WORKER_ID (tier-1 of
// CmuxWorkerID, so the pane renews rather than re-claims) and BARKPARK_TASK_EPOCH
// (the fencing token the close hook echoes back as observed_epoch). Under
// dry-run the pick was not claimed, so worker is "" / epoch is 0 and only
// BARKPARK_TASK is exported (the plan honestly shows no lease yet).
func cmuxCommandTextClaimed(bareID, worker string, epoch int, prompt string) string {
	if worker == "" {
		return cmuxCommandText(bareID, prompt)
	}
	return "BARKPARK_WORKER_ID=" + worker +
		" BARKPARK_TASK_EPOCH=" + strconv.Itoa(epoch) +
		" BARKPARK_TASK=" + bareID + " claude " + shellSingleQuote(prompt)
}

// cmuxInvocation is the copy-pasteable dry-run line: the exact `cmux
// new-workspace …` the spawn WOULD run. new-workspace is cmux's real spawn
// primitive with a command+cwd (confirmed against `cmux new-workspace --help`);
// --command types text+Enter into the fresh pane's shell.
func cmuxInvocation(bareID, cwd, cmd string) string {
	return "cmux new-workspace --name " + shellSingleQuote(bareID) +
		" --cwd " + shellSingleQuote(cwd) +
		" --command " + shellSingleQuote(cmd)
}

func defaultCmuxSpawn(bareID, cwd, cmd string) error {
	c := exec.Command("cmux", "new-workspace", "--name", bareID, "--cwd", cwd, "--command", cmd)
	return c.Start() // Start, never Wait — dispatch returns immediately; panes live on
}

// shellSingleQuote wraps s in single quotes with embedded ' rendered as the
// standard '\” escape, so the result is one safe shell token.
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func printCmuxDispatchHelp(out *writer) {
	out.outf("usage: bp cmux dispatch [--max N] [--proven-only] [--dry-run]")
	out.outf("")
	out.outf("Spawn the dispatch frontier into fresh cmux agent panes: read the shared")
	out.outf("`bp task frontier` model (the maximal non-colliding ready set) and, per pick,")
	out.outf("launch a cmux workspace running an agent with BARKPARK_TASK set. The new pane")
	out.outf("derives its own BARKPARK_WORKER_ID from its surface id, so its SessionStart")
	out.outf("hook claims the task.")
	out.outf("")
	out.outf("flags:")
	out.outf("  --max N         cap the number of panes spawned (0 / omitted = full frontier)")
	out.outf("  --proven-only   spawn only the area-proven isolated set (the safe floor)")
	out.outf("  --claim         claim each pick (declaring its file scope) BEFORE spawning;")
	out.outf("                  spawn only the winners with the lease (worker+epoch) in env,")
	out.outf("                  and name the holder of any pick lost to a racing worker")
	out.outf("  --dry-run       print the launch plan and spawn nothing (mutates nothing)")
	out.outf("")
	out.outf("--dry-run is the DEFAULT when cmux is not on $PATH. Panes are Start()ed, never")
	out.outf("waited on; a spawn failure on one pick continues the batch.")
	out.outf("")
	out.outf("See also: `bp task frontier` (the capacity), `bp cmux install` (the hooks).")
}
