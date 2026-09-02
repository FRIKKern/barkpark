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

// corpusJSON is the fixed task corpus: 11 render_doc envelopes — two epic
// roots with leaf children (the spine's ├─/└─ tree rows drive.sh locates),
// a lifecycle mix (open / in_progress-with-claim / blocked / done), and one
// standalone pair. Titles are unique and stable — they ARE the row identity
// (D118) and appear verbatim in assert transcripts, so never edit one without
// re-recording the committed evidence.
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
  {"doc_id":"fx-hinges","title":"Oil the gate hinges","lifecycle_status":"done","kind":"task","parent_id":"","priority":4,"labels":[],"claim":null,"criteria_progress":{"met":1,"total":1},"dependency_count":0,"dependent_count":0,"inserted_at":"2026-08-03T09:05:00Z","updated_at":"2026-08-05T10:00:00Z","content":{"description":"Fixture standalone, done."}}
]`

// primeJSON is the /v1/tasks/prime slice: counts SUMMING to the corpus row
// count (11 — the board's truncation-honesty check compares len(tasks) against
// the summed counts), the derived ready head (open rows with no undone
// blockers), and a short fixed event tail for the activity ticker.
const primeJSON = `{
  "ok": true,
  "counts": {"open": 6, "in_progress": 2, "blocked": 1, "done": 2},
  "ready": [
    {"doc_id": "fx-hb-bollards"},
    {"doc_id": "fx-hb-fogbell"},
    {"doc_id": "fx-or-graft"},
    {"doc_id": "fx-shed"}
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

// mustCorpus parses the corpus once at startup and REFUSES to boot on a
// malformed or empty corpus — the board's decodeTaskListFull treats a
// docs-less or blank body as offline, so serving one would be the exact silent
// lie this fixture exists to make impossible. It returns the full docs plus
// the in_progress-filtered subset (the D115 route), both as raw messages so
// the served bytes are the committed bytes.
func mustCorpus() (all, inProgress []json.RawMessage) {
	if err := json.Unmarshal([]byte(corpusJSON), &all); err != nil {
		log.Fatalf("tbfixture: corpus does not parse: %v", err)
	}
	if len(all) == 0 {
		log.Fatal("tbfixture: refusing to serve an EMPTY corpus (refuse-empty fence)")
	}
	for _, raw := range all {
		var probe struct {
			Lifecycle string `json:"lifecycle_status"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			log.Fatalf("tbfixture: corpus doc does not parse: %v", err)
		}
		if probe.Lifecycle == "in_progress" {
			inProgress = append(inProgress, raw)
		}
	}
	return all, inProgress
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
