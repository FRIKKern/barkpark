package taskboard

import (
	"context"
	"net/url"
	"sort"
	"sync"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// corpus.go is the board's INCREMENTAL RE-LIST.
//
// THE DEFECT (task-1ca34359dc0805df, re-measured on today's tree 2026-09-15
// against guerrilla, 200x50 pty, instrumented byte counters):
//
//	/v1/tasks  n=22  bytes=193,989,243  in 60 IDLE seconds, no keys pressed
//
// The corpus GET is a cursor walk to EXHAUSTION over ~10 pages of ~10 MB each
// — ~97 MB, ~25 seconds — and on a ledger a six-lead campaign is writing to,
// the 5s minRelistEvery floor is hit continuously, so the board simply runs
// that walk back to back forever. Two full walks fit in one minute; hence 194
// MB. The keyset detector (events.go) is doing its job perfectly. The problem
// is what a "yes, something moved" costs: re-downloading all ~9,000 tasks,
// nearly every one of which has not been touched in weeks.
//
// THE OBSERVATION THAT MAKES IT CHEAP. The walk is ordered desc:updated_at —
// the cursor token is literally {"k":"updated_at",…}. So the rows that changed
// since the last snapshot are exactly the PREFIX of the walk. Let W be the
// greatest updated_at in the corpus we already hold. Every row the server
// wrote after we took that corpus carries updated_at > W (a write re-stamps
// it), so:
//
//	walk from the head until a row with updated_at <= W appears
//	⟹ every changed-or-new row is in hand, and every row beyond is
//	  byte-identical to the copy we are already holding.
//
// That turns the re-list from "all 9,000 rows" into "the handful that moved",
// and the page size can shrink with it (headPageLimit) because the boundary
// lands inside the first page on a board that is merely busy rather than
// stampeding.
//
// WHAT IT DELIBERATELY DOES NOT DO. It does not apply events to rows (charter
// decision #4 is untouched: events still say only "something moved", the
// SNAPSHOT still says what is true). It does not invent an updated_since
// filter the server does not offer — every request here is the same
// /v1/tasks?limit=&cursor= route the full walk uses, asked for less of.
//
// THE ONE THING THE PREFIX CANNOT SEE is a row that DISAPPEARS without a
// write: a hard delete, or a twin collapse that changes which row the query
// projects. Nothing re-stamps updated_at on the survivor, so the vanished row
// would live on in the retained tail. fullResyncEvery bounds that: one honest
// exhaustive walk on a timer, and on the first fetch of every process. Any
// condition the incremental walk cannot discharge — no base, a base that was
// never exhaustive, a server without the cursor, more changed rows than
// maxHeadPages covers — falls straight back to the full walk, which is exactly
// the behaviour that shipped before this file.

const (
	// headPageLimit is the page size of the INCREMENTAL walk. It is small on
	// purpose: the walk stops at the first row at-or-below the watermark, so the
	// page size is the real unit of waste. Live rows measured ~10 KB each on
	// guerrilla (10.5 MB / 1000 rows), so 50 rows is a ~500 KB ceiling on
	// noticing a change instead of ~97 MB.
	headPageLimit      = 50
	headPageLimitToken = "50"
	headFetchPath      = "/v1/tasks?limit=" + headPageLimitToken

	// maxHeadPages bounds the incremental walk. Past this the changed set is so
	// large that paging it 50 at a time is no longer the cheap option, and the
	// walk hands over to the full one rather than degenerating into many small
	// requests. 20 x 50 = 1000 changed rows — the full walk's own page size.
	maxHeadPages = 20

	// fullResyncEvery is how often the board pays for an honest exhaustive walk
	// even when the incremental one could have answered. It is the ONLY thing
	// that can retire a row which vanished without a write (see the note above),
	// so it is a correctness floor, not a tuning knob. Ten minutes is ~1/120th
	// of the re-list rate the board ran at before.
	fullResyncEvery = 10 * time.Minute
)

// corpusBase is the corpus a previous walk left behind, plus the watermark the
// incremental walk measures against. A zero value means "no base": the next
// fetch is a full walk.
type corpusBase struct {
	tasks   []Task
	details DetailIndex
	// watermark is the greatest UpdatedAt in tasks. Zero disables the
	// incremental path — a corpus whose rows carry no updated_at (an older
	// envelope) cannot be prefix-diffed, and guessing one would be the silent
	// staleness this whole file exists to avoid.
	watermark time.Time
	// exhaustive records whether the walk that produced tasks reached the END of
	// the cursor. An incremental walk on top of a NON-exhaustive base would
	// inherit its hole and then call the result complete, so it is refused.
	exhaustive bool
	// lastFull is when the base last came from a full exhaustive walk.
	lastFull time.Time
}

// corpusCache holds the base between fetches. It is a package-level singleton
// because the fetch seam (FetchSnapshotFull) takes only a client — the TUI is
// the one long-lived caller and the one that benefits; every one-shot CLI verb
// (`bp task frontier`, `lint`, `next`, `cmux dispatch`) starts with an empty
// cache and therefore does exactly the full walk it did before.
type corpusCache struct {
	mu   sync.Mutex
	base corpusBase
	// flight is the corpus read currently out, or nil. It is what makes two
	// concurrent asks cost ONE walk — see fetchTaskCorpus.
	flight *corpusFlight
	// live marks a cache that outlives one fetch — the board's, not a one-shot
	// verb's. It is what makes the brief prime projection safe: see primeView.
	live bool
	// eventTail is the rolling union of every brief prime's `recent_events`,
	// newest first, capped at primeEventTailDepth. Empty on a non-live cache.
	eventTail []Event
	// persistDir/persistKey address the ON-DISK base (corpus_persist.go) — the
	// bp config dir and this board's scope key, the same pair cache.go's
	// first-paint snapshot uses. Empty on every one-shot verb's cache, which is
	// what keeps `bp task next`/`lint`/`frontier`/`cmux dispatch` byte-identical
	// to before: they neither read nor write a base.
	persistDir string
	persistKey string
	// diskRead records that the ONE disk read this cache is allowed has already
	// happened. A miss must not be retried on every walk (a missing file would
	// then cost a stat per re-list forever), and a hit must never re-seed over a
	// base the live walks have since moved forward.
	diskRead bool
}

// corpusFlight is one in-progress corpus read. Every caller that arrives while
// it is out waits on done and reads the same answer instead of starting a
// second walk of its own.
type corpusFlight struct {
	done       chan struct{}
	tasks      []Task
	details    DetailIndex
	exhaustive bool
	err        error
}

// primeViewBrief is the value fetchPrime sends as `?view=`. It is a CONSTANT
// rather than a bool so the query string is written once, in one place.
const primeViewBrief = "brief"

// primeEventTailDepth is how deep the rebuilt event tail is allowed to grow: the
// same 100 the FULL prime arm returns at primeReadyLimit, so a live board that
// has been up for a few ticks sees the tail it saw before the brief projection.
const primeEventTailDepth = 100

// primeView reports the `?view=` fetchPrime should ask for through THIS cache.
//
// The discriminator is the cache's own lifetime, which is already the exact
// distinction this needs (detail_data.go): every one-shot verb — `bp task next`,
// `bp task frontier`, `bp task lint`, `bp cmux dispatch`, the chat transport —
// reaches the fetch with a BARE, per-call corpusCache and gets exactly one prime
// body, so a 5-row event tail there would be a silent narrowing of
// computeResumables with nothing to refill it. Those callers keep the full view
// and stay byte-identical. The LIVE board (newSnapshotFetcher) carries its cache
// across every re-list of one long-lived process, so it can take the 96.8% cut
// and rebuild the tail from the 5 newest rows each tick.
func (cc *corpusCache) primeView() string {
	if cc == nil || !cc.live {
		return ""
	}
	return primeViewBrief
}

// listView reports the `?view=` fragment the CORPUS GET should carry through
// THIS cache — `boardViewParam` for a live board, "" (the default shape) for a
// one-shot verb.
//
// The discriminator is deliberately the SAME one primeView uses, for the same
// reason and with a sharper edge. `?view=board` deletes `content`, and the
// DetailIndex the list body hydrates is where `bp task enrichment` reads
// `Disposition`/`CloseReason` and where `bp task frontier` reads `design_doc`.
// Those verbs reach the fetch through FetchSnapshotFull with a BARE cache, get
// exactly one corpus read, and have nowhere to hydrate the prose from — so
// they keep the full view and stay byte-identical. The LIVE board is the one
// caller the criterion is about ("the bp tasks board's LIST/POLL path"), and it
// is also the only one that CAN pay the difference: it re-reads the corpus
// every few seconds, and it opens prose one row at a time, which the always-
// full row route answers (FetchTaskDetailByID).
func (cc *corpusCache) listView() string {
	if cc == nil || !cc.live {
		return ""
	}
	return boardViewParam
}

// mergeEventTail folds one prime's `recent_events` into the cache's rolling tail
// and returns the merged tail, newest first, capped at primeEventTailDepth.
//
// WHY A RING AND NOT JUST THE 5. The brief arm answers with the 5 newest task
// mutations; the full arm answered with 100. Since a live board asks every few
// seconds and each answer OVERLAPS the last, the union across ticks is the same
// tail — it just takes a few ticks to fill after launch, which is stated here
// rather than hidden: the first brief frame carries 5 events where the old full
// frame carried 100, and computeResumables on that FIRST frame sees less.
//
// Dedup is by (mutation, doc_id, at). prime's rows carry no `id` (Tasks.Prime's
// select is event/doc_id/at only), so the triple is the whole identity there is;
// two genuinely distinct mutations sharing all three are indistinguishable ON THE
// WIRE and collapsing them is the honest answer, not a loss.
func (cc *corpusCache) mergeEventTail(fresh []Event) []Event {
	// A one-shot cache does not merge AT ALL — not even a sort or a dedup. The
	// full arm already handed it the whole tail, and an identity claim that
	// quietly reorders is not an identity claim.
	if cc == nil || !cc.live {
		return fresh
	}
	cc.mu.Lock()
	defer cc.mu.Unlock()
	merged := make([]Event, 0, len(cc.eventTail)+len(fresh))
	seen := make(map[string]bool, len(cc.eventTail)+len(fresh))
	add := func(evs []Event) {
		for _, e := range evs {
			k := e.Mutation + "\x00" + e.DocID + "\x00" + e.At.UTC().Format(time.RFC3339Nano)
			if seen[k] {
				continue
			}
			seen[k] = true
			merged = append(merged, e)
		}
	}
	add(fresh)
	add(cc.eventTail)
	sort.SliceStable(merged, func(i, j int) bool { return merged[i].At.After(merged[j].At) })
	if len(merged) > primeEventTailDepth {
		merged = merged[:primeEventTailDepth]
	}
	cc.eventTail = merged
	out := make([]Event, len(merged))
	copy(out, merged)
	return out
}

func (cc *corpusCache) snapshot() corpusBase {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	return cc.base
}

// baseForWalk is snapshot() plus the ONE-TIME disk seed: on a live board's very
// first walk the in-memory base is empty, so the persisted base (written by the
// last exhaustive walk of a previous process) is read and adopted — which is
// what turns a launch's first re-list from the ~105 MB exhaustive walk into the
// incremental head walk.
//
// THREE FENCES, all of them load-bearing:
//
//   - live only. A one-shot verb's bare cache never touches the disk, so every
//     `bp task next`/`lint`/`frontier`/`cmux dispatch` walk stays byte-identical.
//   - once only (diskRead). A miss must not re-stat per re-list; a hit must not
//     overwrite a base the live walks have already advanced past.
//   - never over an existing base. The read is attempted only while the
//     in-memory base is still empty.
//
// It deliberately does NOT relax incrementalUsable: the loaded base carries the
// lastFull of the walk that produced it, so a base older than fullResyncEvery is
// refused by the SAME gate an in-memory one would be, and the walk falls back to
// the honest exhaustive read.
func (cc *corpusCache) baseForWalk() corpusBase {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	if cc.live && !cc.diskRead && cc.base.watermark.IsZero() {
		cc.diskRead = true
		if b, ok := loadPersistedCorpus(cc.persistDir, cc.persistKey); ok {
			cc.base = b
		}
	}
	return cc.base
}

func (cc *corpusCache) store(b corpusBase) {
	cc.mu.Lock()
	cc.base = b
	cc.mu.Unlock()
}

// persist writes b as the next launch's base, on a live board only. It also
// marks the disk read as DONE: a cache that has already produced its own
// exhaustive base has nothing to learn from an older file, and skipping the
// read keeps the seed a launch-time event rather than something that could fire
// mid-session after a base was cleared.
func (cc *corpusCache) persist(b corpusBase) {
	cc.mu.Lock()
	live, dir, key := cc.live, cc.persistDir, cc.persistKey
	cc.diskRead = true
	cc.mu.Unlock()
	if !live {
		return
	}
	savePersistedCorpus(dir, key, b)
}

// watermarkOf is the greatest non-zero UpdatedAt across tasks. A corpus in
// which NO row carries an updated_at returns the zero time, which the caller
// reads as "no incremental path available".
func watermarkOf(tasks []Task) time.Time {
	var w time.Time
	for _, t := range tasks {
		if t.UpdatedAt.After(w) {
			w = t.UpdatedAt
		}
	}
	return w
}

// fetchTaskCorpus is the corpus GET the board's snapshot path calls. It walks
// the changed PREFIX when it safely can and the whole cursor when it cannot,
// and it reports exhaustiveness with the same meaning fetchTaskPages always
// did: true only when the returned corpus is the whole world.
// fetchTaskCorpus is the corpus GET, made SINGLE-FLIGHT: while one read is out,
// every other caller on the same cache waits for it and reads its answer.
//
// THE SECOND DEFECT THIS FILE EXISTS FOR (measured 2026-09-17, guerrilla,
// 200x50 pty, the wirelog.go byte counter):
//
//	/v1/tasks  n=36  bytes=204,631,877  in the FIRST 60 seconds from launch
//
// against ~99.9 MB for ONE exhaustive walk on the same ledger in the same
// minute. The board pays the cold walk TWICE, concurrently, because the
// no-overlap guard the tick path enforces (tickRefetchCmd's fetchInFlight) is
// not reachable from Init: Init calls refetchCmd DIRECTLY on a value receiver,
// so nothing records that a fetch is out, and the first events poll's delta
// — which arrives long before a ~16 s walk finishes — starts a second full
// walk beside the first. Worse, neither can serve as the other's base: the
// incremental path needs a STORED exhaustive corpus, and the first walk has
// not stored one yet, so the second is full too.
//
// The guard therefore belongs where the walk is, not where the tick is. It is
// the cache, not the model, that knows a walk is out, and it is the only place
// that catches the race for EVERY caller (Init, the tick path, the post-action
// reconcile) rather than for the one that happens to hold a mutable Model.
//
// A waiter gets a COPY of the leader's slice and map: the two callers go on to
// compose separate snapshots, and a shared backing array that one of them sorts
// is a data race that a byte saving does not justify.
func fetchTaskCorpus(ctx context.Context, c *apiclient.Client, cc *corpusCache, now time.Time) ([]Task, DetailIndex, bool, error) {
	cc.mu.Lock()
	if f := cc.flight; f != nil {
		cc.mu.Unlock()
		select {
		case <-f.done:
			if f.err != nil {
				return nil, nil, false, f.err
			}
			return copyTasks(f.tasks), copyDetails(f.details), f.exhaustive, nil
		case <-ctx.Done():
			// This caller's own budget ran out. The leader is untouched.
			return nil, nil, false, ctx.Err()
		}
	}
	f := &corpusFlight{done: make(chan struct{})}
	cc.flight = f
	cc.mu.Unlock()

	f.tasks, f.details, f.exhaustive, f.err = fetchTaskCorpusWalk(ctx, c, cc, now)

	cc.mu.Lock()
	cc.flight = nil
	cc.mu.Unlock()
	close(f.done)
	// THE LEADER TAKES A COPY TOO — this is not symmetry for its own sake.
	//
	// f.tasks/f.details are the SAME containers fetchTaskCorpusWalk just stored
	// as the cache's base, and they stay readable by every waiter parked on
	// f.done. The leader's own caller goes on to mutate them in place:
	// fetchSnapshotWith hands `details` to syncDetails, which re-embeds the
	// composed board row into every entry. Handing the leader the originals
	// therefore did two things at once —
	//
	//	fatal error: concurrent map iteration and map write
	//	  taskboard.copyDetails(...)     <- the waiter's copy, in this file
	//	  taskboard.fetchTaskCorpus(...) <- the waiter's return, in this file
	//
	// a waiter iterating the map while the leader's syncDetails writes it, which
	// KILLED THE PROCESS about ten seconds after the cold walk landed (measured
	// on guerrilla 2026-09-18: `bp tasks` died at 29.3 s from launch, twice out
	// of two runs, both times immediately after the 9-page walk completed) — and,
	// quietly, it let the board rewrite the stored base's rows behind the cache's
	// back.
	//
	// The crash is why the incremental re-list of PR #18468 had never once armed
	// in the field: arming needs a SECOND re-list in the same process, and the
	// process did not survive its first one. Copying here is what lets a board
	// live long enough to be cheap.
	return copyTasks(f.tasks), copyDetails(f.details), f.exhaustive, f.err
}

// copyTasks / copyDetails hand a waiter its own containers. The Task values and
// detail values themselves are treated as immutable once decoded — the board
// replaces rows, it does not write through them.
func copyTasks(in []Task) []Task {
	if in == nil {
		return nil
	}
	out := make([]Task, len(in))
	copy(out, in)
	return out
}

func copyDetails(in DetailIndex) DetailIndex {
	if in == nil {
		return nil
	}
	out := make(DetailIndex, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

// fetchTaskCorpusWalk is the walk itself: the incremental prefix when it can
// honestly answer, the exhaustive cursor when it cannot. It is what shipped as
// fetchTaskCorpus before the single-flight wrapper above.
func fetchTaskCorpusWalk(ctx context.Context, c *apiclient.Client, cc *corpusCache, now time.Time) ([]Task, DetailIndex, bool, error) {
	base := cc.baseForWalk()
	if incrementalUsable(base, now) {
		tasks, details, ok, err := fetchTaskHead(ctx, c, base, cc.listView())
		if err != nil {
			return nil, nil, false, err
		}
		if ok {
			cc.store(corpusBase{
				tasks:      tasks,
				details:    details,
				watermark:  watermarkOf(tasks),
				exhaustive: true,
				lastFull:   base.lastFull,
			})
			return tasks, details, true, nil
		}
		// ok=false is never an error — it is "the incremental walk cannot
		// honestly answer this one". Fall through to the full walk.
	}
	tasks, details, exhaustive, err := fetchTaskPages(ctx, c, listFetchPath+cc.listView())
	if err != nil {
		return nil, nil, false, err
	}
	if exhaustive {
		fresh := corpusBase{
			tasks:      tasks,
			details:    details,
			watermark:  watermarkOf(tasks),
			exhaustive: true,
			lastFull:   now,
		}
		cc.store(fresh)
		// Persist ONLY here — the full-walk arm. The incremental arm above stores
		// a base too, but it runs every few seconds on a busy ledger, and
		// re-marshalling the whole corpus to disk at that cadence is the write
		// amplification this file exists to avoid paying on the WIRE. The full
		// walk runs at most once per fullResyncEvery plus once at launch, and its
		// output is exactly the state a load is allowed to adopt.
		cc.persist(fresh)
	}
	// A short walk must not become a base — the next incremental walk would
	// stack a prefix on top of a hole and call the result complete — so the
	// `exhaustive` arm above is the ONLY writer of a base.
	//
	// It must not DESTROY one either, which is what the `else cc.store(
	// corpusBase{})` that stood here did. Losing state because a walk ran out of
	// page budget is the defect, not the remedy: the wipe was self-perpetuating,
	// since the base it threw away is precisely the thing that would have made
	// the next walk cheap enough to finish. Keeping the old base is not serving
	// a stale one — THIS call still returns the short walk with exhaustive=false,
	// so nothing on screen is older than the read that produced it — and the
	// base cannot go stale unnoticed because incrementalUsable refuses any base
	// whose lastFull is older than fullResyncEvery.
	return tasks, details, exhaustive, nil
}

// incrementalUsable is the precondition, stated in one place so every refusal
// is visible: a base that came from a complete walk, carries a real watermark,
// and is not yet due for its periodic honest re-read.
func incrementalUsable(base corpusBase, now time.Time) bool {
	if !base.exhaustive || len(base.tasks) == 0 || base.watermark.IsZero() {
		return false
	}
	if base.lastFull.IsZero() || now.Sub(base.lastFull) >= fullResyncEvery {
		return false
	}
	return true
}

// fetchTaskHead walks the desc:updated_at head until it reaches a row the base
// already accounts for, then merges the fresh prefix over the base.
//
// The second return is CAN-I-ANSWER, not success: false means the caller should
// do the full walk (a pre-cursor server, a changed set past maxHeadPages, a row
// with no updated_at at the boundary). An error is reserved for a genuinely
// failed read, which the caller propagates exactly as before.
func fetchTaskHead(ctx context.Context, c *apiclient.Client, base corpusBase, view string) ([]Task, DetailIndex, bool, error) {
	var (
		fresh        []Task
		freshDetails = DetailIndex{}
		cursor       string
	)
	for page := 0; page < maxHeadPages; page++ {
		body, err := getJSONCtx(ctx, c, headFetchPath+view+"&cursor="+url.QueryEscape(cursor))
		if err != nil {
			return nil, nil, false, err
		}
		tasks, idx, err := decodeTaskListFull(body)
		if err != nil {
			return nil, nil, false, err
		}
		reached := false
		for _, t := range tasks {
			// A row with no updated_at cannot be ordered against the watermark.
			// Refusing here (rather than guessing) is what keeps the walk from
			// stopping early on a row it cannot place.
			if t.UpdatedAt.IsZero() {
				return nil, nil, false, nil
			}
			if !t.UpdatedAt.After(base.watermark) {
				// This row — and by desc:updated_at ordering every row after it —
				// is unchanged since the base was taken.
				reached = true
				break
			}
			fresh = append(fresh, t)
			if d, ok := idx[t.DocID]; ok {
				freshDetails[t.DocID] = d
			}
		}
		if reached {
			return mergeCorpus(fresh, freshDetails, base), freshDetails, true, nil
		}
		next, capable := decodeNextCursor(body)
		if !capable {
			// Pre-cursor server: it cannot page, so it cannot be walked
			// incrementally either. The full walk says so honestly.
			return nil, nil, false, nil
		}
		if next == "" {
			// The walk consumed the WHOLE corpus without ever reaching the
			// watermark — every row is newer than the base. That is a complete,
			// exhaustive corpus in its own right, so return it as one.
			return fresh, freshDetails, true, nil
		}
		cursor = next
	}
	// More changed rows than the head walk is sized for. Hand over.
	return nil, nil, false, nil
}

// mergeCorpus lays the fresh prefix over the retained base: fresh rows first in
// walk order, then every base row the prefix did not replace, in the order the
// base already held them. Because both halves are desc:updated_at and every
// fresh row is strictly newer than every retained one, the seam preserves the
// route's own ordering exactly as the full walk would have produced it.
//
// It also folds the base's DetailIndex forward for the retained rows, so a
// detail pane opened on an untouched task is as deep as it was — the saving is
// in what is re-DOWNLOADED, never in what the board can show.
func mergeCorpus(fresh []Task, freshDetails DetailIndex, base corpusBase) []Task {
	replaced := make(map[string]bool, len(fresh))
	for _, t := range fresh {
		replaced[t.DocID] = true
	}
	out := make([]Task, 0, len(base.tasks)+len(fresh))
	out = append(out, fresh...)
	for _, t := range base.tasks {
		if replaced[t.DocID] {
			continue
		}
		out = append(out, t)
	}
	for id, d := range base.details {
		if _, ok := freshDetails[id]; !ok {
			freshDetails[id] = d
		}
	}
	return out
}
