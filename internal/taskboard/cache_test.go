package taskboard

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// sampleSnapshot is a small, fully-populated snapshot for round-trip tests: it
// exercises every JSON-bearing corner of the frozen Snapshot type (a claim
// pointer, a criteria pointer, labels, counts, an event, and — the honest
// staleness field — FetchedAt) so a marshal/unmarshal regression on any of them
// fails here.
func sampleSnapshot() Snapshot {
	return Snapshot{
		Tasks: []Task{
			{
				DocID:     "a1",
				Title:     "Reconcile the role seam",
				Lifecycle: lifeInProgress,
				Kind:      "task",
				Labels:    []string{"area:tui", "proj:board"},
				Claim:     &Claim{Worker: "opus-3", Epoch: 4, ClaimedAt: time.Date(2026, 7, 3, 11, 40, 0, 0, time.UTC)},
				Criteria:  &Criteria{Met: 2, Total: 3},
				UpdatedAt: time.Date(2026, 7, 3, 11, 55, 0, 0, time.UTC),
			},
			{DocID: "b2", Title: "Wire the cache", Lifecycle: lifeReady},
		},
		Counts:           map[string]int{"in_progress": 1, "ready": 1, "done": 7},
		Events:           []Event{{Mutation: "task.claimed", DocID: "a1", At: time.Date(2026, 7, 3, 11, 40, 0, 0, time.UTC)}},
		ReadyHeadClamped: true,
		FetchedAt:        time.Date(2026, 7, 3, 11, 58, 0, 0, time.UTC),
	}
}

// TestCacheRoundTrip proves a saved snapshot loads back byte-faithful, with the
// FetchedAt stamp intact — staleness is only honest if the cached fetch time
// survives the round trip.
func TestCacheRoundTrip(t *testing.T) {
	dir := t.TempDir()
	key := cacheKey("https://guerrilla.barkpark.cloud", "gyldendal", "prod", "production")
	want := sampleSnapshot()

	SaveCachedSnapshot(dir, key, want)
	got, ok := LoadCachedSnapshot(dir, key)
	if !ok {
		t.Fatal("LoadCachedSnapshot missed a snapshot we just saved")
	}
	if !got.FetchedAt.Equal(want.FetchedAt) {
		t.Errorf("FetchedAt round-trip = %v, want %v", got.FetchedAt, want.FetchedAt)
	}
	if len(got.Tasks) != 2 || got.Tasks[0].DocID != "a1" || got.Tasks[1].DocID != "b2" {
		t.Errorf("tasks did not round-trip: %+v", got.Tasks)
	}
	if got.Tasks[0].Claim == nil || got.Tasks[0].Claim.Epoch != 4 {
		t.Errorf("claim pointer did not round-trip: %+v", got.Tasks[0].Claim)
	}
	if got.Tasks[0].Criteria == nil || got.Tasks[0].Criteria.Total != 3 {
		t.Errorf("criteria pointer did not round-trip: %+v", got.Tasks[0].Criteria)
	}
	if !got.ReadyHeadClamped {
		t.Error("ReadyHeadClamped did not round-trip")
	}
	if got.Counts["done"] != 7 {
		t.Errorf("counts did not round-trip: %+v", got.Counts)
	}
	if len(got.Events) != 1 || got.Events[0].Mutation != "task.claimed" {
		t.Errorf("events did not round-trip: %+v", got.Events)
	}
}

// TestCacheLoadMissesAreSilent proves every failure mode is a clean (zero,
// false) MISS, never an error surface: an empty dir, an absent file, a corrupt
// (non-JSON) file, and a truncated (half-written) file.
func TestCacheLoadMissesAreSilent(t *testing.T) {
	dir := t.TempDir()
	key := cacheKey("s", "w", "p", "d")

	if _, ok := LoadCachedSnapshot("", key); ok {
		t.Error("empty dir should miss")
	}
	if _, ok := LoadCachedSnapshot(dir, key); ok {
		t.Error("absent file should miss")
	}

	path := filepath.Join(dir, cacheFileName(key))
	if err := os.WriteFile(path, []byte("this is not json {{{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := LoadCachedSnapshot(dir, key); ok {
		t.Error("corrupt file should miss, not parse")
	}

	// A truncated write: valid JSON prefix, cut mid-object. Must miss, not panic.
	if err := os.WriteFile(path, []byte(`{"Tasks":[{"DocID":"a1","Ti`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := LoadCachedSnapshot(dir, key); ok {
		t.Error("truncated file should miss")
	}
}

// TestCacheSaveIsAtomicAndLeavesNoDroppings proves a successful save leaves
// EXACTLY the one final cache file in the dir — no *.tmp-* temp file survives.
func TestCacheSaveIsAtomicAndLeavesNoDroppings(t *testing.T) {
	dir := t.TempDir()
	key := cacheKey("s", "w", "p", "d")

	SaveCachedSnapshot(dir, key, sampleSnapshot())

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("dir has %d entries %v, want exactly the one cache file", len(entries), names)
	}
	if entries[0].Name() != cacheFileName(key) {
		t.Errorf("stray file left behind: %q, want %q", entries[0].Name(), cacheFileName(key))
	}
	// A re-save over an existing cache is idempotent and still leaves no temp.
	SaveCachedSnapshot(dir, key, sampleSnapshot())
	entries, _ = os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("re-save left %d entries, want 1", len(entries))
	}
}

// TestCacheSaveEmptyDirIsNoOp proves SaveCachedSnapshot("") is a silent no-op
// (the config-dir-unresolvable path) rather than writing to the cwd.
func TestCacheSaveEmptyDirIsNoOp(t *testing.T) {
	// No panic, no error, nothing to assert beyond "does not blow up" — an empty
	// dir must simply do nothing.
	SaveCachedSnapshot("", "k", sampleSnapshot())
}

// TestCacheKeyStableAndDistinct proves the key is deterministic for a scope and
// distinct across every axis — server, workspace, project, dataset (D125) — AND
// that the NUL separator stops adjacent fields from colliding ("ab"+"" vs
// "a"+"b").
func TestCacheKeyStableAndDistinct(t *testing.T) {
	base := cacheKey("https://guerrilla", "gyldendal", "prod", "production")
	if base != cacheKey("https://guerrilla", "gyldendal", "prod", "production") {
		t.Error("cacheKey is not stable for the same scope")
	}
	if len(base) != 16 {
		t.Errorf("cacheKey len = %d, want 16 (short hex)", len(base))
	}
	distinct := map[string]string{
		"other server":    cacheKey("https://other", "gyldendal", "prod", "production"),
		"other workspace": cacheKey("https://guerrilla", "aschehoug", "prod", "production"),
		"other project":   cacheKey("https://guerrilla", "gyldendal", "staging", "production"),
		"other dataset":   cacheKey("https://guerrilla", "gyldendal", "prod", "staging"),
		"field-boundary":  cacheKey("https://guerrillagyldendal", "", "prod", "production"),
		// A dataset field-boundary: "prod"+"" (project prod, empty dataset) must
		// not collide with ""+"prod" (empty project, dataset prod) — the NUL
		// between project and dataset is what keeps them apart.
		"dataset field-boundary": cacheKey("https://guerrilla", "gyldendal", "", "prod"),
	}
	for name, k := range distinct {
		if k == base {
			t.Errorf("cacheKey collided with base for %s", name)
		}
	}
	// The project↔dataset boundary: the SAME "prod" string sliding across the NUL
	// (project "prod" + empty dataset vs empty project + dataset "prod") must
	// change the hash, or the separator between those two fields is doing nothing.
	if cacheKey("https://guerrilla", "gyldendal", "prod", "") ==
		cacheKey("https://guerrilla", "gyldendal", "", "prod") {
		t.Error("cacheKey lost the project↔dataset boundary: project \"prod\" collided with dataset \"prod\"")
	}
	// The field-boundary case must ALSO differ from its own naive concat twin.
	if cacheKey("ab", "", "c", "d") == cacheKey("a", "b", "c", "d") {
		t.Error("cacheKey lost the field boundary: \"ab\"+\"\" collided with \"a\"+\"b\"")
	}
}

func TestLegacyCacheMigratesWithoutBlankFirstPaint(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		BaseURL:   "https://guerrilla.barkpark.cloud",
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
		CacheDir:  dir,
	}
	cached := Snapshot{
		Tasks:     []Task{{DocID: "still-here", Title: "Cached task", Lifecycle: lifeOpen}},
		Counts:    map[string]int{lifeOpen: 1},
		FetchedAt: fixedNow,
	}
	SaveCachedSnapshot(dir, legacyCacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project), cached)

	m := newModel(nil, "", cfg)
	if _, ok := m.taskByID("still-here"); !ok {
		t.Fatal("dataset-key upgrade discarded the legacy cached task")
	}
	if _, ok := LoadCachedSnapshot(dir, cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project, cfg.Dataset)); !ok {
		t.Fatal("legacy cache was not migrated to the dataset-scoped key")
	}
}

// TestCachePrimedStartIsHonestAndDoesNotFlash is the model-level proof of the
// two first-paint contracts (charter decisions #9 and #20):
//
//	(a) A cache-primed start paints real rows immediately, reads the honest
//	    last-synced age, and NEVER claims the cached data is live.
//	(b) The first LIVE snapshot after a cache-primed start swaps truth in
//	    cleanly — it is NOT dropped by the out-of-order guard (the cached, older
//	    LastSync must not shadow it) and seeds no false change-highlight, because
//	    priming records no diff baseline (there is no prev-task state to flash
//	    against — the flash contract in primeFromCache).
func TestCachePrimedStartIsHonestAndDoesNotFlash(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{BaseURL: "https://guerrilla", Workspace: "gyldendal", Project: "prod", CacheDir: dir}

	// Seed the cache as if a previous session had saved it, 5m before "now".
	cachedAt := fixedNow.Add(-5 * time.Minute)
	cached := Snapshot{
		Tasks:     []Task{{DocID: "cached-1", Title: "Cached ready task", Lifecycle: lifeReady, UpdatedAt: cachedAt}},
		Counts:    map[string]int{"ready": 1},
		FetchedAt: cachedAt,
	}
	SaveCachedSnapshot(dir, cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project, cfg.Dataset), cached)

	// (a) A fresh model for this scope must paint from that cache.
	m := newModel(nil, "", cfg)
	m.now = func() time.Time { return fixedNow }

	if got := len(m.visibleRows()); got == 0 {
		t.Fatal("cache-primed start painted an empty board — first paint was blank")
	}
	if _, ok := m.taskByID("cached-1"); !ok {
		t.Fatal("cache-primed board is missing the cached task")
	}
	if m.ui.Conn == ConnLive {
		t.Fatal("cache-primed start claims ConnLive — cached data must never read as live")
	}
	if !m.ui.LastSync.Equal(cachedAt) {
		t.Fatalf("cache-primed LastSync = %v, want cached FetchedAt %v", m.ui.LastSync, cachedAt)
	}
	frame := ansi.Strip(Render(m.board, m.ui, 80, 24, fixedNow))
	if strings.Contains(frame, " live") {
		t.Errorf("cache-primed frame claims live:\n%s", frame)
	}
	if !strings.Contains(frame, "polling") {
		t.Errorf("cache-primed frame is not honestly polling:\n%s", frame)
	}
	if !strings.Contains(frame, "· 5m") {
		t.Errorf("cache-primed frame missing the honest last-synced age:\n%s", frame)
	}

	// (b) The first live snapshot (newer FetchedAt) must swap truth in — not be
	// dropped as "older than what's on screen" by the out-of-order guard.
	live := Snapshot{
		Tasks: []Task{
			{DocID: "cached-1", Title: "Cached ready task", Lifecycle: lifeReady, UpdatedAt: fixedNow},
			{DocID: "live-2", Title: "Brand-new live task", Lifecycle: lifeReady, UpdatedAt: fixedNow},
		},
		Counts:    map[string]int{"ready": 2},
		FetchedAt: fixedNow,
	}
	m, _ = step(t, m, snapshotMsg{snap: live})

	if !m.ui.LastSync.Equal(fixedNow) {
		t.Fatalf("first live snapshot was DROPPED: LastSync still %v, want %v (cached LastSync shadowed live truth)",
			m.ui.LastSync, fixedNow)
	}
	if _, ok := m.taskByID("live-2"); !ok {
		t.Error("first live snapshot did not swap in the new task — cache shadowed live truth")
	}
	// Priming did NOT go through applySnapshot, so no prev-task diff baseline was
	// seeded: the flash contract (decision #20) holds structurally. If a future
	// pulse/decay slice adds such a field, primeFromCache must keep leaving it
	// empty (see its FLASH CONTRACT comment) or this scenario would false-flash
	// every row on the first live frame.
}

// TestCachePrimedStartSurvivesBackwardsClockJump pins the nastiest cache edge:
// the previous session saved its snapshot under a wall clock AHEAD of this
// session's (NTP step, VM resume, manual clock change), so the cached FetchedAt
// is in this session's FUTURE. The out-of-order guard must compare against
// snapshots applied THIS session only (lastAppliedFetch), never the on-disk
// stamp — otherwise every live fetch (including each 30s backstop, stamped from
// the same skewed clock) would read as "older than what's on screen" and be
// dropped, freezing the board on stale cached rows until real time caught up
// with the bogus stamp. Live truth always beats the file.
func TestCachePrimedStartSurvivesBackwardsClockJump(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{BaseURL: "https://guerrilla", Workspace: "gyldendal", Project: "prod", CacheDir: dir}

	// The cache claims it was fetched an hour in this session's future.
	cachedAt := fixedNow.Add(time.Hour)
	cached := Snapshot{
		Tasks:     []Task{{DocID: "stale-1", Title: "Task from the skewed session", Lifecycle: lifeReady, UpdatedAt: cachedAt}},
		Counts:    map[string]int{"ready": 1},
		FetchedAt: cachedAt,
	}
	SaveCachedSnapshot(dir, cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project, cfg.Dataset), cached)

	m := newModel(nil, "", cfg)
	m.now = func() time.Time { return fixedNow }
	if _, ok := m.taskByID("stale-1"); !ok {
		t.Fatal("cache-primed board is missing the cached task")
	}

	// The first live snapshot carries an HONEST stamp — this session's clock,
	// which sits before the cache's skewed one. It must still be applied.
	live := Snapshot{
		Tasks:     []Task{{DocID: "live-1", Title: "Live truth", Lifecycle: lifeReady, UpdatedAt: fixedNow}},
		Counts:    map[string]int{"ready": 1},
		FetchedAt: fixedNow,
	}
	m, _ = step(t, m, snapshotMsg{snap: live})

	if _, ok := m.taskByID("live-1"); !ok {
		t.Fatal("live snapshot dropped: the future-stamped cache out-ranked live truth (board frozen on stale rows)")
	}
	if _, ok := m.taskByID("stale-1"); ok {
		t.Error("stale cached task survived the live swap")
	}
	if !m.ui.LastSync.Equal(fixedNow) {
		t.Errorf("LastSync = %v, want the live stamp %v", m.ui.LastSync, fixedNow)
	}

	// And the guard still works intra-session: a slower, genuinely older frame
	// from THIS session must be dropped as before.
	older := Snapshot{
		Tasks:     []Task{{DocID: "straggler", Lifecycle: lifeReady}},
		FetchedAt: fixedNow.Add(-10 * time.Second),
	}
	m, _ = step(t, m, snapshotMsg{snap: older})
	if _, ok := m.taskByID("straggler"); ok {
		t.Error("intra-session out-of-order frame was applied — the rollback guard regressed")
	}
}
