package taskboard

import (
	"strings"
	"time"
)

// agentjoin.go — the AGENT↔TASK join (task wsc-bl-agent-task-join, criterion 2).
//
// A running epic/wild-bulk builder is a workflow agent NODE carrying a label;
// the work it advances is a bp TASK row. Today those are two disconnected
// readings: the rail shows an agent, the board shows a task, and nothing says
// they are the same work. This file is the one place that says so, as a PURE
// predicate over (label, []Task) both readers share — the terminal's workflow
// agent-detail pane today, Studio's Doing strip when the api half lands.
//
// THE GRAMMAR (measured, not assumed). Two emitters produce builder labels:
//
//	bp-epic-cycle.workflow.js:1087   `build:${slug(item.title)}`        one segment
//	wild-bulk-cycle.workflow.js:818  `build:${d.slug}:${slug(t.title)}` two segments
//
// so the task token is the LAST colon-segment, never the first. This is
// deliberately NOT chat's workflowLabelParts/1 (the D59 DISPLAY grammar, which
// splits at the FIRST colon): on `build:console:foo` the display grammar yields
// "console:foo" and the join needs "foo". Two grammars, two helpers, no reuse.
//
// THE SLUG (the part a naive join gets wrong). Both emitters share
//
//	slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,40)
//
// — a 40-character SLICE applied AFTER the trim. slugify (repoctx.go) is the
// same kebab with no cap, so on the live guerrilla corpus (9467 rows, measured
// 2026-09-17) slugify(title) differs from the emitted slug on 9273 of them —
// 97.9%. A join written as `slugify(title) == segment` would therefore match
// essentially NOTHING while looking correct in a fixture with short titles.
// Worse, the post-trim slice leaves a TRAILING hyphen on 1550 live titles
// ("...-re-d"), a form slugify can never produce. agentEmitterSlug reproduces
// the emitter byte-for-byte, and the join accepts the uncapped slug too so a
// short title (where the two agree) and a future uncapped emitter both land.
//
// AMBIGUITY IS NOT HYPOTHETICAL. On that same corpus 62 emitted slugs are
// shared by 2-5 DIFFERENT tasks (133 rows) — the 40-char slice manufactures
// collisions that the full titles do not have. An ambiguous key therefore
// resolves to NOTHING: the pane shows no task line at all rather than pinning a
// builder's evidence to the wrong row. A no-match degrades the same way. There
// is no "best guess" tier here by design.
const agentSlugBudget = 40

// agentEmitterSlug reproduces the workflow emitters' slug() exactly: the shared
// kebab, then a 40-BYTE slice with NO re-trim. slugify's output is ASCII-only,
// so the byte slice is also a rune slice. The missing re-trim is not an
// oversight — it is what the emitters do, and reproducing it is the only reason
// the 1550 trailing-hyphen live labels can ever join.
func agentEmitterSlug(title string) string {
	s := slugify(title)
	if len(s) > agentSlugBudget {
		s = s[:agentSlugBudget]
	}
	return s
}

// AgentLabelTaskKey returns the task-slug token of a workflow agent label: the
// LAST colon-segment, lowercased and trimmed. ok is false when the token is
// empty or is not slug-shaped ([a-z0-9-]+) — a free-prose label ("Digest the
// survey") names no task, and treating it as a key would invite a fuzzy match
// this join deliberately does not have.
func AgentLabelTaskKey(label string) (string, bool) {
	key := strings.ToLower(strings.TrimSpace(label))
	if i := strings.LastIndexByte(key, ':'); i >= 0 {
		key = strings.TrimSpace(key[i+1:])
	}
	if key == "" {
		return "", false
	}
	for i := 0; i < len(key); i++ {
		c := key[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return "", false
		}
	}
	return key, true
}

// AgentTaskJoin is the resolved agent↔task edge and the facts BOTH readers
// render from it: the claimed row's live pulse now-line, its criteria
// met-count, and the Studio deep link. It carries no styling and no terminal
// width — the TUI paints it with its own theme, Studio with its own markup,
// from one set of facts.
type AgentTaskJoin struct {
	Label string // the agent label the join started from
	Key   string // the last-colon-segment slug that matched
	Task  Task   // the matched row
	// DeepLink is the Studio route that opens the row: /admin/projects?task=<id>
	// (the live consumers are chat_tool_renderer.ex:430-436 and
	// board_live.ex:246-253). Always the BARE id — a drafts.-prefixed twin
	// collapses to its published spelling before the link is minted.
	DeepLink string
	// Pulse is the claim's now-line (content.claim.now), nil when the holder has
	// never pulsed. Never synthesized: no pulse renders no now-line.
	Pulse *ClaimPulse
	// Met/Total mirror criteria_progress; HasCriteria is false when the envelope
	// omitted it, so the reader omits the meter instead of painting 0/0.
	Met, Total  int
	HasCriteria bool
}

// AgentTaskDeepLink is the Studio route for a task row. Exported because the
// link is a CONTRACT with two Elixir consumers, not a render detail.
func AgentTaskDeepLink(docID string) string {
	return "/admin/projects?task=" + bareID(docID)
}

// AgentTaskIndex is the join's precomputed candidate map: emitted-slug (and,
// where it differs, uncapped slug) -> the rows carrying it. Building it once is
// not a micro-optimisation — the live corpus is ~9.5k rows, and the terminal
// asks this question on every paint of an open agent-detail pane, so a scan per
// call is O(rows) per frame plus a full collapseDraftTwins allocation each
// time. It is also what makes a whole-corpus sweep (the liveprobe arm) finish:
// key-by-key JoinAgentTask over 9.5k keys is 9.5k scans.
//
// A key whose slice holds more than one DISTINCT row is ambiguous and resolves
// to nothing — the ambiguity lives in the index, so every consumer degrades the
// same way without re-deriving the rule.
type AgentTaskIndex struct {
	byKey map[string][]Task
}

// NewAgentTaskIndex builds the join index. Draft twins are collapsed exactly as
// BuildBoard collapses them, so a drafts.X/X pair is one candidate rather than
// a manufactured ambiguity.
func NewAgentTaskIndex(tasks []Task) AgentTaskIndex {
	idx := AgentTaskIndex{byKey: make(map[string][]Task, len(tasks))}
	for _, t := range collapseDraftTwins(tasks) {
		if t.Title == "" {
			continue
		}
		full := slugify(t.Title)
		emitted := full
		if len(emitted) > agentSlugBudget {
			emitted = emitted[:agentSlugBudget]
		}
		idx.byKey[emitted] = append(idx.byKey[emitted], t)
		if full != emitted {
			idx.byKey[full] = append(idx.byKey[full], t)
		}
	}
	return idx
}

// Len reports how many distinct keys the index holds — the liveprobe arm's
// denominator, and the honest answer to "is this index empty?".
func (idx AgentTaskIndex) Len() int { return len(idx.byKey) }

// Keys returns every indexed key. Order is map order (unspecified); callers
// that need determinism sort it.
func (idx AgentTaskIndex) Keys() []string {
	out := make([]string, 0, len(idx.byKey))
	for k := range idx.byKey {
		out = append(out, k)
	}
	return out
}

// Rows returns the rows carrying key — len > 1 is the ambiguous population.
func (idx AgentTaskIndex) Rows(key string) []Task { return idx.byKey[key] }

// Join resolves one workflow agent label against the index. Exactly one
// distinct row must carry the label's last colon-segment; zero (no match) and
// two or more (ambiguous) both return ok=false and the caller renders NOTHING.
func (idx AgentTaskIndex) Join(label string) (AgentTaskJoin, bool) {
	key, ok := AgentLabelTaskKey(label)
	if !ok {
		return AgentTaskJoin{}, false
	}
	rows := idx.byKey[key]
	var match Task
	found := 0
	for _, t := range rows {
		if found > 0 && bareID(t.DocID) == bareID(match.DocID) {
			continue // the same row indexed under both slug forms is not an ambiguity
		}
		found++
		if found > 1 {
			return AgentTaskJoin{}, false // ambiguous — show nothing, never guess
		}
		match = t
	}
	if found != 1 {
		return AgentTaskJoin{}, false
	}
	j := AgentTaskJoin{
		Label:    label,
		Key:      key,
		Task:     match,
		DeepLink: AgentTaskDeepLink(match.DocID),
	}
	if match.Claim != nil {
		j.Pulse = match.Claim.Now
	}
	if match.Criteria != nil {
		j.Met, j.Total, j.HasCriteria = match.Criteria.Met, match.Criteria.Total, true
	}
	return j, true
}

// JoinAgentTask resolves one workflow agent label to the task it advances.
// Candidates are matched on the label's last colon-segment against BOTH the
// emitter slug (capped at 40) and the uncapped slugify of each task's title.
// Exactly one distinct task must match; zero (no match) and two or more
// (ambiguous) both return ok=false, and the caller renders NOTHING. Draft twins
// are collapsed first — exactly as BuildBoard collapses them — so a
// drafts.X/X pair is one candidate, not an ambiguity.
//
// It is the ONE-SHOT convenience form: it builds a whole AgentTaskIndex per
// call, so a surface that asks per paint or per row must hold an index instead
// (that is the whole reason AgentTaskIndex is exported).
func JoinAgentTask(label string, tasks []Task) (AgentTaskJoin, bool) {
	return NewAgentTaskIndex(tasks).Join(label)
}

// AgentTaskSummary is the one-line plain-text projection both readers paint:
//
//	<doc_id> · <met>/<total> criteria · ▸ <pulse text> (<age>) · <deep link>
//
// Every segment is omitted when its figure is absent from the wire — an
// un-pulsed claim shows no now-line, a criteria-less row shows no meter — so
// the line is short and honest rather than padded with zeros. No ANSI, no
// width clamp: the caller styles and truncates.
func AgentTaskSummary(j AgentTaskJoin, now time.Time) string {
	parts := []string{bareID(j.Task.DocID)}
	if j.HasCriteria {
		parts = append(parts, itoa(j.Met)+"/"+itoa(j.Total)+" criteria")
	}
	if j.Pulse != nil && strings.TrimSpace(j.Pulse.Text) != "" {
		line := "▸ " + strings.TrimSpace(j.Pulse.Text)
		if !j.Pulse.At.IsZero() {
			line += " (" + compactAge(now.Sub(j.Pulse.At)) + ")"
		}
		parts = append(parts, line)
	}
	return strings.Join(append(parts, j.DeepLink), " · ")
}

// compactAge renders a duration as the coarse age the now-line carries (a pulse
// is a statement about NOW, so its age is the whole point). Negative clocks read
// "now" rather than a nonsense "-3m".
func compactAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return itoa(int(d/time.Minute)) + "m"
	case d < 24*time.Hour:
		return itoa(int(d/time.Hour)) + "h"
	default:
		return itoa(int(d/(24*time.Hour))) + "d"
	}
}
