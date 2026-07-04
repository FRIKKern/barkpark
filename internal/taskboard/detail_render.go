package taskboard

// detail_render.go — RenderTaskDetail: the Doey-DETAIL-grade task reading view
// (charter D15, wave 5). One pure function (data, width, clock) → lines +
// stops; the shell windows by Frame.Scroll/height. Every section is
// CONDITIONAL so a thin task renders thin (Doey's ExpandedCard discipline —
// but split into small section emitters, not a god-method). Color = state
// only, via the statusRole vocabulary; everything else is monochrome/dim.
// The status WORD appears in the meta line and the derived timeline only —
// nowhere else (Doey: the glyph says it, the text need not repeat it). Task
// prose (description/design) renders through the SAME pdrender registry papers
// use — via mdlite (MarkdownBlocks) — at a min(width-gutter, 72) measure so a
// wide two-pane terminal never feeds pdrender an unreadable column (D24).

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// detailMeasure is the D15 prose measure ceiling: description/design render at
// min(width-4, detailMeasure) cells so long lines stay book-readable even on a
// wide two-pane terminal.
const detailMeasure = 72

// proseIndent is the left margin task prose hangs at, visually nesting the
// rendered markdown under the title column.
const proseIndent = 2

// Honest-truncation caps (D15 hard rule: long lists end in "… and N more",
// never a silent drop). The rails stay generous — their rows are navigation
// stops — while flat fact lists cap tighter.
const (
	childRailCap = 20
	paperRailCap = 10
	codeRefsCap  = 8
)

// minDetailWidth is the pathological floor: below this the layout math (bars,
// glyph gutters, prose measure) stops making sense, so we render as if the
// pane were this wide and let the terminal clip.
const minDetailWidth = 20

// detailRegistry is the one shared pdrender composition root for task prose
// (charter law: one rendering stack — the same engine papers use). Charter D20:
// pdrender renders through its own DarkTheme — its zinc/blue/emerald palette is
// the same family the board uses, so prose harmonizes with the pane and no
// theme injection (which pdrender's constructors do not expose) is needed.
var detailRegistry = pdrender.DefaultRegistry(pdrender.DarkTheme())

// detailProfile is the pdrender color profile task prose renders at. It is
// NoColor — matching pdrender's own document goldens (render_m1_test.go) — for
// two reasons: (1) it upholds the epic's "color = state, never decoration" law
// (prose carries no state, so it wears no hue; block headings/body still take
// the DarkTheme lipgloss styling, which rides the global lipgloss profile, not
// this one); (2) pdrender's COLORED chroma path collapses a multi-line fenced
// code block onto a single line (verified: only the NoColor path re-splits the
// source correctly), and charter law forbids editing pdrender to fix it here.
// NoColor keeps fenced code honestly multi-line and readable.
const detailProfile = pdrender.NoColor

// measure is the SINGLE pure reading-measure helper (charter D24) both the
// detail and paper frames call: prose wraps at min(paneWidth − gutter, 72)
// cells at EVERY width. Terminal typography dies past ~72 cells, so on a wide
// two-pane terminal the extra width becomes margin instead of an unreadable
// line. A pathological floor keeps the wrap width sane below the gutter.
func measure(width int) int {
	m := width - proseGutter
	if m > detailMeasure {
		m = detailMeasure
	}
	if m < proseFloor {
		m = proseFloor
	}
	return m
}

// proseGutter is the total horizontal margin reserved around rendered prose:
// proseIndent on the left plus an equal breathing margin on the right.
const proseGutter = 2 * proseIndent

// proseFloor is the narrowest reading measure — below it pdrender's own
// MinWidth degradation takes over.
const proseFloor = 8

// detailGlyph is the detail view's CALM four-glyph status vocabulary (charter
// D15): ● in_progress, ◐ blocked, ○ ready|open, ✓ done. It is intentionally a
// smaller, steadier set than the board's animated StatusGlyph — a reading view
// never spins. Callers tint it via roleStyle (color = state). Unknown states
// get a neutral dot.
func detailGlyph(lifecycle string) string {
	switch lifecycle {
	case "in_progress":
		return "●"
	case "blocked":
		return "◐"
	case "done", "closed":
		return "✓"
	case "ready", "open":
		return "○"
	default:
		return "·"
	}
}

// detailBuilder accumulates the frame. One mutable value threaded through the
// section emitters keeps blank-line rhythm correct by construction (an
// emitter can never lose a separator the way parallel slice copies can).
type detailBuilder struct {
	lines []string
	stops []Stop
}

// add appends one already-styled, already-width-safe line.
func (b *detailBuilder) add(s string) { b.lines = append(b.lines, s) }

// blank opens a new section with exactly one empty line of rhythm — and only
// when something has already been emitted, so a thin task never renders
// leading or doubled air.
func (b *detailBuilder) blank() {
	if len(b.lines) > 0 && b.lines[len(b.lines)-1] != "" {
		b.lines = append(b.lines, "")
	}
}

// stop registers the NEXT line as a selectable target and reports whether the
// cursor sits on it (stops are indexed in emission order).
func (b *detailBuilder) stop(kind FrameKind, ref, label string, cursor int) bool {
	selected := cursor == len(b.stops)
	b.stops = append(b.stops, Stop{Line: len(b.lines), Kind: kind, Ref: ref, Label: label})
	return selected
}

// RenderTaskDetail renders one task as a full reading view (frozen wave-5
// signature). It returns the frame's body lines plus its selectable stops
// (the CHILDREN and PAPERS rails); the cursor'th stop renders with the ▎
// selection bar + bold. Stop.Line indexes the returned slice exactly. Pure:
// zero fetches, injected clock, no tea imports.
func RenderTaskDetail(d TaskDetail, children []Task, cursor, width int, now time.Time) ([]string, []Stop) {
	if width < minDetailWidth {
		width = minDetailWidth
	}
	b := &detailBuilder{}

	// (1) Title — bold, wrapped (a reading view never clips the one thing the
	// reader came for).
	title := strings.TrimSpace(d.Title)
	if title == "" {
		b.add(dimStyle.Render("(untitled task)"))
	} else {
		for _, ln := range detailWrap(title, width) {
			b.add(titleStyle.Render(ln))
		}
	}

	// (2) Meta line — ONE status health glyph + dim facts. The status word
	// lives here (and in the timeline's life story) only.
	b.add(detailMetaLine(d, width, now))

	// (3) Hybrid timestamps — one line when they fit, stacked when narrow.
	if stamps := detailStampLines(d, width, now); len(stamps) > 0 {
		b.blank()
		b.lines = append(b.lines, stamps...)
	}

	// (4) Derived status timeline (D13f) — the task's life story in one dim
	// horizontal strip, wrapping gracefully at narrow widths.
	if segs := timelineSegments(d, now); len(segs) > 0 {
		b.blank()
		b.lines = append(b.lines, timelineLines(segs, width)...)
	}

	// (5) Description / Design — real typography via mdlite → pdrender.
	if prose := proseLines(d.Description, width); len(prose) > 0 {
		b.blank()
		b.lines = append(b.lines, prose...)
	}
	if prose := proseLines(d.Design, width); len(prose) > 0 {
		b.blank()
		b.add(dimStyle.Render("design"))
		b.lines = append(b.lines, prose...)
	}

	// (6) Acceptance-criteria checklist.
	b.emitCriteria(d, width)

	// (7)+(8) Labels + deps — flat dim facts, one line each.
	b.emitFacts(d, width)

	// (9) Claim block.
	b.emitClaim(d, width, now)

	// (10) Reason strips, code refs, twin.
	b.emitStrip("blocked", d.BlockedReason, warnStyle, width)
	b.emitStrip("closed", d.CloseReason, dimStyle, width)
	b.emitStrip("resolution", d.ResolutionNote, dimStyle, width)
	b.emitCodeRefs(d, width)
	if d.TwinOf != "" {
		partner := d.TwinTitle
		if partner == "" {
			partner = d.TwinOf
		}
		b.blank()
		b.add(truncate(warnStyle.Render("twin ⧉ ")+dimStyle.Render("'"+partner+"'"), width))
	}

	// (11) Selectable rails: CHILDREN then PAPERS. Stop indices are assigned
	// in emission order, so `cursor` walks children first, then papers.
	b.emitChildrenRail(children, cursor, width, now)
	b.emitPapersRail(d.PaperRefs(), cursor, width)

	return b.lines, b.stops
}

// detailMetaLine is section (2): glyph + dim `lifecycle · P<n> · kind · worker`.
func detailMetaLine(d TaskDetail, width int, now time.Time) string {
	glyph := roleStyle(RoleFor(d.Task, now)).Render(detailGlyph(d.Lifecycle))
	var segs []string
	if d.Lifecycle != "" {
		segs = append(segs, d.Lifecycle)
	}
	if p := priorityToken(d.Priority); p != "" {
		segs = append(segs, p)
	}
	if d.Kind != "" {
		segs = append(segs, d.Kind)
	}
	if w := detailWorker(d); w != "" {
		segs = append(segs, w)
	}
	if len(segs) == 0 {
		return glyph
	}
	return glyph + " " + dimStyle.Render(truncate(strings.Join(segs, " · "), width-2))
}

// priorityToken normalizes the wire's priority ("1", "P1", …) to `P<n>`.
func priorityToken(p string) string {
	if p == "" {
		return ""
	}
	if p[0] == 'P' || p[0] == 'p' {
		return p
	}
	return "P" + p
}

// detailWorker is the meta line's who: the live claim's worker, else the
// assignee.
func detailWorker(d TaskDetail) string {
	if d.Claim != nil && d.Claim.Worker != "" {
		return d.Claim.Worker
	}
	return d.Assignee
}

// detailStampLines renders section (3): `created 2h ago (Jul 04, 15:12)` /
// `updated …` — joined on one line when the pane is wide enough, stacked when
// not. Zero times render nothing (a thin task stays thin).
func detailStampLines(d TaskDetail, width int, now time.Time) []string {
	var parts []string
	if s := hybridStamp(d.InsertedAt, now); s != "" {
		parts = append(parts, "created "+s)
	}
	if s := hybridStamp(d.UpdatedAt, now); s != "" {
		parts = append(parts, "updated "+s)
	}
	if len(parts) == 0 {
		return nil
	}
	joined := strings.Join(parts, " · ")
	if disp(joined) <= width {
		return []string{dimStyle.Render(joined)}
	}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		out = append(out, dimStyle.Render(truncate(p, width)))
	}
	return out
}

// hybridStamp is the ONE shared hybrid-timestamp helper (D15, Doey's
// formatTimestampHybrid): "2h ago (Jul 04, 15:12)" — glanceable AND precise,
// no toggle. Empty for a zero time.
func hybridStamp(t, now time.Time) string {
	if t.IsZero() {
		return ""
	}
	abs := t.Format("Jan 02, 15:04")
	age := AgeBadge(t, now)
	if age == "" || age == "now" {
		return "just now (" + abs + ")"
	}
	return age + " ago (" + abs + ")"
}

// shortDate is the timeline's compact absolute marker.
func shortDate(t time.Time) string { return t.Format("Jan 02") }

// timelineSegments derives the D13f status timeline client-side, from the
// fields the wire already carries: InsertedAt → claim (previous_worker, then
// worker) → last_worked_at → terminal lifecycle (+close_reason inline when
// done). No per-task events endpoint exists yet (charter row 19 RESERVED) —
// this is the honest derivation, not a fabricated log.
func timelineSegments(d TaskDetail, now time.Time) []string {
	var segs []string
	if !d.InsertedAt.IsZero() {
		segs = append(segs, "○ created ("+shortDate(d.InsertedAt)+")")
	}
	claimed := d.Claim != nil && d.Claim.Worker != ""
	if d.PreviousWorker != "" {
		segs = append(segs, "● claimed by "+d.PreviousWorker)
	}
	if claimed {
		verb := "claimed by"
		if d.PreviousWorker != "" {
			verb = "reclaimed by"
		}
		seg := "● " + verb + " " + d.Claim.Worker
		if !d.Claim.ClaimedAt.IsZero() {
			seg += " (" + shortDate(d.Claim.ClaimedAt) + ")"
		}
		segs = append(segs, seg)
	}
	if !d.LastWorkedAt.IsZero() {
		segs = append(segs, "● worked ("+shortDate(d.LastWorkedAt)+")")
	}
	switch d.Lifecycle {
	case "done", "closed", "cancelled":
		seg := detailGlyph(d.Lifecycle) + " " + d.Lifecycle
		if !d.UpdatedAt.IsZero() {
			seg += " (" + shortDate(d.UpdatedAt) + ")"
		}
		if d.Lifecycle == "done" && d.CloseReason != "" {
			seg += " — " + d.CloseReason
		}
		segs = append(segs, seg)
	}
	// A task with only "created" has no story to tell yet — the stamps line
	// already says it. One segment renders nothing; two or more render.
	if len(segs) < 2 {
		return nil
	}
	return segs
}

// timelineLines lays the segments out horizontally, joined by " → ", wrapping
// to continuation lines (indented, arrow-led) when the pane is narrow. Dim
// throughout — the glyphs, not color, carry the story.
func timelineLines(segs []string, width int) []string {
	var out []string
	cur := ""
	for _, s := range segs {
		if cur == "" {
			cur = s
			continue
		}
		cand := cur + " → " + s
		if disp(cand) > width {
			out = append(out, dimStyle.Render(truncate(cur+" →", width)))
			cur = "  " + s
			continue
		}
		cur = cand
	}
	if cur != "" {
		out = append(out, dimStyle.Render(truncate(cur, width)))
	}
	return out
}

// proseLines renders task markdown as typography: mdlite (MarkdownBlocks) →
// the shared pdrender engine, at a min(width-4, 72)-cell measure (D15),
// hanging at a 2-col indent. Empty/whitespace source renders nothing.
func proseLines(src string, width int) []string {
	if strings.TrimSpace(src) == "" {
		return nil
	}
	blocks := MarkdownBlocks(src)
	if len(blocks) == 0 {
		return nil
	}
	doc := detailRegistry.RenderDoc(blocks, pdrender.RenderCtx{
		Width:   measure(width),
		Profile: detailProfile,
	})
	pad := strings.Repeat(" ", proseIndent)
	var out []string
	for _, ln := range strings.Split(doc, "\n") {
		// JoinVertical pads short lines to the block width; trim the dead air
		// so goldens (and the terminal) never carry trailing spaces.
		out = append(out, strings.TrimRight(pad+ln, " "))
	}
	return out
}

// emitCriteria is section (6): a `criteria met/total` header plus a ✓/○
// checklist with per-item evidence. When only the {met,total} counter
// survived decoding (no items), the header alone renders — never emptier
// than the wire was honest about.
func (b *detailBuilder) emitCriteria(d TaskDetail, width int) {
	items := d.CriteriaItems
	hasCounter := d.Criteria != nil && d.Criteria.Total > 0
	if len(items) == 0 && !hasCounter {
		return
	}
	met, total := criteriaFraction(d)
	b.blank()
	b.add(dimStyle.Render(fmt.Sprintf("criteria %d/%d", met, total)))
	for i, it := range items {
		glyph, gStyle := "○", dimStyle
		tStyle := lipgloss.NewStyle()
		if it.Met {
			glyph, gStyle = "✓", okStyle
			tStyle = dimStyle // landed work recedes; the ✓ already said it
		}
		if it.Criterion == "" {
			// Malformed entry: keep its slot as a bare glyph — honest that an
			// Nth criterion exists even when its text did not decode.
			b.add("  " + gStyle.Render(glyph))
		} else {
			for j, w := range detailWrap(it.Criterion, width-4) {
				if j == 0 {
					b.add("  " + gStyle.Render(glyph) + " " + tStyle.Render(w))
				} else {
					b.add("    " + tStyle.Render(w))
				}
			}
		}
		if i < len(d.Evidence) && d.Evidence[i] != "" {
			b.add(dimStyle.Render(truncate("    ↳ "+d.Evidence[i], width)))
		}
	}
}

// criteriaFraction prefers the wire's counter and falls back to counting the
// decoded items, so the header never contradicts the meter the board showed.
func criteriaFraction(d TaskDetail) (met, total int) {
	if d.Criteria != nil && d.Criteria.Total > 0 {
		return d.Criteria.Met, d.Criteria.Total
	}
	for _, it := range d.CriteriaItems {
		if it.Met {
			met++
		}
	}
	return met, len(d.CriteriaItems)
}

// emitFacts renders sections (7)+(8): the label line and the deps-in-words
// line. One dim monochrome line each — no chip colors in detail (D14).
func (b *detailBuilder) emitFacts(d TaskDetail, width int) {
	var out []string
	if len(d.Labels) > 0 {
		out = append(out, dimStyle.Render(truncate("labels  "+strings.Join(d.Labels, " · "), width)))
	}
	var dep []string
	if d.DependentCount > 0 {
		dep = append(dep, fmt.Sprintf("blocks %d %s", d.DependentCount, pluralTask(d.DependentCount)))
	}
	if d.DependencyCount > 0 {
		dep = append(dep, fmt.Sprintf("blocked by %d", d.DependencyCount))
	}
	if len(dep) > 0 {
		out = append(out, dimStyle.Render(truncate(strings.Join(dep, " · "), width)))
	}
	if len(out) == 0 {
		return
	}
	b.blank()
	b.lines = append(b.lines, out...)
}

func pluralTask(n int) string {
	if n == 1 {
		return "task"
	}
	return "tasks"
}

// emitClaim is section (9): worker · epoch · ticking claimed age, the lease
// expiry (warn tint when leaning, danger when spent), and the previous
// worker. A TERMINAL task keeps the who-did-it facts but never a lease
// alarm — finished work cannot have an expiring lease (mirrors staleRole's
// terminal-neutral rule).
func (b *detailBuilder) emitClaim(d TaskDetail, width int, now time.Time) {
	if d.Claim == nil || d.Claim.Worker == "" {
		return
	}
	b.blank()
	parts := []string{d.Claim.Worker, fmt.Sprintf("epoch %d", d.Claim.Epoch)}
	if s := hybridStamp(d.Claim.ClaimedAt, now); s != "" {
		parts = append(parts, "claimed "+s)
	}
	b.add(dimStyle.Render(truncate("claim  "+strings.Join(parts, " · "), width)))

	terminal := d.Lifecycle == "done" || d.Lifecycle == "closed" || d.Lifecycle == "cancelled"
	if !d.ClaimExpiredAt.IsZero() && !terminal {
		rem := d.ClaimExpiredAt.Sub(now)
		switch {
		case rem <= 0:
			b.add(dangerStyle.Render(truncate("       lease expired "+AgeBadge(d.ClaimExpiredAt, now)+" ago", width)))
		case rem <= leaseTTL*3/10:
			b.add(warnStyle.Render(truncate("       lease expires in "+durToken(rem), width)))
		default:
			b.add(dimStyle.Render(truncate("       lease expires in "+durToken(rem), width)))
		}
	}
	if d.PreviousWorker != "" {
		b.add(dimStyle.Render(truncate("       previously "+d.PreviousWorker, width)))
	}
}

// durToken is AgeBadge's forward-looking sibling: a compact remaining-time
// token ("45s", "3m", "2h").
func durToken(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
}

// emitStrip renders one short role-tinted reason strip (section 10):
//
//	▍ blocked — waiting on the #979 seam
//
// wrapped with the bar repeated on continuation lines so the strip stays a
// strip. Empty text renders nothing.
func (b *detailBuilder) emitStrip(label, text string, style lipgloss.Style, width int) {
	text = strings.TrimSpace(text)
	if text == "" {
		return
	}
	b.blank()
	for _, w := range detailWrap(label+" — "+text, width-2) {
		b.add(style.Render("▍ " + w))
	}
}

// emitCodeRefs renders the dim code_refs list, capped honestly.
func (b *detailBuilder) emitCodeRefs(d TaskDetail, width int) {
	if len(d.CodeRefs) == 0 {
		return
	}
	b.blank()
	b.add(dimStyle.Render("code"))
	shown, folded := d.CodeRefs, 0
	if len(shown) > codeRefsCap+1 {
		shown, folded = shown[:codeRefsCap], len(shown)-codeRefsCap
	}
	for _, ref := range shown {
		b.add(dimStyle.Render(truncate("  "+ref, width)))
	}
	if folded > 0 {
		b.add(dimStyle.Render(fmt.Sprintf("  … and %d more", folded)))
	}
}

// emitChildrenRail is section (11a): a `children m/n done` header and one
// selectable row per child — glyph + title + dim age — each a Stop pushing
// that child's FrameTask.
func (b *detailBuilder) emitChildrenRail(children []Task, cursor, width int, now time.Time) {
	if len(children) == 0 {
		return
	}
	done := 0
	for _, c := range children {
		if c.Lifecycle == "done" || c.Lifecycle == "closed" {
			done++
		}
	}
	b.blank()
	b.add(dimStyle.Render(fmt.Sprintf("children %d/%d done", done, len(children))))
	shown, folded := children, 0
	if len(children) > childRailCap+1 {
		shown, folded = children[:childRailCap], len(children)-childRailCap
	}
	for _, c := range shown {
		selected := b.stop(FrameTask, c.DocID, c.Title, cursor)
		b.add(childRow(c, selected, width, now))
	}
	if folded > 0 {
		b.add(dimStyle.Render(fmt.Sprintf("  … and %d more", folded)))
	}
}

// childRow is one CHILDREN rail line: selection bar (▎ when the cursor is
// here) + status glyph + title + dim age. The selected title is bold; a done
// child's title recedes.
func childRow(c Task, selected bool, width int, now time.Time) string {
	bar := "  "
	if selected {
		bar = "▎ "
	}
	glyph := roleStyle(RoleFor(c, now)).Render(detailGlyph(c.Lifecycle))
	age := AgeBadge(c.UpdatedAt, now)
	titleBudget := width - 4 // bar(2) + glyph(1) + space(1)
	if age != "" {
		if titleBudget-disp(age)-2 >= 8 {
			titleBudget -= disp(age) + 2
		} else {
			age = ""
		}
	}
	style := titleStyleFor(c.Lifecycle)
	if selected {
		style = boldStyle
	}
	line := bar + glyph + " " + style.Render(truncate(c.Title, titleBudget))
	if age != "" {
		line += "  " + dimStyle.Render(age)
	}
	return line
}

// emitPapersRail is section (11b): a dim `papers` header and one `▸ <slug>`
// row per linked paper, each a Stop pushing FramePaper.
func (b *detailBuilder) emitPapersRail(refs []string, cursor, width int) {
	if len(refs) == 0 {
		return
	}
	b.blank()
	b.add(dimStyle.Render("papers"))
	shown, folded := refs, 0
	if len(refs) > paperRailCap+1 {
		shown, folded = refs[:paperRailCap], len(refs)-paperRailCap
	}
	for _, slug := range shown {
		selected := b.stop(FramePaper, slug, slug, cursor)
		bar, style := "  ", lipgloss.NewStyle()
		if selected {
			bar, style = "▎ ", boldStyle
		}
		b.add(bar + dimStyle.Render("▸") + " " + style.Render(truncate(slug, width-4)))
	}
	if folded > 0 {
		b.add(dimStyle.Render(fmt.Sprintf("  … and %d more", folded)))
	}
}

// detailWrap word-wraps a PLAIN string to width and splits it into lines
// (ANSI-aware wrap; long tokens hard-break rather than overflow).
func detailWrap(s string, width int) []string {
	if width < 1 {
		width = 1
	}
	return strings.Split(ansi.Wrap(s, width, " "), "\n")
}
