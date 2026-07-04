package taskboard

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
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
	snap, _, err := FetchSnapshotFull(c)
	return snap, err
}

// primeReadyLimit is the server's prime clamp maximum, requested as ?limit=. A
// ready head that comes back FULL (this many rows) means the derived-ready
// overlay only covers the top of the queue — honest-but-partial — which the
// board surfaces as a "+" suffix on the header's ready count.
const primeReadyLimit = 100

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
		Tasks:            tasks,
		Counts:           extras.counts,
		Events:           extras.events,
		ReadyHeadClamped: extras.readyCount >= primeReadyLimit,
		FetchedAt:        fetchedAt,
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

// fetchPrime asks for prime at the clamp maximum — which buys the deepest ready
// head and event tail one call allows. The ticker only renders a short tail, but
// the ready overlay wants every claimable row it can get (past the clamp the
// overlay covers the top of the queue only, which composeSnapshot flags).
func fetchPrime(c *apiclient.Client) (primeExtras, error) {
	body, err := getJSON(c, fmt.Sprintf("/v1/tasks/prime?limit=%d", primeReadyLimit))
	if err != nil {
		return primeExtras{}, err
	}
	return decodePrime(body)
}

// decodeTaskList turns a {"ok":…,"docs":[…]} list body into board Tasks.
func decodeTaskList(body []byte) ([]Task, error) {
	tasks, _, err := decodeTaskListFull(body)
	return tasks, err
}

// decodeTaskListFull is the one-pass dual decode: each render_doc envelope
// becomes both its board Task and its TaskDetail reading model, keyed by
// doc_id. One json.Unmarshal of the body, one walk of the docs.
func decodeTaskListFull(body []byte) ([]Task, DetailIndex, error) {
	var env struct {
		Docs []taskWire `json:"docs"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, nil, fmt.Errorf("decode tasks list: %w", err)
	}
	tasks := make([]Task, 0, len(env.Docs))
	details := make(DetailIndex, len(env.Docs))
	for _, w := range env.Docs {
		t := w.toTask()
		tasks = append(tasks, t)
		details[t.DocID] = w.toDetail(t)
	}
	return tasks, details, nil
}

// primeExtras is the slice of /v1/tasks/prime the board consumes: the
// lifecycle counts (stored statuses only — "ready" never appears as a count
// key), the activity-ticker events, and the doc_ids of the derived ready
// queue that composeSnapshot overlays.
type primeExtras struct {
	counts   map[string]int
	events   []Event
	readyIDs map[string]bool
	// readyCount is the number of ready entries on the wire (before dedup into
	// readyIDs), so composeSnapshot can tell a full-clamp head from a short one.
	readyCount int
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
		counts:     env.Counts,
		events:     make([]Event, 0, len(env.RecentEvents)),
		readyIDs:   make(map[string]bool, len(env.Ready)),
		readyCount: len(env.Ready),
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
	// Papers is the top-level surfacing of content.papers (the server lifts it
	// out; live the two are identical). RawMessage so a malformed value can
	// never fail the whole list decode — toDetail falls back to it only when
	// content.papers is absent.
	Papers json.RawMessage `json:"papers"`
	// Content is the full render_doc content map. The board reads
	// content.acceptance_criteria out of it (the checklist text the compact
	// criteria_progress counter omits) and toDetail hydrates the whole
	// TaskDetail reading model from it — all permissively, so a task whose
	// content is a non-object, or whose fields are oddly shaped, degrades to
	// zero values rather than failing the whole list decode.
	Content json.RawMessage `json:"content"`
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
	// PreviousWorker + ExpiredAt are the swept-lease history the detail view
	// reads (live: a swept claim nulls "worker" and records who held it and
	// when it lapsed). RawMessage + tolerant coercion so a malformed value
	// degrades to zero instead of failing the whole list decode — these two
	// are detail fields and ride the frozen tolerance contract.
	PreviousWorker json.RawMessage `json:"previous_worker"`
	ExpiredAt      json.RawMessage `json:"expired_at"`
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
	t.CriteriaItems = decodeAcceptanceCriteria(w.Content)
	return t
}

// decodeAcceptanceCriteria reads the checklist TEXT out of a render_doc's
// content.acceptance_criteria — the per-criterion detail the compact
// criteria_progress {met,total} counter drops. It mirrors the server's
// tolerance contract (api/lib/barkpark/tasks/criteria.ex): an entry is MET only
// when its "met" key is EXACTLY boolean true, and a malformed entry (a non-map,
// or one missing "criterion") keeps its slot as an unmet, empty-text item so the
// decoded length always tracks criteria_progress.total. It is permissive at
// every layer — an absent content, a non-object content, or a non-list
// acceptance_criteria all yield a nil slice rather than an error, so one odd
// task can never blow up the whole list decode.
func decodeAcceptanceCriteria(content json.RawMessage) []CriterionItem {
	if len(bytes.TrimSpace(content)) == 0 {
		return nil
	}
	var wrap struct {
		AcceptanceCriteria []json.RawMessage `json:"acceptance_criteria"`
	}
	if err := json.Unmarshal(content, &wrap); err != nil || len(wrap.AcceptanceCriteria) == 0 {
		return nil
	}
	items := make([]CriterionItem, 0, len(wrap.AcceptanceCriteria))
	for _, raw := range wrap.AcceptanceCriteria {
		items = append(items, decodeCriterion(raw))
	}
	return items
}

// decodeCriterion turns one acceptance_criteria entry into a CriterionItem.
// Only a JSON object with a string "criterion" and "met" === true reads as a
// met, titled item; anything else (a bare string/number, a null, a map without
// "criterion", a "met" of "yes"/1/absent) keeps its slot as unmet with empty
// text — the exact tolerance of Barkpark.Tasks.Criteria's met?/1.
func decodeCriterion(raw json.RawMessage) CriterionItem {
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil || m == nil {
		return CriterionItem{}
	}
	crit, _ := m["criterion"].(string)
	return CriterionItem{Criterion: crit, Met: m["met"] == true}
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

// ── TaskDetail hydration (charter D13/D15 — the reading model) ──────────────

// toDetail hydrates the TaskDetail reading model from the SAME envelope
// toTask consumed — content fields the compact board row drops. Every read is
// permissive: missing/malformed -> zero value, per the frozen wave-5
// tolerance contract (a weird content map may thin the detail view, but it
// never errors and never drops the task).
func (w taskWire) toDetail(t Task) TaskDetail {
	d := TaskDetail{Task: t}
	m := contentMap(w.Content)
	d.Description = strField(m, "description")
	d.Design = strField(m, "design")
	d.DesignDoc = strField(m, "design_doc")
	d.Papers = strList(m["papers"])
	if len(d.Papers) == 0 {
		// The server also lifts papers to the envelope top level (live the two
		// are identical); the fallback covers a writer that only set one.
		d.Papers = strList(rawList(w.Papers))
	}
	d.Evidence = decodeCriteriaEvidence(w.Content)
	d.BlockedReason = strField(m, "blocked_reason")
	d.CloseReason = strField(m, "close_reason")
	d.ResolutionNote = strField(m, "resolution_note")
	d.CodeRefs = flattenCodeRefs(m["code_refs"])
	d.Assignee = strField(m, "assignee")
	d.LastWorkedAt = timeField(m, "last_worked_at")
	if w.Claim != nil {
		d.PreviousWorker = rawString(w.Claim.PreviousWorker)
		d.ClaimExpiredAt = rawTime(w.Claim.ExpiredAt)
	}
	return d
}

// decodeCriteriaEvidence extracts each acceptance_criteria entry's "evidence"
// string. It walks the SAME list, in the same slot-preserving way, as
// decodeAcceptanceCriteria — so the result is index-aligned with
// Task.CriteriaItems by construction (a malformed or evidence-less entry
// keeps its slot as ""). Nil when the task has no criteria at all.
func decodeCriteriaEvidence(content json.RawMessage) []string {
	if len(bytes.TrimSpace(content)) == 0 {
		return nil
	}
	var wrap struct {
		AcceptanceCriteria []json.RawMessage `json:"acceptance_criteria"`
	}
	if err := json.Unmarshal(content, &wrap); err != nil || len(wrap.AcceptanceCriteria) == 0 {
		return nil
	}
	ev := make([]string, len(wrap.AcceptanceCriteria))
	for i, raw := range wrap.AcceptanceCriteria {
		var m map[string]any
		if json.Unmarshal(raw, &m) == nil {
			ev[i], _ = m["evidence"].(string)
		}
	}
	return ev
}

// flattenCodeRefs renders content.code_refs into display strings. The wire
// has no single shape — LIVE-VERIFIED: workers write a MAP (the
// {branch, commits[], prs[], worktree} convention plus free-form
// "<name>": "<ref>" keys; PR ids arrive as JSON numbers), and a plain list
// of strings is tolerated for any older writer. A map flattens to sorted
// "key: value" lines (list values joined with ", "), empty values are
// dropped, and anything unrecognizable decodes to nil — never an error.
func flattenCodeRefs(v any) []string {
	switch refs := v.(type) {
	case []any:
		return strList(refs)
	case map[string]any:
		keys := make([]string, 0, len(refs))
		for k := range refs {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out := make([]string, 0, len(keys))
		for _, k := range keys {
			if val := codeRefValue(refs[k]); val != "" {
				out = append(out, k+": "+val)
			}
		}
		if len(out) == 0 {
			return nil
		}
		return out
	}
	return nil
}

// codeRefValue coerces one code_refs map value to display text: strings pass
// through, numbers stringify (PR ids), lists join with ", ". Anything else
// (nested maps, nulls) -> "" and the key is dropped.
func codeRefValue(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case []any:
		parts := make([]string, 0, len(x))
		for _, e := range x {
			if s := codeRefValue(e); s != "" {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, ", ")
	}
	return ""
}

// contentMap decodes a render_doc content field into a map, tolerating an
// absent or non-object content by returning nil (every strField/timeField
// read of a nil map yields the zero value).
func contentMap(raw json.RawMessage) map[string]any {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	return m
}

// strField reads a string content field; any other shape (absent, null,
// number, object) -> "".
func strField(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

// strList keeps the non-empty string elements of a decoded JSON array;
// non-array input or an all-junk array -> nil.
func strList(v any) []string {
	list, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(list))
	for _, e := range list {
		if s, ok := e.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// timeField parses an RFC3339 string content field; anything else -> zero.
func timeField(m map[string]any, key string) time.Time {
	s, _ := m[key].(string)
	if s == "" {
		return time.Time{}
	}
	ts, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return ts
}

// rawString tolerantly decodes a RawMessage that should be a JSON string;
// null/absent/malformed -> "".
func rawString(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return ""
}

// rawTime tolerantly decodes a RawMessage that should be an RFC3339 string;
// null/absent/malformed -> zero time.
func rawTime(raw json.RawMessage) time.Time {
	var ts time.Time
	if json.Unmarshal(raw, &ts) == nil {
		return ts
	}
	return time.Time{}
}

// rawList tolerantly decodes a RawMessage that should be a JSON array;
// anything else -> nil.
func rawList(raw json.RawMessage) []any {
	var l []any
	if json.Unmarshal(raw, &l) == nil {
		return l
	}
	return nil
}
