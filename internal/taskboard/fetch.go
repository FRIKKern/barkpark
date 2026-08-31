package taskboard

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

const snapshotFetchAttempts = 3

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

// inflightFetchPath is the D120 third fetch: the SAME /v1/tasks route with the
// server-side lifecycle filter, so the response is the same {ok,docs} envelope
// decodeTaskListFull already decodes — and, crucially, the same twin-COLLAPSED
// projection (api tasks/query.ex collapses lifecycle-divergent twins; prime's
// lifecycle_counts do not, D115). The filter param is read optionally by the
// controller — an older server ignores it and answers the full window, which
// the union dedup (mergeInflight) degrades to window-truth, never garbage.
const inflightFetchPath = "/v1/tasks?lifecycle_status=in_progress&limit=1000"

// mergeInflight unions the in-flight fetch's rows into the window list, deduped
// by doc_id with the LIST (window) copy winning on overlap — two copies of one
// doc differ only by fetch timing, and the window copy is the one whose
// lifecycle the rest of the corpus was fetched against. Union-only rows append
// AFTER the window rows, before composeSnapshot: the ready overlay ignores
// them (an in-flight row is never stored open|blocked), board.Now picks them
// up via its unchanged predicate, and syncDetails embeds them with zero
// special-casing. The detail indexes merge the same way (list wins) so a
// rescued NOW row opens at full depth — the thin-frame fallback stays the
// safety net, not the plan.
func mergeInflight(tasks []Task, details DetailIndex, inflight []Task, inflightDetails DetailIndex) ([]Task, DetailIndex) {
	seen := make(map[string]bool, len(tasks))
	for _, t := range tasks {
		seen[t.DocID] = true
	}
	for _, t := range inflight {
		if seen[t.DocID] {
			continue
		}
		seen[t.DocID] = true
		tasks = append(tasks, t)
	}
	if details == nil && len(inflightDetails) > 0 {
		details = make(DetailIndex, len(inflightDetails))
	}
	for id, d := range inflightDetails {
		if _, ok := details[id]; !ok {
			details[id] = d
		}
	}
	return tasks, details
}

// countInProgress is the collapsed in-flight denominator: the count of
// lifecycle==in_progress rows over the DEDUPED UNION mergeInflight built —
// never len(third-fetch) (a stale filtered copy whose window twin already
// moved on must not count) and never prime's raw bucket (twin-doubled, the
// D115 lie). Deriving from the union also makes the number immune to an old
// server that ignored the filter and to param drift: a 200-empty in-flight
// body degrades the count to window-truth.
func countInProgress(tasks []Task) int {
	n := 0
	for _, t := range tasks {
		if t.Lifecycle == lifeInProgress {
			n++
		}
	}
	return n
}

// maxBoardFetchBytes bounds the board's task-corpus fetch. The generic
// GetConditional cap (8 MiB, sized for the capabilities manifest) went dark on
// guerrilla when /v1/tasks?limit=1000 crossed 9.1 MB (2026-07-24). 32 MiB buys
// ~3× corpus growth of headroom; the real fix is the two-level board (brief
// tier on the board, detail on focus — /papers/ctx-compression-taskboard-
// flagship), which shrinks this fetch instead of chasing it with a bigger cap.
const maxBoardFetchBytes = 32 << 20

// snapshotFetchTimeout is the snapshot path's OWN request budget, carried as a
// per-request context deadline (see snapshotHTTP below). It is deliberately NOT
// a raise of the apiclient's Timeout: the one shared Client also serves the
// interactive claim/close verbs, where the 5s DefaultTimeout is right — a
// keystroke must fail fast, never hang half a minute. The heavy corpus GET
// (/v1/tasks?limit=1000, ~9 MB live) and prime routinely see 2.0-2.4s of server
// TTFB on guerrilla, so the inherited 5s left ~2x margin and blew under load —
// which the old path then mislabeled "offline" (a lie; the server answers).
// 30s is a snapshot-shaped budget: generous enough that a slow-but-alive server
// completes, finite so a genuinely dead read still surfaces.
const snapshotFetchTimeout = 30 * time.Second

// snapshotHTTP is the snapshot path's transport. It carries NO client-level
// Timeout — the deadline rides each request's context (getJSONCtx), so the
// budget is scoped to the snapshot fetch alone and can never leak into the
// apiclient the interactive verbs share. A plain shared http.Client is safe for
// concurrent use (the list and prime GETs fly concurrently, charter D113b).
var snapshotHTTP = &http.Client{}

// getJSON is getJSONCtx under the snapshot path's own default budget. Kept as
// the two-arg convenience so every snapshot-path caller gets the scoped
// deadline even when it has no context of its own to thread.
func getJSON(c *apiclient.Client, path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), snapshotFetchTimeout)
	defer cancel()
	return getJSONCtx(ctx, c, path)
}

// getJSONCtx issues an authenticated GET to a top-level path with the caller's
// context deadline, the Client's bearer token, and the board's own
// maxBoardFetchBytes cap. It does not modify apiclient — the request runs on
// snapshotHTTP precisely so the apiclient's interactive 5s Timeout cannot clamp
// a snapshot-sized read (and the snapshot budget cannot slow a keystroke).
// Every error carries the path, and a non-200 carries the status plus a
// one-line body hint, so the shell's degraded banner can say WHICH call failed
// and why ("GET /v1/tasks/prime: status 401: …"). The cap is a refusal, never a
// trim — a truncated JSON body would parse as garbage or a plausible prefix.
func getJSONCtx(ctx context.Context, c *apiclient.Client, path string) ([]byte, error) {
	var lastErr error
	for attempt := 0; attempt < snapshotFetchAttempts; attempt++ {
		body, retry, err := getJSONAttempt(ctx, c, path)
		if err == nil {
			return body, nil
		}
		lastErr = err
		if !retry || attempt == snapshotFetchAttempts-1 {
			return nil, err
		}

		// Guerrilla can briefly refuse a DB checkout while a large task query is
		// completing. Retry only server-side failures, inside the existing 30s
		// snapshot deadline; auth, malformed requests, oversize bodies and local
		// transport failures still fail immediately and truthfully.
		delay := time.Duration(attempt+1) * 150 * time.Millisecond
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return nil, fmt.Errorf("GET %s: %w", path, ctx.Err())
		}
	}
	return nil, lastErr
}

func getJSONAttempt(ctx context.Context, c *apiclient.Client, path string) ([]byte, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL()+path, nil)
	if err != nil {
		return nil, false, fmt.Errorf("GET %s: %w", path, err)
	}
	if token := c.Token(); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := snapshotHTTP.Do(req)
	if err != nil {
		return nil, false, fmt.Errorf("GET %s: %w", path, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBoardFetchBytes+1))
	if err != nil {
		return nil, false, fmt.Errorf("GET %s: %w", path, err)
	}
	if int64(len(body)) > maxBoardFetchBytes {
		return nil, false, &oversizeBodyError{Path: path, Limit: maxBoardFetchBytes}
	}
	if resp.StatusCode != http.StatusOK {
		retry := resp.StatusCode >= http.StatusInternalServerError && resp.StatusCode <= 599
		return nil, retry, &httpStatusError{Path: path, StatusCode: resp.StatusCode, Hint: bodyHint(body)}
	}
	return body, false, nil
}

// httpStatusError carries a refused snapshot fetch's status as the INT it was
// read as, not only as text. Error() is byte-identical to the fmt.Errorf this
// replaced, so every caller that reads the message ("GET /v1/tasks: status 401:
// …") is unchanged — what is new is that snapshotErrorLabel can consult
// StatusCode via errors.As instead of running strings.Contains over the message.
// That distinction is load-bearing because Hint is bodyHint(body): up to 120
// characters of the SERVER'S OWN response, which this binary does not control.
// A gateway 500 whose body forwards "upstream status 404", or a 404 whose body
// says "prefix exceeds 0 bytes", used to hijack its own classification and put
// the wrong failure on the operator's identity strip.
type httpStatusError struct {
	Path       string
	StatusCode int
	// Hint is bodyHint's ": …" suffix (already condensed and capped) or "".
	Hint string
}

func (e *httpStatusError) Error() string {
	return fmt.Sprintf("GET %s: status %d%s", e.Path, e.StatusCode, e.Hint)
}

// oversizeBodyError is the typed twin for the maxBoardFetchBytes refusal, for
// the same reason: "the response blew the cap" is a fact this code KNOWS, and
// leaving snapshotErrorLabel to infer it from the words "exceeds" and "bytes"
// let any response body carrying those words claim the class.
type oversizeBodyError struct {
	Path  string
	Limit int64
}

func (e *oversizeBodyError) Error() string {
	return fmt.Sprintf("GET %s: response exceeds %d bytes — refusing to parse a truncated body", e.Path, e.Limit)
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
// overlay covers the top of the queue only, which composeSnapshot flags). The
// context carries FetchSnapshotFull's shared snapshot budget, so both halves of
// one snapshot expire together.
func fetchPrime(ctx context.Context, c *apiclient.Client) (primeExtras, error) {
	body, err := getJSONCtx(ctx, c, fmt.Sprintf("/v1/tasks/prime?limit=%d", primeReadyLimit))
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
//
// ENVELOPE FENCE (epic law: no verb reports success on an exit code alone). A
// VALUE-typed `Docs []taskWire` decodes `null`, `{}`, `{"error":…}` and
// `{"ok":false,"error":{…}}` to zero rows with a NIL error — a plausible,
// silent, EMPTY BOARD for a 200 that said nothing. The POINTER field below
// distinguishes "key absent/null" from `{"docs":[]}` (a legitimate empty
// board, which stays err=nil) inside the SAME single Unmarshal — no second
// pass. `[]`, zero bytes and HTML already fail the Unmarshal itself, so this
// fence covers strictly the well-formed-JSON-object-without-the-key class.
//
// This does NOT cross detail_data.go's 'Tolerance contract (frozen wave-5)':
// that contract is FIELD-scoped (one odd task's content must never break the
// whole list decode) and remains untouched — every per-doc field stays as
// permissive as it was. What is fenced here is the ENVELOPE, one level above
// it: whether the server answered with a task list at all.
//
// The error text carries "decode", which snapshotErrorLabel already maps to
// "invalid snapshot" on the existing ConnOffline+ConnProblem channel
// (live.go) — the refusal reuses the honest transport path, inventing nothing.
func decodeTaskListFull(body []byte) ([]Task, DetailIndex, error) {
	var env struct {
		Docs *[]taskWire `json:"docs"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, nil, fmt.Errorf("decode tasks list: %w", err)
	}
	// Nil check STRICTLY before any deref: a reordering here turns the silent
	// lie into a nil-pointer panic, which is worse. TestDecodeEnvelopeFence
	// covers every poison, so a reorder fails the suite rather than shipping.
	if env.Docs == nil {
		return nil, nil, fmt.Errorf("decode tasks list: response carried no %q key%s", "docs", bodyHint(body))
	}
	docs := *env.Docs
	tasks := make([]Task, 0, len(docs))
	details := make(DetailIndex, len(docs))
	for _, w := range docs {
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
//
// ENVELOPE FENCE, same law as decodeTaskListFull. The prime predicate is
// deliberately NOT "counts is present": the controller branches on view, and
// counts is one key in one shape of the envelope, so keying on it alone would
// red a future brief view that legitimately omits it. The predicate is
// therefore `counts` present OR `ok` asserted TRUE — which still refuses all
// four poisons, because `{"ok":false,"error":{…}}` asserts the opposite and
// `null`/`{}`/`{"error":…}` assert nothing. `{"ok":true,"counts":{}}` and a
// counts-bearing body both pass. Field-level tolerance below is unchanged.
func decodePrime(body []byte) (primeExtras, error) {
	var env struct {
		OK           *bool           `json:"ok"`
		Counts       *map[string]int `json:"counts"`
		RecentEvents []eventWire     `json:"recent_events"`
		Ready        []struct {
			DocID string `json:"doc_id"`
		} `json:"ready"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return primeExtras{}, fmt.Errorf("decode prime: %w", err)
	}
	// Nil check STRICTLY before the deref below — see decodeTaskListFull.
	if env.Counts == nil && (env.OK == nil || !*env.OK) {
		return primeExtras{}, fmt.Errorf("decode prime: response carried neither %q nor an affirmative %q%s", "counts", "ok", bodyHint(body))
	}
	counts := map[string]int(nil)
	if env.Counts != nil {
		counts = *env.Counts
	}
	extras := primeExtras{
		counts:     counts,
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
	// Now is the D9 pulse — content.claim.now {"text","ts","criterion"?}.
	// RawMessage + decodePulse's tolerance so a malformed pulse degrades to
	// no-pulse instead of failing the whole list decode.
	Now json.RawMessage `json:"now"`
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
		t.Claim = &Claim{Worker: w.Claim.Worker, Epoch: w.Claim.Epoch, ClaimedAt: at,
			Now: decodePulse(w.Claim.Now)}
	}
	// criteria_progress is OMITTED when absent (wire contract), so a nil
	// pointer stays a nil Criteria — never a misleading 0/0.
	if w.Criteria != nil {
		t.Criteria = &Criteria{Met: w.Criteria.Met, Total: w.Criteria.Total}
	}
	t.CriteriaItems = decodeAcceptanceCriteria(w.Content)
	m := contentMap(w.Content)
	papers := strList(m["papers"])
	if len(papers) == 0 {
		papers = strList(rawList(w.Papers))
	}
	t.Completeness = ScoreCompleteness(CompletenessInput{
		Title:           t.Title,
		Description:     strField(m, "description"),
		HasCriteria:     len(t.CriteriaItems) > 0,
		Placement:       t.ParentID,
		Priority:        t.Priority,
		HasDependencies: t.DependencyCount > 0 || len(strList(m["dependencies"])) > 0,
		HasPaper:        strField(m, "design_doc") != "" || len(papers) > 0,
	})
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
// text — the exact tolerance of Barkpark.Tasks.Criteria's met?/1. The D8
// attempts trail rides along, decoded with the same tolerance.
func decodeCriterion(raw json.RawMessage) CriterionItem {
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil || m == nil {
		return CriterionItem{}
	}
	crit, _ := m["criterion"].(string)
	ev, _ := m["evidence"].(string)
	return CriterionItem{Criterion: crit, Met: m["met"] == true, Evidence: ev, Attempts: decodeAttempts(m["attempts"])}
}

// decodeAttempts reads a criterion's honest-miss trail — the D8 attempts[]
// list of {"note","ts","worker"} entries `bp task stamp --miss` appends
// (server-bounded to the 5 most recent). Tolerant at every layer: a non-list
// value or a non-map entry decodes to nothing, and a map entry keeps whatever
// fields parse (a missing note/ts/worker degrades to its zero value). The
// presence of at least one well-formed attempt is what turns a board rung
// amber, so junk can never fake a recorded miss.
func decodeAttempts(v any) []CriterionAttempt {
	list, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]CriterionAttempt, 0, len(list))
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		a := CriterionAttempt{At: timeField(m, "ts")}
		a.Note = strField(m, "note")
		a.Worker = strField(m, "worker")
		out = append(out, a)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// decodePulse turns content.claim.now into a ClaimPulse (charter D9's pinned
// {"text","ts","criterion"?} shape). Tolerance contract: absent/null/malformed
// or an empty text → nil (no pulse — an empty now-line says nothing, so it
// renders nothing); a missing/`null`/non-integer criterion → -1 (the pulse
// names no criterion, so no ladder rung spins); a malformed ts → zero time
// (which renders as maximally stale — an undatable pulse must never read
// fresh).
func decodePulse(raw json.RawMessage) *ClaimPulse {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	var w struct {
		Text      string          `json:"text"`
		Ts        json.RawMessage `json:"ts"`
		Criterion json.RawMessage `json:"criterion"`
	}
	if json.Unmarshal(raw, &w) != nil || strings.TrimSpace(w.Text) == "" {
		return nil
	}
	p := &ClaimPulse{Text: w.Text, At: rawTime(w.Ts), Criterion: -1}
	var idx int
	if json.Unmarshal(w.Criterion, &idx) == nil && idx >= 0 {
		p.Criterion = idx
	}
	return p
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
	d.BriefRaw = rawPortableDoc(m["brief"])
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
	d.Disposition = strField(m, "disposition")
	d.DispositionReason = strField(m, "disposition_reason")
	d.ReopenTrigger = strField(m, "reopen_trigger")
	d.CodeRefs = flattenCodeRefs(m["code_refs"])
	d.Assignee = strField(m, "assignee")
	d.LastWorkedAt = timeField(m, "last_worked_at")
	d.Purpose = decodeTaskPurpose(m["purpose"])
	if w.Claim != nil {
		d.PreviousWorker = rawString(w.Claim.PreviousWorker)
		d.ClaimExpiredAt = rawTime(w.Claim.ExpiredAt)
	}
	return d
}

func decodeTaskPurpose(v any) TaskPurpose {
	m, _ := v.(map[string]any)
	if m == nil {
		return TaskPurpose{}
	}
	return TaskPurpose{
		PartOf:     strField(m, "part_of"),
		Impact:     strField(m, "impact"),
		Statement:  strField(m, "statement"),
		Why:        strField(m, "why"),
		Endgame:    strField(m, "endgame"),
		Importance: decodePurposeScore(m["importance"]),
		Relevance:  decodePurposeScore(m["relevance"]),
		Proof:      decodePurposeProof(m["proof"]),
	}
}

func decodePurposeScore(v any) PurposeScore {
	m, _ := v.(map[string]any)
	if m == nil {
		return PurposeScore{}
	}
	score, set := 0, false
	if n, ok := m["score"].(float64); ok && n >= 0 && n <= 100 {
		score, set = int(n), true
	}
	return PurposeScore{Score: score, Reason: strField(m, "reason"), Set: set}
}

func decodePurposeProof(v any) []PurposeProof {
	rows, _ := v.([]any)
	out := make([]PurposeProof, 0, len(rows))
	for _, row := range rows {
		m, _ := row.(map[string]any)
		if m == nil {
			continue
		}
		p := PurposeProof{Claim: strField(m, "claim"), Evidence: strField(m, "evidence"), Source: strField(m, "source")}
		if p.Claim != "" || p.Evidence != "" || p.Source != "" {
			out = append(out, p)
		}
	}
	return out
}

// rawPortableDoc preserves a task's inline PortableDoc value for pdrender.
// Missing, null and non-object values degrade to the legacy description.
func rawPortableDoc(value any) []byte {
	if value == nil {
		return nil
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) || raw[0] != '{' {
		return nil
	}
	var env struct {
		Blocks []json.RawMessage `json:"blocks"`
	}
	if json.Unmarshal(raw, &env) != nil || env.Blocks == nil {
		return nil
	}
	return append([]byte(nil), raw...)
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
