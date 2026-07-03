// Package semrole is the one shared owner of Barkpark's status→semantic-role
// vocabulary. A "role" is one of the product's four semantic colour tokens —
// ok | info | warn | danger — or "" meaning neutral/uncoloured (never a guess).
// The same four roles are the cloud SPA's --ok/--info/--warn/--danger design
// tokens, so a status cell in a `bp` table, a dot in the dashboard, and a card
// in the portrait task board all mean the same thing. Colour means STATE, never
// decoration.
//
// This package holds ONLY the vocabulary. It renders nothing: the CLI keeps its
// ANSI painter (internal/cli ansiForRole) and the task board keeps its lipgloss
// styles (internal/taskboard) — both consult For for the mapping so the
// vocabulary can never drift between surfaces.
package semrole

import (
	"sort"
	"strings"
)

// taskLifecycleRoles is the task-lifecycle half of the vocabulary (added by the
// reconciliation slice; mirrors taskboard.RoleFor so `bp task … -o table`
// colours lifecycle cells for free). ready/open carry no urgency and
// "cancelled" is terminal-but-not-done — all three are neutral (""), matching
// the board's RoleFor default for them. Kept as a map (not switch cases) so
// TaskLifecycles can publish the full token set: the task board's parity test
// iterates it, which turns "token added here but not to taskboard.RoleFor" into
// a guaranteed CI failure instead of a silent cross-surface drift. Keys MUST
// stay disjoint from the cloud switch in For below — a task entry is consulted
// first and would shadow a same-named cloud token (TestVocabulariesDisjoint
// trips on any overlap).
var taskLifecycleRoles = map[string]string{
	"in_progress": "info",
	"blocked":     "warn",
	"done":        "ok",
	"closed":      "ok",
	"ready":       "",
	"open":        "",
	"cancelled":   "",
}

// TaskLifecycles returns every task-lifecycle token this package maps, sorted.
// It exists for parity tests: any surface with its own lifecycle→role mapping
// (internal/taskboard RoleFor) iterates this list against For, so extending the
// vocabulary here forces every surface to keep up in the same commit.
func TaskLifecycles() []string {
	tokens := make([]string, 0, len(taskLifecycleRoles))
	for t := range taskLifecycleRoles {
		tokens = append(tokens, t)
	}
	sort.Strings(tokens)
	return tokens
}

// For maps a status-like token to its semantic colour role, returning one of
// "ok", "info", "warn", "danger", or "" (neutral/uncoloured) when the token is
// not a recognised status. The match is case-insensitive on the trimmed value;
// an unknown string yields "" — For never guesses.
//
// Two vocabularies share this table:
//
//   - Cloud / deploy / health tokens (from PR #979's CLI tables and the control
//     plane): live/up/online/ok → ok; queued/building/pushing/provisioning/
//     pending/removing/behind → info ("behind" is news, not an alarm);
//     degraded/unknown/suspended → warn; failed/error/offline/removal_failed →
//     danger.
//   - Task-lifecycle tokens (bp task … -o table, the portrait board): see
//     taskLifecycleRoles above.
//
// The two sets are disjoint, so the union is unambiguous.
func For(status string) string {
	token := strings.ToLower(strings.TrimSpace(status))
	if role, ok := taskLifecycleRoles[token]; ok {
		return role
	}
	switch token {
	// --- cloud / deploy / health vocabulary (moved verbatim from
	// internal/cli statusRole; the decision-32 attention fixture pins these
	// tones and holds this table to them) ---
	case "live", "up", "online", "ok":
		return "ok"
	case "queued", "building", "pushing", "provisioning", "pending", "removing", "behind":
		return "info"
	// "inactive" is the webhook list's manually-switched-off state, kept
	// distinct from "suspended" (the system-imposed instance state).
	case "degraded", "unknown", "suspended", "inactive":
		return "warn"
	case "failed", "error", "offline", "removal_failed":
		return "danger"
	default:
		return "" // unknown token → neutral, never a guess
	}
}
