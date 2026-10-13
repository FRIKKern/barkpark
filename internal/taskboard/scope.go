package taskboard

import (
	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Goal scoping. A repo that tracks one goal inside a shared workspace (the
// barkpark-studio repo works the Studio Parity goal inside guerrilla's default
// workspace, next to 500+ unrelated rows) names it as "goal" in .barkpark.json,
// and the board then shows that goal row and every task under it, nothing else.
//
// The scope is applied to the composed snapshot, after the full corpus fetch:
// the descendant walk needs every parent_id link, and the corpus walk, prime and
// the in-flight leg stay byte-identical to an unscoped board. An empty goal is
// the identity everywhere in this file, so a board without the key behaves
// exactly as it did before the key existed.

// boardCacheKey is the snapshot/corpus cache identity for cfg. Without a goal it
// is the plain scope key, so existing cache files keep their names. With one,
// the goal joins the key, so a scoped board and an unscoped board on the same
// server never read or overwrite each other's first-paint cache.
func boardCacheKey(cfg Config) string {
	if cfg.Goal == "" {
		return cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project, cfg.Dataset)
	}
	return cacheKey(cfg.BaseURL, cfg.Workspace, cfg.Project, cfg.Dataset+"\x00goal\x00"+bareID(cfg.Goal))
}

// scopeFetcher wraps a snapshot fetcher so every snapshot it returns is scoped
// to goal. An empty goal returns fetch unchanged.
func scopeFetcher(fetch func(*apiclient.Client) (Snapshot, DetailIndex, error), goal string) func(*apiclient.Client) (Snapshot, DetailIndex, error) {
	if goal == "" {
		return fetch
	}
	return func(c *apiclient.Client) (Snapshot, DetailIndex, error) {
		snap, details, err := fetch(c)
		if err != nil {
			return snap, details, err
		}
		return scopeToGoal(snap, goal), details, nil
	}
}

// scopeToGoal keeps the goal row and its descendants (parent_id chains, drafts.
// prefix ignored on both sides) and drops every other task. Counts are
// recomputed from the kept rows, because prime's counts describe the whole
// workspace, and the event tail keeps only events about kept rows. The
// DetailIndex is left whole: it is keyed by doc id, so rows outside the scope
// are simply never opened from the board.
//
// A goal id that matches no row yields an empty board rather than the full one:
// a typo in .barkpark.json should read as "nothing here", never as a silently
// unscoped board.
func scopeToGoal(snap Snapshot, goal string) Snapshot {
	if goal == "" {
		return snap
	}
	root := bareID(goal)
	children := make(map[string][]string, len(snap.Tasks))
	for _, t := range snap.Tasks {
		if t.ParentID != "" {
			p := bareID(t.ParentID)
			children[p] = append(children[p], bareID(t.DocID))
		}
	}
	keep := map[string]bool{root: true}
	queue := []string{root}
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		for _, c := range children[id] {
			if !keep[c] {
				keep[c] = true
				queue = append(queue, c)
			}
		}
	}

	out := snap
	out.Tasks = make([]Task, 0, len(keep))
	out.Counts = map[string]int{}
	for _, t := range snap.Tasks {
		if keep[bareID(t.DocID)] {
			out.Tasks = append(out.Tasks, t)
			// "ready" is the board's own overlay on an open row; prime counts it
			// as open, so the scoped counts do too.
			life := t.Lifecycle
			if life == lifeReady {
				life = lifeOpen
			}
			out.Counts[life]++
		}
	}
	out.Events = nil
	for _, e := range snap.Events {
		if keep[bareID(e.DocID)] {
			out.Events = append(out.Events, e)
		}
	}
	return out
}
