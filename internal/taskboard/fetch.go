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
//   - GET /v1/tasks/prime supplies the lifecycle counts and the recent task.%
//     mutation events for the activity ticker.
//
// The task routes are mounted at the host's TOP-LEVEL /v1 scope (tenancy rides
// the bearer token), so the paths are joined onto BaseURL directly — NOT the
// workspace/project-scoped URL. Both fetches are required: a partial board
// would silently drop counts or the ticker, so any failure is returned as an
// error and the caller (the tea shell) renders its honest degraded state.
//
// FetchSnapshot is the IO boundary, so it stamps FetchedAt from the wall clock;
// the pure BuildBoard downstream takes its "now" as an explicit parameter.
func FetchSnapshot(c *apiclient.Client) (Snapshot, error) {
	tasks, err := fetchTaskList(c)
	if err != nil {
		return Snapshot{}, err
	}
	counts, events, err := fetchPrime(c)
	if err != nil {
		return Snapshot{}, err
	}
	return Snapshot{
		Tasks:     tasks,
		Counts:    counts,
		Events:    events,
		FetchedAt: time.Now().UTC(),
	}, nil
}

// getJSON issues an authenticated GET to a top-level path, reusing the Client's
// configured http.Client and bearer token (via the public GetConditional
// helper, called with no If-None-Match so it always fetches the body). It does
// not modify apiclient. A non-200 is an error carrying the status.
func getJSON(c *apiclient.Client, path string) ([]byte, error) {
	res, err := c.GetConditional(c.BaseURL()+path, "")
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: status %d", path, res.StatusCode)
	}
	return res.Body, nil
}

func fetchTaskList(c *apiclient.Client) ([]Task, error) {
	body, err := getJSON(c, "/v1/tasks?limit=1000")
	if err != nil {
		return nil, err
	}
	return decodeTaskList(body)
}

func fetchPrime(c *apiclient.Client) (map[string]int, []Event, error) {
	body, err := getJSON(c, "/v1/tasks/prime")
	if err != nil {
		return nil, nil, err
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

// decodePrime pulls the lifecycle counts and recent events out of a prime body.
func decodePrime(body []byte) (map[string]int, []Event, error) {
	var env struct {
		Counts       map[string]int `json:"counts"`
		RecentEvents []eventWire    `json:"recent_events"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, nil, fmt.Errorf("decode prime: %w", err)
	}
	events := make([]Event, 0, len(env.RecentEvents))
	for _, e := range env.RecentEvents {
		events = append(events, Event{Mutation: e.Event, DocID: e.DocID, At: e.At})
	}
	return env.Counts, events, nil
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
