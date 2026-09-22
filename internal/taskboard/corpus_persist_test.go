package taskboard

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// corpus_persist_test.go is the LAUNCH arm of task-58c0d9a3cce11643.
//
// corpus_base_survives_test.go proves a base survives the flight and a short
// walk. This proves it survives the PROCESS — which is the whole of the launch
// bill: measured against guerrilla 2026-09-22, the board's first 60 seconds
// were 106,681,901 wire bytes against a 10 MB bar, essentially all of it the
// one exhaustive walk every launch paid because the base died with the board.
//
// Both tests drive the real fetchTaskCorpus seam against a byte-counting
// fixture, and both name the mutation that reds them.

// ledgerFixture is a cursor-capable /v1/tasks that COUNTS what it served, split
// by the page size the caller asked for — so "did the incremental head walk
// arm?" is read off the tally rather than inferred.
type ledgerFixture struct {
	srv *httptest.Server

	mu      sync.Mutex
	rows    []map[string]any // newest first (desc:updated_at), mutated by bump()
	bytes   int
	reqs    int
	fullReq int // requests at the 1000-row full-walk page size
	headReq int // requests at the 50-row incremental page size
}

// newLedgerFixture builds n rows, newest first, each carrying a kilobyte of
// content prose — the shape that makes a full walk expensive and a head walk
// cheap. updated_at descends from `at`, one minute apart.
func newLedgerFixture(t *testing.T, n int, at time.Time) *ledgerFixture {
	t.Helper()
	f := &ledgerFixture{}
	prose := make([]byte, 1024)
	for i := range prose {
		prose[i] = 'x'
	}
	for i := 0; i < n; i++ {
		f.rows = append(f.rows, map[string]any{
			"doc_id":           fmt.Sprintf("t-%04d", i),
			"rev":              "r0",
			"title":            fmt.Sprintf("Row %04d", i),
			"lifecycle_status": "open",
			"kind":             "task",
			"updated_at":       at.Add(time.Duration(-i) * time.Minute).Format(time.RFC3339Nano),
			"content": map[string]any{
				"description": string(prose),
				"acceptance_criteria": []map[string]any{
					{"criterion": "c0 " + string(prose), "met": false},
				},
			},
		})
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/tasks", f.serve)
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func (f *ledgerFixture) serve(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 {
		limit = 1000
	}
	off, _ := strconv.Atoi(r.URL.Query().Get("cursor"))

	f.mu.Lock()
	rows := make([]map[string]any, len(f.rows))
	copy(rows, f.rows)
	f.mu.Unlock()

	end := off + limit
	if end > len(rows) {
		end = len(rows)
	}
	page := map[string]any{"next_cursor": nil}
	if end < len(rows) {
		page["next_cursor"] = strconv.Itoa(end)
	}
	body, _ := json.Marshal(map[string]any{"ok": true, "docs": rows[off:end], "page": page})

	f.mu.Lock()
	f.bytes += len(body)
	f.reqs++
	switch limit {
	case taskListLimit:
		f.fullReq++
	case headPageLimit:
		f.headReq++
	}
	f.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func (f *ledgerFixture) client() *apiclient.Client {
	return apiclient.New(apiclient.Config{BaseURL: f.srv.URL})
}

// bump re-stamps one row's updated_at and title and rotates it to the head,
// exactly as a write does on a desc:updated_at route.
func (f *ledgerFixture) bump(docID, title string, at time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i, r := range f.rows {
		if r["doc_id"] != docID {
			continue
		}
		r["title"] = title
		r["rev"] = "r1"
		r["updated_at"] = at.Format(time.RFC3339Nano)
		f.rows = append(append([]map[string]any{r}, f.rows[:i]...), f.rows[i+1:]...)
		return
	}
	panic("bump: no such row " + docID)
}

func (f *ledgerFixture) tally() (bytes, reqs, full, head int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bytes, f.reqs, f.fullReq, f.headReq
}

func (f *ledgerFixture) reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.bytes, f.reqs, f.fullReq, f.headReq = 0, 0, 0, 0
}

// TestTheCorpusBaseSurvivesTheProcess is the before/after of the launch bill,
// measured on the SAME fixture in the same test so the two figures are
// comparable by construction.
//
// REDS ON: removing the disk seed in corpusCache.baseForWalk, or the
// savePersistedCorpus call in fetchTaskCorpusWalk's exhaustive arm. Either way
// the second process pays the full walk again and the byte assertion fires with
// both numbers in the message.
func TestTheCorpusBaseSurvivesTheProcess(t *testing.T) {
	dir := t.TempDir()
	const key = "scopekey"
	at := time.Date(2026, 9, 22, 7, 0, 0, 0, time.UTC)
	f := newLedgerFixture(t, 1200, at)
	c := f.client()

	// ── process 1: the cold launch every launch used to be ──────────────────
	now := time.Now()
	cc1 := &corpusCache{live: true, persistDir: dir, persistKey: key}
	tasks, _, exh, err := fetchTaskCorpus(context.Background(), c, cc1, now)
	if err != nil || !exh {
		t.Fatalf("precondition failed: the cold walk returned exhaustive=%v err=%v, want a complete walk", exh, err)
	}
	if len(tasks) != 1200 {
		t.Fatalf("precondition failed: the cold walk returned %d rows, want 1200", len(tasks))
	}
	coldBytes, _, coldFull, coldHead := f.tally()
	if coldFull == 0 {
		t.Fatalf("precondition failed: the cold walk issued %d full-page requests, want at least one — this test measures the wrong thing", coldFull)
	}
	if coldHead != 0 {
		t.Fatalf("precondition failed: the cold walk issued %d head-page requests; it was not a cold walk", coldHead)
	}
	if coldBytes < 1_000_000 {
		t.Fatalf("precondition failed: the cold walk served %d bytes, too small for the saving below to mean anything", coldBytes)
	}

	// PRECONDITION on the artifact itself, printed as a key set rather than
	// inferred from a later pass: an absent file makes every assertion below a
	// statement about the FULL walk path, not about the seed.
	if _, ok := loadPersistedCorpus(dir, key); !ok {
		t.Fatal("precondition failed: the exhaustive walk wrote no readable base to disk, so process 2 below has nothing to seed from and its verdict would be about the cold path")
	}

	// ── process 2: a BRAND NEW cache — the next `bp tasks` launch ───────────
	f.reset()
	cc2 := &corpusCache{live: true, persistDir: dir, persistKey: key}
	tasks2, details2, exh2, err := fetchTaskCorpus(context.Background(), c, cc2, now.Add(time.Second))
	if err != nil {
		t.Fatalf("launch walk: %v", err)
	}
	warmBytes, _, warmFull, warmHead := f.tally()

	if !exh2 {
		t.Fatalf("the seeded launch walk reported exhaustive=false: a base loaded from disk must carry its own exhaustiveness, or mergeForward's absence heuristic stays armed for rows the walk did see")
	}
	if warmFull != 0 {
		t.Fatalf("the launch walk still issued %d FULL-page requests: the persisted base did not arm the incremental path, so this launch pays the whole corpus again (%d bytes, against %d cold)", warmFull, warmBytes, coldBytes)
	}
	if warmHead == 0 {
		t.Fatalf("the launch walk issued no head-page requests at all (%d requests total): it did not take the incremental path", warmHead)
	}
	if warmBytes >= coldBytes/10 {
		t.Fatalf("the launch walk served %d bytes against the cold walk's %d — less than the 10x the persisted base exists to buy", warmBytes, coldBytes)
	}
	// Fidelity is the other half: the seeded walk must return the WHOLE corpus,
	// not just the prefix it re-read, and the retained rows must keep the detail
	// the last process decoded for them.
	if len(tasks2) != 1200 {
		t.Fatalf("the seeded walk returned %d rows, want the full 1200: the base was loaded but not merged forward", len(tasks2))
	}
	if d, ok := details2["t-1100"]; !ok || d.Description == "" {
		t.Fatalf("a row retained from the persisted base has no detail (present=%v): the persisted base must carry the DetailIndex, or every untouched row's pane goes thin after a relaunch", ok)
	}
	if got := tasks2[0].CriteriaItems; len(got) != 1 {
		t.Fatalf("a retained row lost its decoded acceptance_criteria (%d items): the board's criteria ladder (charter D11) is drawn from them", len(got))
	}

	t.Logf("launch window: cold walk %d B over %d full pages; seeded launch %d B over %d head pages", coldBytes, coldFull, warmBytes, warmHead)
}

// TestASeededBoardStillNoticesAChangeWithinOnePoll is criterion 2's
// change-noticing arm, and it is the risk this whole PR creates: a board that
// starts from a FILE could start from a stale world and keep showing it.
//
// A mutation lands at T; the walk the poll loop fires one basePollEvery later
// must return it. The interval is not assumed — nextPollInterval is asked for
// the post-delta cadence, so the "within 2s" in the criterion is the schedule
// the code actually arms rather than a number this test invented.
//
// REDS ON: removing the `!t.UpdatedAt.After(base.watermark)` boundary check's
// effect by seeding a base with a watermark at or ahead of the mutation — i.e.
// on any change that makes the seeded base authoritative over the head walk.
// The control arm below proves the assertion can fail.
func TestASeededBoardStillNoticesAChangeWithinOnePoll(t *testing.T) {
	dir := t.TempDir()
	const key = "scopekey"
	at := time.Date(2026, 9, 22, 7, 0, 0, 0, time.UTC)
	f := newLedgerFixture(t, 300, at)
	c := f.client()

	now := time.Now()
	cc1 := &corpusCache{live: true, persistDir: dir, persistKey: key}
	if _, _, exh, err := fetchTaskCorpus(context.Background(), c, cc1, now); err != nil || !exh {
		t.Fatalf("precondition failed: seeding walk exhaustive=%v err=%v", exh, err)
	}
	if _, ok := loadPersistedCorpus(dir, key); !ok {
		t.Fatal("precondition failed: no base on disk, so the board below is not a SEEDED board and this test measures the cold path")
	}

	// THE POLL CADENCE, read from the code rather than written down here: a
	// board that just saw a delta re-polls at basePollEvery.
	interval := nextPollInterval(maxPollEvery, true)
	if interval != basePollEvery {
		t.Fatalf("precondition failed: nextPollInterval after a delta is %v, not basePollEvery (%v) — the window this test asserts is not the one the loop arms", interval, basePollEvery)
	}

	// T: the ledger moves. The row rotates to the head with a NEWER updated_at.
	mutationAt := at.Add(time.Hour)
	f.bump("t-0200", "MOVED AT T", mutationAt)

	// T + one basePollEvery: the launch's first walk, on a brand-new cache that
	// can only know the world through the file.
	cc2 := &corpusCache{live: true, persistDir: dir, persistKey: key}
	tasks, details, _, err := fetchTaskCorpus(context.Background(), c, cc2, now.Add(interval))
	if err != nil {
		t.Fatalf("poll walk: %v", err)
	}
	var seen string
	for _, tk := range tasks {
		if tk.DocID == "t-0200" {
			seen = tk.Title
		}
	}
	if seen != "MOVED AT T" {
		t.Fatalf("a mutation at T was NOT reflected by T+%v: the seeded board reports t-0200 as %q, want %q — a base loaded from disk must never make the head walk blind to a row that moved after it was written", interval, seen, "MOVED AT T")
	}
	if d, ok := details[t0200]; !ok || d.Task.Title != "MOVED AT T" {
		t.Fatalf("the detail index kept the STALE copy of the moved row (present=%v title=%q): fresh rows must win over the retained base in both containers", ok, d.Task.Title)
	}

	// THE CONTROL. Same fixture, same walk — but the base on disk is re-written
	// with a watermark AHEAD of the mutation, which is exactly what a seeded
	// base that lied about its freshness would look like. The assertion above
	// MUST fail here, or it is not measuring the boundary at all.
	stale, ok := loadPersistedCorpus(dir, key)
	if !ok {
		t.Fatal("control setup failed: the base vanished")
	}
	stale.watermark = mutationAt.Add(time.Hour)
	savePersistedCorpus(dir, key, stale)
	cc3 := &corpusCache{live: true, persistDir: dir, persistKey: key}
	controlTasks, _, _, err := fetchTaskCorpus(context.Background(), c, cc3, now.Add(interval))
	if err != nil {
		t.Fatalf("control walk: %v", err)
	}
	controlSeen := ""
	for _, tk := range controlTasks {
		if tk.DocID == "t-0200" {
			controlSeen = tk.Title
		}
	}
	if controlSeen == "MOVED AT T" {
		t.Fatal("the CONTROL passed: a base whose watermark is an hour AHEAD of the mutation still reported the moved row, so the assertion above cannot fail and proves nothing about the watermark boundary")
	}
}

const t0200 = "t-0200"
