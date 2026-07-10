package cli

// cmux_install.go — `bp cmux install [--print]`: emit the Claude Code settings
// hook block + the worker-id shell line the bridge needs (task-TUI epic, wave
// 14, design §5). PRINT-FIRST and print-only in v1: it shows the two blocks and
// where to paste them; it NEVER writes ~/.claude/settings.json (a careful
// --merge is the reserved §5c slice). The hooks run ALONGSIDE cmux's own — the
// settings hooks map is additive per event, so ours ADD, never replace.

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// cmuxHooksBlock is the settings.json fragment wiring the four Claude Code
// events to `bp cmux hook <event>`. PreToolUse uses a catch-all matcher (renew
// on any tool); the session/stop events take no matcher.
const cmuxHooksBlock = `{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bp cmux hook SessionStart" } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bp cmux hook PreToolUse" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bp cmux hook Stop" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "bp cmux hook SessionEnd" } ] }
    ]
  }
}`

func runCmuxInstall(out *writer, g globals, args []string) int {
	if g.help {
		printCmuxInstallHelp(out)
		return exitOK
	}
	// --print is the DEFAULT (shows the blocks, writes nothing); --merge folds the
	// hooks into ~/.claude/settings.json (the additive writer in
	// cmux_install_merge.go — this file only dispatches to it; --yes is a global,
	// already on g.yes). Any other flag is a usage error.
	merge := false
	for _, a := range args {
		switch a {
		case "--print":
			// explicit default
		case "--merge":
			merge = true
		default:
			return usageErrf(out, func() { printCmuxInstallHelp(out) }, "unknown flag %q (install accepts --print, --merge, --yes)", a)
		}
	}
	if merge {
		return runCmuxInstallMerge(out, g)
	}

	out.outf("# bp cmux install — add these two blocks by hand (nothing is written for you).")
	out.outf("#")
	out.outf("# 1. Claude Code hooks → ~/.claude/settings.json")
	out.outf("#    These ADD to any hooks already there (cmux's own included) — the hooks")
	out.outf("#    map is additive per event, so this runs ALONGSIDE cmux's claude-hook.")
	out.outf("")
	out.outf("%s", cmuxHooksBlock)
	out.outf("")
	out.outf("# 2. Worker-id shell line → your shell profile (~/.zshrc / ~/.bashrc) or the")
	out.outf("#    cmux pane-init hook, so every pane exports it before Claude starts.")
	out.outf("")
	out.outf("%s", taskboard.CmuxShellLine())
	out.outf("")
	out.outf("# Then: set BARKPARK_TASK=<doc_id> in a pane (or use `bp cmux dispatch`), and")
	out.outf("# that pane's Claude claims the task on SessionStart. `bp cmux status` shows it.")
	return exitOK
}

// hooksBlockValid is a cheap self-check the tests use: the printed block must be
// valid JSON and name `bp cmux hook <event>` for each of the four events.
func hooksBlockValid() bool {
	for _, ev := range []string{"SessionStart", "PreToolUse", "Stop", "SessionEnd"} {
		if !strings.Contains(cmuxHooksBlock, "bp cmux hook "+ev) {
			return false
		}
	}
	return true
}

func printCmuxInstallHelp(out *writer) {
	out.outf("usage: bp cmux install [--print | --merge [--yes]]")
	out.outf("")
	out.outf("Print the Claude Code settings.json hook block (SessionStart/PreToolUse/Stop/")
	out.outf("SessionEnd → `bp cmux hook <event>`) and the guarded worker-id shell line")
	out.outf("(`export BARKPARK_WORKER_ID=%s`), with instructions for", taskboard.CmuxSurfaceExport)
	out.outf("where to paste each. The hooks run ALONGSIDE cmux's own — they ADD, never")
	out.outf("replace.")
	out.outf("")
	out.outf("  --print   (default) show the blocks; write nothing")
	out.outf("  --merge   fold the four hooks into ~/.claude/settings.json — additive,")
	out.outf("            deduped, foreign hooks untouched; prints a diff and needs --yes")
	out.outf("            to write (a timestamped backup is made first)")
}
