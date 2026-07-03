package semrole

import (
	"sort"
	"testing"
)

// cloudTokens is the pinned cloud/deploy/health half of the vocabulary — the
// exact token set moved verbatim from internal/cli statusRole. The disjointness
// tripwire below keys off this list.
var cloudTokens = []string{
	"live", "up", "online", "ok",
	"queued", "building", "pushing", "provisioning", "pending", "removing", "behind",
	"degraded", "unknown", "suspended",
	"failed", "error", "offline", "removal_failed",
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
		"failed": "danger", "error": "danger", "offline": "danger", "removal_failed": "danger",
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
// published set carries exactly the seven known tokens (extend both this pin
// and taskboard.RoleFor when the vocabulary grows — the taskboard parity test
// enforces the latter automatically).
func TestTaskLifecyclesMatchesFor(t *testing.T) {
	want := []string{"blocked", "cancelled", "closed", "done", "in_progress", "open", "ready"}
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
