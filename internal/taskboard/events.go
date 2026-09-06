package taskboard

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
)

// events.go is the board's CHEAP CHANGE DETECTOR: a keyset poll of
// GET /v1/tasks/events?since=<cursor> that answers "did any task move?" for the
// price of one PK-index read, so the EXPENSIVE pair (GET /v1/tasks?limit=1000 —
// ~9 MB live — plus GET /v1/tasks/prime, a 2 GB parallel seq scan on
// mutation_events) runs only when the answer is yes.
//
// WHY (measured on guerrilla, 2026-09-01T21:43-21:46Z, task-e2f5ecca0be9a6d1):
// three open boards produced 360 GET /v1/tasks + 219 GET /v1/tasks/prime in
// five minutes against a 2-core box at load 11. The board itself was the load.
// The old loop refetched the whole snapshot on EVERY dataset SSE frame (any
// document type, debounced 750ms) plus an unconditional 30s backstop, and each
// refetch is THREE heavy requests (list + prime + the in-flight filter pass).
// On a dataset a six-lead campaign is writing to, that is a refetch every few
// seconds, forever, per board.
//
// The keyset feed exists precisely so a board can poll a cursor instead
// (api/lib/barkpark/tasks/events.ex): `WHERE id > $since ORDER BY id ASC` over
// the monotonic mutation_events PK — an index scan, and the ONLY exact resume
// cursor (prime's recent_events sorts inserted_at DESC and carries no id, so it
// is replay-unsafe by construction). This file polls THAT, and hands the
// snapshot refetch a delta bit instead of a timer.
//
// THE ONE IRON RULE IS UNCHANGED (charter decision #4): events never carry
// truth. A page of events only says "something moved"; the snapshot refetch
// says WHAT is true. Nothing here applies an event payload to a row.

const (
	// taskEventsPath is the keyset feed. The task routes are mounted at the
	// host's TOP-LEVEL /v1 scope (tenancy rides the bearer token), exactly like
	// the list/prime fetches in fetch.go.
	taskEventsPath = "/v1/tasks/events"

	// taskEventsPageLimit is the page size asked for. The server clamps to
	// [1,500] (Tasks.Events.page_limit) and reports has_more as "a full page came
	// back", so asking for the server maximum makes a catch-up drain page in the
	// fewest round trips.
	taskEventsPageLimit = 500

	// basePollEvery is the floor cadence: the interval used right after a delta,
	// after a user action, and at start. It is also the fastest the board can be
	// made to re-list — a dataset moving faster than this coalesces into one
	// re-list per interval instead of one per mutation frame.
	basePollEvery = 2 * time.Second

	// maxPollEvery is the idle ceiling. The interval doubles on every poll that
	// found nothing, so a quiet board settles at one cheap indexed read per 30s
	// and issues ZERO list/prime requests.
	maxPollEvery = 30 * time.Second

	// drainPollEvery paces the CATCH-UP walk. A page that came back full
	// (has_more) means the cursor is behind the tip — on a cold start it is at 0
	// and the whole task-event backlog is between us and now. Those pages are
	// walked back-to-back at this cadence and, crucially, WITHOUT re-listing:
	// the board already holds a snapshot newer than any of that history, so
	// re-listing per page would be the storm this file exists to end. Exactly
	// ONE re-list is owed at the end of a drain (drainOwed), and only if the
	// drain actually saw an event.
	drainPollEvery = 50 * time.Millisecond

	// maxDrainPages bounds the catch-up walk so a pathological backlog cannot
	// turn the cheap detector into its own request storm. On overflow the board
	// gives up on the feed for this process (eventsOff) and falls back to the
	// legacy backstop loop — degraded, honest, never worse than before.
	maxDrainPages = 2000

	// minRelistEvery is the floor between two HEAVY reads, and it is a separate
	// number from basePollEvery on purpose — the two answer different questions.
	// basePollEvery is how fast the board NOTICES (cheap, indexed); this is how
	// often it is allowed to RELOAD (the ~9 MB list + prime's seq scan).
	//
	// It exists because the 2s detect floor alone made the busy case WORSE, and
	// the budget simulation caught it: a ledger moving on every poll re-listed 32
	// times in 60 simulated seconds where the old SSE-debounced loop managed 15.
	// Fast detection is only a win if it does not turn into fast re-listing. The
	// measured campaign cadence on guerrilla was one refetch per ~4.1s per board
	// (219 prime / 3 boards / 300s), so a 5s floor is strictly below what the
	// server was already absorbing, and a delta detected inside the floor is not
	// dropped — relistOwed carries it to the next permitted read.
	minRelistEvery = 5 * time.Second

	// slowReadThreshold is the visible-state trigger. A poll that takes longer
	// than this is not "working", it is queueing behind something on the server —
	// the board says so (paused (server slow)) and backs off exactly as an idle
	// board does, instead of leaning harder on a box that is already struggling.
	// A slow read is also NOT CONSUMED: the cursor does not advance and no
	// re-list fires, so the delta it may have carried is re-detected by the first
	// healthy poll rather than being silently dropped.
	slowReadThreshold = 2 * time.Second

	// pausedLabel is the operator-facing state for a slow or failed poll. It sits
	// in its own UIState field rather than ConnProblem so it can never fight with
	// (or be clobbered by) a snapshot-path error label.
	pausedLabel = "paused (server slow)"
)

// TaskEvent is one row of the keyset feed. ID is THE CURSOR — the monotonic
// mutation_events PK, the only field a resume may key on. The rest is carried
// because it costs nothing and makes the poll self-describing in a test; the
// board never renders it (decision #4: the refetch is what says what is true).
type TaskEvent struct {
	ID    int64     `json:"id"`
	Event string    `json:"event"`
	DocID string    `json:"doc_id"`
	Rev   string    `json:"rev"`
	At    time.Time `json:"at"`
}

// TaskEventsPage is one answer from GET /v1/tasks/events. Cursor is what the
// server says to pass back as ?since= (it echoes the request's since when the
// page is empty, so a caught-up poll is idempotent); HasMore is the server's own
// "a full page came back" flag, which is the signal to walk again immediately.
type TaskEventsPage struct {
	OK      bool        `json:"ok"`
	Events  []TaskEvent `json:"events"`
	Cursor  int64       `json:"cursor"`
	HasMore bool        `json:"has_more"`
}

// FetchTaskEvents issues one keyset poll. It rides the SAME transport and byte
// cap as the snapshot fetches (getJSON → snapshotHTTP), so the board's read
// budget stays in one place and the interactive apiclient timeout can never
// clamp it.
//
// A malformed body is a REFUSAL, not a zero page: silently reading a garbage
// answer as "no events" would make the board go quietly stale, which is the
// exact failure the visible paused state exists to prevent.
func FetchTaskEvents(c *apiclient.Client, since int64, limit int) (TaskEventsPage, error) {
	if since < 0 {
		since = 0
	}
	if limit <= 0 {
		limit = taskEventsPageLimit
	}
	q := url.Values{}
	q.Set("since", strconv.FormatInt(since, 10))
	q.Set("limit", strconv.Itoa(limit))
	path := taskEventsPath + "?" + q.Encode()

	body, err := getJSON(c, path)
	if err != nil {
		return TaskEventsPage{}, err
	}
	var page TaskEventsPage
	if err := json.Unmarshal(body, &page); err != nil {
		return TaskEventsPage{}, fmt.Errorf("decode %s: %w", taskEventsPath, err)
	}
	// The cursor is the contract. A server that answered 200 with no cursor (an
	// older build that does not carry the route, a proxy's own JSON) must not be
	// mistaken for "caught up at 0" — that would restart the drain on every poll.
	if !page.OK && len(page.Events) == 0 && page.Cursor == 0 {
		return TaskEventsPage{}, fmt.Errorf("decode %s: body carries no task-events envelope", taskEventsPath)
	}
	// Never let a server answer move the cursor BACKWARD: the resume is
	// monotonic by construction and a regression would replay history forever.
	if page.Cursor < since {
		page.Cursor = since
	}
	return page, nil
}

// --- message types -----------------------------------------------------------

// eventsPollMsg is the self-clocking poll tick. It carries the generation it was
// armed under: a user action or a manual refresh bumps eventsGen so every timer
// from the superseded chain is dropped instead of double-clocking the loop.
//
// The chain is self-clocking on PURPOSE — a poll result arms the next tick, and
// nothing else does. That is the whole no-overlap guarantee: while a read is in
// flight there is no timer pending, so a slow tick can never queue another.
type eventsPollMsg struct{ gen int }

// eventsResultMsg is one poll's outcome. elapsed is measured around the request
// itself (not the reducer), because it is the SERVER's latency the paused state
// reports, and the board's own render time must never be able to trip it.
type eventsResultMsg struct {
	gen     int
	page    TaskEventsPage
	err     error
	elapsed time.Duration
}

// --- commands ----------------------------------------------------------------

// schedulePoll arms the next poll tick at d under gen.
func (m Model) schedulePoll(gen int, d time.Duration) tea.Cmd {
	return m.tick(d, func(time.Time) tea.Msg { return eventsPollMsg{gen: gen} })
}

// pollEventsCmd runs one keyset read off the update loop and times it.
func (m Model) pollEventsCmd(gen int) tea.Cmd {
	fetch := m.fetchEvents
	client := m.client
	since := m.eventCursor
	now := m.now
	return func() tea.Msg {
		start := now()
		page, err := fetch(client, since, taskEventsPageLimit)
		return eventsResultMsg{gen: gen, page: page, err: err, elapsed: now().Sub(start)}
	}
}

// --- the interval schedule ---------------------------------------------------

// nextPollInterval is the adaptive schedule, as a pure function so the whole
// ladder is a table test rather than a wall-clock observation:
//
//	delta (or a user action) → basePollEvery, always. A board that just moved is
//	                           the board most likely to move again.
//	idle                     → double, capped at maxPollEvery.
//
// An error or a slow read takes the IDLE arm on purpose: backing off is the
// only response to a struggling server that does not make it worse.
func nextPollInterval(cur time.Duration, delta bool) time.Duration {
	if delta {
		return basePollEvery
	}
	if cur < basePollEvery {
		return basePollEvery
	}
	next := cur * 2
	if next > maxPollEvery {
		return maxPollEvery
	}
	return next
}

// --- reducers ----------------------------------------------------------------

// handleEventsPoll fires one keyset read, unless the feed has been given up on
// or a read is already in flight. It arms NO timer of its own — the result
// reducer is what re-clocks the chain — so the loop can never run two reads at
// once and a stalled read simply means the next tick has not been scheduled yet.
func (m Model) handleEventsPoll(msg eventsPollMsg) (Model, tea.Cmd) {
	if msg.gen != m.eventsGen || m.eventsOff {
		return m, nil
	}
	if m.pollInFlight {
		// Belt and braces: the chain is self-clocking, so this should be
		// unreachable. If a stray tick from the live generation ever does arrive
		// while a read is out, drop it — re-arming here is what would build the
		// queue this guard exists to prevent.
		return m, nil
	}
	m.pollInFlight = true
	return m, m.pollEventsCmd(msg.gen)
}

// handleEventsResult applies one poll outcome and re-clocks the chain. Four
// arms, in the order they matter:
//
//  1. SLOW or FAILED → paused (server slow) with the next retry time, back off
//     like idle, and DO NOT consume the read (the cursor stays put, no re-list),
//     so a delta hiding behind a slow read is re-detected rather than lost.
//  2. FULL PAGE (has_more) → the cursor is behind the tip: walk the next page
//     immediately at drainPollEvery WITHOUT re-listing, and remember that one
//     re-list is owed. This is what makes a cold start (cursor 0, the whole
//     backlog between us and now) cost a short cheap walk instead of one heavy
//     re-list per page.
//  3. DELTA (events on a final page, or a drain finishing) → exactly ONE
//     re-list, and the interval snaps back to basePollEvery.
//  4. NOTHING → double the interval toward the 30s ceiling. This arm is the
//     steady state of a quiet board: no list, no prime, one indexed read.
func (m Model) handleEventsResult(msg eventsResultMsg) (Model, tea.Cmd) {
	if msg.gen != m.eventsGen {
		// A superseded generation's read landing late: release the in-flight bit
		// (it is this read's) but never re-clock a dead chain.
		m.pollInFlight = false
		return m, nil
	}
	m.pollInFlight = false

	if msg.err != nil || msg.elapsed > slowReadThreshold {
		m.pollEvery = nextPollInterval(m.pollEvery, false)
		m.ui.Paused = true
		m.ui.RetryAt = m.now().Add(m.pollEvery)
		return m, m.armNextPoll(m.pollEvery)
	}
	m.ui.Paused = false
	m.ui.RetryAt = time.Time{}
	m.eventCursor = msg.page.Cursor

	if msg.page.HasMore {
		m.drainPages++
		if len(msg.page.Events) > 0 {
			m.drainOwed = true
		}
		if m.drainPages > maxDrainPages {
			// A backlog this deep means the feed cannot be caught up cheaply.
			// Stand the detector down for this process rather than let the
			// catch-up walk become its own storm; the backstop still refreshes
			// the board, exactly as it did before this loop existed.
			m.eventsOff = true
			m.drainOwed = false
			m.pollNudged = false
			return m, nil
		}
		m.pollEvery = basePollEvery
		return m, m.armNextPoll(drainPollEvery)
	}

	delta := len(msg.page.Events) > 0 || m.drainOwed || m.relistOwed
	m.drainPages = 0
	m.drainOwed = false
	m.pollEvery = nextPollInterval(m.pollEvery, delta)
	if !delta {
		m.relistOwed = false
		return m, m.armNextPoll(m.pollEvery)
	}

	// A delta inside the re-list floor is HELD, never dropped: remember that a
	// reload is owed and come back exactly when the floor expires. This is what
	// keeps a constantly-moving ledger from turning 2s detection into 2s
	// re-listing — the board still learns about the change in 2s, it just reloads
	// on the slower clock the server can afford.
	if wait := minRelistEvery - m.now().Sub(m.lastRelistAt); wait > 0 && !m.lastRelistAt.IsZero() {
		m.relistOwed = true
		return m, m.armNextPoll(wait)
	}
	next := m.armNextPoll(m.pollEvery)
	relist := m.tickRefetchCmd()
	if relist == nil {
		// The heavy pair is already out — and it is OLDER than this delta: it
		// was issued before the event existed, so it cannot carry it. The
		// events were CONSUMED above (the cursor advanced past them), so the
		// next poll sees an empty page and would call the board idle. HOLD the
		// delta instead: relistOwed keeps `delta` true on the next poll, which
		// keeps the interval at the floor and re-tries the re-list the moment
		// the outstanding fetch clears. Dropping it here is what left a stamped
		// criteria ladder stale while the interval doubled toward 30s.
		m.relistOwed = true
		return m, next
	}
	m.relistOwed = false
	m.lastRelistAt = m.now()
	m.fetchInFlight = true
	return m, tea.Batch(relist, next)
}

// armNextPoll is the chain's ONE re-clock point. It honours a nudge that
// arrived while the read was out (nudgePoll could not arm a timer then without
// racing the read it was waiting on), so a user action or an SSE frame during a
// slow poll still collapses the next interval to the floor.
func (m *Model) armNextPoll(d time.Duration) tea.Cmd {
	if m.pollNudged {
		m.pollNudged = false
		m.pollEvery = basePollEvery
		d = 0
	}
	return m.schedulePoll(m.eventsGen, d)
}

// tickRefetchCmd is the TICK-DRIVEN re-list, and the one place the no-overlap
// rule is enforced for the heavy pair: it REFUSES (returns nil) while a
// snapshot fetch is still out, because queueing a second 9 MB list behind a
// slow one is exactly how one slow read turns into a backlog of them.
//
// A refusal is NOT a licence to forget. The in-flight fetch was issued before
// the delta existed and reads server state from BEFORE it, so it cannot carry
// the change — the earlier claim that "the in-flight fetch reads the same
// server state a moment later" was false for precisely the case that matters.
// Every caller that consumed a delta must therefore HOLD it (relistOwed) on a
// nil answer and re-try; only handleBackstop may drop, because its unconditional
// timer consumed nothing and fires again on its own.
//
// Keystroke-driven refetches (the post-claim/close reconcile) deliberately do
// NOT ride this guard: those are rare, user-initiated, and must land.
func (m Model) tickRefetchCmd() tea.Cmd {
	if m.fetchInFlight {
		return nil
	}
	return m.refetchCmd(false)
}

// nudgePoll collapses the interval back to the floor and asks the feed NOW. It
// is what a live SSE frame and a user action both do: they are hints that the
// board is about to be interesting, not truth about what changed — the poll
// still asks the feed, and the feed still decides whether the heavy pair runs.
//
// Two shapes, and the split is the no-overlap rule:
//
//   - idle → bump the generation (orphaning any pending timer, so a burst of
//     nudges cannot leave two chains clocking the loop) and arm immediately.
//   - a read already in flight → arm NOTHING. Starting a second read here is
//     exactly the overlap this loop forbids, and clearing pollInFlight to fake
//     one would leave two reads racing. Record the nudge instead; armNextPoll
//     honours it the moment the outstanding read lands.
func (m *Model) nudgePoll() tea.Cmd {
	if m.eventsOff {
		return nil
	}
	m.pollEvery = basePollEvery
	if m.pollInFlight {
		m.pollNudged = true
		return nil
	}
	m.eventsGen++
	return m.schedulePoll(m.eventsGen, 0)
}

// manualRefresh is the `r` key: the user overriding the adaptive ladder. It does
// BOTH halves deliberately —
//
//   - an immediate full re-list, because the whole point of the key is "do not
//     wait for the poll to notice"; it rides the same no-overlap guard, so
//     leaning on r while a 9 MB list is already out is a no-op rather than a
//     way to hand-crank the storm this loop removed.
//   - a nudge, because the poll interval must also collapse to the floor: a
//     board the user just touched is a board about to be interesting, and
//     leaving it parked at the 30s idle ceiling would make the NEXT change take
//     half a minute to appear.
//
// It also clears the paused state optimistically. The next poll result is what
// re-establishes it truthfully if the server is still slow — but a stale
// "paused (server slow)" sitting on screen while a fresh read is in flight would
// be a lie about what the board is doing right now.
func (m Model) manualRefresh() (Model, tea.Cmd) {
	m.ui.Paused = false
	m.ui.RetryAt = time.Time{}
	cmds := []tea.Cmd{}
	if relist := m.tickRefetchCmd(); relist != nil {
		m.fetchInFlight = true
		m.lastRelistAt = m.now()
		m.relistOwed = false
		cmds = append(cmds, relist)
	}
	if nudge := (&m).nudgePoll(); nudge != nil {
		cmds = append(cmds, nudge)
	}
	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}
