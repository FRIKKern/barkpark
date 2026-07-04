package taskboard

// detail_data.go — the wave-5 detail substrate (charter slice 14, D13/D25).
//
// Pure data on top of the ONE /v1/tasks round-trip the board already makes:
//
//   - FetchSnapshotFull hydrates the TaskDetail reading model in the SAME
//     fetch+decode pass as the board rows (zero extra network — the list
//     envelope already ships each task's full content map).
//   - ChildrenOf / DrivenTasks / PaperRefs are snapshot derivations: the
//     parent_id child index, the paper→tasks inversion, and a task's paper
//     links. No fetch, no server change — the wire already carries every edge.
//
// The wire-decode itself (taskWire/claimWire, toDetail, decodeTaskListFull)
// lives in fetch.go alongside the board's own decode; this file owns the
// derivations and the full-hydration fetch entry point.

import (
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// FetchSnapshotFull is FetchSnapshot plus detail hydration (charter D13: the
// list envelope already ships each task's full content map, so the reading
// view costs ZERO extra round-trips). The same two calls as ever — the
// /v1/tasks list once, prime once — with the one list body decoded into the
// board Task AND the TaskDetail reading model in a single pass.
//
// Tolerance contract (frozen wave-5): every detail field that is missing or
// malformed on the wire decodes to its zero value — never an error, never a
// dropped task. One odd content map degrades to a thin detail view; the board
// row itself is untouched.
//
// The DetailIndex embeds each task's post-overlay board row (syncDetails), so
// details[id].Task always agrees with Snapshot.Tasks about derived readiness.
func FetchSnapshotFull(c *apiclient.Client) (Snapshot, DetailIndex, error) {
	body, err := getJSON(c, "/v1/tasks?limit=1000")
	if err != nil {
		return Snapshot{}, nil, err
	}
	tasks, details, err := decodeTaskListFull(body)
	if err != nil {
		return Snapshot{}, nil, err
	}
	extras, err := fetchPrime(c)
	if err != nil {
		return Snapshot{}, nil, err
	}
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
