package cli

import (
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// runTasksBoard is the builtin `bp tasks` — the portrait, live, glanceable task
// pane (internal/taskboard). It is a built-in (not a manifest verb) because it
// is a full-screen interactive Bubble Tea program, not the single JSON body the
// generic command path decodes.
//
// NB: `bp tasks` (this interactive pane) is a DIFFERENT thing from `bp task …`
// (the manifest-driven singular noun that lists/claims/closes tasks as JSON).
// The help below cross-references both so neither is a dead end.
func runTasksBoard(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		printTasksBoardHelp(out)
		return exitOK
	}
	// The board takes no positionals or flags of its own; reject stray args so a
	// typo (`bp tasks ready`, meaning `bp task ready`) fails loudly with the
	// cross-reference instead of silently ignoring the word.
	if len(args) > 0 {
		return usageErrf(out, func() { printTasksBoardHelp(out) },
			"bp tasks takes no arguments (got %q) — did you mean `bp task %s`?", args[0], args[0])
	}

	// A full-screen alt-screen TUI needs a real terminal. Without one (piped,
	// redirected, CI) fail cleanly and point at the scriptable sibling instead
	// of scribbling escape codes into a file.
	if !out.isTTY {
		out.errf("bp tasks needs a terminal — run it in an interactive shell.")
		out.errf("For scripting, use the manifest-driven `bp task …` verbs (e.g. `bp task ready -o json`).")
		return exitGeneric
	}

	cfg := taskboard.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
	}
	// The first-paint snapshot cache lives in the bp config dir
	// (${XDG_CONFIG_HOME:-~/.config}/barkpark) — reuse the exact resolution the
	// rest of bp uses rather than hardcoding a path. A resolve failure just
	// leaves CacheDir empty, which disables the cache (honest cold start) instead
	// of erroring the whole board.
	if dir, err := configDir(); err == nil {
		cfg.CacheDir = dir
	}
	if err := taskboard.Run(cfg); err != nil {
		out.errf("bp tasks: %v", err)
		return exitGeneric
	}
	return exitOK
}

// printTasksBoardHelp prints the short help block for `bp tasks`, cross-
// referencing the manifest-driven `bp task …` verbs in both directions.
func printTasksBoardHelp(out *writer) {
	out.outf("usage: bp tasks")
	out.outf("")
	out.outf("Open the live portrait task board: a tall, glanceable pane organized by")
	out.outf("epics with active work pinned on top, latest movement first, auto-connected")
	out.outf("to the server this repo resolves to. It refreshes itself live.")
	out.outf("")
	out.outf("enter descends — a task opens its full detail; from there its linked paper,")
	out.outf("the paper's tasks, a child task, its children… esc/backspace ascends, and a")
	out.outf("breadcrumb always shows where you are. Wide terminals show a two-pane")
	out.outf("board+reader; narrow ones push full-frame. One view, no toggles.")
	out.outf("")
	out.outf("keys:")
	out.outf("  j / k, ↓ / ↑   move the cursor")
	out.outf("  g / G          jump to top / bottom")
	out.outf("  enter          descend — open the task / paper / child under the cursor")
	out.outf("  esc, backspace go back up one level")
	out.outf("  h / l          fold / unfold the epic under the cursor (on the board)")
	out.outf("  c              claim the ready task under the cursor")
	out.outf("  x              close a claimed task (press x again to confirm)")
	out.outf("  o              open the task in Studio (the URL is shown too)")
	out.outf("  q, ctrl-c      quit")
	out.outf("")
	out.outf("`bp tasks` (this pane) is separate from `bp task …` — the scriptable verbs")
	out.outf("that list, claim, and close tasks as JSON (see `bp task -h`).")
}
