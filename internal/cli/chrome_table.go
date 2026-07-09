package cli

// chrome_table.go — header-driven table chrome for renderHzTable (the ONE shared
// cloud/hetzner table renderer, hetzner_cmd.go). It threads the emitted-but-
// unconsumed provider-identity and instance-lifecycle design tokens
// (internal/semrole/chrome_gen.go: GenProviderMark + GenInstanceLifecycle) into
// the fleet tables so a `bp cloud`/`bp cloud hetzner` list reads with the same
// provider marks and lifecycle hues the Cloud SPA renders — one token emitter,
// both surfaces (Decision 7).
//
// A column is tinted by its HEADER, never by cell contents, so there is zero
// value-collision risk: a PROVIDER column tints identity marks
// (hetzner/azure → GenProviderMark); a STATUS/STATE/LIFECYCLE column tints a
// recognised instance-lifecycle state through its status role hue
// (GenInstanceLifecycle → Role → semrole.RoleColor). An unrecognised cell value
// passes through unpainted — chrome never guesses (mirrors statusRole).
//
// HARD CONTRACT: tint ONLY. paintChromeCell wraps the already-PADDED cell in an
// SGR span (the writer.paintCell idiom) and renderHzTable calls it solely when
// out.color is on — column widths are measured on the BARE strings upstream, so
// color-off (non-tty / NO_COLOR / --no-color) output is byte-identical to a
// build without this file: no glyphs, no invented columns, no injected bytes.
// Gen* colours are read as symbols (never hex — the #1563 ratchet) and rendered
// through lipgloss's ambient colour profile, so the truecolor→256→16→ascii
// degradation ladder is preserved (the golden tests pin the profile).

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/semrole"
	"github.com/charmbracelet/lipgloss"
)

// cellTinter maps a bare cell value to an adaptive colour, reporting ok=false
// when the value is outside its vocabulary (→ leave the cell unpainted).
type cellTinter func(bare string) (lipgloss.AdaptiveColor, bool)

// tinterForHeader returns the tinter for a column header, or nil when the column
// carries no chrome vocabulary. Match is case-insensitive on the header label so
// it works regardless of the upper/lower casing a call site chose.
func tinterForHeader(header string) cellTinter {
	switch strings.ToUpper(strings.TrimSpace(header)) {
	case "PROVIDER":
		return providerTint
	case "STATUS", "STATE", "LIFECYCLE":
		return lifecycleTint
	default:
		return nil
	}
}

// providerTint tints a provider-identity cell (hetzner / azure) with its
// GenProviderMark colour. Identity ONLY (Decision 7) — never a status voice; an
// unrecognised provider passes through unpainted.
func providerTint(bare string) (lipgloss.AdaptiveColor, bool) {
	c, ok := semrole.GenProviderMark[strings.ToLower(strings.TrimSpace(bare))]
	return c, ok
}

// lifecycleTint tints a recognised instance-lifecycle state (GenInstanceLifecycle
// keys: provisioning/live/degraded/stopped/archived/decommissioned/adopted)
// through its status ROLE hue (Decision 7: colour is read THROUGH the role, never
// a bespoke per-state hue). The neutral-role states (stopped, archived carry
// Role "") and any unrecognised status (a raw hcloud "running"/"off") pass
// through unpainted.
func lifecycleTint(bare string) (lipgloss.AdaptiveColor, bool) {
	tok, ok := semrole.GenInstanceLifecycle[strings.ToLower(strings.TrimSpace(bare))]
	if !ok || tok.Role == "" {
		return lipgloss.AdaptiveColor{}, false
	}
	return semrole.RoleColor(tok.Role)
}

// paintChromeCell wraps an already-PADDED table cell in the SGR of tint's colour.
// Mirrors writer.paintCell: the tint wraps the padded string so upstream column
// widths (measured on bare values) are untouched, and lipgloss renders through
// the ambient colour profile. bare is the UN-padded value so a cell's trailing
// alignment spaces never defeat the vocabulary match. A nil tinter or an
// out-of-vocabulary value returns padded verbatim. The caller (renderHzTable)
// guards on out.color, so this is only ever reached with colour enabled.
func paintChromeCell(tint cellTinter, padded, bare string) string {
	if tint == nil {
		return padded
	}
	color, ok := tint(bare)
	if !ok {
		return padded
	}
	return lipgloss.NewStyle().Foreground(color).Render(padded)
}
