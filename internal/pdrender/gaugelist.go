package pdrender

import (
	"math"
	"sort"
	"strconv"
	"strings"
)

// ── gauge-list ───────────────────────────────────────────────────────────────
//
// The terminal counterpart of a meter/gauge list — the "/usage share rows" read
// (a ranked stack of proportion bars with exact right-aligned readouts), in the
// reader/CLI. This is the most Barkpark-native block of the TUI creative slate:
// its COUNT mode rides the EXISTING task-list wire contract, bucketing real bp
// task rows into a gauge per group. The meter reuses statBar's ▓/░ idiom (the
// same fill glyphs momentumBar / the roadmap track use) — no third glyph pair is
// invented — so the datum lives in the BAR LENGTH + the DIGITS and survives an
// ANSI strip at every profile (the detail-ceiling doctrine: geometry carries the
// datum, colour only reinforces).
//
// CONTRACT (ratified, pbp-tui-creative-slate — gauge-list):
//
//	gauge-list: {mode:'count'|'share', title?, groupBy?, snapshot?, rows?, max?}
//
//	- mode     'count' (default) buckets a task-list snapshot; 'share' draws
//	           author-supplied rows. Absent mode is inferred: a bare `rows` key
//	           (no `snapshot`) reads as share, otherwise count.
//	- title    optional bold caption above the gauges.
//	- COUNT MODE ──────────────────────────────────────────────────────────────
//	  groupBy  one of {worker, phase, status, priority}; default "status".
//	           `snapshot` is the VERBATIM task-list row array ({title,status,
//	           priority,criteria,blocked_by,worker,phase,depth}); rows are bucketed
//	           in Go by the groupBy field (a missing/empty field → the "(none)"
//	           bucket), sorted DESC by count then label ASC, meter = count/maxCount.
//	           groupBy "epic" is UNBACKED here (the parent→epic join is the WAVE-3
//	           resolver's job): it renders a dim honest note, NEVER faked from a
//	           parent_id. Absent `snapshot` → the dim unresolved placeholder.
//	- SHARE MODE ──────────────────────────────────────────────────────────────
//	  rows     [{label, value, note?}]; meter = value/max when `max` is positive,
//	           else value/Σ. Author order is preserved. Absent `rows` → the dim
//	           unresolved placeholder.
//
// SNAPSHOT-AUTHORITATIVE: the block draws WHATEVER is in Attrs and never fetches;
// the `query` field (the inert forward contract for the already-merged Elixir
// aggregate resolver, wired in a future slice) is NEVER read. When the mode's
// data key is absent the block degrades HONESTLY to `[gauge-list — unresolved]`
// rather than pretending. Import discipline holds: only lipgloss (via the Theme)
// + the stdlib; every document-controlled string passes through sanitizeText;
// widths are ANSI-aware and every meter is a FILL over the resolved cell width
// (statBar), never an N-up divide — so the "one solver" tripwire stays green.
type gaugeListRenderer struct{}

func (gaugeListRenderer) Render(b Block, ctx RenderCtx) []string {
	w := clampWidth(ctx.Width)

	var out []string
	if title := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "title"))); title != "" {
		out = append(out, wrapLines(ctx.Theme.Body.Bold(true).Render(title), w)...)
	}

	var gauges []gaugeRow
	switch gaugeMode(b.Attrs) {
	case "share":
		if !resolvedKeyPresent(b, "rows") {
			return append(out, unresolvedPlaceholder(ctx, "gauge-list"))
		}
		gauges = shareGauges(b.Attrs)
		if len(gauges) == 0 {
			return append(out, ctx.Theme.Dim.Render("No data yet."))
		}
	default: // count
		groupBy := strings.TrimSpace(attrStr(b.Attrs, "groupBy"))
		if groupBy == "" {
			groupBy = "status"
		}
		// groupBy "epic" needs the aggregate resolver (parent→epic join) — never
		// fake it from a raw parent_id; render an honest dim note instead.
		if groupBy == "epic" {
			return append(out, ctx.Theme.Dim.Render("epic grouping needs the resolver"))
		}
		if !resolvedKeyPresent(b, "snapshot") {
			return append(out, unresolvedPlaceholder(ctx, "gauge-list"))
		}
		rows := itemMaps(b.Attrs, "snapshot")
		if len(rows) == 0 {
			return append(out, ctx.Theme.Dim.Render("No tasks yet."))
		}
		gauges = countGauges(rows, groupBy)
	}

	return append(out, gaugeRows(gauges, ctx, w)...)
}

// gaugeRow is one resolved meter line: a label, its [0,1] proportion (the bar
// length), the exact right-aligned readout digits (a count or a percent — the
// datum that survives an ANSI strip), and an optional trailing dim note.
type gaugeRow struct {
	label string
	prop  float64
	digit string
	note  string
}

// gaugeMode resolves the mode: an explicit "count"/"share", else inferred — a
// bare `rows` key with no `snapshot` reads as share, otherwise count.
func gaugeMode(m map[string]any) string {
	switch strings.ToLower(strings.TrimSpace(attrStr(m, "mode"))) {
	case "count":
		return "count"
	case "share":
		return "share"
	}
	if _, hasRows := m["rows"]; hasRows {
		if _, hasSnap := m["snapshot"]; !hasSnap {
			return "share"
		}
	}
	return "count"
}

// countGauges buckets the verbatim task-list snapshot rows by the groupBy field
// and returns gauges sorted DESC by count then label ASC, meter = count/maxCount.
func countGauges(rows []map[string]any, groupBy string) []gaugeRow {
	counts := make(map[string]int)
	for _, r := range rows {
		counts[gaugeBucketKey(r, groupBy)]++
	}

	type kv struct {
		label string
		count int
	}
	kvs := make([]kv, 0, len(counts))
	maxCount := 0
	for k, c := range counts {
		kvs = append(kvs, kv{k, c})
		if c > maxCount {
			maxCount = c
		}
	}
	sort.Slice(kvs, func(i, j int) bool {
		if kvs[i].count != kvs[j].count {
			return kvs[i].count > kvs[j].count // desc count
		}
		return kvs[i].label < kvs[j].label // then label asc
	})
	if maxCount <= 0 {
		maxCount = 1 // guard: never divide the meter proportion by zero
	}

	gs := make([]gaugeRow, 0, len(kvs))
	for _, e := range kvs {
		gs = append(gs, gaugeRow{
			label: e.label,
			prop:  float64(e.count) / float64(maxCount),
			digit: strconv.Itoa(e.count),
		})
	}
	return gs
}

// gaugeBucketKey is a task row's group label for the given field. priority is
// bucketed by its P<n> label (priorityLabel); every other field by its trimmed
// string. A missing/empty field → the "(none)" bucket (so unassigned work is
// counted, never dropped).
func gaugeBucketKey(r map[string]any, groupBy string) string {
	var key string
	if groupBy == "priority" {
		key = priorityLabel(attrStr(r, "priority"))
	} else {
		key = strings.TrimSpace(attrStr(r, groupBy))
	}
	if key = sanitizeText(key); key == "" {
		return "(none)"
	}
	return key
}

// shareGauges reads the author-supplied share rows in order. denom = `max` when
// positive, else Σ value (guarded to 1 so an all-zero list never divides by
// zero); the readout digit is the meter's own percent (round(prop*100)%), so the
// digit is the exact reading of the bar.
func shareGauges(m map[string]any) []gaugeRow {
	items := itemMaps(m, "rows")
	if len(items) == 0 {
		return nil
	}
	sum := 0.0
	for _, it := range items {
		sum += attrFloat(it, "value")
	}
	denom := attrFloat(m, "max")
	if denom <= 0 {
		denom = sum
	}
	if denom <= 0 {
		denom = 1
	}

	gs := make([]gaugeRow, 0, len(items))
	for _, it := range items {
		prop := attrFloat(it, "value") / denom
		if prop < 0 {
			prop = 0
		}
		if prop > 1 {
			prop = 1
		}
		gs = append(gs, gaugeRow{
			label: sanitizeText(strings.TrimSpace(attrStr(it, "label"))),
			prop:  prop,
			digit: strconv.Itoa(int(math.Round(prop*100))) + "%",
			note:  sanitizeText(strings.TrimSpace(attrStr(it, "note"))),
		})
	}
	return gs
}

// gaugeRows renders the resolved gauges into aligned meter lines:
// `label  ▓▓▓▓░░░░ digits`. The label column is the widest label capped to a
// third of the surface; the readout column is the widest digit string; the meter
// track fills whatever is left (a subtraction over the already-resolved cell
// width, exactly like statBar — NOT an N-up divide, so the one-solver tripwire
// stays green). Every glyph is profile-agnostic (statBar's ▓/░), so the
// ANSI-stripped line is a complete artifact at all three profiles.
func gaugeRows(gs []gaugeRow, ctx RenderCtx, w int) []string {
	labelW, rightW, noteW := 0, 0, 0
	for _, g := range gs {
		if n := runeWidth(g.label); n > labelW {
			labelW = n
		}
		if n := runeWidth(g.digit); n > rightW {
			rightW = n
		}
		if n := runeWidth(g.note); n > noteW {
			noteW = n
		}
	}
	cap := w / 3
	if cap < 6 {
		cap = 6
	}
	if cap > 24 {
		cap = 24
	}
	if labelW > cap {
		labelW = cap
	}
	if labelW < 1 {
		labelW = 1
	}
	// A note column (share mode) is reserved so the meters keep a common length
	// and every note is visible; capped to a quarter of the surface. Zero when no
	// row carries a note → the render is byte-identical to a note-free list.
	if noteW > 0 {
		ncap := w / 4
		if ncap < 4 {
			ncap = 4
		}
		if noteW > ncap {
			noteW = ncap
		}
	}
	// Meter track = surface − label − digits − (note column) − the joining spaces
	// (label "  " bar " " digits ["  " note]). A FILL over the resolved cell
	// width (like statBar), never an N-up divide.
	reserved := labelW + 2 + rightW + 1
	if noteW > 0 {
		reserved += noteW + 2
	}
	barW := w - reserved
	if barW < 1 {
		barW = 1
	}

	out := make([]string, 0, len(gs))
	for _, g := range gs {
		labelLines := hardBoundDisplayLines([]string{g.label}, labelW)
		if len(labelLines) == 0 {
			labelLines = []string{""}
		}
		noteLines := []string(nil)
		if noteW > 0 && g.note != "" {
			noteLines = hardBoundDisplayLines([]string{g.note}, noteW)
		}
		bar := statBar(g.prop, barW, ctx)
		pad := rightW - runeWidth(g.digit)
		if pad < 0 {
			pad = 0
		}
		digit := strings.Repeat(" ", pad) + ctx.Theme.Body.Render(g.digit)
		rowH := len(labelLines)
		if len(noteLines) > rowH {
			rowH = len(noteLines)
		}
		for i := 0; i < rowH; i++ {
			label := ""
			if i < len(labelLines) {
				label = labelLines[i]
			}
			line := ctx.Theme.Body.Render(padRight(label, labelW)) + "  "
			if i == 0 {
				line += bar + " " + digit
			} else {
				line += strings.Repeat(" ", barW+1+rightW)
			}
			if i < len(noteLines) {
				line += "  " + ctx.Theme.Dim.Render(noteLines[i])
			}
			out = append(out, line)
		}
	}
	return out
}
