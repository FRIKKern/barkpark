package semrole

import "testing"

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
