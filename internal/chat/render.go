package chat

import (
	"fmt"
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
// pdrender.RenderDoc call. RenderDoc reseeds its "Figure N." counter to 0 at
// the head of every call, so one-call-per-message IS the per-message Figure
// reset the charter mandates — a reply is a self-contained document, not a page
// in one long paper. The live streaming tail (charter D9) is the ONE thing that
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
	noticeStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("5"))
	cardBar     = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	focusBar    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	allowStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	cursorStyle = lipgloss.NewStyle().Reverse(true)
)

// cardRoles are the interactive card rows (charter D27/D28: approval/question/
// plan render as bespoke cards, answerable in-canvas from the TUI). They are
// EXCLUDED from golden parity, which is deliberately assistant reply-body
// projection only. The engine routes one wire ask to one of these three roles by
// its tool_name (permission_role/1) — the store IS the router.
var cardRoles = map[string]string{
	"approval": "Approval requested",
	"question": "Question",
	"plan":     "Plan proposed",
}

// blockRoles are the structural rows now promoted to dual-surface PortableDoc
// block types (charter D25, Law 1): the server carries a typed block
// (chat-tool-diff / chat-todo / chat-thinking) on the message, so the transcript
// renders a REAL diff / checklist / thought row through the same pdrender seam
// the assistant reply body uses — no longer collapsed to one dim line. When the
// block is absent (a mid-persist or thinner frame) the render degrades honestly
// to the dim provenance line, never a blank or a crash.
var blockRoles = map[string]bool{
	"tool": true, "todo": true, "thinking": true,
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
	w := bodyWidth(width)
	var lines []string
	push := func(ls ...string) {
		if len(lines) > 0 && len(ls) > 0 {
			lines = append(lines, "")
		}
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
		if r := renderMessage(width, msg, focused, inflight); len(r) > 0 {
			push(r...)
		}
	}
	for _, ls := range m.st.Local {
		push(renderLocalSend(w, ls)...)
	}
	if strings.TrimSpace(m.st.Tail) != "" {
		push(renderTail(w, m.st.Tail)...)
	}
	if len(lines) == 0 {
		lines = []string{dimStyle.Render("No messages yet — type below and press Enter.")}
	}
	return lines
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
		return renderUserEcho(w, msg.SourceMarkdown)
	case cardRoles[msg.Role] != "":
		return cardView(w, msg, focused, inflight)
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
// pdrender — it settles into blocks at the turn boundary.
func renderTail(w int, tail string) []string {
	body := wrap(strings.TrimRight(tail, " "), w)
	out := make([]string, 0, len(body)+1)
	out = append(out, dimStyle.Render("assistant · streaming…"))
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
	for _, ln := range wrap(cardBody(msg), w-2) {
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
// <1k verbatim, <10k one decimal (1.2k), <1M whole (42k), else 1.3M.
func formatTokens(n int) string {
	switch {
	case n < 0:
		return "—"
	case n < 1000:
		return fmt.Sprintf("%d", n)
	case n < 10000:
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	case n < 1000000:
		return fmt.Sprintf("%dk", n/1000)
	default:
		return fmt.Sprintf("%.1fM", float64(n)/1000000)
	}
}

// cardBody extracts a display string for a card row: a well-known metadata
// field if present, else the source markdown.
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

// ── the sessions picker ──────────────────────────────────────────────────────

// renderPicker paints the launch screen (charter: launch = list/resume/new).
// Honest states: loading, error, empty, and the list — a "+ new session" row is
// always the first cursor stop so a cold account can still start.
func (m Model) renderPicker() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("bp chat") + dimStyle.Render("  ·  "+serverHost(m.cfg.BaseURL)) + "\n")
	b.WriteString(dimStyle.Render(strings.Repeat("─", clamp(m.width, 8, 80))) + "\n\n")

	rows := m.pickerRows()
	switch {
	case m.loading && len(m.sessions) == 0:
		b.WriteString(dimStyle.Render("Loading sessions…"))
	case m.pickErr != "":
		b.WriteString(noticeStyle.Render("Could not load sessions: "+m.pickErr) + "\n")
		b.WriteString(dimStyle.Render("press r to retry · q to quit"))
	default:
		for i, r := range rows {
			cursor := "  "
			line := r
			if i == m.pickCursor {
				cursor = youStyle.Render("▸ ")
				line = titleStyle.Render(r)
			}
			b.WriteString(cursor + line + "\n")
		}
		if len(m.sessions) == 0 {
			b.WriteString("\n" + dimStyle.Render("No sessions yet — the row above starts your first one."))
		}
	}

	b.WriteString("\n\n" + dimStyle.Render("↑/↓ move · enter open · n new · r refresh · q quit"))
	return b.String()
}

// pickerRows is the picker's navigable line list: a "+ new session" row (index
// 0) followed by one row per session summary. The cursor indexes this slice, so
// the shell and the paint can never disagree (the taskboard spine discipline).
func (m Model) pickerRows() []string {
	rows := []string{"+ new session"}
	for _, s := range m.sessions {
		title := strings.TrimSpace(s.Title)
		if title == "" {
			title = "untitled session"
		}
		meta := fmt.Sprintf("%d msg", s.MessageCount)
		if s.PendingApprovals > 0 {
			meta += fmt.Sprintf(" · %d pending", s.PendingApprovals)
		}
		if age := relTime(s.LastActiveAt); age != "" {
			meta += " · " + age
		}
		rows = append(rows, fmt.Sprintf("%-40s %s", truncate(title, 40), dimStyle.Render(meta)))
	}
	return rows
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
	all := m.transcriptLines(m.width)
	body := window(all, bodyH, m.scroll)
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
// status glyph, then a rule.
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
	rule := dimStyle.Render(strings.Repeat("─", clamp(m.width, 8, 100)))
	return line + "\n" + rule
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

	hints := "enter send · esc interrupt · ctrl+b sessions · ctrl+c quit"
	if n := len(m.answerableCards()); n > 0 {
		// A pending card is waiting — advertise the answer keys so the affordance
		// is discoverable even when the card scrolled out of view.
		label := fmt.Sprintf("%d card waiting: ctrl+a allow · ctrl+r deny", n)
		if n > 1 {
			label += " · tab next"
		}
		hints = label + "  ·  " + hints
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

// bodyHeight is the transcript viewport row count: the frame minus the two
// header rows and the three footer rows, floored at one.
func (m Model) bodyHeight() int {
	h := m.height - 5
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
	// trim rune-wise to width-1, add ellipsis
	out := ""
	for _, r := range s {
		if lipgloss.Width(out)+1 >= w {
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
	if iso == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return ""
	}
	d := time.Since(t)
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
