package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// chat_blocks.go — the terminal twin of the Studio chat's bespoke tool-row HEEx
// (api/lib/barkpark_web/live/studio/chat_tool_renderer.ex). It closes the Law-1
// parallel-render fork: the three highest-frequency non-text chat rows are now
// PortableDoc block TYPES, decoded from the SAME message JSON both surfaces
// consume and rendered here through the ordinary Decode -> RenderDoc seam.
//
//   - chat-tool-diff — a file-mutation as a colored +/- line diff (the DP-LCS
//     `TextDiff.diff_lines/2` output the server carries verbatim on the block).
//   - chat-todo      — the living checklist card: ☒/◐/☐ glyphs + "N/M done".
//   - chat-thinking  — a dim "✻ Thought for N tokens" provenance row.
//
// These carry the SAME visual vocabulary as chat_tool_renderer.ex (glyphs,
// "N/M done", the +/− diff prefixes) so a session reads identically whether the
// human is in Studio or in `bp chat`. The block maps are the shared contract
// (mirrored in the chat_golden_toolrows fixture, cross-checked on both surfaces).

// ── chat-tool-diff ────────────────────────────────────────────────────────────
// A file-mutation tool call rendered as a real colored line diff (charter D25,
// Law 1). The server has already run the ONE diff engine (TextDiff.diff_lines/2)
// and carries the flat `lines:[{op,text}]` list on the block, plus the file
// `path` and the `added`/`removed` counts — pdrender never re-diffs. Op glyphs
// mirror chat_tool_renderer.ex: "+ " added, "- " removed, "  " context.
//
// Honest truncation is a render concern only (chat_tool_renderer's
// @collapsed_budget): past chatDiffBudget lines the tail folds behind an honest
// "… +N more lines" — the store keeps the full input, a reopened session
// replays it in whole. Long lines are cell-truncated (a code diff must never
// re-wrap: that would break column alignment) with a dim ellipsis.
type chatToolDiffRenderer struct{}

// chatDiffBudget caps the diff lines drawn inline before the tail folds — the
// terminal shows a compact hunk, exactly like the Studio card's 20-line budget.
const chatDiffBudget = 20

func (chatToolDiffRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	pal := Resolve(ctx.Theme.themeID)
	addStyle := lipgloss.NewStyle().Foreground(pal.ToneOK)
	delStyle := lipgloss.NewStyle().Foreground(pal.ToneDanger)
	ctxStyle := ctx.Theme.Dim

	var out []string

	// Header: the mutated file path (bold ink) + a colored +N −M tally. A diff
	// with no path (a defensively-thin frame) still shows the tally so the row is
	// never blank.
	added := attrInt(b.Attrs, "added", -1)
	removed := attrInt(b.Attrs, "removed", -1)
	lines := attrSlice(b.Attrs, "lines")
	if added < 0 {
		added = countDiffOp(lines, "+")
	}
	if removed < 0 {
		removed = countDiffOp(lines, "-")
	}
	tally := addStyle.Render("+"+itoa(added)) + " " + delStyle.Render("−"+itoa(removed))
	if path := sanitizeText(chatDiffPath(b.Attrs)); path != "" {
		head := lipgloss.NewStyle().Bold(true).Foreground(pal.ChromeInk).Render(path)
		out = append(out, truncateANSI(head+"  "+tally, w))
	} else {
		out = append(out, truncateANSI(tally, w))
	}

	// The diff body: one styled row per op-line, budget-capped with an honest
	// overflow footnote for the folded tail. The budget is DRAWABLE-ONLY on
	// every surface (charter D40): a gap hunk-separator never spends budget,
	// and never draws once the budget is spent — a rule introducing rows the
	// fold already discarded would be chrome for nothing.
	shown := 0
	for _, ln := range lines {
		lm, ok := ln.(map[string]any)
		if !ok {
			continue
		}
		if shown >= chatDiffBudget {
			continue
		}
		op := attrStr(lm, "op")
		text := sanitizeCodeText(attrStr(lm, "text"))
		if op == "gap" {
			out = append(out, ctxStyle.Render(strings.Repeat("─", clampWidth(w/3))))
			continue
		}
		prefix, style := diffLineStyle(op, addStyle, delStyle, ctxStyle)
		out = append(out, truncateANSI(style.Render(prefix+text), w))
		shown++
	}
	if over := diffOverflow(lines) - chatDiffBudget; over > 0 {
		out = append(out, ctxStyle.Render("… +"+itoa(over)+" more lines"))
	}
	return out
}

// chatDiffPath reads the mutated file path tolerantly. The Go golden fixture
// carries a flat `path`, but the LIVE Elixir controller (chat_tool_diff_block)
// nests the whole tool call under `input`, so the file path arrives as
// `input.file_path`. Preferring the flat key and falling back into the nested
// input keeps both the fixture leg and real server data rendering the header —
// the same "prefer the live key, fall back" discipline as attrStrFirst. Without
// this the diff card is path-less on real /v1/chat data (Law-1 parity break).
func chatDiffPath(attrs map[string]any) string {
	if p := attrStr(attrs, "path"); p != "" {
		return p
	}
	if input, ok := attrs["input"].(map[string]any); ok {
		return attrStrFirst(input, "file_path", "path")
	}
	return ""
}

// diffLineStyle maps an op to its display prefix + style. Context lines are dim
// (a two-space gutter keeps them aligned under +/−); an unknown op degrades to
// the context rendering rather than vanishing.
func diffLineStyle(op string, add, del, ctxStyle lipgloss.Style) (string, lipgloss.Style) {
	switch op {
	case "+":
		return "+ ", add
	case "-":
		return "- ", del
	default:
		return "  ", ctxStyle
	}
}

// countDiffOp counts diff lines carrying a given op — the fallback when the
// block omits the precomputed added/removed tally.
func countDiffOp(lines []any, op string) int {
	n := 0
	for _, ln := range lines {
		if lm, ok := ln.(map[string]any); ok && attrStr(lm, "op") == op {
			n++
		}
	}
	return n
}

// diffOverflow counts the drawable (non-gap) diff lines — the denominator the
// budget folds against.
func diffOverflow(lines []any) int {
	n := 0
	for _, ln := range lines {
		if lm, ok := ln.(map[string]any); ok && attrStr(lm, "op") != "gap" {
			n++
		}
	}
	return n
}

// ── chat-todo ─────────────────────────────────────────────────────────────────
// The living checklist card (charter D39 vocabulary): a "● Update todos · N/M
// done" header over one glyph-marked row per item — ☒ completed, ◐ in-progress,
// ☐ pending — with an in-progress item's present-tense activeForm shown as a dim
// "→" continuation. An empty list still renders the header + an honest "⎿ no
// items", never a blank box (Kinsta/Vercel honest-empty bar).
type chatTodoRenderer struct{}

func (chatTodoRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	pal := Resolve(ctx.Theme.themeID)
	accent := lipgloss.NewStyle().Foreground(pal.ChromeAccent)
	okStyle := lipgloss.NewStyle().Foreground(pal.ToneOK)
	dim := ctx.Theme.Dim

	todos := attrSlice(b.Attrs, "todos")

	head := accent.Render("●") + " Update todos"
	if len(todos) > 0 {
		head += dim.Render(" · " + todoProgress(todos) + " done")
	}
	out := []string{truncateANSI(head, w)}

	if len(todos) == 0 {
		out = append(out, dim.Render("⎿ no items"))
		return out
	}

	for _, t := range todos {
		tm, ok := t.(map[string]any)
		if !ok {
			continue
		}
		status := normalizeTodoStatus(attrStr(tm, "status"))
		content := sanitizeText(attrStr(tm, "content"))
		glyph, textStyle := todoGlyphStyle(status, accent, okStyle, dim)
		out = append(out, truncateANSI("  "+glyph+" "+textStyle.Render(content), w))
		if status == "in_progress" {
			if af := sanitizeText(attrStrFirst(tm, "activeForm", "active_form")); af != "" {
				out = append(out, truncateANSI(dim.Render("    → "+af), w))
			}
		}
	}
	return out
}

// todoProgress is the compact "N/M" honest tally — in-progress is NOT done, only
// completed counts (mirrors chat_tool_renderer.todo_progress/1).
func todoProgress(todos []any) string {
	done := 0
	for _, t := range todos {
		if tm, ok := t.(map[string]any); ok && normalizeTodoStatus(attrStr(tm, "status")) == "completed" {
			done++
		}
	}
	return itoa(done) + "/" + itoa(len(todos))
}

// normalizeTodoStatus folds the wire status to the three-state vocabulary,
// defaulting to pending for anything unrecognized (mirrors normalize_status/1).
func normalizeTodoStatus(s string) string {
	switch s {
	case "in_progress", "completed":
		return s
	default:
		return "pending"
	}
}

// todoGlyphStyle returns the checklist glyph + the item text style for a status:
// ☒ completed (ok + strikethrough), ◐ in-progress (accent, bold), ☐ pending
// (dim). Mirrors chat_tool_renderer.todo_glyph/1 + todo_text_style/1.
func todoGlyphStyle(status string, accent, ok, dim lipgloss.Style) (string, lipgloss.Style) {
	switch status {
	case "completed":
		return ok.Render("☒"), dim.Strikethrough(true)
	case "in_progress":
		return accent.Render("◐"), accent.Bold(true)
	default:
		return dim.Render("☐"), lipgloss.NewStyle()
	}
}

// ── chat-thinking ─────────────────────────────────────────────────────────────
// The dim extended-thinking provenance row (charter D25): a single "✻ Thought
// for N tokens" line — the thought BODY stays collapsed (Studio shows only the
// token count too), so the transcript reads clean while still being honest that
// the model reasoned. A frame without a token count degrades to "✻ Thinking…".
type chatThinkingRenderer struct{}

func (chatThinkingRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	dim := ctx.Theme.Dim
	tokens := attrInt(b.Attrs, "tokens", 0)
	label := "✻ Thinking…"
	if tokens > 0 {
		label = "✻ Thought for " + itoa(tokens) + " tokens"
	}
	return []string{truncateANSI(dim.Render(label), w)}
}

// ── chat-approval / chat-question / chat-plan (the INTERACTIVE cards) ──────────
// The three interactive chat rows (charter D35), promoted to dual-surface block
// TYPES like the inert rows above. CRITICAL: the block carries only the read-time
// VISUAL — the tool name / question prompts / plan lede + the terminal status.
// A card's ANSWERABILITY (the focus ring + ctrl+a/ctrl+r) is NOT here: it is
// driven by the message ENVELOPE in internal/chat/render.go's cardView, keyed off
// role+request_id+approval_status. This renderer is what a read-only replay shows
// AND the body cardView wraps with its interactive shell — a naive answer control
// here would render a DEAD card divorced from the envelope's answer state.

// chatCardHeader is the shared header row for the three interactive cards: a bold
// title and a right-side status word (pending / ✓ allowed / ⊘ denied / — canceled)
// — the honest read-only state, mirroring Components.chat_card_header on the
// Studio/reader surface.
func chatCardHeader(ctx RenderCtx, w int, title, status string) string {
	head := lipgloss.NewStyle().Bold(true).Render(sanitizeText(title))
	badge := ctx.Theme.Dim.Render(chatStatusLabel(status))
	return truncateANSI(head+"  "+badge, w)
}

// chatStatusLabel folds the approval lifecycle to its display word — the block's
// own read-only badge (the TUI footer's badge is a SEPARATE envelope-driven layer
// in internal/chat's cardResolutionBadge). Mirrors Components.chat_status_label.
func chatStatusLabel(status string) string {
	switch status {
	case "allowed":
		return "✓ allowed"
	case "denied":
		return "⊘ denied"
	case "canceled":
		return "— canceled"
	case "pending", "":
		return "pending"
	default:
		return status
	}
}

type chatApprovalRenderer struct{}

func (chatApprovalRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	tool := attrStr(b.Attrs, "tool_name")
	if tool == "" {
		tool = "tool"
	}
	status := attrStr(b.Attrs, "approval_status")
	title := tool
	if status == "pending" || status == "" {
		title = "Allow " + tool + "?"
	}

	out := []string{chatCardHeader(ctx, w, title, status)}
	if summary := sanitizeText(attrStr(b.Attrs, "summary")); summary != "" {
		for _, ln := range wrapLines(summary, w) {
			out = append(out, ctx.Theme.Dim.Render(ln))
		}
	}
	return out
}

type chatQuestionRenderer struct{}

func (chatQuestionRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	status := attrStr(b.Attrs, "approval_status")
	out := []string{chatCardHeader(ctx, w, "Question", status)}

	questions := attrSlice(b.Attrs, "questions")
	if len(questions) == 0 {
		out = append(out, ctx.Theme.Dim.Render("⎿ no question"))
		return out
	}

	accent := lipgloss.NewStyle().Foreground(Resolve(ctx.Theme.themeID).ChromeAccent)
	for _, q := range questions {
		qm, ok := q.(map[string]any)
		if !ok {
			continue
		}
		if prompt := sanitizeText(attrStr(qm, "question")); prompt != "" {
			out = append(out, wrapLines(prompt, w)...)
		}
		if chips := chatQuestionChips(attrSlice(qm, "options"), accent); chips != "" {
			for _, ln := range wrapLines("  "+chips, w) {
				out = append(out, ln)
			}
		}
	}
	return out
}

// chatQuestionChips renders the option labels as bracketed chips (the visual, not
// the interactive selector). Bare-string options only (the Elixir builder folds
// {label} maps to strings), so a non-string entry is skipped.
func chatQuestionChips(options []any, style lipgloss.Style) string {
	var labels []string
	for _, o := range options {
		if s, ok := o.(string); ok {
			if s = sanitizeText(s); s != "" {
				labels = append(labels, style.Render("["+s+"]"))
			}
		}
	}
	return strings.Join(labels, " ")
}

type chatPlanRenderer struct{}

func (chatPlanRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)
	title := attrStr(b.Attrs, "title")
	if title == "" {
		title = "Proposed plan"
	}
	status := attrStr(b.Attrs, "approval_status")

	out := []string{chatCardHeader(ctx, w, title, status)}
	if preview := sanitizeText(attrStr(b.Attrs, "preview")); preview != "" {
		for _, ln := range wrapLines(preview, w) {
			out = append(out, ctx.Theme.Dim.Render(ln))
		}
	}
	return out
}
