package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// stable_test.go — the live-document consumer (charter D81), driven by the TWO
// fixtures that already govern this wire, never by hand-typed frames:
//
//   - internal/pdrender/testdata/chat_stable_frames.json — the HAND-AUTHORED
//     cross-surface CONTRACT (mobile charter D59). The same file the Elixir
//     emitter must match and apps/mobile consumes; its `cursor_rule` is what
//     stable.go implements. Read across the package boundary on purpose: copying
//     it here would fork the contract, and reduce_test.go already reads
//     ../../api/test/fixtures for the same reason.
//   - internal/pdrender/testdata/chat_stable_frames_real.json — the EVIDENCE: the
//     `stable` frames a PRODUCTION Barkpark actually put on a socket during one
//     live turn, lifted from the raw SSE byte log.
//
// Every test below feeds the reducer the events the SOCKET carries, in the
// server's own ingest order (recorder.ex: the raw text delta goes out FIRST, then
// the segment frame it makes safe to commit), so the byte space the offsets index
// is the byte space the tail really holds.

const (
	stableContractFixture = "chat_stable_frames.json"
	stableRealFixture     = "chat_stable_frames_real.json"
)

type stableFixtureFrame struct {
	Event string          `json:"event"`
	Data  json.RawMessage `json:"data"`
}

type stableWalkExpectation struct {
	Outcome              string `json:"outcome"`
	AcceptedStableFrames int    `json:"accepted_stable_frames"`
	CommittedBytes       int    `json:"committed_bytes"`
	FinalTurn            int    `json:"final_turn"`
}

type stableFixtureSequence struct {
	Name            string                `json:"name"`
	Sources         map[string]string     `json:"sources"`
	SkeletonAtFrame *int                  `json:"skeleton_at_frame"`
	DropsSegments   bool                  `json:"drops_segments"`
	Frames          []stableFixtureFrame  `json:"frames"`
	Expected        stableWalkExpectation `json:"expected"`
}

type stableContractFile struct {
	Scope     string                  `json:"scope"`
	Sequences []stableFixtureSequence `json:"sequences"`
}

type stableRealFile struct {
	Scope          string               `json:"scope"`
	CapturedTurn   int                  `json:"captured_turn"`
	MidTurnFrames  int                  `json:"mid_turn_frames"`
	CommittedBytes int                  `json:"committed_bytes"`
	Frames         []stableFixtureFrame `json:"frames"`
}

func readStableFixture(t *testing.T, name string, into any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "pdrender", "testdata", name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
}

func loadStableContract(t *testing.T) stableContractFile {
	t.Helper()
	var fx stableContractFile
	readStableFixture(t, stableContractFixture, &fx)
	if fx.Scope != "chat-stable-frame-wire" {
		t.Fatalf("fixture floor: scope = %q, want chat-stable-frame-wire", fx.Scope)
	}
	if len(fx.Sequences) < 7 {
		t.Fatalf("fixture floor: %d sequences, want >= 7", len(fx.Sequences))
	}
	return fx
}

func loadStableRealCapture(t *testing.T) stableRealFile {
	t.Helper()
	var fx stableRealFile
	readStableFixture(t, stableRealFixture, &fx)
	if fx.Scope != "chat-stable-frame-wire-real-capture" {
		t.Fatalf("fixture floor: scope = %q, want chat-stable-frame-wire-real-capture", fx.Scope)
	}
	if fx.MidTurnFrames < 3 || fx.CommittedBytes < 1000 {
		t.Fatalf("fixture floor: the capture shrank to %d frames / %d bytes", fx.MidTurnFrames, fx.CommittedBytes)
	}
	return fx
}

// stableFrameHeader is the envelope both payload shapes share.
type stableFrameHeader struct {
	Turn   int             `json:"turn"`
	From   *int            `json:"from"`
	To     *int            `json:"to"`
	Blocks json.RawMessage `json:"blocks"`
	Reason string          `json:"reason"`
}

func decodeStableHeader(t *testing.T, raw json.RawMessage) stableFrameHeader {
	t.Helper()
	var h stableFrameHeader
	if err := json.Unmarshal(raw, &h); err != nil {
		t.Fatalf("decode frame data: %v", err)
	}
	return h
}

// realCaptureSource rebuilds the turn's SOURCE MARKDOWN from the captured frames,
// byte for byte. The capture records the frames, not the delta bytes, but the
// reconstruction is exact rather than approximate: each frame's window is its
// paragraph text plus the blank line that closed it (573+2, 574+2, 596+2, 577+2,
// 546+0 in the recorded capture), and the test asserts the total lands exactly on
// the fixture's own recorded committed_bytes. A capture whose shape stops
// matching this rule fails loudly here instead of silently testing a fiction.
func realCaptureSource(t *testing.T, fx stableRealFile) string {
	t.Helper()
	var b strings.Builder
	for i, f := range fx.Frames {
		if f.Event != "stable" {
			continue
		}
		h := decodeStableHeader(t, f.Data)
		var blocks []struct {
			Type    string `json:"type"`
			Content []struct {
				Value string `json:"value"`
			} `json:"content"`
		}
		if err := json.Unmarshal(h.Blocks, &blocks); err != nil {
			t.Fatalf("frame %d: decode blocks: %v", i, err)
		}
		if len(blocks) != 1 || blocks[0].Type != "paragraph" {
			t.Fatalf("frame %d: the reconstruction rule covers a single paragraph block; the capture now carries %d blocks — teach this helper the new shape", i, len(blocks))
		}
		var text strings.Builder
		for _, c := range blocks[0].Content {
			text.WriteString(c.Value)
		}
		pad := (*h.To - *h.From) - len(text.String())
		if pad < 0 || pad > 2 {
			t.Fatalf("frame %d: window %d cannot hold %d bytes of paragraph text", i, *h.To-*h.From, len(text.String()))
		}
		b.WriteString(text.String())
		b.WriteString(strings.Repeat("\n", pad))
	}
	src := b.String()
	if len(src) != fx.CommittedBytes {
		t.Fatalf("reconstruction is %d bytes, the capture recorded %d committed", len(src), fx.CommittedBytes)
	}
	return src
}

// stableScript turns recorded frames into the events the socket carries: the raw
// text deltas covering the bytes a frame refers to go out FIRST (recorder.ex
// ingest order — inverting it would put a `stable` frame ahead of the bytes it
// covers), then the frame. A turn change emits the turn-start frame the claude
// lane sends, because that is where a turn's byte 0 is stamped.
//
// The deltas follow the SOURCE, not the frames: a hole in the segment stream is a
// missing FRAME, never missing bytes — the text always arrives.
func stableScript(t *testing.T, frames []stableFixtureFrame, sources map[string]string, chunk int) []FrameEvent {
	t.Helper()
	if chunk < 1 {
		chunk = 1 << 30
	}
	var out []FrameEvent
	sent := map[int]int{}
	turn := 0
	// flush sends the bytes a real socket would already have carried: the delta
	// stream is always AHEAD of the segment stream, because a segment is only
	// emitted once its bytes have gone out.
	flush := func(turn int) {
		src := sources[strconv.Itoa(turn)]
		for sent[turn] < len(src) {
			end := sent[turn] + chunk
			if end > len(src) {
				end = len(src)
			}
			out = append(out, deltaFrame(t, src[sent[turn]:end]))
			sent[turn] = end
		}
	}
	for _, f := range frames {
		h := decodeStableHeader(t, f.Data)
		if h.Turn != turn {
			flush(turn)
			turn = h.Turn
			out = append(out, initFrame(t))
		}
		want := 0
		switch {
		case f.Event == "stable" && h.To != nil:
			want = *h.To
		case h.From != nil:
			want = *h.From
		}
		src := sources[strconv.Itoa(h.Turn)]
		if want > len(src) {
			want = len(src)
		}
		for sent[h.Turn] < want {
			end := sent[h.Turn] + chunk
			if end > want {
				end = want
			}
			out = append(out, deltaFrame(t, src[sent[h.Turn]:end]))
			sent[h.Turn] = end
		}
		out = append(out, FrameEvent{Name: f.Event, Data: f.Data})
	}
	flush(turn)
	return out
}

// driveStable folds the script through the REAL Reduce and counts how many
// `stable` frames were actually accepted (a segment appended), which is the
// fixture's accepted_stable_frames even across a turn change that drops the
// previous turn's segments.
func driveStable(t *testing.T, evs []FrameEvent) (State, int) {
	t.Helper()
	st := State{}
	accepted := 0
	for _, ev := range evs {
		before := len(st.Segments)
		var effects []Effect
		st, effects = Reduce(st, ev, t0)
		if ev.Name == "stable" && len(st.Segments) > before {
			accepted++
		}
		if ev.Name == "stable" || ev.Name == "stable_end" {
			if len(effects) != 0 {
				t.Fatalf("a %s frame produced %d effects — the live document is presentation-only (D9)", ev.Name, len(effects))
			}
		}
	}
	return st, accepted
}

// plainText strips SGR and collapses whitespace so a rendered transcript can be
// searched for CONTENT without depending on where the renderer wrapped a line.
func plainText(lines []string) string {
	return strings.Join(strings.Fields(ansi.Strip(strings.Join(lines, "\n"))), " ")
}

// assertNoContentLost proves the improvement-only floor at the byte level: every
// word of the turn's source is still somewhere on screen, whether it came back as
// a rendered block or as plain remainder. This is the assertion a silently
// mis-split tail fails — a cursor that skips bytes drops words that no block
// covers and no remainder shows.
func assertNoContentLost(t *testing.T, label, source string, lines []string) {
	t.Helper()
	shown := plainText(lines)
	for _, word := range strings.Fields(source) {
		w := strings.TrimFunc(word, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
		if len(w) < 4 {
			continue
		}
		if !strings.Contains(shown, w) {
			t.Fatalf("%s: %q from the source is on no line — content was lost between the segments and the plain remainder\n%s", label, w, strings.Join(lines, "\n"))
		}
	}
}

func liveModel(st State) Model {
	return Model{width: 80, height: 24, screen: screenChat, scroll: -1, st: st}
}

// ── the floor: with no `stable` frames the TUI is exactly what it is today ────

// TestStableAbsentIsTodaysFlatTail is the improvement-only property (D76) as a
// byte comparison, not a promise: a state with a live tail and no segments
// renders through renderLiveTail exactly what renderTail renders. Every
// pre-existing reduce/render/model assertion in this package passes unmodified
// for the same structural reason.
func TestStableAbsentIsTodaysFlatTail(t *testing.T) {
	st := State{Tail: "The reply is still\nstreaming in plain text, wrapped by the same helper.\n"}
	got := strings.Join(renderLiveTail(chatRegistry, 80, st), "\n")
	want := strings.Join(renderTail(bodyWidth(80), st.Tail), "\n")
	if got != want {
		t.Fatalf("with no committed segments the live tail must be byte-identical to today's flat tail\ngot:\n%s\nwant:\n%s", got, want)
	}
}

// TestStableMalformedFrameIsInert: an unreadable frame changes nothing. That is
// not a shrug — the byte cursor notices the missing bytes on the NEXT frame and
// stops the turn, so a frame this decoder could not read is never absorbed.
func TestStableMalformedFrameIsInert(t *testing.T) {
	base := State{Tail: "some streamed text", StableTurn: 1, CommittedBytes: 4}
	for _, data := range []string{
		`not json at all`,
		`{"turn":1,"from":4}`, // no `to`
		`{"turn":1,"from":4,"to":4,"blocks":[{"type":"paragraph"}]}`, // empty window
		`{"turn":1,"from":4,"to":9,"blocks":[]}`,                     // settles nothing
		`{"turn":0,"from":4,"to":9,"blocks":[{"type":"paragraph"}]}`, // no such turn
	} {
		got := reduceStable(base, []byte(data))
		if len(got.Segments) != 0 || got.CommittedBytes != base.CommittedBytes || got.StableStopped {
			t.Fatalf("frame %s must be inert, got segments=%d committed=%d stopped=%v", data, len(got.Segments), got.CommittedBytes, got.StableStopped)
		}
	}
	if got := reduceStableEnd(base, []byte(`{"turn":1,"from":4,"reason":"wat"}`)); got.StableEnd != "" || got.StableStopped {
		t.Fatalf("an unknown terminal reason must be inert, got end=%q stopped=%v", got.StableEnd, got.StableStopped)
	}
}

// ── the real capture ─────────────────────────────────────────────────────────

// TestStableRealCaptureRendersRichAndLosesNothing replays the frames a PRODUCTION
// server really emitted. The turn commits five append-only segments; the
// committed prefix renders through the same Decode → RenderDoc stack the settled
// transcript uses; nothing is lost; and the result is genuinely RICHER than the
// flat tail it replaces.
func TestStableRealCaptureRendersRichAndLosesNothing(t *testing.T) {
	fx := loadStableRealCapture(t)
	src := realCaptureSource(t, fx)
	st, accepted := driveStable(t, stableScript(t, fx.Frames, map[string]string{strconv.Itoa(fx.CapturedTurn): src}, 128))

	if accepted != fx.MidTurnFrames {
		t.Fatalf("accepted %d of the capture's %d stable frames", accepted, fx.MidTurnFrames)
	}
	if st.CommittedBytes != fx.CommittedBytes {
		t.Fatalf("committed %d bytes, the capture recorded %d", st.CommittedBytes, fx.CommittedBytes)
	}
	if st.StableTurn != fx.CapturedTurn || !st.StableStopped || st.StableEnd != "settled" {
		t.Fatalf("turn=%d stopped=%v end=%q, want turn=%d stopped=true end=settled", st.StableTurn, st.StableStopped, st.StableEnd, fx.CapturedTurn)
	}
	// The last boundary reached the end of the turn, so by `stable_end` the WHOLE
	// live tail is committed and nothing is left on the plain path.
	if rem := tailRemainder(st); rem != "" {
		t.Fatalf("a fully-committed turn must leave no plain remainder, got %d bytes", len(rem))
	}

	lines := renderLiveTail(chatRegistry, 80, st)
	assertNoContentLost(t, "real capture", src, lines)
	if len(lines) < 2 || !strings.Contains(ansi.Strip(lines[0]), streamingMarker) {
		t.Fatalf("the live turn keeps its streaming marker, got %q", lines[0])
	}

	// THE SAME STACK, proven by output identity: the committed segments render
	// exactly what the SETTLED row renders from the same blocks — Decode →
	// RenderDoc, one call, one Figure reset (D10). Not a similar path; the same one.
	settled := renderAssistantDoc(chatRegistry, 80, Message{Role: "assistant", Blocks: settledBlocks(t, fx)})
	if got := strings.Join(lines[1:], "\n"); got != strings.Join(settled, "\n") {
		t.Fatalf("the committed prefix must render through the settled stack byte for byte\ngot:\n%s\nwant:\n%s", got, strings.Join(settled, "\n"))
	}

	// Recorded honestly, because it is the shape of THIS capture: the turn is five
	// plain paragraphs, and prose wrapped by pdrender happens to land byte-for-byte
	// on prose wrapped by the plain tail. Progressive rendering earns its keep on
	// headings, lists and fences (TestStableGoldenHeadingAndListColour) — on pure
	// prose it is honestly a no-op, which is the improvement-only floor from the
	// other side.
	if strings.Join(lines, "\n") != strings.Join(renderTail(bodyWidth(80), st.Tail), "\n") {
		t.Fatal("this capture is prose-only: if the two paths now differ, the fixture changed shape and this test's premise needs re-reading")
	}
}

// TestStableRealCaptureMidTurnSplitsAtTheCursor: while the turn is still
// streaming, exactly the committed prefix is rich and exactly the rest is plain —
// no byte is painted twice and none is hidden.
func TestStableRealCaptureMidTurnSplitsAtTheCursor(t *testing.T) {
	fx := loadStableRealCapture(t)
	src := realCaptureSource(t, fx)
	sources := map[string]string{strconv.Itoa(fx.CapturedTurn): src}

	// Stop after the second stable frame: the turn is mid-flight.
	var head []stableFixtureFrame
	for _, f := range fx.Frames {
		if f.Event != "stable" {
			break
		}
		head = append(head, f)
		if len(head) == 2 {
			break
		}
	}
	st, _ := driveStable(t, stableScript(t, head, sources, 64))

	h := decodeStableHeader(t, head[1].Data)
	if st.CommittedBytes != *h.To {
		t.Fatalf("committed %d, want the second frame's to=%d", st.CommittedBytes, *h.To)
	}
	if got, want := tailRemainder(st), src[*h.To:]; got != want {
		t.Fatalf("the plain remainder must be exactly the uncommitted source\ngot  %d bytes\nwant %d bytes", len(got), len(want))
	}
	if st.StableStopped {
		t.Fatal("a healthy mid-turn stream must still be consuming")
	}
	assertNoContentLost(t, "mid-turn", src, renderLiveTail(chatRegistry, 80, st))
}

// TestStableChunkingInvariance is the chunking law: the SAME frames split across
// any number of ticks — one byte per delta, or the whole turn in one — reach the
// identical quiescent frame. The reducer is a fold over the wire, so how the
// socket happened to slice the bytes can never change what the reader sees.
func TestStableChunkingInvariance(t *testing.T) {
	fx := loadStableRealCapture(t)
	src := realCaptureSource(t, fx)
	sources := map[string]string{strconv.Itoa(fx.CapturedTurn): src}

	var want string
	for _, chunk := range []int{1, 3, 17, 256, 4096, 0 /* one delta per frame */} {
		st, accepted := driveStable(t, stableScript(t, fx.Frames, sources, chunk))
		got := strings.Join(renderLiveTail(chatRegistry, 80, st), "\n")
		if accepted != fx.MidTurnFrames || st.CommittedBytes != fx.CommittedBytes {
			t.Fatalf("chunk=%d: accepted %d / committed %d", chunk, accepted, st.CommittedBytes)
		}
		if want == "" {
			want = got
			continue
		}
		if got != want {
			t.Fatalf("chunk=%d produced a different quiescent frame\ngot:\n%s\nwant:\n%s", chunk, got, want)
		}
	}
}

// ── the contract's recorded walks ────────────────────────────────────────────

// TestStableContractSequences executes the cross-surface fixture's cursor_rule
// through the SHIPPED reducer: every recorded outcome, every recorded byte count,
// every recorded drop. The three degrade sequences must land on the plain floor
// with nothing lost.
func TestStableContractSequences(t *testing.T) {
	fx := loadStableContract(t)
	outcomes := map[string]bool{}

	for _, seq := range fx.Sequences {
		seq := seq
		t.Run(seq.Name, func(t *testing.T) {
			st, accepted := driveStable(t, stableScript(t, seq.Frames, seq.Sources, 32))

			if accepted != seq.Expected.AcceptedStableFrames {
				t.Fatalf("accepted %d stable frames, the contract records %d", accepted, seq.Expected.AcceptedStableFrames)
			}
			if st.CommittedBytes != seq.Expected.CommittedBytes {
				t.Fatalf("committed %d bytes, the contract records %d", st.CommittedBytes, seq.Expected.CommittedBytes)
			}
			if st.StableTurn != seq.Expected.FinalTurn {
				t.Fatalf("final turn %d, the contract records %d", st.StableTurn, seq.Expected.FinalTurn)
			}
			if seq.DropsSegments && len(st.Segments) != 0 {
				t.Fatalf("the contract marks this sequence drops_segments, yet %d survived", len(st.Segments))
			}
			// A gap, a degrade and a cap are all TERMINAL for the turn: nothing
			// may be consumed after them.
			if seq.Expected.Outcome != "streaming" && !st.StableStopped {
				t.Fatalf("outcome %q must stop consumption for the turn", seq.Expected.Outcome)
			}
			outcomes[seq.Expected.Outcome] = true

			// The floor, on every sequence including the broken ones: whatever the
			// segment stream did, the reader still sees every byte of the turn.
			for turn, src := range seq.Sources {
				if turn == strconv.Itoa(st.StableTurn) {
					assertNoContentLost(t, seq.Name, src, renderLiveTail(chatRegistry, 80, st))
				}
			}
		})
	}

	for _, want := range []string{"settled", "capped", "degraded", "gap"} {
		if !outcomes[want] {
			t.Fatalf("coverage floor: no sequence reaches outcome %q", want)
		}
	}
}

// TestStableHoleKeepsCommittedAndPlainsTheRest is the append-only guard, run.
// The contract's midstream_gap sequence drops the middle frame of a three-segment
// turn: the client keeps the one segment it committed, stops consuming, and puts
// the ENTIRE rest of the turn — including the bytes the missing frame would have
// covered — back on the plain path. Never worse than today's flat tail.
//
// MUTATION: delete the `from != st.CommittedBytes` guard in reduceStable and this
// reds twice over — the cursor jumps to 93 and the 45 bytes the hole covers are
// painted by no block and shown by no remainder.
func TestStableHoleKeepsCommittedAndPlainsTheRest(t *testing.T) {
	fx := loadStableContract(t)
	seq := findStableSequence(t, fx, "midstream_gap_one_frame_dropped")
	src := seq.Sources["1"]

	st, accepted := driveStable(t, stableScript(t, seq.Frames, seq.Sources, 8))
	if accepted != 1 || len(st.Segments) != 1 {
		t.Fatalf("the hole must keep exactly the pre-hole segment, accepted=%d segments=%d", accepted, len(st.Segments))
	}
	if st.CommittedBytes != seq.Expected.CommittedBytes {
		t.Fatalf("the cursor must stay at %d, got %d", seq.Expected.CommittedBytes, st.CommittedBytes)
	}
	if !st.StableStopped {
		t.Fatal("a hole stops the turn: a later frame must not re-open the wound")
	}
	if got, want := tailRemainder(st), src[st.CommittedBytes:]; got != want {
		t.Fatalf("the remainder must cover every uncommitted byte\ngot  %q\nwant %q", got, want)
	}
	assertNoContentLost(t, "hole", src, renderLiveTail(chatRegistry, 80, st))

	// A frame arriving after the stop is inert, not a second chance.
	after := reduceStable(st, []byte(`{"turn":1,"from":14,"to":59,"blocks":[{"type":"paragraph","content":[{"type":"text","value":"late"}]}]}`))
	if len(after.Segments) != 1 || after.CommittedBytes != st.CommittedBytes {
		t.Fatalf("a post-stop frame must be inert, got segments=%d committed=%d", len(after.Segments), after.CommittedBytes)
	}
}

// TestStableTurnBoundaryGapIsRejected: `from` alone false-accepts a spliced turn
// whose predecessor's total coincidentally equals the survivor's `from` — the
// contract's recorded run proof for why `turn` is on the wire. The shipped
// reducer must reject it and re-base to the plain floor.
func TestStableTurnBoundaryGapIsRejected(t *testing.T) {
	fx := loadStableContract(t)
	seq := findStableSequence(t, fx, "turn_boundary_gap_false_accepted_by_from_only")

	st, _ := driveStable(t, stableScript(t, seq.Frames, seq.Sources, 64))
	if st.StableTurn != 2 || !st.StableStopped {
		t.Fatalf("turn 2 must be adopted and refused, got turn=%d stopped=%v", st.StableTurn, st.StableStopped)
	}
	if st.CommittedBytes != 0 || len(st.Segments) != 0 {
		t.Fatalf("a re-based turn starts from nothing, got committed=%d segments=%d", st.CommittedBytes, len(st.Segments))
	}
	// Turn 1's text is still in the tail (its settle has not landed) and turn 2's
	// bytes appended after it — both must still be readable, plainly.
	assertNoContentLost(t, "turn 1", seq.Sources["1"], renderLiveTail(chatRegistry, 80, st))
	assertNoContentLost(t, "turn 2", seq.Sources["2"], renderLiveTail(chatRegistry, 80, st))
}

// TestStableDegradedDropsSegmentsAndCappedKeepsThem pins the two terminal frames
// that are NOT settled, and they are deliberately different: a degrade means the
// server distrusts its own blocks, so they go; a cap means the document is frozen
// at a boundary it still stands behind, so what is committed stays.
func TestStableDegradedDropsSegmentsAndCappedKeepsThem(t *testing.T) {
	fx := loadStableContract(t)

	deg := findStableSequence(t, fx, "degraded_after_two_segments")
	st, _ := driveStable(t, stableScript(t, deg.Frames, deg.Sources, 16))
	if len(st.Segments) != 0 || st.CommittedBytes != 0 || st.StableEnd != "degraded" {
		t.Fatalf("a degrade drops everything, got segments=%d committed=%d end=%q", len(st.Segments), st.CommittedBytes, st.StableEnd)
	}
	if got := tailRemainder(st); got != deg.Sources["1"] {
		t.Fatalf("after a degrade the WHOLE tail is plain again\ngot  %q\nwant %q", got, deg.Sources["1"])
	}
	if a, b := strings.Join(renderLiveTail(chatRegistry, 80, st), "\n"), strings.Join(renderTail(bodyWidth(80), st.Tail), "\n"); a != b {
		t.Fatal("a degraded turn must render exactly today's flat tail")
	}

	// A cap after two good segments keeps them: same frames, terminal reason swapped.
	capped := append([]stableFixtureFrame(nil), deg.Frames[:2]...)
	capped = append(capped, stableFixtureFrame{Event: "stable_end", Data: json.RawMessage(`{"turn":1,"from":81,"reason":"capped"}`)})
	st, _ = driveStable(t, stableScript(t, capped, deg.Sources, 16))
	if len(st.Segments) != 2 || st.CommittedBytes != 81 || !st.StableStopped || st.StableEnd != "capped" {
		t.Fatalf("a cap freezes at the boundary and KEEPS what is committed, got segments=%d committed=%d stopped=%v end=%q",
			len(st.Segments), st.CommittedBytes, st.StableStopped, st.StableEnd)
	}
	assertNoContentLost(t, "capped", deg.Sources["1"], renderLiveTail(chatRegistry, 80, st))
}

// TestStableSnapshotIntoAShortTailIsRefused: the connect-time snapshot (D63)
// commits from the turn's byte 0, which a client that attached MID-TURN never
// received. Painting it would show the segment as a block AND as plain source
// underneath, forever — the exact corruption recorder.ex's ingest-order comment
// warns about. The window must be inside the tail we hold, or the turn stays plain.
func TestStableSnapshotIntoAShortTailIsRefused(t *testing.T) {
	st := State{Tail: "only the bytes since I attached.\n\n"}
	snapshot := []byte(`{"turn":7,"from":0,"to":4096,"blocks":[{"type":"paragraph","content":[{"type":"text","value":"everything before the attach"}]}],"skeleton":null}`)

	got := reduceStable(st, snapshot)
	if len(got.Segments) != 0 || got.CommittedBytes != 0 {
		t.Fatalf("an unmappable window must be refused, got segments=%d committed=%d", len(got.Segments), got.CommittedBytes)
	}
	if !got.StableStopped {
		t.Fatal("refusing the window stops the turn — the client cannot map any later frame either")
	}
	if a, b := strings.Join(renderLiveTail(chatRegistry, 80, got), "\n"), strings.Join(renderTail(bodyWidth(80), st.Tail), "\n"); a != b {
		t.Fatal("a refused snapshot renders exactly today's flat tail")
	}
}

// TestStableBaseFollowsACarriedTurn is the D77 residual, consumed correctly: a
// finished turn's text is still painted (its settle GET has not landed) when the
// next turn's init arrives, so the new turn's byte 0 sits PAST it. The base is
// stamped at that init, and both lanes get the same treatment.
func TestStableBaseFollowsACarriedTurn(t *testing.T) {
	carried := "TURN-1 REPLY, still painted while its settle GET is in flight.\n\n"
	for _, lane := range []struct {
		name  string
		start FrameEvent
	}{
		{"claude system/init", initFrame(t)},
		{"codex turn_started", FrameEvent{Name: "runtime", Data: []byte(`{"kind":"turn_started"}`)}},
	} {
		t.Run(lane.name, func(t *testing.T) {
			st := State{Tail: carried}
			st, _ = Reduce(st, lane.start, t0)
			if st.StableBase != len(carried) {
				t.Fatalf("the turn-start frame must stamp the base at %d, got %d", len(carried), st.StableBase)
			}
			body := "Turn two commits its own bytes.\n\nAnd keeps streaming.\n"
			st, _ = Reduce(st, deltaFrame(t, body), t0)
			frame := []byte(`{"turn":2,"from":0,"to":33,"blocks":[{"type":"paragraph","content":[{"type":"text","value":"Turn two commits its own bytes."}]}],"skeleton":null}`)
			st = reduceStable(st, frame)

			if st.CommittedBytes != 33 || len(st.Segments) != 1 {
				t.Fatalf("turn 2's first segment must commit against the carried base, got committed=%d segments=%d", st.CommittedBytes, len(st.Segments))
			}
			if got, want := tailRemainder(st), body[33:]; got != want {
				t.Fatalf("the remainder must start after turn 2's committed prefix\ngot  %q\nwant %q", got, want)
			}
			lines := renderLiveTail(chatRegistry, 80, st)
			shown := plainText(lines)
			if strings.Count(shown, "Turn two commits its own bytes.") != 1 {
				t.Fatalf("the committed prefix must be painted exactly once:\n%s", strings.Join(lines, "\n"))
			}
			if !strings.Contains(shown, "TURN-1 REPLY") {
				t.Fatalf("the carried turn stays readable as plain text:\n%s", strings.Join(lines, "\n"))
			}
		})
	}
}

// ── the settle seam (D9/D77) ─────────────────────────────────────────────────

// TestStablePromotionToSettleNoDuplicateNoLoss walks the real capture all the way
// through the turn boundary: frames → result → the settle GET landing. The
// committed segments are dropped in the SAME reducer step that appends the
// persisted row, so the answer is on screen exactly once before the promotion and
// exactly once after it — never twice, never zero.
//
// MUTATION: delete `st = clearStable(st)` from reduceTailFetched's D77-guarded
// tail clear and this reds — five segments survive a settle they no longer
// describe, and the live document outlives the tail it annotates.
func TestStablePromotionToSettleNoDuplicateNoLoss(t *testing.T) {
	fx := loadStableRealCapture(t)
	src := realCaptureSource(t, fx)
	st, _ := driveStable(t, stableScript(t, fx.Frames, map[string]string{strconv.Itoa(fx.CapturedTurn): src}, 128))

	probe := firstSentence(src)
	before := plainText(liveModel(st).transcriptLines(80))
	if strings.Count(before, probe) != 1 {
		t.Fatalf("mid-turn the answer must be on screen exactly once, got %d", strings.Count(before, probe))
	}

	// The turn boundary: the result frame settles, the GET lands with the
	// persisted row carrying the SAME blocks the segments were built from.
	st, effects := Reduce(st, resultFrame(t, "", false), t0)
	fetch, ok := effects[0].(FetchTailEffect)
	if !ok {
		t.Fatalf("the result frame must issue the settle GET, got %T", effects[0])
	}
	row := Message{Seq: 1, Role: "assistant", SourceMarkdown: src, Blocks: settledBlocks(t, fx)}
	st, _ = Reduce(st, TailFetchedEvent{Session: Session{Messages: []Message{row}}, Gen: fetch.Gen}, t0)

	if st.Tail != "" {
		t.Fatalf("the settle clears the tail, got %d bytes", len(st.Tail))
	}
	if len(st.Segments) != 0 || st.CommittedBytes != 0 || st.StableTurn != 0 || st.StableBase != 0 || st.StableStopped || st.StableEnd != "" {
		t.Fatalf("the live document must die with the tail it annotates: segments=%d committed=%d turn=%d base=%d stopped=%v end=%q",
			len(st.Segments), st.CommittedBytes, st.StableTurn, st.StableBase, st.StableStopped, st.StableEnd)
	}

	after := plainText(liveModel(st).transcriptLines(80))
	if n := strings.Count(after, probe); n != 1 {
		t.Fatalf("after the promotion the answer must be on screen exactly once, got %d", n)
	}
	assertNoContentLost(t, "settled transcript", src, liveModel(st).transcriptLines(80))
}

// TestStableSettledTranscriptIsByteIdentical: the settled row renders through
// renderAssistantDoc exactly as it always has — the live document is presentation
// only, and it leaves no trace in the transcript it hands over to (D9).
func TestStableSettledTranscriptIsByteIdentical(t *testing.T) {
	fx := loadStableRealCapture(t)
	src := realCaptureSource(t, fx)
	row := Message{Seq: 1, Role: "assistant", SourceMarkdown: src, Blocks: settledBlocks(t, fx)}

	// One model reached the settled row THROUGH the live document; the other never
	// saw a `stable` frame in its life.
	viaSegments, _ := driveStable(t, stableScript(t, fx.Frames, map[string]string{strconv.Itoa(fx.CapturedTurn): src}, 128))
	viaSegments, effects := Reduce(viaSegments, resultFrame(t, "", false), t0)
	viaSegments, _ = Reduce(viaSegments, TailFetchedEvent{Session: Session{Messages: []Message{row}}, Gen: effects[0].(FetchTailEffect).Gen}, t0)

	plain := State{Messages: []Message{row}, LastSeq: 1}

	got := strings.Join(liveModel(viaSegments).transcriptLines(80), "\n")
	want := strings.Join(liveModel(plain).transcriptLines(80), "\n")
	if got != want {
		t.Fatalf("the settled transcript must be byte-identical with and without the live document\ngot:\n%s\nwant:\n%s", got, want)
	}
}

// ── the skeleton (D67) ───────────────────────────────────────────────────────

// TestStableSkeletonIsOneHonestLine: the server-provided skeleton renders as ONE
// existing-idiom status line built from its `kind` alone. It never fabricates
// content, and it never repeats skeleton.prose — those bytes are already in the
// plain remainder above it, and printing them again would double them.
func TestStableSkeletonIsOneHonestLine(t *testing.T) {
	fx := loadStableContract(t)
	seq := findStableSequence(t, fx, "open_fence_skeleton")
	if seq.SkeletonAtFrame == nil {
		t.Fatal("fixture floor: open_fence_skeleton no longer records which frame carries it")
	}
	src := seq.Sources["1"]

	// Drive only up to (and including) the skeleton-bearing frame.
	st, _ := driveStable(t, stableScript(t, seq.Frames[:*seq.SkeletonAtFrame+1], seq.Sources, 12))
	if st.Skeleton == nil {
		t.Fatal("the frame's skeleton must reach the state")
	}
	lines := renderLiveTail(chatRegistry, 80, st)

	forming := 0
	for _, ln := range lines {
		if strings.Contains(ansi.Strip(ln), "forming…") {
			forming++
		}
	}
	if forming != 1 {
		t.Fatalf("exactly ONE placeholder per frame (D67), got %d:\n%s", forming, strings.Join(lines, "\n"))
	}
	last := ansi.Strip(lines[len(lines)-1])
	if last != "⋯ code block forming…" {
		t.Fatalf("the placeholder names the forming block from the server's kind, got %q", last)
	}
	// The prose above the forming component is live text in the remainder — shown
	// once, by the plain path, not re-printed by the placeholder.
	if n := strings.Count(plainText(lines), "It looks like this:"); n != 1 {
		t.Fatalf("skeleton.prose must appear exactly once (in the remainder), got %d", n)
	}
	assertNoContentLost(t, "skeleton", src, lines)

	// An eighth kind a newer server invents degrades to the generic word rather
	// than printing something this surface has no shape for.
	if got := skeletonLine(&StableSkeleton{Kind: "hologram"}); got != "⋯ block forming…" {
		t.Fatalf("an unknown kind must degrade to the generic placeholder, got %q", got)
	}
	if got := skeletonLine(nil); got != "" {
		t.Fatalf("no skeleton means no placeholder, got %q", got)
	}
}

// ── D79: the colour-knob law ─────────────────────────────────────────────────

// TestStableGoldenHeadingAndListColour is the D79 golden: heading and list colour
// live on the process-global lipgloss profile, so the assertion runs under a
// FORCED TrueColor profile with a t.Cleanup restore. The guard-the-guard arm
// proves the force is load-bearing — under a colourless profile the same
// committed segments carry no SGR at all, which is exactly why an unforced
// assertion here would be vacuous.
func TestStableGoldenHeadingAndListColour(t *testing.T) {
	fx := loadStableContract(t)
	seq := findStableSequence(t, fx, "clean_three_segments_settled")
	st, _ := driveStable(t, stableScript(t, seq.Frames, seq.Sources, 24))
	if len(st.Segments) != 3 {
		t.Fatalf("the golden needs all three segments committed, got %d", len(st.Segments))
	}

	prev := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(prev) })

	lipgloss.SetColorProfile(termenv.Ascii)
	flat := strings.Join(renderLiveTail(chatRegistry, 80, st), "\n")
	if strings.Contains(flat, "\x1b[") {
		t.Fatalf("under a colourless profile the committed segments must carry no SGR:\n%q", flat)
	}
	// The enrichment itself, before any colour: a committed heading has lost its
	// `##` and a committed list its `- ` — the flat tail shows the markdown source,
	// this shows the document.
	if plain := strings.Join(renderTail(bodyWidth(80), st.Tail), "\n"); plain == flat {
		t.Fatal("a heading/list turn must render DIFFERENTLY from the flat tail — the pdrender stack is not being reached")
	} else if strings.Contains(flat, "## Streaming stables") || strings.Contains(flat, "- the byte cursor") {
		t.Fatalf("committed blocks must render as a document, not as markdown source:\n%s", flat)
	}

	lipgloss.SetColorProfile(termenv.TrueColor)
	colored := strings.Join(renderLiveTail(chatRegistry, 80, st), "\n")
	if colored == flat {
		t.Fatal("forcing TrueColor changed nothing — the heading/list styles are not on the global profile any more")
	}
	if ansi.Strip(colored) != flat {
		t.Fatalf("colour must be the ONLY difference between the two profiles\n%q\n%q", ansi.Strip(colored), flat)
	}

	heading, bullet := "", ""
	for _, ln := range strings.Split(colored, "\n") {
		switch {
		case heading == "" && strings.Contains(ansi.Strip(ln), "Streaming stables"):
			heading = ln
		case bullet == "" && strings.Contains(ansi.Strip(ln), "the byte cursor advances"):
			bullet = ln
		}
	}
	if !strings.Contains(heading, "\x1b[") {
		t.Fatalf("a committed heading must wear the theme's colour under TrueColor, got %q", heading)
	}
	if !strings.Contains(bullet, "\x1b[") {
		t.Fatalf("a committed list bullet must wear the theme's colour under TrueColor, got %q", bullet)
	}
	if !strings.Contains(ansi.Strip(bullet), "•") {
		t.Fatalf("a committed list renders the bullet glyph, got %q", ansi.Strip(bullet))
	}
}

// TestStableFenceIsStructuralOnly is D79's other half: pdrender's chat profile is
// the hardcoded NoColor const, which short-circuits chroma, so a fence is asserted
// on STRUCTURE only — the border glyph, the language label, and the code body.
// There is deliberately NO colour assertion here: it would be vacuous or falsely
// red by construction.
func TestStableFenceIsStructuralOnly(t *testing.T) {
	fx := loadStableContract(t)
	seq := findStableSequence(t, fx, "open_fence_skeleton")
	st, _ := driveStable(t, stableScript(t, seq.Frames, seq.Sources, 20))

	lines := renderLiveTail(chatRegistry, 80, st)
	var fence []string
	for _, ln := range lines {
		if strings.HasPrefix(ansi.Strip(ln), "▌") {
			fence = append(fence, ansi.Strip(ln))
		}
	}
	if len(fence) < 2 {
		t.Fatalf("a committed fence renders a bordered, multi-line block, got %d lines:\n%s", len(fence), strings.Join(lines, "\n"))
	}
	label := strings.TrimSpace(strings.TrimPrefix(fence[0], "▌"))
	if label == "" || strings.ToUpper(label) != label {
		t.Fatalf("the fence's first line is its language label, got %q", label)
	}
	body := strings.Join(fence[1:], "\n")
	if !strings.Contains(body, "func Render(doc Doc) string") {
		t.Fatalf("the fence body must carry the code verbatim, got:\n%s", body)
	}
}

// ── helpers ──────────────────────────────────────────────────────────────────

func findStableSequence(t *testing.T, fx stableContractFile, name string) stableFixtureSequence {
	t.Helper()
	for _, seq := range fx.Sequences {
		if seq.Name == name {
			return seq
		}
	}
	t.Fatalf("fixture floor: sequence %q is gone", name)
	return stableFixtureSequence{}
}

// settledBlocks assembles the persisted row's `blocks` from the capture — the
// same blocks the segments carried, which is exactly the point: the server's
// settle self-check (D61) passed because concat(segments) matched the whole
// document.
func settledBlocks(t *testing.T, fx stableRealFile) json.RawMessage {
	t.Helper()
	var all []json.RawMessage
	for _, f := range fx.Frames {
		if f.Event != "stable" {
			continue
		}
		h := decodeStableHeader(t, f.Data)
		var blocks []json.RawMessage
		if err := json.Unmarshal(h.Blocks, &blocks); err != nil {
			t.Fatalf("decode blocks: %v", err)
		}
		all = append(all, blocks...)
	}
	raw, err := json.Marshal(map[string]any{"version": 1, "blocks": all})
	if err != nil {
		t.Fatalf("marshal settled blocks: %v", err)
	}
	return raw
}

// firstSentence is a distinctive probe string for counting how many times the
// answer appears on screen.
func firstSentence(src string) string {
	if i := strings.Index(src, "."); i > 0 {
		return strings.Join(strings.Fields(src[:i]), " ")
	}
	return strings.Join(strings.Fields(src), " ")
}
