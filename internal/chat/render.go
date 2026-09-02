package chat

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/pdrender"
	"github.com/charmbracelet/lipgloss"
)

// render.go — the pure paint. Nothing here touches the network, the clock, or
// the reducer: it turns a Model (screen + State + input) into a string the
// Bubble Tea shell hands back from View. The transcript is the load-bearing
// surface, so it lives here behind small helpers the golden-parity harness
// (ct-w1-golden-harness) can call directly.
//
// Rendering law (charter D8/D10): every SETTLED assistant message is one
// pdrender.RenderDoc call — a reply is a self-contained document, not a page in
// one long paper. Nothing accumulates across replies: pdrender generates no
// figure numbers at all (it only emphasises an author-typed "Figure N." lead,
// mirroring the web reader), so a caption reads the same in message 1 and 50. The live streaming tail (charter D9) is the ONE thing that
// does NOT go through pdrender: it is plain-text truth, word-wrapped and
// redrawn per tick, and it is replaced by settled blocks at the turn boundary.

// chatRegistry is the ONE shared pdrender composition root for chat prose — the
// same DarkTheme stack task detail prose uses (taskboard/detail_render.go), so
// the transcript harmonizes with the rest of bp. Figure numbering is per-CALL
// (RenderDoc seeds it), never per-registry, so sharing one registry across
// messages is safe: each renderMessage makes its own RenderDoc call.
var chatRegistry = pdrender.DefaultRegistry(pdrender.DarkTheme())

// chatProfile matches detail prose: NoColor keeps fenced code honestly
// multi-line (pdrender's colored path collapses it) while block headings/body
// still wear the DarkTheme lipgloss styling that rides the global lipgloss
// profile. Color stays a signal of STATE (chrome/notice), never decoration.
const chatProfile = pdrender.NoColor

var (
	dimStyle    = lipgloss.NewStyle().Faint(true)
	titleStyle  = lipgloss.NewStyle().Bold(true)
	youStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	badgeStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	warnStyle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("3"))
	noticeStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("5"))
	cardBar     = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	focusBar    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	allowStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	cursorStyle = lipgloss.NewStyle().Reverse(true)

	// The epic-cycle phase ticks (wsc D3): done = evergreen, active = the live
	// phase, future = dim. No fake breathing in a static paint — the glyph and
	// colour carry the state (same discipline as railGlyph).
	tickDoneStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	tickActiveStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))

	// A tool row that settled on an ERROR result — the ✗ half of the
	// settle-gated gutter (toolRowGlyph). ANSI index, like every style above;
	// internal/chat carries no hex, so the go-literal gate stays quiet.
	toolFailStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
)

// cardRoles are the interactive card rows (charter D27/D28: approval/question/
// plan). They stay CARDS — routed to cardView so they keep their focus ring +
// answer footer — but their BODY is now a dual-surface PortableDoc block type
// (chat-approval/chat-question/chat-plan, charter D35): cardBodyLines renders the
// server's typed block through the SAME pdrender seam the reader uses, so the
// card body reads identically in Studio and the terminal. The card's
// ANSWERABILITY stays on the message ENVELOPE (role+request_id+approval_status),
// NEVER the block — so the row is never a DEAD card divorced from its answer
// state. The engine routes one wire ask to one of these three roles by its
// tool_name (permission_role/1) — the store IS the router.
var cardRoles = map[string]string{
	"approval": "Approval requested",
	"question": "Question",
	"plan":     "Plan proposed",
}

// blockRoles are the structural rows now promoted to dual-surface PortableDoc
// block types (charter D25, Law 1): the server carries a typed block
// (chat-todo / chat-thinking) on the message, so the transcript renders a REAL
// checklist / thought row through the same pdrender seam the assistant reply
// body uses — no longer collapsed to one dim line. When the block is absent (a
// mid-persist or thinner frame) the render degrades honestly to the dim
// provenance line, never a blank or a crash.
//
// `tool` is NOT here: a tool row draws a GUTTER HEADER (its settle glyph plus
// the tool line) above whatever block it carries, so it routes to renderToolRow
// — and most tool rows (Bash/Read/Grep) carry no block at all, which is exactly
// why the glyph is an envelope fact rather than block content.
var blockRoles = map[string]bool{
	"todo": true, "thinking": true,
}

// structuralRoles are the remaining Recorder provenance rows that the MVP
// transcript still shows as ONE dim line rather than full render — their settled
// truth is a heading in the conversation, not a body the reader reads. Never
// hidden (that would be a silent gap); dimmed. `system` has no bespoke block
// type (nothing visual to promote), so it stays here.
var structuralRoles = map[string]bool{
	"system": true,
}

// bodyWidth is the wrap measure for prose: capped so terminal typography stays
// readable on a wide pane, floored so the layout math never goes negative.
func bodyWidth(width int) int {
	w := width - 2
	if w > 88 {
		w = 88
	}
	if w < 8 {
		w = 8
	}
	return w
}

// transcriptLines renders the WHOLE conversation to a flat line slice at the
// given width: settled messages (each its own RenderDoc call), then unsettled
// optimistic local sends (badged ⧗ queued mid-turn, charter D12), then the live
// streaming tail (charter D9). The shell windows this slice with follow-mode
// (render.go window()); this function is width-pure and clock-free so the
// golden harness can diff it against the Studio projection.
func (m Model) transcriptLines(width int) []string {
	lines, _ := m.transcriptBuild(width, "")
	return lines
}

// transcriptBuild is the ONE conversation accumulator (wsc-needs-you): it walks
// the messages exactly once and, alongside the flat line slice, records the line
// index where the card whose request_id == targetRID begins (its first content
// line, after the block separator). startLine is -1 when targetRID is "" or the
// target card is not present/answerable — so the needs-you Enter-jump pins the
// viewport straight to the pending card off this SAME walk, never a forked second
// pass over the transcript. transcriptLines is the width-pure/clock-free façade
// the golden harness diffs against the Studio projection.
func (m Model) transcriptBuild(width int, targetRID string) ([]string, int) {
	lines, startLine, _ := m.transcriptAnchored(width, targetRID)
	return lines, startLine
}

// transcriptAnchored is transcriptBuild plus the BLOCK INDEX the scroll anchor
// keys on (charter D80). blockStarts[i] is the physical line index of the first
// content line of block i, where a block is one unit the accumulator pushes — a
// settled message, an optimistic local send, or the streaming tail — in walk
// order. The blank separator push() prepends between blocks belongs to NEITHER
// block (it sits at blockStarts[i]-1), exactly like the targetRID startLine
// capture below, which is the same arithmetic generalised from the one
// answerable() card to every block.
//
// Blocks are the anchor's coordinate system. A pinned viewport records
// (block, intra-block offset) instead of a raw physical top line, so a height
// change ABOVE the pin shifts blockStarts and the pin follows its own content
// instead of silently showing something else at the same line number.
func (m Model) transcriptAnchored(width int, targetRID string) ([]string, int, []int) {
	w := bodyWidth(width)
	var lines []string
	var blockStarts []int
	startLine := -1
	push := func(ls ...string) {
		if len(ls) == 0 {
			return
		}
		if len(lines) > 0 {
			lines = append(lines, "")
		}
		blockStarts = append(blockStarts, len(lines))
		lines = append(lines, ls...)
	}
	// The focused pending card's request_id — its card wears the active border +
	// the answer hint; the others stay quiet answerable cards.
	focusRID := ""
	if card, ok := m.focusedCard(); ok {
		focusRID = card.RequestID()
	}
	for _, msg := range m.st.Messages {
		focused := focusRID != "" && msg.RequestID() == focusRID && answerable(msg)
		inflight := m.st.AnswerInFlight[msg.RequestID()]
		r := renderMessage(width, msg, focused, inflight)
		if len(r) == 0 {
			continue
		}
		// Capture the target card's block start BEFORE the push, accounting for the
		// blank separator push prepends once the slice is non-empty.
		if targetRID != "" && startLine < 0 && msg.RequestID() == targetRID && answerable(msg) {
			sep := 0
			if len(lines) > 0 {
				sep = 1
			}
			startLine = len(lines) + sep
		}
		push(r...)
	}
	for _, ls := range m.st.Local {
		push(renderLocalSend(w, ls)...)
	}
	if strings.TrimSpace(m.st.Tail) != "" {
		// The live turn (charter D9/D81): committed segments through the settled
		// pdrender stack, the uncommitted remainder plain. With no `stable` frames
		// on the wire this returns renderTail's bytes unchanged.
		push(renderLiveTail(chatRegistry, width, m.st)...)
	}
	// Live ledger transitions (tlv-bl-chat-live-transition-stream) close the
	// transcript. They are pushed LAST, in arrival order, because they are the
	// newest thing that happened and they carry no seq to interleave by — a
	// live-only frame has no persisted row to sit beside. This is the honest
	// MVP the charter allows: one line per transition, no chip rendering (the
	// TUI has none for tasks at all today).
	if ls := renderTaskTransitions(w, m.st.TaskTransitions); len(ls) > 0 {
		push(ls...)
	}
	if len(lines) == 0 {
		lines = []string{dimStyle.Render("No messages yet — type below and press Enter.")}
		blockStarts = []int{0}
	}
	return lines, startLine, blockStarts
}

// renderMessage renders one settled Postgres row (charter D8). Assistant rows
// go through pdrender; user rows echo as a marked prompt; approval/question/
// plan render as interactive cards (answerable when pending, resolution badge
// when terminal); other structural rows collapse to one dim provenance line.
// Assistant is the ONLY role in golden parity's scope. focused marks the card
// the answer keys act on; inflight is the decision POSTed but not yet confirmed.
func renderMessage(width int, msg Message, focused bool, inflight string) []string {
	w := bodyWidth(width)
	switch {
	case msg.Role == "assistant":
		return renderAssistantDoc(chatRegistry, width, msg)
	case msg.Role == "user":
		return append(renderUserEcho(w, msg.SourceMarkdown), renderAttachments(w, msg.Attachments)...)
	case cardRoles[msg.Role] != "":
		return cardView(w, msg, focused, inflight)
	case msg.Role == "tool":
		return renderToolRow(chatRegistry, width, msg)
	case blockRoles[msg.Role]:
		return renderStructuralDoc(chatRegistry, width, msg)
	case structuralRoles[msg.Role]:
		return []string{dimStyle.Render(truncate(provenanceLabel(msg), w))}
	default:
		// Forward-compatible: an unknown role still renders its source, never a
		// crash or a blank (same tolerance pdrender's decoder shows).
		return renderUserEcho(w, msg.SourceMarkdown)
	}
}

// renderAssistantDoc is the golden-parity seam: server `blocks` → pdrender
// Decode → ONE RenderDoc call (Figure counter reset). Empty/undecodable blocks
// fall back to the raw source_markdown as a plain paragraph so a mid-persist row
// is never blank. Exported-shape (package-visible) so ct-w1-golden-harness can
// project a message identically to the reader.
func renderAssistantDoc(reg *pdrender.Registry, width int, msg Message) []string {
	w := bodyWidth(width)
	blocks, err := pdrender.Decode([]byte(msg.Blocks))
	if err != nil || len(blocks) == 0 {
		return wrap(strings.TrimSpace(msg.SourceMarkdown), w)
	}
	// ONE RenderDoc call per message — this is the per-message Figure reset
	// (charter D10). The shared registry is safe because the counter is seeded
	// per call, not per registry.
	doc := reg.RenderDoc(blocks, pdrender.RenderCtx{Width: w, Profile: chatProfile})
	out := make([]string, 0, strings.Count(doc, "\n")+1)
	for _, ln := range strings.Split(doc, "\n") {
		out = append(out, strings.TrimRight(ln, " "))
	}
	return out
}

// renderStructuralDoc renders a tool/todo/thinking row through pdrender on the
// typed block the server emits (charter D25, Law 1): chat-tool-diff → a colored
// line diff, chat-todo → the ☒/◐/☐ checklist card, chat-thinking → the dim
// thought row — the SAME block types Studio renders, drawn in the terminal.
// When the block is absent or undecodable (a mid-persist or thinner frame) it
// degrades honestly to the one-line dim provenance label, never a blank line or
// a crash — the same forward-compat tolerance the assistant path shows.
func renderStructuralDoc(reg *pdrender.Registry, width int, msg Message) []string {
	w := bodyWidth(width)
	blocks, err := pdrender.Decode([]byte(msg.Blocks))
	if err != nil || len(blocks) == 0 {
		return []string{dimStyle.Render(truncate(provenanceLabel(msg), w))}
	}
	doc := reg.RenderDoc(blocks, pdrender.RenderCtx{Width: w, Profile: chatProfile})
	out := make([]string, 0, strings.Count(doc, "\n")+1)
	for _, ln := range strings.Split(doc, "\n") {
		out = append(out, strings.TrimRight(ln, " "))
	}
	return out
}

// ── the tool row's settle-gated gutter glyph (both-surfaces truth table) ──────
//
// The Go twin of BarkparkWeb.Studio.ChatToolRenderer.settle_state/1. Both
// surfaces read the SAME three ENVELOPE facts off the row's `metadata`, which
// chat_controller.message_json already ships verbatim for every row:
//
//	turn_settled — stamped by the Recorder (StudioChat.settle_tool_rows/1) when
//	               the row's TURN emitted its terminal `result` frame;
//	tool_error   — stamped by attach_tool_result/4 when the row's `tool_result`
//	               block carried `is_error: true`;
//	output       — the tool_result's text, stamped by the same seam.
//
// SETTLE gate: while the turn runs, the gutter is neutral ● — a mid-turn
// tool_result never flips it. PROVENANCE gate: after the settle, only a row
// that actually carries a result may claim ✓; a row whose result never arrived
// stays ● forever rather than fabricate a completion. This is a truth table
// over the envelope, NOT a re-derivation — so `bp chat` and Studio cannot drift.
func toolRowState(msg Message) string {
	if !metaTrue(msg, "turn_settled") {
		return "pending"
	}
	if metaTrue(msg, "tool_error") {
		return "error"
	}
	if out, ok := msg.Metadata["output"].(string); ok && out != "" {
		return "ok"
	}
	return "pending"
}

// toolRowGlyph is the drawn form of toolRowState: the glyph plus the style that
// carries its meaning without color being load-bearing (the glyph differs too,
// so a NoColor profile or a monochrome terminal still reads the outcome).
func toolRowGlyph(msg Message) (string, lipgloss.Style) {
	switch toolRowState(msg) {
	case "ok":
		return "✓", tickDoneStyle
	case "error":
		return "✗", toolFailStyle
	default:
		return "●", dimStyle
	}
}

// metaTrue reads a boolean envelope fact off a row's raw metadata map — false
// when the map, the key, or the JSON type is absent (forward-compatible: an
// older server that never stamped turn_settled renders every row neutral, which
// is the honest reading, not a crash).
func metaTrue(msg Message, key string) bool {
	if msg.Metadata == nil {
		return false
	}
	b, ok := msg.Metadata[key].(bool)
	return ok && b
}

// renderToolRow paints one transcript tool row: the settle-gated gutter glyph +
// the tool line, then whatever typed block the row carries (a chat-tool-diff for
// a file mutation; nothing at all for Bash/Read/Grep, which is the common case).
// This mirrors Studio's `● Edit — path` header above its diff card, so the same
// session reads the same way on both surfaces.
func renderToolRow(reg *pdrender.Registry, width int, msg Message) []string {
	w := bodyWidth(width)
	glyph, style := toolRowGlyph(msg)
	out := []string{style.Render(glyph) + " " + truncate(toolRowLabel(msg), w-2)}

	blocks, err := pdrender.Decode([]byte(msg.Blocks))
	if err != nil || len(blocks) == 0 {
		return out
	}
	doc := reg.RenderDoc(blocks, pdrender.RenderCtx{Width: w, Profile: chatProfile})
	for _, ln := range strings.Split(doc, "\n") {
		out = append(out, strings.TrimRight(ln, " "))
	}
	return out
}

// toolRowLabel is the tool row's one-line text — the Recorder's `tool_line`
// preview, persisted as source_markdown. Never empty, so the gutter glyph always
// has a row to sit on.
func toolRowLabel(msg Message) string {
	if s := firstLine(msg.SourceMarkdown); s != "" {
		return s
	}
	return "tool"
}

// provenanceLabel is the honest one-line fallback for a structural row that has
// no renderable block: the role, plus the first line of its source when present.
func provenanceLabel(msg Message) string {
	label := "· " + msg.Role
	if s := firstLine(msg.SourceMarkdown); s != "" {
		label += ": " + s
	}
	return label
}

// renderUserEcho paints a user message as a marked, wrapped prompt echo.
func renderUserEcho(w int, src string) []string {
	src = strings.TrimSpace(src)
	if src == "" {
		return nil
	}
	body := wrap(src, w-2)
	out := make([]string, 0, len(body))
	for i, ln := range body {
		marker := "  "
		if i == 0 {
			marker = youStyle.Render("› ")
		}
		out = append(out, marker+ln)
	}
	return out
}

// renderAttachments draws a user row's chat-owned attachment references
// (ct-bl-chat-attachments) as one dim chip per file: the media type and a human
// byte size, under the prompt echo.
//
// It renders the REFERENCE and nothing else. The terminal never fetches or
// draws the bytes, and there is deliberately nothing here to print a local path
// or a URL with a token in it — the wire shape carries neither, so this renderer
// structurally cannot leak one. That is the same reference Studio renders from,
// which is what makes "one shape, both surfaces" true rather than parallel.
func renderAttachments(w int, atts []Attachment) []string {
	if len(atts) == 0 {
		return nil
	}
	out := make([]string, 0, len(atts))
	for _, a := range atts {
		label := a.MediaType
		if label == "" {
			label = "attachment"
		}
		if a.ByteSize > 0 {
			label += " · " + humanBytes(a.ByteSize)
		}
		out = append(out, "  "+dimStyle.Render(truncate("⎘ "+label, w-2)))
	}
	return out
}

// humanBytes formats a byte count for an attachment chip. Deliberately coarse —
// a chip says "how big, roughly", and a precise count would be noise next to a
// media type.
func humanBytes(n int) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// renderLocalSend paints an optimistic, not-yet-settled user send. A mid-turn
// send wears the ⧗ queued badge (charter D12) until its own turn drains it.
func renderLocalSend(w int, ls LocalSend) []string {
	out := renderUserEcho(w, ls.Content)
	if ls.Queued && len(out) > 0 {
		out[0] += " " + badgeStyle.Render("⧗ queued")
	}
	return out
}

// renderTail paints the live streaming tail (charter D9): plain-text delta
// truth, word-wrapped, under a dim streaming marker. It NEVER goes through
// pdrender — it settles into blocks at the turn boundary. It is also the
// improvement-only FLOOR (D76): renderLiveTail returns exactly these bytes
// whenever the server sends no `stable` frames, or stops sending them.
func renderTail(w int, tail string) []string {
	body := wrap(strings.TrimRight(tail, " "), w)
	out := make([]string, 0, len(body)+1)
	out = append(out, dimStyle.Render(streamingMarker))
	out = append(out, body...)
	return out
}

// cardView boxes an approval/question/plan row as a bespoke card with a left
// rule and a state-dependent footer (charter D27/D28). The footer is the honest
// state:
//   - resolved (allowed/denied/canceled): a terminal badge — the same row Studio
//     answered flips here on refetch (Law-2, one Postgres truth).
//   - answering in flight: an immediate "answering: allow…" line.
//   - pending + focused: the answer affordance (ctrl+a/ctrl+r + tab).
//   - pending + not focused: a quiet "tab to answer" nudge.
//   - not answerable (no request_id): the read-only replay footnote.
//
// A focused pending card wears a bold top bar so the operator sees which card a
// keystroke acts on. Excluded from golden parity (assistant-reply-only).
func cardView(w int, msg Message, focused bool, inflight string) []string {
	bar := cardBar.Render("│ ")
	title := cardRoles[msg.Role]
	topBar := cardBar.Render("┌ ")
	if focused {
		topBar = focusBar.Render("┌ ")
		title += "  " + focusBar.Render("◀ focused")
	}
	out := []string{topBar + titleStyle.Render(title)}
	for _, ln := range cardBodyLines(w-2, msg) {
		out = append(out, bar+ln)
	}

	var foot string
	switch {
	case msg.Resolved():
		foot = cardResolutionBadge(msg.ApprovalStatus())
	case inflight != "":
		foot = badgeStyle.Render(answeringNotice(inflight))
	case answerable(msg):
		allow, deny := cardVerbs(msg.Role)
		if focused {
			foot = dimStyle.Render(fmt.Sprintf("ctrl+a %s · ctrl+r %s · tab next", allow, deny))
		} else {
			foot = dimStyle.Render(fmt.Sprintf("tab to focus · ctrl+a %s · ctrl+r %s", allow, deny))
		}
	default:
		// No request_id to answer (malformed/legacy row) — honest read-only note.
		foot = dimStyle.Render("read-only replay — answer in Studio")
	}
	out = append(out, cardBar.Render("└ ")+foot)
	return out
}

// cardVerbs names the allow/deny actions per card role. A plan proposal reads
// approve / keep planning (charter: plan-approve=allow, plan-keep=deny); an
// approval or a question reads allow / deny (scope is allow/deny only this wave).
func cardVerbs(role string) (allow, deny string) {
	if role == "plan" {
		return "approve", "keep planning"
	}
	return "allow", "deny"
}

// cardResolutionBadge is the terminal-state footer for a resolved card.
func cardResolutionBadge(status string) string {
	switch status {
	case "allowed":
		return allowStyle.Render("✓ allowed")
	case "denied":
		return noticeStyle.Render("⊘ denied")
	case "canceled":
		return dimStyle.Render("— canceled (no runtime to answer)")
	default:
		return dimStyle.Render(status)
	}
}

// ── live ledger transitions (tlv-bl-chat-live-transition-stream) ─────────────

// renderTaskTransitions renders the session's live ledger transitions: one dim
// mono line per transition, oldest first, each printed as `<glyph> <label>`.
// The label string comes STRAIGHT off the wire — Elixir's
// `Barkpark.StudioChat.TaskTransition.label/3` built it, the same function
// Studio's transcript row renders — so the two surfaces cannot word a
// transition differently. The glyph carries the state the GUI carries in a
// `--life-*` tint: a terminal has no colour token to borrow.
//
// Only the last maxTaskTransitions are shown, with an honest "+N earlier"
// header above them: a long session accumulates them, and a transcript that is
// mostly ledger noise is the firehose the scoping rule exists to refuse.
func renderTaskTransitions(w int, ts []TaskTransition) []string {
	if len(ts) == 0 {
		return nil
	}
	const maxTaskTransitions = 6
	var out []string
	start := 0
	if len(ts) > maxTaskTransitions {
		start = len(ts) - maxTaskTransitions
		out = append(out, dimStyle.Render(fmt.Sprintf("… +%d earlier task transitions", start)))
	}
	for _, t := range ts[start:] {
		out = append(out, truncate(taskTransitionGlyph(t.Status)+" "+dimStyle.Render(t.Label), w))
	}
	return out
}

// taskTransitionGlyph is the terminal's stand-in for Studio's `--life-*` tint:
// a settled task reads ✓, a cancelled/blocked one ✕, live work ●, anything else
// the neutral ◆. It mirrors railGlyph's vocabulary so the two live bands in this
// TUI do not teach two different alphabets.
func taskTransitionGlyph(status string) string {
	switch status {
	case "done", "closed":
		return allowStyle.Render("✓")
	case "cancelled", "blocked":
		return noticeStyle.Render("✕")
	case "in_progress":
		return badgeStyle.Render("●")
	default:
		return dimStyle.Render("◆")
	}
}

// ── the agents rail (Law-2 continuity) ───────────────────────────────────────

// renderRail paints the task-keyed agents rail below the transcript (charter
// D47) from the session's decoded rail_snapshot — the SAME mission control
// Studio shows, so a mid-session surface switch keeps it (Law-2). Empty snapshot
// → no band (honest absence, never an empty box). Capped to a handful of rows
// with a "+N more" overflow so it never crowds the transcript.
func renderRail(width int, rail []RailEntry) []string {
	if len(rail) == 0 {
		return nil
	}
	w := clamp(width, 8, 100)
	const maxRows = 5
	out := []string{
		dimStyle.Render(strings.Repeat("─", w)),
		titleStyle.Render("agents") + dimStyle.Render(fmt.Sprintf("  ·  %d in session", len(rail))),
	}
	for i, e := range rail {
		if i >= maxRows {
			out = append(out, dimStyle.Render(fmt.Sprintf("  … +%d more", len(rail)-maxRows)))
			break
		}
		out = append(out, railLine(w, e))
	}
	return out
}

// railLine is one agent row: a status glyph, the sub-agent label, then its
// status and token usage — mirroring Studio's rail_entry header line
// (rail_label + rail_header_summary) for the non-workflow case.
func railLine(w int, e RailEntry) string {
	meta := railStatusLabel(e.Status)
	if e.HasTokens {
		meta += " · " + formatTokens(e.Tokens) + " tok"
	}
	head := railGlyph(e.Status) + " " + e.Label
	line := head + dimStyle.Render("  ·  "+meta)
	return truncate(line, w)
}

// railGlyph is the status glyph, matching Studio's rail_entry_glyph: a settled
// cycle ✓, an interrupted one ✕, a live one ● (no fake breathing in a static
// paint — the glyph alone carries the state).
func railGlyph(status string) string {
	switch status {
	case "completed":
		return allowStyle.Render("✓")
	case "interrupted":
		return noticeStyle.Render("✕")
	default:
		return badgeStyle.Render("●")
	}
}

// railStatusLabel mirrors Studio's rail_status_label: completed → done,
// interrupted → interrupted, anything else → running.
func railStatusLabel(status string) string {
	switch status {
	case "completed":
		return "done"
	case "interrupted":
		return "interrupted"
	default:
		return "running"
	}
}

// formatTokens is the compact token count Studio's format_tokens renders:
// <1k verbatim, <10k one decimal (1.2k), <1M whole k ROUNDED (145.5k → 146k,
// parity with Elixir's round/1 — truncation drifted low), else 1.3M.
func formatTokens(n int) string {
	switch {
	case n < 0:
		return "—"
	case n < 1000:
		return fmt.Sprintf("%d", n)
	case n < 10000:
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	case n < 1000000:
		return fmt.Sprintf("%dk", int(math.Round(float64(n)/1000)))
	default:
		return fmt.Sprintf("%.1fM", float64(n)/1000000)
	}
}

// ── the below-composer workflow panel (wave session-card charter D13–D15) ────

// workflowStripVisible: the strip (and therefore the whole panel) exists ONLY
// while the open session's workflow entry is live — a settled run drops the
// strip and gives the transcript its rows back; plain chats never had it, so
// idle frames are byte-identical to the pre-panel geometry.
func (m Model) workflowStripVisible() bool {
	// The live SSE summary (wsc-bl-workflow-sse) is the freshest signal: present +
	// not Terminal ⇒ the strip stays up and refreshes mid-turn. It supersedes the
	// rail fold because a summary can arrive before the first turn-boundary refetch
	// hydrates st.Workflow.
	if lw := m.st.LiveWorkflow; lw != nil {
		return !lw.Terminal
	}
	return m.st.Workflow != nil && entryLifecycle(m.st.Workflow.Status) == "live"
}

// workflowPanelLines is the whole panel paint: the collapsed strip, plus the
// Enter-expanded two-pane detail. nil when no live workflow — chatFooter and
// bodyHeight both key off this one function, so the paint and the geometry can
// never disagree.
func (m Model) workflowPanelLines() []string {
	if !m.workflowStripVisible() {
		return nil
	}
	focused := m.focus == focusWorkflow
	needsYou := m.needsYou()
	// D41: a pending answerable card suppresses EVERY stall badge — a fleet
	// waiting on the operator is never stalled (the wait is the operator's).
	// needsYou implies !stallOK, so the warn banner and stall badges can never
	// render together (one urgent state at a time).
	stallOK := len(m.answerableCards()) == 0
	// The collapsed strip: the needs-you cockpit state (a live workflow blocked on
	// a pending answerable card) WINS — it flips to the warn banner so someone
	// watching the workflow strip sees the session is waiting on them (Enter jumps
	// to the card). Otherwise the strip prefers the live compact summary
	// (wsc-bl-workflow-sse) — its counters/elapsed advance mid-turn off the SSE
	// `event: workflow` delta, no rail refetch — falling back to the rail fold when
	// no summary has arrived yet (resume, or a pre-SSE server).
	var strip string
	switch {
	case needsYou:
		strip = renderWorkflowNeedsYouStrip(m.width, m.workflowLabel(), focused)
	case m.st.LiveWorkflow != nil:
		strip = renderWorkflowStripSummary(m.width, m.st.LiveWorkflow, m.now(), focused)
	default:
		strip = renderWorkflowStrip(m.width, m.st.Workflow, journeyOf(m.st.Workflow), m.now(), focused)
	}
	lines := []string{strip}
	if m.st.Workflow != nil {
		wf := m.st.Workflow
		j := journeyOf(wf)
		// The Enter-expanded detail iterates per-agent Nodes the compact summary
		// LACKS, so it stays sourced from the raw rail fold — turn-boundary fresh
		// (the accepted ceiling, backlogged wsc-bl-workflow-sse-detail). Guard on
		// Workflow because a summary-only strip can be up before the rail hydrated.
		if m.wfExpanded {
			// The needs-you banner also rides ABOVE the phase panes in the expanded
			// panel — the same warn phrase as the collapsed strip, so the pending gate
			// stays visible while the operator reads the detail.
			if needsYou {
				lines = append(lines, warnStyle.Render(needsYouBanner))
			}
			lines = append(lines, renderWorkflowDetail(m.width, wf, j, m.now(), m.wfPhase, stallOK)...)
			// The THIRD focus level (wave session-card charter D30/D39): the selected
			// agent's detail pane, appended INSIDE this one function so bodyHeight
			// self-corrects and the frame height stays fixed — mirroring the shipped
			// Studio pane (#3959). Additive under wfAgentDetail: an idle or a
			// phase-only panel is byte-identical to before this level existed.
			if m.wfAgentDetail {
				lines = append(lines, renderWorkflowAgentDetail(m.width, j, m.now(), m.wfPhase, m.wfAgent, stallOK)...)
			}
		}
		// D43: the terminal result box — the panel bottom once the rail entry has
		// settled (reachable while the strip still stands on a fresher live
		// summary): the outcome stated verbatim, never a vanish-with-no-verdict.
		lines = append(lines, m.workflowResultBox(j)...)
	}
	return lines
}

// workflowResultBox is the D43 terminal result box: outcome glyph + the entry's
// lifecycle word VERBATIM ('completed'/'interrupted') + the honest settled/total
// and token figures, a FIRST-CLASS failed line whenever the fleet carries
// failures (j.Failed otherwise renders nowhere at summary level — a 'completed'
// entry can carry failed agents), and the epic grade line ONLY when the cached
// picker Epic's wave_status heartbeat carries 'complete — grade' (task-spine
// truth already on the list wire — ZERO new wire; the richer epic-on-session
// ride is backlog wsc-bl-epic-on-session-json). An interrupted wave is stated
// plainly and NEVER dressed with a resultPreview snippet. nil while live.
func (m Model) workflowResultBox(j WorkflowJourney) []string {
	if j.EntryStatus == "live" {
		return nil
	}
	glyph := allowStyle.Render("✓")
	if j.EntryStatus == "interrupted" {
		glyph = noticeStyle.Render("✕")
	}
	head := glyph + " " + titleStyle.Render(j.EntryStatus) +
		dimStyle.Render(fmt.Sprintf(" · %d/%d agents", j.Settled(), j.AgentsTotal))
	if j.HasTokens {
		head += dimStyle.Render(" · ↓" + formatTokens(j.Tokens))
	}
	out := []string{head}
	if j.Failed > 0 {
		out = append(out, "  "+noticeStyle.Render(fmt.Sprintf("✕ %d failed", j.Failed)))
	}
	if epic := m.cachedEpic(); epic != nil && strings.Contains(epic.WaveStatus, "complete — grade") {
		w := m.width - 2
		if w < 8 {
			w = 8
		}
		out = append(out, "  "+dimStyle.Render(truncate(epic.WaveStatus, w)))
	}
	return out
}

// cachedEpic resolves the open session's epic-goal line from the PICKER cache —
// the list wire already carries Epic per session row (wsc D9/D12), so the grade
// line costs zero new wire. nil when the cache has no row (or no epic) for the
// open session — the box then simply omits the grade line, never fabricates one.
func (m Model) cachedEpic() *EpicGoal {
	for _, s := range m.sessions {
		if s.ID == m.st.SessionID {
			return s.Epic
		}
	}
	return nil
}

// renderWorkflowAgentDetail is the third focus level (wave session-card charter
// D39): the SELECTED agent's expanded detail, a byte-for-honesty mirror of the
// shipped Studio pane (#3959). A header row (state glyph / label / model family /
// tokens / elapsed, via workflowAgentLine) tops it; below, indented:
//
//	· an attempt>1 retry chip FIRST;
//	· the lowercase 'about' brief (promptPreview, wrapped);
//	· then — MUTUALLY EXCLUSIVE — the live '▸' NOW line (bare glyph, no label:
//	  lastToolName · lastToolSummary · progress-age) while the agent runs, OR the
//	  lowercase 'done' result (resultPreview, capped at 300) once terminal.
//
// terminal/failed DERIVE from State (never a wire bool). HONESTY (D27): thinking
// never rides the wire, so NOTHING is labeled 'thinking' — the brief, the tool
// line, and the result ARE the honest window; every absent field is omitted, not
// fabricated. nil when the selection resolves to no agent (a detail-less phase),
// so the pane never paints an empty gutter.
func renderWorkflowAgentDetail(width int, j WorkflowJourney, now time.Time, selPhase, selAgent int, stallOK bool) []string {
	if selPhase < 0 || selPhase >= len(j.Phases) {
		return nil
	}
	// The pane addresses the SAME pin-running projection the row list paints
	// (charter D44): the selection resolves through visibleAgents' index map,
	// NEVER phase.Agents[selAgent] directly — a folded settled agent must not
	// shift which agent the cursor names.
	visible, indexMap, _ := visibleAgents(j.Phases[selPhase])
	if selAgent < 0 || selAgent >= len(visible) {
		return nil
	}
	a := j.Phases[selPhase].Agents[indexMap[selAgent]]

	w := width - 2
	if w < 8 {
		w = 8
	}
	indent := "  "

	// Header row: the selected agent's own line (glyph/label/model/tokens/elapsed).
	out := []string{workflowAgentLine(width, a, j.EntryStatus, now, stallOK)}

	// attempt>1 retry chip FIRST.
	if a.Attempt > 1 {
		out = append(out, indent+badgeStyle.Render(fmt.Sprintf("attempt %d", a.Attempt)))
	}

	// 'about' — the brief, wrapped (omit when absent/blank).
	if a.PromptPreview != nil {
		out = append(out, labeledWrap(indent, "about", *a.PromptPreview, w)...)
	}

	// NOW / DONE are mutually exclusive, keyed on the DERIVED terminal state.
	if workflowStateTerminal(a.State) {
		// DONE — the settled result, capped at 300 (verbatim, not re-parsed).
		if a.ResultPreview != nil {
			out = append(out, labeledWrap(indent, "done", truncate(strings.TrimSpace(*a.ResultPreview), 300), w)...)
		}
	} else if a.LastToolName != nil || a.LastToolSummary != nil {
		// NOW — the live tool line: a bare '▸' (no label), the tool name, its
		// one-line summary, and the coarse progress age — each only when carried.
		name := derefString(a.LastToolName)
		summary := derefString(a.LastToolSummary)
		age := ""
		if a.LastProgressAt != nil {
			age = formatElapsed(now.Sub(time.UnixMilli(*a.LastProgressAt)))
		}
		line := "▸"
		if name != "" {
			line += " " + titleStyle.Render(name)
		}
		if summary != "" {
			budget := w - lipgloss.Width("▸ "+name) - lipgloss.Width(" · "+age) - 4
			if budget < 8 {
				budget = 8
			}
			line += " " + dimStyle.Render("· "+truncate(summary, budget))
		}
		if age != "" {
			line += " " + dimStyle.Render("· "+age)
		}
		out = append(out, indent+line)
	}
	return out
}

// labeledWrap emits a dim-labeled, wrapped text block indented under the agent
// header — 'about <brief>' / 'done <result>'. The label dims; continuation lines
// align under the indent. nil when the text is blank, so an absent field is
// omitted (never a bare label with nothing after it).
func labeledWrap(indent, label, text string, w int) []string {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	inner := w - lipgloss.Width(indent)
	if inner < 8 {
		inner = 8
	}
	// The label prefixes the FIRST line, so reserve its width up front — otherwise
	// body[0]+label overruns the pane width by label+1 columns and the terminal
	// wraps the tail ugly (house discipline: workflowAgentLine budgets its label
	// the same way so glyph/meta/elapsed keep their seats).
	first := inner - lipgloss.Width(label) - 1
	if first < 8 {
		first = 8
	}
	body := wrapFirst(text, first, inner)
	if len(body) == 0 {
		return nil
	}
	body[0] = dimStyle.Render(label) + " " + body[0]
	out := make([]string, 0, len(body))
	for _, ln := range body {
		out = append(out, indent+ln)
	}
	return out
}

// derefString reads a *string as "" when nil — an absent field is empty, never a
// panic.
func derefString(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// renderWorkflowStrip is the collapsed one-liner: '○ <label>' left; the
// Claude-Code-style '<done>/<total> agents done · <elapsed> · ↓<tokens>' right.
// done counts SETTLED agents (success + failed — an honest 13/17); elapsed and
// tokens are omitted entirely when the wire carries no figure (charter D15).
// A focused strip swaps the glyph for a bold ❯ so the operator sees which zone
// the arrows drive.
func renderWorkflowStrip(width int, wf *Workflow, j WorkflowJourney, now time.Time, focused bool) string {
	right := fmt.Sprintf("%d/%d agents done", j.Settled(), j.AgentsTotal)
	if el, ok := workflowElapsed(wf, j, now); ok {
		right += " · " + formatElapsed(el)
	}
	if j.HasTokens {
		right += " · ↓" + formatTokens(j.Tokens)
	}
	return workflowStripLine(width, badgeStyle.Render("○"), wf.Label, right, focused)
}

// renderWorkflowStripSummary paints the collapsed strip from the COMPACT live
// summary (wsc-bl-workflow-sse) — the mid-turn SSE `event: workflow` delta, so
// the counters and elapsed advance WITHIN a turn without a rail refetch (the D13
// lag removed). Same layout and honesty rules as the rail-fold strip: settled =
// AgentsDone (done+failed, wire-carried), elapsed omitted when the wire has no
// StartedAt, tokens only when > 0 (never synthesised, D15).
func renderWorkflowStripSummary(width int, wf *SessionWorkflow, now time.Time, focused bool) string {
	right := fmt.Sprintf("%d/%d agents done", wf.AgentsDone, wf.AgentsTotal)
	if el, ok := summaryElapsed(wf, now); ok {
		right += " · " + formatElapsed(el)
	}
	if wf.Tokens > 0 {
		right += " · ↓" + formatTokens(wf.Tokens)
	}
	return workflowStripLine(width, badgeStyle.Render("○"), wf.Label, right, focused)
}

// needsYouBanner is the warn-token needs-you phrase shared by the collapsed strip
// (its right cluster) and the expanded panel's banner line, so the two can never
// drift: '⏸ needs you — approval pending'. The pending gate is truth the TUI
// already tracks (answerableCards ∩ a live workflow) — zero new wire.
const needsYouBanner = "⏸ needs you — approval pending"

// renderWorkflowNeedsYouStrip is the collapsed strip in the needs-you cockpit
// state (wsc-needs-you): a live workflow whose session is blocked on a pending
// answerable card. The counter cluster is REPLACED by the warn needs-you banner —
// a single, unmissable state, never a counter shown alongside a pending gate. The
// focus glyph still wins when the strip owns the arrows (the operator sees which
// zone Enter drives — Enter here jumps to the card).
func renderWorkflowNeedsYouStrip(width int, label string, focused bool) string {
	return workflowStripLine(width, warnStyle.Render("⏸"), label, warnStyle.Render(needsYouBanner), focused)
}

// workflowStripLine lays out the collapsed one-liner: a focus-aware glyph +
// truncated label on the left, the styled cluster right-aligned. The label yields
// columns first so the cluster always keeps its right-edge seat. Shared by the
// live-summary path, the rail-fold fallback, and the needs-you banner so they can
// never drift. The caller supplies the base glyph; a focused strip always swaps it
// for the bold ❯ so the operator sees which zone the arrows drive.
func workflowStripLine(width int, glyph, label, right string, focused bool) string {
	if focused {
		glyph = focusBar.Render("❯")
	}
	maxLabel := width - lipgloss.Width(right) - 5
	if maxLabel < 8 {
		maxLabel = 8
	}
	label = truncate(label, maxLabel)
	if focused {
		label = titleStyle.Render(label)
	}
	left := glyph + " " + label
	pad := width - lipgloss.Width(left) - lipgloss.Width(right)
	if pad < 2 {
		pad = 2
	}
	return left + strings.Repeat(" ", pad) + dimStyle.Render(right)
}

// summaryElapsed is workflowElapsed's compact-summary twin (wsc-bl-workflow-sse):
// live = now − StartedAt; terminal = EndedAt − StartedAt. false when a figure is
// absent from the wire — the strip omits elapsed, never synthesizes it (D15).
func summaryElapsed(wf *SessionWorkflow, now time.Time) (time.Duration, bool) {
	if wf == nil || wf.StartedAt == nil {
		return 0, false
	}
	start := time.UnixMilli(*wf.StartedAt)
	if !wf.Terminal {
		return now.Sub(start), true
	}
	if wf.EndedAt != nil {
		return time.UnixMilli(*wf.EndedAt).Sub(start), true
	}
	return 0, false
}

// workflowDetailMaxAgents caps the agents pane so a 20-surveyor Explore phase
// never eats the transcript — the overflow row says how many more are running.
const workflowDetailMaxAgents = 8

// ── D40: the inline result snippet extractor ─────────────────────────────────

// agentSnippetKeys is the headline-key priority order (charter D40): the first
// key PRESENT wins, whole-value — the summary/title IS the headline, so no
// first-sentence surgery happens on key-extracted values.
var agentSnippetKeys = [...]string{"direction", "summary", "title", "test_summary", "evidence", "notes"}

// agentSnippetKeyRes are the truncation-tolerant per-key extractors:
// "<k>"\s*:\s*"((?:\\.|[^"\\])*) — the corpus truth is 817/820 real
// resultPreview values clip at exactly 401 chars (never parseable JSON), so the
// unanchored escape-aware body capture runs to end-of-string when the closing
// quote was clipped away. RE2 handles the unterminated tail without backtracking.
var agentSnippetKeyRes = func() [len(agentSnippetKeys)]*regexp.Regexp {
	var res [len(agentSnippetKeys)]*regexp.Regexp
	for i, k := range agentSnippetKeys {
		res[i] = regexp.MustCompile(`"` + k + `"\s*:\s*"((?:\\.|[^"\\])*)`)
	}
	return res
}()

// agentSnippet extracts the one-line headline of a settled agent's persisted
// resultPreview (wave session-card charter D40) — pure PRESENTATION of
// wire-carried text, never synthesis. The ladder: (a) blank → ""; (b) a
// defensive whole-parse for the rare untruncated JSON object (first present
// key wins); (c) the truncation-tolerant key-regex over the same keys; (d) a
// bare-prose first-line/first-sentence fallback for non-JSON payloads. Every
// branch funnels through cleanSnippet, and a JSON-shaped payload that yields no
// key returns "" — the row renders NOTHING rather than brace-noise.
func agentSnippet(preview string) string {
	s := strings.TrimSpace(preview)
	if s == "" {
		return ""
	}
	if strings.HasPrefix(s, "{") {
		// (b) whole-parse — exercised by the synthetic untruncated fixture; zero
		// real captures reach it (they all clip mid-object).
		var obj map[string]any
		if json.Unmarshal([]byte(s), &obj) == nil {
			for _, k := range agentSnippetKeys {
				if v, ok := obj[k].(string); ok {
					if out := cleanSnippet(v); out != "" {
						return out
					}
				}
			}
			return ""
		}
		// (c) key-regex over the clipped tail.
		for i := range agentSnippetKeys {
			if got := agentSnippetKeyRes[i].FindStringSubmatch(s); got != nil {
				if out := cleanSnippet(unescapeJSONFragment(got[1])); out != "" {
					return out
				}
			}
		}
		return "" // JSON-shaped but headline-less — never brace-noise
	}
	// (d) bare prose: first line, leading markdown markers stripped, first
	// sentence — the ONLY branch that does sentence extraction.
	line := strings.TrimSpace(strings.TrimLeft(firstLine(s), "#* "))
	if i := strings.Index(line, ". "); i > 0 {
		line = line[:i+1]
	}
	return cleanSnippet(line)
}

// unescapeJSONFragment resolves the escape sequences a regex-captured JSON
// string body still carries (\n \t \" \\ \/ — newlines/tabs become spaces for
// the one-line snippet) and DROPS a dangling trailing backslash left by a
// clip mid-escape.
func unescapeJSONFragment(s string) string {
	if n := len(s); n > 0 && s[n-1] == '\\' {
		i := n
		for i > 0 && s[i-1] == '\\' {
			i--
		}
		if (n-i)%2 == 1 {
			s = s[:n-1]
		}
	}
	return strings.NewReplacer(
		`\n`, " ", `\t`, " ", `\r`, " ", `\"`, `"`, `\\`, `\`, `\/`, "/",
	).Replace(s)
}

// cleanSnippet normalizes an extracted headline to one honest line: real
// newlines/tabs become spaces, whitespace collapses, and a trailing clip
// ellipsis is dropped (the width truncate re-adds its own when needed, D31).
func cleanSnippet(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	s = strings.TrimSuffix(strings.TrimSuffix(s, "…"), "...")
	return strings.TrimSpace(s)
}

// ── D41: the no-progress badge ───────────────────────────────────────────────

// workflowStallAfter is the D41 no-progress threshold: a non-terminal agent
// whose last wire-carried progress tick is older wears the warn badge.
const workflowStallAfter = 90 * time.Second

// agentStallBadge is the honesty-shaped stall signal (charter D41): for a
// NON-terminal agent whose lastProgressAt is older than workflowStallAfter it
// returns 'no progress since <HH:MM>' — a statement true under ANY staleness of
// the rail (lastProgressAt refreshes only at the turn-boundary refetch sites),
// where an absolute 'stalled' verdict would fabricate one. Agents without the
// timestamp get no badge (never synthesized), and bp carries no pid signal so
// no crashed/stopped/dead state exists anywhere.
func agentStallBadge(a WorkflowNode, now time.Time) string {
	if workflowStateTerminal(a.State) || a.LastProgressAt == nil {
		return ""
	}
	at := time.UnixMilli(*a.LastProgressAt)
	if now.Sub(at) <= workflowStallAfter {
		return ""
	}
	return "no progress since " + at.Format("15:04")
}

// renderWorkflowDetail is the Enter-expanded two-pane detail: phases left
// (glyph + title + settled/total), the SELECTED phase's agents right (glyph +
// pair-grammar label + model family · tokens + elapsed). Selection is the ▸
// row; the footer hint row is owned by chatFooter (it swaps the hints line).
func renderWorkflowDetail(width int, wf *Workflow, j WorkflowJourney, now time.Time, sel int, stallOK bool) []string {
	if len(j.Phases) == 0 {
		return nil
	}
	if sel < 0 || sel >= len(j.Phases) {
		sel = 0
	}
	leftW := clamp(width/3, 16, 30)
	rightW := width - leftW - 3
	if rightW < 8 {
		rightW = 8
	}

	left := make([]string, 0, len(j.Phases))
	for i, p := range j.Phases {
		cursor := "  "
		title := truncate(p.Title, leftW-9)
		if i == sel {
			cursor = focusBar.Render("▸ ")
			title = titleStyle.Render(title)
		}
		row := cursor + workflowPhaseGlyph(p) + " " + title
		if p.Total > 0 {
			row += dimStyle.Render(fmt.Sprintf(" %d/%d", p.Settled(), p.Total))
		}
		if pad := leftW - lipgloss.Width(row); pad > 0 {
			row += strings.Repeat(" ", pad)
		}
		left = append(left, row)
	}

	right := workflowAgentLines(rightW, j.Phases[sel], j.EntryStatus, now, stallOK)

	rows := len(left)
	if len(right) > rows {
		rows = len(right)
	}
	sep := dimStyle.Render(" │ ")
	blank := strings.Repeat(" ", leftW)
	out := make([]string, 0, rows)
	for i := 0; i < rows; i++ {
		l, r := blank, ""
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			r = right[i]
		}
		out = append(out, l+sep+r)
	}
	return out
}

// workflowAgentLines paints the selected phase's agents pane over the
// visibleAgents pin-running projection (charter D44): running agents are never
// folded, settled rows carry their D40 result snippet as a dimmed second line,
// and the overflow row counts the folded SETTLED agents (suffixing the hidden
// running count in the running>cap edge). An agentless phase says so honestly
// instead of rendering an empty gutter.
func workflowAgentLines(w int, p WorkflowPhase, entryStatus string, now time.Time, stallOK bool) []string {
	if len(p.Agents) == 0 {
		return []string{dimStyle.Render(truncate("no agents in this phase yet", w))}
	}
	visible, _, settledOverflow := visibleAgents(p)
	out := make([]string, 0, len(visible)+1)
	hiddenRunning := p.Running
	for _, a := range visible {
		out = append(out, workflowAgentLine(w, a, entryStatus, now, stallOK))
		if !workflowStateTerminal(a.State) {
			hiddenRunning--
			continue
		}
		// D40: the inline result snippet — a dimmed second line under SETTLED rows
		// only (running rows never carry one: no live churn). The extracted
		// headline goes FULL to the width truncate (D31); "" renders nothing.
		if a.ResultPreview != nil {
			if snip := agentSnippet(*a.ResultPreview); snip != "" {
				out = append(out, dimStyle.Render(truncate("    "+snip, w)))
			}
		}
	}
	if settledOverflow > 0 || hiddenRunning > 0 {
		row := fmt.Sprintf("  … +%d more", settledOverflow)
		if hiddenRunning > 0 {
			row += fmt.Sprintf(" (%d running)", hiddenRunning)
		}
		out = append(out, dimStyle.Render(row))
	}
	return out
}

// workflowAgentLine is one agent row: state glyph · label (pair grammar: dim
// kind + bold rest) · optional D41 no-progress badge · model family · tokens,
// with the elapsed right-aligned — each figure rendered ONLY when the wire
// carries it (charter D15).
func workflowAgentLine(w int, a WorkflowNode, entryStatus string, now time.Time, stallOK bool) string {
	elapsed := ""
	if el, ok := agentElapsed(a, entryStatus, now); ok {
		elapsed = formatElapsed(el)
	}

	stall := ""
	if stallOK {
		stall = agentStallBadge(a, now)
	}

	meta := ""
	if fam := modelFamily(a.Model); fam != "" {
		meta = fam
	}
	if a.Tokens != nil {
		if meta != "" {
			meta += " · "
		}
		meta += formatTokens(*a.Tokens)
	}

	// budget the plain label so glyph+badge+meta+elapsed keep their seats
	budget := w - 3 - lipgloss.Width(elapsed)
	if meta != "" {
		budget -= lipgloss.Width(meta) + 2
	}
	if stall != "" {
		budget -= lipgloss.Width(stall) + 2
	}
	if budget < 6 {
		budget = 6
	}
	label := a.Label
	if label == "" {
		label = "agent"
	}
	var labelOut string
	if kind, rest, pair := workflowLabelParts(label); pair && lipgloss.Width(label) <= budget {
		labelOut = dimStyle.Render(kind+":") + titleStyle.Render(rest)
	} else {
		labelOut = truncate(label, budget)
	}

	line := workflowAgentGlyph(a) + " " + labelOut
	if stall != "" {
		line += "  " + noticeStyle.Render(stall)
	}
	if meta != "" {
		line += "  " + dimStyle.Render(meta)
	}
	if elapsed != "" {
		if pad := w - lipgloss.Width(line) - lipgloss.Width(elapsed); pad > 0 {
			line += strings.Repeat(" ", pad)
		} else {
			line += " "
		}
		line += dimStyle.Render(elapsed)
	}
	return line
}

// workflowPhaseGlyph is the phase-state glyph of the D58 truth table: done ✓,
// active ❯ (the breathing frontier), interrupted ✕, skipped/unreached a dim ·,
// future its dim index — the same vocabulary Studio's journey renders.
func workflowPhaseGlyph(p WorkflowPhase) string {
	switch p.Status {
	case "done":
		return allowStyle.Render("✓")
	case "active":
		return badgeStyle.Render("❯")
	case "interrupted":
		return noticeStyle.Render("✕")
	case "future":
		return dimStyle.Render(fmt.Sprintf("%d", p.Index))
	default: // skipped / unreached
		return dimStyle.Render("·")
	}
}

// workflowAgentGlyph mirrors Studio's rail_agent_glyph: failed ✕, terminal ✓,
// live ● — through the SAME ported state sets, never an enumeration.
func workflowAgentGlyph(a WorkflowNode) string {
	switch {
	case workflowStateFailed(a.State):
		return noticeStyle.Render("✕")
	case workflowStateTerminal(a.State):
		return allowStyle.Render("✓")
	default:
		return badgeStyle.Render("●")
	}
}

// formatElapsed is the compact wall-clock duration the panel renders: 42s,
// 3m12s, 1h04m. Only ever called with a wire-derived duration (charter D15).
func formatElapsed(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	s := int(d.Seconds())
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm%02ds", s/60, s%60)
	default:
		return fmt.Sprintf("%dh%02dm", s/3600, (s%3600)/60)
	}
}

// cardBodyLines renders the interactive card's BODY (charter D35, Law 1). The
// visual is now a typed PortableDoc block (chat-approval/chat-question/chat-plan)
// the server carries on the row — decoded through the SAME Decode -> RenderDoc
// seam the reader and the assistant reply body use, so the card body reads
// identically in Studio and the terminal. The card's ANSWERABILITY is NOT here:
// it stays on the envelope (cardView's footer), keyed off role+request_id+
// approval_status. A row with no block (a mid-persist frame or a legacy row)
// degrades to the metadata/source preview, never a blank — the same forward-
// compat tolerance the assistant path shows.
func cardBodyLines(w int, msg Message) []string {
	blocks, err := pdrender.Decode([]byte(msg.Blocks))
	if err == nil && len(blocks) > 0 {
		doc := chatRegistry.RenderDoc(blocks, pdrender.RenderCtx{Width: w, Profile: chatProfile})
		out := make([]string, 0, strings.Count(doc, "\n")+1)
		for _, ln := range strings.Split(doc, "\n") {
			out = append(out, strings.TrimRight(ln, " "))
		}
		return out
	}
	return wrap(cardBody(msg), w)
}

// cardBody extracts a display string for a card row: a well-known metadata
// field if present, else the source markdown. The fallback body when a row
// carries no typed block (cardBodyLines).
func cardBody(msg Message) string {
	for _, k := range []string{"prompt", "question", "summary", "plan", "text"} {
		if v, ok := msg.Metadata[k]; ok {
			if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
				return s
			}
		}
	}
	return strings.TrimSpace(msg.SourceMarkdown)
}

// ── the epic-cycle session card (wsc D3/D12) ─────────────────────────────────
//
// The session list grows exactly two extra lines when a row carries a workflow
// summary — the SAME two lines the Studio sidebar card shows (parity law). The
// data is the COMPACT pre-folded wire summary (apiclient.ChatWorkflowSummary),
// decoded straight off the list endpoint: there is NO Go fold and NO rail decode
// here (decodeRail is untouched for lists). A plain session carries no summary
// and renders exactly as today — the minimalism contract (plain chats pay zero).

// workflowCardLines renders the two epic-cycle card lines for a workflow row,
// each pre-indented two columns so it aligns under the session title past the
// picker's cursor gutter. Line one: the phase ticks + the phase word (or the
// terminal outcome) + the settled/total agent counter (13/17, Claude-Code-style),
// plus the token total when the wire carries one. Line two (only when the wire
// carries the SIBLING epic goal, wsc D9): the epic title + slices-done/total +
// wave_status. Returns nil for a nil summary — the caller adds nothing, so a
// non-workflow row is byte-identical to today.
func workflowCardLines(w int, wf *SessionWorkflow, epic *EpicGoal, pending int) []string {
	if wf == nil {
		return nil
	}
	out := []string{"  " + workflowTickLine(w-2, wf, pending)}
	if epic != nil {
		out = append(out, "  "+workflowGoalLine(w-2, epic))
	}
	return out
}

// workflowTickLine paints the phase ticks + phase/outcome + settled/total counter
// (+ tokens when present). Elapsed is deliberately omitted on list rows (D15 —
// there is no per-row clock in the picker); tokens render only when Tokens > 0
// (never synthesised). When the session is blocked on a pending gate (pending>0)
// and the run is still live, the needs-you pill REPLACES the live status word —
// needs-you > working, a single badge in the word slot (never a new line, never
// side-by-side) — so the picker surfaces "this session is waiting on you" at a
// glance. A terminal wave is never needs-you: its lifecycle word still wins.
func workflowTickLine(w int, wf *SessionWorkflow, pending int) string {
	var ticks strings.Builder
	for _, s := range phaseTicks(wf) {
		ticks.WriteString(tickGlyph(s))
	}
	counter := fmt.Sprintf("%d/%d", wf.AgentsDone, wf.AgentsTotal)
	word := wf.Phase
	switch {
	case wf.Terminal:
		// the wire's lifecycle word verbatim ("completed"/"interrupted") — an
		// honest settle, never a stuck phase word
		word = wf.Outcome
		if word == "" {
			word = "completed"
		}
	case pending > 0:
		// the needs-you pill supersedes the live phase word (needs-you > working)
		word = warnStyle.Render("⏸ needs you")
	case word == "":
		word = "working"
	}
	line := ticks.String() + dimStyle.Render(" · ") + word + dimStyle.Render(" · ") + counter
	if wf.Tokens > 0 {
		line += dimStyle.Render("  ·  ↓" + formatTokens(wf.Tokens) + " tok")
	}
	return truncate(line, w)
}

// workflowGoalLine paints the epic-goal card line — the same vocabulary the
// Studio sidebar renders: ↳ epic title · slices done/total · wave_status
// heartbeat when the ledger carries one (wsc D9). "PRs open" is intentionally
// absent (D8 — no data source; never fabricated).
func workflowGoalLine(w int, g *EpicGoal) string {
	title := strings.TrimSpace(g.Title)
	if title == "" {
		title = "epic goal"
	}
	meta := fmt.Sprintf("%d/%d slices", g.SlicesDone, g.SlicesTotal)
	if hb := strings.TrimSpace(g.WaveStatus); hb != "" {
		meta += " · " + hb
	}
	line := dimStyle.Render("↳ ") + title + dimStyle.Render("  ·  "+meta)
	return truncate(line, w)
}

// phaseTicks is the phase states to draw. It prefers the wire ticks verbatim
// (the server's D3 projection — always present on the real wire); when they are
// absent it derives them from PhaseIndex/PhasesTotal — presentation-only
// geometry, NOT a rail fold — so a summary that carries only the phase counters
// still shows an honest strip. PhaseIndex is 1-based (the journey's phase
// index); 0 means "no breathing phase named".
func phaseTicks(wf *SessionWorkflow) []string {
	if len(wf.Ticks) > 0 {
		return wf.Ticks
	}
	total := wf.PhasesTotal
	if total <= 0 {
		total = 7
	}
	ticks := make([]string, total)
	for i := range ticks {
		switch {
		case wf.Terminal:
			ticks[i] = "done"
		case i+1 < wf.PhaseIndex:
			ticks[i] = "done"
		case i+1 == wf.PhaseIndex:
			ticks[i] = "active"
		default:
			ticks[i] = "future"
		}
	}
	return ticks
}

// tickGlyph is the per-phase glyph over the journey's six-state vocabulary:
// done ● (evergreen), active ◉ (the live phase), interrupted ✕ (the dead
// frontier — honesty over symmetry), and future/skipped/unreached a dim ○.
// Unknown states render dim too (forward-compat, never a crash) — the same
// tolerance the rest of the decoder shows.
func tickGlyph(state string) string {
	switch state {
	case "done":
		return tickDoneStyle.Render("●")
	case "active":
		return tickActiveStyle.Render("◉")
	case "interrupted":
		return noticeStyle.Render("✕")
	default:
		return dimStyle.Render("○")
	}
}

// ── the sessions picker ──────────────────────────────────────────────────────

// renderPicker paints the launch screen (charter: launch = list/resume/new).
// Honest states: loading, error, empty, and the list — a "+ new session" row is
// always the first cursor stop so a cold account can still start.
func (m Model) renderPicker() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("bp chat") + dimStyle.Render("  ·  "+serverHost(m.cfg.BaseURL)) + "\n")
	// The context identity band (context.go): which host, which server, which
	// workspace/project/dataset, which repo root. It sits ABOVE the rule so it
	// reads as part of the client's own identity rather than as a roster row,
	// and pickerAvail charges the roster budget for however many lines it took.
	for _, l := range m.contextLines(m.width) {
		b.WriteString(l + "\n")
	}
	b.WriteString(dimStyle.Render(strings.Repeat("─", clamp(m.width, 8, 80))) + "\n\n")

	rows := m.pickerRows()
	switch {
	case m.loading && len(m.sessions) == 0:
		b.WriteString(dimStyle.Render("Loading sessions…"))
	case m.pickErr != "":
		b.WriteString(noticeStyle.Render("Could not load sessions: "+m.pickErr) + "\n")
		b.WriteString(dimStyle.Render("press r to retry · q to quit"))
	default:
		// Window the ROW BLOCK ONLY by summed PHYSICAL lines (a workflow row is
		// one navigable entry spanning three lines) — the header above and the
		// notice/footer below always paint.
		b.WriteString(rowWindowBlock(rows, m.pickerAvail(), m.pickTop, m.pickCursor, m.height <= 0))
		if len(m.sessions) == 0 {
			b.WriteString("\n" + dimStyle.Render("No sessions yet — the row above starts your first one."))
		}
	}

	// The fleet stream's terminal give-up (D54h) degrades to one honest notice
	// line — the cold list keeps the herd usable, states just stop moving.
	if m.fleetNotice != "" {
		b.WriteString("\n" + noticeStyle.Render(m.fleetNotice))
	}

	// The picker hint line (charter D71 fold): advertise the full navigation
	// vocabulary the roster actually supports — pgup/pgdn + g/G paging shipped in
	// #5896 but never reached this line, `?` opens the key-reference overlay, and
	// `a`/`s` are the two halves of the archive door (dismiss here, restore from
	// the shelf) — a screen the hint line never names is a screen nobody finds.
	b.WriteString("\n\n" + dimStyle.Render("↑/↓ move · pgup/pgdn · g/G ends · enter attach · n new · a archive · s shelf · r refresh · ? help · q quit"))
	return b.String()
}

// rowWindowBlock paints a windowed, cursor-highlighted row block with the ↑/↓
// overflow affordances — the shared body of BOTH list screens (the herd picker
// and the archived shelf), so their windowing and highlight behaviour cannot
// drift apart. Budgets count PHYSICAL lines, never row indices (a workflow row
// is one navigable entry spanning three lines). showAll (a bare test Model with
// no WindowSizeMsg yet, height<=0) paints every row rather than an empty frame.
func rowWindowBlock(rows []string, avail, top, cursor int, showAll bool) string {
	start, end := 0, len(rows)
	if !showAll {
		counts := rowLineCounts(rows)
		start = followTop(counts, avail, top, cursor)
		end = pickerFitEnd(counts, avail, start)
	}
	var b strings.Builder
	if start > 0 {
		b.WriteString(dimStyle.Render(fmt.Sprintf("  ↑ %d more above", start)) + "\n")
	}
	for i := start; i < end; i++ {
		prefix, line := "  ", rows[i]
		if i == cursor {
			prefix, line = youStyle.Render("▸ "), titleStyle.Render(rows[i])
		}
		b.WriteString(prefix + line + "\n")
	}
	if below := len(rows) - end; below > 0 {
		b.WriteString(dimStyle.Render(fmt.Sprintf("  ↓ %d more below", below)) + "\n")
	}
	return b.String()
}

// pickerRows is the herd home's navigable line list (herd charter D50h/D52h):
// a "+ new session" row (index 0) followed by one row per session in ATTENTION
// order (orderedSessions — blocked > stalled > working > idle). The cursor
// indexes this slice, so the shell and the paint can never disagree (the
// taskboard spine discipline) — a workflow row is ONE navigable entry that
// happens to span extra lines, so arrow keys still stop once per session.
//
// Every session row wears the four-state pill, an honest RELATIVE age (frame
// ts / agent_state_at — NEVER a live now-line: the fleet wire carries no
// activity line by the never-content law, D50h) and the session's cost. A
// plain (workflow-less) row stays ONE physical line; a session running an epic
// cycle grows the same two wsc card lines the Studio sidebar shows (wsc
// D3/D12, UNCHANGED by the herd layer).
func (m Model) pickerRows() []string {
	rows := []string{"+ new session"}
	now := m.clock()
	for _, s := range m.orderedSessions() {
		row := m.herdRowLine(s, now)
		if extra := workflowCardLines(clamp(m.width, 8, 100), s.Workflow, s.Epic, s.PendingApprovals); len(extra) > 0 {
			row += "\n" + strings.Join(extra, "\n")
		}
		rows = append(rows, row)
	}
	return rows
}

// ── picker windowing (cursor-follow viewport) ────────────────────────────────
//
// The picker windows its ROW BLOCK the way the taskboard windows its spine
// (windowSpine): a viewport clipped to the terminal, ↑/↓ "N more" affordances
// for hidden overflow, and a top that slides so the cursor row never leaves
// view. Rows are variable-HEIGHT here (a workflow session is one navigable row
// spanning three physical lines), so all budgets count physical lines, never
// row indices.

// rowLineCounts is each picker row's physical-line span (1 + embedded
// newlines) — the unit every windowing budget is charged in.
func rowLineCounts(rows []string) []int {
	counts := make([]int, len(rows))
	for i, r := range rows {
		counts[i] = strings.Count(r, "\n") + 1
	}
	return counts
}

// pickerAvail is the physical-line budget for the row block: the frame minus
// the chrome renderPicker paints outside the loop (title + rule + blank above;
// two footer lines below; one more when the fleet notice is up). Floored at 1
// so a pathologically short terminal still paints the cursor row — never an
// empty list.
func (m Model) pickerAvail() int {
	// The context band is variable-height (it packs to the terminal width), so
	// the budget asks it how tall it is rather than assuming a line. Same
	// measure the paint uses — a divergence here is how a frame overflows.
	chrome := 6 + len(m.contextLines(m.width))
	if m.fleetNotice != "" {
		chrome++
	}
	avail := m.height - chrome
	if avail < 1 {
		avail = 1
	}
	return avail
}

// pickerFitEnd is the exclusive end row of the window starting at top: rows
// are admitted while their summed physical lines fit the budget, with one line
// re-charged per more-indicator (↑ when top > 0, ↓ when rows remain below).
// At least one row is always admitted so a row taller than the whole budget
// (workflow card on a tiny terminal) still paints rather than looping forever.
func pickerFitEnd(counts []int, avail, top int) int {
	fit := func(budget int) int {
		end, used := top, 0
		for end < len(counts) && used+counts[end] <= budget {
			used += counts[end]
			end++
		}
		return end
	}
	budget := avail
	if top > 0 {
		budget-- // the ↑ indicator line
	}
	end := fit(budget)
	if end < len(counts) {
		end = fit(budget - 1) // the ↓ indicator line
	}
	if end <= top {
		end = top + 1
	}
	return end
}

// followTop slides a stored viewport top the minimum distance that keeps the
// cursor row's FULL physical-line span inside the window (cursor-follow). Pure
// and list-agnostic: the picker and the shelf both window through it, so there
// is ONE cursor-follow law in the package rather than a forked copy per screen.
func followTop(counts []int, avail, top, cursor int) int {
	if len(counts) == 0 {
		return 0
	}
	cursor = clamp(cursor, 0, len(counts)-1)
	top = clamp(top, 0, len(counts)-1)
	if cursor < top {
		return cursor
	}
	for top < cursor && cursor >= pickerFitEnd(counts, avail, top) {
		top++
	}
	return top
}

// followPickTop is the herd home's effective viewport top: render calls it for
// the paint, the key/sync paths persist it back to m.pickTop so paging
// accumulates. m.height<=0 means show-all (top 0).
func (m Model) followPickTop() int {
	if m.height <= 0 {
		return 0
	}
	rows := m.pickerRows()
	if len(rows) == 0 {
		return 0
	}
	return followTop(rowLineCounts(rows), m.pickerAvail(), m.pickTop, m.pickCursor)
}

// pickerPage is one window's worth of navigable rows — the pgup/pgdn stride.
// Show-all (no height yet) pages the whole roster, i.e. a full jump.
func (m Model) pickerPage() int {
	if m.height <= 0 {
		return len(m.sessions)
	}
	rows := m.pickerRows()
	if len(rows) == 0 {
		return 1
	}
	counts := rowLineCounts(rows)
	start := m.followPickTop()
	n := pickerFitEnd(counts, m.pickerAvail(), start) - start
	if n < 1 {
		n = 1
	}
	return n
}

// herdRowLine paints one session's herd row — one physical line: the
// four-state pill (+ stall badge), the title, and the dim meta tail
// (messages · pending · cost · relative age).
func (m Model) herdRowLine(s SessionSummary, now time.Time) string {
	row := m.herd.herdRowFor(s.ID)
	title := herdRowTitle(row, s)
	if title == "" {
		title = "untitled session"
	}
	meta := fmt.Sprintf("%d msg", s.MessageCount)
	if s.PendingApprovals > 0 {
		meta += fmt.Sprintf(" · %d pending", s.PendingApprovals)
	}
	if c := formatCost(s.TotalCostUSD); c != "" {
		meta += " · " + c
	}
	if age := m.herdAge(row, s, now); age != "" {
		meta += " · " + age
	}
	return fmt.Sprintf("%s %-40s %s", herdPill(row, now), truncate(title, 40), dimStyle.Render(meta))
}

// herdRowTitle is the row's honest title: the HERD's held title when it holds
// one, else the cold list's. The herd is the fresher source by construction —
// herdSeed/herdSnapshot copy every non-blank list/snapshot title into the row,
// and the live D69h `title` frame lands THERE and nowhere else, so a session
// renamed after the last list read (the async titler, a rename from Studio)
// updates the row in place instead of waiting for the next roster refetch.
func herdRowTitle(row HerdRow, s SessionSummary) string {
	if t := strings.TrimSpace(row.Title); t != "" {
		return t
	}
	return strings.TrimSpace(s.Title)
}

// herdPill is the four-state pill (working|blocked|idle|unknown), padded to a
// fixed cell width so titles align down the list. A stalled working session
// (D53h: no frame past herdStallAfter, computed FRESH at render time) wears
// the warn badge in place of the plain working word — the honest "it may be
// wedged" signal the sort also keys on.
func herdPill(row HerdRow, now time.Time) string {
	const w = 11
	switch {
	case row.AgentState == "blocked":
		return padCell(warnStyle.Render("⏸ blocked"), w)
	case row.AgentState == "working" && herdStalled(row, now):
		return padCell(warnStyle.Render("⚠ stalled"), w)
	case row.AgentState == "working":
		return padCell(tickActiveStyle.Render("● working"), w)
	case row.AgentState == "idle":
		return padCell(dimStyle.Render("○ idle"), w)
	}
	return padCell(dimStyle.Render("? unknown"), w)
}

// herdAge is the row's honest relative liveness age — the last frame the herd
// actually saw (flip or heartbeat), else the cold list's last_active_at.
// NEVER a live now-line (the fleet wire carries none by design, D50h).
func (m Model) herdAge(row HerdRow, s SessionSummary, now time.Time) string {
	if !row.LastFrameAt.IsZero() {
		return relAge(row.LastFrameAt, now)
	}
	return relAge(parseHerdTime(s.LastActiveAt), now)
}

// formatCost renders the session's cumulative spend; "" when the wire carries
// none (never a fabricated $0.00).
func formatCost(usd float64) string {
	if usd <= 0 {
		return ""
	}
	return fmt.Sprintf("$%.2f", usd)
}

// padCell right-pads s to w terminal cells (ANSI-aware — styled pills carry
// escape codes fmt's %-*s would count as width).
func padCell(s string, w int) string {
	if d := w - lipgloss.Width(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

// ── the archived shelf (charter D28) ─────────────────────────────────────────

// renderShelf paints the archived shelf: the sessions `a` dismissed, and the
// one key that puts them back. Honest states, the same four the picker owns —
// loading, error-with-retry, EMPTY (a shelf with nothing on it says so, it does
// not look broken), and the list.
//
// Rows wear NO attention pill on purpose. archived_at is dismissal and
// agent_state is attention, but the server keeps archived sessions out of the
// fleet snapshot entirely — so a pill here would be stale-by-construction for
// every row shelved before this process started, i.e. the screen inventing a
// liveness claim it cannot back. What the shelf shows instead is what it
// honestly knows: the title, the size of the conversation, its cost, and how
// long it has been shelved.
func (m Model) renderShelf() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("bp chat · shelf") + dimStyle.Render("  ·  archived sessions") + "\n")
	b.WriteString(dimStyle.Render(strings.Repeat("─", clamp(m.width, 8, 80))) + "\n\n")

	switch {
	case m.shelfLoading && len(m.shelf) == 0:
		b.WriteString(dimStyle.Render("Loading the shelf…"))
	case m.shelfErr != "" && len(m.shelf) == 0:
		b.WriteString(noticeStyle.Render(m.shelfErr) + "\n")
		b.WriteString(dimStyle.Render("press r to retry · esc back to the herd"))
	case len(m.shelf) == 0:
		b.WriteString(dimStyle.Render("Nothing on the shelf — `a` on the herd archives a session."))
	default:
		b.WriteString(rowWindowBlock(m.shelfRows(), m.shelfAvail(), m.shelfTop, m.shelfCursor, m.height <= 0))
		// A REFUSED restore keeps the list AND says so (the model.go law: the row
		// came back by shelf re-read, never by a guessed re-insert).
		if m.shelfErr != "" {
			b.WriteString("\n" + noticeStyle.Render(m.shelfErr))
		}
	}

	b.WriteString("\n\n" + dimStyle.Render("↑/↓ move · enter/u restore · esc back · r refresh · ? help · q quit"))
	return b.String()
}

// shelfRows is the shelf's navigable line list — one PHYSICAL line per archived
// session, in the server's own order (last_active_at desc, the same order `bp
// chat ls --archived` prints). There is no attention sort here: the herd order
// ranks by what needs you, and nothing on the shelf does.
func (m Model) shelfRows() []string {
	rows := make([]string, 0, len(m.shelf))
	now := m.clock()
	for _, s := range m.shelf {
		rows = append(rows, m.shelfRowLine(s, now))
	}
	return rows
}

// shelfRowLine paints one shelved session: the title (the herd's held title when
// it holds one — herdRowTitle, so a D69h rename reads here too) and the dim meta
// tail (messages · cost · how long shelved).
func (m Model) shelfRowLine(s SessionSummary, now time.Time) string {
	title := herdRowTitle(m.herd.herdRowFor(s.ID), s)
	if title == "" {
		title = "untitled session"
	}
	meta := fmt.Sprintf("%d msg", s.MessageCount)
	if c := formatCost(s.TotalCostUSD); c != "" {
		meta += " · " + c
	}
	if age := m.shelvedAge(s, now); age != "" {
		meta += " · shelved " + age
	}
	return fmt.Sprintf("%-40s %s", truncate(title, 40), dimStyle.Render(meta))
}

// shelvedAge is how long the row has been on the shelf — archived_at when the
// wire carries it, else the last activity we know of. Never fabricated: an
// unstamped, never-active row simply shows no age.
func (m Model) shelvedAge(s SessionSummary, now time.Time) string {
	if t := parseHerdTime(s.ArchivedAt); !t.IsZero() {
		return relAge(t, now)
	}
	return relAge(parseHerdTime(s.LastActiveAt), now)
}

// shelfAvail is the shelf's physical-line budget: the frame minus the chrome
// renderShelf paints outside the row block (title + rule + blank above; two
// footer lines below), plus one more when a refused-restore notice is up.
// Floored at 1 so a pathologically short terminal still paints the cursor row.
func (m Model) shelfAvail() int {
	chrome := 6
	if m.shelfErr != "" {
		chrome++
	}
	avail := m.height - chrome
	if avail < 1 {
		avail = 1
	}
	return avail
}

// followShelfTop is the shelf's effective viewport top — the SAME cursor-follow
// law the picker uses (followTop), never a forked copy.
func (m Model) followShelfTop() int {
	if m.height <= 0 {
		return 0
	}
	rows := m.shelfRows()
	if len(rows) == 0 {
		return 0
	}
	return followTop(rowLineCounts(rows), m.shelfAvail(), m.shelfTop, m.shelfCursor)
}

// shelfPage is one window's worth of shelf rows — the pgup/pgdn stride.
// Show-all (no height yet) pages the whole shelf, i.e. a full jump.
func (m Model) shelfPage() int {
	if m.height <= 0 {
		return len(m.shelf)
	}
	rows := m.shelfRows()
	if len(rows) == 0 {
		return 1
	}
	n := pickerFitEnd(rowLineCounts(rows), m.shelfAvail(), m.followShelfTop()) - m.followShelfTop()
	if n < 1 {
		n = 1
	}
	return n
}

// ── the conversation screen ──────────────────────────────────────────────────

// renderChat paints the conversation: header, the windowed transcript
// (follow-mode while streaming, charter), a status/notice line, and the
// composer + key hints.
func (m Model) renderChat() string {
	header := m.chatHeader()
	footer := m.chatFooter()
	rail := renderRail(m.width, m.st.Rail)

	// The rail band eats transcript height so the total frame stays fixed and the
	// composer keeps its stable bottom seat.
	bodyH := m.bodyHeight() - len(rail)
	if bodyH < 1 {
		bodyH = 1
	}
	body := m.transcriptViewport(bodyH)
	for len(body) < bodyH {
		body = append(body, "")
	}

	out := header + "\n" + strings.Join(body, "\n")
	if len(rail) > 0 {
		out += "\n" + strings.Join(rail, "\n")
	}
	return out + "\n" + footer
}

// chatHeader is the two-line title band: session title (or "untitled") + a live
// status glyph on the left, the mode/model/effort badge cluster right-aligned,
// then a rule.
func (m Model) chatHeader() string {
	title := strings.TrimSpace(m.st.Title)
	if title == "" {
		title = "untitled session"
	}
	status := ""
	switch m.st.Phase {
	case TurnStreaming, TurnWaiting:
		status = dimStyle.Render(" · streaming…")
	case TurnInterrupting:
		status = noticeStyle.Render(" · interrupting…")
	}
	line := titleStyle.Render(truncate(title, clamp(m.width-16, 8, 72))) + status
	// Right-align the badge cluster, dropping detail (effort → model → mode)
	// before ever letting the title band wrap onto a second line.
	for _, badges := range m.chatHeaderBadges() {
		gap := m.width - lipgloss.Width(line) - lipgloss.Width(badges)
		if badges != "" && gap >= 2 {
			line += strings.Repeat(" ", gap) + badges
			break
		}
	}
	rule := dimStyle.Render(strings.Repeat("─", clamp(m.width, 8, 100)))
	return line + "\n" + rule
}

// chatHeaderBadges is the right-aligned status cluster, returned as
// progressively smaller candidates (full → no effort → mode only → model only)
// so the header keeps the most load-bearing fact when width is tight. Mode
// truth prefers the reducer's observed value over the D14 continuity seed; the
// model prefers the observed wire id over the intent alias.
func (m Model) chatHeaderBadges() []string {
	rawMode := m.st.Mode
	if rawMode == "" {
		rawMode = m.mode
	}
	mode := modeBadge(rawMode)
	model := m.modelBadgeText()
	effort := ""
	if m.effortChoice != "" && m.effortChoice != "default" {
		effort = m.effortChoice
	}
	sep := dimStyle.Render(" · ")

	var out []string
	if mode != "" && model != "" && effort != "" {
		out = append(out, mode+sep+model+sep+dimStyle.Render(effort))
	}
	if mode != "" && model != "" {
		out = append(out, mode+sep+model)
	}
	if mode != "" {
		out = append(out, mode)
	}
	if mode == "" && model != "" {
		// A provider without mode switching still gets its model badge.
		out = append(out, model)
	}
	return out
}

// modeBadge renders the permission mode as the two-state product projection:
// ◇ PLAN (plan + discuss, read-only) ⇄ ▶ AUTOPILOT ("auto"). An odd raw mode
// (a resumed acceptEdits/manual/… row, or armed bypass) shows verbatim in the
// warn tone — honest, never guessed. The glyphs carry the split even in the
// NoColor profile (chatProfile).
func modeBadge(mode string) string {
	switch mode {
	case "":
		return ""
	case "plan":
		return focusBar.Render("◇ PLAN")
	case "auto":
		return allowStyle.Bold(true).Render("▶ AUTOPILOT")
	default:
		return badgeStyle.Render(mode)
	}
}

// modelBadgeText is the header's model label: the observed answering model's
// family when a turn has revealed it, else the picker intent ("Default" when
// unset — the CLI chooses).
func (m Model) modelBadgeText() string {
	id := m.st.Model
	if id == "" {
		id = m.modelChoice
	}
	if id == "" || id == "default" {
		return "Default"
	}
	return modelFamily(id)
}

// chatFooter is the three-line base: a notice/status line, the composer, and
// the key hints. The notice is the ONLY place an interrupt/error/exit speaks —
// never a full error screen (charter D11: an interrupted turn is a normal
// outcome, the session stays live).
func (m Model) chatFooter() string {
	notice := m.st.Notice
	if notice == "" {
		if m.scroll >= 0 {
			notice = dimStyle.Render("(scrolled — press End to follow)")
		} else if m.queuedCount() > 0 {
			notice = badgeStyle.Render(fmt.Sprintf("⧗ %d queued", m.queuedCount()))
		}
	} else {
		notice = noticeStyle.Render(notice)
	}

	prompt := youStyle.Render("› ")
	composer := prompt + m.composerView()

	// Esc is contextual (D51h): mid-turn it interrupts; idle it detaches back
	// to the herd — the hints say which, honestly, per frame.
	escHint := "esc interrupt"
	if m.st.Phase == TurnIdle {
		escHint = "esc herd"
	}
	hints := "enter send · " + escHint + " · ctrl+p mode · ctrl+b sessions · ctrl+c quit"
	if n := len(m.answerableCards()); n > 0 {
		// A pending card is waiting — advertise the answer keys so the affordance
		// is discoverable even when the card scrolled out of view.
		label := fmt.Sprintf("%d card waiting: ctrl+a allow · ctrl+r deny", n)
		if n > 1 {
			label += " · tab next"
		}
		hints = label + "  ·  " + hints
	}

	// The below-composer workflow panel (wave session-card charter D13/D14).
	// STRICTLY conditional: with no live workflow this function returns the
	// exact 3-line stack it always did — idle frames stay byte-identical.
	if panel := m.workflowPanelLines(); len(panel) > 0 {
		if m.focus == focusWorkflow {
			// the panel owns the arrows — the hints say so honestly (esc here
			// collapses; it never interrupts from inside the panel)
			if m.wfAgentDetail {
				hints = "↑/↓ agent · esc/← back · ctrl+c quit"
			} else if m.wfExpanded {
				hints = "↑/↓ select phase · enter agent · esc back · ctrl+c quit"
			} else {
				hints = "enter details · ↑ composer · ctrl+c quit"
			}
		} else {
			hints += " · ↓ workflow"
		}
		return notice + "\n" + composer + "\n" +
			strings.Join(panel, "\n") + "\n" + dimStyle.Render(hints)
	}
	return notice + "\n" + composer + "\n" + dimStyle.Render(hints)
}

// composerView shows the input with a block cursor, tail-truncated so a long
// draft keeps the caret visible instead of scrolling off the right edge.
func (m Model) composerView() string {
	avail := clamp(m.width-4, 8, 200)
	text := m.input
	if lipgloss.Width(text) > avail {
		// keep the tail (where the caret is)
		for lipgloss.Width(text) > avail && len(text) > 0 {
			_, size := decodeFirstRune(text)
			text = text[size:]
		}
	}
	return text + cursorStyle.Render(" ")
}

func (m Model) queuedCount() int {
	n := 0
	for _, l := range m.st.Local {
		if l.Queued {
			n++
		}
	}
	return n
}

// ── windowing ────────────────────────────────────────────────────────────────

// window is the manual line-slice viewport (charter: manual windowing, NOT
// bubbles/viewport). scroll < 0 is FOLLOW mode — the bottom of the transcript,
// so a streaming reply always stays in view. A non-negative scroll is a pinned
// top line, clamped so it can never run past the content.
func window(lines []string, height, scroll int) []string {
	if height <= 0 || len(lines) == 0 {
		return nil
	}
	if len(lines) <= height {
		return lines
	}
	maxTop := len(lines) - height
	if scroll < 0 || scroll > maxTop {
		return lines[maxTop:] // follow: pin to bottom
	}
	return lines[scroll : scroll+height]
}

// scrollAnchor is a CONTENT-relative pin (charter D80). A raw physical top line
// is not a stable address: any height change in content ABOVE it silently swaps
// the viewport (measured: an 11-line growth == 11 lines of drift, with no signal
// to the reader). The anchor addresses the top row as (block ordinal,
// intra-block line offset) — never a string match, which duplicate lines and a
// width re-wrap both defeat — so the pin is relocated against the CURRENT
// layout on every frame.
//
// set is the discriminator, not a zero-value guess: {block:0, off:0} is a real
// anchor (the Home key), so an unset anchor must be distinguishable from a pin
// at the very top.
type scrollAnchor struct {
	set   bool
	block int
	off   int
}

// anchorAt records the content anchor for a physical top line against the
// layout that top line was computed in. A top landing on the blank separator
// before block i resolves to the END of block i-1 (the last block whose start is
// <= top) — its offset simply runs one past that block's last line, which
// relocates to the same separator wherever the block moves.
func anchorAt(blockStarts []int, top int) scrollAnchor {
	if len(blockStarts) == 0 || top < 0 {
		return scrollAnchor{}
	}
	i := 0
	for j, start := range blockStarts {
		if start > top {
			break
		}
		i = j
	}
	return scrollAnchor{set: true, block: i, off: top - blockStarts[i]}
}

// resolve relocates the anchor into the CURRENT layout, returning the physical
// top line to slice at. An anchor whose block no longer exists (the transcript
// was replaced wholesale, not grown) degrades to the raw pinned index — no
// worse than the pre-anchor behaviour, and never a jump to somewhere the reader
// did not ask for.
func (a scrollAnchor) resolve(blockStarts []int, fallback, maxTop int) int {
	if !a.set || a.block < 0 || a.block >= len(blockStarts) {
		return fallback
	}
	top := blockStarts[a.block] + a.off
	if top < 0 {
		top = 0
	}
	if top > maxTop {
		top = maxTop
	}
	return top
}

// viewportTop is the physical top line window() should slice at for this frame.
//
// FOLLOW MODE IS UNTOUCHED: scroll < 0 passes straight through, so the pure
// last-N slice (and its bottom clamp) stays byte-identical — follow was already
// structurally immune to height change and gains nothing from an anchor. A pin
// carrying an anchor is RELOCATED against the current blockStarts. A pin with
// no anchor (a caller that poked m.scroll directly) keeps the old raw-index
// semantics verbatim.
func (m Model) viewportTop(blockStarts []int, maxTop int) int {
	if m.scroll < 0 || !m.anchor.set {
		return m.scroll
	}
	return m.anchor.resolve(blockStarts, m.scroll, maxTop)
}

// transcriptViewport is the windowed transcript body — the ONE place the pinned
// top is re-anchored to content before the slice. renderChat paints exactly
// this; tests read it without going through the header/footer chrome.
func (m Model) transcriptViewport(bodyH int) []string {
	all, _, blockStarts := m.transcriptAnchored(m.width, "")
	maxTop := len(all) - bodyH
	if maxTop < 0 {
		maxTop = 0
	}
	return window(all, bodyH, m.viewportTop(blockStarts, maxTop))
}

// bodyHeight is the transcript viewport row count: the frame minus the two
// header rows and the three footer rows, floored at one. The below-composer
// workflow panel eats transcript rows CONDITIONALLY (wave session-card charter
// D14): with no live workflow this stays the height-5 constant verbatim, so an
// idle session's geometry is byte-identical to the pre-panel frame.
func (m Model) bodyHeight() int {
	h := m.height - 5 - len(m.workflowPanelLines())
	if h < 1 {
		h = 1
	}
	return h
}

// maxScrollTop is the largest valid pinned-top index for the current transcript
// at the current geometry — the scroll handler clamps against it.
func (m Model) maxScrollTop() int {
	n := len(m.transcriptLines(m.width))
	bodyH := m.bodyHeight() - len(renderRail(m.width, m.st.Rail))
	if bodyH < 1 {
		bodyH = 1
	}
	top := n - bodyH
	if top < 0 {
		top = 0
	}
	return top
}

// ── small helpers ────────────────────────────────────────────────────────────

func wrap(s string, w int) []string {
	if w < 1 {
		w = 1
	}
	s = strings.TrimRight(s, " ")
	if s == "" {
		return nil
	}
	var out []string
	for _, para := range strings.Split(s, "\n") {
		if para == "" {
			out = append(out, "")
			continue
		}
		var line string
		for _, word := range strings.Fields(para) {
			switch {
			case line == "":
				line = word
			case lipgloss.Width(line)+1+lipgloss.Width(word) <= w:
				line += " " + word
			default:
				out = append(out, line)
				line = word
			}
		}
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

// wrapFirst is wrap with a narrower FIRST output line (firstW) and full-width
// continuation lines (restW) — for a labeled block whose label eats the head of
// line 0, so no physical line ever overruns the pane. Identical word/newline
// grammar to wrap otherwise.
func wrapFirst(s string, firstW, restW int) []string {
	if firstW < 1 {
		firstW = 1
	}
	if restW < 1 {
		restW = 1
	}
	s = strings.TrimRight(s, " ")
	if s == "" {
		return nil
	}
	widthOf := func(i int) int {
		if i == 0 {
			return firstW
		}
		return restW
	}
	var out []string
	for _, para := range strings.Split(s, "\n") {
		if para == "" {
			out = append(out, "")
			continue
		}
		var line string
		for _, word := range strings.Fields(para) {
			switch {
			case line == "":
				line = word
			case lipgloss.Width(line)+1+lipgloss.Width(word) <= widthOf(len(out)):
				line += " " + word
			default:
				out = append(out, line)
				line = word
			}
		}
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

func truncate(s string, w int) string {
	if w < 1 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	if w <= 1 {
		return "…"
	}
	// trim rune-wise to width-1, add ellipsis. Reserve one display cell for the
	// ellipsis and measure the ACTUAL per-rune width (a hardcoded +1 assumes the
	// next rune is a single cell, so a width-2 rune — emoji/CJK — at the boundary
	// overshoots w by one cell).
	out := ""
	for _, r := range s {
		rw := lipgloss.Width(string(r))
		if lipgloss.Width(out)+rw > w-1 {
			break
		}
		out += string(r)
	}
	return out + "…"
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func decodeFirstRune(s string) (rune, int) {
	for i, r := range s {
		if i == 0 {
			// find size by locating next rune boundary
			for j := 1; j <= 4; j++ {
				if i+j >= len(s) || isRuneStart(s[i+j]) {
					return r, j
				}
			}
			return r, 1
		}
	}
	return 0, 0
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }

// relTime renders an ISO8601 timestamp as a compact "3m"/"2h"/"5d" age, or ""
// when it cannot be parsed (honest blank, never a crash).
func relTime(iso string) string {
	return relAge(parseHerdTime(iso), time.Now())
}

// relAge is relTime's pure core with an injected clock (the herd rows render
// under the shell's frozen test clock).
func relAge(t, now time.Time) string {
	if t.IsZero() {
		return ""
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

// serverHost reduces a base URL to host[:port] for the chrome line.
// contextLines paints the launch screen's context identity band: one segment
// per field — `host <name>`, `server <url>`, `workspace/project/dataset`, and
// `repo <root>` — packed greedily onto as many lines as the width needs. It
// PACKS rather than truncating because every field is load-bearing: a band that
// drops "dataset" off the right edge at 80 columns answers the question wrong
// by omission. Only a single segment wider than the whole line is truncated,
// and then the ellipsis says so.
//
// A field whose config claim and actual connection DISAGREE (ContextField.
// Mismatch) leads with ⚠ and wears the warn style, and its Display() carries
// both values — the disagreement is the most important thing on the screen when
// it exists, and invisible when it does not.
//
// An UNRESOLVED identity (the zero Model literal a unit test builds by hand)
// paints NO band at all rather than a row of empty markers about nothing. Every
// path that reaches a terminal is built by newModel, which always resolves.
func (m Model) contextLines(width int) []string {
	if len(m.ctxid.Fields) == 0 {
		return nil
	}
	w := clamp(width, 24, 120)
	const sep = " · "

	var lines []string
	plain, styled := "", ""
	flush := func() {
		if plain != "" {
			lines = append(lines, styled)
			plain, styled = "", ""
		}
	}
	for _, f := range m.ctxid.Fields {
		seg := f.Name + " " + f.Display()
		style := dimStyle
		if f.Mismatch {
			seg = "⚠ " + seg
			style = warnStyle
		}
		if plain != "" && lipgloss.Width(plain)+lipgloss.Width(sep)+lipgloss.Width(seg) > w {
			flush()
		}
		if plain == "" {
			// A lone segment wider than the whole line is truncated — visibly,
			// with an ellipsis — rather than pushed past the frame edge.
			if lipgloss.Width(seg) > w {
				seg = truncate(seg, w)
			}
			plain, styled = seg, style.Render(seg)
			continue
		}
		plain += sep + seg
		styled += dimStyle.Render(sep) + style.Render(seg)
	}
	flush()
	return lines
}

func serverHost(baseURL string) string {
	s := strings.TrimSpace(baseURL)
	s = strings.TrimPrefix(s, "https://")
	s = strings.TrimPrefix(s, "http://")
	if i := strings.IndexByte(s, '/'); i >= 0 {
		s = s[:i]
	}
	if s == "" {
		return "—"
	}
	return s
}
