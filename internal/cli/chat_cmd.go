package cli

import (
	"github.com/FRIKKern/barkpark/internal/chat"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runChat is the builtin `bp chat` — the native terminal chat client
// (internal/chat), the second surface of One Chat, Two Surfaces (charter
// .claude/workflows/bp-chat-tui-charter.md, vision /papers/barkpark-chat-tui).
// It is a built-in (not a manifest verb) because it is a full-screen interactive
// Bubble Tea program with its own live SSE stream, not the single JSON body the
// generic command path decodes — the same reason `bp tasks` is a builtin.
func runChat(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		printChatHelp(out)
		return exitOK
	}
	// The client takes no positionals or flags of its own; reject stray args so a
	// typo fails loudly instead of being silently ignored.
	if len(args) > 0 {
		return usageErrf(out, func() { printChatHelp(out) },
			"bp chat takes no arguments (got %q)", args[0])
	}

	// A full-screen alt-screen TUI needs a real terminal. Without one (piped,
	// redirected, CI) fail cleanly instead of scribbling escape codes into a file.
	if !out.isTTY {
		out.errf("bp chat needs a terminal — run it in an interactive shell.")
		return exitGeneric
	}

	// Token is the DATA-PLANE bearer (ctx.Token), never the control-plane
	// CloudToken (charter D3): the /v1/chat routes are admin-token gated on the
	// content server this repo resolves to.
	cfg := chat.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
	}
	if err := chat.Run(cfg); err != nil {
		out.errf("bp chat: %v", err)
		return exitGeneric
	}
	return exitOK
}

// printChatHelp prints the short help block for `bp chat`.
func printChatHelp(out *writer) {
	out.outf("usage: bp chat")
	out.outf("")
	out.outf("Open the native terminal chat client — the second surface of One Chat, Two")
	out.outf("Surfaces, driving the SAME engine Studio chat drives over the /v1/chat wire.")
	out.outf("Launch lists your sessions; resume one or start a new conversation.")
	out.outf("")
	out.outf("The transcript renders block-for-block by pdrender (the same engine papers")
	out.outf("use); replies stream live and settle into rendered blocks at each turn's end.")
	out.outf("")
	out.outf("keys:")
	out.outf("  picker")
	out.outf("    ↑ / ↓          move between sessions")
	out.outf("    enter          open the session (or start a new one on the top row)")
	out.outf("    n              start a new session")
	out.outf("    r              refresh the list")
	out.outf("    q, ctrl-c      quit")
	out.outf("  conversation")
	out.outf("    type + enter   send a message (mid-turn sends queue for the next turn)")
	out.outf("    esc            interrupt the running turn (the session stays live)")
	out.outf("    ↑ / ↓, wheel   scroll the transcript · End follows the live tail")
	out.outf("    ctrl-b         back to the sessions list (your draft is saved)")
	out.outf("    ctrl-c         quit (your draft is saved)")
}
