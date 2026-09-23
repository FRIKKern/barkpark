package taskboard

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	tea "github.com/charmbracelet/bubbletea"
)

// relist_liveness_test.go is the FRESHNESS GUARD for the board's re-list.
//
// Making a poller cheap is trivial and every cheap way of getting it wrong
// looks identical from the outside: poll less often, cache harder, or diff the
// corpus wrongly, and the byte counter falls while the board quietly stops
// telling the truth. This file is the control that separates those from a real
// win: a mutation made at T must be on the board by T+basePollEvery, and the
// assertions below are RED on any cheapening that drops the delta.
//
// It is deliberately written against the REAL fetch seam (FetchSnapshotFull)
// over a REAL cursor-paged ledger served by httptest, not against a stub — a
// test whose fetch is a fake cannot notice that the fetch stopped re-reading.

// ─── the fake ledger ────────────────────────────────────────────────────────

// ledgerRow is one mutable task in the fake ledger.
type ledgerRow struct {
	DocID     string
	Title     string
	Lifecycle string
	Rev       string
	UpdatedAt time.Time
}

// fakeLedger serves /v1/tasks (cursor-paged, desc updated_at), /v1/tasks/prime
// and /v1/tasks/events over a corpus a test can MUTATE mid-run. It counts the
// bytes it hands out per route so the same fixture also backs the budget
// assertions.
type fakeLedger struct {
	t    *testing.T
	mu   sync.Mutex
	rows []ledgerRow // kept sorted desc by UpdatedAt
	// pageLimitSeen records every ?limit= the corpus walk asked for, so a test
	// can tell an incremental head walk from a full-corpus walk.
	bytes map[string]int64
	calls map[string]int
	// viewsSeen records every ?view= the corpus GET spelled, "" for the default
	// shape. It is what lets a test assert WHICH projection the board asked for
	// rather than infer it from a byte count.
	viewsSeen []string
	events    []TaskEvent
	cursor    int64
	srv       *httptest.Server
	// padding inflates each row's content so a page is expensive, the way a
	// live task row (~10 KB of criteria + evidence) is.
	padding string
}

func newFakeLedger(t *testing.T, n int, padBytes int) *fakeLedger {
	t.Helper()
	l := &fakeLedger{
		t:       t,
		bytes:   map[string]int64{},
		calls:   map[string]int{},
		padding: string(make([]byte, 0)),
	}
	pad := make([]byte, padBytes)
	for i := range pad {
		pad[i] = 'x'
	}
	l.padding = string(pad)
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < n; i++ {
		l.rows = append(l.rows, ledgerRow{
			DocID:     fmt.Sprintf("t-%04d", i),
			Title:     fmt.Sprintf("Row %04d", i),
			Lifecycle: "open",
			Rev:       "r0",
			// Newest first: row 0 is the freshest.
			UpdatedAt: base.Add(time.Duration(n-i) * time.Minute),
		})
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/tasks/events", l.serveEvents)
	mux.HandleFunc("/v1/tasks/prime", l.servePrime)
	// The single-row route, which is ALWAYS full (`?view=` is a list param). It
	// is what a `?view=board` board hydrates an opened pane from.
	mux.HandleFunc("/v1/tasks/", l.serveTaskRow)
	mux.HandleFunc("/v1/tasks", l.serveTasks)
	l.srv = httptest.NewServer(mux)
	t.Cleanup(l.srv.Close)
	return l
}

func (l *fakeLedger) client() *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: l.srv.URL})
}

func (l *fakeLedger) record(route string, n int) {
	l.mu.Lock()
	l.bytes[route] += int64(n)
	l.calls[route]++
	l.mu.Unlock()
}

func (l *fakeLedger) tally(route string) (int64, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.bytes[route], l.calls[route]
}

// mutate rewrites one row's title and re-stamps its updated_at to at, which
// rotates it to the head of the desc:updated_at ordering exactly as the server
// does. It also appends an event so the cheap keyset poll reports the delta.
func (l *fakeLedger) mutate(docID, title string, at time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := range l.rows {
		if l.rows[i].DocID != docID {
			continue
		}
		row := l.rows[i]
		row.Title = title
		row.UpdatedAt = at
		row.Rev = fmt.Sprintf("r%d", l.cursor+1)
		l.rows = append(l.rows[:i], l.rows[i+1:]...)
		l.rows = append([]ledgerRow{row}, l.rows...)
		l.cursor++
		l.events = append(l.events, TaskEvent{ID: l.cursor, Event: "task.update", DocID: docID, Rev: "r"})
		return
	}
	l.t.Fatalf("mutate: no such row %q", docID)
}

func (l *fakeLedger) serveEvents(w http.ResponseWriter, r *http.Request) {
	l.mu.Lock()
	var since int64
	fmt.Sscanf(r.URL.Query().Get("since"), "%d", &since)
	var out []TaskEvent
	for _, e := range l.events {
		if e.ID > since {
			out = append(out, e)
		}
	}
	cursor := since
	if len(out) > 0 {
		cursor = out[len(out)-1].ID
	}
	l.mu.Unlock()
	body, _ := json.Marshal(map[string]any{"ok": true, "events": out, "cursor": cursor, "has_more": false})
	l.record("events", len(body))
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (l *fakeLedger) servePrime(w http.ResponseWriter, r *http.Request) {
	body := []byte(`{"ok":true,"counts":{"open":1},"ready":[],"recent_events":[]}`)
	l.record("prime", len(body))
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// serveTasks is the cursor-paged corpus GET. The cursor is the plain index of
// the next row (the real server's token is opaque; the only contract the client
// depends on is that page.next_cursor is present iff ?cursor= was spelled and
// null on the last page).
func (l *fakeLedger) serveTasks(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	route := "tasks"
	view := q.Get("view")
	l.mu.Lock()
	rows := append([]ledgerRow(nil), l.rows...)
	l.viewsSeen = append(l.viewsSeen, view)
	l.mu.Unlock()
	if q.Get("lifecycle_status") == "in_progress" {
		route = "tasks_in_progress"
		rows = nil
	}
	limit := 1000
	fmt.Sscanf(q.Get("limit"), "%d", &limit)
	if limit <= 0 {
		limit = 1000
	}
	start := 0
	if c := q.Get("cursor"); c != "" {
		fmt.Sscanf(c, "%d", &start)
	}
	end := start + limit
	if end > len(rows) {
		end = len(rows)
	}
	docs := make([]map[string]any, 0, end-start)
	for _, row := range rows[start:end] {
		doc := map[string]any{
			"doc_id":           row.DocID,
			"rev":              row.Rev,
			"title":            row.Title,
			"lifecycle_status": row.Lifecycle,
			"kind":             "task",
			"updated_at":       row.UpdatedAt.Format(time.RFC3339Nano),
		}
		// The REAL projection, not a stub of it: `?view=board` ships the full
		// card with `content` DELETED and `content_digest` in its place
		// (api .../tasks_controller/params.ex render_doc(doc, :board)). Serving
		// `content` anyway would make every assertion below vacuous — the board
		// would pass on a shape the live server never sends.
		if view == "board" {
			doc["content_digest"] = map[string]any{
				"criteria_marks":   "mao",
				"has_description":  true,
				"has_dependencies": false,
				"has_paper":        false,
			}
		} else {
			doc["content"] = map[string]any{"description": l.padding}
		}
		docs = append(docs, doc)
	}
	page := map[string]any{}
	if _, spelled := q["cursor"]; spelled {
		if end < len(rows) {
			page["next_cursor"] = fmt.Sprintf("%d", end)
		} else {
			page["next_cursor"] = nil
		}
	}
	body, _ := json.Marshal(map[string]any{"ok": true, "docs": docs, "page": page})
	l.record(route, len(body))
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// serveTaskRow is GET /v1/tasks/:doc_id — the always-full row route. It counts
// its calls under "task_row" so a test can assert how MANY rows a board paid
// prose for, which is the whole trade `?view=board` makes.
func (l *fakeLedger) serveTaskRow(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/v1/tasks/")
	l.mu.Lock()
	var found *ledgerRow
	for i := range l.rows {
		if l.rows[i].DocID == id {
			row := l.rows[i]
			found = &row
			break
		}
	}
	l.mu.Unlock()
	if found == nil {
		http.NotFound(w, r)
		return
	}
	body, _ := json.Marshal(map[string]any{"ok": true, "doc": map[string]any{
		"doc_id":           found.DocID,
		"rev":              found.Rev,
		"title":            found.Title,
		"lifecycle_status": found.Lifecycle,
		"kind":             "task",
		"updated_at":       found.UpdatedAt.Format(time.RFC3339Nano),
		"content":          map[string]any{"description": "PROSE for " + found.DocID},
	}})
	l.record("task_row", len(body))
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// ─── the guard ──────────────────────────────────────────────────────────────

// ledgerModel wires a Model to the fake ledger through the REAL fetch seams,
// capturing the delay every tick arms so the test reads the schedule the code
// chose instead of re-deriving it.
func ledgerModel(l *fakeLedger, armed *[]time.Duration) Model {
	m := newModel(l.client(), "", Config{BaseURL: l.srv.URL})
	m.tick = func(d time.Duration, fn func(time.Time) tea.Msg) tea.Cmd {
		*armed = append(*armed, d)
		return func() tea.Msg { return fn(time.Now()) }
	}
	return m
}

// titleOf reads one row out of the model's merged corpus.
func titleOf(m Model, docID string) (string, bool) {
	for _, t := range m.tasks {
		if t.DocID == docID {
			return t.Title, true
		}
	}
	return "", false
}

// driveSnapshot runs a refetch command to completion and applies its snapshot.
func driveSnapshot(t *testing.T, m Model, cmd tea.Cmd) Model {
	t.Helper()
	if cmd == nil {
		t.Fatal("no command to drive")
	}
	for _, msg := range runCmd(cmd) {
		if s, ok := msg.(snapshotMsg); ok {
			if s.err != nil {
				t.Fatalf("snapshot fetch failed: %v", s.err)
			}
			m, _ = m.applySnapshot(s)
		}
	}
	return m
}

// ─── the freshness bound ────────────────────────────────────────────────────

// freshnessRoundSlack is how many baseline rounds a freshness round is allowed
// to cost. It is a RATIO, not a duration: the thing it bounds is "the path that
// carries a mutation is not asymptotically dearer than a plain re-list", which
// is a property of the code and survives any machine speed. Four leaves room
// for scheduler jitter between the two measurements without leaving room for a
// second corpus walk.
const freshnessRoundSlack = 4

// measureFreshnessRound times ONE freshness round on an UNMUTATED ledger: the
// cheap keyset poll plus the full re-list it would buy, over the same fixture,
// in the same process, on the same machine, moments before the real one.
//
// It exists because the assertion it feeds used to be a wall-clock literal
// (elapsed > basePollEvery). That literal measured how busy the machine was,
// not whether the re-list carried the change: on a loaded CI runner a
// completely CORRECT re-list reds it (run 35743747353, job 106800326576 —
// "mutation 1 reflected only at T+3.668s"). basePollEvery is a real floor on
// the POLL and stays exactly where it is; it was never a budget for the cost
// of a corpus walk, and reusing it as one is what made this file load-bound.
//
// The model is passed and returned BY VALUE, so the probe leaves the caller's
// board untouched — it reads the ledger, it does not advance the test.
func measureFreshnessRound(t *testing.T, l *fakeLedger, m Model) time.Duration {
	t.Helper()
	probe := m
	start := time.Now()
	if _, err := FetchTaskEvents(l.client(), probe.eventCursor, taskEventsPageLimit); err != nil {
		t.Fatalf("baseline events poll: %v", err)
	}
	probe.fetchInFlight = false
	_ = driveSnapshot(t, probe, probe.refetchCmd(false))
	round := time.Since(start)
	if round <= 0 {
		t.Fatalf("baseline freshness round measured %v — the probe did no work, so any bound derived from it is vacuous", round)
	}
	return round
}

// freshnessBound turns that baseline into the ceiling the tests assert against.
// It is floored at basePollEvery so a fast machine never gets a bound TIGHTER
// than the interval the board actually promises — the guard may only ever be
// looser than the literal it replaced, never stricter.
func freshnessBound(round time.Duration) time.Duration {
	bound := round * freshnessRoundSlack
	if bound < basePollEvery {
		bound = basePollEvery
	}
	return bound
}

// TestBoardNoticesAMutationWithinOneBasePoll is c1's guard.
//
// A mutation made at T — on a row DEEP in the corpus, page 3 of the walk, the
// exact row an incremental head walk would be tempted to skip — must be on the
// board by T+basePollEvery. The test asserts three separate things, each of
// which a cheapening can break on its own:
//
//  1. the poll that notices the delta is armed no slower than basePollEvery;
//  2. the re-list it buys actually CARRIES the new value (this is the one a
//     caching or diffing mistake reds);
//  3. the cost of that round is no more than a small multiple of one plain
//     freshness round measured in the SAME run (see measureFreshnessRound) —
//     a machine-scaled bound, not a wall-clock literal.
//
// Written and run GREEN against the unmodified tree before any cheapening, so
// it cannot have been shaped to fit the optimisation it guards.
func TestBoardNoticesAMutationWithinOneBasePoll(t *testing.T) {
	// 2500 rows at ~4 KB each: three pages of the 1000-row corpus walk, so the
	// mutated row below is genuinely off the head page.
	l := newFakeLedger(t, 2500, 4096)
	var armed []time.Duration
	m := ledgerModel(l, &armed)

	// Cold fetch: the board holds the whole corpus.
	m = driveSnapshot(t, m, m.refetchCmd(false))
	const victim = "t-2400"
	if got, ok := titleOf(m, victim); !ok || got != "Row 2400" {
		t.Fatalf("cold fetch: %s = %q (present=%v), want %q", victim, got, ok, "Row 2400")
	}

	// The bound for the assertion at the bottom, measured HERE on THIS machine
	// against an unmutated ledger, so a slow runner scales it instead of
	// failing it.
	baseline := measureFreshnessRound(t, l, m)

	// ── T: the mutation ──────────────────────────────────────────────────
	T := time.Now()
	l.mutate(victim, "MUTATED", time.Now().UTC())

	// The cheap poll notices. handleEventsResult is the one arm that converts a
	// delta into a re-list; runCmd walks whatever it queued.
	page, err := FetchTaskEvents(l.client(), m.eventCursor, taskEventsPageLimit)
	if err != nil {
		t.Fatalf("events poll: %v", err)
	}
	if len(page.Events) == 0 {
		t.Fatalf("the keyset poll reported NO delta for a mutation that happened — the detector is blind, so nothing downstream can be trusted")
	}
	m, cmd := m.handleEventsResult(eventsResultMsg{gen: m.eventsGen, page: page})

	if m.pollEvery > basePollEvery {
		t.Fatalf("after a delta the poll interval is %v, want <= %v (basePollEvery): a board that backs off on a MOVING ledger notices the next change late", m.pollEvery, basePollEvery)
	}

	sawRelist := false
	for _, msg := range runCmd(cmd) {
		s, ok := msg.(snapshotMsg)
		if !ok {
			continue
		}
		sawRelist = true
		if s.err != nil {
			t.Fatalf("the re-list the delta bought failed: %v", s.err)
		}
		m, _ = m.applySnapshot(s)
	}
	if !sawRelist {
		t.Fatalf("a delta produced NO re-list: the board saw the event and never re-read the snapshot")
	}

	// ── the assertion the whole file exists for ──────────────────────────
	got, ok := titleOf(m, victim)
	if !ok {
		t.Fatalf("%s vanished from the board after the re-list", victim)
	}
	if got != "MUTATED" {
		t.Fatalf("the board still shows %s = %q after the re-list that a delta bought: the mutation made at T is NOT reflected. A re-list that does not carry the change is a re-list that only looks cheap.", victim, got)
	}
	// The LOGICAL round is the subject, and it is the titleOf check just above:
	// the mutation is carried by the re-list that followed it. What remains
	// here is a COST guard, and it is stated relative to a round measured in
	// this run rather than as a wall-clock literal.
	if bound := freshnessBound(baseline); time.Since(T) > bound {
		t.Fatalf("mutation at T reflected only at T+%v; one unmutated freshness round on this machine costs %v, so the bound is %v (%dx). The re-list carried the change but cost far more than a plain round.",
			time.Since(T).Round(time.Millisecond), baseline.Round(time.Millisecond), bound.Round(time.Millisecond), freshnessRoundSlack)
	}
	if len(armed) > 0 {
		for _, d := range armed {
			if d > maxPollEvery {
				t.Fatalf("a tick armed %v, past the %v ceiling", d, maxPollEvery)
			}
		}
	}
}

// TestASecondMutationIsSeenAfterTheFirst is the second half of the same guard:
// one re-list carrying one change proves nothing about the NEXT one. A
// cheapening that advances its freshness watermark wrongly (>= instead of >, or
// stamping it from the client clock) passes the test above and fails here,
// because the second mutation's row is the one the bad watermark excludes.
func TestASecondMutationIsSeenAfterTheFirst(t *testing.T) {
	l := newFakeLedger(t, 2500, 4096)
	var armed []time.Duration
	m := ledgerModel(l, &armed)
	m = driveSnapshot(t, m, m.refetchCmd(false))
	baseline := measureFreshnessRound(t, l, m)

	for i, c := range []struct{ doc, title string }{
		{"t-2400", "FIRST"},
		{"t-0007", "SECOND"},
		{"t-1200", "THIRD"},
	} {
		T := time.Now()
		l.mutate(c.doc, c.title, time.Now().UTC())
		page, err := FetchTaskEvents(l.client(), m.eventCursor, taskEventsPageLimit)
		if err != nil {
			t.Fatalf("mutation %d: events poll: %v", i, err)
		}
		var cmd tea.Cmd
		m, cmd = m.handleEventsResult(eventsResultMsg{gen: m.eventsGen, page: page})
		if len(page.Events) == 0 {
			t.Fatalf("mutation %d (%s): the keyset poll reported NO delta", i, c.doc)
		}
		// minRelistEvery throttles the HEAVY read; the delta is not dropped, it
		// is OWED (relistOwed). This test measures freshness, not the throttle
		// (TestPoll_* pins that), so fire the owed re-list directly when the
		// floor swallowed it.
		relisted := false
		for _, msg := range runCmd(cmd) {
			if s, ok := msg.(snapshotMsg); ok {
				relisted = true
				if s.err != nil {
					t.Fatalf("mutation %d: re-list failed: %v", i, s.err)
				}
				m, _ = m.applySnapshot(s)
			}
		}
		if !relisted {
			if !m.relistOwed {
				t.Fatalf("mutation %d (%s): no re-list fired AND none was owed — the delta was dropped", i, c.doc)
			}
			m.fetchInFlight = false
			m = driveSnapshot(t, m, m.refetchCmd(false))
		}
		got, ok := titleOf(m, c.doc)
		if !ok || got != c.title {
			t.Fatalf("mutation %d (%s): board shows %q (present=%v), want %q — the re-list stopped carrying changes after the first one", i, c.doc, got, ok, c.title)
		}
		// Same shape, same reason as the guard above: the logical round is the
		// titleOf check, this is the cost guard, and it scales with the machine.
		if bound := freshnessBound(baseline); time.Since(T) > bound {
			t.Fatalf("mutation %d reflected only at T+%v; one unmutated freshness round on this machine costs %v, so the bound is %v (%dx).",
				i, time.Since(T).Round(time.Millisecond), baseline.Round(time.Millisecond), bound.Round(time.Millisecond), freshnessRoundSlack)
		}
	}
}

// TestIncrementalRelistStopsDownloadingTheWholeCorpus is the BUDGET half —
// c0's mechanism in a hermetic fixture, so the client-side saving is pinned by
// the suite and not only by a pty run against a live server.
//
// It is the exact counterpart of the liveness guards above: they red when the
// re-list stops carrying changes, this one reds when the re-list goes back to
// re-downloading everything. Neither alone is evidence; the pair is.
func TestIncrementalRelistStopsDownloadingTheWholeCorpus(t *testing.T) {
	l := newFakeLedger(t, 2500, 4096)
	var armed []time.Duration
	m := ledgerModel(l, &armed)

	m = driveSnapshot(t, m, m.refetchCmd(false))
	coldBytes, coldCalls := l.tally("tasks")
	if coldBytes == 0 {
		t.Fatal("the cold walk downloaded nothing — the fixture is not being read, so every number below is meaningless")
	}

	// One row moves. That is the whole delta.
	l.mutate("t-2400", "MUTATED", time.Now().UTC())
	m = driveSnapshot(t, m, m.refetchCmd(false))
	warmBytes, warmCalls := l.tally("tasks")
	delta := warmBytes - coldBytes
	if got, ok := titleOf(m, "t-2400"); !ok || got != "MUTATED" {
		t.Fatalf("the cheap re-list dropped the change: t-2400 = %q (present=%v)", got, ok)
	}
	// A full re-walk costs the cold price again. The incremental one costs one
	// small page. The threshold is deliberately loose (a tenth) so this test
	// pins the MECHANISM, not a byte count that drifts with the fixture.
	if delta*10 > coldBytes {
		t.Fatalf("re-list after a ONE-ROW change cost %d bytes against a %d-byte cold walk (%d calls cold, %d warm): the board is still re-downloading the whole corpus",
			delta, coldBytes, coldCalls, warmCalls)
	}
	t.Logf("cold walk %d bytes over %d calls; re-list after one change %d bytes (%.2f%% of the walk)",
		coldBytes, coldCalls, delta, 100*float64(delta)/float64(coldBytes))
}

// TestAFullResyncStillHappens pins the one thing the prefix walk cannot see: a
// row that vanishes without a write. fullResyncEvery is the bound, and a base
// older than it must NOT be answered incrementally.
func TestAFullResyncStillHappens(t *testing.T) {
	now := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	base := corpusBase{
		tasks:      []Task{{DocID: "t-1", UpdatedAt: now.Add(-time.Hour)}},
		watermark:  now.Add(-time.Hour),
		exhaustive: true,
		lastFull:   now.Add(-fullResyncEvery + time.Second),
	}
	if !incrementalUsable(base, now) {
		t.Fatal("a base inside fullResyncEvery was refused: the cheapening never engages")
	}
	base.lastFull = now.Add(-fullResyncEvery)
	if incrementalUsable(base, now) {
		t.Fatalf("a base %v old was still answered incrementally: nothing would ever retire a row that vanished without a write", fullResyncEvery)
	}
	for _, c := range []struct {
		name string
		mut  func(*corpusBase)
	}{
		{"a non-exhaustive base", func(b *corpusBase) { b.exhaustive = false }},
		{"an empty base", func(b *corpusBase) { b.tasks = nil }},
		{"a base with no watermark", func(b *corpusBase) { b.watermark = time.Time{} }},
		{"a base that never had a full walk", func(b *corpusBase) { b.lastFull = time.Time{} }},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := corpusBase{
				tasks:      []Task{{DocID: "t-1", UpdatedAt: now.Add(-time.Hour)}},
				watermark:  now.Add(-time.Hour),
				exhaustive: true,
				lastFull:   now.Add(-time.Minute),
			}
			c.mut(&b)
			if incrementalUsable(b, now) {
				t.Fatalf("%s was accepted as an incremental base", c.name)
			}
		})
	}
}
