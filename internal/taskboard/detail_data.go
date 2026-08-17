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
		wg              sync.WaitGroup
	)
	wg.Add(3)
	go func() {
		defer wg.Done()
		body, err := getJSONCtx(ctx, c, "/v1/tasks?limit=1000")
		if err != nil {
			listErr = err
			return
		}
		tasks, details, listErr = decodeTaskListFull(body)
	}()
	go func() {
		defer wg.Done()
		extras, primeErr = fetchPrime(ctx, c)
	}()
	go func() {
		defer wg.Done()
		// The in-flight leg decodes in-goroutine through the SAME
		// decodeTaskListFull — the filtered response is the same {ok,docs}
		// envelope, and {"docs":[]} legitimately decodes to zero rows with a
		// nil error (an empty in-flight population is a fact, not a failure).
		body, err := getJSONCtx(ctx, c, inflightFetchPath)
		if err != nil {
			inflightErr = err
			return
		}
		inflightTasks, inflightDetails, inflightErr = decodeTaskListFull(body)
	}()
	wg.Wait()
	if listErr != nil {
		return Snapshot{}, nil, listErr
	}
	if primeErr != nil {
		return Snapshot{}, nil, primeErr
	}
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
