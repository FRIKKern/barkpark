package chat

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// reduce.go — the PURE session state machine. Every SSE frame, user intent,
// and fetch result flows through Reduce(state, event, now) → (state, effects);
// the Bubble Tea shell (model.go) only translates tea messages into Events and
// executes Effects as commands. Purity is the test seam: the acceptance
// criteria (D11 interrupt truth, D12 queued steer, D8 tail settling) are all
// proven by driving Reduce with recorded NDJSON-shaped frames — no terminal,
// no server, no clock.

// wedgeTimeout is the client-OWNED interrupt wedge (charter D11): if the
// terminal result frame never arrives within 8s of Esc, the client
// force-degrades locally instead of wedging in "interrupting…" forever. The
// LiveView has its own timer; this one is ours.
const wedgeTimeout = 8 * time.Second

// TurnPhase is where the session's current turn stands, from the client's
// point of view. The server does not carry this state (charter D12) — it is
// derived from the frames we've seen.
type TurnPhase int

const (
	// TurnIdle — no active turn; Esc is a silent no-op (charter D11).
	TurnIdle TurnPhase = iota
	// TurnWaiting — a send was accepted but no init/delta has arrived yet.
	TurnWaiting
	// TurnStreaming — deltas are flowing (or the turn is running post-init).
	TurnStreaming
	// TurnInterrupting — Esc was pressed; waiting for the terminal result
	// frame (truth) or the 8s wedge timer (local degrade).
	TurnInterrupting
)

// LocalSend is an optimistic local echo of an outgoing user message — shown
// immediately, badged ⧗ queued while another turn is streaming (charter D12),
// and dropped once the turn-boundary refetch returns its persisted row.
type LocalSend struct {
	Content string
	Queued  bool
}

// State is the whole reducible session state. Messages are settled Postgres
// truth; Tail is the live-delta carve-out (charter D9); everything else is
// client-derived turn/queue/notice state.
type State struct {
	SessionID string
	Title     string
	Messages  []Message
	LastSeq   int

	Phase    TurnPhase
	Tail     string      // live streaming text (event:chat text deltas)
	Settling bool        // result seen, tail refetch in flight
	Local    []LocalSend // optimistic sends not yet settled into Messages
	WedgeAt  time.Time   // interrupt wedge deadline (zero unless interrupting)

	Notice string // one-line footer status (never an error screen)
	Exited bool   // the session process exited (event:exit)
}

// Event is anything Reduce consumes.
type Event interface{ isChatEvent() }

// FrameEvent is one SSE frame off the events stream (event name + raw data).
type FrameEvent struct {
	Name string
	Data []byte
}

// SendEvent is the user pressing Enter on a non-empty input.
type SendEvent struct{ Content string }

// InterruptEvent is the user pressing Esc.
type InterruptEvent struct{}

// TickEvent is the 100ms heartbeat — the wedge timer's clock.
type TickEvent struct{}

// TailFetchedEvent is the turn-boundary GET landing (?since= rows + the full
// session struct, which carries the possibly-AI-refreshed title, charter D15).
type TailFetchedEvent struct {
	Session Session
	Err     error
}

func (FrameEvent) isChatEvent()       {}
func (SendEvent) isChatEvent()        {}
func (InterruptEvent) isChatEvent()   {}
func (TickEvent) isChatEvent()        {}
func (TailFetchedEvent) isChatEvent() {}

// Effect is an IO instruction the shell executes (the reducer never does IO).
type Effect interface{ isChatEffect() }

// FetchTailEffect — GET the session with ?since=SinceSeq (turn boundary).
type FetchTailEffect struct{ SinceSeq int }

// SendEffect — POST the message body.
type SendEffect struct{ Content string }

// InterruptEffect — POST the interrupt.
type InterruptEffect struct{}

func (FetchTailEffect) isChatEffect() {}
func (SendEffect) isChatEffect()      {}
func (InterruptEffect) isChatEffect() {}

// Reduce is the single transition function. It never blocks, never does IO,
// and never panics on malformed frames — an unknown or unparseable frame is
// simply inert (forward-compatible, same tolerance as pdrender's decoder).
func Reduce(st State, ev Event, now time.Time) (State, []Effect) {
	switch ev := ev.(type) {
	case FrameEvent:
		return reduceFrame(st, ev)
	case SendEvent:
		return reduceSend(st, ev)
	case InterruptEvent:
		return reduceInterrupt(st, now)
	case TickEvent:
		return reduceTick(st, now)
	case TailFetchedEvent:
		return reduceTailFetched(st, ev)
	}
	return st, nil
}

// reduceSend appends the optimistic echo and always POSTs immediately — the
// server does not distinguish queued (charter D12); the ⧗ badge is pure local
// turn state. A send during an active turn stays badged until the NEXT
// system/init frame proves a fresh turn started.
func reduceSend(st State, ev SendEvent) (State, []Effect) {
	content := strings.TrimSpace(ev.Content)
	if content == "" {
		return st, nil
	}
	midTurn := st.Phase != TurnIdle
	st.Local = append(st.Local, LocalSend{Content: content, Queued: midTurn})
	if !midTurn {
		st.Phase = TurnWaiting
	}
	st.Notice = ""
	return st, []Effect{SendEffect{Content: content}}
}

// reduceInterrupt implements charter D11: Esc with no active turn is a SILENT
// no-op (the server would ack {still_queued:[]}; we don't even ask). With a
// turn active it flips to "interrupting" immediately — the control ack is
// semantically empty, so there is nothing to wait for — and arms the client's
// own 8s wedge timer. The truth arrives as the result frame.
func reduceInterrupt(st State, now time.Time) (State, []Effect) {
	if st.Phase == TurnIdle {
		return st, nil
	}
	if st.Phase == TurnInterrupting {
		return st, nil // already asked; the wedge timer owns escalation
	}
	st.Phase = TurnInterrupting
	st.WedgeAt = now.Add(wedgeTimeout)
	st.Notice = "interrupting…"
	return st, []Effect{InterruptEffect{}}
}

// reduceTick fires the wedge: silence past the deadline force-degrades
// LOCALLY (charter D11) — the turn is declared over for this client, honestly
// labelled, and the session stays usable. If the server-side turn is in fact
// still running, the next frame or refetch re-syncs us.
func reduceTick(st State, now time.Time) (State, []Effect) {
	if st.Phase == TurnInterrupting && !st.WedgeAt.IsZero() && !now.Before(st.WedgeAt) {
		st.Phase = TurnIdle
		st.WedgeAt = time.Time{}
		st.Settling = true
		st.Notice = "interrupt unacknowledged after 8s — degraded locally; refetching"
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq}}
	}
	return st, nil
}

// reduceFrame dispatches one SSE frame.
func reduceFrame(st State, ev FrameEvent) (State, []Effect) {
	switch ev.Name {
	case "message":
		// Replay phase: a persisted row (reconnect catch-up). Same merge rule
		// as the tail refetch — seq must advance.
		var m Message
		if err := json.Unmarshal(ev.Data, &m); err == nil && m.Seq > st.LastSeq {
			st.Messages = append(st.Messages, m)
			st.LastSeq = m.Seq
			st.Local = dropSettledLocal(st.Local, []Message{m})
		}
		return st, nil
	case "chat":
		return reduceClaudeFrame(st, ev.Data)
	case "permission":
		// The ask row is persisted by the Recorder — refetch the tail so the
		// read-only card renders from replay truth (the interactive answer
		// flow is backlog ct-bl-interactive-cards).
		st.Settling = true
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq}}
	case "exit":
		var body struct {
			Status     int    `json:"status"`
			StderrTail string `json:"stderr_tail"`
		}
		_ = json.Unmarshal(ev.Data, &body)
		st.Exited = true
		st.Phase = TurnIdle
		st.WedgeAt = time.Time{}
		st.Notice = fmt.Sprintf("session process exited (status %d) — send to relaunch", body.Status)
		return st, nil
	}
	return st, nil
}

// reduceClaudeFrame handles one raw claude stream-json frame (event: chat).
// Shapes mirror what ChatLive consumes (chat_live.ex) — init, text deltas,
// and the terminal result. Everything else (thinking pulses, tool chatter,
// task_* system frames) is inert for the MVP transcript: those rows arrive as
// persisted truth at the turn boundary.
func reduceClaudeFrame(st State, data []byte) (State, []Effect) {
	var frame struct {
		Type    string `json:"type"`
		Subtype string `json:"subtype"`
		Event   struct {
			Type  string `json:"type"`
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
		} `json:"event"`
		TerminalReason string `json:"terminal_reason"`
		IsError        bool   `json:"is_error"`
	}
	if err := json.Unmarshal(data, &frame); err != nil {
		return st, nil
	}

	switch {
	case frame.Type == "system" && frame.Subtype == "init":
		// A fresh turn began. Any queued sends' badges clear — the queue is
		// now draining, oldest first, exactly like ChatLive's
		// clear_queued_badges (charter D12).
		for i := range st.Local {
			st.Local[i].Queued = false
		}
		if st.Phase == TurnIdle || st.Phase == TurnWaiting {
			st.Phase = TurnStreaming
		}
		return st, nil

	case frame.Type == "stream_event" &&
		frame.Event.Type == "content_block_delta" &&
		frame.Event.Delta.Type == "text_delta":
		st.Tail += frame.Event.Delta.Text
		if st.Phase == TurnIdle || st.Phase == TurnWaiting {
			st.Phase = TurnStreaming
		}
		// While interrupting, deltas may keep landing until the CLI actually
		// stops — keep accumulating (the truth is the result frame).
		return st, nil

	case frame.Type == "result":
		// The turn boundary — the ONLY interrupt truth (charter D11): an
		// interrupted turn is a NORMAL outcome, never an error, and the
		// session stays live.
		interrupted := st.Phase == TurnInterrupting || frame.TerminalReason == "aborted_streaming"
		switch {
		case interrupted:
			st.Notice = "⊘ Interrupted — session live"
		case frame.IsError:
			st.Notice = fmt.Sprintf("the turn ended with an error (%s)", frame.Subtype)
		default:
			st.Notice = ""
		}
		st.Phase = TurnIdle
		st.WedgeAt = time.Time{}
		st.Settling = true
		// Settle: refetch the tail so the plain-text stream becomes pdrender
		// blocks AND the AI title lands (charter D8/D15). The tail stays
		// painted until the fetch returns — never a blank flash.
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq}}
	}
	return st, nil
}

// reduceTailFetched merges the turn-boundary GET: new rows append (seq-asc,
// monotonic), the live tail clears (it settled into blocks), matching local
// echoes drop, and the title refreshes (charter D15). A failed fetch keeps
// the tail painted and says so — never silently drops streamed text.
func reduceTailFetched(st State, ev TailFetchedEvent) (State, []Effect) {
	st.Settling = false
	if ev.Err != nil {
		st.Notice = "refetch failed — transcript may lag (" + ev.Err.Error() + ")"
		return st, nil
	}
	fresh := make([]Message, 0, len(ev.Session.Messages))
	for _, m := range ev.Session.Messages {
		if m.Seq > st.LastSeq {
			fresh = append(fresh, m)
			st.LastSeq = m.Seq
		}
	}
	st.Messages = append(st.Messages, fresh...)
	st.Local = dropSettledLocal(st.Local, fresh)
	if t := strings.TrimSpace(ev.Session.Title); t != "" {
		st.Title = t
	}
	if st.Phase == TurnIdle {
		st.Tail = ""
	}
	return st, nil
}

// dropSettledLocal removes optimistic echoes whose persisted user row just
// arrived (first content match wins — duplicate sends settle one per row).
// Unmatched echoes stay: a queued send's row may not persist until its own
// turn starts.
func dropSettledLocal(local []LocalSend, settled []Message) []LocalSend {
	if len(local) == 0 || len(settled) == 0 {
		return local
	}
	remaining := append([]LocalSend(nil), local...)
	for _, m := range settled {
		if m.Role != "user" {
			continue
		}
		for i, l := range remaining {
			if strings.TrimSpace(m.SourceMarkdown) == l.Content {
				remaining = append(remaining[:i], remaining[i+1:]...)
				break
			}
		}
	}
	return remaining
}
