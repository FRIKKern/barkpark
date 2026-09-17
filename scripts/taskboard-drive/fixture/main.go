// Command tbfixture is the taskboard-drive hermetic fixture server (charter
// D122, task ttw21-hermetic-drive): a dependency-free stdlib HTTP server that
// serves the task board's LIVE-pinned fetch surface from a fixed, committed
// corpus so drive.sh's churn-independent asserts run byte-deterministic on any
// machine, against no real Barkpark server.
//
// THE LIVE-PINNED SHAPE (the polling shape was REJECTED at decide): exactly
// three endpoints, all 200, streaming on the third —
//
//   - GET …/v1/tasks?limit=1000            → a non-empty {"ok":true,"docs":[…]}
//     render_doc envelope. decodeTaskListFull's envelope fence REFUSES a body
//     without the "docs" key, so the corpus is parsed at startup and the
//     process refuses to boot on a malformed or EMPTY corpus (see mustCorpus).
//   - GET …/v1/tasks/prime?limit=100       → lifecycle counts + recent events +
//     the derived ready head (decodePrime needs counts or an affirmative ok).
//   - GET …/v1/data/listen/<dataset>       → 200 text/event-stream, one
//     "event: welcome" frame, then ": keepalive" comments every 5s, held open.
//     A single welcome frame upgrades the board's ◐ polling → ● live
//     (OnLivePulse), and the held-open stream pins it there stably.
//
// Plus the D115 forward route: GET …/v1/tasks?lifecycle_status=in_progress
// serves the same envelope filtered to in_progress rows — required by the
// board once ttw19-bl-drafts-now-drop merges, cheap to serve unconditionally.
//
// Plus the KEYSET EVENT FEED: GET …/v1/tasks/events?since=<id>&limit=<n> — the
// route the board polls instead of re-listing on a timer (internal/taskboard/
// events.go, task-e2f5ecca0be9a6d1). The fixture serves an EXHAUSTED feed by
// default: whatever `since` is asked for, the answer is
// {"ok":true,"events":[],"cursor":<since>,"has_more":false}. That is not a stub,
// it IS the assertion — a hermetic run has a still corpus, so an honest feed
// says "nothing moved", and the board must therefore issue its list+prime pair
// exactly ONCE (the initial load) for the whole run no matter how long it is
// held open. -emit-event-after <d> flips one event into the feed after d, so the
// harness can also drive the other half of the contract: a delta produces
// exactly one re-list.
//
// GET /__counts returns the per-route request tally as JSON. That is what turns
// "the board polls the feed instead of re-listing" from a claim into a
// measurement drive.sh can assert on.
//
// Paths are matched by SUFFIX (never a hardcoded /w/default/p/default): the
// board issues /v1/tasks flat but the SSE listen rides the workspace/project-
// scoped URL, and the scope segments are config-dependent.
//
// /v1/data/export is DELIBERATELY not served: the export poll only fires on
// the SSE fallback path, so its absence is a tripwire — if the board ever
// degrades to polling under the fixture, the '● live' assert in drive.sh reds
// loudly instead of the fixture quietly absorbing the fallback.
//
// Run: go run ./scripts/taskboard-drive/fixture -addr 127.0.0.1:4799
// (drive.sh builds it to a temp binary so cleanup can kill the exact pid).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// corpusJSON is the fixed task corpus: 32 render_doc envelopes — five epic
// roots with leaf children (the spine's ├─/└─ tree rows drive.sh locates),
// a lifecycle mix (open / in_progress-with-claim / blocked / done), and one
// standalone pair. Titles are unique and stable — they ARE the row identity
// (D118) and appear verbatim in assert transcripts, so never edit one without
// re-recording the committed evidence.
//
// WHY 32 AND NOT 11 (D130, task ttw22-fixture-overflow-enrichment): the
// original 11-doc corpus flattened to ~14 spine lines, which FITS the wide
// board's ~34-row spine window at 130x40. windowSpine (render.go) only paints
// its numbered "↑ N more above" / "↓ N more below" affordances when
// len(spineLines) > avail, so with 11 docs those markers never rendered and
// the D119 marker-CLICK gesture (wideBoardMarkerAt -> moveCursor) could not be
// asserted hermetically at all — the class was live-only by accident of corpus
// size, not by design. The three added sections (bell tower / quarry road /
// salt marsh) push the flattened spine past the window so the overflow markers
// are a boot-time fact of every hermetic run. The floor is MECHANICAL, not a
// comment: mustCorpus refuses to boot below spineOverflowFloor, so shrinking
// the corpus back under the overflow boundary fails loudly instead of quietly
// turning drive.sh's marker asserts into no-ops.
//
// The added rows carry NO churn: fixed ids, fixed timestamps, fixed claims.
// They grow the corpus; they do not make it move.
const corpusJSON = `[
  {"doc_id":"fx-harbor","title":"Harbor lights epic","lifecycle_status":"open","kind":"task","parent_id":"","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":4},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-01T09:00:00Z","updated_at":"2026-08-10T09:00:00Z","content":{"description":"Fixture epic: relight the harbor.","acceptance_criteria":[{"criterion":"north channel dredged","met":true,"evidence":"fixture"},{"criterion":"pier bollards painted","met":false,"evidence":""},{"criterion":"fog bell replaced","met":false,"evidence":""},{"criterion":"old winch retired","met":false,"evidence":""}]}},
  {"doc_id":"fx-hb-dredge","title":"Dredge the north channel","lifecycle_status":"in_progress","kind":"task","parent_id":"fx-harbor","priority":1,"labels":[],"claim":{"worker":"fixture-worker","epoch":3,"ts_iso":"2026-08-10T08:00:00Z"},"criteria_progress":{"met":1,"total":2},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-01T09:01:00Z","updated_at":"2026-08-10T08:00:00Z","content":{"description":"Fixture leaf, claimed and in progress."}},
  {"doc_id":"fx-hb-bollards","title":"Paint the pier bollards","lifecycle_status":"open","kind":"task","parent_id":"fx-harbor","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-01T09:02:00Z","updated_at":"2026-08-05T09:00:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-hb-fogbell","title":"Replace the fog bell","lifecycle_status":"open","kind":"task","parent_id":"fx-harbor","priority":3,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-01T09:03:00Z","updated_at":"2026-08-04T09:00:00Z","content":{"description":"Fixture leaf, open."}},
  {"doc_id":"fx-hb-winch","title":"Retire the old winch","lifecycle_status":"done","kind":"task","parent_id":"fx-harbor","priority":3,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-01T09:04:00Z","updated_at":"2026-08-08T09:00:00Z","content":{"description":"Fixture leaf, done."}},
  {"doc_id":"fx-orchard","title":"Orchard rows epic","lifecycle_status":"open","kind":"task","parent_id":"","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":3},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-02T09:00:00Z","updated_at":"2026-08-09T09:00:00Z","content":{"description":"Fixture epic: plant the orchard."}},
  {"doc_id":"fx-or-graft","title":"Graft the pear stock","lifecycle_status":"open","kind":"task","parent_id":"fx-orchard","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":2},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-02T09:01:00Z","updated_at":"2026-08-06T09:00:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-or-mulch","title":"Mulch the seedling beds","lifecycle_status":"in_progress","kind":"task","parent_id":"fx-orchard","priority":2,"labels":[],"claim":{"worker":"fixture-worker-two","epoch":1,"ts_iso":"2026-08-09T08:30:00Z"},"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-02T09:02:00Z","updated_at":"2026-08-09T08:30:00Z","content":{"description":"Fixture leaf, claimed and in progress."}},
  {"doc_id":"fx-or-net","title":"Net the cherry rows","lifecycle_status":"blocked","kind":"task","parent_id":"fx-orchard","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":1,"dependent_count":0,"inserted_at":"2026-08-02T09:03:00Z","updated_at":"2026-08-07T09:00:00Z","content":{"description":"Fixture leaf, blocked on the graft."}},
  {"doc_id":"fx-shed","title":"Sweep the tool shed","lifecycle_status":"open","kind":"task","parent_id":"","priority":4,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-03T09:00:00Z","updated_at":"2026-08-03T09:00:00Z","content":{"description":"Fixture standalone, open and ready."}},
  {"doc_id":"fx-hinges","title":"Oil the gate hinges","lifecycle_status":"done","kind":"task","parent_id":"","priority":4,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-03T09:05:00Z","updated_at":"2026-08-05T10:00:00Z","content":{"description":"Fixture standalone, done."}},
  {"doc_id":"fx-bt","title":"Bell tower epic","lifecycle_status":"open","kind":"task","parent_id":"","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":3},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:00:00Z","updated_at":"2026-08-04T09:00:00Z","content":{"description":"Fixture epic: rehang the bells."}},
  {"doc_id":"fx-bt-headstock","title":"Recast the cracked headstock","lifecycle_status":"open","kind":"task","parent_id":"fx-bt","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:01:00Z","updated_at":"2026-08-04T09:01:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-bt-louvres","title":"Reslat the belfry louvres","lifecycle_status":"open","kind":"task","parent_id":"fx-bt","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:02:00Z","updated_at":"2026-08-04T09:02:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-bt-rope","title":"Splice the tenor bell rope","lifecycle_status":"in_progress","kind":"task","parent_id":"fx-bt","priority":3,"labels":[],"claim":{"worker":"fixture-worker-bt","epoch":2,"ts_iso":"2026-08-04T08:30:00Z"},"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:03:00Z","updated_at":"2026-08-04T09:03:00Z","content":{"description":"Fixture leaf, claimed and in progress."}},
  {"doc_id":"fx-bt-clapper","title":"Rebush the treble clapper","lifecycle_status":"open","kind":"task","parent_id":"fx-bt","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:04:00Z","updated_at":"2026-08-04T09:04:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-bt-frame","title":"Shim the oak bell frame","lifecycle_status":"open","kind":"task","parent_id":"fx-bt","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:05:00Z","updated_at":"2026-08-04T09:05:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-bt-hatch","title":"Reseal the tower hatch","lifecycle_status":"done","kind":"task","parent_id":"fx-bt","priority":3,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-04T09:06:00Z","updated_at":"2026-08-04T09:06:00Z","content":{"description":"Fixture leaf, done."}},
  {"doc_id":"fx-qr","title":"Quarry road epic","lifecycle_status":"open","kind":"task","parent_id":"","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":3},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:00:00Z","updated_at":"2026-08-05T09:00:00Z","content":{"description":"Fixture epic: reopen the quarry road."}},
  {"doc_id":"fx-qr-culvert","title":"Rebuild the washed culvert","lifecycle_status":"open","kind":"task","parent_id":"fx-qr","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:01:00Z","updated_at":"2026-08-05T09:01:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-qr-verge","title":"Regrade the western verge","lifecycle_status":"open","kind":"task","parent_id":"fx-qr","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:02:00Z","updated_at":"2026-08-05T09:02:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-qr-gate","title":"Rehang the quarry gate","lifecycle_status":"in_progress","kind":"task","parent_id":"fx-qr","priority":3,"labels":[],"claim":{"worker":"fixture-worker-qr","epoch":2,"ts_iso":"2026-08-05T08:30:00Z"},"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:03:00Z","updated_at":"2026-08-05T09:03:00Z","content":{"description":"Fixture leaf, claimed and in progress."}},
  {"doc_id":"fx-qr-signage","title":"Repost the weight-limit signage","lifecycle_status":"open","kind":"task","parent_id":"fx-qr","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:04:00Z","updated_at":"2026-08-05T09:04:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-qr-ditch","title":"Clear the roadside ditch","lifecycle_status":"open","kind":"task","parent_id":"fx-qr","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:05:00Z","updated_at":"2026-08-05T09:05:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-qr-cattlegrid","title":"Relevel the cattle grid","lifecycle_status":"done","kind":"task","parent_id":"fx-qr","priority":3,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-05T09:06:00Z","updated_at":"2026-08-05T09:06:00Z","content":{"description":"Fixture leaf, done."}},
  {"doc_id":"fx-sm","title":"Salt marsh epic","lifecycle_status":"open","kind":"task","parent_id":"","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":3},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:00:00Z","updated_at":"2026-08-06T09:00:00Z","content":{"description":"Fixture epic: reflood the salt marsh."}},
  {"doc_id":"fx-sm-sluice","title":"Rehang the tidal sluice","lifecycle_status":"open","kind":"task","parent_id":"fx-sm","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:01:00Z","updated_at":"2026-08-06T09:01:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-sm-boardwalk","title":"Replank the marsh boardwalk","lifecycle_status":"open","kind":"task","parent_id":"fx-sm","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:02:00Z","updated_at":"2026-08-06T09:02:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-sm-hide","title":"Rebuild the birdwatcher hide","lifecycle_status":"in_progress","kind":"task","parent_id":"fx-sm","priority":3,"labels":[],"claim":{"worker":"fixture-worker-sm","epoch":2,"ts_iso":"2026-08-06T08:30:00Z"},"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:03:00Z","updated_at":"2026-08-06T09:03:00Z","content":{"description":"Fixture leaf, claimed and in progress."}},
  {"doc_id":"fx-sm-saltings","title":"Reseed the upper saltings","lifecycle_status":"open","kind":"task","parent_id":"fx-sm","priority":1,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:04:00Z","updated_at":"2026-08-06T09:04:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-sm-counter","title":"Recalibrate the tide counter","lifecycle_status":"open","kind":"task","parent_id":"fx-sm","priority":2,"labels":[],"claim":null,"criteria_progress":{"met":0,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:05:00Z","updated_at":"2026-08-06T09:05:00Z","content":{"description":"Fixture leaf, open and ready."}},
  {"doc_id":"fx-sm-fence","title":"Retension the stock fence","lifecycle_status":"done","kind":"task","parent_id":"fx-sm","priority":3,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-06T09:06:00Z","updated_at":"2026-08-06T09:06:00Z","content":{"description":"Fixture leaf, done."}}
]`

// primeJSON is the /v1/tasks/prime slice: counts SUMMING to the corpus row
// count (32 — the board's truncation-honesty check compares len(tasks) against
// the summed counts; countsSum below is the mechanical guard that they still
// agree), the derived ready head (open rows with no undone blockers), and a
// short fixed event tail for the activity ticker.
const primeJSON = `{
  "ok": true,
  "counts": {"open": 21, "in_progress": 5, "blocked": 1, "done": 5},
  "ready": [
    {"doc_id": "fx-hb-bollards"},
    {"doc_id": "fx-hb-fogbell"},
    {"doc_id": "fx-or-graft"},
    {"doc_id": "fx-shed"},
    {"doc_id": "fx-bt-headstock"},
    {"doc_id": "fx-bt-louvres"},
    {"doc_id": "fx-bt-clapper"},
    {"doc_id": "fx-bt-frame"},
    {"doc_id": "fx-qr-culvert"},
    {"doc_id": "fx-qr-verge"},
    {"doc_id": "fx-qr-signage"},
    {"doc_id": "fx-qr-ditch"},
    {"doc_id": "fx-sm-sluice"},
    {"doc_id": "fx-sm-boardwalk"},
    {"doc_id": "fx-sm-saltings"},
    {"doc_id": "fx-sm-counter"}
  ],
  "recent_events": [
    {"event": "task.claim", "doc_id": "fx-or-mulch", "at": "2026-08-09T08:30:00Z"},
    {"event": "task.close", "doc_id": "fx-hb-winch", "at": "2026-08-08T09:00:00Z"},
    {"event": "task.claim", "doc_id": "fx-hb-dredge", "at": "2026-08-10T08:00:00Z"}
  ]
}`

// keepaliveEvery paces the SSE comment frames. The live server sends one per
// 30s of quiet; 5s here keeps the liveness signal well inside the board's
// liveStale window for the whole (short) harness run.
const keepaliveEvery = 5 * time.Second

// mustCorpus audits the corpus once at startup and REFUSES to boot on any
// violation auditCorpus reports — a malformed or empty corpus (the board's
// decodeTaskListFull treats a docs-less or blank body as offline, so serving
// one would be the exact silent lie this fixture exists to make impossible),
// a duplicate row identity, a dangling parent, a prime/corpus count mismatch,
// or a corpus shrunk below the overflow floors. It returns the full docs plus
// the in_progress-filtered subset (the D115 route), both as raw messages so
// the served bytes are the committed bytes.
func mustCorpus() (all, inProgress []json.RawMessage) {
	all, inProgress, err := auditCorpus(corpusJSON, primeJSON)
	if err != nil {
		log.Fatalf("tbfixture: %v", err)
	}
	return all, inProgress
}

// The corpus FLOORS (D130, task ttw22-fixture-overflow-enrichment). A floor
// matters because zero is also zero failures: the D119 marker asserts in
// drive.sh can only fire while the flattened spine OVERFLOWS the wide board's
// window, and a shrunk corpus would turn each of them into a silent no-op
// rather than a red. These are deliberately a floor on the corpus SHAPE, not
// arithmetic on spine lines — the fixture does not (and must not) reimplement
// flattenSpine/windowSpine, and section display modes mean a doc does not
// always paint a row, so any line count computed here would be a guess. The
// PAINTED overflow marker is proven where it is visible: drive.sh asserts the
// numbered "↓ N more below" affordance in the wide frame. This guard's job is
// only to make a shrink LOUD at boot instead of quietly disarming that assert.
const (
	corpusFloorDocs     = 32 // the corpus that measurably overflows the spine at 130x40
	corpusFloorSections = 5  // epic roots — sections are what put blank separators in the spine
)

// auditCorpus parses the corpus and the prime slice, ENROLS every document in
// the same walk, and refuses on any violation. It is a predicate over whatever
// the corpus happens to hold, never a hand-kept list of expected ids: add a row
// and it is audited; remove enough rows and the floor refuses.
//
// It returns the full docs plus the in_progress-filtered subset (the D115
// route), both as raw messages so the served bytes are the committed bytes.
func auditCorpus(corpus, prime string) (all, inProgress []json.RawMessage, err error) {
	if err := json.Unmarshal([]byte(corpus), &all); err != nil {
		return nil, nil, fmt.Errorf("corpus does not parse: %w", err)
	}
	if len(all) == 0 {
		return nil, nil, fmt.Errorf("refusing to serve an EMPTY corpus (refuse-empty fence)")
	}
	if len(all) < corpusFloorDocs {
		return nil, nil, fmt.Errorf("corpus has %d docs, floor is %d — below the floor the wide spine stops overflowing and drive.sh's D119 marker asserts silently stop measuring anything", len(all), corpusFloorDocs)
	}

	type doc struct {
		DocID     string `json:"doc_id"`
		Title     string `json:"title"`
		Lifecycle string `json:"lifecycle_status"`
		ParentID  string `json:"parent_id"`
	}
	byID := make(map[string]bool, len(all))
	byTitle := make(map[string]string, len(all))
	parents := make(map[string]int)
	counts := map[string]int{}
	roots := 0
	for i, raw := range all {
		var d doc
		if err := json.Unmarshal(raw, &d); err != nil {
			return nil, nil, fmt.Errorf("corpus doc %d does not parse: %w", i, err)
		}
		if d.DocID == "" || d.Title == "" || d.Lifecycle == "" {
			return nil, nil, fmt.Errorf("corpus doc %d is missing doc_id/title/lifecycle_status", i)
		}
		if byID[d.DocID] {
			return nil, nil, fmt.Errorf("corpus doc_id %q appears twice", d.DocID)
		}
		byID[d.DocID] = true
		// The rendered TITLE is the row identity drive.sh keys every
		// churn-coupled assert on (D118) and line_of_ident takes the FIRST
		// match — two rows sharing a title would make those asserts point at
		// the wrong row, so a duplicate is refused here rather than debugged
		// from a capture-pane frame later.
		if prev, dup := byTitle[d.Title]; dup {
			return nil, nil, fmt.Errorf("corpus title %q is shared by %s and %s — titles ARE the row identity (D118)", d.Title, prev, d.DocID)
		}
		byTitle[d.Title] = d.DocID
		counts[d.Lifecycle]++
		if d.ParentID == "" {
			roots++
		} else {
			parents[d.ParentID]++
		}
		if d.Lifecycle == "in_progress" {
			inProgress = append(inProgress, raw)
		}
	}
	for parent := range parents {
		if !byID[parent] {
			return nil, nil, fmt.Errorf("corpus parent_id %q names no document in the corpus", parent)
		}
	}
	// Epic roots = parented-to-nothing documents that actually have children.
	// The standalone pair (fx-shed / fx-hinges) are roots with no children and
	// paint under the synthetic "(no epic)" section, so they are not sections.
	sections := 0
	for id := range byID {
		if parents[id] > 0 {
			sections++
		}
	}
	if sections < corpusFloorSections {
		return nil, nil, fmt.Errorf("corpus has %d epic sections, floor is %d — sections carry the spine's blank separators and are load-bearing for the overflow", sections, corpusFloorSections)
	}

	// The board's truncation-honesty check compares len(tasks) against the
	// SUMMED prime counts, so a corpus edit that forgets primeJSON makes the
	// board declare itself truncated. Catch it at boot, in the same walk.
	var primeDoc struct {
		Counts map[string]int `json:"counts"`
	}
	if err := json.Unmarshal([]byte(prime), &primeDoc); err != nil {
		return nil, nil, fmt.Errorf("prime slice does not parse: %w", err)
	}
	sum := 0
	for _, n := range primeDoc.Counts {
		sum += n
	}
	if sum != len(all) {
		return nil, nil, fmt.Errorf("prime counts sum to %d but the corpus holds %d docs — the board would report itself truncated", sum, len(all))
	}
	for lifecycle, n := range counts {
		if primeDoc.Counts[lifecycle] != n {
			return nil, nil, fmt.Errorf("prime counts[%q]=%d but the corpus holds %d such docs", lifecycle, primeDoc.Counts[lifecycle], n)
		}
	}
	return all, inProgress, nil
}

func envelope(docs []json.RawMessage) []byte {
	body, err := json.Marshal(struct {
		OK   bool              `json:"ok"`
		Docs []json.RawMessage `json:"docs"`
	}{OK: true, Docs: docs})
	if err != nil {
		log.Fatalf("tbfixture: envelope marshal: %v", err)
	}
	return body
}

func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// serveListen holds the SSE stream open for the life of the client: 200 +
// one welcome frame (upgrades ◐ polling → ● live via OnLivePulse), then a
// keepalive comment every keepaliveEvery until the client goes away.
func serveListen(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, []byte(`{"ok":false,"error":{"type":"no_flush"}}`))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "event: welcome\ndata: {}\n\n")
	flusher.Flush()
	ticker := time.NewTicker(keepaliveEvery)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

// requestLog is the fixture's measurement instrument: a per-route tally the
// harness reads back over GET /__counts. It exists because the board's whole
// contract after task-e2f5ecca0be9a6d1 is about HOW MANY requests it makes, and
// a shape assertion on the rendered pane cannot see that. Guarded by a mutex —
// the SSE stream is held open on its own goroutine while the polls arrive.
type requestLog struct {
	mu sync.Mutex
	n  map[string]int
}

func newRequestLog() *requestLog { return &requestLog{n: map[string]int{}} }

func (l *requestLog) count(route string) {
	l.mu.Lock()
	l.n[route]++
	l.mu.Unlock()
}

func (l *requestLog) snapshot() map[string]int {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make(map[string]int, len(l.n))
	for k, v := range l.n {
		out[k] = v
	}
	return out
}

// eventsBody answers one keyset poll. `cursor` echoes `since` on an empty page —
// the SAME contract the real controller has (tasks_controller.ex events/2 →
// `case rows do [] -> max(since, 0)`), so a caught-up board's poll is idempotent
// and its cursor never moves on its own.
//
// tip is the id of the single synthetic event this fixture will emit once
// -emit-event-after has elapsed (0 = never). Serving it exactly once, on the
// first poll whose since is below it, is what lets drive.sh assert the OTHER
// half of the contract: one delta → exactly one re-list, not one per poll.
func eventsBody(since, tip int64) []byte {
	type ev struct {
		ID    int64  `json:"id"`
		Event string `json:"event"`
		DocID string `json:"doc_id"`
		Rev   string `json:"rev"`
		At    string `json:"at"`
	}
	events := []ev{}
	cursor := since
	if tip > since {
		events = append(events, ev{ID: tip, Event: "task.claim", DocID: "fx-hb-bollards", Rev: "fixture", At: "2026-08-10T09:00:00Z"})
		cursor = tip
	}
	body, err := json.Marshal(struct {
		OK      bool   `json:"ok"`
		Events  []ev   `json:"events"`
		Cursor  int64  `json:"cursor"`
		HasMore bool   `json:"has_more"`
		Note    string `json:"-"`
	}{OK: true, Events: events, Cursor: cursor, HasMore: false})
	if err != nil {
		log.Fatalf("tbfixture: events marshal: %v", err)
	}
	return body
}

func main() {
	addr := flag.String("addr", "127.0.0.1:4799", "listen address")
	emitAfter := flag.Duration("emit-event-after", 0, "emit one task event into /v1/tasks/events after this long (0 = never; the feed stays exhausted)")
	flag.Parse()

	all, inProgress := mustCorpus()
	fullBody := envelope(all)
	inProgressBody := envelope(inProgress)
	logbook := newRequestLog()
	started := time.Now()

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		// Suffix/segment matching ONLY — the listen path rides the
		// workspace/project scope (/w/<ws>/p/<proj>/v1/data/listen/<dataset>)
		// and the scope segments are config-dependent.
		case strings.Contains(path, "/v1/data/listen/"):
			logbook.count("listen")
			serveListen(w, r)
		case strings.HasSuffix(path, "/__counts"):
			body, err := json.Marshal(logbook.snapshot())
			if err != nil {
				writeJSON(w, http.StatusInternalServerError, []byte(`{"ok":false}`))
				return
			}
			writeJSON(w, http.StatusOK, body)
		case strings.HasSuffix(path, "/v1/tasks/events"):
			logbook.count("events")
			since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
			var tip int64
			if *emitAfter > 0 && time.Since(started) >= *emitAfter {
				tip = 1
			}
			writeJSON(w, http.StatusOK, eventsBody(since, tip))
		case strings.HasSuffix(path, "/v1/tasks/prime"):
			logbook.count("prime")
			writeJSON(w, http.StatusOK, []byte(primeJSON))
		case strings.HasSuffix(path, "/v1/tasks"):
			if r.URL.Query().Get("lifecycle_status") == "in_progress" {
				logbook.count("tasks_in_progress")
				writeJSON(w, http.StatusOK, inProgressBody)
				return
			}
			logbook.count("tasks")
			writeJSON(w, http.StatusOK, fullBody)
		default:
			writeJSON(w, http.StatusNotFound, []byte(`{"ok":false,"error":{"type":"not_found","message":"tbfixture serves only the board's live-pinned surface"}}`))
		}
	})

	log.Printf("tbfixture: serving %d docs (%d in_progress) on %s", len(all), len(inProgress), *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
