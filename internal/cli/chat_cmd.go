package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/chat"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runChat is the builtin `bp chat` — the native terminal chat client
// (internal/chat), the second surface of One Chat, Two Surfaces (charter
// .claude/workflows/bp-chat-tui-charter.md, vision /papers/barkpark-chat-tui).
// It is a built-in (not a manifest verb) because it is a full-screen interactive
// Bubble Tea program with its own live SSE stream, not the single JSON body the
// generic command path decodes — the same reason `bp tasks` is a builtin.
//
// `bp chat ls` is the one NON-TUI verb (herd charter D55h): it is peeled off
// BEFORE the stray-args reject and the TTY gate, because listing/watching the
// herd is exactly what a pipe or a script wants (`bp chat ls -o json | jq`,
// `bp chat ls --watch` in a monitor pane).
//
// `bp chat --theme <identity>` reskins the transcript to a design-system palette
// (charter D61-D64). chat --theme = the SKIN IDENTITY axis (evergreen/charple/
// ember/fjord/iris), which is DISTINCT from `bp paper --theme` = the light/dark
// MODE axis; chat mode is fixed dark.
//
// chatThemeIdentities are the skin identities `bp chat --theme` accepts — the
// genPalette ids in internal/pdrender/tokens_gen.go. Resolve/ThemeFor already
// fall back to evergreen for an id the palette map doesn't carry, but we mirror
// the set HERE so the fallback is LOUD (a stderr notice) instead of a silent
// reskin the user never asked for.
var chatThemeIdentities = map[string]bool{
	"evergreen": true, "charple": true, "ember": true, "fjord": true, "iris": true,
}

func runChat(out *writer, g globals, ctx manifest.Context, args []string) int {
	if len(args) > 0 && args[0] == "ls" {
		return runChatLs(out, g, ctx, args[1:])
	}
	// `unarchive` is the OTHER non-TTY verb, and it exists because the shelf door
	// was one-way: the TUI's `a` archives and `bp chat ls --archived` shows the
	// shelf, but nothing outside a terminal could put a row BACK — a dismissal
	// was effectively permanent for any script, pipe, or CI pane. Peeled here for
	// the same reason as `ls`: before the stray-arg reject and the TTY gate.
	if len(args) > 0 && args[0] == "unarchive" {
		return runChatUnarchive(out, g, ctx, args[1:])
	}
	if g.help {
		printChatHelp(out)
		return exitOK
	}

	// `--theme <identity>` reskins the transcript to a design-system palette
	// (charter D61-D64). This is the SKIN IDENTITY axis — evergreen/charple/ember/
	// fjord/iris — DISTINCT from `bp paper --theme` which selects a light/dark
	// MODE; chat mode stays dark. It is PEELED here, before the stray-arg reject,
	// so the flag never trips the "no arguments" gate (mirrors how `ls` is peeled
	// above). Precedence: this flag > BP_THEME/config (ResolveThemeID) > evergreen.
	themeFlag := ""
	var rest []string
	for i := 0; i < len(args); i++ {
		key, inlineVal, hasInline := splitFlagToken(args[i])
		if key == "--theme" {
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--theme")
			if err != nil {
				return usageErrf(out, func() { printChatHelp(out) }, "%v", err)
			}
			themeFlag = v
			i = ni - 1
			continue
		}
		rest = append(rest, args[i])
	}
	args = rest

	// The client takes no other positionals or flags of its own; reject stray
	// args so a typo fails loudly instead of being silently ignored.
	if len(args) > 0 {
		return usageErrf(out, func() { printChatHelp(out) },
			"bp chat takes no arguments besides `ls` and `unarchive` (got %q)", args[0])
	}

	// Resolve the skin identity by precedence and validate it. An UNKNOWN id is
	// NOT an error (correcting the old AC): it falls back to evergreen with a
	// one-line stderr notice, so a typo degrades to the default skin instead of
	// crashing a full-screen program.
	themeID := strings.TrimSpace(themeFlag)
	if themeID == "" {
		fileCfg, _ := LoadConfig() // missing/unreadable config → nil → env/default
		themeID = strings.TrimSpace(ResolveThemeID(fileCfg))
	}
	if !chatThemeIdentities[themeID] {
		out.errf("bp chat: unknown --theme %q — using evergreen (choices: charple, ember, evergreen, fjord, iris)", themeID)
		themeID = DefaultThemeID
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
		Theme:     themeID,
	}
	if err := chat.Run(cfg); err != nil {
		out.errf("bp chat: %v", err)
		return exitGeneric
	}
	return exitOK
}

// runChatLs is `bp chat ls [--watch]` (herd charter D55h): the herd roster
// without a TTY. One-shot it prints one row per session (state, title, cost,
// age — `-o json` emits the raw sidebar rows); with --watch it holds the ONE
// fleet SSE stream and prints one line per STATE FLIP (session id, state,
// title) until Ctrl-C, which exits 0.
func runChatLs(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		printChatLsHelp(out)
		return exitOK
	}
	watch := false
	archived := false
	for _, a := range args {
		switch a {
		case "--watch":
			watch = true
		case "--archived":
			archived = true
		default:
			return usageErrf(out, func() { printChatLsHelp(out) },
				"unknown chat ls argument %q (bp chat ls takes --watch and --archived)", a)
		}
	}
	if watch && archived {
		// The fleet stream carries state FLIPS for the live fleet; there is no
		// archived-shelf stream and an archived session emits no flips. Silently
		// watching an empty stream would look like a hang.
		return usageErrf(out, func() { printChatLsHelp(out) },
			"bp chat ls --archived cannot be combined with --watch (the shelf has no live stream)")
	}

	// The chat routes are data-plane-token scoped (charter D3/D21) — no
	// workspace/project/dataset plumbing exists on the wire to carry.
	client := apiclient.New(apiclient.Config{BaseURL: ctx.Server, Token: ctx.Token})

	if watch {
		return runChatLsWatch(out, ctx, client)
	}

	sessions, err := client.ListChatSessions(archived)
	if err != nil {
		out.errf("bp chat ls: %v", err)
		return exitGeneric
	}
	if out.machineOut() {
		// Round-trip through JSON so -o json / -o yaml both emit the wire shape.
		raw, err := json.Marshal(sessions)
		if err != nil {
			out.errf("bp chat ls: %v", err)
			return exitGeneric
		}
		var generic any
		_ = json.Unmarshal(raw, &generic)
		if out.emitStructured(map[string]any{"sessions": generic}) {
			return exitOK
		}
	}
	if len(sessions) == 0 {
		if archived {
			out.outf("no archived chat sessions")
		} else {
			out.outf("no chat sessions")
		}
		return exitOK
	}
	now := time.Now()
	for _, s := range sessions {
		title := strings.TrimSpace(s.Title)
		if title == "" {
			title = "untitled session"
		}
		state := s.AgentState
		if state == "" {
			state = "unknown"
		}
		meta := fmt.Sprintf("%d msg", s.MessageCount)
		if s.TotalCostUSD > 0 {
			meta += fmt.Sprintf(" · $%.2f", s.TotalCostUSD)
		}
		if age := chatLsAge(s.AgentStateAt, s.LastActiveAt, now); age != "" {
			meta += " · " + age
		}
		out.outf("%s  %-8s %-40s %s", s.ID, state, truncateCell(title, 40), meta)
	}
	return exitOK
}

// runChatUnarchive is `bp chat unarchive <id>` — the shelf's way BACK, and the
// half that made archiving reversible outside the TUI.
//
// Idempotent by the server's contract (unarchiving a live session still 200s),
// so a re-run is safe; a missing or foreign id is the 404 NOT-FOUND ORACLE and
// is reported as exactly that — "no chat session <id>" — because the wire
// deliberately cannot tell the two apart, and a message like "not yours" would
// be inventing a fact.
func runChatUnarchive(out *writer, g globals, ctx manifest.Context, args []string) int {
	if g.help {
		printChatUnarchiveHelp(out)
		return exitOK
	}
	var ids []string
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			return usageErrf(out, func() { printChatUnarchiveHelp(out) },
				"unknown chat unarchive argument %q (bp chat unarchive takes one session id)", a)
		}
		ids = append(ids, a)
	}
	if len(ids) != 1 {
		// One id, never a list: this is a lifecycle write, and a partial failure
		// halfway through a batch leaves the caller guessing which rows moved.
		return usageErrf(out, func() { printChatUnarchiveHelp(out) },
			"bp chat unarchive needs exactly one session id (got %d)", len(ids))
	}

	client := apiclient.New(apiclient.Config{BaseURL: ctx.Server, Token: ctx.Token})
	session, status, raw, err := client.UnarchiveChatSessionRaw(ids[0])
	// THE FENCE RUNS FIRST, before the error check, on the same reasoning
	// #15917 gave: on an accepted status the RAW BYTES are the receipt, and the
	// decode error an HTML page or an empty 200 produces
	// ("decode unarchive response: invalid character '<' …") names the JSON
	// parser rather than the transport. `{}` / `null` / `{"result":null}` do not
	// even error — they decode to a ZERO ChatSession and printed
	// `unarchived   untitled session` at rc=0.
	//
	// GATED ON A 2xx: chatSendRaw returns an error for a non-accepted status
	// too, and status 0 on a transport failure. Screening those would answer a
	// refused 404 or a dead socket with "unreadable write receipt: HTTP 0",
	// burying the real cause. The fence's business is a STATED SUCCESS whose
	// body said nothing.
	if status >= 200 && status < 300 {
		if rc, handled := screenBuiltinWriteReceipt(out, "chat unarchive", status, raw); handled {
			return rc
		}
	}
	if err != nil {
		out.errf("bp chat unarchive: %v", err)
		return exitGeneric
	}
	if out.machineOut() {
		raw, merr := json.Marshal(session)
		if merr != nil {
			out.errf("bp chat unarchive: %v", merr)
			return exitGeneric
		}
		var generic any
		_ = json.Unmarshal(raw, &generic)
		if out.emitStructured(map[string]any{"session": generic}) {
			return exitOK
		}
	}
	title := strings.TrimSpace(session.Title)
	if title == "" {
		title = "untitled session"
	}
	out.outf("unarchived %s  %s", session.ID, title)
	return exitOK
}

// runChatLsWatch holds the fleet stream synchronously (the runListen
// precedent): one printed line per state flip, Ctrl-C cancels the context and
// exits 0. The transport owns reconnect/backoff; only its terminal give-up is
// an error.
func runChatLsWatch(out *writer, ctx manifest.Context, client *apiclient.Client) int {
	sigCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	if out.isTTY {
		out.errf("watching the herd on %s — Ctrl-C to stop", ctx.Server)
	}
	err := client.FleetEvents(sigCtx, "", func(event, data string) error {
		if line, ok := fleetWatchLine(event, []byte(data)); ok {
			out.outf("%s", line)
		}
		return nil
	}, func() {
		if out.isTTY {
			out.errf("reconnecting to %s …", ctx.Server)
		}
	})
	if err != nil && sigCtx.Err() == nil {
		out.errf("bp chat ls --watch: %v", err)
		return exitGeneric
	}
	return exitOK
}

// fleetWatchLine renders one --watch output line from a fleet frame: STATE
// FLIPS only (session id, state, title when the frame carries one — live
// flips carry title:null by design). Snapshots, heartbeats, keepalives, and
// malformed frames print nothing.
func fleetWatchLine(event string, data []byte) (string, bool) {
	if event != "state" {
		return "", false
	}
	var f struct {
		SessionID  string  `json:"session_id"`
		AgentState string  `json:"agent_state"`
		Title      *string `json:"title"`
	}
	if err := json.Unmarshal(data, &f); err != nil || f.SessionID == "" || f.AgentState == "" {
		return "", false
	}
	line := f.SessionID + "  " + f.AgentState
	if f.Title != nil {
		if t := strings.TrimSpace(*f.Title); t != "" {
			line += "  " + t
		}
	}
	return line, true
}

// chatLsAge is the roster row's honest relative age: the agent-state flip
// timestamp when the widened wire carries one, else last_active_at; "" when
// neither parses (honest blank, never fabricated).
func chatLsAge(agentStateAt, lastActiveAt string, now time.Time) string {
	for _, iso := range []string{agentStateAt, lastActiveAt} {
		if iso == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339, iso)
		if err != nil {
			continue
		}
		d := now.Sub(t)
		if d < 0 {
			d = 0
		}
		switch {
		case d < time.Minute:
			return "just now"
		case d < time.Hour:
			return fmt.Sprintf("%dm", int(d.Minutes()))
		case d < 24*time.Hour:
			return fmt.Sprintf("%dh", int(d.Hours()))
		default:
			return fmt.Sprintf("%dd", int(d.Hours()/24))
		}
	}
	return ""
}

// printChatHelp prints the short help block for `bp chat`.
func printChatHelp(out *writer) {
	out.outf("usage: bp chat [--theme <skin>]   open the herd (interactive TUI)")
	out.outf("       bp chat ls [--watch]       list the herd without a TTY")
	out.outf("       bp chat ls --archived      list the archived shelf")
	out.outf("       bp chat unarchive <id>     put a shelved session back on the herd")
	out.outf("")
	out.outf("  --theme <skin>   design-system palette: evergreen (default), charple,")
	out.outf("                   ember, fjord, iris — the SKIN IDENTITY (mode stays dark;")
	out.outf("                   distinct from `bp paper --theme` which picks light/dark).")
	out.outf("                   Unknown skin → evergreen (with a notice). Also BP_THEME.")
	out.outf("")
	out.outf("Open the native terminal chat client — the second surface of One Chat, Two")
	out.outf("Surfaces, driving the SAME engine Studio chat drives over the /v1/chat wire.")
	out.outf("Launch lands on the herd: every session with its agent-state pill")
	out.outf("(working/blocked/idle/unknown), sorted by attention — blocked first.")
	out.outf("")
	out.outf("The transcript renders block-for-block by pdrender (the same engine papers")
	out.outf("use); replies stream live and settle into rendered blocks at each turn's end.")
	out.outf("")
	out.outf("keys:")
	out.outf("  herd (launch)")
	out.outf("    ↑ / ↓          move between sessions")
	out.outf("    enter          attach to the session (or start a new one on the top row)")
	out.outf("    n              start a new session")
	out.outf("    a              archive the row (dismiss it — the session keeps running)")
	out.outf("    r              refresh the list")
	out.outf("    q, ctrl-c      quit")
	out.outf("  conversation")
	out.outf("    type + enter   send a message (mid-turn sends queue for the next turn)")
	out.outf("    esc            interrupt the running turn (the session stays live);")
	out.outf("                   with no turn running, detach back to the herd")
	out.outf("    ↑ / ↓, wheel   scroll the transcript · End follows the live tail")
	out.outf("    ctrl-b         back to the herd (your draft is saved)")
	out.outf("    ctrl-c         quit (your draft is saved)")
}

// printChatUnarchiveHelp prints the short help block for `bp chat unarchive`.
func printChatUnarchiveHelp(out *writer) {
	out.outf("usage: bp chat unarchive <session-id>")
	out.outf("")
	out.outf("Put an archived session back on the active herd — the way BACK from the shelf")
	out.outf("`bp chat ls --archived` lists. Archiving is DISMISSAL: nothing about the")
	out.outf("session's liveness or its agent state changed, so nothing is being restarted")
	out.outf("here — only which list the row appears in.")
	out.outf("")
	out.outf("Idempotent (unarchiving a session that is already active still succeeds).")
	out.outf("`-o json` emits the refreshed session. A missing session and one you cannot")
	out.outf("see are reported the same way, by design.")
}

// printChatLsHelp prints the short help block for `bp chat ls`.
func printChatLsHelp(out *writer) {
	out.outf("usage: bp chat ls [--watch | --archived]")
	out.outf("")
	out.outf("List the chat herd without a TTY: one row per session — id, agent state")
	out.outf("(working/blocked/idle/unknown), title, messages, cost, and age.")
	out.outf("`-o json` emits the raw sidebar rows.")
	out.outf("")
	out.outf("  --watch      hold the fleet stream and print one line per state flip")
	out.outf("               (session id, state, title) until Ctrl-C (exits 0)")
	out.outf("  --archived   list the archived SHELF instead of the active herd.")
	out.outf("               Archiving is DISMISSAL — orthogonal to liveness and to")
	out.outf("               attention: a shelved session keeps running and keeps its")
	out.outf("               agent state. Not combinable with --watch (no live stream")
	out.outf("               exists for the shelf).")
}
