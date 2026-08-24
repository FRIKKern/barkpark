package cli

// tasks_next_cmd.go — `bp task next <worker> --frontier`: a FRONTIER-AWARE
// atomic claim (cmux-bridge epic, df-next-frontier). Bare `bp task next <worker>`
// is untouched — it falls through to the manifest queue endpoint
// (POST /v1/tasks/claim), the server's single-pick FIFO. The --frontier mode is a
// client-side intercept that instead:
//
//  1. fetches the board snapshot (the same one `bp task frontier` reads),
//  2. computes taskboard.Frontier — the maximal non-colliding ready set,
//  3. claims the top pick BY ID through the existing epoch-CAS claim
//     (POST /v1/tasks/:id/claim, TaskClaimResources), DECLARING the pick's file
//     scope so the server's resource fence rejects a claim whose files another
//     worker already holds,
//  4. on a lost race (not_ready / already_claimed) or a file fence
//     (resource_conflict) it SKIPS to the next non-colliding pick, and across a
//     few bounded rounds refetches + recomputes the frontier against the fresh
//     claim set — never touching the queue endpoint, never inventing a second
//     lock. The claim ledger IS the lock.
//
// So N workers can each run `bp task next <w> --frontier` and each atomically
// win a DIFFERENT non-colliding task — the answer to "how many agents can run at
// once without colliding", claimed rather than guessed.

import (
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// frontierClaimRounds bounds the refetch+recompute loop: after this many rounds
// where every frontier pick was lost to a racing claimer, the caller reports an
// honest "frontier exhausted" instead of spinning forever.
const frontierClaimRounds = 5

// sortedFiles is the deterministic []string the claim body carries — sorted keys
// of a file-scope set (taskboard.FilesOf, the df-file-edge parser — the SAME
// normalization the frontier's interference model reads, so the claim's exact-
// string server fence can never drift from the frontier's overlap verdict), so
// the same task always declares the same resource list.
func sortedFiles(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for f := range set {
		out = append(out, f)
	}
	sort.Strings(out)
	return out
}

// frontierSkip is one recorded skip during the claim loop: a pick the worker
// could not win, and why — a lost race or a named file-holder collision.
type frontierSkip struct {
	ID     string `json:"id"`
	Reason string `json:"reason"`
	Holder string `json:"holder,omitempty"`
}

// runTaskNextFrontier handles `bp task next <worker> --frontier`. It is reached
// ONLY from the cli.go `task` intercept when --frontier is present; bare
// `bp task next` never lands here.
func runTaskNextFrontier(out *writer, g globals, ctx manifest.Context, worker string, opts taskboard.FrontierOpts) int {
	if strings.TrimSpace(worker) == "" {
		out.userErr("task next --frontier: a worker id is required (usage: bp task next <worker> --frontier)")
		return exitUsage
	}

	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts", // tasks live as drafts, exactly like `bp task frontier`
	})

	var skips []frontierSkip
	sawAnyReady := false

	for round := 0; round < frontierClaimRounds; round++ {
		snap, details, err := taskboard.FetchSnapshotFull(client)
		if err != nil {
			return fetchSnapshotErr(out, "task next --frontier", err)
		}
		now := time.Now().UTC()
		board := taskboard.BuildBoard(snap, taskboard.RepoContext{}, now)
		// Enrich with the real cross-root block edges (the frontier verb's guard),
		// so a genuine dependency never lets two picks dispatch in parallel.
		fopts := opts
		fopts.CrossEdges = fetchCrossEdges(client, snap)
		picks := taskboard.Frontier(snap, details, board.Now, now, fopts)
		if len(picks) > 0 {
			sawAnyReady = true
		}

		for _, p := range picks {
			resources := sortedFiles(taskboard.FilesOf(p.Task))
			outcome, err := client.TaskClaimResources(p.Task.DocID, worker, resources)
			if err != nil {
				// Transport failure OR a won claim with no fencing epoch (epoch<=0):
				// both are HARD failures — nothing was safely claimed.
				out.userErr("task next --frontier: %v", err)
				return exitGeneric
			}
			if outcome.OK {
				return emitFrontierClaim(out, p, worker, outcome.Epoch, skips, outcome.Help, outcome.Notices)
			}
			// A business rejection: record the skip and try the next non-colliding
			// pick. A lost race is `not_ready` (the queue moved the task out of
			// ready), NOT `already_claimed` — never treat it as task-gone.
			skips = append(skips, describeSkip(p, outcome))
		}
		// Every pick this round was lost — refetch + recompute against the fresh
		// claim set on the next round.
	}

	// Bounded rounds exhausted, or no ready tasks at all.
	return emitFrontierExhausted(out, sawAnyReady, skips)
}

// describeSkip turns a rejected claim outcome into a recorded skip, naming the
// file holder when the rejection was a resource_conflict.
func describeSkip(p taskboard.Pick, outcome apiclient.TaskClaimOutcome) frontierSkip {
	id := taskboard.BareID(p.Task.DocID)
	switch outcome.Reason {
	case "resource_conflict":
		holder := holderText(outcome.Conflicts)
		return frontierSkip{ID: id, Reason: "resource_conflict", Holder: holder}
	default:
		// not_ready / already_claimed / anything else the server named.
		return frontierSkip{ID: id, Reason: outcome.Reason}
	}
}

// holderText names who holds the contested files in a resource_conflict, e.g.
// "task-b (worker-2): internal/cli/cli.go". Empty when the server named none.
func holderText(conflicts []apiclient.TaskConflict) string {
	parts := make([]string, 0, len(conflicts))
	for _, c := range conflicts {
		// HolderID, never .Task: the server spells this key `doc_id`, so reading
		// .Task made every real skip render a LEADING BLANK where the holder's
		// row id belongs (apiclient.TaskConflict).
		who := taskboard.BareID(c.HolderID())
		if c.Worker != "" {
			who += " (" + c.Worker + ")"
		}
		if len(c.Resources) > 0 {
			who += ": " + strings.Join(c.Resources, ", ")
		}
		parts = append(parts, who)
	}
	return strings.Join(parts, "; ")
}

func emitFrontierClaim(out *writer, p taskboard.Pick, worker string, epoch int, skips []frontierSkip, help []string, notices []apiclient.TaskNotice) int {
	id := taskboard.BareID(p.Task.DocID)
	if out.machineOut() {
		claimed := map[string]any{"id": id, "title": p.Task.Title, "worker": worker, "epoch": epoch}
		payload := map[string]any{
			"ok":      true,
			"claimed": claimed,
			"skipped": skipsJSON(skips),
		}
		// The frontier claim BYPASSES runCommand (which builds its own JSON via
		// renderSuccess), so the server's help[]/notices — decoded on the outcome —
		// would vanish from the machine shape unless carried here explicitly. Add
		// them as fields (parity with renderSuccess echoing the raw body) only when
		// present, so the empty-case shape is unchanged; ALSO mirror to stderr below
		// so a piped agent gets the help: lines runCommand gives every other verb.
		if len(help) > 0 {
			payload["help"] = help
		}
		if len(notices) > 0 {
			payload["notices"] = notices
		}
		if out.output == "yaml" {
			out.renderYAML(payload)
		} else {
			out.renderJSON(payload)
		}
		emitTaskHelpLines(out, help)
		emitTaskNoticeLines(out, notices)
		return exitOK
	}
	// Human mode: name the losers first (so the reason we skipped past them is
	// visible), then the winning claim.
	for _, s := range skips {
		out.outf("↷ skipped %s (%s)%s", s.ID, s.Reason, holderSuffix(s))
	}
	out.outf("✓ claimed %s  worker=%s  epoch=%d", id, worker, epoch)
	out.outf("  %s", p.Task.Title)
	// Rail-awareness heads-up + the server's next-command templates go to stderr
	// (the emitNotices / emitHelpHints house pattern), so stdout stays the clean
	// receipt while the claimer still learns what to run next (charter D18).
	emitTaskNoticeLines(out, notices)
	emitTaskHelpLines(out, help)
	return exitOK
}

func emitFrontierExhausted(out *writer, sawAnyReady bool, skips []frontierSkip) int {
	reason := "frontier_exhausted"
	msg := "frontier exhausted — every non-colliding pick was claimed by a racing worker"
	if !sawAnyReady {
		reason = "no_ready"
		msg = "no ready tasks — nothing to dispatch"
	}
	if out.machineOut() {
		payload := map[string]any{
			"ok":      false,
			"reason":  reason,
			"skipped": skipsJSON(skips),
		}
		if out.output == "yaml" {
			out.renderYAML(payload)
		} else {
			out.renderJSON(payload)
		}
		return exitGeneric
	}
	for _, s := range skips {
		out.outf("↷ skipped %s (%s)%s", s.ID, s.Reason, holderSuffix(s))
	}
	out.userErr("task next --frontier: %s", msg)
	return exitGeneric
}

func holderSuffix(s frontierSkip) string {
	if s.Holder == "" {
		return ""
	}
	return " — held by " + s.Holder
}

// skipsJSON always returns a non-nil slice so the -o json shape carries an empty
// array, never null, when nothing was skipped.
func skipsJSON(skips []frontierSkip) []frontierSkip {
	if skips == nil {
		return []frontierSkip{}
	}
	return skips
}

// parseNextFrontierArgs splits `next` tail into the worker positional and the
// frontier flags. It strips the mode marker --frontier and the worker (the first
// bare, non-flag token), then hands the remaining flags to parseFrontierFlags so
// `--proven-only` / `--max N` work exactly as they do on `bp task frontier`.
func parseNextFrontierArgs(tail []string) (string, taskboard.FrontierOpts, error) {
	worker := ""
	var flags []string
	for i := 0; i < len(tail); i++ {
		a := tail[i]
		if a == "--frontier" {
			continue
		}
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
			// --max takes a following value; keep it attached to the flag stream.
			if a == "--max" && i+1 < len(tail) {
				flags = append(flags, tail[i+1])
				i++
			}
			continue
		}
		if worker == "" {
			worker = a
			continue
		}
		return "", taskboard.FrontierOpts{}, errFrontierExtraArg(a)
	}
	opts, err := parseFrontierFlags(flags)
	if err != nil {
		return "", taskboard.FrontierOpts{}, err
	}
	return worker, opts, nil
}

func errFrontierExtraArg(a string) error {
	return &frontierArgError{arg: a}
}

type frontierArgError struct{ arg string }

func (e *frontierArgError) Error() string {
	return "unexpected argument " + e.arg + " (usage: bp task next <worker> --frontier [--proven-only] [--max N])"
}

// printReadyFrontierHeader prepends the dispatch-capacity line to `bp task ready`
// (human/table mode). It runs the SAME taskboard.Frontier model the `frontier`
// verb reads, but with ZERO graph calls (charter D12): no CrossEdges enrichment,
// because the per-root GET /v1/graph/:root fan-out can cost ~10s/root live and
// the header must answer instantly — a capacity HEADLINE needs no cross-root
// graph precision. (The explicit verbs — `bp task frontier`, `bp task next
// --frontier` — keep the enrichment, bounded by fetchCrossEdges' pool +
// deadline.) Purely best-effort: any fetch/compute error drops the header
// silently and the ready list renders untouched.
func printReadyFrontierHeader(out *writer, ctx manifest.Context) {
	client := apiclient.New(apiclient.Config{
		BaseURL:     ctx.Server,
		Token:       ctx.Token,
		Workspace:   ctx.Workspace,
		Project:     ctx.Project,
		Dataset:     ctx.Dataset,
		Perspective: "drafts",
	})
	snap, details, err := taskboard.FetchSnapshotFull(client)
	if err != nil {
		return // best-effort: no header, never block the ready list
	}
	now := time.Now().UTC()
	board := taskboard.BuildBoard(snap, taskboard.RepoContext{}, now)
	full := taskboard.Frontier(snap, details, board.Now, now, taskboard.FrontierOpts{})
	proven, unproven := frontierTally(full)
	out.outf("FRONTIER · %d independent · %d proven · %d unproven", len(full), proven, unproven)
}
