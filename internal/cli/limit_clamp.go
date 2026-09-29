package cli

import "fmt"

// limit_clamp.go carries the ONE thing a client can know about a server-side
// window cap without being told what the cap is.
//
// THE DEFECT THIS ANSWERS. `bp` asks a capped endpoint for N rows, receives at
// most the server's ceiling, and says nothing. A caller reading the response
// cannot tell a genuine N-row total from a page the server narrowed — and a
// full page read as a complete count manufactured four false findings across
// four lanes in r18 alone. The fix is not to know the ceiling. It is to notice
// that the REQUEST and the RESPONSE disagree.
//
// THE TRAP THIS AVOIDS. A literal `200` in the Go client would be a second copy
// of a server-owned truth (the clamp lives in
// cloud/lib/barkpark_cloud/web/router.ex, `parse_limit(_, default, max)`), and
// it drifts silently the moment the cap moves — the exact defect #18390 removed
// from internal/pdrender. Nothing below names a cap. Both numbers in every
// comparison are read off the SAME exchange.

// serverClampedBy reports the window the CALLER asked for when the server
// APPLIED a smaller one — and 0 otherwise, which is the whole point.
//
// What the client compares, in one sentence: the number it put on the wire
// against the number the server echoed back as the window it actually used.
//
// Both operands come from the same request/response pair, so the rule holds at
// any ceiling and needs no knowledge of where the ceiling sits:
//
//   - applied == requested is the caller getting exactly what they asked for.
//     SILENT — reporting it would be noise, and a signal that cries wolf on
//     every honest full window is tuned out inside a week, which is this
//     defect pointing the other way.
//   - applied > requested cannot be a clamp (nothing was narrowed), so it is
//     silent too.
//   - applied < requested is the server having narrowed the request. That is
//     the one fact the caller cannot see and the client can.
//
// requested <= 0 means the caller typed no flag at all and therefore chose no
// number to be misled about. applied <= 0 means the server echoed no window —
// an older control plane, or an envelope with nothing to report — and an
// absent echo is not evidence of a clamp.
func serverClampedBy(requested, applied int) int {
	if requested > 0 && applied > 0 && applied < requested {
		return requested
	}
	return 0
}

// clampNotice is the advisory line for a narrowed window. It names BOTH sides —
// what was asked for and what arrived — so a reader can tell a real total from
// a ceiling without re-running anything, and `unit` names what is being counted
// ("rows", "points") so the sentence reads the same on every capped surface.
func clampNotice(unit string, requested, applied int) string {
	return fmt.Sprintf(
		"narrowed: asked for %d %s, the server applied %d — this window is a server ceiling, not the end of the data",
		requested, unit, applied,
	)
}
