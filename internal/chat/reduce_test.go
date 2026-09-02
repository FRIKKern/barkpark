package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func loadQueueFixture(t *testing.T, name string) []map[string]any {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "api", "test", "fixtures", "claude_chat", name))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var frames []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var frame map[string]any
		if err := json.Unmarshal([]byte(line), &frame); err != nil {
			t.Fatalf("decode fixture line: %v", err)
		}
		if frame["type"] != "fixture_provenance" {
			frames = append(frames, frame)
		}
	}
	return frames
}

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

func TestInterruptNoActiveTurnFixtureIsSilentNoOp(t *testing.T) {
	frames := loadQueueFixture(t, "interrupt_no_active_turn.ndjson")
	if len(frames) != 1 {
		t.Fatalf("frames = %d, want 1", len(frames))
	}
	response := frames[0]["response"].(map[string]any)
	body := response["response"].(map[string]any)
	if queued := body["still_queued"].([]any); len(queued) != 0 {
		t.Fatalf("still_queued = %#v, want []", queued)
	}

	got, effs := drive(State{SessionID: "s1", Phase: TurnIdle}, t0, InterruptEvent{})
	if got.Phase != TurnIdle || got.Notice != "" || len(effs) != 0 {
		t.Fatalf("empty ack race must remain silent: phase=%v notice=%q effects=%d", got.Phase, got.Notice, len(effs))
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

func TestMidTurnQueuedUserFixturePreservesTurnOneUntilFreshInit(t *testing.T) {
	frames := loadQueueFixture(t, "mid_turn_queued_user.ndjson")
	if len(frames) != 7 {
		t.Fatalf("frames = %d, want 7", len(frames))
	}

	st := State{SessionID: "s1"}
	st, _ = drive(st, t0, chatFrame(t, frames[0]), chatFrame(t, frames[1]))
	if st.Tail != "turn one" || st.Phase != TurnStreaming {
		t.Fatalf("turn one not streaming intact: tail=%q phase=%v", st.Tail, st.Phase)
	}

	content := frames[2]["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
	st, effs := drive(st, t0, SendEvent{Content: content})
	if st.Tail != "turn one" || len(st.Local) != 1 || !st.Local[0].Queued || !hasEffect[SendEffect](effs) {
		t.Fatalf("queued send changed turn one or lost queue truth: tail=%q local=%+v effects=%+v", st.Tail, st.Local, effs)
	}

	st, _ = drive(st, t0, chatFrame(t, frames[3]))
	if st.Phase != TurnIdle || st.Tail != "turn one" || !st.Local[0].Queued {
		t.Fatalf("turn one result must settle without consuming queued send: phase=%v tail=%q local=%+v", st.Phase, st.Tail, st.Local)
	}

	st, _ = drive(st, t0, chatFrame(t, frames[4]))
	if st.Phase != TurnStreaming || st.Local[0].Queued || st.Tail != "turn one" {
		t.Fatalf("fresh init must start queued turn and preserve turn one: phase=%v tail=%q local=%+v", st.Phase, st.Tail, st.Local)
	}
}

// TestSettleRaceStaleTailFetchDoesNotCorrupt proves charter D77: a stale turn-1
// tail-settle GET landing AFTER a queued turn-2's init already flipped Phase must
// still settle turn 1 into a single row AND clear the stale tail — the old
// Phase==TurnIdle guard mis-read the resumed streaming phase and left turn 1
// rendered twice, then turn-2 deltas concatenated onto the stale tail. Reverting
// the guard to `st.Phase == TurnIdle` makes this test fail (mutation-proof).
func TestSettleRaceStaleTailFetchDoesNotCorrupt(t *testing.T) {
	st := State{SessionID: "s1"}
	st, _ = drive(st, t0, initFrame(t), deltaFrame(t, "turn one"))

	// Turn 1's result emits the settle GET, which captures turn 1's generation.
	st, effs := drive(st, t0, resultFrame(t, "", false))
	fetch, ok := hasFetchTail(effs)
	if !ok {
		t.Fatal("result must emit the tail-settle FetchTailEffect")
	}
	if st.Phase != TurnIdle || st.Tail != "turn one" {
		t.Fatalf("turn one settling: phase=%v tail=%q", st.Phase, st.Tail)
	}

	// A queued turn 2's init lands BEFORE turn 1's GET returns — it flips Phase to
	// TurnStreaming, exactly the signal the old guard (Phase==TurnIdle) mis-read.
	st, _ = drive(st, t0, initFrame(t))
	if st.Phase != TurnStreaming {
		t.Fatalf("turn two init must resume streaming, got %v", st.Phase)
	}

	// Turn 1's stale GET finally lands, carrying turn 1's generation and turn 1's
	// settled row. Its Gen still matches TailGen (turn 2 has not appended a delta
	// yet), so it settles turn 1 into ONE row AND clears the stale tail.
	settled := Session{ID: "s1", Messages: []Message{
		{Seq: 1, Role: "assistant", Blocks: json.RawMessage(`[{"type":"paragraph","content":[{"type":"text","value":"turn one"}]}]`)},
	}}
	st, _ = drive(st, t0, TailFetchedEvent{Session: settled, Gen: fetch.Gen})
	if len(st.Messages) != 1 {
		t.Fatalf("turn one must settle into exactly one row, got %d", len(st.Messages))
	}
	if st.Tail != "" {
		t.Fatalf("the stale settle must clear turn one's tail (no double render), got %q", st.Tail)
	}

	// Turn 2's deltas now build a CLEAN tail — never concatenated onto a stale
	// turn-1 prefix.
	st, _ = drive(st, t0, deltaFrame(t, "turn two"))
	if st.Tail != "turn two" {
		t.Fatalf("turn two tail must be clean, got %q (stale-tail corruption)", st.Tail)
	}
}

// TestSettleRaceLiveTailSurvivesStaleFetch proves the OTHER wrong-fix the guard
// must avoid (charter D77): an unconditional `st.Tail = ""` would wipe turn 2's
// LIVE text when turn 1's stale GET lands after turn 2 already streamed a delta.
// The generation mismatch protects it.
func TestSettleRaceLiveTailSurvivesStaleFetch(t *testing.T) {
	st := State{SessionID: "s1"}
	st, _ = drive(st, t0, initFrame(t), deltaFrame(t, "one"))
	st, effs := drive(st, t0, resultFrame(t, "", false))
	fetch, ok := hasFetchTail(effs)
	if !ok {
		t.Fatal("result must emit the tail-settle FetchTailEffect")
	}

	// Turn 2 init + a delta re-stamp the tail to generation 2 BEFORE turn 1's GET
	// lands. (The stale "one" prefix is a bounded transient that clears at turn
	// 2's own settle; the load-bearing invariant is that turn 2's text is NOT lost.)
	st, _ = drive(st, t0, initFrame(t), deltaFrame(t, "two"))

	st, _ = drive(st, t0, TailFetchedEvent{
		Session: Session{ID: "s1", Messages: []Message{{Seq: 1, Role: "assistant", Blocks: json.RawMessage(`[]`)}}},
		Gen:     fetch.Gen,
	})
	if !strings.Contains(st.Tail, "two") {
		t.Fatalf("turn two's live text must survive a stale settle, got %q", st.Tail)
	}
}

// TestAnsweredRefetchClearsTailAtGeneration proves the answered-refetch path
// (since=0) carries the current generation and clears the tail at its boundary
// when no new turn has advanced it (charter D77 explicit decision).
func TestAnsweredRefetchClearsTailAtGeneration(t *testing.T) {
	st := State{SessionID: "s1", Gen: 2, TailGen: 2, Tail: "live", AnswerInFlight: map[string]string{"r1": "allow"}}
	st, effs := drive(st, t0, AnsweredEvent{RequestID: "r1"})
	fetch, ok := hasFetchTail(effs)
	if !ok || fetch.Gen != 2 {
		t.Fatalf("answered refetch must carry the current generation, got %+v ok=%v", fetch, ok)
	}
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1"}, Gen: fetch.Gen})
	if st.Tail != "" {
		t.Fatalf("the answered refetch must clear the tail at its boundary, got %q", st.Tail)
	}
}

// TestWedgeRefetchClearsTailAtGeneration proves the 8s interrupt-wedge refetch
// path carries the current generation and clears the degraded tail at its
// boundary (charter D77 explicit decision).
func TestWedgeRefetchClearsTailAtGeneration(t *testing.T) {
	st := State{SessionID: "s1", Phase: TurnStreaming, Gen: 1, TailGen: 1, Tail: "degraded"}
	st, _ = drive(st, t0, InterruptEvent{})
	st, effs := drive(st, t0.Add(9*time.Second), TickEvent{})
	fetch, ok := hasFetchTail(effs)
	if !ok || fetch.Gen != 1 {
		t.Fatalf("the wedge refetch must carry the current generation, got %+v ok=%v", fetch, ok)
	}
	if st.Phase != TurnIdle {
		t.Fatalf("the wedge must degrade to idle, got %v", st.Phase)
	}
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1"}, Gen: fetch.Gen})
	if st.Tail != "" {
		t.Fatalf("the wedge refetch must clear the degraded tail, got %q", st.Tail)
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

// TestWorkflowFrameUpdatesLiveWorkflowNoEffect proves wsc-bl-workflow-sse: the
// mid-turn `event: workflow` delta overwrites LiveWorkflow and asks for NO IO —
// that MISSING turn-boundary refetch is the D13 lag removed. A malformed frame is
// inert (forward-compat), leaving the last-known summary intact.
func TestWorkflowFrameUpdatesLiveWorkflowNoEffect(t *testing.T) {
	data := []byte(`{"label":"run","agents_done":1,"agents_total":3,"running":2,"terminal?":false}`)
	st, effs := drive(State{SessionID: "s1", Phase: TurnStreaming}, t0, FrameEvent{Name: "workflow", Data: data})

	if len(effs) != 0 {
		t.Fatalf("a workflow frame does no IO (the lag removed), got %d effects", len(effs))
	}
	if st.LiveWorkflow == nil {
		t.Fatal("a workflow frame must set LiveWorkflow")
	}
	if st.LiveWorkflow.Label != "run" || st.LiveWorkflow.AgentsDone != 1 || st.LiveWorkflow.AgentsTotal != 3 {
		t.Fatalf("LiveWorkflow decoded wrong: %+v", st.LiveWorkflow)
	}
	if st.LiveWorkflow.Terminal {
		t.Fatal("a running summary must not be Terminal")
	}

	// A malformed frame leaves the last-known summary intact (never clobbers).
	st2, _ := drive(st, t0, FrameEvent{Name: "workflow", Data: []byte(`not json`)})
	if st2.LiveWorkflow == nil || st2.LiveWorkflow.Label != "run" {
		t.Fatalf("a malformed workflow frame must leave the last summary intact, got %+v", st2.LiveWorkflow)
	}
}

// TestTitleFrameUpdatesTitleNoEffect proves ct-bl-recorder-titles on the client
// half: the `event: title` push renames the header mid-session and asks for NO
// IO — that MISSING session GET is the D15 poll retired. An empty or malformed
// frame is inert (the last-known title stands), and a later turn-boundary fetch
// carrying the same persisted title converges rather than fighting it.
func TestTitleFrameUpdatesTitleNoEffect(t *testing.T) {
	data := []byte(`{"session_id":"s1","title":"Fix the flaky login test"}`)
	st, effs := drive(State{SessionID: "s1", Title: "New chat", Phase: TurnStreaming}, t0, FrameEvent{Name: "title", Data: data})

	if len(effs) != 0 {
		t.Fatalf("a title frame does no IO (the D15 poll retired), got %d effects", len(effs))
	}
	if st.Title != "Fix the flaky login test" {
		t.Fatalf("Title = %q, want the pushed title", st.Title)
	}

	// Malformed and empty-title frames are inert — never a blanked header.
	for _, bad := range [][]byte{[]byte(`not json`), []byte(`{"session_id":"s1","title":"   "}`), []byte(`{}`)} {
		next, _ := drive(st, t0, FrameEvent{Name: "title", Data: bad})
		if next.Title != "Fix the flaky login test" {
			t.Fatalf("a %q title frame must leave the last title intact, got %q", bad, next.Title)
		}
	}

	// Reconnect convergence: the frame is unreplayable by design, so a client
	// that dropped it learns the SAME title from the turn-boundary session read.
	// The two paths must agree — otherwise a reconnect visibly reverts the header.
	settled, _ := drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1", Title: "Fix the flaky login test"}})
	if settled.Title != "Fix the flaky login test" {
		t.Fatalf("a settled fetch must converge on the pushed title, got %q", settled.Title)
	}
}

// pendingCardRow builds a persisted, pending approval-family row (the shape the
// Recorder writes via persist_approval_ask): request_id + pending status in the
// raw metadata map.
func pendingCardRow(seq int, role, requestID string) Message {
	return Message{
		Seq:            seq,
		Role:           role,
		SourceMarkdown: "run `rm -rf build`?",
		Metadata: map[string]any{
			"request_id":      requestID,
			"approval_status": "pending",
		},
	}
}

// TestAnswerPostsThenFullRefetch proves the Law-1 answer contract: a card answer
// emits the approval POST (an AnswerEffect carrying request_id + decision) with
// an immediate in-flight badge, and the POST completing fires a FULL refetch
// (SinceSeq 0) — the only refetch that surfaces an in-place metadata flip.
func TestAnswerPostsThenFullRefetch(t *testing.T) {
	st := State{SessionID: "s1", Messages: []Message{pendingCardRow(3, "approval", "req-1")}, LastSeq: 3}

	st, effs := drive(st, t0, AnswerEvent{RequestID: "req-1", Decision: "allow"})
	var ae AnswerEffect
	found := false
	for _, e := range effs {
		if a, ok := e.(AnswerEffect); ok {
			ae, found = a, true
		}
	}
	if !found || ae.RequestID != "req-1" || ae.Decision != "allow" {
		t.Fatalf("answer must emit an AnswerEffect{req-1, allow}, got %+v", effs)
	}
	if st.AnswerInFlight["req-1"] != "allow" {
		t.Fatalf("answer must record the in-flight decision, got %v", st.AnswerInFlight)
	}
	if st.Notice != "allowing…" {
		t.Fatalf("answer must give immediate feedback, got %q", st.Notice)
	}

	st, effs = drive(st, t0, AnsweredEvent{RequestID: "req-1"})
	f, ok := hasFetchTail(effs)
	if !ok || f.SinceSeq != 0 {
		t.Fatalf("a successful answer must trigger a FULL refetch (SinceSeq 0), got %+v", effs)
	}
}

// TestAnswerRefetchFlipsCardInPlace proves the pending → allowed flip: the
// resolved row keeps its seq (only metadata changed), so the turn-boundary merge
// must UPDATE it in place, not skip it — and the in-flight badge clears once the
// terminal status lands.
func TestAnswerRefetchFlipsCardInPlace(t *testing.T) {
	st := State{
		SessionID:      "s1",
		Messages:       []Message{pendingCardRow(3, "approval", "req-1")},
		LastSeq:        3,
		AnswerInFlight: map[string]string{"req-1": "allow"},
	}
	// The full refetch returns the SAME seq-3 row, now allowed.
	resolved := pendingCardRow(3, "approval", "req-1")
	resolved.Metadata["approval_status"] = "allowed"
	sess := Session{ID: "s1", Messages: []Message{resolved}}

	st, _ = drive(st, t0, TailFetchedEvent{Session: sess})

	if len(st.Messages) != 1 {
		t.Fatalf("an in-place flip must not duplicate the row, got %d messages", len(st.Messages))
	}
	if !st.Messages[0].Resolved() || st.Messages[0].ApprovalStatus() != "allowed" {
		t.Fatalf("the card must flip to allowed in place, got status %q", st.Messages[0].ApprovalStatus())
	}
	if _, still := st.AnswerInFlight["req-1"]; still {
		t.Fatal("the in-flight badge must clear once the card resolves")
	}
}

// TestStudioAnswerResolvesSameCard proves Law-2 one-truth: a card resolved by
// ANOTHER surface (Studio calling update_approval_status/3) shows as resolved in
// the TUI purely from a refetch — no local answer, no sync engine.
func TestStudioAnswerResolvesSameCard(t *testing.T) {
	st := State{SessionID: "s1", Messages: []Message{pendingCardRow(5, "question", "q-9")}, LastSeq: 5}
	answered := pendingCardRow(5, "question", "q-9")
	answered.Metadata["approval_status"] = "denied"
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1", Messages: []Message{answered}}})
	if st.Messages[0].ApprovalStatus() != "denied" {
		t.Fatalf("a Studio-denied card must read denied in the TUI on refetch, got %q", st.Messages[0].ApprovalStatus())
	}
}

// TestAnswerScopeIsAllowDenyOnly proves the D28 scope fence: a blank request_id
// or a decision outside allow/deny is a silent no-op (no POST, no state change).
func TestAnswerScopeIsAllowDenyOnly(t *testing.T) {
	base := State{SessionID: "s1"}
	for _, ev := range []AnswerEvent{
		{RequestID: "", Decision: "allow"},
		{RequestID: "req-1", Decision: "approve"}, // not allow/deny
		{RequestID: "req-1", Decision: ""},
	} {
		st, effs := drive(base, t0, ev)
		if len(effs) != 0 || len(st.AnswerInFlight) != 0 {
			t.Fatalf("out-of-scope answer %+v must be a silent no-op, got effects=%d inflight=%v", ev, len(effs), st.AnswerInFlight)
		}
	}
}

// TestAnswerErrorClearsInFlight proves an answer POST failure surfaces honestly
// and drops the badge so the card stays pending (retryable), never stuck
// "answering…".
func TestAnswerErrorClearsInFlight(t *testing.T) {
	st := State{SessionID: "s1", AnswerInFlight: map[string]string{"req-1": "deny"}}
	st, effs := drive(st, t0, AnsweredEvent{RequestID: "req-1", Err: errString("403 forbidden")})
	if len(effs) != 0 {
		t.Fatalf("a failed answer must not refetch, got %d effects", len(effs))
	}
	if _, still := st.AnswerInFlight["req-1"]; still {
		t.Fatal("a failed answer must clear the in-flight badge (retryable)")
	}
	if !strings.Contains(st.Notice, "answer failed") {
		t.Fatalf("a failed answer must surface an honest notice, got %q", st.Notice)
	}
}

// TestRailContinuityHydratesFromRefetch proves Law-2 rail continuity: a session
// GET carrying a rail_snapshot decodes into the task-keyed rail, sorted stably by
// task_id, with Studio's label/status/token fields.
func TestRailContinuityHydratesFromRefetch(t *testing.T) {
	snap := json.RawMessage(`{
	  "task-b": {"status":"running","row":{"description":"survey the tree"},"usage":{"total_tokens":4200}},
	  "task-a": {"status":"completed","row":{"task_type":"verify"},"usage":{"total_tokens":900}}
	}`)
	st := State{SessionID: "s1"}
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1", RailSnapshot: snap}})
	if len(st.Rail) != 2 {
		t.Fatalf("rail must decode both entries, got %d", len(st.Rail))
	}
	// Sorted by task_id: task-a before task-b.
	if st.Rail[0].TaskID != "task-a" || st.Rail[1].TaskID != "task-b" {
		t.Fatalf("rail must sort by task_id, got %q,%q", st.Rail[0].TaskID, st.Rail[1].TaskID)
	}
	if st.Rail[0].Status != "completed" || st.Rail[0].Label != "verify" || st.Rail[0].Tokens != 900 {
		t.Fatalf("rail entry must carry status/label/tokens, got %+v", st.Rail[0])
	}
	if st.Rail[1].Label != "survey the tree" {
		t.Fatalf("rail label must prefer row.description, got %q", st.Rail[1].Label)
	}
}

// errString is a tiny error for the failed-fetch test.
type errString string

func (e errString) Error() string { return string(e) }

// TestInitFrameCapturesModelAndMode proves the header-truth capture: the init
// frame's resolved model + permissionMode land in State, a frame missing them
// never blanks known values, and the CLI's post-plan "default" is NOT painted
// (the server redirects it to Autopilot; the turn-boundary refetch carries
// that truth here).
func TestInitFrameCapturesModelAndMode(t *testing.T) {
	st := State{SessionID: "s1"}
	st, _ = drive(st, t0, chatFrame(t, map[string]any{
		"type": "system", "subtype": "init",
		"model": "claude-opus-4-8[1m]", "permissionMode": "plan",
	}))
	if st.Model != "claude-opus-4-8[1m]" {
		t.Fatalf("Model = %q, want the observed wire id", st.Model)
	}
	if st.Mode != "plan" {
		t.Fatalf("Mode = %q, want plan", st.Mode)
	}

	// A bare init (no model/permissionMode keys) never blanks the facts.
	st, _ = drive(st, t0, initFrame(t))
	if st.Model != "claude-opus-4-8[1m]" || st.Mode != "plan" {
		t.Fatalf("bare init must not blank facts, got model=%q mode=%q", st.Model, st.Mode)
	}

	// The CLI's own post-plan flip reports "default" — inert for display.
	st, _ = drive(st, t0, chatFrame(t, map[string]any{
		"type": "system", "subtype": "init", "permissionMode": "default",
	}))
	if st.Mode != "plan" {
		t.Fatalf("post-plan default must not paint, got mode=%q", st.Mode)
	}
}

// TestTailFetchedRefreshesMode proves the turn-boundary mode sync: the store
// row is where the server-side plan→autopilot switch lands, and the refetch
// carries it to the badge.
func TestTailFetchedRefreshesMode(t *testing.T) {
	st := State{SessionID: "s1", Mode: "plan"}
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1", Mode: "auto"}})
	if st.Mode != "auto" {
		t.Fatalf("Mode = %q, want auto after refetch", st.Mode)
	}
	// A row with no mode never blanks the badge.
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1"}})
	if st.Mode != "auto" {
		t.Fatalf("modeless refetch must not blank, got %q", st.Mode)
	}
}

// TestPlanApproveNoticePromisesAutopilot proves the plan-approve optimism: an
// allow on a plan card says what happens next; a deny (keep planning) keeps
// the ordinary answering notice.
func TestPlanApproveNoticePromisesAutopilot(t *testing.T) {
	planCard := Message{Seq: 1, Role: "plan", Metadata: map[string]any{
		"request_id": "r1", "approval_status": "pending",
	}}
	st := State{SessionID: "s1", Messages: []Message{planCard}}
	st, _ = drive(st, t0, AnswerEvent{RequestID: "r1", Decision: "allow"})
	if !strings.Contains(st.Notice, "Autopilot") {
		t.Fatalf("plan-approve notice must promise Autopilot, got %q", st.Notice)
	}

	st2 := State{SessionID: "s1", Messages: []Message{planCard}}
	st2, _ = drive(st2, t0, AnswerEvent{RequestID: "r1", Decision: "deny"})
	if strings.Contains(st2.Notice, "Autopilot") {
		t.Fatalf("plan-keep must not promise Autopilot, got %q", st2.Notice)
	}
}

// ── the runtime lane (codex + remote/RemoteRef) ─────────────────────────────
// The wire has TWO live text lanes: event:chat (raw claude stream-json) and
// event:runtime (the normalized Runtime.Event struct codex and RemoteRef emit,
// with the text at native.params.delta). Before this lane existed a codex frame
// fell through reduceFrame inert — no tail, no phase flip, and no settle at
// all, so the persisted answer never reached the transcript.

// runtimeFrame builds an event:runtime FrameEvent from the serialized
// %Runtime.Event{} shape chat_controller.ex puts on the wire.
func runtimeFrame(t *testing.T, kind string, extra map[string]any) FrameEvent {
	t.Helper()
	obj := map[string]any{
		"version":    1,
		"provider":   "codex",
		"session_id": "s1",
		"durability": "delta",
		"kind":       kind,
	}
	for k, v := range extra {
		obj[k] = v
	}
	raw, err := json.Marshal(obj)
	if err != nil {
		t.Fatalf("marshal runtime frame: %v", err)
	}
	return FrameEvent{Name: "runtime", Data: raw}
}

// runtimeTextFrame is a codex text frame of the given kind. text_delta,
// thinking_delta and tool_delta ALL carry their text at native.params.delta
// (codex protocol.ex maps item/agentMessage/delta, item/reasoning/textDelta and
// item/commandExecution/outputDelta to the same place) — which is exactly why
// the kind match must be exact.
func runtimeTextFrame(t *testing.T, kind, delta string) FrameEvent {
	return runtimeFrame(t, kind, map[string]any{
		"item_id": "item_1",
		"native": map[string]any{
			"method": "item/agentMessage/delta",
			"params": map[string]any{"itemId": "item_1", "delta": delta},
		},
	})
}

// TestRuntimeTextDeltasStreamAndTurnCompletedSettles proves the codex lane
// streams and — the correctness half — settles: without the turn_completed arm
// the phase never returns to idle and the persisted answer never lands.
func TestRuntimeTextDeltasStreamAndTurnCompletedSettles(t *testing.T) {
	// A codex session never emits a claude system/init frame, so the phase must
	// leave TurnWaiting on the first delta.
	st, _ := drive(State{SessionID: "s1"}, t0, SendEvent{Content: "hi"})
	if st.Phase != TurnWaiting {
		t.Fatalf("send should wait, got %v", st.Phase)
	}

	st, effs := drive(st, t0,
		runtimeTextFrame(t, "text_delta", "Hel"),
		runtimeTextFrame(t, "text_delta", "lo, "),
		runtimeTextFrame(t, "text_delta", "world"),
	)
	if st.Tail != "Hello, world" {
		t.Fatalf("tail = %q, want %q", st.Tail, "Hello, world")
	}
	if st.Phase != TurnStreaming {
		t.Fatalf("a runtime delta must start streaming, got %v", st.Phase)
	}
	if len(effs) != 0 {
		t.Fatalf("a delta must trigger no IO (tail is live truth), got %d effects", len(effs))
	}
	if st.TailGen != st.Gen {
		t.Fatalf("TailGen = %d, want the issuing Gen %d (D77 stamp)", st.TailGen, st.Gen)
	}

	st, effs = drive(st, t0, runtimeFrame(t, "turn_completed", map[string]any{
		"durability": "durable", "terminal_state": "completed",
	}))
	if st.Phase != TurnIdle {
		t.Fatalf("turn_completed must end the turn, phase = %v", st.Phase)
	}
	if !st.Settling {
		t.Fatal("turn_completed must mark the state settling")
	}
	f, ok := hasFetchTail(effs)
	if !ok {
		t.Fatal("turn_completed must emit the turn-boundary FetchTailEffect")
	}
	if f.SinceSeq != st.LastSeq || f.Gen != st.Gen {
		t.Fatalf("refetch = {SinceSeq %d, Gen %d}, want {%d, %d}", f.SinceSeq, f.Gen, st.LastSeq, st.Gen)
	}
	// The tail stays painted until the fetch returns — never a blank flash.
	if st.Tail != "Hello, world" {
		t.Fatalf("tail must survive until settlement lands, got %q", st.Tail)
	}
}

// TestRuntimeKindMatchIsExact pins THE TRAP: thinking_delta (reasoning) and
// tool_delta (command output) carry their text at the SAME native.params.delta
// location as the answer, so a loose match splices them into the transcript.
func TestRuntimeKindMatchIsExact(t *testing.T) {
	st, _ := drive(State{SessionID: "s1"}, t0,
		initFrame(t),
		runtimeTextFrame(t, "text_delta", "The answer is "),
	)
	if st.Tail != "The answer is " {
		t.Fatalf("tail = %q, want the streamed answer", st.Tail)
	}

	st, effs := drive(st, t0,
		runtimeTextFrame(t, "thinking_delta", "let me reconsider the premise…"),
		runtimeTextFrame(t, "tool_delta", "$ rm -rf build\nremoved 412 files"),
		runtimeFrame(t, "item_started", map[string]any{
			"native": map[string]any{"params": map[string]any{"item": map[string]any{"id": "i1"}}},
		}),
		runtimeFrame(t, "usage", map[string]any{"usage": map[string]any{"input_tokens": 10}}),
	)
	if st.Tail != "The answer is " {
		t.Fatalf("reasoning/tool output must NEVER enter the tail, got %q", st.Tail)
	}
	if len(effs) != 0 {
		t.Fatalf("non-terminal runtime kinds must trigger no IO, got %d effects", len(effs))
	}

	// The answer keeps streaming around them — the tail is picky, not frozen.
	st, _ = drive(st, t0, runtimeTextFrame(t, "text_delta", "42."))
	if st.Tail != "The answer is 42." {
		t.Fatalf("tail = %q, want the answer to keep streaming", st.Tail)
	}
}

// TestRuntimeTurnCompletedTerminalState proves an interrupted or failed codex
// turn is still a settle, with an honest notice — the D11 rule on this lane.
func TestRuntimeTurnCompletedTerminalState(t *testing.T) {
	base := State{SessionID: "s1", Phase: TurnStreaming, Tail: "partial"}

	st, effs := drive(base, t0, runtimeFrame(t, "turn_completed", map[string]any{
		"terminal_state": "interrupted",
	}))
	if st.Phase != TurnIdle || !strings.Contains(st.Notice, "Interrupted") {
		t.Fatalf("interrupted turn: phase %v notice %q", st.Phase, st.Notice)
	}
	if _, ok := hasFetchTail(effs); !ok {
		t.Fatal("an interrupted codex turn must still settle")
	}

	st, effs = drive(base, t0, runtimeFrame(t, "turn_completed", map[string]any{
		"terminal_state": "failed",
	}))
	if !strings.Contains(st.Notice, "error") {
		t.Fatalf("failed turn notice = %q, want an honest error line", st.Notice)
	}
	if _, ok := hasFetchTail(effs); !ok {
		t.Fatal("a failed codex turn must still settle")
	}

	st, _ = drive(base, t0, runtimeFrame(t, "turn_completed", map[string]any{
		"terminal_state": "completed",
	}))
	if st.Notice != "" {
		t.Fatalf("a clean turn must carry no notice, got %q", st.Notice)
	}
}

// TestRuntimeFrameTolerance proves a malformed or payload-less runtime frame is
// inert — the decoder never throws and never moves the tail on garbage.
func TestRuntimeFrameTolerance(t *testing.T) {
	base := State{SessionID: "s1", Phase: TurnStreaming, Tail: "kept"}

	for name, ev := range map[string]FrameEvent{
		"garbage":       {Name: "runtime", Data: []byte("not json")},
		"no native":     runtimeFrame(t, "text_delta", nil),
		"delta not str": runtimeFrame(t, "text_delta", map[string]any{"native": map[string]any{"params": map[string]any{"delta": 42}}}),
		"empty delta":   runtimeTextFrame(t, "text_delta", ""),
	} {
		st, effs := drive(base, t0, ev)
		if st.Tail != "kept" {
			t.Fatalf("%s: tail = %q, want it untouched", name, st.Tail)
		}
		if len(effs) != 0 {
			t.Fatalf("%s: want no effects, got %d", name, len(effs))
		}
	}
}

// TestRuntimeAndClaudeLanesShareTheTail is the CONTROL LEG: the same drive()
// harness observes the claude lane streaming and settling, so none of the
// runtime assertions above can be vacuously green on a dead harness.
func TestRuntimeAndClaudeLanesShareTheTail(t *testing.T) {
	st, effs := drive(State{SessionID: "s1"}, t0, initFrame(t), deltaFrame(t, "Hel"), deltaFrame(t, "lo"))
	if st.Tail != "Hello" || st.Phase != TurnStreaming {
		t.Fatalf("control: claude lane must still stream, tail %q phase %v", st.Tail, st.Phase)
	}
	st, effs = drive(st, t0, resultFrame(t, "", false))
	f, ok := hasFetchTail(effs)
	if !ok || f.Gen != st.Gen {
		t.Fatalf("control: claude lane must still settle, effs %v", effs)
	}
}

// ── the tail display cap (mob-bl-go-tail-cap-parity) ────────────────────────
//
// State.Tail was UNBOUNDED on both lanes: mob-bl-runtime-lane-consumer capped
// the MOBILE tail at 262144 bytes with FREEZE semantics, but its brief scoped
// the cap to mobile only, so a runaway turn grew the Go string without limit in
// the TUI. The standing parity law says a weakness present in both reducers is
// fixed on both; these tests are the Go half of apps/mobile/src/chat/
// reducer.ts's appendTail contract.
//
// FREEZE, not close and not shed: the tail stops growing, everything already
// shown is KEPT, one honest line says the preview was truncated, deltas keep
// arriving and the turn still settles.

// capOverflowText returns text long enough that one delta breaches MaxTailBytes.
func capOverflowText() string {
	return strings.Repeat("x", MaxTailBytes+1)
}

func TestTailCap_ClaudeLaneFreezesAtTheCap(t *testing.T) {
	st, _ := drive(State{SessionID: "s1"}, t0, initFrame(t), deltaFrame(t, "kept"))
	st, _ = drive(st, t0, deltaFrame(t, capOverflowText()))

	if !st.TailCapped {
		t.Fatalf("tail must latch capped once a delta breaches %d bytes", MaxTailBytes)
	}
	// KEPT: what was already shown survives; the overflowing delta does not land.
	if !strings.HasPrefix(st.Tail, "kept") {
		t.Fatalf("frozen tail dropped what was already shown: %.40q", st.Tail)
	}
	if strings.Contains(st.Tail, "xxxx") {
		t.Fatalf("the overflowing delta must NOT be appended")
	}
	// HONEST: the marker says the preview was truncated.
	if !strings.HasSuffix(st.Tail, TailCapNotice) {
		t.Fatalf("frozen tail must carry the notice, got %.80q", st.Tail)
	}
	// BOUNDED: notice included, the tail cannot approach the runaway size.
	if len(st.Tail) > MaxTailBytes+len(TailCapNotice) {
		t.Fatalf("frozen tail is %d bytes, over the bound", len(st.Tail))
	}

	// FROZEN, not closed: later deltas are absorbed without growing the tail and
	// without a second notice.
	frozen := st.Tail
	st, _ = drive(st, t0, deltaFrame(t, "after"), deltaFrame(t, "more"))
	if st.Tail != frozen {
		t.Fatalf("a capped tail must stop growing; %.60q -> %.60q", frozen, st.Tail)
	}
	if strings.Count(st.Tail, TailCapNotice) != 1 {
		t.Fatalf("the notice must appear exactly once, got %d", strings.Count(st.Tail, TailCapNotice))
	}

	// AND THE TURN STILL SETTLES — the cap is a display bound, never a shed.
	st, effs := drive(st, t0, resultFrame(t, "", false))
	f, ok := hasFetchTail(effs)
	if !ok {
		t.Fatalf("a capped turn must still settle and refetch, effs %v", effs)
	}
	if f.Gen != st.Gen {
		t.Fatalf("settle fetch Gen %d != state Gen %d — the cap broke the D77 fence", f.Gen, st.Gen)
	}
}

func TestTailCap_RuntimeLaneFreezesAtTheCap(t *testing.T) {
	// The row's actual ask: BOTH arms. The runtime lane appended at its own site
	// and would have stayed unbounded if only the claude arm were routed through
	// the shared accumulator.
	st, _ := drive(State{SessionID: "s1"}, t0, runtimeTextFrame(t, "text_delta", "kept"))
	st, _ = drive(st, t0, runtimeTextFrame(t, "text_delta", capOverflowText()))

	if !st.TailCapped {
		t.Fatalf("runtime lane must latch capped too — it has its own append site")
	}
	if !strings.HasPrefix(st.Tail, "kept") || !strings.HasSuffix(st.Tail, TailCapNotice) {
		t.Fatalf("runtime frozen tail wrong shape: %.80q", st.Tail)
	}
	frozen := st.Tail
	st, _ = drive(st, t0, runtimeTextFrame(t, "text_delta", "after"))
	if st.Tail != frozen {
		t.Fatalf("capped runtime tail must stop growing")
	}
}

func TestTailCap_SettleReleasesTheLatch(t *testing.T) {
	// The cap bounds ONE turn's preview, never the session. A latch that survived
	// the settle would cap every later turn at zero bytes — a worse bug than the
	// one the cap fixes, and invisible to a test that only drives one turn.
	st, _ := drive(State{SessionID: "s1"}, t0, initFrame(t), deltaFrame(t, capOverflowText()))
	if !st.TailCapped {
		t.Fatalf("precondition: the tail must be capped")
	}
	_, effs := drive(st, t0, resultFrame(t, "", false))
	f, ok := hasFetchTail(effs)
	if !ok {
		t.Fatalf("precondition: expected a settle fetch")
	}
	st, _ = drive(st, t0, resultFrame(t, "", false))
	st, _ = drive(st, t0, TailFetchedEvent{Session: Session{ID: "s1"}, Gen: f.Gen})

	if st.TailCapped || st.TailBytes != 0 || st.Tail != "" {
		t.Fatalf("settle must release the latch: capped=%v bytes=%d tail=%.30q",
			st.TailCapped, st.TailBytes, st.Tail)
	}

	// The NEXT turn streams normally.
	st, _ = drive(st, t0, initFrame(t), deltaFrame(t, "fresh turn"))
	if st.Tail != "fresh turn" || st.TailCapped {
		t.Fatalf("post-settle turn must stream normally, got %.40q capped=%v", st.Tail, st.TailCapped)
	}
}

func TestTailCap_UnderTheCapIsUntouched(t *testing.T) {
	// THE NEGATIVE ARM. A cap is only a fix if an ordinary turn is byte-identical
	// to before: an accumulator that froze early, dropped text, or stamped a
	// notice on a short tail would pass every assertion above.
	st, _ := drive(State{SessionID: "s1"}, t0, initFrame(t), deltaFrame(t, "Hel"), deltaFrame(t, "lo"))
	if st.Tail != "Hello" {
		t.Fatalf("ordinary tail changed: %q", st.Tail)
	}
	if st.TailCapped {
		t.Fatalf("a 5-byte tail must not be capped")
	}
	if st.TailBytes != 5 {
		t.Fatalf("TailBytes = %d, want 5 — the counter must track streamed bytes", st.TailBytes)
	}
	if strings.Contains(st.Tail, TailCapNotice) {
		t.Fatalf("an uncapped tail must carry no notice")
	}

	// Exactly AT the cap is still allowed — the bound is a breach test, not a
	// fencepost that steals the last byte.
	st, _ = drive(State{SessionID: "s1"}, t0, initFrame(t),
		deltaFrame(t, strings.Repeat("y", MaxTailBytes)))
	if st.TailCapped {
		t.Fatalf("a tail of exactly MaxTailBytes must NOT be capped")
	}
	if st.TailBytes != MaxTailBytes {
		t.Fatalf("TailBytes = %d, want %d", st.TailBytes, MaxTailBytes)
	}
}

func TestTailCap_MultibyteIsCountedInBytesNotRunes(t *testing.T) {
	// The cap is stated in UTF-8 BYTES (charter D64), which is what the mobile
	// twin counts by hand. A rune-counting Go implementation would let a
	// multibyte stream reach ~4x the intended size — the same runaway this fix
	// bounds, just slower.
	const emoji = "😀" // 4 bytes, 1 rune
	per := MaxTailBytes/len(emoji) + 1
	st, _ := drive(State{SessionID: "s1"}, t0, initFrame(t),
		deltaFrame(t, strings.Repeat(emoji, per)))
	if !st.TailCapped {
		t.Fatalf("a multibyte stream past the BYTE cap must freeze (rune-counting would not)")
	}
}

func TestTailCap_MatchesTheMobileConstant(t *testing.T) {
	// The parity law is about the NUMBER as much as the behaviour: two reducers
	// with different ceilings show different amounts of the same turn.
	// apps/mobile/src/chat/reducer.ts: `export const MAX_TAIL_BYTES = 262_144`.
	if MaxTailBytes != 262144 {
		t.Fatalf("MaxTailBytes = %d, but the mobile twin uses 262144", MaxTailBytes)
	}
}
