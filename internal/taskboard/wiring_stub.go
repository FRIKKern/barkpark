package taskboard

// ─────────────────────────────────────────────────────────────────────────────
// WIRING STUB — DELETE AT MERGE.
//
// This file carries the slice-14 primitives (chip palette + chipSlot/chipText/
// Chips/ChipsAll and the day-scale staleRole) that slice 16 (render + shell
// integration) is BUILT AGAINST but does not own. Every symbol below is copied
// VERBATIM from slice 14's perfected branch
// (loop-epic/chip-primitive-tag-palette-day-scale-sta-0-p: chips.go + the
// theme.go additions), so this branch's goldens match the merged tree — when
// slice 14 lands, the lead DELETES this whole file and the call sites in
// components.go/render.go/program.go compile against the real homes unchanged.
// ─────────────────────────────────────────────────────────────────────────────

import (
	"fmt"
	"hash/fnv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// chipSlotCount is the number of chip hues (theme.go's chipStyle palette). Every
// tag hashes into [0, chipSlotCount); the modulus is pinned by chips_test.go so a
// hash-algorithm change trips CI instead of silently re-coloring every board.
const chipSlotCount = 6

// chipMaxVisible caps how many hued chips a tight row-1 run paints before the
// rest collapse into a single dim "+N" — identity should orient a glance, not
// crowd out the title and state meta.
const chipMaxVisible = 2

// chipMinBudget is the display-column floor under which Chips renders nothing at
// all: a chip run narrower than this can only garble, so a cramped row keeps its
// title + state instead of a truncated half-chip.
const chipMinBudget = 12

// taxonomyPrefixes are the label namespaces whose leading `<prefix>:` is stripped
// from the DISPLAYED chip text (`proj:cloud` shows as `cloud`) while the FULL tag
// still drives the color hash — so `proj:cloud` and `area:cloud` read as two
// distinct hues even though both shorten to `cloud`.
var taxonomyPrefixes = map[string]bool{
	"proj": true, "area": true, "phase": true, "kind": true, "host": true,
}

// chipSlot is the deterministic tag→hue assignment: an FNV-1a 32-bit hash of the
// FULL (unstripped) tag string, mod chipSlotCount. Same tag → same slot on every
// row, every surface, every run — so a reader learns "that hue = perf" once and
// the association holds. Hashing the full tag (not the stripped display text) is
// deliberate: two taxonomy tags that display identically must not collide.
func chipSlot(tag string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(tag))
	return int(h.Sum32() % chipSlotCount)
}

// chipText is a tag's display form: one taxonomy prefix stripped (split on the
// FIRST ':' only when that prefix is a known taxonomy AND a non-empty remainder
// follows — a dangling "proj:" must not become an invisible zero-width chip).
// A bare tag, or a ':' under an unrecognized prefix, is shown verbatim.
func chipText(tag string) string {
	if i := strings.IndexByte(tag, ':'); i > 0 && i < len(tag)-1 && taxonomyPrefixes[tag[:i]] {
		return tag[i+1:]
	}
	return tag
}

// Chips renders a width-safe, styled identity run for a task's labels:
//
//	perf  live  +2  +theme?
//	└hued chips┘ └ovf┘ └suggested (dim)┘
//
// Rules (charter wave-3 chip contract):
//   - Empty labels and the label equal to sectionTag are suppressed — a row never
//     restates the section it already sits under.
//   - At most chipMaxVisible hued chips paint; the remaining eligible tags fold
//     into a dim `+N`.
//   - Chip TEXT strips one taxonomy prefix; chip HUE hashes the full tag.
//   - suggested (when non-empty) always renders LAST as a dim `+<short>?` — a
//     relatedness hint, never a hued (applied) chip, because identity color is
//     earned only once the tag is actually on the task.
//   - Returns "" when budget < chipMinBudget; never exceeds budget display cols.
func Chips(labels []string, suggested, sectionTag string, budget int) string {
	return chipRun(labels, suggested, sectionTag, budget, chipMaxVisible)
}

// ChipsAll is the expanded-detail variant: EVERY eligible label paints hued (no
// chipMaxVisible cap — the expanded view is where the reader asked to see the
// whole tag set), folding to a `+N` only when the budget genuinely runs out.
func ChipsAll(labels []string, suggested, sectionTag string, budget int) string {
	return chipRun(labels, suggested, sectionTag, budget, len(labels))
}

// chipRun is the shared engine behind Chips/ChipsAll: greedy hued chips up to
// maxHued, then an overflow count, then the suggested hint.
func chipRun(labels []string, suggested, sectionTag string, budget, maxHued int) string {
	if budget < chipMinBudget {
		return ""
	}

	// Eligible = non-empty, not the row's own section tag.
	eligible := make([]string, 0, len(labels))
	for _, l := range labels {
		if l == "" || l == sectionTag {
			continue
		}
		eligible = append(eligible, l)
	}

	var tokens []string
	var costs []int // per-token cost actually charged (incl. its joining space)
	used := 0
	// add appends a token if it (plus a leading space when not first) still fits
	// the budget; reports whether it landed.
	add := func(styled string, w int) bool {
		cost := w
		if len(tokens) > 0 {
			cost++ // the joining space
		}
		if used+cost > budget {
			return false
		}
		tokens = append(tokens, styled)
		costs = append(costs, cost)
		used += cost
		return true
	}

	shown := 0
	for _, tag := range eligible {
		if shown >= maxHued {
			break
		}
		text := chipText(tag)
		if !add(chipStyle(chipSlot(tag)).Render(text), disp(text)) {
			break // out of room — the rest fold into overflow
		}
		shown++
	}

	// Overflow must NEVER be silently dropped — a run that paints one chip and
	// hides the rest lies about the task's identity. If `+N` doesn't fit, pop
	// hued chips (growing N) until the honest count lands.
	for overflow := len(eligible) - shown; overflow > 0; overflow++ {
		tok := fmt.Sprintf("+%d", overflow)
		if add(dimStyle.Render(tok), disp(tok)) {
			break
		}
		if len(tokens) == 0 {
			break // unreachable at budget ≥ chipMinBudget; guard anyway
		}
		used -= costs[len(costs)-1]
		tokens = tokens[:len(tokens)-1]
		costs = costs[:len(costs)-1]
		shown--
	}

	if suggested != "" {
		tok := "+" + chipText(suggested) + "?"
		add(dimStyle.Render(tok), disp(tok))
	}

	return strings.Join(tokens, " ")
}

// Chip hues — IDENTITY color, one per chipSlot. Deliberately muted (pastel/300-
// level on dark, mid-600 on light) so they read one notch softer than the four
// saturated ROLE colors: a chip can never be misread as a state signal.
// (Verbatim from slice 14's theme.go — see that branch for the full rationale.)
var chipColors = [chipSlotCount]lipgloss.AdaptiveColor{
	{Light: "#7c3aed", Dark: "#c4b5fd"}, // 0 violet
	{Light: "#0891b2", Dark: "#67e8f9"}, // 1 cyan
	{Light: "#be123c", Dark: "#fda4af"}, // 2 rose
	{Light: "#4d7c0f", Dark: "#bef264"}, // 3 lime
	{Light: "#a21caf", Dark: "#f0abfc"}, // 4 fuchsia
	{Light: "#c2410c", Dark: "#fdba74"}, // 5 orange
}

var chipStyles = func() [chipSlotCount]lipgloss.Style {
	var s [chipSlotCount]lipgloss.Style
	for i, c := range chipColors {
		s[i] = lipgloss.NewStyle().Foreground(c)
	}
	return s
}()

// chipStyle resolves a chip slot to its identity style. Defensive modulo keeps a
// caller that hands a raw hash (rather than a chipSlot result) in bounds.
func chipStyle(slot int) lipgloss.Style {
	slot = ((slot % chipSlotCount) + chipSlotCount) % chipSlotCount
	return chipStyles[slot]
}

// Staleness thresholds — day-scale, distinct from the minute-scale claim lease.
// A live task that has not MOVED in this long is drifting; the tint warms so an
// outdated row is impossible to miss. Boundaries are exclusive (a task at exactly
// the threshold is not yet stale), matching board.go's doneFoldAfter convention.
const (
	staleWarnAfter   = 3 * 24 * time.Hour
	staleDangerAfter = 7 * 24 * time.Hour
)

// staleRole grades a task by time-since-last-update, independent of lifecycle
// role: RoleWarn past 3 days, RoleDanger past 7, RoleNeutral while fresh. A
// TERMINAL task (done/closed/cancelled) is ALWAYS neutral — finished work cannot
// go stale, so an old done row never falsely wears an alarm. This drives the
// day-scale age badge the renderer appends to aging open/ready/blocked rows
// (and to unclaimed in_progress rows, which have no claim-age tint to alarm them).
func staleRole(updatedAt, now time.Time, lifecycle string) Role {
	switch lifecycle {
	case "done", "closed", "cancelled":
		return RoleNeutral
	}
	age := now.Sub(updatedAt)
	switch {
	case age > staleDangerAfter:
		return RoleDanger
	case age > staleWarnAfter:
		return RoleWarn
	default:
		return RoleNeutral
	}
}
