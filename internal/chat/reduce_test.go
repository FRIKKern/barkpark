package chat

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// reduce_test.go — the recorded-frame reducer proofs. Every acceptance-criteria
// invariant (D8 settlement, D9 tail carve-out, D11 interrupt truth, D12 queued
// steer, D15 title refresh) is driven by feeding Reduce the same NDJSON-shaped
// frames the server emits — no terminal, no server, no clock. This IS the test
// seam the pure reducer exists for.

var t0 = time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)

// chatFrame builds an event:chat FrameEvent from a raw JSON object.
func chatFrame(t *testing.T, obj any) FrameEvent {
	t.Helper()
	raw, err := json.Marshal(obj)
	if err != nil {
		t.Fatalf("marshal frame: %v", err)
	}
	return FrameEvent{Name: "chat", Data: raw}
}

func initFrame(t *testing.T) FrameEvent {
	return chatFrame(t, map[string]any{"type": "system", "subtype": "init"})
}

func deltaFrame(t *testing.T, text string) FrameEvent {
	return chatFrame(t, map[string]any{
		"type":  "stream_event",
		"event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": text}},
	})
}

func resultFrame(t *testing.T, reason string, isErr bool) FrameEvent {
	return chatFrame(t, map[string]any{
		"type": "result", "subtype": "success", "terminal_reason": reason, "is_error": isErr,
	})
}

// drive folds a sequence of events through Reduce, collecting the LAST effect
// set, so a test can assert the settled state plus what IO the final event asked
// for.
func drive(st State, now time.Time, evs ...Event) (State, []Effect) {
	var effs []Effect
	for _, ev := range evs {
		st, effs = Reduce(st, ev, now)
	}
	return st, effs
}

func hasFetchTail(effs []Effect) (FetchTailEffect, bool) {
	for _, e := range effs {
		if f, ok := e.(FetchTailEffect); ok {
			return f, true
		}
	}
	return FetchTailEffect{}, false
}

func hasEffect[T Effect](effs []Effect) bool {
	for _, e := range effs {
		if _, ok := e.(T); ok {
			return true
		}
	}
	return false
}

// TestDeltaTailAccumulatesAndSettlesAtResult proves D8/D9: deltas form the live
// plain-text tail; ONLY the terminal result frame is the turn boundary, and it
// alone asks for the ?since= refetch that settles the tail into blocks.
func TestDeltaTailAccumulatesAndSettlesAtResult(t *testing.T) {
	st := State{SessionID: "s1"}
	st, _ = drive(st, t0, initFrame(t))
	if st.Phase != TurnStreaming {
		t.Fatalf("init frame should start streaming, got %v", st.Phase)
	}

	st, effs := drive(st, t0, deltaFrame(t, "Hel"), deltaFrame(t, "lo"))
	if st.Tail != "Hello" {
		t.Fatalf("tail = %q, want %q", st.Tail, "Hello")
	}
	if len(effs) != 0 {
		t.Fatalf("a delta must trigger no IO (tail is live truth), got %d effects", len(effs))
	}

	st, effs = drive(st, t0, resultFrame(t, "", false))
	if st.Phase != TurnIdle {
		t.Fatalf("result must end the turn, phase = %v", st.Phase)
	}
	if !st.Settling {
		t.Fatal("result must mark the state settling")
	}
	f, ok := hasFetchTail(effs)
	if !ok {
		t.Fatal("result must emit exactly one FetchTailEffect (the turn-boundary refetch)")
	}
	if f.SinceSeq != st.LastSeq {
		t.Fatalf("refetch SinceSeq = %d, want LastSeq %d", f.SinceSeq, st.LastSeq)
	}
	// The tail stays painted until the fetch returns — never a blank flash.
	if st.Tail != "Hello" {
		t.Fatalf("tail must survive until settlement lands, got %q", st.Tail)
	}
}

// TestTailFetchedSettlesAndRefreshesTitle proves D8/D15: the turn-boundary GET
// appends the persisted blocks, clears the settled tail, and lands the
// (AI-refreshed) title.
func TestTailFetchedSettlesAndRefreshesTitle(t *testing.T) {
	st := State{SessionID: "s1", Tail: "Hello", Settling: true, Phase: TurnIdle, LastSeq: 0}
	sess := Session{
		ID:    "s1",
		Title: "Refreshed AI Title",
		Messages: []Message{
			{Seq: 1, Role: "assistant", Blocks: json.RawMessage(`[{"type":"paragraph","content":[{"type":"text","value":"Hello"}]}]`)},
		},
	}
	st, _ = drive(st, t0, TailFetchedEvent{Session: sess})

	if got := len(st.Messages); got != 1 {
		t.Fatalf("settled message count = %d, want 1", got)
	}
	if st.LastSeq != 1 {
		t.Fatalf("LastSeq = %d, want 1 (seq cursor advanced)", st.LastSeq)
	}
	if st.Tail != "" {
		t.Fatalf("tail must clear once it settles into blocks, got %q", st.Tail)
	}
	if st.Title != "Refreshed AI Title" {
		t.Fatalf("title = %q, want the refreshed title (D15)", st.Title)
	}
	if st.Settling {
		t.Fatal("settling must clear after the fetch lands")
	}
}

// TestTailFetchedErrorKeepsTailPainted proves the D8 "never silently drop
// streamed text" rule: a failed refetch keeps the tail and says so.
func TestTailFetchedErrorKeepsTailPainted(t *testing.T) {
	st := State{SessionID: "s1", Tail: "partial reply", Settling: true}
	st, _ = drive(st, t0, TailFetchedEvent{Err: errString("boom")})
	if st.Tail != "partial reply" {
		t.Fatalf("a failed refetch must keep the tail, got %q", st.Tail)
	}
	if st.Notice == "" {
		t.Fatal("a failed refetch must surface an honest notice")
	}
}

// TestInterruptImmediateThenAbortedIsNotAnError proves D11: Esc during a turn
// flips to interrupting immediately and arms the wedge; the empty control ack is
// non-terminal; only the result frame settles it — and aborted_streaming is a
// NORMAL outcome ("Interrupted — session live"), never an error.
func TestInterruptImmediateThenAbortedIsNotAnError(t *testing.T) {
	st := State{SessionID: "s1", Phase: TurnStreaming, Tail: "thinking"}

	st, effs := drive(st, t0, InterruptEvent{})
	if st.Phase != TurnInterrupting {
		t.Fatalf("Esc must flip to interrupting immediately, got %v", st.Phase)
	}
	if st.Notice != "interrupting…" {
		t.Fatalf("notice = %q, want interrupting…", st.Notice)
	}
	if !hasEffect[InterruptEffect](effs) {
		t.Fatal("Esc must emit an InterruptEffect")
	}
	if st.WedgeAt.IsZero() {
		t.Fatal("Esc must arm the local wedge timer")
	}

	// The empty control ack is not completion — a further delta keeps us
	// interrupting (deltas may keep landing until the CLI actually stops).
	st, _ = drive(st, t0, deltaFrame(t, " more"))
	if st.Phase != TurnInterrupting {
		t.Fatalf("a delta after Esc must NOT settle the turn, phase = %v", st.Phase)
	}

	// The result frame is the truth: aborted_streaming settles non-error.
	st, effs = drive(st, t0, resultFrame(t, "aborted_streaming", false))
	if st.Phase != TurnIdle {
		t.Fatalf("result must end the interrupted turn, phase = %v", st.Phase)
	}
	if st.Notice != "⊘ Interrupted — session live" {
		t.Fatalf("interrupted notice = %q, want the non-error session-live line", st.Notice)
	}
	if _, ok := hasFetchTail(effs); !ok {
		t.Fatal("an interrupted turn still settles its tail from Postgres")
	}
}

// TestInterruptWedgeDegradesLocally proves the D11 8s wedge: if the result never
// arrives, a tick past the deadline force-degrades locally and refetches.
func TestInterruptWedgeDegradesLocally(t *testing.T) {
	st := State{SessionID: "s1", Phase: TurnStreaming}
	st, _ = drive(st, t0, InterruptEvent{})

	// A tick before the deadline changes nothing.
	st2, effs := drive(st, t0.Add(7*time.Second), TickEvent{})
	if st2.Phase != TurnInterrupting || len(effs) != 0 {
		t.Fatal("a tick before the 8s deadline must not degrade")
	}

	// A tick past 8s degrades locally and refetches.
	st3, effs := drive(st, t0.Add(9*time.Second), TickEvent{})
	if st3.Phase != TurnIdle {
		t.Fatalf("the wedge must degrade to idle after 8s, phase = %v", st3.Phase)
	}
	if _, ok := hasFetchTail(effs); !ok {
		t.Fatal("the wedge must refetch on degrade")
	}
}

// TestIdleEscIsSilentNoOp proves D11: Esc with no active turn does nothing —
// no phase change, no IO.
func TestIdleEscIsSilentNoOp(t *testing.T) {
	st := State{SessionID: "s1", Phase: TurnIdle}
	got, effs := drive(st, t0, InterruptEvent{})
	if got.Phase != TurnIdle || got.Notice != "" || len(effs) != 0 {
		t.Fatalf("idle Esc must be a silent no-op, got phase=%v notice=%q effects=%d", got.Phase, got.Notice, len(effs))
	}
}

// TestMidTurnSendQueuesThenResolvesNextTurn proves D12: a send during a turn is
// badged queued and only un-badges when a fresh system/init frame proves the
// next turn started.
func TestMidTurnSendQueuesThenResolvesNextTurn(t *testing.T) {
	st := State{SessionID: "s1", Phase: TurnStreaming}

	st, effs := drive(st, t0, SendEvent{Content: "next question"})
	if len(st.Local) != 1 || !st.Local[0].Queued {
		t.Fatalf("a mid-turn send must be badged queued, got %+v", st.Local)
	}
	if !hasEffect[SendEffect](effs) {
		t.Fatal("a send always POSTs immediately (the server does not distinguish queued)")
	}
	if st.Phase != TurnStreaming {
		t.Fatalf("a mid-turn send must not change the running phase, got %v", st.Phase)
	}

	// The next turn's init frame drains the badge.
	st, _ = drive(st, t0, initFrame(t))
	if st.Local[0].Queued {
		t.Fatal("a fresh system/init frame must clear the queued badge (the turn started)")
	}
}

// TestFreshSendStartsWaiting proves the idle-send path: a send with no active
// turn flips to waiting and is NOT badged.
func TestFreshSendStartsWaiting(t *testing.T) {
	st := State{SessionID: "s1", Phase: TurnIdle}
	st, _ = drive(st, t0, SendEvent{Content: "hi"})
	if st.Phase != TurnWaiting {
		t.Fatalf("a fresh send must flip to waiting, got %v", st.Phase)
	}
	if st.Local[0].Queued {
		t.Fatal("a fresh send must not be badged queued")
	}
}

// TestExitFrameSurfacesReason proves the public exit frame (charter D23
// {status, reason}) settles honestly: a null-status crash names its reason (not
// a misleading "status 0"), an integer exit shows the code, and the turn ends
// relaunchable — never carrying a stderr tail (the transport drops it).
func TestExitFrameSurfacesReason(t *testing.T) {
	// A crash with no integer status: reason must speak, status must NOT read 0.
	crash := FrameEvent{Name: "exit", Data: []byte(`{"status":null,"reason":"crashed"}`)}
	st, effs := drive(State{SessionID: "s1", Phase: TurnStreaming}, t0, crash)
	if !st.Exited || st.Phase != TurnIdle {
		t.Fatalf("exit must end the turn and mark exited, got exited=%v phase=%v", st.Exited, st.Phase)
	}
	if len(effs) != 0 {
		t.Fatalf("exit does no IO, got %d effects", len(effs))
	}
	if !strings.Contains(st.Notice, "crashed") {
		t.Fatalf("a null-status crash must name its reason, got %q", st.Notice)
	}
	if strings.Contains(st.Notice, "status 0") {
		t.Fatalf("a null-status exit must NOT misreport as status 0, got %q", st.Notice)
	}

	// An integer exit shows the code alongside the reason.
	clean := FrameEvent{Name: "exit", Data: []byte(`{"status":0,"reason":"clean"}`)}
	st, _ = drive(State{SessionID: "s1"}, t0, clean)
	if !strings.Contains(st.Notice, "status 0") || !strings.Contains(st.Notice, "clean") {
		t.Fatalf("an integer exit must show status + reason, got %q", st.Notice)
	}
}

// errString is a tiny error for the failed-fetch test.
type errString string

func (e errString) Error() string { return string(e) }
