package chat

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
)

// herd.go — the PURE herd reducer (charter D52h): the multiplexer home screen's
// state machine, a sibling of reduce.go that is deliberately NOT part of the
// single-session turn machine (State stays single-session; the herd is fleet
// truth). Every rule here is a named, frozen-clock-testable function over
// HerdState — the shell only parses wire frames (applyFleetFrame) and calls
// these; no IO, no real clock.
//
// The wire this reduces is the ONE life-of-process fleet stream (charter D45h/
// D54h — GET /v1/chat/events via apiclient.FleetEvents) plus the cold sessions
// list (GET /v1/chat/sessions, which carries agent_state/agent_state_at since
// the D50h widen). Named wire residuals, each its own rule + test:
//
//   - a fleet SNAPSHOT overlays state but NEVER truncates the list-sourced
//     roster (the snapshot is 50-capped; the cold list is the full roster);
//   - FLIPS are idempotent map upserts (a double-emitted flip is harmless);
//   - a NULL live-flip title keeps the held title (flips carry title:null by
//     design — the snapshot/list title is the one worth keeping);
//   - HEARTBEATS bump LastFrameAt only — never AgentState, never LastFlipAt;
//   - a TITLE frame (D69h) renames the row IN PLACE and touches NOTHING else —
//     not the state, not either clock (the async titler is a server-side write,
//     never a sign of agent life);
//   - STALL is computed FRESH from LastFrameAt at sort/render time (D53h): a
//     fresh frame un-stalls for free, and there is no stored bool to go stale.

// herdStallAfter is the herd stall threshold (charter D53h): a WORKING session
// with no frame (flip or heartbeat) for this long wears the stall badge. It is
// 150s = 2.5× the server's 60s heartbeat — the same bound the server's
// AgentStateSweeper uses — and is deliberately a DISTINCT const from
// workflowStallAfter (90s, the D41 in-strip AGENT stall: a different concept).
const herdStallAfter = 150 * time.Second

// HerdRow is one session's herd truth: its four-state agent_state
// (working|blocked|idle|unknown), the held title, and the two clocks the sort
// and the stall badge read — LastFlipAt (the last STATE CHANGE, the tie-break)
// and LastFrameAt (the last sign of life: flips AND heartbeats).
type HerdRow struct {
	SessionID   string
	AgentState  string
	Title       string
	LastFlipAt  time.Time
	LastFrameAt time.Time
}

// HerdState is the pure herd truth: rows keyed by session id, plus the cursor —
// a SESSION ID, never an index (charter D52h), resolved against the sorted
// order at render time so it follows its session across resorts by
// construction.
type HerdState struct {
	Rows   map[string]HerdRow
	Cursor string
}

// clone copies the row map so every rule is pure (the fleet is small; a copy
// per frame is cheap and keeps the frozen-clock tests honest).
func (h HerdState) clone() HerdState {
	rows := make(map[string]HerdRow, len(h.Rows)+1)
	for k, v := range h.Rows {
		rows[k] = v
	}
	return HerdState{Rows: rows, Cursor: h.Cursor}
}

// ── wire frame parsing ───────────────────────────────────────────────────────

// fleetSnapshotFrame / fleetStateFrame / fleetHeartbeatFrame / fleetTitleFrame
// mirror the four D45h/D69h frame shapes verbatim. Title is *string on the flip
// frame because the wire says `title:null` on every live flip BY DESIGN — nil
// must mean "keep what you hold", never "blank the title". The title frame's
// Title is a plain string: that frame exists ONLY to carry one, so a null there
// is simply a blank the trimTitle law drops.
type fleetSnapshotFrame struct {
	Sessions []fleetStateFrame `json:"sessions"`
}

type fleetStateFrame struct {
	SessionID  string  `json:"session_id"`
	AgentState string  `json:"agent_state"`
	TS         string  `json:"ts"`
	Title      *string `json:"title"`
}

type fleetHeartbeatFrame struct {
	SessionID string `json:"session_id"`
	TS        string `json:"ts"`
}

// fleetTitleFrame is the D69h title update: id-less, seq-less, unreplayable,
// and carrying ONLY {session_id,title} — no state, no ts, no owner stamp
// (chat_controller.fleet_title_frame/2 is pinned to exactly this shape).
type fleetTitleFrame struct {
	SessionID string `json:"session_id"`
	Title     string `json:"title"`
}

// applyFleetFrame parses one wire frame (event name + data bytes) and reduces
// it. ok=false means the frame was not herd-shaped (unknown event, malformed
// JSON) — the caller ignores it, the same forward-compat tolerance the rest of
// the chat decoder shows.
func applyFleetFrame(h HerdState, event string, data []byte) (HerdState, bool) {
	switch event {
	case "snapshot":
		var f fleetSnapshotFrame
		if err := json.Unmarshal(data, &f); err != nil {
			return h, false
		}
		return herdSnapshot(h, f.Sessions), true
	case "state":
		var f fleetStateFrame
		if err := json.Unmarshal(data, &f); err != nil || f.SessionID == "" {
			return h, false
		}
		return herdFlip(h, f), true
	case "heartbeat":
		var f fleetHeartbeatFrame
		if err := json.Unmarshal(data, &f); err != nil || f.SessionID == "" {
			return h, false
		}
		return herdHeartbeat(h, f.SessionID, parseHerdTime(f.TS)), true
	case "title":
		var f fleetTitleFrame
		if err := json.Unmarshal(data, &f); err != nil || f.SessionID == "" {
			return h, false
		}
		return herdTitle(h, f.SessionID, f.Title), true
	}
	return h, false
}

// parseHerdTime parses the wire's ISO8601 ts; zero time on failure (honest
// blank — the row still sorts, it just carries no age).
func parseHerdTime(iso string) time.Time {
	if iso == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return time.Time{}
	}
	return t
}

// ── the named reducer rules ──────────────────────────────────────────────────

// herdSeed cold-mounts the herd from the sessions list (the D50h widen:
// agent_state/agent_state_at now ride sidebar_json). The list is the ROSTER —
// every summary gets a row — but live truth wins: a row that already saw a
// LIVE flip newer than the list's agent_state_at keeps its live state (the
// list is a point-in-time read; the stream is fresher). A summary with no
// agent_state (an old server) mounts honestly as "unknown". Titles are
// list-sourced (flips carry title:null), so a non-empty list title always
// refreshes the held one.
func herdSeed(h HerdState, sessions []SessionSummary) HerdState {
	out := h.clone()
	for _, s := range sessions {
		state := s.AgentState
		if state == "" {
			state = "unknown"
		}
		at := parseHerdTime(s.AgentStateAt)
		row, ok := out.Rows[s.ID]
		if !ok {
			row = HerdRow{SessionID: s.ID, AgentState: state, LastFlipAt: at, LastFrameAt: at}
		} else if !row.LastFlipAt.After(at) {
			// the list read is at least as fresh as the last live flip → adopt it
			row.AgentState = state
			row.LastFlipAt = at
			if at.After(row.LastFrameAt) {
				row.LastFrameAt = at
			}
		}
		if t := trimTitle(s.Title); t != "" {
			row.Title = t
		}
		out.Rows[s.ID] = row
	}
	return out
}

// herdSnapshot overlays a fleet snapshot: every listed session is upserted
// with the server's current state, but rows NOT in the snapshot are KEPT — the
// snapshot is 50-capped and must never truncate the list-sourced roster
// (charter D52h). A non-empty snapshot title refreshes the held one.
func herdSnapshot(h HerdState, sessions []fleetStateFrame) HerdState {
	out := h.clone()
	for _, s := range sessions {
		if s.SessionID == "" {
			continue
		}
		out = herdFlip(out, s)
	}
	return out
}

// herdFlip upserts one state flip. Idempotent by construction: re-applying the
// same flip (a double emit, a replayed frame) lands the identical row. A nil
// (wire-null) or empty title keeps the held title — the flip frame's
// title:null is a design fact, not an erase instruction. LastFlipAt and
// LastFrameAt both advance to the flip's ts (a flip IS a frame).
func herdFlip(h HerdState, f fleetStateFrame) HerdState {
	out := h.clone()
	ts := parseHerdTime(f.TS)
	row, ok := out.Rows[f.SessionID]
	if !ok {
		row = HerdRow{SessionID: f.SessionID}
	}
	row.AgentState = f.AgentState
	row.LastFlipAt = ts
	if ts.After(row.LastFrameAt) {
		row.LastFrameAt = ts
	}
	if f.Title != nil {
		if t := trimTitle(*f.Title); t != "" {
			row.Title = t
		}
	}
	out.Rows[f.SessionID] = row
	return out
}

// herdHeartbeat bumps LastFrameAt ONLY — never AgentState, never LastFlipAt
// (charter D41h: the tick proves a long tool call is not a dead BEAM; it is
// not a state change). A heartbeat for a session the herd does not hold is
// ignored — the roster is list-sourced, and a bare {session_id,ts} carries
// nothing worth mounting a row from.
func herdHeartbeat(h HerdState, sessionID string, ts time.Time) HerdState {
	row, ok := h.Rows[sessionID]
	if !ok {
		return h
	}
	out := h.clone()
	if ts.After(row.LastFrameAt) {
		row.LastFrameAt = ts
	}
	out.Rows[sessionID] = row
	return out
}

// herdTitle folds the D69h `title` frame: it renames the row IN PLACE and
// touches NOTHING else — never AgentState, never LastFlipAt, and deliberately
// NOT LastFrameAt either. The async AI titler is a SERVER-side write that lands
// once per session, typically while the runtime sits idle; treating it as a
// sign of life would let a rename silently un-stall a wedged session — the one
// lie the D53h badge exists to prevent. A blank title keeps the held one (the
// shared trimTitle law), and a title for a session the herd does not hold is
// IGNORED: the roster is list-sourced and {session_id,title} carries no
// agent_state to mount an honest row from (the same rule herdHeartbeat obeys).
func herdTitle(h HerdState, sessionID, title string) HerdState {
	row, ok := h.Rows[sessionID]
	if !ok {
		return h
	}
	t := trimTitle(title)
	if t == "" {
		return h
	}
	out := h.clone()
	row.Title = t
	out.Rows[sessionID] = row
	return out
}

// herdStalled is the D53h stall badge, computed FRESH from LastFrameAt at
// sort/render time — never a stored bool, so any fresh frame (flip or
// heartbeat) un-stalls for free. Only a WORKING session can stall (blocked is
// waiting on a human, idle/unknown carry no promise of frames), and a row that
// never saw a timestamp cannot honestly be called stalled.
func herdStalled(row HerdRow, now time.Time) bool {
	return row.AgentState == "working" &&
		!row.LastFrameAt.IsZero() &&
		now.Sub(row.LastFrameAt) > herdStallAfter
}

// herdRank is the attention sort's rank: blocked(0) > stalled(1) > working(2)
// > idle(3) > unknown(4) > anything-else(5). Blocked/stalled/working/idle is
// the charter's law verbatim; unknown ranks BELOW idle — it carries no live
// signal and nothing actionable (a reaped or mid-turn-dead session; the
// server's sweeper owns its recovery), so it must not crowd the attention
// zone. Unknown wire values sort last (forward-compat, never a crash).
func herdRank(row HerdRow, now time.Time) int {
	switch {
	case row.AgentState == "blocked":
		return 0
	case herdStalled(row, now):
		return 1
	case row.AgentState == "working":
		return 2
	case row.AgentState == "idle":
		return 3
	case row.AgentState == "unknown":
		return 4
	}
	return 5
}

// herdRowFor resolves the herd row for a session id — a zero row (state ""),
// never a panic, when the herd holds nothing for it (a roster the stream and
// seed have not reached yet).
func (h HerdState) herdRowFor(id string) HerdRow {
	if row, ok := h.Rows[id]; ok {
		return row
	}
	return HerdRow{SessionID: id}
}

// herdOrder sorts the given roster ids by attention (charter D52h): rank asc,
// then LastFlipAt DESC (the freshest flip reads first within a band), then
// session id asc — fully deterministic, so equal-state rows never jitter under
// the cursor. The roster is the caller's (list-sourced) id set; the herd only
// supplies each id's row.
func herdOrder(h HerdState, roster []string, now time.Time) []string {
	out := append([]string(nil), roster...)
	sort.SliceStable(out, func(i, j int) bool {
		ri, rj := h.herdRowFor(out[i]), h.herdRowFor(out[j])
		ki, kj := herdRank(ri, now), herdRank(rj, now)
		if ki != kj {
			return ki < kj
		}
		if !ri.LastFlipAt.Equal(rj.LastFlipAt) {
			return ri.LastFlipAt.After(rj.LastFlipAt)
		}
		return out[i] < out[j]
	})
	return out
}

// trimTitle is the shared title normalisation (blank-ish titles never
// overwrite a held one).
func trimTitle(s string) string { return strings.TrimSpace(s) }
