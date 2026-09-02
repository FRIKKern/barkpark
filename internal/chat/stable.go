package chat

import (
	"encoding/json"
	"strings"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// stable.go — the LIVE-DOCUMENT consumer (charter D81), and nothing else.
//
// The stable prefix of a streaming turn is computed ONCE, SERVER-SIDE
// (api/lib/barkpark/studio_chat/stream_segments.ex) and put on the existing chat
// SSE stream as `event: stable` / `event: stable_end` frames carrying PortableDoc
// BLOCK JSON. This file consumes them. It contains no boundary scan, no markdown
// parser and no memo: a second boundary implementation would fork the law the
// server owns and reintroduce the three run-proven defects D81 item 2 records.
//
// Three properties hold structurally rather than by care:
//
//  1. IMPROVEMENT-ONLY (D76's floor, verbatim). Every field below is inert until
//     a server emits `stable` frames: with none on the wire Segments stays empty
//     and renderLiveTail returns renderTail's bytes unchanged. A server that
//     never emits them sees today's TUI exactly.
//  2. D9 INTACT. These frames are presentation-only. They never produce an
//     Effect, never touch LastSeq/Messages, and never clear the tail — the
//     settle path (result frame → FetchTailEffect → TailFetchedEvent, guarded by
//     D77's generation token) stays the sole truth, and the settled transcript
//     stays byte-identical. Segments are dropped at exactly the moment the tail
//     they annotate is cleared, so the persisted row replaces them in ONE
//     reducer step: nothing is painted twice and nothing is lost between.
//  3. NO CURSOR POISONING. Both frames are id-LESS by design (D81 item 1), so
//     scanListenFrames never advances Last-Event-ID for them. This file adds no
//     routing: reduceFrame already dispatches on the event NAME.
//
// The consumer contract is the cross-surface fixture
// internal/pdrender/testdata/chat_stable_frames.json (mobile charter D59) — the
// same file apps/mobile consumes. Its `cursor_rule` is implemented here verbatim.

// StableSegment is one committed segment of the turn now streaming: the server's
// half-open byte window [From,To) over that turn's source markdown, plus the
// PortableDoc blocks the window converts to. Blocks stay RAW and are decoded at
// paint time through the same pdrender.Decode the settled transcript uses — there
// is no second block model in this package.
type StableSegment struct {
	Turn   int
	From   int
	To     int
	Blocks json.RawMessage
}

// StableSkeleton is the server's classification of the block still FORMING past
// the committed cursor (charter D67) — at most one per frame, so the tail can
// never sprout a second placeholder. Prose is the live text ABOVE the forming
// component; the terminal deliberately does NOT re-render it, because those bytes
// are already inside the plain remainder this surface paints under the segments.
type StableSkeleton struct {
	Kind  string `json:"kind"`
	Prose string `json:"prose"`
}

// maxStableSegments bounds ONE turn's committed segments client-side — the same
// number the server's own per-turn bound uses (@default_max_segments_per_turn,
// stream_segments.ex) and the same constant apps/mobile exports as
// MAX_STABLE_SEGMENTS. A client bound is not redundant with the server's: the
// bytes on this wire come from whatever server the operator pointed `bp` at.
const maxStableSegments = 4096

// streamingMarker is the dim header the live tail wears. One owner: both the
// plain path (renderTail) and the segment path render THIS string, so a
// progressive turn and a flat one are still recognisably the same thing.
const streamingMarker = "assistant · streaming…"

// stableWire is the union of both payload shapes (D59). From/To are pointers so
// an absent field is distinguishable from a legitimate 0. Unknown keys are
// ignored by construction — a future server stamping `hint` or `cost` must not
// degrade this client (the fixture's unknown_future_fields_tolerated sequence).
type stableWire struct {
	Turn     int             `json:"turn"`
	From     *int            `json:"from"`
	To       *int            `json:"to"`
	Blocks   json.RawMessage `json:"blocks"`
	Skeleton *StableSkeleton `json:"skeleton"`
	Reason   string          `json:"reason"`
}

// reduceStable consumes one `event: stable` frame — THE ACCEPT RULE, and it is
// not hygiene. Live frames carry no id and are never replayed while this client
// reconnects on a backoff ladder, so a consumer that ignored `from` would splice
// a silently WRONG document: no error, and the same final cursor as the ungapped
// stream. `turn` is load-bearing on top of `from`, because a turn-boundary gap
// whose predecessor's total coincidentally equals the survivor's `from` is
// false-accepted by `from` alone (the fixture's
// turn_boundary_gap_false_accepted_by_from_only sequence RUNS that disagreement).
//
// A malformed frame is INERT rather than fatal — and that is not a shrug: the
// byte cursor notices the missing bytes on the NEXT frame and stops the turn, so
// a frame this decoder could not read can never be silently absorbed.
func reduceStable(st State, data []byte) State {
	var f stableWire
	if err := json.Unmarshal(data, &f); err != nil {
		return st
	}
	if f.Turn <= 0 || f.From == nil || f.To == nil {
		return st
	}
	from, to := *f.From, *f.To
	// Half-open [from,to) with at least one byte: an empty window would advance
	// the cursor while painting nothing, the one shape that could swallow source
	// bytes. And a frame with no blocks settles nothing.
	if from < 0 || to <= from || !hasBlocks(f.Blocks) {
		return st
	}

	st = adoptStableTurn(st, f.Turn)
	if st.StableStopped {
		// Terminal means terminal: a later frame for a stopped turn is inert. It
		// is NOT an error — it simply cannot append to a document this client has
		// already promised not to reflow.
		return st
	}
	if from != st.CommittedBytes {
		// THE HOLE. Keep every committed segment — that content is real,
		// converted, already read — render the remainder plain, never patch the
		// gap, and stop consuming so a later frame cannot re-open the wound.
		return stopStable(st)
	}
	// The bytes must already BE in our tail. The server's ingest order guarantees
	// it (recorder.ex puts the raw delta on the wire and only then derives the
	// segments it makes safe to commit), so a failure here means this client is
	// not holding the byte space the offsets index — the connect-time snapshot to
	// a mid-turn attach is the real case: its window starts at the turn's byte 0,
	// which this tail never received. Painting it would show the segment as a
	// block AND as plain source underneath, forever. Refusing lands the turn on
	// today's plain floor instead.
	if st.StableBase+to > len(st.Tail) {
		return stopStable(st)
	}
	if len(st.Segments) >= maxStableSegments {
		return stopStable(st)
	}

	st.Segments = append(st.Segments, StableSegment{Turn: f.Turn, From: from, To: to, Blocks: f.Blocks})
	// The cursor advances by `to` — the SOURCE offset, never the rendered block
	// text (53 source vs 42 derived bytes over four segments in the contract's run
	// proof, which is why `to` is on the wire at all).
	st.CommittedBytes = to
	st.Skeleton = f.Skeleton
	return st
}

// reduceStableEnd consumes the turn's terminal frame (charter D61).
//
//	settled  — the server compared concat(segments) against a whole-document
//	           conversion of the text that ACTUALLY PERSISTS and they matched. The
//	           segments stay painted until the settle refetch swaps in the
//	           persisted row (reduceTailFetched), which is what makes the turn
//	           boundary pop-free.
//	capped   — the segmenter hit its bound and the document is FROZEN at the last
//	           boundary. Reachable with zero segments ever emitted, which is why
//	           this is its own event. What is committed stays; the rest of the
//	           turn renders plain.
//	degraded — the server distrusts its OWN segmentation, so those blocks may not
//	           match the persisted text: DROP them and render the plain tail,
//	           today's exact behaviour. `from` is deliberately not cursor-checked
//	           here — a cursor complaint about discarded bytes is noise.
func reduceStableEnd(st State, data []byte) State {
	var f stableWire
	if err := json.Unmarshal(data, &f); err != nil {
		return st
	}
	if f.Turn <= 0 || f.From == nil || *f.From < 0 {
		return st
	}
	switch f.Reason {
	case "settled", "capped", "degraded":
	default:
		return st
	}

	st = adoptStableTurn(st, f.Turn)
	st.StableEnd = f.Reason
	if f.Reason == "degraded" {
		return dropStable(st)
	}
	if st.StableStopped {
		return st
	}
	if *f.From != st.CommittedBytes {
		return stopStable(st)
	}
	st.StableStopped = true
	st.Skeleton = nil
	return st
}

// adoptStableTurn switches to the frame's turn, resetting the per-turn cursor —
// the fixture's cursor_rule verbatim. The PREVIOUS turn's segments are dropped
// here, and that is where this consumer parts company with the mobile one: mobile
// keeps a settled turn's segment rows and suppresses its persisted row instead,
// while the TUI's segments annotate the ONE live tail region that starts at
// StableBase, so a re-based turn cannot keep them. The dropped turn's text is
// still on screen — as the plain tail it was before this slice existed — until
// its own settle lands. Today's floor, never worse.
func adoptStableTurn(st State, turn int) State {
	if turn == st.StableTurn {
		return st
	}
	st.StableTurn = turn
	st.Segments = nil
	st.CommittedBytes = 0
	st.Skeleton = nil
	st.StableStopped = false
	st.StableEnd = ""
	return st
}

// stopStable ends consumption for this turn and KEEPS what is committed: the
// remainder simply goes back to being plain.
func stopStable(st State) State {
	st.StableStopped = true
	st.Skeleton = nil
	return st
}

// dropStable throws this turn's segments away and puts the whole tail back on the
// plain path — the server-declared degrade, spelled out: nothing half-committed
// survives a drop.
func dropStable(st State) State {
	st.Segments = nil
	st.CommittedBytes = 0
	st.Skeleton = nil
	st.StableStopped = true
	return st
}

// clearStable releases the live document at the settle seam. It is called from
// exactly ONE place — the D77-guarded tail clear in reduceTailFetched — because
// the segments describe bytes of Tail: they must die with it, in the same reducer
// step that appends the persisted row, or the turn would be painted twice.
func clearStable(st State) State {
	st.Segments = nil
	st.StableTurn = 0
	st.CommittedBytes = 0
	st.StableBase = 0
	st.Skeleton = nil
	st.StableStopped = false
	st.StableEnd = ""
	return st
}

// hasBlocks reports whether the frame's `blocks` really is a non-empty array.
func hasBlocks(raw json.RawMessage) bool {
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return false
	}
	return len(arr) > 0
}

// committedBlocks decodes every committed segment into ONE block list, in commit
// order. Append-only means concatenation is the whole merge: no dedup, no
// re-ordering, no reconciliation.
func committedBlocks(st State) []pdrender.Block {
	var out []pdrender.Block
	for _, seg := range st.Segments {
		blocks, err := pdrender.Decode(seg.Blocks)
		if err != nil {
			continue
		}
		out = append(out, blocks...)
	}
	return out
}

// tailRemainder is the plain, still-uncommitted part of the live tail. With no
// segments committed this is the WHOLE tail, byte for byte, which is why a server
// that never emits `stable` frames sees today's behaviour exactly.
func tailRemainder(st State) string {
	cut := st.StableBase + st.CommittedBytes
	if len(st.Segments) == 0 || cut <= 0 {
		return st.Tail
	}
	if cut >= len(st.Tail) {
		return ""
	}
	return st.Tail[cut:]
}

// skeletonLine is the honest one-line placeholder for the block still forming
// past the cursor. It uses ONLY the server's `kind` against a fixed vocabulary
// (skeleton_label/1's seven labels, charter D67; an eighth degrades to the
// generic "block" rather than printing a word this surface has no shape for) —
// it never fabricates content, and it never repeats skeleton.Prose, which is
// already visible in the plain remainder above it.
func skeletonLine(sk *StableSkeleton) string {
	if sk == nil {
		return ""
	}
	label := skeletonLabels[sk.Kind]
	if label == "" {
		label = "block"
	}
	return "⋯ " + label + " forming…"
}

// skeletonLabels is skeleton_label/1's whole vocabulary (charter D67), rendered
// in terminal words. The server can emit no eighth kind; this map's fallback
// means a newer one still renders honestly.
var skeletonLabels = map[string]string{
	"code":    "code block",
	"diagram": "diagram",
	"chart":   "chart",
	"stats":   "stats",
	"table":   "table",
	"callout": "callout",
	"block":   "block",
}

// renderLiveTail paints the live streaming turn.
//
// With committed segments it is: the dim streaming marker, then the committed
// prefix through the SAME pdrender Decode → RenderDoc stack the settled
// transcript uses (ONE RenderDoc call over the concatenated blocks — the
// per-message Figure reset of charter D10, exactly as renderAssistantDoc does for
// a settled row), then the uncommitted remainder as plain wrapped text, then the
// forming-block placeholder.
//
// With none — no server support, a hole, a degrade, or undecodable blocks — it
// returns renderTail's bytes unchanged. That fallback is the improvement-only
// floor (D76) as a code path rather than a promise.
func renderLiveTail(reg *pdrender.Registry, width int, st State) []string {
	w := bodyWidth(width)
	if len(st.Segments) == 0 {
		return renderTail(w, st.Tail)
	}
	blocks := committedBlocks(st)
	if len(blocks) == 0 {
		return renderTail(w, st.Tail)
	}

	out := []string{dimStyle.Render(streamingMarker)}
	// Anything BEFORE this turn's byte 0 is a previous turn still waiting for its
	// own settle (the D77 residual). It belongs to no segment of this turn, so it
	// stays exactly what it is today: plain text, painted first.
	if st.StableBase > 0 && st.StableBase <= len(st.Tail) {
		out = append(out, wrap(strings.TrimRight(st.Tail[:st.StableBase], " "), w)...)
	}
	doc := reg.RenderDoc(blocks, pdrender.RenderCtx{Width: w, Profile: chatProfile})
	for _, ln := range strings.Split(doc, "\n") {
		out = append(out, strings.TrimRight(ln, " "))
	}
	out = append(out, wrap(strings.TrimRight(tailRemainder(st), " "), w)...)
	if line := skeletonLine(st.Skeleton); line != "" {
		out = append(out, dimStyle.Render(line))
	}
	return out
}
