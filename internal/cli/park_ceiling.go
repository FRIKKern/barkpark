package cli

// park_ceiling.go — the CLI half of `bp park`'s 2 MB ceiling.
//
// `bp park` (row ctx-b3-bp-park) parks a bulky payload server-side behind a
// handle so an agent can drop it out of context and still know what it holds.
// Two design constraints are RATIFIED on that row:
//
//	1. a 2 MB ceiling per parked blob, enforced SERVER-SIDE
//	2. a MANDATORY summary — a handle with no summary re-costs a fetch to
//	   learn what it is (/papers/ctx-compression-handle-doctrine)
//
// This file is NOT the enforcement of (1). The server is the authority and must
// refuse an oversized park on its own, because the CLI is one of several
// clients (MCP bridge, raw HTTP, LiveView) and a client-side limit any of them
// can skip is not a ceiling. What this file adds is a FAST-FAIL MIRROR: an
// oversized park is refused before 2 MB of body is pushed over the wire to be
// rejected at the far end. The failure direction that matters is the one where
// the guard is WRONG: it must never refuse a payload the server would accept,
// so the constant here is the server's number, and a body at exactly the
// ceiling is ACCEPTED (the refusal is strictly greater-than).
//
// Scoped to the `park` noun on purpose. A generic body ceiling across every
// manifest write would be a different (larger) decision about every existing
// verb, and this row does not carry it. The noun-scoped special case has
// precedent in this package — see stampBodyKey2, which special-cases task.stamp
// at the same seam.
//
// Summary mandatoriness (2) needs NO code here: bindArgs already refuses a
// missing or empty-string required positional, so the moment the plugin's
// capabilities entry declares `arg("summary", true, …)`, `bp park <payload>`
// with no summary is refused client-side with the usage block. That is pinned
// by TestParkWithoutSummaryIsRefused rather than assumed.

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// parkNoun is the manifest noun the ceiling is scoped to.
const parkNoun = "park"

// parkPayloadCeilingBytes is the ratified per-blob ceiling: 2 MB, spelled as
// 2 MiB (2 << 20 = 2097152) to match how a server-side Plug body limit is
// written. It is a MIRROR of the server's number, not the source of it — if the
// two ever disagree the server wins and this constant is the bug.
const parkPayloadCeilingBytes = 2 << 20

// checkParkPayloadCeiling refuses a `bp park` write whose assembled JSON body
// exceeds the ceiling. Every other noun passes through untouched, and so does a
// park body at or under the limit.
func checkParkPayloadCeiling(cmd manifest.Command, body []byte) error {
	if cmd.Noun != parkNoun || !cmd.Writes {
		return nil
	}
	if len(body) <= parkPayloadCeilingBytes {
		return nil
	}
	return fmt.Errorf(
		"park payload is %d bytes, over the %d-byte (2 MB) ceiling for a parked blob: "+
			"park a slice of it, or split it across handles. bp refuses this before sending; "+
			"the server enforces the same ceiling independently",
		len(body), parkPayloadCeilingBytes)
}
