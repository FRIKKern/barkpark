package semrole

import (
	"sort"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// cloudTokens is the pinned cloud/deploy/health half of the vocabulary — the
// exact token set moved verbatim from internal/cli statusRole. The disjointness
// tripwire below keys off this list.
var cloudTokens = []string{
	"live", "up", "online", "ok",
	"queued", "building", "pushing", "provisioning", "pending", "removing", "behind",
	"degraded", "unknown", "suspended", "near_limit",
	// The charter-D69 triage rungs (deploy-reliability w5): a box under
	// sustained load, a box whose disk is at the meter's own ceiling, and a live
	// box the control plane has never heard a byte from. Before this slice all
	// three fell to the neutral default and would have shipped UNCOLOURED.
	"strained", "filling", "unreported",
	// jpf-w1 D7: a queued deployment no builder claimed for 5 minutes. Its own
	// word because "queued" is already pinned info/blue three lines up.
	"deploy_stalled",
	// dr-w10-s1 / dr-w24-followup: the deploy verdict and the off-the-train
	// sha, ranks 5 and 6. Warn, not danger — see For's own monotonicity note.
	"deploys_failing", "diverged",
	// The usage-meter STATE token for a read that was attempted and FAILED
	// (dr-w3-s6 followup): before this entry it fell to the neutral default and
	// painted identically to the deliberate "unmetered".
	"unavailable",
	"failed", "error", "offline", "removal_failed", "over_limit",
}

// TestForCloudVocabulary pins the cloud/deploy/health tokens moved verbatim
// from internal/cli statusRole, including case-insensitivity, whitespace
// trimming, and the "unknown → no role" rule (never a guess).
func TestForCloudVocabulary(t *testing.T) {
	cases := map[string]string{
		"live": "ok", "up": "ok", "online": "ok", "ok": "ok", "OK": "ok", " Live ": "ok",
		"queued": "info", "building": "info", "pushing": "info", "provisioning": "info",
		"pending": "info", "removing": "info",
		// "behind" is info, not warn — "update available" is news, not an alarm.
		"behind":   "info",
		"degraded": "warn", "unknown": "warn", "suspended": "warn",
		// The D69 triage rungs share degraded's grammar — a box to LOOK AT, not
		// one that has already failed — and sit between it and "behind" on the
		// ladder, so painting any of them danger would make the tone ladder
		// non-monotone (rank 5 shouting louder than rank 4).
		"strained": "warn", "STRAINED": "warn", " filling ": "warn",
		"filling": "warn", "unreported": "warn",
		// deploy_stalled is warn, NOT the info tone "queued" carries: waiting is
		// news, waiting five minutes with no builder is an alarm.
		"deploy_stalled": "warn", "DEPLOY_STALLED": "warn",
		// deploys_failing and diverged are warn for ladder monotonicity: rank 4
		// (degraded) is warn, so ranks 5 and 6 may not shout louder.
		"deploys_failing": "warn", "DEPLOYS_FAILING": "warn", " diverged ": "warn",
		"diverged": "warn",
		"failed":   "danger", "error": "danger", "offline": "danger", "removal_failed": "danger",
		// Usage-meter quota states: near_limit warns, over_limit is danger.
		"near_limit": "warn", "NEAR_LIMIT": "warn", " over_limit ": "danger", "over_limit": "danger",
		// A meter whose read FAILED is a broken instrument — warn, and tonally
		// distinct from "unmetered", which is deliberate and stays neutral.
		"unavailable": "warn", "UNAVAILABLE": "warn", " unavailable ": "warn",
		"unmetered": "",
		// Unknown strings get NO role.
		"":                    "",
		"banana":              "",
		"42":                  "",
		"a title with spaces": "",
	}
	for in, want := range cases {
		if got := For(in); got != want {
			t.Errorf("For(%q) = %q, want %q", in, got, want)
		}
	}
	// Belt-and-suspenders: every cloud token in the pinned list must resolve to
	// SOME role — a token silently dropped from For's switch would otherwise
	// only fail if its cases-map entry above were dropped in the same edit.
	for _, tok := range cloudTokens {
		if For(tok) == "" {
			t.Errorf("cloud token %q lost its role", tok)
		}
	}
}

// TestVocabulariesDisjoint is the tripwire for the doc-comment claim "the two
// sets are disjoint, so the union is unambiguous". For consults the
// task-lifecycle map BEFORE the cloud switch, so a task entry that reuses a
// cloud token would silently shadow the decision-32 tone. Any overlap fails
// here, in this package, before it can reach a surface.
func TestVocabulariesDisjoint(t *testing.T) {
	task := TaskLifecycles()
	for _, c := range cloudTokens {
		if i := sort.SearchStrings(task, c); i < len(task) && task[i] == c {
			t.Errorf("token %q is in BOTH the cloud and task-lifecycle vocabularies", c)
		}
	}
}

// TestTaskLifecyclesMatchesFor pins TaskLifecycles to the map For consults:
// every published token round-trips through For with the pinned role, and the
// published set carries exactly the nine known tokens — the seven shipped states
// plus the pre-open thought states considering + researching (task-lifecycle-
// visibility epic). Extend both this pin and taskboard.RoleFor when the
// vocabulary grows — the taskboard parity test enforces the latter automatically.
func TestTaskLifecyclesMatchesFor(t *testing.T) {
	want := []string{"blocked", "cancelled", "closed", "considering", "done", "in_progress", "open", "ready", "researching"}
	got := TaskLifecycles()
	if len(got) != len(want) {
		t.Fatalf("TaskLifecycles() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("TaskLifecycles() = %v, want %v (sorted)", got, want)
		}
	}
}

// TestForTaskLifecycleVocabulary pins the task-lifecycle tokens this slice
// added, including case-insensitivity and the neutral ("") terminal states.
func TestForTaskLifecycleVocabulary(t *testing.T) {
	cases := map[string]string{
		"in_progress": "info", "IN_PROGRESS": "info", " in_progress ": "info",
		"blocked": "warn",
		"done":    "ok", "closed": "ok",
		// ready/open have no urgency; cancelled is terminal-but-not-done → neutral.
		"ready": "", "open": "", "cancelled": "",
	}
	for in, want := range cases {
		if got := For(in); got != want {
			t.Errorf("For(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestRoles pins the four semantic roles and their generated companions: every
// role has an adaptive tone and an ANSI-16 floor, and the floor is the pinned
// SGR code — notably info → blue (34), the visible cross-surface coherence fix.
func TestRoles(t *testing.T) {
	want := []string{"ok", "info", "warn", "danger"}
	got := Roles()
	if len(got) != len(want) {
		t.Fatalf("Roles() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Roles() = %v, want %v", got, want)
		}
	}
	for _, r := range got {
		if _, ok := GenStatusTone[r]; !ok {
			t.Errorf("role %q has no generated tone", r)
		}
		if _, ok := GenANSI16[r]; !ok {
			t.Errorf("role %q has no ANSI-16 floor", r)
		}
	}
	floor := map[string]int{"ok": 32, "info": 34, "warn": 33, "danger": 31}
	for r, code := range floor {
		if GenANSI16[r] != code {
			t.Errorf("ANSI-16 floor for %q = %d, want %d", r, GenANSI16[r], code)
		}
	}
}

// TestThemes pins the enumeration seam the all-themes surfaces loop: every
// registered theme id, DefaultTheme first and the rest sorted, every entry
// resolvable through the theme-keyed accessors. This is the contract that makes
// "add theme N+1 → the slate/showroom grow with no code edit" hold — a theme in
// genTones but not returned here (or vice-versa) would silently drop a surface.
func TestThemes(t *testing.T) {
	got := Themes()
	if len(got) == 0 {
		t.Fatal("Themes() returned no themes")
	}
	if got[0] != DefaultTheme {
		t.Errorf("Themes()[0] = %q, want DefaultTheme %q first", got[0], DefaultTheme)
	}
	// exactly the genTones key set, no dupes, no phantom ids
	if len(got) != len(genTones) {
		t.Errorf("Themes() has %d ids, genTones has %d — must be 1:1", len(got), len(genTones))
	}
	seen := map[string]bool{}
	for _, id := range got {
		if seen[id] {
			t.Errorf("Themes() lists %q twice", id)
		}
		seen[id] = true
		if _, ok := genTones[id]; !ok {
			t.Errorf("Themes() lists %q which genTones cannot resolve", id)
		}
	}
	// tail (everything after DefaultTheme) is lexicographically sorted
	for i := 2; i < len(got); i++ {
		if got[i-1] > got[i] {
			t.Errorf("Themes() tail not sorted: %q before %q", got[i-1], got[i])
		}
	}
}

// TestRoleColor pins the role→AdaptiveColor accessor the CLI/TUI paint through:
// every semantic role returns EXACTLY its GenStatusTone entry (the unflattened
// adaptive tone, so the profile degradation ladder is preserved), and any
// non-role string returns the zero value with ok=false — never a guess. A
// lifecycle state is NOT a role, so it too resolves !ok here (that is
// LifecycleColor's job).
func TestRoleColor(t *testing.T) {
	for _, role := range Roles() {
		got, ok := RoleColor(role)
		if !ok {
			t.Errorf("RoleColor(%q) ok=false, want true", role)
			continue
		}
		if want := GenStatusTone[role]; got != want {
			t.Errorf("RoleColor(%q) = %+v, want %+v (GenStatusTone)", role, got, want)
		}
	}
	// Unknown strings, a lifecycle state, and a status TOKEN (not a role) all
	// yield the zero value + ok=false — RoleColor keys on the role name only.
	for _, bad := range []string{"", "banana", "in_progress", "live", "OK"} {
		if got, ok := RoleColor(bad); ok || got != (lipgloss.AdaptiveColor{}) {
			t.Errorf("RoleColor(%q) = %+v ok=%v, want zero/false", bad, got, ok)
		}
	}
}

// TestLifecycleColor pins the lifecycle-state→AdaptiveColor accessor: every
// TaskLifecycles() token returns EXACTLY its GenLifecycleHue entry (unflattened),
// done/closed stay TEAL, and any non-lifecycle string returns zero/false.
func TestLifecycleColor(t *testing.T) {
	for _, state := range TaskLifecycles() {
		got, ok := LifecycleColor(state)
		if !ok {
			t.Errorf("LifecycleColor(%q) ok=false, want true", state)
			continue
		}
		if want := GenLifecycleHue[state]; got != want {
			t.Errorf("LifecycleColor(%q) = %+v, want %+v (GenLifecycleHue)", state, got, want)
		}
	}
	// done/closed carry the teal lifecycle hue, distinct from status.ok green.
	for _, state := range []string{"done", "closed"} {
		if got, _ := LifecycleColor(state); got.Light != "#0d9488" || got.Dark != "#2dd4bf" {
			t.Errorf("LifecycleColor(%q) = %+v, want teal #0d9488/#2dd4bf", state, got)
		}
	}
	// Unknown strings and a status role (not a lifecycle state) yield zero/false.
	for _, bad := range []string{"", "banana", "ok", "danger"} {
		if got, ok := LifecycleColor(bad); ok || got != (lipgloss.AdaptiveColor{}) {
			t.Errorf("LifecycleColor(%q) = %+v ok=%v, want zero/false", bad, got, ok)
		}
	}
}

// TestColorAgreesWithFor is the slice's central invariant: Color paints a token
// iff it is a lifecycle state OR For resolves it to a role. Status tokens paint
// their role tone; lifecycle states paint their lifecycle hue (done stays teal,
// NOT ok-green — Decision 4); unknown tokens stay unpainted.
func TestColorAgreesWithFor(t *testing.T) {
	// Cloud/health tokens all resolve to a role → paint that role's tone.
	for _, tok := range cloudTokens {
		l, d, colored := Color(tok)
		role := For(tok)
		if !colored {
			t.Errorf("Color(%q) uncoloured but For=%q", tok, role)
			continue
		}
		_, isLife := GenLifecycleHue[tok]
		if !isLife && role == "" {
			t.Errorf("Color(%q) coloured but neither a role nor a lifecycle state", tok)
		}
		if !isLife {
			want := GenStatusTone[role]
			if l != want.Light || d != want.Dark {
				t.Errorf("Color(%q) = %s/%s, want role %q tone %s/%s", tok, l, d, role, want.Light, want.Dark)
			}
		}
	}
	// Every lifecycle token is coloured and paints its lifecycle hue.
	for _, tok := range TaskLifecycles() {
		l, d, colored := Color(tok)
		if !colored {
			t.Errorf("Color(%q) lifecycle token is uncoloured", tok)
			continue
		}
		hue := GenLifecycleHue[tok]
		if l != hue.Light || d != hue.Dark {
			t.Errorf("Color(%q) = %s/%s, want lifecycle hue %s/%s", tok, l, d, hue.Light, hue.Dark)
		}
	}
	// done/closed paint TEAL, distinct from status.ok green (Decision 4 tripwire).
	for _, tok := range []string{"done", "closed"} {
		if l, d, _ := Color(tok); l != "#0d9488" || d != "#2dd4bf" {
			t.Errorf("Color(%q) = %s/%s, want teal #0d9488/#2dd4bf", tok, l, d)
		}
	}
	// An unknown token is uncoloured — Color never guesses.
	if l, d, colored := Color("banana"); colored || l != "" || d != "" {
		t.Errorf("Color(banana) = %q/%q colored=%v, want uncoloured", l, d, colored)
	}
	// Case-insensitivity and trimming, inherited from For.
	if l, d, colored := Color("  IN_PROGRESS  "); !colored || l != "#2563eb" || d != "#60a5fa" {
		t.Errorf("Color(' IN_PROGRESS ') = %q/%q colored=%v, want #2563eb/#60a5fa", l, d, colored)
	}
}
