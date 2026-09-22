package taskboard

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"
)

// corpus_persist.go makes the incremental re-list's BASE survive the process.
//
// THE DEFECT IT CLOSES (task-58c0d9a3cce11643, the CLI half of
// task-1ca34359dc0805df). corpus.go turned a re-list from "all ~9,000 rows"
// into "the handful that moved" — but only from the SECOND re-list of a
// process onward, because the base it diffs against lived in memory and died
// with the board. Every launch therefore paid the full exhaustive cursor walk
// before it could be cheap. Measured against guerrilla 2026-09-22, one
// back-to-back population: the full walk is 104,880,094 wire bytes, and the
// board's own first 60 seconds were 106,681,901 B — 10.7x the 10 MB bar the
// parent row sets. Every window from t=30s was already under it (worst steady
// window 3,177,124 B; one armed re-list 786,789 B). The cost is ENTIRELY the
// cold walk, and the cold walk is entirely "we threw the corpus away".
//
// WHY THIS FILE AND NOT `?view=board`. The server's board projection
// (api .../params.ex render_board_with_counts) is `:full` with the `content`
// key DELETED, and the board reads `content` on the ROW path, not only in the
// detail pane: criteriaLadder (charter D11) renders one rung per
// content.acceptance_criteria entry, and completenessBadge scores
// content.description / dependencies / design_doc / papers. A board fed
// `?view=board` BEFORE 2026-09-22 would silently lose both on every row.
// THAT HALF IS NOW FIXED (task-9289217dc43ad78f): the projection carries
// `content_digest` — the compact per-criterion marks and the completeness
// booleans — and fetch.go decodes them, so a board fed `?view=board` keeps
// its ladder and its badge. This file is still the right answer to a
// DIFFERENT question: the digest cheapens each walk, while persisting the
// base removes the cold walk. Persisting the base costs NO fidelity at all — the rows it reloads are the exact rows the
// last exhaustive walk decoded.
//
// TWO CONTRACTS, inherited verbatim from cache.go, keep this an optimization
// and never a liability:
//
//   - LOAD is tolerant: a missing, unreadable, truncated, corrupt, wrong-
//     version or oversized file is a MISS, never an error. A miss simply means
//     the next walk is the full one — exactly today's behaviour.
//   - SAVE is best-effort: every failure is swallowed. Persisting must never
//     interrupt the live loop.
//
// STALENESS IS NOT WIDENED. The loaded base carries the lastFull stamp of the
// walk that produced it, and incrementalUsable is unchanged: a base older than
// fullResyncEvery still forces the honest exhaustive walk. So a relaunch
// within the resync window is cheap, and a relaunch outside it is byte-
// identical to main. This file adds no new window in which a row that vanished
// WITHOUT a write could survive on screen.

// corpusFilePrefix namespaces the persisted base inside the shared bp config
// dir, next to (and never colliding with) taskboard-cache-* and
// taskboard-cursor-*.
const corpusFilePrefix = "taskboard-corpus-"

// corpusFileVersion is the on-disk shape's version. A bump makes every older
// file a clean MISS rather than a decode that half-works: the payload is the
// board's own Task/TaskDetail structs, so a field rename must not be able to
// resurrect a half-populated corpus.
const corpusFileVersion = 1

// maxPersistedCorpusBytes caps the COMPRESSED file both ways — refused on
// write, and a miss on read. The corpus is gzipped JSON (live: ~10x on this
// payload), so 64 MiB is far above the live corpus and its job is to stop a
// pathological ledger from filling a home directory or stalling a read.
const maxPersistedCorpusBytes = 64 << 20

// corpusFileName is the on-disk file name for a scope key.
func corpusFileName(key string) string { return corpusFilePrefix + key + ".json.gz" }

// persistedCorpus is the file's shape. Every field of corpusBase that the
// incremental walk reads is carried explicitly — nothing is re-derived on load,
// because a re-derived watermark or a guessed lastFull is exactly the silent
// staleness corpus.go exists to avoid.
type persistedCorpus struct {
	Version    int         `json:"version"`
	Tasks      []Task      `json:"tasks"`
	Details    DetailIndex `json:"details"`
	Watermark  time.Time   `json:"watermark"`
	Exhaustive bool        `json:"exhaustive"`
	LastFull   time.Time   `json:"last_full"`
}

// loadPersistedCorpus reads the persisted base for key from dir. TOLERANT by
// contract: every failure path returns (zero, false).
//
// It also REFUSES a base it could not honestly diff against, at the same three
// gates incrementalUsable uses — not exhaustive, no rows, no watermark — so a
// file written by a future bug cannot seed a hole into a live board.
func loadPersistedCorpus(dir, key string) (corpusBase, bool) {
	if dir == "" {
		return corpusBase{}, false
	}
	raw, err := os.ReadFile(filepath.Join(dir, corpusFileName(key)))
	if err != nil || len(raw) == 0 || int64(len(raw)) > maxPersistedCorpusBytes {
		return corpusBase{}, false
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return corpusBase{}, false
	}
	defer zr.Close()
	plain, err := io.ReadAll(zr)
	if err != nil {
		return corpusBase{}, false
	}
	var p persistedCorpus
	if err := json.Unmarshal(plain, &p); err != nil {
		return corpusBase{}, false
	}
	if p.Version != corpusFileVersion {
		return corpusBase{}, false
	}
	if !p.Exhaustive || len(p.Tasks) == 0 || p.Watermark.IsZero() || p.LastFull.IsZero() {
		return corpusBase{}, false
	}
	return corpusBase{
		tasks:      p.Tasks,
		details:    p.Details,
		watermark:  p.Watermark,
		exhaustive: p.Exhaustive,
		lastFull:   p.LastFull,
	}, true
}

// savePersistedCorpus writes b as the next launch's base. BEST-EFFORT and
// ATOMIC (writeFileAtomic, cache.go): temp file in the same dir, then rename.
//
// A base that would be REFUSED on load is not written — writing one would
// leave a file that can only ever miss, and would overwrite a good base with
// a useless one.
func savePersistedCorpus(dir, key string, b corpusBase) {
	if dir == "" || !b.exhaustive || len(b.tasks) == 0 || b.watermark.IsZero() || b.lastFull.IsZero() {
		return
	}
	plain, err := json.Marshal(persistedCorpus{
		Version:    corpusFileVersion,
		Tasks:      b.tasks,
		Details:    b.details,
		Watermark:  b.watermark,
		Exhaustive: b.exhaustive,
		LastFull:   b.lastFull,
	})
	if err != nil {
		return
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(plain); err != nil {
		return
	}
	if err := zw.Close(); err != nil {
		return
	}
	if int64(buf.Len()) > maxPersistedCorpusBytes {
		return
	}
	writeFileAtomic(dir, corpusFileName(key), buf.Bytes())
}
