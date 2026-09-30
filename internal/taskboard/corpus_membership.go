package taskboard

import (
	"context"
	"encoding/json"
	"net/url"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// corpus_membership.go is the CHEAP half of the periodic resync
// (task-1ca34359dc0805df).
//
// fullResyncEvery exists for ONE question the incremental head walk cannot
// answer: which rows VANISHED without a write (a hard delete, a twin collapse
// that changes which row the index projects). Answering it by re-downloading
// the whole corpus cost ~14 MB on guerrilla under `?view=board` — measured
// 2026-09-30 as the one 60 s window in ten that broke the row's 10 MB bar
// (14,266,448 B of /v1/tasks at t=120..180 s, every other window ~1 MB).
//
// Membership needs far less than the rows: the doc_id set and each row's
// updated_at. `GET /v1/tasks?view=ids` serves exactly that — same query, scope,
// ordering and cursor as every other view — at ~1 MB for the same corpus. The
// resync becomes:
//
//  1. walk the ids view to the end of the cursor (exhaustive or nothing);
//  2. drop every base row the server no longer lists;
//  3. REFUSE (fall back to the honest full walk) on anything the prune cannot
//     explain: a listed row the base lacks, or a base row whose updated_at
//     disagrees with the server's, at or below the watermark. Rows NEWER than
//     the watermark are not a disagreement — the head walk that runs right
//     after picks them up exactly as it does on every re-list;
//  4. run the ordinary incremental head walk over the pruned base.
//
// Any failure — a server without the view (400), a transport error, a short
// walk — falls back to the full walk that shipped before this file, so the
// cheap path can only ever make the resync cheaper, never less honest.

// idsViewParam is the `?view=` fragment of the membership walk.
const idsViewParam = "&view=ids"

// membershipRow is one row of the ids view.
type membershipRow struct {
	DocID     string    `json:"doc_id"`
	UpdatedAt time.Time `json:"updated_at"`
}

// resyncByMembershipUsable is incrementalUsable WITHOUT the age gate: a base
// that is structurally sound (exhaustive, non-empty, watermarked, with a known
// lastFull) but merely DUE for its periodic re-read can be re-verified by
// membership instead of re-downloaded. A base that fails any structural test
// still takes the full walk.
func resyncByMembershipUsable(base corpusBase) bool {
	return base.exhaustive && len(base.tasks) > 0 && !base.watermark.IsZero() && !base.lastFull.IsZero()
}

// fetchMembership walks the ids view to the end of its cursor. ok=false means
// the walk cannot vouch for the WHOLE population (a pre-cursor server, the page
// cap) — a partial membership list would prune rows that merely sat past the
// last page, which is the silent loss this whole path must never cause.
func fetchMembership(ctx context.Context, c *apiclient.Client) (map[string]time.Time, bool, error) {
	out := map[string]time.Time{}
	cursor := ""
	for page := 0; page < maxTaskPages; page++ {
		body, err := getJSONCtx(ctx, c, listFetchPath+idsViewParam+"&cursor="+url.QueryEscape(cursor))
		if err != nil {
			return nil, false, err
		}
		var env struct {
			Docs []membershipRow `json:"docs"`
		}
		if err := json.Unmarshal(body, &env); err != nil {
			return nil, false, err
		}
		for _, r := range env.Docs {
			if r.DocID == "" || r.UpdatedAt.IsZero() {
				// A row the prune cannot place is a row it cannot vouch for.
				return nil, false, nil
			}
			out[r.DocID] = r.UpdatedAt
		}
		next, capable := decodeNextCursor(body)
		if !capable {
			return nil, false, nil
		}
		if next == "" {
			return out, true, nil
		}
		cursor = next
	}
	return nil, false, nil
}

// pruneByMembership applies the server's membership to the base. It returns the
// pruned base and ok=true only when every difference is explained by a vanished
// row or by a write newer than the watermark; anything else is ok=false and the
// caller takes the full walk.
func pruneByMembership(base corpusBase, members map[string]time.Time) (corpusBase, int, bool) {
	inBase := make(map[string]bool, len(base.tasks))
	kept := make([]Task, 0, len(base.tasks))
	dropped := 0
	for _, t := range base.tasks {
		inBase[t.DocID] = true
		at, listed := members[t.DocID]
		if !listed {
			dropped++
			continue
		}
		if !at.After(base.watermark) && !at.Equal(t.UpdatedAt) {
			// The server holds a different version of this row at or below the
			// watermark: the head walk will never revisit it. Only a full read
			// can say what the row is now.
			return corpusBase{}, 0, false
		}
		kept = append(kept, t)
	}
	for id, at := range members {
		if !inBase[id] && !at.After(base.watermark) {
			// A row the base never saw that the head walk will not reach either.
			return corpusBase{}, 0, false
		}
	}
	details := make(DetailIndex, len(base.details))
	for id, d := range base.details {
		if _, listed := members[id]; listed {
			details[id] = d
		}
	}
	return corpusBase{
		tasks:      kept,
		details:    details,
		watermark:  base.watermark,
		exhaustive: true,
		lastFull:   base.lastFull,
	}, dropped, true
}

// resyncByMembership is the whole cheap resync: membership walk, prune, then the
// incremental head walk over the pruned base. ok=false (with a nil error) means
// "take the full walk"; it never returns a corpus it cannot vouch for.
func resyncByMembership(ctx context.Context, c *apiclient.Client, base corpusBase, view string, now time.Time) (corpusBase, bool, error) {
	members, exhaustive, err := fetchMembership(ctx, c)
	if err != nil || !exhaustive {
		// A refusing server (an older one answers `?view=ids` with a 400), a
		// transport failure or a short walk: the full walk decides instead.
		return corpusBase{}, false, nil
	}
	pruned, _, ok := pruneByMembership(base, members)
	if !ok {
		return corpusBase{}, false, nil
	}
	tasks, details, ok, err := fetchTaskHead(ctx, c, pruned, view)
	if err != nil {
		return corpusBase{}, false, err
	}
	if !ok {
		return corpusBase{}, false, nil
	}
	return corpusBase{
		tasks:      tasks,
		details:    details,
		watermark:  watermarkOf(tasks),
		exhaustive: true,
		// The membership walk WAS an exhaustive read of the population — the one
		// thing the full walk's lastFull certifies — so it restarts the clock.
		lastFull: now,
	}, true, nil
}
