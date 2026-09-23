package taskboard

// detail_data.go — the wave-5 detail substrate (charter slice 14, D13/D25).
//
// Pure data on top of the /v1/tasks round-trips the board already makes:
//
//   - FetchSnapshotFull hydrates the TaskDetail reading model in the SAME
//     fetch+decode pass as the board rows (zero extra network per row — the
//     list envelope already ships each task's full content map).
//   - ChildrenOf / DrivenTasks / PaperRefs are snapshot derivations: the
//     parent_id child index, the paper→tasks inversion, and a task's paper
//     links. No fetch, no server change — the wire already carries every edge.
//
// The wire-decode itself (taskWire/claimWire, toDetail, decodeTaskListFull)
// lives in fetch.go alongside the board's own decode; this file owns the
// derivations and the full-hydration fetch entry point.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// FetchSnapshotFull is FetchSnapshot plus detail hydration (charter D13: the
// list envelope already ships each task's full content map, so the reading
// view costs ZERO extra round-trips per row). Three calls compose one snapshot:
// the /v1/tasks window list, prime, and the lifecycle-filtered in-flight list
// (charter D120) — with each list body decoded into the board Task AND the
// TaskDetail reading model in a single pass.
//
// The round-trips fly CONCURRENTLY (charter D113b). The endpoints are
// server-TTFB-bound and guerrilla serves them independently, so a sequential
// prime paid for the list's latency for nothing; the goroutines below overlap
// the GETs instead. Each list body's decode rides its own goroutine (it needs
// nothing from prime), so a live swap sees one round-trip of wall time, not
// three. apiclient.Client wraps a shared net/http.Client — safe for concurrent
// use — and each goroutine writes ONLY its own result variables; nothing reads
// them before wg.Wait.
//
// The third GET (inflightFetchPath) exists because prime's lifecycle_counts
// are twin-doubled (D115: prime has no collapse_twins while /v1/tasks
// collapses, so a lifecycle-divergent twin counts twice) and the 1000-row
// window can drop a claimed row entirely. The filtered list is the collapsed
// truth for the in-flight population; mergeInflight + countInProgress
// (fetch.go) fold it in between wg.Wait and composeSnapshot. It joins the
// SAME all-required failure contract — best-effort was rejected (D120):
// on failure it would silently repaint the proven-liar prime count.
//
// Failure honesty is otherwise unchanged (fetch.go:33-36): all fetches are
// required, so ANY error yields the SAME degraded outcome as the old
// sequential path — the caller's honest degraded state, never a partial
// snapshot. Error precedence is list > prime > inflight, matching the old
// order (list first). The 32MiB bound and the refuse-empty envelope fence
// (#6033/#8604) live in getJSON/decodeTaskListFull, untouched.
//
// Tolerance contract (frozen wave-5): every detail field that is missing or
// malformed on the wire decodes to its zero value — never an error, never a
// dropped task. One odd content map degrades to a thin detail view; the board
// row itself is untouched.
//
// The DetailIndex embeds each task's post-overlay board row (syncDetails), so
// details[id].Task always agrees with Snapshot.Tasks about derived readiness.
//
// Both GETs run under ONE per-request context deadline (snapshotFetchTimeout,
// ~30s) scoped HERE — the snapshot path's own budget, not a raise of the shared
// apiclient Timeout. That client also serves the interactive claim/close verbs,
// where the 5s DefaultTimeout is right; the corpus GET is the one call whose
// honest budget is snapshot-shaped. Rationale in full at snapshotFetchTimeout
// (fetch.go).
func FetchSnapshotFull(c *apiclient.Client) (Snapshot, DetailIndex, error) {
	// A bare, per-call corpus cache: no base, so the corpus GET is the same
	// exhaustive walk it has always been. Every one-shot CLI verb (`bp task
	// frontier` / `lint` / `next`, `bp cmux dispatch`) reaches the fetch through
	// here and is therefore byte-identical to before. The board takes the
	// incremental path via newSnapshotFetcher, which keeps its cache across the
	// re-lists of one long-lived process.
	return fetchSnapshotWith(c, &corpusCache{})
}

// newSnapshotFetcher returns a fetch seam that CARRIES a corpus cache, so
// successive re-lists from one board can walk only the changed prefix
// (corpus.go). One cache per fetcher — never a package global — so two boards,
// or two tests, can never seed each other's corpus.
//
// cacheDir/cacheKey address the PERSISTED base (corpus_persist.go): the same bp
// config dir and scope key the first-paint snapshot cache uses. They are passed
// in rather than resolved here so a test can point the whole seam at a
// t.TempDir(), and an empty cacheDir disables persistence entirely — which is
// what a board with no resolvable config dir gets, and it is byte-identical to
// the pre-persistence behaviour.
func newSnapshotFetcher(cacheDir, cacheKey string) func(*apiclient.Client) (Snapshot, DetailIndex, error) {
	// live:true — this cache outlives one fetch, which is what licenses the brief
	// prime projection and the rolling event tail (corpus.go primeView).
	cc := &corpusCache{live: true, persistDir: cacheDir, persistKey: cacheKey}
	return func(c *apiclient.Client) (Snapshot, DetailIndex, error) {
		return fetchSnapshotWith(c, cc)
	}
}

func fetchSnapshotWith(c *apiclient.Client, cc *corpusCache) (Snapshot, DetailIndex, error) {
	ctx, cancel := context.WithTimeout(context.Background(), snapshotFetchTimeout)
	defer cancel()
	var (
		tasks           []Task
		details         DetailIndex
		listErr         error
		extras          primeExtras
		primeErr        error
		inflightTasks   []Task
		inflightDetails DetailIndex
		inflightErr     error
		listExhaustive  bool
		wg              sync.WaitGroup
	)
	wg.Add(3)
	go func() {
		defer wg.Done()
		// task-6c59bff7cb6b36ee: the corpus GET is a CURSOR WALK, not one
		// window. listExhaustive records whether the walk actually reached the
		// end — the fact mergeForward needs to tell "this row closed" from
		// "this row rotated out of the window".
		// The corpus GET walks the CHANGED PREFIX when it safely can and the
		// whole cursor when it cannot (corpus.go); either way listExhaustive
		// keeps its meaning — true only when the returned corpus is the whole
		// world — so mergeForward's absence heuristic is unaffected.
		tasks, details, listExhaustive, listErr = fetchTaskCorpus(ctx, c, cc, time.Now())
	}()
	go func() {
		defer wg.Done()
		extras, primeErr = fetchPrime(ctx, c, cc.primeView())
	}()
	go func() {
		defer wg.Done()
		// The in-flight leg decodes in-goroutine through the SAME
		// decodeTaskListFull — the filtered response is the same {ok,docs}
		// envelope, and {"docs":[]} legitimately decodes to zero rows with a
		// nil error (an empty in-flight population is a fact, not a failure).
		inflightTasks, inflightDetails, _, inflightErr = fetchTaskPages(ctx, c, inflightFetchPath+cc.listView())
	}()
	wg.Wait()
	if listErr != nil {
		return Snapshot{}, nil, listErr
	}
	if primeErr != nil {
		return Snapshot{}, nil, primeErr
	}
	// Rebuild the event tail the brief projection trims. On a one-shot cache
	// primeView() returned "", the body already carried the full tail, and this
	// is an identity (nothing stored, nothing to merge with) — so those verbs
	// stay byte-identical in BOTH directions, request and Snapshot.
	extras.events = cc.mergeEventTail(extras.events)
	if inflightErr != nil {
		return Snapshot{}, nil, inflightErr
	}
	// D120 merge point: fold the in-flight fetch into the window BEFORE the
	// snapshot composes, so the ready overlay, board.Now and syncDetails all
	// see one deduped corpus with zero special-casing downstream.
	tasks, details = mergeInflight(tasks, details, inflightTasks, inflightDetails)
	// Exactly ONE bucket collapses: in_progress derives from the deduped
	// union (the /v1/tasks route collapses twins; prime does not). done/open/
	// blocked/cancelled stay prime-raw — still twin-doubled — until the api
	// twin fix lands (ttw20-bl-prime-counts-collapse-twins), so a summed-
	// Counts denominator is only as collapsed as its in_progress term.
	if extras.counts == nil {
		extras.counts = make(map[string]int, 1)
	}
	extras.counts[lifeInProgress] = countInProgress(tasks)
	snap := composeSnapshot(tasks, extras, time.Now().UTC())
	snap.Exhaustive = listExhaustive
	syncDetails(details, snap.Tasks)
	return snap, details, nil
}

// syncDetails re-embeds each composed board row into its TaskDetail. The
// ready overlay (composeSnapshot) upgrades lifecycles AFTER the decode pass
// built the details, so without this step a detail frame could contradict the
// board row it was opened from.
func syncDetails(details DetailIndex, tasks []Task) {
	for _, t := range tasks {
		if d, ok := details[t.DocID]; ok {
			d.Task = t
			details[t.DocID] = d
		}
	}
}

// bareID strips the drafts. document prefix so ids and paper slugs compare in
// their published form. Live data mixes the two freely: a task lives at
// "drafts.dwb-20" while its parent_id says "dwb" and its design_doc says
// "deploy-with-barkpark" — the same convention repoctx already matches
// commits against.
func bareID(id string) string { return strings.TrimPrefix(id, draftsPrefix) }

// BareID is the exported form of bareID for callers outside the package (the
// CLI's `bp task frontier` renderer) that need the drafts.-stripped id.
func BareID(id string) string { return bareID(id) }

// isDraftID is the package's ONE prefix test — the Go half of THE DRAFT LABEL
// CONTRACT (Barkpark.Tasks.Board's moduledoc, shipped in #18961). What marks a
// row a draft is the `drafts.` spelling of its OWN stored doc_id and nothing
// else: not status, not lifecycle_status, not content. A `drafts.`-spelled row
// stored status:"published" is STILL a draft, which is exactly why this may
// never become a status check. Elixir consolidated the same test into
// Barkpark.Content.DraftId.draft?/1 (@canonical capability:draft-published-id)
// after the scattered String.starts_with? calls drifted; this is the mirror of
// that consolidation, so every caller in this package tests the prefix HERE —
// `grep -rn 'strings.HasPrefix(.*drafts' internal/taskboard` must stay a single
// site. It is deliberately the NEIGHBOUR of bareID: the test reads the RAW id,
// bareID destroys the evidence, so the two live together and the ordering
// (test, THEN strip) is visible in one screen.
func isDraftID(id string) bool { return strings.HasPrefix(id, draftsPrefix) }

// ChildrenOf returns the direct children of docID — every task whose
// parent_id names it, drafts.-prefix-agnostic on both sides — oldest-inserted
// first, so a goal's sub-task rail reads in authoring order like the server's
// own children listing. Empty docID matches nothing (an empty parent_id means
// "no parent", never "child of the empty id").
func ChildrenOf(tasks []Task, docID string) []Task {
	want := bareID(docID)
	if want == "" {
		return nil
	}
	var out []Task
	for _, t := range tasks {
		if t.ParentID != "" && bareID(t.ParentID) == want {
			out = append(out, t)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].InsertedAt.Before(out[j].InsertedAt)
	})
	return out
}

// DrivenTasks returns every task that names the paper slug — via design_doc
// or papers[] membership, drafts.-prefix-agnostic both ways — band-ordered
// like epic children (in_progress → ready → blocked → open → unknown →
// terminal, freshest first inside each band).
//
// Snapshot inversion IS the paper→tasks projector on purpose: the server's
// GET /v1/graph/:id/tasks rides published-coalesced reverse_referencers and
// live-verifiably returns nothing for a drafts.* corpus (charter D13d; the
// projector fix is a reserved server slice).
//
// The frozen signature carries no clock, so the age-derived stale demotion
// band is skipped here (orderChildren with a zero now can never exceed the
// stale threshold); every other band matches the board exactly.
func DrivenTasks(tasks []Task, details DetailIndex, slug string) []Task {
	want := bareID(slug)
	if want == "" {
		return nil
	}
	var out []Task
	for _, t := range tasks {
		if d, ok := details[t.DocID]; ok && d.namesPaper(want) {
			out = append(out, t)
		}
	}
	orderChildren(out, time.Time{})
	return out
}

// namesPaper reports whether the detail links the (bare) paper slug via
// design_doc or papers[].
func (d TaskDetail) namesPaper(want string) bool {
	if d.DesignDoc != "" && bareID(d.DesignDoc) == want {
		return true
	}
	for _, p := range d.Papers {
		if bareID(p) == want {
			return true
		}
	}
	return false
}

// PaperRefs lists the papers this task points at: design_doc first (the
// primary design link), then papers[] in wire order, deduped on the bare
// slug — "drafts.x" and "x" collapse to the first-seen spelling. Nil when
// the task links no paper.
func (d TaskDetail) PaperRefs() []string {
	var refs []string
	seen := make(map[string]bool, 1+len(d.Papers))
	add := func(s string) {
		if s == "" || seen[bareID(s)] {
			return
		}
		seen[bareID(s)] = true
		refs = append(refs, s)
	}
	add(d.DesignDoc)
	for _, p := range d.Papers {
		add(p)
	}
	return refs
}

// ─── per-row hydration off the always-full row route ───────────────────────

// taskDetailPath is the single-row GET. The route is ALWAYS the full card —
// `?view=` is a LIST param and this route does not read it — so one request
// restores every content field `?view=board` deleted for the one row a reader
// actually opened.
const taskDetailPath = "/v1/tasks/"

// FetchTaskDetailByID hydrates ONE task's full TaskDetail from GET
// /v1/tasks/:doc_id.
//
// WHY IT EXISTS. The live board's list/poll path asks for `?view=board`
// (corpusCache.listView), which deletes `content` — so the DetailIndex the list
// body hydrates carries the board ROW (identity, lifecycle, claim, the digest-
// derived ladder and badge) and none of the prose the detail pane draws:
// description, brief, evidence, code_refs, purpose, the blocked/closed/
// disposition strips. This is the fetch that pays for exactly the rows a reader
// opens, which is the trade the projection was cut for: the corpus walk goes
// from 105,755,961 B to 13,035,765 B and a single opened row costs a few KB.
//
// It decodes through the SAME taskWire/toTask/toDetail the list path uses, so
// there is one decode contract and one tolerance contract, not two. The doc's
// own board row is rebuilt from the full card here; applying it is the caller's
// job (Model.applyTaskDetail re-embeds the LIVE snapshot row over it, so a
// hydration in flight across a re-list can never resurrect a stale lifecycle).
func FetchTaskDetailByID(c *apiclient.Client, docID string) (TaskDetail, error) {
	if strings.TrimSpace(docID) == "" {
		return TaskDetail{}, fmt.Errorf("fetch task detail: empty doc_id")
	}
	body, err := getJSON(c, taskDetailPath+url.PathEscape(docID))
	if err != nil {
		return TaskDetail{}, err
	}
	var env struct {
		Doc *taskWire `json:"doc"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return TaskDetail{}, fmt.Errorf("decode task detail: %w", err)
	}
	// Nil STRICTLY before deref, and an absent `doc` is a refusal rather than a
	// zero TaskDetail: a blank pane that claims to be the row is the silent lie
	// this whole seam exists to avoid.
	if env.Doc == nil {
		return TaskDetail{}, fmt.Errorf("decode task detail: response carried no %q key%s", "doc", bodyHint(body))
	}
	w := *env.Doc
	return w.toDetail(w.toTask()), nil
}
