package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go/TUI leg of the chat LIVE-DOCUMENT wire contract (mobile charter D59).
//
// The fixture — internal/pdrender/testdata/chat_stable_frames.json — is the
// contract itself, not a sample of one implementation's output: the server
// emitter must MATCH it and every client must reach the outcomes it records.
// It is hand-authored (unlike its chat_golden_toolrows.json neighbour, which a
// mix task writes) precisely because it has to exist BEFORE either half is
// built — that is what lets the emitter and the mobile consumer fly in
// parallel instead of against each other.
//
// Two proofs live here, and they are different in kind:
//
//  1. RENDER. Every stable frame's blocks decode through the real
//     Decode -> RenderDoc seam with zero unknown-block fallback. A frame is
//     only useful if the surface can actually draw it; this pins the TUI's
//     side of that ahead of ct-bl-stream-rich.
//
//  2. CURSOR. The byte-cursor walk recorded in the fixture is executed, not
//     described: accept a stable frame iff its turn matches and its `from`
//     equals the committed cursor, then commit `to`. The three degrade
//     sequences must be REJECTED at the recorded frame with the recorded
//     offsets — an off-by-one in either direction reds.
//
// The turn-boundary sequence gets a third treatment: BOTH the contract
// predicate and the naive from-only predicate are run over the same frames and
// the disagreement is asserted. That is the run proof for why `turn` is on the
// wire at all — an assertion that "from alone is insufficient" would be a
// claim; watching the from-only walk swallow a spliced turn is a fact.

const stableFramesFixture = "chat_stable_frames.json"

type stableFrameFixture struct {
	Comment   string            `json:"_comment"`
	Scope     string            `json:"scope"`
	Contract  map[string]string `json:"contract"`
	Offsets   map[string]string `json:"offsets"`
	Sequences []stableSequence  `json:"sequences"`
}

type stableSequence struct {
	Name             string            `json:"name"`
	Title            string            `json:"title"`
	Why              string            `json:"why"`
	Sources          map[string]string `json:"sources"`
	SkeletonAtFrame  *int              `json:"skeleton_at_frame"`
	DropsSegments    bool              `json:"drops_segments"`
	Frames           []stableWireFrame `json:"frames"`
	Expected         stableWalk        `json:"expected"`
	ExpectedFromOnly *stableWalk       `json:"expected_from_only"`
}

// stableWireFrame is the SSE envelope: an event name plus the always-present
// data line, kept raw so the unknown-field probe below can see the real keys.
type stableWireFrame struct {
	Event string          `json:"event"`
	Data  json.RawMessage `json:"data"`
}

// stableFrameData covers BOTH payload shapes (Reason is empty on `stable`, To
// and Blocks are absent on `stable_end`) — the union a consumer decodes after
// switching on the event name. Neither frame carries an id: the (turn, from)
// pair is the identity.
type stableFrameData struct {
	Turn     int             `json:"turn"`
	From     int             `json:"from"`
	To       int             `json:"to"`
	Blocks   json.RawMessage `json:"blocks"`
	Skeleton *stableSkeleton `json:"skeleton"`
	Reason   string          `json:"reason"`
}

type stableSkeleton struct {
	Kind  string `json:"kind"`
	Prose string `json:"prose"`
}

type stableWalk struct {
	Outcome              string     `json:"outcome"`
	AcceptedStableFrames int        `json:"accepted_stable_frames"`
	CommittedBytes       int        `json:"committed_bytes"`
	FinalTurn            int        `json:"final_turn"`
	Gap                  *stableGap `json:"gap"`
}

type stableGap struct {
	FrameIndex   int `json:"frame_index"`
	Turn         int `json:"turn"`
	ExpectedFrom int `json:"expected_from"`
	ActualFrom   int `json:"actual_from"`
}

// knownStableKeys is the D59 field set. Anything else on the wire is a FUTURE
// field a consumer must ignore; the fixture floor asserts at least one really
// shows up so the tolerance is exercised rather than assumed.
var knownStableKeys = map[string]bool{
	"turn": true, "from": true, "to": true, "blocks": true,
	"skeleton": true, "reason": true,
}

// skeletonLabels is skeleton_label/1's whole vocabulary (charter D67) — the
// server can emit no eighth kind, and a client has a shape for no eighth kind.
var skeletonLabels = map[string]bool{
	"diagram": true, "chart": true, "stats": true, "table": true,
	"callout": true, "code": true, "block": true,
}

func loadStableFrames(t *testing.T) stableFrameFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", stableFramesFixture))
	if err != nil {
		t.Fatalf("read stable-frame fixture: %v", err)
	}
	var fx stableFrameFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode stable-frame fixture: %v", err)
	}
	// Floors: a gutted fixture must red HERE rather than shrink coverage in
	// silence. Scope pins identity; the contract map pins the self-describing
	// header a cold reader needs.
	if fx.Scope != "chat-stable-frame-wire" {
		t.Fatalf("fixture floor: scope = %q, want chat-stable-frame-wire", fx.Scope)
	}
	for _, key := range []string{"stable", "stable_end", "why_to", "why_turn"} {
		if strings.TrimSpace(fx.Contract[key]) == "" {
			t.Fatalf("fixture floor: contract.%s is empty — the file must state D59 on its own", key)
		}
	}
	if len(fx.Sequences) < 7 {
		t.Fatalf("fixture floor: %d sequences, want >= 7 (settled, skeleton, gap, turn-gap, capped, degraded, unknown-field)", len(fx.Sequences))
	}
	return fx
}

// walkStableFrames executes the fixture's recorded cursor rule. useTurn selects
// the predicate: true is the D59 contract (a turn change resets the cursor),
// false is the naive from-only client D59 exists to rule out.
func walkStableFrames(t *testing.T, seq stableSequence, useTurn bool) stableWalk {
	t.Helper()
	res := stableWalk{Outcome: "streaming"}
	turn := -1
	committed := 0

	for i, f := range seq.Frames {
		var d stableFrameData
		if err := json.Unmarshal(f.Data, &d); err != nil {
			t.Fatalf("%s frame %d: decode data: %v", seq.Name, i, err)
		}
		res.FinalTurn = d.Turn
		if useTurn && d.Turn != turn {
			turn = d.Turn
			committed = 0
		}

		switch f.Event {
		case "stable":
			if d.From != committed {
				res.Outcome = "gap"
				res.CommittedBytes = committed
				res.Gap = &stableGap{FrameIndex: i, Turn: d.Turn, ExpectedFrom: committed, ActualFrom: d.From}
				return res
			}
			committed = d.To
			res.AcceptedStableFrames++

		case "stable_end":
			// A SERVER-declared degrade is categorically different from a
			// client-detected gap: the client throws its segments away and
			// renders the persisted row, so `from` is not cursor-checked.
			if d.Reason == "degraded" {
				committed = 0
				res.Outcome = "degraded"
				continue
			}
			if d.From != committed {
				res.Outcome = "gap"
				res.CommittedBytes = committed
				res.Gap = &stableGap{FrameIndex: i, Turn: d.Turn, ExpectedFrom: committed, ActualFrom: d.From}
				return res
			}
			res.Outcome = d.Reason

		default:
			t.Fatalf("%s frame %d: unknown event %q (D59 has exactly two)", seq.Name, i, f.Event)
		}
	}

	res.CommittedBytes = committed
	return res
}

func assertStableWalk(t *testing.T, label string, got, want stableWalk) {
	t.Helper()
	if got.Outcome != want.Outcome {
		t.Fatalf("%s: outcome = %q, want %q", label, got.Outcome, want.Outcome)
	}
	if got.AcceptedStableFrames != want.AcceptedStableFrames {
		t.Fatalf("%s: accepted %d stable frames, want %d", label, got.AcceptedStableFrames, want.AcceptedStableFrames)
	}
	if got.CommittedBytes != want.CommittedBytes {
		t.Fatalf("%s: committed %d bytes, want %d", label, got.CommittedBytes, want.CommittedBytes)
	}
	if got.FinalTurn != want.FinalTurn {
		t.Fatalf("%s: final turn %d, want %d", label, got.FinalTurn, want.FinalTurn)
	}
	switch {
	case want.Gap == nil && got.Gap != nil:
		t.Fatalf("%s: unexpected gap %+v", label, *got.Gap)
	case want.Gap != nil && got.Gap == nil:
		t.Fatalf("%s: no gap detected, want %+v", label, *want.Gap)
	case want.Gap != nil && *got.Gap != *want.Gap:
		t.Fatalf("%s: gap %+v, want %+v", label, *got.Gap, *want.Gap)
	}
}

// TestChatStableFramesRender is proof (1): every recorded stable frame's blocks
// survive the real Decode -> RenderDoc seam with no unknown-block fallback, and
// every frame's [from,to) window stays inside its turn's recorded source.
func TestChatStableFramesRender(t *testing.T) {
	fx := loadStableFrames(t)
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}

	renderedBlocks := 0
	skeletons := 0
	unknownFields := 0

	for _, seq := range fx.Sequences {
		seq := seq
		t.Run(seq.Name, func(t *testing.T) {
			if strings.TrimSpace(seq.Why) == "" {
				t.Fatalf("sequence %q carries no `why` — the fixture must explain itself", seq.Name)
			}
			for i, f := range seq.Frames {
				var d stableFrameData
				if err := json.Unmarshal(f.Data, &d); err != nil {
					t.Fatalf("frame %d: decode data: %v", i, err)
				}

				// Forward-compat probe: count keys outside the D59 set. The Go
				// struct decode above already ignored them — this only proves
				// the fixture really exercises that tolerance.
				var keys map[string]json.RawMessage
				if err := json.Unmarshal(f.Data, &keys); err != nil {
					t.Fatalf("frame %d: decode data keys: %v", i, err)
				}
				for k := range keys {
					if !knownStableKeys[k] {
						unknownFields++
					}
				}

				if f.Event == "stable_end" {
					switch d.Reason {
					case "settled", "capped", "degraded":
					default:
						t.Fatalf("frame %d: stable_end reason %q outside D59's three", i, d.Reason)
					}
					continue
				}

				// Byte-window sanity against the recorded source. Sources are
				// pure ASCII by fixture rule, so len() is both the byte and the
				// UTF-16 length and the mobile leg asserts the identical bound.
				if d.From < 0 || d.To <= d.From {
					t.Fatalf("frame %d: empty or inverted window [%d,%d)", i, d.From, d.To)
				}
				if src, ok := seq.Sources[itoa(d.Turn)]; ok && d.To > len(src) {
					t.Fatalf("frame %d: to=%d past turn %d's %d-byte source", i, d.To, d.Turn, len(src))
				}

				if d.Skeleton != nil {
					skeletons++
					// `kind` must be one of the server's seven labels
					// (skeleton_label/1, charter D67) — an eighth would render a
					// word no surface has a shape for. `prose` is deliberately
					// NOT required non-empty: it is the prose ABOVE the forming
					// component, and it is legitimately "" whenever the
					// component starts exactly at `to`.
					if !skeletonLabels[d.Skeleton.Kind] {
						t.Fatalf("frame %d: skeleton kind %q outside the server's seven labels", i, d.Skeleton.Kind)
					}
				}

				blocks, err := Decode(d.Blocks)
				if err != nil {
					t.Fatalf("frame %d: decode blocks: %v", i, err)
				}
				if len(blocks) == 0 {
					t.Fatalf("frame %d: a stable frame with no blocks settles nothing", i)
				}
				out := ansi.Strip(reg.RenderDoc(blocks, ctx))
				assertNoUnknownBlock(t, "stable frame "+itoa(i), out)
				renderedBlocks += len(blocks)
			}
		})
	}

	// Non-vacuity floors: a fixture that quietly lost its blocks, its skeleton
	// case or its future-field case would otherwise pass everything above.
	if renderedBlocks < 10 {
		t.Fatalf("coverage floor: only %d blocks rendered across the fixture", renderedBlocks)
	}
	if skeletons == 0 {
		t.Fatalf("coverage floor: no frame carries a skeleton — the open-fence case is gone")
	}
	if unknownFields == 0 {
		t.Fatalf("coverage floor: no frame carries an unknown future field — the tolerance is untested")
	}
}

// TestChatStableFramesCursor is proof (2): the recorded walk, executed. The
// three degrade sequences must be rejected at exactly the recorded frame and
// offsets.
func TestChatStableFramesCursor(t *testing.T) {
	fx := loadStableFrames(t)

	reasons := map[string]bool{}
	gaps := 0

	for _, seq := range fx.Sequences {
		seq := seq
		t.Run(seq.Name, func(t *testing.T) {
			got := walkStableFrames(t, seq, true)
			assertStableWalk(t, seq.Name, got, seq.Expected)
			if got.Gap != nil {
				gaps++
			}
			reasons[seq.Expected.Outcome] = true

			if seq.SkeletonAtFrame != nil {
				var d stableFrameData
				if err := json.Unmarshal(seq.Frames[*seq.SkeletonAtFrame].Data, &d); err != nil {
					t.Fatalf("decode skeleton frame: %v", err)
				}
				if d.Skeleton == nil {
					t.Fatalf("skeleton_at_frame points at frame %d, which carries none", *seq.SkeletonAtFrame)
				}
			}
			if seq.DropsSegments && got.CommittedBytes != 0 {
				t.Fatalf("%s: drops_segments, yet %d bytes stayed committed", seq.Name, got.CommittedBytes)
			}
		})
	}

	// Every terminal reason and the client-detected gap must be exercised.
	for _, want := range []string{"settled", "capped", "degraded", "gap"} {
		if !reasons[want] {
			t.Fatalf("coverage floor: no sequence reaches outcome %q", want)
		}
	}
	if gaps < 2 {
		t.Fatalf("coverage floor: %d gap sequences, want >= 2 (midstream + turn boundary)", gaps)
	}
}

// TestChatStableFramesTurnIsDiscriminating is the reason `turn` is on the wire,
// RUN rather than claimed: both predicates walk the same recorded frames, and
// on exactly one sequence they disagree — the from-only client false-accepts a
// spliced turn (splicing turn 2's tail onto turn 1's message) where the
// contract predicate reports the gap.
func TestChatStableFramesTurnIsDiscriminating(t *testing.T) {
	fx := loadStableFrames(t)

	discriminating := 0
	for _, seq := range fx.Sequences {
		seq := seq
		t.Run(seq.Name, func(t *testing.T) {
			strict := walkStableFrames(t, seq, true)
			fromOnly := walkStableFrames(t, seq, false)

			if seq.ExpectedFromOnly == nil {
				// No recorded divergence: the two predicates MUST agree, which
				// is what makes the one divergence below meaningful.
				assertStableWalk(t, seq.Name+" (from-only)", fromOnly, seq.Expected)
				return
			}

			discriminating++
			assertStableWalk(t, seq.Name+" (from-only)", fromOnly, *seq.ExpectedFromOnly)
			if strict.Outcome != "gap" {
				t.Fatalf("%s: the turn-plus-from predicate must REJECT this sequence, got %q", seq.Name, strict.Outcome)
			}
			if fromOnly.Outcome == "gap" {
				t.Fatalf("%s: the from-only predicate must FALSE-ACCEPT this sequence — it rejected instead, so the case no longer discriminates", seq.Name)
			}
			if fromOnly.AcceptedStableFrames <= strict.AcceptedStableFrames {
				t.Fatalf("%s: from-only accepted %d frames, strict accepted %d — the false accept must swallow strictly more",
					seq.Name, fromOnly.AcceptedStableFrames, strict.AcceptedStableFrames)
			}
		})
	}

	if discriminating != 1 {
		t.Fatalf("fixture floor: %d sequences record a from-only divergence, want exactly 1 (the turn boundary)", discriminating)
	}
}
