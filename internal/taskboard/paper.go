package taskboard

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// paper.go — the FramePaper reading surface (charter wave-5 slice 16, D17/D20).
// A paper is fetched through ONE direct scoped read (apiclient.PaperDoc, D13e),
// decoded into a PaperState, then rendered WHOLESALE through pdrender — the same
// Decode → DefaultRegistry(theme).RenderDoc pipeline the `bp paper view` CLI
// uses — with NO theme bridge: pdrender.Theme's fields are unexported and only
// DarkTheme()/LightTheme() construct one, so the board's statusRole palette
// cannot be injected (charter law forbids editing pdrender). pdrender's own dark
// palette rides the same zinc/blue/emerald family the board uses, so the two
// harmonize with no bridge (D20). Below the body, a "Tasks driven by this paper"
// rail IS the frame's []Stop — the only selectable targets in v1 (in-body
// wikilink chips are display-only, D17).

// paperGutter is the left breathing room reserved before the wrapped prose. The
// reading measure is min(width − gutter, paperMaxMeasure): terminal typography
// dies past ~72 cells, so extra pane width becomes margin, not longer lines
// (charter D24).
const (
	paperGutter      = 2
	paperMaxMeasure  = 72
	paperCacheMax    = 32
	paperRailProfile = pdrender.ANSI256 // the modern-terminal floor: OSC-8 links + faithful palette, no truecolor bleed
)

// paperMeasure caps the prose width at min(width − gutter, 72), floored at
// pdrender.MinWidth so a very narrow pane still renders (chrome-dropped) rather
// than collapsing to nothing.
func paperMeasure(width int) int {
	m := width - paperGutter
	if m > paperMaxMeasure {
		m = paperMaxMeasure
	}
	if m < pdrender.MinWidth {
		m = pdrender.MinWidth
	}
	// Never let the reading measure exceed the pane itself: at a pathologically
	// narrow width the MinWidth floor would otherwise feed pdrender a width wider
	// than the frame and break the never-exceeds-width invariant.
	if m > width && width > 0 {
		m = width
	}
	return m
}

// FetchPaper is the frame's single IO edge: one direct scoped read of the paper
// by slug (apiclient.PaperDoc at the client's configured perspective), decoded
// into the render/fetch state. A doc that carries body_html but ZERO portable
// blocks (exists live) sets HTMLOnly so the frame can honestly hand the reader
// off to a browser instead of rendering a blank. Every failure lands as a
// one-line Err on a still-usable PaperState (never a panic, never a bare error
// screen) AND is returned so the shell can log it. Loading is left false — the
// shell sets it true on the placeholder state while this call is in flight.
func FetchPaper(c *apiclient.Client, dataset, slug string) (PaperState, error) {
	ps := PaperState{Slug: slug}
	raw, err := c.PaperDoc(dataset, slug, c.Perspective)
	if err != nil {
		ps.Err = err.Error()
		return ps, err
	}

	var env struct {
		Title    string          `json:"title"`
		Rev      string          `json:"_rev"`
		Blocks   json.RawMessage `json:"blocks"`
		BodyHTML string          `json:"body_html"`
	}
	if jerr := json.Unmarshal(raw, &env); jerr != nil {
		ps.Err = "decode paper: " + jerr.Error()
		return ps, jerr
	}

	ps.Title = strings.TrimSpace(env.Title)
	ps.Rev = strings.TrimSpace(env.Rev)
	switch {
	case blocksNonEmpty(env.Blocks):
		ps.BlocksRaw = env.Blocks
	case strings.TrimSpace(env.BodyHTML) != "":
		// A block-less paper with rendered HTML → honest browser-handoff.
		ps.HTMLOnly = true
	}
	return ps, nil
}

// blocksNonEmpty reports whether raw is a JSON array with at least one element.
// null / absent / "[]" / a non-array all count as empty — the HTMLOnly and
// not-found branches key off this.
func blocksNonEmpty(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		return false
	}
	var arr []json.RawMessage
	if json.Unmarshal(trimmed, &arr) != nil {
		return false
	}
	return len(arr) > 0
}

// ── render cache ──────────────────────────────────────────────────────────────
//
// Decoding + laying out a paper is the frame's one expensive step, so the
// rendered body lines are cached by (slug, rev, width) — Doey's markdown-cache
// lesson: a live-polling reader must not re-run the renderer every frame. The
// key deliberately omits chip state, so an in-body wikilink chip shows the
// status as of the FIRST render at that key (display-only, charter D17); the
// driven rail below is rebuilt every call and always shows live status. A `_rev`
// bump (any edit) changes the key and re-renders.
var (
	paperCacheMu     sync.Mutex
	paperCache       = map[string][]string{}
	paperDecodeCount int // test instrument: pdrender.Decode invocations from the body renderer
)

func paperCacheKey(slug, rev string, width int) string {
	return slug + "\x00" + rev + "\x00" + strconv.Itoa(width)
}

// renderPaperBody returns the body lines for the current PaperState: an honest
// one-line state (loading / error / HTML-only / not-found) OR the pdrender
// output, cached by (slug, rev, width). resolver wires in-body wikilink chips to
// the live snapshot; it is consulted only on a cache MISS (see the cache note).
func renderPaperBody(ps PaperState, width int, resolver func(id string) *pdrender.TaskChip) []string {
	switch {
	case ps.Loading:
		return []string{dimStyle.Render("loading…")}
	case ps.Err != "":
		return []string{dimStyle.Render(truncate("could not load paper — "+ps.Err, width))}
	case ps.HTMLOnly:
		return []string{dimStyle.Render(truncate("HTML-only paper — o opens in browser", width))}
	case !blocksNonEmpty(ps.BlocksRaw):
		// A dangling / empty result — never a crash, an honest dim line.
		return []string{dimStyle.Render("not found")}
	}

	key := paperCacheKey(ps.Slug, ps.Rev, width)
	paperCacheMu.Lock()
	defer paperCacheMu.Unlock()
	if body, ok := paperCache[key]; ok {
		return body
	}

	paperDecodeCount++
	blocks, err := pdrender.Decode(ps.BlocksRaw)
	if err != nil {
		body := []string{dimStyle.Render("paper body could not be rendered")}
		paperCache[key] = body
		return body
	}

	// pdrender WHOLESALE — no theme bridge (D20): the dark preset by construction.
	theme := pdrender.DarkTheme()
	reg := pdrender.DefaultRegistry(theme)
	rctx := pdrender.RenderCtx{
		Width:        paperMeasure(width),
		Theme:        theme,
		Profile:      paperRailProfile,
		TaskResolver: resolver,
	}
	rendered := reg.RenderDoc(blocks, rctx)
	body := strings.Split(rendered, "\n")

	if len(paperCache) >= paperCacheMax {
		paperCache = map[string][]string{}
	}
	paperCache[key] = body
	return body
}

// RenderPaperFrame lays out one FramePaper: a bold title, a dim identity line,
// the pdrender body (or an honest state line), then the "Tasks driven by this
// paper" rail. The rail rows are the frame's ONLY Stops (Kind FrameTask) — the
// shell descends into a driven task on enter. The rail renders even while the
// body is loading or failed, so the reader always sees what the paper drives.
// cursor selects one rail row (the ▎ left bar); it is clamped to the rail.
func RenderPaperFrame(ps PaperState, driven []Task, chipSource []Task, cursor, width int, now time.Time) ([]string, []Stop) {
	if width < 1 {
		width = 1
	}
	var lines []string
	var stops []Stop

	// Header: bold title + dim identity/rev line.
	title := strings.TrimSpace(ps.Title)
	if title == "" {
		title = strings.TrimSpace(ps.Slug)
	}
	if title == "" {
		title = "(untitled paper)"
	}
	lines = append(lines, titleStyle.Render(truncate(title, width)))
	if meta := paperMetaLine(ps); meta != "" {
		lines = append(lines, dimStyle.Render(truncate(meta, width)))
	}
	lines = append(lines, "")

	// Body (cached), with live in-body chips resolved from the snapshot.
	resolver := paperChipResolver(chipSource)
	lines = append(lines, renderPaperBody(ps, width, resolver)...)
	lines = append(lines, "")

	// Driven-tasks rail — the frame's Stops.
	lines = append(lines, dimStyle.Render(truncate(paperRailHeader(len(driven)), width)))
	if len(driven) == 0 {
		lines = append(lines, dimStyle.Render("No tasks reference this paper"))
		return lines, stops
	}
	if cursor < 0 {
		cursor = 0
	}
	if cursor >= len(driven) {
		cursor = len(driven) - 1
	}
	for i, t := range driven {
		label := strings.TrimSpace(t.Title)
		if label == "" {
			label = t.DocID
		}
		lineIdx := len(lines)
		lines = append(lines, paperDrivenRow(t, i == cursor, width, now))
		stops = append(stops, Stop{Line: lineIdx, Kind: FrameTask, Ref: t.DocID, Label: label})
	}
	return lines, stops
}

// paperMetaLine is the dim identity line under the title: slug · rev, either
// omitted when absent. "" when both are empty (the shell then skips the line).
func paperMetaLine(ps PaperState) string {
	var parts []string
	if s := strings.TrimSpace(ps.Slug); s != "" {
		parts = append(parts, s)
	}
	if r := strings.TrimSpace(ps.Rev); r != "" {
		parts = append(parts, r)
	}
	return strings.Join(parts, " · ")
}

// paperRailHeader labels the driven-tasks rail with its honest count.
func paperRailHeader(n int) string {
	return fmt.Sprintf("Tasks driven by this paper (%d)", n)
}

// paperDrivenRow is one compact rail row: a ▎ selection bar (D14), the
// role-tinted status glyph, the title, and a dim right-aligned age. One line,
// width-safe (leftRight/truncate do the ANSI-aware clipping).
func paperDrivenRow(t Task, selected bool, width int, now time.Time) string {
	sel := " "
	if selected {
		sel = "▎"
	}
	title := strings.TrimSpace(t.Title)
	if title == "" {
		title = t.DocID
	}
	role := RoleFor(t, now)
	glyph := roleStyle(role).Render(StatusGlyph(t.Lifecycle, 0))
	left := sel + " " + glyph + " " + titleStyleFor(t.Lifecycle).Render(title)

	age := AgeBadge(t.UpdatedAt, now)
	if age == "" {
		return truncate(left, width)
	}
	return leftRight(left, dimStyle.Render(age), width)
}

// paperChipResolver builds the in-body wikilink task-chip seam from the live
// snapshot: a task's board fields mapped into a display-only pdrender.TaskChip.
// It generalizes paper_cmd.go's key scheme — the task's doc_id in both the
// `drafts.` and published spellings plus its lowercased title — so a wikilink
// pinned to either id form (or written by title) resolves. Returns nil when the
// snapshot is empty (pdrender then keeps the plain-wikilink degrade).
func paperChipResolver(chipSource []Task) func(id string) *pdrender.TaskChip {
	if len(chipSource) == 0 {
		return nil
	}
	byKey := make(map[string]*pdrender.TaskChip, len(chipSource)*3)
	put := func(k string, chip *pdrender.TaskChip) {
		if k == "" {
			return
		}
		if _, taken := byKey[k]; !taken {
			byKey[k] = chip
		}
	}
	for _, t := range chipSource {
		chip := taskToChip(t)
		id := t.DocID
		pub := strings.TrimPrefix(id, "drafts.")
		put(id, chip)
		put(pub, chip)
		put("drafts."+pub, chip)
		put(strings.ToLower(strings.TrimSpace(t.Title)), chip)
	}
	return func(id string) *pdrender.TaskChip {
		id = strings.TrimSpace(id)
		if id == "" {
			return nil
		}
		if c, ok := byKey[id]; ok {
			return c
		}
		if c, ok := byKey[strings.ToLower(id)]; ok {
			return c
		}
		return nil
	}
}

// taskToChip maps a board Task into a display-only pdrender.TaskChip. Priority
// is parsed permissively (a non-numeric priority drops the P-segment — 0 is a
// VALID priority, the highest, so a bool flag gates it); criteria omit the m/n
// segment when absent (never "0/0").
func taskToChip(t Task) *pdrender.TaskChip {
	chip := &pdrender.TaskChip{
		Title:  strings.TrimSpace(t.Title),
		Status: strings.TrimSpace(t.Lifecycle),
	}
	if p, ok := parseChipPriority(t.Priority); ok {
		chip.Priority = p
		chip.HasPriority = true
	}
	if t.Criteria != nil && t.Criteria.Total > 0 {
		chip.CriteriaMet = t.Criteria.Met
		chip.CriteriaTotal = t.Criteria.Total
	}
	return chip
}

// parseChipPriority reads the board's display priority string as a 0..4 integer
// for the chip's P-segment. A non-numeric or negative value drops the segment.
func parseChipPriority(s string) (int, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}
