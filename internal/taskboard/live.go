package taskboard

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
)

// live.go owns the live-refresh loop: the SSE dirty-bit → debounced full
// refetch, the periodic backstop poll, and the honest connection state.
//
// The one iron rule (charter decision #4): events NEVER carry truth. An SSE
// frame only says "something moved"; the refetch says WHAT is true. We refetch
// the whole snapshot and rebuild the board — never apply an event payload
// incrementally — so there is no drift and no ghost rows.

// --- message types -----------------------------------------------------------

// changeMsg is pushed into the program by the apiclient change seams. Both a
// real SSE mutation frame and the NDJSON poll fallback mark the board dirty and
// (re)arm the debounce; live distinguishes them. live==true (OnChange, a real
// SSE frame) is the only thing that refreshes lastLiveEvent and so the only
// thing that can hold the ● live connection state — a poll-fallback change
// (live==false, OnChangeFallback) refetches but reads honestly as ◐ polling.
type changeMsg struct{ live bool }

// pulseMsg is pushed by the apiclient OnLivePulse seam: the SSE stream received
// a frame (the welcome event on subscribe, a `: keepalive` comment — sent every
// 30s of quiet — or a mutation), so the stream is verifiably connected right
// now. It carries no "data changed" meaning: it only refreshes lastLiveEvent
// (and upgrades a ◐ polling dot to ● live), never marks dirty and never
// refetches. This is what keeps the dot honest over a QUIET dataset — without
// it, ● live could only ever be held by mutation frames, and a healthy idle
// stream would read as polling.
type pulseMsg struct{}

// debounceMsg fires debounceDelay after the LAST changeMsg. It carries the
// debounce generation it was scheduled under; a stale generation (a newer
// change arrived meanwhile) is ignored, so a burst of N events collapses to a
// single refetch that runs once the stream goes quiet.
type debounceMsg struct{ gen int }

// backstopMsg is the periodic ticker that refetches unconditionally. It exists
// to survive a silently-dropped SSE stream: even if no OnChange ever fires, the
// board still refreshes every backstopEvery, and the connection state honestly
// degrades to ConnPolling when no live event has been seen recently.
type backstopMsg struct{}

// actionResultMsg carries the outcome of a claim/close command back to the
// update loop (the act verbs run off-loop so the network never blocks a
// keystroke). handleActionResult renders res on the strip and, on success,
// fires the reconciling refetch.
// docID is the row the verb ran against, carried so handleActionResult can arm
// the observed_rev close recovery on the EXACT doc the server refused (the
// result itself names no row, and the cursor may have moved while the request
// was in flight).
type actionResultMsg struct {
	docID string
	res   ActionResult
}

// snapshotMsg is the result of a refetch. The connection state is NOT derived
// from what drove the fetch — applySnapshot reads the single truth of whether
// a live SSE frame was seen recently (liveIsFresh). keepStrip marks the
// reconciling refetch a successful claim/close fires itself: that snapshot IS
// the action landing, so it must not wipe the action's own confirmation off
// the strip (any other snapshot clears a stale strip + disarms the close guard).
type snapshotMsg struct {
	snap Snapshot
	// details is the TaskDetail reading index decoded in the SAME round-trip as
	// the board rows (charter D28: the shell keeps the DetailIndex — the fetch
	// seam widened to FetchSnapshotFull). applySnapshot stores it on the Model so
	// every FrameTask and the depth-0 wide preview read their detail straight out
	// of the in-hand index, with zero extra fetches.
	details   DetailIndex
	err       error
	keepStrip bool
}

// --- commands ----------------------------------------------------------------

// scheduleDebounce arms a one-shot timer tagged with the current generation.
func (m Model) scheduleDebounce(gen int) tea.Cmd {
	d := m.debounceDelay
	return m.tick(d, func(time.Time) tea.Msg { return debounceMsg{gen: gen} })
}

// scheduleBackstop arms the next periodic backstop tick. It reschedules itself
// from the backstopMsg handler, so the ticker runs for the life of the program.
func (m Model) scheduleBackstop() tea.Cmd {
	d := m.backstopEvery
	return m.tick(d, func(time.Time) tea.Msg { return backstopMsg{} })
}

// refetchCmd runs the (injectable) snapshot fetch off the update loop and
// delivers the result as a snapshotMsg. The fetch is captured by value so the
// command is self-contained and safe to run concurrently with further updates.
// keepStrip is set only by the post-action reconcile (see snapshotMsg).
func (m Model) refetchCmd(keepStrip bool) tea.Cmd {
	fetch := m.fetch
	client := m.client
	return func() tea.Msg {
		snap, details, err := fetch(client)
		return snapshotMsg{snap: snap, details: details, err: err, keepStrip: keepStrip}
	}
}

// --- reducers ----------------------------------------------------------------

// handleChange marks the board dirty and re-arms the debounce for BOTH a live
// SSE frame and a poll-fallback change (either way the board must refetch). It
// records the moment of the last live event ONLY when the change is live, so a
// client leaning entirely on the poll fallback never spoofs the ● live state.
func (m Model) handleChange(msg changeMsg) (Model, tea.Cmd) {
	m.dirty = true
	if msg.live {
		m.lastLiveEvent = m.now()
	}
	m.debounceGen++
	return m, m.scheduleDebounce(m.debounceGen)
}

// handlePulse records proof-of-life from the SSE stream and re-derives the
// connection state under the same single truth applySnapshot uses (liveIsFresh
// — trivially fresh right after the bump). ConnOffline is NOT upgraded: a
// failed refetch means the DATA path is broken, and only a successful fetch
// (applySnapshot) may clear that — a live stream with unreachable reads must
// keep the honest ✗. No dirty bit, no debounce, no refetch: a pulse says the
// pipe is open, not that anything changed.
//
// The one state a pulse DOES lift is the timeout class: a snapshot fetch that
// blew its budget degrades to ◐ + "server timeout" (applySnapshot never marks
// a slow fetch ConnOffline — slow is not gone), and the stream proving itself
// alive is exactly the evidence that upgrades that dot back to ●. The "server
// timeout" label itself is NOT cleared here — the DATA on screen is still
// stale, and only a snapshot that actually lands (applySnapshot's success
// path) may say the fetch path recovered. Genuine unreachability (dial-tcp →
// ConnOffline) stays behind the guard above, untouched.
func (m Model) handlePulse() (Model, tea.Cmd) {
	m.lastLiveEvent = m.now()
	if m.ui.Conn != ConnOffline {
		m.ui.Conn = ConnLive
	}
	return m, nil
}

// handleDebounce fires the coalesced reaction to an SSE burst — but only for the
// newest generation and only if something is actually dirty.
//
// WHAT IT COALESCES INTO CHANGED (task-e2f5ecca0be9a6d1). It used to be the full
// snapshot refetch: three heavy requests, on every burst, forever. But an SSE
// frame is a DATASET-wide signal — it fires for papers, chat, sessions, every
// document type — so on a busy dataset it was refetching the task corpus for
// writes that touched no task at all. It now nudges the keyset poll instead: the
// cheap PK-indexed feed answers "did any TASK move?" and only a yes runs the
// pair. The debounce is kept exactly as it was, because coalescing a burst of
// frames into one question is still the right shape — only the question got
// cheap. With the feed unavailable (eventsOff) this falls back to the old
// refetch, so an older server behaves as before.
func (m Model) handleDebounce(msg debounceMsg) (Model, tea.Cmd) {
	if msg.gen != m.debounceGen || !m.dirty {
		return m, nil
	}
	m.dirty = false
	if m.eventsOff {
		return m, m.refetchCmd(false)
	}
	return m, (&m).nudgePoll()
}

// handleBackstop refetches unconditionally and re-arms the ticker. It is the
// SAFETY NET now, not the refresh path (defaultBackstopEvery moved 30s → 5m):
// the keyset poll drives refreshes, and this covers the cursor catch-up window
// and a feed that is not there at all. The re-list rides the same no-overlap
// guard the poll's does — a backstop that fires while a slow snapshot fetch is
// still out re-arms the ticker and drops the duplicate read rather than
// stacking a second 9 MB list on the server it is waiting for.
func (m Model) handleBackstop() (Model, tea.Cmd) {
	next := m.scheduleBackstop()
	relist := m.tickRefetchCmd()
	if relist == nil {
		return m, next
	}
	m.fetchInFlight = true
	m.lastRelistAt = m.now()
	m.relistOwed = false
	return m, tea.Batch(relist, next)
}

// applySnapshot swaps in a freshly-rebuilt board and updates the connection
// state honestly. The state follows ONE truth — whether a real live SSE frame
// was seen within liveStale (liveIsFresh) — regardless of what drove THIS
// refetch (a live event, a debounce, or the periodic backstop):
//
//   - refetch failed      → ConnOffline, KEEP the last good board — EXCEPT the
//     timeout class (isSnapshotTimeout), which degrades to ◐/● under the same
//     liveIsFresh truth: a fetch that blew its budget proves slow, not gone,
//     and must never paint the ✗ offline lie.
//   - success, live fresh → ConnLive   (a real SSE frame within liveStale).
//   - success, live stale → ConnPolling (we are leaning on the NDJSON poll).
//
// This is what makes the ●/◐ dot honest: a poll-fallback change refetches and
// swaps the board but never bumps lastLiveEvent (see handleChange), so a client
// stuck reconnecting — refreshing purely off the poll — reads ◐ polling, never
// ● live. A backstop refetch does not itself imply polling either: if a live
// frame is still recent, the stream is healthy and the state stays ● live.
//
// Two in-flight refetches (a debounce racing the backstop) can complete out of
// order; a success frame older than what is already on screen is dropped so
// slow responses never roll the board backward. The selection follows the TASK
// (its doc id), not the raw cursor index — a live board reorders itself on
// every refresh, and the highlight silently hopping to a different task on
// each SSE frame would make the pane unusable while it breathes.
func (m Model) applySnapshot(msg snapshotMsg) (Model, tea.Cmd) {
	// Release the tick-driven re-list gate FIRST, on every arm including the
	// error and out-of-order returns below: a fetch that failed is a fetch that
	// is no longer in flight, and leaving the bit set would wedge the board on
	// the backstop forever after one bad read.
	m.fetchInFlight = false
	if msg.err != nil {
		// Surface WHY — getJSON builds its errors precisely so the status chrome
		// can name the failure truthfully (snapshotErrorLabel maps it to a short
		// honest label). Without this line the board goes silently dark on a fetch
		// error, which reads as "no tasks" instead of "sync failed" (the 8 MiB cap
		// incident). The next landed snapshot clears it on the success path below.
		m.ui.ConnProblem = snapshotErrorLabel(msg.err)
		if isSnapshotTimeout(msg.err) {
			// Timeout class: the fetch blew its budget, which means the server is
			// SLOW, not gone — ✗ offline would be a lie (the 5s-inherited-timeout
			// flap: offline → recovered → offline while the server answered every
			// time). Degrade under the same single truth as the success path: a
			// fresh SSE frame holds ● (the pipe is proven alive, so the dot never
			// flaps through ◐ on one slow fetch), a stale stream reads ◐. The
			// "server timeout" label above says why the DATA is stale either way.
			if m.liveIsFresh() {
				m.ui.Conn = ConnLive
			} else {
				m.ui.Conn = ConnPolling
			}
			return m, nil
		}
		m.ui.Conn = ConnOffline
		return m, nil
	}
	m.ui.ConnProblem = ""
	// Out-of-order guard: compare against the newest snapshot APPLIED this
	// session (lastAppliedFetch), NOT ui.LastSync — a cache-primed start seeds
	// LastSync from the on-disk FetchedAt, and if the wall clock jumped
	// backwards between sessions that stamp would out-rank every live fetch and
	// freeze the board on stale cached rows (each 30s backstop is stamped from
	// the same skewed clock, so it would never self-heal). Live truth always
	// beats a file; only intra-session fetches order each other.
	if !m.lastAppliedFetch.IsZero() && msg.snap.FetchedAt.Before(m.lastAppliedFetch) {
		return m, nil
	}
	var selected string
	if r, ok := m.currentRow(); ok {
		selected = r.docID
	}
	// Per-row forward-only merge (SECOND layer, under the FetchedAt guard above).
	// FetchedAt orders FETCHES by the client wall clock, not DATA freshness, so a
	// backstop/reconcile fetch that read slightly-stale server rows can pass the
	// guard yet carry a row OLDER (in server UpdatedAt/Epoch) than what's on
	// screen. Reconcile per doc id so a displayed row can only move FORWARD: keep
	// the shown row when the incoming one is stale for it, take the incoming row
	// otherwise, add new rows, drop rows the snapshot no longer lists — UNLESS the
	// window is truncated (below), in which case a non-terminal row the snapshot
	// no longer lists might just be outside the clamp, not closed. The merged set
	// feeds build, repo correlation, the flash diff, AND prevTasks/cache — so a
	// stale-then-fresh sequence neither reverts a row nor spuriously flashes it.
	truncated := snapshotTruncated(msg.snap)
	merged, agedOut := mergeForward(m.prevTasks, msg.snap.Tasks, truncated)
	mergedSnap := msg.snap
	mergedSnap.Tasks = merged
	// Keep the reading substrate in hand (charter D28): the merged task set feeds
	// ChildrenOf/DrivenTasks for the detail + paper frames, and the DetailIndex is
	// the zero-fetch source every FrameTask + the wide depth-0 preview read from.
	m.tasks = merged
	if msg.details != nil {
		m.details = msg.details
	}
	// Recompute repo correlation against the fresh task set BEFORE building, so
	// the "↳ git" badges and epic-rank boost track the tasks as they move. Pure
	// and cheap; a no-op (empty Mentioned) outside a git repo.
	m.repo = CorrelateRepo(m.subjects, m.branch, m.repoName, mergedSnap.Tasks)
	m.board = m.build(mergedSnap, m.repo, m.now())

	// Flash ladder (charter decision 17): motion is a MEASUREMENT. Diff the last
	// applied snapshot against this one and stamp each changed doc id so the
	// renderer can derive a one-shot fade (FlashLevel). The diff is snapshot-only
	// (decision 4: never incremental event application). The FIRST snapshot of a
	// session flashes NOTHING — a board you just opened is still — which
	// LastSync.IsZero() (checked before it is stamped below) reports exactly.
	// NOTE for the cache slice (decision 20): this guard covers only the cold
	// paint ITSELF. If a cached snapshot is ever applied through here, it seeds
	// prevTasks + LastSync, and the first LIVE snapshot after it would diff-flash
	// everything that moved since the cache was written — the wall of highlights
	// decision 20 forbids. The cache wiring must suppress that first live diff
	// itself. prevTasks is always advanced so the NEXT diff has a base.
	firstSnapshot := m.ui.LastSync.IsZero()
	if !firstSnapshot {
		if m.ui.Flashes == nil {
			m.ui.Flashes = map[string]time.Time{}
		}
		landed := m.now()
		// Diff against the MERGED set, not the raw snapshot: a row that was kept
		// because the incoming copy was stale is byte-identical to prevTasks, so it
		// does not flash — only rows that actually moved forward do.
		for _, id := range changedDocIDs(m.prevTasks, merged) {
			m.ui.Flashes[id] = landed
		}
	}
	m.prevTasks = merged

	m.ui.LastSync = msg.snap.FetchedAt
	m.lastAppliedFetch = msg.snap.FetchedAt

	// ── first-paint cache write (slice 8) ───────────────────────────────────
	// Persist the accepted snapshot as the next launch's first paint (charter
	// decision #9). Best-effort by contract — SaveCachedSnapshot swallows every
	// failure and never blocks — and already throttled to at most one write per
	// applied snapshot: the 750ms SSE debounce upstream coalesces event bursts
	// into a single refetch, so no extra rate guard is needed. Only the accepted
	// board is cached: the err path and the out-of-order-drop guard above both
	// return before here, so a stale or failed fetch never overwrites a good
	// cache. cacheDir=="" (no resolvable config dir) makes this a silent no-op.
	//
	// The keyset cursor rides along (Snapshot.EventCursor). It is not board data
	// — it is the resume point for the cheap poll — but this is the one file the
	// board already writes per scope, and persisting it is what makes the SECOND
	// launch skip the catch-up walk: a cold cursor is 0, which means the whole
	// task-event backlog sits between the board and now. An absent or stale value
	// costs one walk, never a wrong board, because the cursor never carries truth
	// (decision #4) — it only decides WHEN the snapshot fetch runs.
	mergedSnap.EventCursor = m.eventCursor
	SaveCachedSnapshot(m.cacheDir, m.cacheKey, mergedSnap)
	// ────────────────────────────────────────────────────────────────────────
	if !msg.keepStrip {
		// A landed snapshot clears any transient strip AND disarms the close
		// guard: the arm-prompt is the guard's only visible face, so the two
		// must never part ways (an invisibly-armed x firing a close on the next
		// press would be a trap). The one exception is the reconciling refetch a
		// successful action fired itself — wiping its own confirmation within
		// the network round-trip would make every success flash unreadably.
		m.ui.Strip = ActionStrip{}
		m.pendingClose = ""
	}
	// Aged-out notice (distinct from the ambient "showing N of M" footnote,
	// which only says the corpus is bigger than the fetch — never that specific
	// rows went stale). agedOut is always 0 when the window was not truncated,
	// so an untruncated refresh never touches the strip here. This intentionally
	// runs AFTER the keepStrip guard above: on the rare refresh that is both a
	// post-action reconcile AND truncated, the honest aged-out count takes
	// priority over the action's own confirmation rather than silently losing it.
	if agedOut > 0 {
		word := "task"
		if agedOut != 1 {
			word = "tasks"
		}
		m.ui.Strip = ActionStrip{
			Message: fmt.Sprintf("%d %s aged out of the 1000-row window — still open, not closed", agedOut, word),
			Role:    RoleWarn,
		}
	}
	if m.liveIsFresh() {
		m.ui.Conn = ConnLive
	} else {
		m.ui.Conn = ConnPolling
	}
	if selected != "" {
		for i, r := range m.visibleRows() {
			if r.docID == selected {
				m.ui.Cursor = i
				break
			}
		}
	}
	m.clampCursor()

	// Drop already-faded flash entries. The heartbeat prunes on every tick, but
	// when a snapshot lands on a board whose ticker has stopped (or is about to
	// stop below), nothing else would — and stale level-0 entries would pile up
	// in UIState.Flashes for the life of the session. Level-0 entries never make
	// Alive true, so pruning here cannot change the arm/stop decision.
	pruneFlashes(m.ui.Flashes, m.now())

	// Re-arm (or stand down) the heartbeat against the freshly-built board. A new
	// claim in the NOW band or a just-stamped flash makes it Alive → arm the tick
	// chain (guarded, so a redundant arm while already running is a no-op). If the
	// board has gone still — no claims, all flashes decayed — stop the chain and
	// reset Frame to 0 so the rest state is deterministic and at-rest goldens stay
	// byte-identical (charter decision 16). The arm cmd is hoisted to its own
	// statement: maybeStartHeartbeat mutates m through its pointer receiver, and
	// `return m, m.maybeStartHeartbeat()` would leave the order of the m-copy vs
	// the call unspecified (Go spec orders only the calls) — a compiler copying m
	// first would return a model without frameOn/frameGen while the tick already
	// carries the bumped gen.
	if Alive(m.board, m.ui, m.now()) {
		hb := m.maybeStartHeartbeat()
		return m, hb
	}
	if m.frameOn {
		m.stopHeartbeat()
	} else {
		m.ui.Frame = 0
	}
	return m, nil
}

// labelServerTimeout is the timeout class's operator-facing label — the same
// phrase humanizeReason (actions.go) uses for a timed-out claim/close, so the
// two surfaces name the one condition with one voice. Distinct from "offline"
// by design: a timeout means the server is slow, not gone.
const labelServerTimeout = "server timeout"

// isSnapshotTimeout reports whether a snapshot fetch error is a client-side
// timeout — TYPED, mirroring humanizeReason's errors.As pattern (actions.go),
// never a string match on deadline text (the phrasing varies by transport
// stage and Go version). Two shapes cover every stage of getJSONCtx's request:
// http.Client.Do wraps a deadline/dial timeout as *url.Error (whose Timeout()
// is true for context.DeadlineExceeded too), and a deadline that fires MID-BODY
// surfaces from io.ReadAll as context.DeadlineExceeded without the url.Error
// wrapper. A dial-tcp connection refused is a *url.Error with Timeout()==false,
// so genuine unreachability stays out of this class.
func isSnapshotTimeout(err error) bool {
	var uerr *url.Error
	if errors.As(err, &uerr) && uerr.Timeout() {
		return true
	}
	return errors.Is(err, context.DeadlineExceeded)
}

// snapshotErrorLabel keeps the identity strip accurate without dumping a long
// transport/decode error into the fixed-width header. The full error remains at
// the fetch boundary for tests and diagnostics; this is the operator-facing
// classification.
//
// EVERY class this binary can KNOW is decided on a TYPE, never on the error's
// text, and the reason is that the text is not ours: a status error's message
// ends in bodyHint(body) — up to 120 characters of the SERVER'S OWN response.
// The old switch ran strings.Contains over that, so a body that merely SPELLED
// another status or the oversize words stole the class: a 403 explaining itself
// with "membership probe returned status 401" read "unauthorized"; a gateway
// 500 forwarding "upstream status 404" read "snapshot unavailable" — a
// permanent-looking class for the one failure that is actually retryable.
//   - timeout: typed (errors.As on *url.Error + errors.Is DeadlineExceeded) —
//     a *url.Error's text spells the whole request and carries no "timeout"
//     word, which is how a slow fetch used to read "offline".
//   - status: typed (*httpStatusError.StatusCode, the int resp.StatusCode was
//     read as), so the code decides and the body is never consulted.
//   - oversize: typed (*oversizeBodyError).
//
// The trailing string switch is the LEGACY tail: it exists for errors this
// package did not construct (a hand-built error in a caller or a test). It
// checks "decode" — a prefix THIS binary writes on decodeTaskListFull's
// refusals — before the status words, so a decode refusal whose bodyHint quotes
// a status still lands in its own documented "invalid snapshot" class.
func snapshotErrorLabel(err error) string {
	if err == nil {
		return ""
	}
	if isSnapshotTimeout(err) {
		return labelServerTimeout
	}
	var oversize *oversizeBodyError
	if errors.As(err, &oversize) {
		return "snapshot too large"
	}
	var status *httpStatusError
	if errors.As(err, &status) {
		return httpStatusLabel(status.StatusCode)
	}
	s := strings.ToLower(err.Error())
	switch {
	case strings.Contains(s, "decode"):
		return "invalid snapshot"
	case strings.Contains(s, "exceeds") && strings.Contains(s, "bytes"):
		return "snapshot too large"
	case strings.Contains(s, "status 401"):
		return "unauthorized"
	case strings.Contains(s, "status 403"):
		return "forbidden"
	case strings.Contains(s, "status 404"):
		return "snapshot unavailable"
	case strings.Contains(s, "status 5"):
		return "server error"
	default:
		return "offline"
	}
}

// httpStatusLabel names a refused fetch's status class from the CODE. 5xx is a
// range check, not a "status 5" prefix match, so a 5xx is a 5xx whatever the
// body says — and any other unmapped code (a 400, a 429) keeps the honest
// generic bucket rather than being guessed at.
func httpStatusLabel(code int) string {
	switch {
	case code == http.StatusUnauthorized:
		return "unauthorized"
	case code == http.StatusForbidden:
		return "forbidden"
	case code == http.StatusNotFound:
		return "snapshot unavailable"
	case code >= 500 && code <= 599:
		return "server error"
	default:
		return "offline"
	}
}

// snapshotTruncated reports whether the 1000-row task-list clamp is active on
// this fetch: the fetch is desc:updated_at (tasks_controller.ex) clamped to a
// fixed row count, so over a corpus bigger than the clamp, len(snap.Tasks) —
// the envelopes actually returned — falls short of the summed lifecycle
// Counts the server reports as the true corpus total. This is the SAME
// predicate render.go's summedLifecycleCounts/"showing N of M" footnote uses
// (b.TaskCount > 0 && b.TaskCount < total), evaluated one step earlier in the
// pipeline — against the RAW incoming snapshot, before mergeForward runs —
// because mergeForward is exactly the thing that needs to know whether a
// prev-only absence means "closed" or "rotated out of the window". A zero
// fetch (len 0, e.g. an empty corpus) is never truncated.
func snapshotTruncated(snap Snapshot) bool {
	total := 0
	for _, v := range snap.Counts {
		total += v
	}
	n := len(snap.Tasks)
	return n > 0 && n < total
}

// liveIsFresh reports whether a live SSE event has been seen recently enough to
// still trust the stream. lastLiveEvent's zero value (no event ever) is never
// fresh, so a program that never gets a single frame reads honestly as polling.
func (m Model) liveIsFresh() bool {
	if m.lastLiveEvent.IsZero() {
		return false
	}
	return m.now().Sub(m.lastLiveEvent) <= m.liveStale
}

// wireLive connects the apiclient change seam to a running program and starts
// the SSE listener. The listener loops for the life of the process (it has no
// stop channel — the program owning it exits the whole binary), exactly like
// the desk TUI's live wiring. Split out so Run stays readable and this seam can
// be exercised against an httptest server in tests.
func wireLive(p *tea.Program, c *apiclient.Client, token string) {
	// OnChange = a real SSE mutation frame (live==true, holds ● live);
	// OnChangeFallback = the NDJSON poll fallback (live==false, reads ◐ polling);
	// OnLivePulse = any stream frame at all (welcome/keepalive/mutation), which
	// keeps ● honest while the dataset is QUIET. Wiring all three means a
	// poll-driven change still refetches, but only genuine stream traffic can
	// bump lastLiveEvent — so the connection dot never lies in either direction.
	c.OnChange = func() { p.Send(changeMsg{live: true}) }
	c.OnChangeFallback = func() { p.Send(changeMsg{live: false}) }
	c.OnLivePulse = func() { p.Send(pulseMsg{}) }
	// StartSSE now takes a context (mirroring Listen in listen.go): a stalled
	// connection (server accepts, never writes) used to block the read forever
	// with no way to unblock it. wireLive doesn't own the program's Run() call
	// (program.go) so there is no shutdown signal to cancel against from here;
	// context.Background() is the same nil-safe, never-canceled behaviour as
	// before this fix, so the reconnect/happy-path here is unchanged — the real
	// fix (a cancellable ctx actually unblocking the read) is exercised by
	// change_test.go and by main.go's app-lifetime ctx for the desk TUI.
	go c.StartSSE(context.Background(), token)
}
