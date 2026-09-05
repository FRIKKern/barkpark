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

	// Model is the OBSERVED wire model id ("claude-opus-4-8[1m]") off the
	// system/init frame — fact, distinct from the shell's intent alias
	// (Model.modelChoice, D14 continuity). Empty until the first turn streams;
	// the header prefers it over the intent.
	Model string

	// Mode is the session's permission mode for DISPLAY (the Plan ⇄ Autopilot
	// badge): seeded from the session GET, refreshed at every turn boundary
	// (how the server-side plan→autopilot switch reaches this surface) and by
	// the init frame's permissionMode. Continuity write-back stays on the
	// shell's m.mode — this field never PATCHes.
	Mode string

	Phase    TurnPhase
	Tail     string      // live streaming text (event:chat text deltas)
	Settling bool        // result seen, tail refetch in flight
	Local    []LocalSend // optimistic sends not yet settled into Messages
	WedgeAt  time.Time   // interrupt wedge deadline (zero unless interrupting)

	// Gen is the turn generation, bumped once per turn-start frame on EITHER
	// lane (claude system/init, codex runtime turn_started). It is the
	// settle-race token (charter D77): a turn's tail-settle GET carries the Gen
	// that issued it, so a STALE turn-1 fetch landing after a queued turn-2's init
	// already flipped Phase (reduce.go's init handler) can be told apart from a
	// fetch that still owns the live tail. The old clear guard keyed off
	// Phase==TurnIdle, which the queued-send init defeats — turn-1 then rendered
	// twice and turn-2 deltas concatenated onto the stale tail.
	Gen int
	// TailGen is the generation the current Tail text belongs to — stamped every
	// time a delta appends. reduceTailFetched clears the tail ONLY when the
	// landing GET's Gen equals TailGen (same generation), so a turn-1 settle can
	// neither blank nor corrupt turn-2's live stream. Init deliberately does NOT
	// touch Tail/TailGen (that would blank-flash the still-painted prior tail —
	// the no-blank-flash invariant); the tail carries its generation with it.
	TailGen int
	// TailBytes is the UTF-8 byte length of the STREAMED text in Tail (the
	// freeze notice is deliberately NOT counted), carried so the cap check is
	// O(delta) rather than O(tail) — re-measuring a quarter-megabyte string on
	// every delta is the second half of the same runaway-turn problem.
	TailBytes int
	// TailCapped is the freeze latch: once the tail breaches MaxTailBytes it
	// stops growing. Released with the tail at the settle boundary, because the
	// cap bounds ONE turn's preview, never the session.
	TailCapped bool

	// ── the LIVE DOCUMENT (charter D81) ─────────────────────────────────────
	//
	// Every field here is INERT until a server puts `event: stable` frames on the
	// wire: Segments stays empty, the cursors stay 0, and the tail is exactly the
	// plain string it is today. That is the improvement-only floor (D76), and it
	// is structural rather than a flag. The consumer lives in stable.go.

	// Segments are the committed rich segments of the turn now streaming,
	// append-only, keyed on the SERVER's turn and byte cursor.
	Segments []StableSegment
	// StableTurn is the server-authored turn whose segment stream is being
	// consumed (0 = none yet). This — never the client's Gen — fences the cursor:
	// Gen advances on system/init, not on the reconnect replay that causes a gap.
	StableTurn int
	// StableBase is the byte index in Tail where StableTurn's byte 0 sits. It is
	// almost always 0; it is non-zero exactly in the D77 residual window where a
	// finished turn's text is still painted (its settle GET has not landed) while
	// the next turn already streams. Stamped at the turn-start frame both lanes
	// emit (claude system/init, codex turn_started), released with the tail.
	StableBase int
	// CommittedBytes is the exclusive end, in the SERVER's byte space, of
	// everything committed for StableTurn — and the only `from` the next frame
	// may carry.
	CommittedBytes int
	// Skeleton classifies the block still forming past the cursor (D67), off the
	// last accepted frame. nil means the remainder is ordinary prose.
	Skeleton *StableSkeleton
	// StableStopped latches when this turn stops consuming `stable` frames: a
	// hole, the client segment bound, an unmappable window, or a terminal frame.
	// The committed segments STAY — the remainder simply goes back to plain.
	StableStopped bool
	// StableEnd is the terminal reason seen for StableTurn ("" = still streaming).
	StableEnd string

	// Rail is the decoded agents-rail (charter D47) hydrated from the session's
	// rail_snapshot — task-keyed mission control that survives a surface switch
	// (Law-2). Re-decoded on every full session load / turn-boundary refetch.
	Rail []RailEntry

	// Workflow is the open session's workflow-bearing rail entry (wave
	// session-card charter D13): the highest-seq entry carrying a workflow node
	// list, decoded from the SAME rail_snapshot as Rail at the SAME turn-boundary
	// sites — no new SSE frame, no polling (mid-turn lag is the accepted UX
	// ceiling). nil for plain chats — the below-composer panel then costs zero.
	Workflow *Workflow

	// LiveWorkflow is the COMPACT workflow summary pushed MID-TURN over the SSE
	// `event: workflow` frame (wsc-bl-workflow-sse) — the same
	// apiclient.ChatWorkflowSummary the list wire carries, NOT the raw *Workflow
	// rail fold (which has per-agent Nodes this lacks). The collapsed strip prefers
	// it so its counters/elapsed advance WITHIN a turn without a rail refetch —
	// that missing refetch IS the D13 lag removed. nil until the first workflow
	// frame; a Terminal summary drops the strip. The Enter-expanded detail still
	// reads Workflow (it needs the Nodes) — turn-boundary fresh, the accepted
	// ceiling (backlogged wsc-bl-workflow-sse-detail).
	LiveWorkflow *SessionWorkflow

	// AnswerInFlight maps a card's request_id → the decision ("allow"/"deny")
	// POSTed but not yet confirmed by a refetch — the immediate-feedback layer:
	// the card reads "answering: allow…" until the server-resolved row lands and
	// flips it (or the POST errors and it clears).
	AnswerInFlight map[string]string

	// TaskTransitions is the session's live ledger-transition log
	// (tlv-bl-chat-live-transition-stream): one row per `event: task` frame the
	// Recorder re-broadcast for a task THIS session touched. Append-only in
	// ARRIVAL order, so a duplicate or replayed frame can never reorder what is
	// already painted; seenTaskEvents is the dedupe set keyed on the frame's own
	// event_id (the mutation_events row id), which is why a second delivery of
	// the same transition renders exactly once. These rows are LIVE-ONLY: the
	// server never persists them, so a tail refetch neither duplicates nor
	// erases them, and the settled task_prime snapshot contract is untouched.
	TaskTransitions []TaskTransition
	seenTaskEvents  map[string]bool

	Notice string // one-line footer status (never an error screen)
	Exited bool   // the session process exited (event:exit)
}

// TaskTransition is one decoded `event: task` frame — the compact summary
// Recorder.transition_summary/1 builds from the SAME
// Barkpark.StudioChat.TaskTransition projection Studio's transcript renders, so
// the terminal prints the server's `label` verbatim rather than re-deriving a
// second wording that could drift.
type TaskTransition struct {
	EventID  string `json:"event_id"`
	TaskID   string `json:"task_id"`
	Title    string `json:"title"`
	Status   string `json:"status"`
	Mutation string `json:"mutation"`
	Verb     string `json:"verb"`
	Label    string `json:"label"`
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
	// Gen is the generation of the FetchTailEffect that issued this GET, threaded
	// through the shell (FetchTailEffect.Gen → tailFetchedMsg.gen → here). The
	// settle guard clears the tail only when Gen == State.TailGen (charter D77) —
	// zero for the pre-generation call sites (answered/wedge/legacy tests), which
	// matches a zero TailGen, so their single-turn clear is unchanged.
	Gen int
}

// AnswerEvent is the user answering the focused card via a keystroke (charter
// D27/D28): Decision is "allow" or "deny" ONLY (allow = approve / plan-approve /
// answer-allow; deny = reject / plan-keep). No caller-supplied updatedInput —
// rich AskUserQuestion input is deferred (ct-bl-question-updatedinput, D28).
type AnswerEvent struct {
	RequestID string
	Decision  string
}

// QuestionAnswerEvent is the user answering an AskUserQuestion card with a
// SPECIFIC option rather than a blanket allow (ct-bl-question-updatedinput,
// closing the D28 deferral). Answers is the constrained wire map — question
// string → the chosen label — built from the card's OWN server-held ask, so the
// TUI can only ever name options the model offered. The server re-validates it
// against that same stored ask and rebuilds `updatedInput` itself; D22 is intact
// because nothing here is free-form.
type QuestionAnswerEvent struct {
	RequestID string
	Answers   map[string]any
}

// AnsweredEvent is the answer POST completing. On success it triggers a FULL
// refetch so the server-resolved card flips pending → allowed/denied in place (a
// resolved row keeps its seq — only its metadata changes — so a since=0 refetch,
// not a since=LastSeq tail, is what surfaces the flip).
type AnsweredEvent struct {
	RequestID string
	Err       error
}

func (FrameEvent) isChatEvent()          {}
func (SendEvent) isChatEvent()           {}
func (InterruptEvent) isChatEvent()      {}
func (TickEvent) isChatEvent()           {}
func (TailFetchedEvent) isChatEvent()    {}
func (AnswerEvent) isChatEvent()         {}
func (QuestionAnswerEvent) isChatEvent() {}
func (AnsweredEvent) isChatEvent()       {}

// Effect is an IO instruction the shell executes (the reducer never does IO).
type Effect interface{ isChatEffect() }

// FetchTailEffect — GET the session with ?since=SinceSeq (turn boundary). A
// SinceSeq of 0 is a FULL refetch (every row, so an in-place metadata flip like
// a resolved approval is picked up); a positive SinceSeq returns only newer rows.
type FetchTailEffect struct {
	SinceSeq int
	// Gen stamps the turn generation live when this GET was issued so the landing
	// TailFetchedEvent can prove it belongs to the tail it would clear (charter
	// D77 settle-race token). Every settle-boundary emit site (result, answered,
	// wedge-tick, permission) carries State.Gen; the D42 workflow-expand
	// HYDRATION refetch (keys.go) carries -1 — not a boundary, so its landing
	// must never clear a live tail.
	Gen int
}

// SendEffect — POST the message body.
type SendEffect struct{ Content string }

// InterruptEffect — POST the interrupt.
type InterruptEffect struct{}

// AnswerEffect — POST {request_id, decision} to /v1/chat/sessions/:id/approval
// (charter wire contract): allow/deny only, no updatedInput. Answered by an
// AnsweredEvent carrying the same request_id.
type AnswerEffect struct {
	RequestID string
	Decision  string
}

// AnswerQuestionEffect — the rich AskUserQuestion answer POST. Separate from
// AnswerEffect because it hits a DIFFERENT route with a different body: the
// allow/deny hot path keeps no map-shaped surface at all.
type AnswerQuestionEffect struct {
	RequestID string
	Answers   map[string]any
}

func (FetchTailEffect) isChatEffect() {}
func (SendEffect) isChatEffect()      {}
func (InterruptEffect) isChatEffect() {}
func (AnswerEffect) isChatEffect()    {}

// AnswerQuestionEffect — POST {request_id, answers} to
// /v1/chat/sessions/:id/answer. Answered by the SAME AnsweredEvent an
// AnswerEffect is, so the pending → resolved refetch has exactly one landing
// path (no second settle grammar to drift).
func (AnswerQuestionEffect) isChatEffect() {}

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
	case AnswerEvent:
		return reduceAnswer(st, ev)
	case QuestionAnswerEvent:
		return reduceQuestionAnswer(st, ev)
	case AnsweredEvent:
		return reduceAnswered(st, ev)
	}
	return st, nil
}

// reduceAnswer records the in-flight decision (immediate feedback) and emits the
// POST. It is a no-op for a blank request_id (nothing to answer) or a decision
// other than allow/deny (the scope fence, charter D28). The card's terminal flip
// is server truth, arriving on the AnsweredEvent's full refetch — never guessed
// locally, so a Studio answer and a TUI answer converge on the SAME row.
func reduceAnswer(st State, ev AnswerEvent) (State, []Effect) {
	if ev.RequestID == "" || (ev.Decision != "allow" && ev.Decision != "deny") {
		return st, nil
	}
	if st.AnswerInFlight == nil {
		st.AnswerInFlight = map[string]string{}
	}
	st.AnswerInFlight[ev.RequestID] = ev.Decision
	st.Notice = answeringNotice(ev.Decision)
	// An approved plan card is the autopilot promise: say so now — the server
	// engages Autopilot (steer + persist) and the badge lands on truth at the
	// turn boundary / next init frame.
	if ev.Decision == "allow" {
		for _, msg := range st.Messages {
			if msg.RequestID() == ev.RequestID && msg.Role == "plan" {
				st.Notice = "Plan approved — engaging ▶ Autopilot…"
				break
			}
		}
	}
	return st, []Effect{AnswerEffect{RequestID: ev.RequestID, Decision: ev.Decision}}
}

// reduceQuestionAnswer records the in-flight answer and emits the rich POST. It
// is the option-picking twin of reduceAnswer: a blank request_id or an empty
// answers map is inert (nothing to say), and the card's terminal flip is still
// server truth arriving on the AnsweredEvent refetch — never guessed locally, so
// a Studio answer and a TUI answer converge on the SAME Postgres row.
//
// The in-flight badge reads "allow" because that is what the decision IS on the
// wire: an AskUserQuestion answer is an allow carrying the picked labels.
func reduceQuestionAnswer(st State, ev QuestionAnswerEvent) (State, []Effect) {
	if ev.RequestID == "" || len(ev.Answers) == 0 {
		return st, nil
	}
	if st.AnswerInFlight == nil {
		st.AnswerInFlight = map[string]string{}
	}
	st.AnswerInFlight[ev.RequestID] = "allow"
	st.Notice = answeringNotice("allow")
	return st, []Effect{AnswerQuestionEffect{RequestID: ev.RequestID, Answers: ev.Answers}}
}

// reduceAnswered handles the POST completing. A transport error clears the
// in-flight badge and surfaces honestly (the card stays pending — the operator
// can retry). On success it fires a FULL refetch (SinceSeq 0) so the resolved
// row's metadata flip lands in place; the in-flight badge lingers until that
// refetch confirms the terminal status (reduceTailFetched drops it).
func reduceAnswered(st State, ev AnsweredEvent) (State, []Effect) {
	if ev.Err != nil {
		delete(st.AnswerInFlight, ev.RequestID)
		st.Notice = "answer failed — " + ev.Err.Error()
		return st, nil
	}
	st.Settling = true
	// The answer refetch carries the CURRENT generation: if no new turn has begun
	// by the time it lands, its Gen still matches TailGen and the tail clears at
	// this boundary; if a fresh turn's init/delta advanced TailGen meanwhile, the
	// mismatch protects that live text (charter D77).
	return st, []Effect{FetchTailEffect{SinceSeq: 0, Gen: st.Gen}}
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
		// The wedge refetch clears the degraded tail at its boundary: it carries
		// the current generation, which matches TailGen unless a fresh turn already
		// advanced it (charter D77).
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq, Gen: st.Gen}}
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
	case "runtime":
		return reduceRuntimeFrame(st, ev.Data)
	case "stable":
		// The live document (charter D81): one committed segment of the streaming
		// turn, PortableDoc blocks and a byte window. PRESENTATION ONLY — no
		// Effect, no LastSeq, no tail clear; the frame is id-less so the resume
		// cursor never moves for it either. stable.go owns the rule.
		return reduceStable(st, ev.Data), nil
	case "stable_end":
		// The turn's terminal segment frame: settled / capped / degraded.
		return reduceStableEnd(st, ev.Data), nil
	case "workflow":
		// Live workflow delta (wsc-bl-workflow-sse): the COMPACT summary pushed
		// mid-turn so the collapsed strip refreshes without a turn-boundary
		// refetch. Overwrite LiveWorkflow; NO Effect — that MISSING refetch is the
		// D13 lag removed. A malformed frame is inert (forward-compat, same
		// tolerance the exit/message paths show), leaving the last-known summary.
		var wf SessionWorkflow
		if err := json.Unmarshal(ev.Data, &wf); err == nil {
			st.LiveWorkflow = &wf
		}
		return st, nil
	case "title":
		// The AI title landed (ct-bl-recorder-titles): the Recorder publishes it
		// on the session topic, so the header renames itself mid-session instead
		// of waiting for a turn-boundary session GET to notice (the D15 poll).
		// Carries ONLY {session_id, title} (D23); the sid is ignored exactly as
		// the workflow case ignores it — this stream IS one session, so the
		// subscription is the fence, not a field.
		//
		// NO Effect: that missing refetch is the whole point. An empty or
		// malformed frame is inert, leaving the last-known title standing — the
		// turn-boundary GET below is still the settling truth, so a dropped frame
		// costs freshness, never correctness.
		var body struct {
			SessionID string `json:"session_id"`
			Title     string `json:"title"`
		}
		if err := json.Unmarshal(ev.Data, &body); err == nil {
			if t := strings.TrimSpace(body.Title); t != "" {
				st.Title = t
			}
		}
		return st, nil
	case "task":
		// A live ledger transition (tlv-bl-chat-live-transition-stream): a task
		// THIS session touched changed lifecycle state mid-conversation. NO
		// Effect — the point of the frame is that the transcript learns about the
		// move WITHOUT a re-fetch. A malformed frame is inert (forward-compatible,
		// the same tolerance the workflow/exit paths show), and a frame carrying
		// no event_id is dropped rather than rendered twice, because an
		// unkeyable row cannot be deduped.
		var t TaskTransition
		if err := json.Unmarshal(ev.Data, &t); err != nil || t.EventID == "" {
			return st, nil
		}
		if st.seenTaskEvents[t.EventID] {
			return st, nil
		}
		if st.seenTaskEvents == nil {
			st.seenTaskEvents = map[string]bool{}
		}
		st.seenTaskEvents[t.EventID] = true

		st.TaskTransitions = append(st.TaskTransitions, t)
		return st, nil
	case "permission":
		// The ask row is persisted by the Recorder — refetch the tail so the
		// answerable card renders from replay truth (request_id + pending status
		// in its metadata); the operator then answers it with the card keys.
		st.Settling = true
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq, Gen: st.Gen}}
	case "exit":
		// The public exit frame is EXACTLY {status, reason} over the fixed enum
		// (charter D23): the transport DROPS the stderr tail, so it is never a
		// field here. status is null for a non-integer exit (crash/reap), so it is
		// a pointer; reason carries the honest cause the notice surfaces.
		var body struct {
			Status *int   `json:"status"`
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(ev.Data, &body)
		st.Exited = true
		st.Phase = TurnIdle
		st.WedgeAt = time.Time{}
		st.Notice = exitNotice(body.Status, body.Reason)
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
		Model          string `json:"model"`
		PermissionMode string `json:"permissionMode"`
	}
	if err := json.Unmarshal(data, &frame); err != nil {
		return st, nil
	}

	switch {
	case frame.Type == "system" && frame.Subtype == "init":
		// A fresh turn began — bump the generation FIRST so a still-in-flight
		// prior-turn settle GET (which captured the OLD Gen) can be told apart when
		// it lands (charter D77). Tail/TailGen are deliberately untouched: the prior
		// tail stays painted until its own settle lands (no blank flash), carrying
		// its own generation with it.
		st.Gen++
		// The new turn's byte 0 is wherever the tail stands right now (charter
		// D81): normally 0, and the leftover length of a still-unsettled prior
		// turn in the D77 residual window. Stamped BEFORE any of this turn's
		// deltas append, which is the only moment the offset is knowable.
		st.StableBase = len(st.Tail)
		// Any queued sends' badges clear — the queue is
		// now draining, oldest first, exactly like ChatLive's
		// clear_queued_badges (charter D12).
		for i := range st.Local {
			st.Local[i].Queued = false
		}
		// The init frame carries the RESOLVED model and permission mode the CLI
		// actually runs — capture both as observed fact (a frame missing either
		// never blanks a known value). "default" is the CLI's own post-plan flip:
		// the server redirects it to Autopilot ("auto") and this surface learns
		// the truth at the turn boundary, so don't paint the transient here.
		if frame.Model != "" {
			st.Model = frame.Model
		}
		if frame.PermissionMode != "" && frame.PermissionMode != "default" {
			st.Mode = frame.PermissionMode
		}
		if st.Phase == TurnIdle || st.Phase == TurnWaiting {
			st.Phase = TurnStreaming
		}
		return st, nil

	case frame.Type == "stream_event" &&
		frame.Event.Type == "content_block_delta" &&
		frame.Event.Delta.Type == "text_delta":
		st = appendTail(st, frame.Event.Delta.Text)
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
		// painted until the fetch returns — never a blank flash. The GET carries
		// THIS turn's generation so its landing clears only this turn's tail.
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq, Gen: st.Gen}}
	}
	return st, nil
}

// reduceRuntimeFrame handles one normalized Runtime.Event frame (event:
// runtime) — the codex and remote/RemoteRef text lane, the sibling of
// event: chat. The wire is the serialized %Runtime.Event{} struct
// (chat_controller.ex sse_runtime_frame): `kind` is the normalized verb and
// `native` retains the lossless provider envelope, so the text lives at
// native.params.delta.
//
// The kind is matched EXACTLY, and that is load-bearing: codex's protocol maps
// item/reasoning/textDelta → thinking_delta and item/commandExecution/
// outputDelta → tool_delta to the SAME native.params.delta location, so a loose
// match would splice reasoning and command output into the answer. Everything
// that is not text_delta or turn_completed is inert here — those rows arrive as
// persisted truth at the turn boundary, exactly as on the claude lane.
func reduceRuntimeFrame(st State, data []byte) (State, []Effect) {
	var frame struct {
		Kind          string          `json:"kind"`
		TerminalState string          `json:"terminal_state"`
		Native        json.RawMessage `json:"native"`
	}
	if err := json.Unmarshal(data, &frame); err != nil {
		return st, nil
	}

	switch frame.Kind {
	case "turn_started":
		// The codex lane's turn-start signal — the sibling of the claude lane's
		// system/init. It does exactly two things and emits NOTHING (no effect, no
		// IO): it advances the generation, and it stamps the live-document base.
		//
		// The generation advance is what makes the D77 settle fence LIVE on this
		// lane. Before it, Gen moved only inside the claude system/init arm, so a
		// codex turn kept the generation it started in: a stale turn-1 settle GET
		// carried a Gen that still equalled TailGen when it landed, and
		// reduceTailFetched cleared turn 2's live tail. Bumped FIRST and here for
		// the same reason init bumps it there — Tail/TailGen are deliberately
		// untouched, so the prior turn's text stays painted (no blank flash) and
		// carries its own generation with it until its own settle lands.
		st.Gen++
		// The base is the ONLY moment this turn's byte 0 is knowable (charter
		// D81). Phase, tail and notice stay exactly as inert as they were before
		// this case existed; the stable cursor (StableTurn/CommittedBytes) is
		// keyed on the SERVER turn and is deliberately NOT reset here.
		st.StableBase = len(st.Tail)
		return st, nil

	case "text_delta":
		// native is decoded lazily and tolerantly: a provider envelope whose
		// params.delta is not a string leaves the tail untouched rather than
		// killing the frame's whole decode.
		var native struct {
			Params struct {
				Delta string `json:"delta"`
			} `json:"params"`
		}
		if err := json.Unmarshal(frame.Native, &native); err != nil || native.Params.Delta == "" {
			return st, nil
		}
		// Stamped and CAPPED through the same accumulator the claude lane uses
		// (charter D77), so the settle guard and the display cap see the same
		// shape on both lanes — and the generation the stamp carries is now this
		// lane's own, advanced by the turn_started arm above.
		st = appendTail(st, native.Params.Delta)
		if st.Phase == TurnIdle || st.Phase == TurnWaiting {
			st.Phase = TurnStreaming
		}
		return st, nil

	case "turn_completed":
		// The codex turn boundary — the sibling of the claude result frame, and
		// the ONLY settle a codex turn gets. Without it the phase never returns to
		// idle and the Recorder's persisted answer never reaches the transcript.
		interrupted := st.Phase == TurnInterrupting || frame.TerminalState == "interrupted"
		switch {
		case interrupted:
			st.Notice = "⊘ Interrupted — session live"
		case frame.TerminalState == "failed":
			st.Notice = "the turn ended with an error"
		default:
			st.Notice = ""
		}
		st.Phase = TurnIdle
		st.WedgeAt = time.Time{}
		st.Settling = true
		return st, []Effect{FetchTailEffect{SinceSeq: st.LastSeq, Gen: st.Gen}}
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
	// Merge by seq: a row we already hold is UPDATED in place (an approval card
	// flips its approval_status metadata WITHOUT changing its seq, so a full
	// refetch must replace it, not skip it); a genuinely newer row appends and
	// advances the cursor. A since=LastSeq tail refetch returns only new rows, so
	// this loop degrades to the append-only behaviour there.
	bySeq := make(map[int]int, len(st.Messages))
	for i, m := range st.Messages {
		bySeq[m.Seq] = i
	}
	fresh := make([]Message, 0, len(ev.Session.Messages))
	for _, m := range ev.Session.Messages {
		if idx, ok := bySeq[m.Seq]; ok {
			st.Messages[idx] = m
		} else if m.Seq > st.LastSeq {
			fresh = append(fresh, m)
			st.LastSeq = m.Seq
		}
	}
	st.Messages = append(st.Messages, fresh...)
	st.Local = dropSettledLocal(st.Local, fresh)
	// Law-2 rail continuity: re-hydrate the agents rail from the refetched
	// snapshot so a resumed session (and every turn boundary) shows the same
	// mission control Studio shows. The workflow panel re-decodes at the SAME
	// site — turn-boundary freshness (charter D13), one snapshot, one moment.
	if len(ev.Session.RailSnapshot) > 0 {
		st.Rail = decodeRail(ev.Session.RailSnapshot)
		st.Workflow = decodeWorkflow(ev.Session.RailSnapshot)
	}
	// Any in-flight answer whose card is no longer pending has been resolved
	// server-side (by this TUI's POST or by a Studio answer to the SAME row) —
	// drop its badge so the card reads its terminal state.
	for rid := range st.AnswerInFlight {
		if !cardPending(st.Messages, rid) {
			delete(st.AnswerInFlight, rid)
		}
	}
	if t := strings.TrimSpace(ev.Session.Title); t != "" {
		st.Title = t
	}
	// Turn-boundary mode sync: the store row is where the server-side
	// plan→autopilot switch lands, so the badge follows it here — no new SSE
	// frame, the same freshness ceiling as the rail (charter D13).
	if m := strings.TrimSpace(ev.Session.Mode); m != "" {
		st.Mode = m
	}
	// Settle-race guard (charter D77): clear the streamed tail ONLY when this GET
	// was issued in the generation the tail still belongs to. A stale prior-turn
	// settle (its Gen < TailGen because a queued send's init already bumped the
	// generation and a delta re-stamped the tail) leaves the LIVE tail intact —
	// the old Phase==TurnIdle guard cleared on the wrong signal and let turn-1
	// render twice while turn-2 deltas concatenated onto the stale tail.
	if ev.Gen == st.TailGen {
		// Clearing the tail also RELEASES the freeze latch — the cap bounds one
		// turn's preview, never the session. Leaving it latched would silently
		// cap every later turn in the session at zero bytes, which is a worse
		// bug than the one the cap fixes.
		st.Tail = ""
		st.TailBytes = 0
		st.TailCapped = false
		// The live document dies WITH the tail it annotates (charter D81): the
		// committed segments describe bytes of Tail, and the persisted row that
		// replaces them was appended above in this same reducer step. Dropping
		// them here — never earlier, never later — is what makes the promotion
		// atomic: no frame paints the segments and the settled row together, and
		// none paints neither.
		st = clearStable(st)
	}
	return st, nil
}

// MaxTailBytes is the live tail's display cap in UTF-8 BYTES (charter D64's
// number, the same constant apps/mobile/src/chat/reducer.ts exports as
// MAX_TAIL_BYTES). The server does NOT enforce it for us: the LiveView caps its
// own accumulator (chat_live.ex advance_streaming) but chat_controller forwards
// raw frames, so every client bounds its own tail or a runaway turn grows an
// unbounded string.
const MaxTailBytes = 262144

// TailCapNotice is what a frozen tail says — the same honest promise the web's
// capped bubble makes (chat_live.ex `data-streaming-capped`) and the mobile
// reducer's TAIL_CAP_NOTICE. It is appended INTO the tail because the tail is
// the only text the transcript renders.
const TailCapNotice = "\n\n— live preview truncated — the full response arrives on completion"

// appendTail appends streamed text to the live tail — the ONE accumulator both
// lanes share, so the D77 generation stamp and the display cap can never
// diverge between providers.
//
// FREEZE semantics at MaxTailBytes (parity with apps/mobile appendTail and the
// web's capped bubble): the tail stops growing, everything already shown is
// KEPT, and one honest line says the preview was truncated. The stream is
// neither closed nor shed — deltas keep arriving, the turn still settles, and
// the settle refetch brings the full untruncated answer from Postgres.
//
// Go strings are already UTF-8, so len() IS the byte length the cap is stated
// in; the mobile twin has to count code units by hand because JS strings are
// UTF-16. Same number, same unit, different arithmetic.
func appendTail(st State, text string) State {
	// The generation stamp happens on EVERY delta, capped or not (charter D77):
	// a frozen tail still belongs to this turn, and a settle GET from an older
	// generation must still be told apart from one that owns it. Stamping only
	// on the growing path would un-fence the tail the moment it froze.
	st.TailGen = st.Gen
	if st.TailCapped {
		return st
	}
	bytes := st.TailBytes + len(text)
	if bytes > MaxTailBytes {
		st.Tail += TailCapNotice
		st.TailCapped = true
		return st
	}
	st.Tail += text
	st.TailBytes = bytes
	return st
}

// cardPending reports whether the row carrying request_id is still awaiting a
// decision. An absent row (or one already resolved) reads not-pending, so its
// in-flight badge clears.
func cardPending(msgs []Message, requestID string) bool {
	for _, m := range msgs {
		if m.RequestID() == requestID {
			return m.ApprovalStatus() == "pending"
		}
	}
	return false
}

// answeringNotice is the immediate-feedback footer line for an answer POST in
// flight — honest present-tense, replaced by the card's terminal badge once the
// refetch confirms it.
func answeringNotice(decision string) string {
	if decision == "deny" {
		return "denying…"
	}
	return "allowing…"
}

// exitNotice renders the public exit frame (charter D23 {status, reason}) as one
// honest footer line. reason is the fixed enum (clean/failed_start/crashed/
// idle_reaped/unknown); status is shown only when the subprocess reported a real
// integer code (null otherwise). A session is always relaunchable by sending.
func exitNotice(status *int, reason string) string {
	if reason == "" {
		reason = "unknown"
	}
	if status != nil {
		return fmt.Sprintf("session process exited (%s, status %d) — send to relaunch", reason, *status)
	}
	return fmt.Sprintf("session process exited (%s) — send to relaunch", reason)
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
