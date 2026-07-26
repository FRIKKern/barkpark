// Package chat is the native `bp chat` terminal client — the second surface of
// One Chat, Two Surfaces (charter .claude/workflows/bp-chat-tui-charter.md,
// vision /papers/barkpark-chat-tui). It drives the SAME engine Studio chat
// drives, over the fixed /v1/chat wire contract: sessions picker on launch,
// transcript rendered block-for-block by pdrender, live streaming tail, Esc
// interrupt, queued steer badge, draft continuity.
//
// # State doctrine — the chat carve-out (charter D9)
//
// The taskboard's live.go doctrine is "events never carry truth": every SSE
// frame is only a refetch trigger. Chat carves out ONE deliberate exception:
// live `event: chat` text deltas ARE the live-tail truth, because they are
// never persisted anywhere — there is no row to refetch while a turn streams.
// Settled truth stays Postgres: at every turn boundary (the `result` frame)
// the client refetches the message tail (GET ?since=<seq>) and the plain-text
// tail SETTLES into server-computed PortableDoc blocks. Nothing rendered from
// a delta outlives the turn that produced it.
//
// # Figure numbering — per-message reset (charter D10)
//
// Each assistant reply is rendered as its OWN document (one pdrender.RenderDoc
// call per message), so "Figure N." numbering resets per message. That is the
// deliberate chat convention — a reply is a self-contained document, not a
// page in one long paper — documented here so it reads as a decision, not an
// accident inherited from RenderDoc's per-call counter seeding.
//
// # Result-boundary settlement (charter D8/D15)
//
// The terminal `result` frame is the ONLY turn boundary. Nothing about a turn
// settles before it: not the tail (it stays plain text), not the title, not the
// persisted rows. At the result frame the reducer emits ONE FetchTailEffect
// (GET ?since=maxSeq); when it lands, the plain-text tail is replaced by
// server-computed PortableDoc blocks, the (possibly AI-refreshed) title lands,
// and the seq cursor advances. The tail stays painted until the fetch returns —
// never a blank flash. An interrupt (charter D11) is a NORMAL result outcome,
// never an error: `terminal_reason=aborted_streaming` settles to
// "Interrupted — session live" and the session stays usable.
//
// # Golden parity boundary — reply-body projection only
//
// The golden-transcript parity harness (ct-w1-golden-harness) covers exactly the
// ASSISTANT REPLY BODY projection: renderAssistantDoc is the seam it diffs
// against the Studio reader. User echoes, the live tail, and the bespoke
// approval/question/plan cards are DELIBERATELY out of golden scope — the tail
// is transient truth that settles into a golden-covered assistant body at the
// result boundary. One projection, one parity contract.
//
// # The archived shelf — a two-way door (charter D28)
//
// Archiving is DISMISSAL: orthogonal to status (liveness) and to agent_state
// (attention), and the server emits no fleet frame for the flip in EITHER
// direction. `a` on the herd home shelves the cursor row; `s` opens the SHELF
// screen (its own roster, its own cursor — GET /v1/chat/sessions?archived=true),
// where `enter`/`u` restores a row (POST …/unarchive) and `esc` returns to the
// herd. Both flips are optimistic because nothing else will ever tell the list
// the row moved; a refused flip surfaces honestly and RE-READS the list it came
// from rather than guessing the row back in. `bp chat ls --archived` and `bp
// chat unarchive <id>` are the same two verbs for scripts.
//
// # Interactive cards + the agents rail (charter D27/D28, Law-1/Law-2)
//
// approval/question/plan cards are answerable in-canvas: the focused pending
// card takes Ctrl+A (allow / approve / plan-approve) or Ctrl+R (deny / keep
// planning); Tab cycles the focus ring. An answer POSTs {request_id, decision}
// to /v1/chat/sessions/:id/approval (allow/deny ONLY — rich AskUserQuestion
// updatedInput is deferred, ct-bl-question-updatedinput) and then FULL-refetches
// the tail. The resolved row keeps its seq — only its approval_status metadata
// flips pending → allowed/denied — so the turn-boundary merge UPDATES rows in
// place, not append-only. Because the flip is a Postgres row (server-side
// update_approval_status/3), a Studio answer and a TUI answer converge on the
// SAME card with no sync engine (Law-2, one truth). The session's rail_snapshot
// decodes into a task-keyed agents rail band below the transcript, so a
// mid-session surface switch keeps the same mission control Studio shows.
package chat
