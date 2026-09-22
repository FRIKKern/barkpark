package taskboard

import (
	"strings"
	"testing"
	"time"
)

// ── ARM 1 (the RED arm) ────────────────────────────────────────────────────
// The 40-char emitter slice is the whole defect. 97.9% of live titles (9273 of
// 9467, measured 2026-09-17) slug LONGER than 40 chars, so a join written as
// `slugify(title) == segment` matches nothing real. This arm uses a REAL live
// title and the label its emitter would produce: revert agentEmitterSlug to a
// plain slugify (drop the cap) and it fails. It cannot pass vacuously — the
// asserted DocID is the specific row, not "some match".

// liveLongTitle is a verbatim live row (doc_id dr-w10-f1-zombied-run-remediation)
// whose slug is 69 chars — the emitter slices it to 40.
const liveLongTitle = "A ZOMBIED run is detected but never re-dispatched — the remediation half"

// liveTrailingHyphenLabel is what bp-epic-cycle emits for that title: the slice
// lands mid-word and leaves a TRAILING hyphen, a form slugify can never produce.
const liveTrailingHyphenLabel = "build:a-zombied-run-is-detected-but-never-re-d"

func TestJoinAgentTaskMatchesTheEmitterSlugNotTheFullSlug(t *testing.T) {
	tasks := []Task{
		{DocID: "dr-w10-f1-zombied-run-remediation", Title: liveLongTitle},
		{DocID: "unrelated", Title: "Some other row entirely"},
	}
	// The full slug is longer than the budget and ends WITHOUT a hyphen, so a
	// cap-less join literally cannot produce this label's key. Assert that first
	// so the arm's premise is visible, not assumed.
	full := slugify(liveLongTitle)
	if len(full) <= agentSlugBudget {
		t.Fatalf("fixture no longer exercises the cap: slug is %d chars", len(full))
	}
	if strings.HasSuffix(full, "-") {
		t.Fatalf("fixture premise broken: slugify must not emit a trailing hyphen")
	}
	j, ok := JoinAgentTask(liveTrailingHyphenLabel, tasks)
	if !ok {
		t.Fatalf("no join for the live emitter label %q (key=%q, emitted slug=%q)",
			liveTrailingHyphenLabel, mustKey(t, liveTrailingHyphenLabel), agentEmitterSlug(liveLongTitle))
	}
	if j.Task.DocID != "dr-w10-f1-zombied-run-remediation" {
		t.Fatalf("joined the wrong row: %q", j.Task.DocID)
	}
	if j.DeepLink != "/admin/projects?task=dr-w10-f1-zombied-run-remediation" {
		t.Fatalf("deep link = %q", j.DeepLink)
	}
}

// Both emitter grammars must land on the SAME task: one colon segment
// (bp-epic-cycle) and two (wild-bulk). The two-segment case is the one that
// breaks if the join ever reuses chat's first-colon display grammar.
func TestJoinAgentTaskHandlesBothLabelGrammars(t *testing.T) {
	tasks := []Task{{DocID: "t-1", Title: "Rewire the fold"}}
	for _, label := range []string{"build:rewire-the-fold", "build:console:rewire-the-fold"} {
		j, ok := JoinAgentTask(label, tasks)
		if !ok || j.Task.DocID != "t-1" {
			t.Fatalf("label %q did not join to t-1 (ok=%v)", label, ok)
		}
		if j.Key != "rewire-the-fold" {
			t.Fatalf("label %q resolved key %q, want the LAST segment", label, j.Key)
		}
	}
	// The first-colon grammar would yield "console:rewire-the-fold" here, which
	// is not slug-shaped and joins to nothing. Pin that they really differ, so a
	// later "just reuse workflowLabelParts" edit has a failing test waiting.
	if k, ok := AgentLabelTaskKey("build:console:rewire-the-fold"); !ok || k == "console:rewire-the-fold" {
		t.Fatalf("last-segment key collapsed into the first-colon grammar: %q", k)
	}
}

// ── ARM 2 (the QUIET arm) ──────────────────────────────────────────────────
// Ambiguity and no-match must render NOTHING. On the live corpus 62 emitted
// slugs are shared by 2-5 different tasks (133 rows), so this is the common
// case, not a corner. This arm stays quiet under the RED arm's mutation (both
// candidates would simply stop matching, and ok=false either way) — which is
// exactly why the third mutation below exists.
func TestJoinAgentTaskDegradesToNothing(t *testing.T) {
	ambiguous := []Task{
		{DocID: "a-1", Title: "Historical smoke record cmux smoke t2 1700"},
		{DocID: "a-2", Title: "Historical smoke record cmux smoke t2 1701"},
	}
	// Premise: the 40-char slice really does collide these two DIFFERENT titles.
	if agentEmitterSlug(ambiguous[0].Title) != agentEmitterSlug(ambiguous[1].Title) {
		t.Fatalf("fixture no longer collides: %q vs %q",
			agentEmitterSlug(ambiguous[0].Title), agentEmitterSlug(ambiguous[1].Title))
	}
	if ambiguous[0].Title == ambiguous[1].Title {
		t.Fatal("fixture premise broken: the two rows must be genuinely different work")
	}
	if _, ok := JoinAgentTask("build:"+agentEmitterSlug(ambiguous[0].Title), ambiguous); ok {
		t.Fatal("an ambiguous key produced a match — a builder's evidence would pin to the wrong row")
	}
	// No match at all.
	if _, ok := JoinAgentTask("build:nothing-named-this", ambiguous); ok {
		t.Fatal("an unmatched key produced a match")
	}
	// Not slug-shaped: free prose names no task.
	for _, label := range []string{"Digest the survey", "verify:Encryption Leak", "build:", "", "   "} {
		if _, ok := JoinAgentTask(label, ambiguous); ok {
			t.Fatalf("label %q joined to something", label)
		}
	}
	// A drafts twin of the SAME row is one candidate, not an ambiguity.
	twins := []Task{
		{DocID: "drafts.t-9", Title: "Rewire the fold"},
		{DocID: "t-9", Title: "Rewire the fold"},
	}
	j, ok := JoinAgentTask("build:rewire-the-fold", twins)
	if !ok {
		t.Fatal("a drafts twin pair read as ambiguous — collapseDraftTwins is not being applied")
	}
	if j.DeepLink != "/admin/projects?task=t-9" {
		t.Fatalf("deep link kept a drafts spelling: %q", j.DeepLink)
	}
}

// ── ARM 3 (what the QUIET arm discriminates) ──────────────────────────────
// A quiet arm that only ever asserts ok==false can pass on a join that matches
// NOTHING, ever. This arm is the control the quiet arm lacks: it is the
// mutation "make the ambiguity check pick the first candidate instead of
// bailing" turned into a positive assertion — the SAME two colliding titles,
// but with one of them removed, must now join. If the join degenerated to
// always-nothing, this reds while TestJoinAgentTaskDegradesToNothing stays
// green; if the ambiguity guard is deleted, the degrade test reds while this
// stays green. Neither test alone separates the two failures.
func TestJoinAgentTaskStillMatchesOnceTheCollisionIsGone(t *testing.T) {
	colliding := "Historical smoke record cmux smoke t2 1700"
	key := "build:" + agentEmitterSlug(colliding)
	single := []Task{
		{DocID: "a-1", Title: colliding},
		{DocID: "b-1", Title: "Something with a completely different name"},
	}
	j, ok := JoinAgentTask(key, single)
	if !ok {
		t.Fatalf("the unambiguous form of the colliding key did not join (key=%q)", key)
	}
	if j.Task.DocID != "a-1" {
		t.Fatalf("joined %q, want a-1", j.Task.DocID)
	}
}

// The projected line must omit every figure the wire did not carry, and carry
// each one it did. A padded "0/0 criteria" on a criteria-less row is the exact
// fabrication the row's purpose forbids.
func TestAgentTaskSummaryOmitsAbsentFigures(t *testing.T) {
	now := time.Date(2026, 9, 17, 4, 0, 0, 0, time.UTC)
	bare := Task{DocID: "t-1", Title: "Rewire the fold"}
	j, ok := JoinAgentTask("build:rewire-the-fold", []Task{bare})
	if !ok {
		t.Fatal("setup join failed")
	}
	got := AgentTaskSummary(j, now)
	if got != "t-1 · /admin/projects?task=t-1" {
		t.Fatalf("bare row summary = %q", got)
	}
	if strings.Contains(got, "0/0") || strings.Contains(got, "▸") {
		t.Fatalf("summary fabricated an absent figure: %q", got)
	}

	rich := bare
	rich.Criteria = &Criteria{Met: 2, Total: 4}
	rich.Claim = &Claim{Worker: "cli-r20c-w19", Now: &ClaimPulse{
		Text: "writing the join helper", At: now.Add(-7 * time.Minute),
	}}
	j, ok = JoinAgentTask("build:rewire-the-fold", []Task{rich})
	if !ok {
		t.Fatal("setup join failed on the rich row")
	}
	got = AgentTaskSummary(j, now)
	want := "t-1 · 2/4 criteria · ▸ writing the join helper (7m) · /admin/projects?task=t-1"
	if got != want {
		t.Fatalf("rich summary =\n  %q\nwant\n  %q", got, want)
	}

	// A claim with no now-line renders no now-line — never an empty ▸.
	unpulsed := rich
	unpulsed.Claim = &Claim{Worker: "w"}
	j, _ = JoinAgentTask("build:rewire-the-fold", []Task{unpulsed})
	if got := AgentTaskSummary(j, now); strings.Contains(got, "▸") {
		t.Fatalf("un-pulsed claim painted a now-line: %q", got)
	}
}

// The Go emitter reproduction must equal the JS emitter on real live titles.
// These pairs were computed by running the verbatim workflow slug() over the
// live guerrilla corpus (bp task ls --all, 9467 rows, 2026-09-17); they are the
// wire's own answer, not a re-derivation of this file's logic.
func TestAgentEmitterSlugMatchesTheWorkflowEmitter(t *testing.T) {
	cases := []struct{ title, want string }{
		{liveLongTitle, "a-zombied-run-is-detected-but-never-re-d"},
		{"deployments.status is an unconstrained varchar, so an unknown status enters the census as silent success",
			"deployments-status-is-an-unconstrained-v"},
		{"The Console gate's nothing-ran green is announced by a single ::notice:: annotation, and GitHub caps annotations at 10 per level per step",
			"the-console-gate-s-nothing-ran-green-is-"},
		{"Rewire the fold", "rewire-the-fold"}, // short: cap is a no-op
	}
	for _, c := range cases {
		if got := agentEmitterSlug(c.title); got != c.want {
			t.Errorf("agentEmitterSlug(%q)\n = %q\nwant %q", c.title, got, c.want)
		}
	}
}

func mustKey(t *testing.T, label string) string {
	t.Helper()
	k, _ := AgentLabelTaskKey(label)
	return k
}
