package taskboard

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// FetchSnapshot composes the board's raw state from the two proven task
// endpoints in a single Snapshot:
//
//   - GET /v1/tasks?limit=1000 supplies the full task corpus (render_doc
//     envelopes: doc_id, title, lifecycle_status, kind, parent_id, priority,
//     labels, claim, criteria_progress, dependency/dependent counts, timestamps).
//   - GET /v1/tasks/prime supplies the lifecycle counts, the recent task.%
//     mutation events for the activity ticker, and the engine's READY QUEUE.
//
// The ready queue is load-bearing: storage never holds lifecycle "ready" (the
// stored enum is open|in_progress|blocked|done|cancelled) — readiness is
// derived server-side (lifecycle open|blocked + every blocks-edge done), so
// composeSnapshot overlays it from prime's ready head. Without the overlay the
// board's ready band would be permanently empty against a live server.
//
// The task routes are mounted at the host's TOP-LEVEL /v1 scope (tenancy rides
// the bearer token), so the paths are joined onto BaseURL directly — NOT the
// workspace/project-scoped URL. Both fetches are required: a partial board
// would silently drop counts, readiness and the ticker, so any failure is
// returned as an error and the caller (the tea shell) renders its honest
// degraded state.
//
// Truncation honesty: the list endpoint clamps at 1000 rows. Snapshot carries
// the full lifecycle Counts from prime, so a renderer can detect a truncated
// corpus by comparing len(Tasks) against the summed Counts and say so instead
// of quietly showing a partial board.
//
// FetchSnapshot is the IO boundary, so it stamps FetchedAt from the wall clock;
// the pure BuildBoard downstream takes its "now" as an explicit parameter.
func FetchSnapshot(c *apiclient.Client) (Snapshot, error) {
	tasks, err := fetchTaskList(c)
	if err != nil {
		return Snapshot{}, err
	}
	extras, err := fetchPrime(c)
	if err != nil {
		return Snapshot{}, err
	}
	return composeSnapshot(tasks, extras, time.Now().UTC()), nil
}

// composeSnapshot is the pure composition step: it marks the tasks named by
// prime's ready queue with the derived "ready" lifecycle and assembles the
// Snapshot. The overlay only upgrades a task whose stored lifecycle is
// open|blocked — the engine's own readiness precondition — so a row that moved
// (claimed, closed) between the two fetches can never be mislabelled ready.
func composeSnapshot(tasks []Task, extras primeExtras, fetchedAt time.Time) Snapshot {
	for i := range tasks {
		if !extras.readyIDs[tasks[i].DocID] {
			continue
		}
		if tasks[i].Lifecycle == lifeOpen || tasks[i].Lifecycle == lifeBlocked {
			tasks[i].Lifecycle = lifeReady
		}
	}
	return Snapshot{
		Tasks:     tasks,
		Counts:    extras.counts,
		Events:    extras.events,
		FetchedAt: fetchedAt,
	}
}

// getJSON issues an authenticated GET to a top-level path, reusing the Client's
// configured http.Client and bearer token (via the public GetConditional
// helper, called with no If-None-Match so it always fetches the body). It does
// not modify apiclient. Every error carries the path, and a non-200 carries the
// status plus a one-line body hint, so the shell's degraded banner can say
// WHICH call failed and why ("GET /v1/tasks/prime: status 401: …").
func getJSON(c *apiclient.Client, path string) ([]byte, error) {
	res, err := c.GetConditional(c.BaseURL()+path, "")
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", path, err)
	}
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: status %d%s", path, res.StatusCode, bodyHint(res.Body))
	}
	return res.Body, nil
}

// bodyHint condenses an error body into a short single-line ": …" suffix so a
// 401/403 explains itself without ever dumping a page of HTML into a one-line
// status banner. Empty body -> empty hint.
func bodyHint(body []byte) string {
	s := strings.Join(strings.Fields(string(body)), " ")
	if s == "" {
		return ""
	}
	const max = 120
	if len(s) > max {
		s = s[:max] + "…"
	}
	return ": " + s
}

func fetchTaskList(c *apiclient.Client) ([]Task, error) {
	body, err := getJSON(c, "/v1/tasks?limit=1000")
	if err != nil {
		return nil, err
	}
	return decodeTaskList(body)
}

// fetchPrime asks for prime at limit=100 — the server's clamp maximum — which
// buys the deepest ready head and event tail one call allows. The ticker only
// renders a short tail, but the ready overlay wants every claimable row it can
// get (past 100 ready rows the overlay covers the top of the queue only).
func fetchPrime(c *apiclient.Client) (primeExtras, error) {
	body, err := getJSON(c, "/v1/tasks/prime?limit=100")
	if err != nil {
		return primeExtras{}, err
	}
	return decodePrime(body)
}

// decodeTaskList turns a {"ok":…,"docs":[…]} list body into board Tasks.
func decodeTaskList(body []byte) ([]Task, error) {
	var env struct {
		Docs []taskWire `json:"docs"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode tasks list: %w", err)
	}
	tasks := make([]Task, 0, len(env.Docs))
	for _, w := range env.Docs {
		tasks = append(tasks, w.toTask())
	}
	return tasks, nil
}

// primeExtras is the slice of /v1/tasks/prime the board consumes: the
// lifecycle counts (stored statuses only — "ready" never appears as a count
// key), the activity-ticker events, and the doc_ids of the derived ready
// queue that composeSnapshot overlays.
type primeExtras struct {
	counts   map[string]int
	events   []Event
	readyIDs map[string]bool
}

// decodePrime pulls the counts, recent events and ready-queue ids out of a
// prime body. The ready entries are full render_docs on the wire; only their
// doc_id matters here — the authoritative task rows come from the list fetch.
func decodePrime(body []byte) (primeExtras, error) {
	var env struct {
		Counts       map[string]int `json:"counts"`
		RecentEvents []eventWire    `json:"recent_events"`
		Ready        []struct {
			DocID string `json:"doc_id"`
		} `json:"ready"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return primeExtras{}, fmt.Errorf("decode prime: %w", err)
	}
	extras := primeExtras{
		counts:   env.Counts,
		events:   make([]Event, 0, len(env.RecentEvents)),
		readyIDs: make(map[string]bool, len(env.Ready)),
	}
	for _, e := range env.RecentEvents {
		extras.events = append(extras.events, Event{Mutation: e.Event, DocID: e.DocID, At: e.At})
	}
	for _, r := range env.Ready {
		extras.readyIDs[r.DocID] = true
	}
	return extras, nil
}

// taskWire is the render_doc envelope shape. lifecycle_status, kind and
// parent_id sit at the top level (the controller lifts them out of content);
// priority is decoded permissively because content.priority is an integer 0..4
// on the wire while the board carries it as a display string.
type taskWire struct {
	DocID           string          `json:"doc_id"`
	Title           string          `json:"title"`
	Lifecycle       string          `json:"lifecycle_status"`
	Kind            string          `json:"kind"`
	ParentID        string          `json:"parent_id"`
	Priority        json.RawMessage `json:"priority"`
	Labels          []string        `json:"labels"`
	Claim           *claimWire      `json:"claim"`
	Criteria        *criteriaWire   `json:"criteria_progress"`
	DependencyCount int             `json:"dependency_count"`
	DependentCount  int             `json:"dependent_count"`
	InsertedAt      time.Time       `json:"inserted_at"`
	UpdatedAt       time.Time       `json:"updated_at"`
}

// claimWire is content.claim. The engine writes the lease timestamp as
// "ts_iso"; "claimed_at" is accepted as a fallback for any caller that emits
// the friendlier name. A swept lease clears "worker" (JSON null -> ""), which
// is how the board tells an expired claim from a live one.
type claimWire struct {
	Worker    string    `json:"worker"`
	Epoch     int       `json:"epoch"`
	TsISO     time.Time `json:"ts_iso"`
	ClaimedAt time.Time `json:"claimed_at"`
}

type criteriaWire struct {
	Met   int `json:"met"`
	Total int `json:"total"`
}

type eventWire struct {
	Event string    `json:"event"`
	DocID string    `json:"doc_id"`
	At    time.Time `json:"at"`
}

func (w taskWire) toTask() Task {
	t := Task{
		DocID:           w.DocID,
		Title:           w.Title,
		Lifecycle:       w.Lifecycle,
		Kind:            w.Kind,
		ParentID:        w.ParentID,
		Priority:        coercePriority(w.Priority),
		Labels:          w.Labels,
		DependencyCount: w.DependencyCount,
		DependentCount:  w.DependentCount,
		InsertedAt:      w.InsertedAt,
		UpdatedAt:       w.UpdatedAt,
	}
	if w.Claim != nil {
		at := w.Claim.TsISO
		if at.IsZero() {
			at = w.Claim.ClaimedAt
		}
		t.Claim = &Claim{Worker: w.Claim.Worker, Epoch: w.Claim.Epoch, ClaimedAt: at}
	}
	// criteria_progress is OMITTED when absent (wire contract), so a nil
	// pointer stays a nil Criteria — never a misleading 0/0.
	if w.Criteria != nil {
		t.Criteria = &Criteria{Met: w.Criteria.Met, Total: w.Criteria.Total}
	}
	return t
}

// coercePriority renders content.priority (a JSON number, a string, or null)
// into the board's display string. Null/absent -> "".
func coercePriority(raw json.RawMessage) string {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var n json.Number
	if json.Unmarshal(raw, &n) == nil {
		return n.String()
	}
	return strings.Trim(string(raw), `"`)
}
