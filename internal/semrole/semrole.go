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

import "strings"

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
//   - Task-lifecycle tokens (bp task … -o table, the portrait board):
//     in_progress → info; blocked → warn; done/closed → ok; ready/open/cancelled
//     → "" (neutral). "cancelled" is terminal-but-not-done, matching the board's
//     RoleFor default for that case.
//
// The two sets are disjoint, so the union is unambiguous.
func For(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	// --- cloud / deploy / health vocabulary (moved verbatim from
	// internal/cli statusRole; the decision-32 attention fixture pins these
	// tones and holds this table to them) ---
	case "live", "up", "online", "ok":
		return "ok"
	case "queued", "building", "pushing", "provisioning", "pending", "removing", "behind":
		return "info"
	case "degraded", "unknown", "suspended":
		return "warn"
	case "failed", "error", "offline", "removal_failed":
		return "danger"

	// --- task-lifecycle vocabulary (added by the reconciliation slice;
	// mirrors taskboard.RoleFor so `bp task … -o table` colours lifecycle
	// cells for free) ---
	case "in_progress":
		return "info"
	case "blocked":
		return "warn"
	case "done", "closed":
		return "ok"
	case "ready", "open", "cancelled":
		return "" // neutral / uncoloured — no urgency (cancelled is terminal-but-not-done)

	default:
		return "" // unknown token → neutral, never a guess
	}
}
