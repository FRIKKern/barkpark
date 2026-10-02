package main

import (
	"strings"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// paperDocCache is the document cache the paper pane's three reference
// resolvers read through. It exists because they did not have one: taskChipResolver,
// paperValueResolver and paperRefResolver each called DataStore.QueryResult —
// an unconditional HTTP GET, no cache layer anywhere in the path — from INSIDE
// a synchronous render pass, and paperRefResolver did it once per schema PER
// REFERENCE NODE with no memo at all.
//
// The measured cost of one render of a paper with 4 reference nodes, 2
// valuerefs and 2 task chips across 5 schemas (paper_render_requests_test.go,
// which is the instrument, not a claim): 10 requests when the referenced type
// heads the schema scan, 26 when it trails it — M*N + M + 1. Through this cache
// the same render costs 5: one page per type, once.
//
// TWO LIFETIMES, and the difference is the point:
//
//   - Held on the model (m.paperDocs), the cache outlives a render pass, so the
//     SECOND and every later render of the same paper — every keystroke, every
//     resize, every scroll — issues ZERO requests. That is what makes the pane
//     stop blocking on the network.
//   - Absent (a zero-value model in a test, say), buildPaperContent makes a
//     throwaway one for the pass, which still collapses the per-node scan.
//
// The first render of a paper still fetches: this is a cache, not an async
// resolve, and the cache is honest about that. What it removes is the
// re-fetching — the N-per-node blowup within a pass, and the whole cost again
// on every subsequent frame.
//
// STALENESS is bounded by invalidation, not by a clock. refreshDocViews()
// clears the cache, and that is the single funnel every mutation and every
// DataStoreRefreshMsg (the SSE echo of any change, including a Studio edit)
// already runs through; applyScope clears it too, because a scope change makes
// every cached page answer for the wrong dataset.
//
// It is NOT safe for concurrent use: the TUI renders on one goroutine.
type paperDocCache struct {
	ds *DataStore

	// pages memoises one QueryResult per type for the cache's lifetime.
	pages map[string]paperCachedPage

	// index is the id→doc map shared by paperValueResolver and paperRefResolver,
	// built once from a sweep of every schema.
	index       map[string]Doc
	indexFailed bool
	indexBuilt  bool

	// chips is the task-chip map keyed in BOTH the published and `drafts.`
	// spellings, built once from the task page.
	chips       map[string]*pdrender.TaskChip
	chipsFailed bool
	chipsBuilt  bool
}

// paperCachedPage is one type's page plus whether the read behind it FAILED.
// The distinction is load-bearing: a refused read and an empty type both yield
// zero docs, and the resolvers report the difference through readFailed.
type paperCachedPage struct {
	docs   []Doc
	failed bool
}

func newPaperDocCache(ds *DataStore) *paperDocCache {
	return &paperDocCache{ds: ds}
}

// invalidate drops everything the cache holds. The next lookup re-reads.
func (c *paperDocCache) invalidate() {
	if c == nil {
		return
	}
	c.pages = nil
	c.index = nil
	c.indexFailed = false
	c.indexBuilt = false
	c.chips = nil
	c.chipsFailed = false
	c.chipsBuilt = false
}

// page returns one type's documents and whether the read behind them failed,
// querying the store at most ONCE per type per cache lifetime.
func (c *paperDocCache) page(typeName string) ([]Doc, bool) {
	if c == nil || c.ds == nil || typeName == "" {
		return nil, false
	}
	if p, ok := c.pages[typeName]; ok {
		return p.docs, p.failed
	}
	docs, outcome := c.ds.QueryResult(typeName, "")
	p := paperCachedPage{docs: docs, failed: outcome.Failed()}
	if c.pages == nil {
		c.pages = map[string]paperCachedPage{}
	}
	c.pages[typeName] = p
	return p.docs, p.failed
}

// docIndex returns the id→doc map across every loaded schema, plus whether ANY
// type's read failed. It preserves the two rules the two callers depended on:
//
//   - first-taken wins for a duplicate id (D3: the published spelling is
//     preferred at LOOKUP time, by trying `id` before `drafts.`+id), EXCEPT that
//     a stored doc with an empty title is upgraded by a later one that has a
//     title — paperRefResolver's scan used to walk PAST a title-less match, and
//     collapsing the scan into a map must not quietly change that answer.
//   - the failure flag is the OR across the sweep, reported by the caller only
//     when the id was not found anyway, so a reference that resolved never cries
//     wolf about an unrelated type's refusal.
func (c *paperDocCache) docIndex() (map[string]Doc, bool) {
	if c == nil {
		return nil, false
	}
	if c.indexBuilt {
		return c.index, c.indexFailed
	}
	c.index = map[string]Doc{}
	c.indexBuilt = true
	for i := range schemas {
		page, failed := c.page(schemas[i].Name)
		if failed {
			c.indexFailed = true
		}
		for _, d := range page {
			if d.ID == "" {
				continue
			}
			prev, taken := c.index[d.ID]
			if taken && !(prev.Title == "" && d.Title != "") {
				continue
			}
			c.index[d.ID] = d
		}
	}
	return c.index, c.indexFailed
}

// taskChips returns the task-chip map (keyed in both spellings) and whether the
// task read failed.
func (c *paperDocCache) taskChips() (map[string]*pdrender.TaskChip, bool) {
	if c == nil {
		return nil, false
	}
	if c.chipsBuilt {
		return c.chips, c.chipsFailed
	}
	c.chips = map[string]*pdrender.TaskChip{}
	c.chipsBuilt = true
	docs, failed := c.page("task")
	c.chipsFailed = failed
	for _, d := range docs {
		if d.ID == "" {
			continue
		}
		chip := taskChipFromDoc(d)
		pub := strings.TrimPrefix(d.ID, "drafts.")
		c.chips[pub] = chip
		c.chips["drafts."+pub] = chip
	}
	return c.chips, c.chipsFailed
}
