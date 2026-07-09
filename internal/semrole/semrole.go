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

	"github.com/charmbracelet/lipgloss"
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

// Roles returns the four semantic colour roles in canonical order. Every role
// has a generated adaptive tone (GenStatusTone) and a pinned ANSI-16 floor
// (GenANSI16) in tokens_gen.go.
func Roles() []string { return []string{"ok", "info", "warn", "danger"} }

// Themes returns every registered theme id in a stable order: DefaultTheme
// (evergreen) first, the rest lexicographically. It is the enumeration seam the
// all-themes surfaces (`bp style`'s per-theme slate, the Studio showroom matrix)
// loop so they GROW when theme N+1 lands: genTones (tokens_gen.go) gains one
// keyed entry and every caller widens with zero code edits — the "adding theme
// N+1 touches exactly one new file" invariant made observable. Keyed off the
// same genTones the RoleColorFor/LifecycleColorFor accessors read, so it can
// never list a theme those accessors can't resolve.
func Themes() []string {
	rest := make([]string, 0, len(genTones))
	haveDefault := false
	for id := range genTones {
		if id == DefaultTheme {
			haveDefault = true
			continue
		}
		rest = append(rest, id)
	}
	sort.Strings(rest)
	out := make([]string, 0, len(genTones))
	if haveDefault {
		out = append(out, DefaultTheme)
	}
	return append(out, rest...)
}

// RoleColor returns the generated adaptive tone for one of the four semantic
// roles (ok/info/warn/danger), reading GenStatusTone directly — the role IS the
// key, no status-token resolution. It returns the lipgloss.AdaptiveColor
// UNFLATTENED (never a pre-baked hex) so lipgloss/termenv preserves the
// truecolor→256→16→NO_COLOR degradation ladder through the active colour
// profile. An unrecognised role yields the zero AdaptiveColor and ok=false —
// callers must not paint on !ok (RoleColor never guesses). This is the surface
// seam the CLI/TUI paint their status dots through, so an `ok` dot in a `bp`
// table is byte-identically the same design token as the SPA's --ok.
func RoleColor(role string) (color lipgloss.AdaptiveColor, ok bool) {
	return RoleColorFor(DefaultTheme, role)
}

// RoleColorFor is the theme-parameterized RoleColor: it reads the status tone for
// one role out of Resolve(theme) (tokens_gen.go's theme-keyed map), defaulting to
// the evergreen skin for an unknown/empty theme id. RoleColor is this with the
// default theme — the byte-frozen evergreen accessor every current caller uses.
// The seam a later wave threads a resolved theme id through so a `bp` status dot
// changes with the theme identity, orthogonally to light/dark mode.
func RoleColorFor(theme, role string) (color lipgloss.AdaptiveColor, ok bool) {
	tone, found := Resolve(theme).StatusTone[role]
	return tone, found
}

// LifecycleColor returns the generated adaptive glyph hue for a lifecycle state
// (in_progress/blocked/done/closed/cancelled/ready/open), reading
// GenLifecycleHue directly. Like RoleColor it returns the AdaptiveColor
// UNFLATTENED so the profile ladder is preserved, and yields the zero value with
// ok=false for any non-lifecycle string — never a guess. done/closed stay TEAL
// here (their lifecycle hue), deliberately distinct from status.ok green.
func LifecycleColor(state string) (color lipgloss.AdaptiveColor, ok bool) {
	return LifecycleColorFor(DefaultTheme, state)
}

// LifecycleColorFor is the theme-parameterized LifecycleColor, reading the glyph
// hue out of Resolve(theme).LifecycleHue and defaulting to evergreen for an
// unknown/empty id. LifecycleColor is this with the default theme.
func LifecycleColorFor(theme, state string) (color lipgloss.AdaptiveColor, ok bool) {
	hue, found := Resolve(theme).LifecycleHue[state]
	return hue, found
}

// ChromeColorFor returns a theme's CLI/TUI chrome role colour (chrome-accent,
// chrome-text-secondary, chrome-dim, chrome-ink, …) out of ResolveChrome(theme),
// defaulting to evergreen for an unknown/empty id. It is the chrome peer of
// RoleColorFor: the taskboard reads its neutral/dim/title chrome through it so a
// theme change moves the board's chrome with every other surface. An unrecognised
// role yields the zero AdaptiveColor and ok=false — callers must not paint on !ok.
func ChromeColorFor(theme, role string) (color lipgloss.AdaptiveColor, ok bool) {
	c, found := ResolveChrome(theme).Chrome[role]
	return c, found
}

// Color resolves a coloured token to its light/dark hex pair, sourced from the
// generated tokens_gen.go (design/tokens.json). Two paint layers, in order:
//
//   - A lifecycle state (in_progress, done, cancelled, …) paints its LIFECYCLE
//     glyph hue — so `done` is teal, not ok-green (Decision 4). This includes
//     the neutral-role states (cancelled/ready/open), which still carry a hue.
//   - Any other token routes through For to its semantic status role tone
//     (ok/info/warn/danger).
//
// colored is false only when the token is neither a lifecycle state nor a
// recognised status — the caller leaves it unpainted (Color never guesses,
// mirroring For). By construction, colored ⇒ the token is a lifecycle state or
// For(token) != "" (TestColorAgreesWithFor pins this).
func Color(token string) (light, dark string, colored bool) {
	t := strings.ToLower(strings.TrimSpace(token))
	if hue, ok := GenLifecycleHue[t]; ok {
		return hue.Light, hue.Dark, true
	}
	if role := For(t); role != "" {
		tone := GenStatusTone[role]
		return tone.Light, tone.Dark, true
	}
	return "", "", false
}
