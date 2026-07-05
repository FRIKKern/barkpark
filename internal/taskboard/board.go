package taskboard

import (
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Lifecycle values as the BOARD sees them. Storage holds a 5-value enum —
// open|in_progress|blocked|done|cancelled (api Tasks.Validation) — and the
// server NEVER serves "ready": readiness is derived by the engine's queue
// (lifecycle open|blocked + every blocks-edge satisfied) and overlaid onto the
// fetched tasks by composeSnapshot from prime's ready head. "closed" is
// defensive: an alias some callers emit for a terminated task. The board
// treats any value it does not recognise as an ordinary non-terminal row
// (ranked just after "open").
const (
	lifeInProgress = "in_progress"
	lifeReady      = "ready"
	lifeBlocked    = "blocked"
	lifeOpen       = "open"
	lifeDone       = "done"
	lifeClosed     = "closed"
	lifeCancelled  = "cancelled"
)

// kindGoal roots an epic. A goal always heads its own section even with no
// children; every other parentless task is an orphan unless it heads a subtree.
const kindGoal = "goal"

// Attention-policy thresholds. Boundaries are EXCLUSIVE: an epic idle exactly 7d
// is not yet dormant — the collapse only trips once the age is strictly past the
// threshold. (Wave-11 D50 dropped the done-fold AGE gate entirely: done never
// grants a row by being young; it folds regardless of age, keeping only the <=2
// freshest as a dim completion cue — see buildEpic and doneCueMax.)
const (
	dormantAfter = 7 * 24 * time.Hour
	// staleBandAfter is the age past which a NON-terminal row sinks into the
	// stale band (below open, above terminal) — a visible "this hasn't moved"
	// demotion inside the same ordered list, no toggle. Exclusive like the others.
	staleBandAfter = 7 * 24 * time.Hour
	// staleCountAfter is the (shorter) age that makes a non-terminal task count
	// toward Board.Stale — the header's cold-work tally trips earlier than the
	// band demotion so the number warns before rows visibly rot.
	staleCountAfter = 3 * 24 * time.Hour
)

// doneCueMax is how many of a section's FRESHEST done children survive the
// terminal fold as a dim completion CUE (charter D50 / wave-11). Age no longer
// grants a done row: every terminal child beyond this count folds into the
// "+N done" tally regardless of how young it is, so a mass-close (the auth epic's
// ~25 fresh ✓ closes) never floods the view. The cue rows ride childBand 6 (the
// section bottom) and render ONLY when the section shows child rows (focus /
// explicit expand — a header/inactive section shows none).
const doneCueMax = 2

// Focus-window sizes (charter D51 / wave-11). Around each active/blocked seed the
// board shows a bounded neighborhood — its context — instead of a flat head:
// up to focusParents ancestors, focusSiblings ready siblings, focusChildren
// direct children. Merged across seeds and capped at focusWindowMax so two active
// tasks near each other read as ONE wider neighborhood, never two lists.
const (
	focusParents   = 2
	focusSiblings  = 3
	focusChildren  = 3
	focusWindowMax = 12
)

// Cluster derivation policy. A loose task's cluster KEY is its first proj: label,
// else its first area: label, else the most-shared of its remaining labels that
// at least clusterShareMin loose tasks carry (frequency desc, ties lexically
// first) — phase: labels NEVER key a cluster. A key needs clusterMemberMin member
// tasks before it becomes a Cluster; a lone-keyed task falls back to an orphan.
const (
	labelProjPrefix  = "proj:"
	labelAreaPrefix  = "area:"
	labelPhasePrefix = "phase:"
	clusterShareMin  = 3 // a plain (non-proj/area) label must be this common to key
	clusterMemberMin = 2 // a key needs this many members to form a Cluster
)

// Relatedness thresholds on title-token Jaccard. An unclustered orphan gets a
// cluster SUGGESTION at suggestThreshold; two same-group tasks are TWINS (likely
// the same work) at the higher twinThreshold.
const (
	suggestThreshold = 0.4
	twinThreshold    = 0.6
)

// anyInNow reports whether any task in the slice is a NOW-pinned claim — the
// shared "does this section own active work" test behind Epic/Cluster.Active and
// Board.OrphansActive (wave-7 decision 32). It runs against the SAME nowSet the
// NOW de-dup uses, so a section is Active exactly when it contributes a row to
// the pinned band.
func anyInNow(tasks []Task, nowSet map[string]bool) bool {
	for _, t := range tasks {
		if nowSet[t.DocID] {
			return true
		}
	}
	return false
}

// priorityRank maps a priority string to a sort key: lower ranks first. The live
// corpus stores a numeric 0–4 string (P0 most urgent); a leading "P"/"p" is
// tolerated so both "0" and "P0" rank identically. An absent or non-numeric
// priority sorts LAST (maxInt), so unprioritized ready work never jumps the queue.
func priorityRank(p string) int {
	s := strings.TrimSpace(p)
	s = strings.TrimPrefix(s, "P")
	s = strings.TrimPrefix(s, "p")
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return int(^uint(0) >> 1) // maxInt — absent/non-numeric last
}

// lastActivity is a task's freshest movement across the three signals the wire
// already carries (charter D49 / wave-11): updated_at, the claim time, and the
// newest matching prime event. bareID-normalized so a drafts.* task id matches
// an event id. This is the atom recency ranking is built on.
func lastActivity(t Task, evAt map[string]time.Time) time.Time {
	la := t.UpdatedAt
	if t.Claim != nil && t.Claim.ClaimedAt.After(la) {
		la = t.Claim.ClaimedAt
	}
	if a, ok := evAt[bareID(t.DocID)]; ok && a.After(la) {
		la = a
	}
	return la
}

// sectionActivity is the newest lastActivity across a task set (charter D49):
// the WHOLE member set INCLUDING the folded done/cancelled and the NOW-pinned
// claims — computed BEFORE any fold strips rows, so a mass-close's recency is not
// thrown away with the folded rows and a just-worked epic keeps its top rank.
func sectionActivity(tasks []Task, evAt map[string]time.Time) time.Time {
	var la time.Time
	for _, t := range tasks {
		if a := lastActivity(t, evAt); a.After(la) {
			la = a
		}
	}
	return la
}

// BuildBoard is the ENTIRE zero-config organization policy for the portrait
// task TUI. It is pure: the same (snapshot, repo, now) always yields the same
// Board, and it never reads the wall clock — the now parameter is the only
// notion of "current time", so goldens and unit tests are deterministic.
//
// Policy, in order:
//   - NOW  = tasks holding a LIVE claim (claim present, worker non-empty) whose
//     lifecycle is in_progress, newest-updated first. A swept lease clears the
//     worker (and the server reverts lifecycle to open), so expired claims fall
//     out of NOW automatically — the board trusts the server's claim truth.
//   - EPICS = parent-rooted groups. A root is a task whose parent is empty or
//     points at a doc absent from the snapshot. A root becomes an epic when it
//     is a goal OR heads a subtree (has children); a lone parentless non-goal
//     task is an orphan instead. Within an epic, children order
//     in_progress -> ready -> blocked -> open (updated desc inside each), with
//     recent terminal rows (done/closed/cancelled younger than 24h) pinned at
//     the bottom and older terminal rows folded into DoneFolded. An epic whose
//     freshest member is older than 7d is Dormant.
//   - Epics rank by freshest member (updated desc), with a boost that floats any
//     epic mentioning a repo-correlated task above the unmentioned ones.
//   - ORPHANS = every parentless non-goal leaf. Terminal orphans older than
//     the fold threshold collapse into OrphansFolded (the flat-queue live shape
//     is dominated by long-closed loose tasks); the survivors are band-ordered
//     exactly like epic children (in_progress -> ready -> blocked -> open ->
//     recent-terminal, updated desc inside each band) rather than a raw
//     updated-desc mix, so the live rows sit above the just-closed tail.
func BuildBoard(s Snapshot, repo RepoContext, now time.Time) Board {
	board := Board{
		Counts:           s.Counts,
		Events:           s.Events,
		ReadyHeadClamped: s.ReadyHeadClamped,
		TaskCount:        len(s.Tasks),
	}

	byID := make(map[string]Task, len(s.Tasks))
	for _, t := range s.Tasks {
		byID[t.DocID] = t
	}

	// evAt indexes the freshest prime event per (bareID) task — the third recency
	// signal lastActivity/sectionActivity fold in (charter D49). Built once here so
	// the per-section recency clock is a map lookup, not a scan of s.Events.
	evAt := make(map[string]time.Time, len(s.Events))
	for _, e := range s.Events {
		id := bareID(e.DocID)
		if a, ok := evAt[id]; !ok || e.At.After(a) {
			evAt[id] = e.At
		}
	}

	// NOW band: live claims that are still in_progress, freshest first.
	for _, t := range s.Tasks {
		if t.Claim != nil && t.Claim.Worker != "" && t.Lifecycle == lifeInProgress {
			board.Now = append(board.Now, t)
		}
	}
	sortByUpdatedDesc(board.Now)

	// NOW de-dup (charter D14/decision 6): a claimed task renders ONLY in the NOW
	// band, never again as a row inside its epic / cluster / orphan pile. nowSet is
	// the exclusion index; a NOW task that is a leaf drops out of the spine
	// entirely (it lives in the pinned band), and a NOW task that heads a subtree
	// still keeps its epic HEADER (the header is structure, not a duplicate row).
	nowSet := make(map[string]bool, len(board.Now))
	for _, t := range board.Now {
		nowSet[t.DocID] = true
	}

	// Group every task under its epic root (walk the parent chain to the top /
	// to a dangling pointer). rootOrder preserves first-seen order so the later
	// stable sort is deterministic regardless of map iteration.
	groups := make(map[string][]Task)
	var rootOrder []string
	for _, t := range s.Tasks {
		r := rootOf(t, byID)
		if _, seen := groups[r]; !seen {
			rootOrder = append(rootOrder, r)
		}
		groups[r] = append(groups[r], t)
	}

	for _, rootID := range rootOrder {
		members := groups[rootID]
		root := byID[rootID]

		// children is the FULL descendant set (everything but the root). The
		// NOW-pinned claims stay in here through epic ranking + dormancy; they are
		// stripped for display by dedupNowFromEpics after sortEpics below.
		children := make([]Task, 0, len(members))
		for _, m := range members {
			if m.DocID != rootID {
				children = append(children, m)
			}
		}

		// A goal always headlines; a non-goal root only earns a section when it
		// actually heads a subtree. Everything else is a loose leaf. A claimed
		// leaf joins the pile too — like the epic children above, it is stripped
		// for DISPLAY only after cluster derivation + ranking (see below), so a
		// claim can never dissolve its cluster or demote its cluster's rank.
		if root.Kind != kindGoal && len(children) == 0 {
			board.Orphans = append(board.Orphans, root)
			continue
		}
		epic := buildEpic(root, children, now, evAt)
		// Active (wave-7 decision 32) = the epic owns a NOW task. Computed here,
		// while the full descendant set + root are in hand and BEFORE
		// dedupNowFromEpics strips the claims for display, so it sees exactly which
		// sections contribute to the pinned band. A live claim always outranks
		// recency (charter D49), so Active is the first sortEpics key.
		epic.Active = nowSet[root.DocID] || anyInNow(children, nowSet)
		// LastActivity ranks the section by recency (charter D49): the newest
		// movement across the WHOLE member set (root + every descendant + claims +
		// the soon-to-be-folded done), computed HERE where `members` is in hand and
		// BEFORE buildEpic's fold strips the done rows — so a mass-close keeps the
		// epic near the top instead of sinking with its folded closes.
		epic.LastActivity = sectionActivity(members, evAt)
		board.Epics = append(board.Epics, epic)
	}

	// nowByRoot maps an epic root -> its live NOW claims, the focus-window anchors
	// (charter D51): the active work each section's neighborhood is drawn around.
	nowByRoot := make(map[string][]Task, len(board.Now))
	for _, t := range board.Now {
		r := rootOf(t, byID)
		nowByRoot[r] = append(nowByRoot[r], t)
	}

	sortEpics(board.Epics, repo)
	// Strip the NOW-pinned claims from the ranked epics' displayed children (D14).
	dedupNowFromEpics(board.Epics, nowSet)
	// Focus windows (charter D51): now that each epic's children are FINAL (claims
	// stripped, done folded to the <=2 cue), compute the neighborhood the board
	// shows around active/blocked work. Empty set => the epic renders header+rollup
	// only (inactive); non-empty => modeFocus shows exactly this neighborhood.
	for i := range board.Epics {
		e := &board.Epics[i]
		e.FocusSet = sectionFocus(e.Children, nowByRoot[e.Root.DocID])
	}
	board.Orphans, board.OrphansFolded, board.OrphansCancelledFolded = foldStaleOrphans(board.Orphans, now, evAt)
	orderChildren(board.Orphans, now)

	// Carve derived clusters out of the loose-orphan pile: labels that relate
	// tasks become named sections so the flat "(no epic)" queue self-organizes.
	// deriveClusters sets each cluster's Active (owns a NOW claim) and LastActivity
	// (recency clock, charter D49) from the pre-fold members, so sortClusters can
	// rank by both. The freq map is computed against the SAME loose set the keys
	// are resolved from, so suggestion-eligibility below stays consistent.
	loose := board.Orphans
	board.Clusters, board.Orphans = deriveClusters(loose, now, nowSet, evAt)

	board.OrphansActive = anyInNow(board.Orphans, nowSet)

	// NOW de-dup for the loose pile, mirroring the epic treatment above: the
	// claims stayed in `loose` through label frequency, cluster membership and
	// freshest-member ranking — so claiming one member of a minimum-size cluster
	// never dissolves the section or drops its rank mid-session — and leave the
	// DISPLAY only now (charter D14).
	board.Clusters = dedupNowFromClusters(board.Clusters, nowSet)
	board.Orphans = stripNow(board.Orphans, nowSet)

	// Focus windows for the derived clusters + the loose bucket (charter D51),
	// mirroring the epic treatment: the neighborhood shown around active/blocked
	// loose work. The NOW anchors are the live claims whose context lives in the
	// kept member set; a lone-claim cluster with no context yields an empty set →
	// header mode, which is correct.
	for i := range board.Clusters {
		cl := &board.Clusters[i]
		cl.FocusSet = sectionFocus(cl.Tasks, nowAnchorsFor(cl.Tasks, board.Now))
	}
	board.OrphansFocusSet = sectionFocus(board.Orphans, nowAnchorsFor(board.Orphans, board.Now))

	// Twin detection: near-duplicate titles within the same group point at each
	// other so "these two are the same work" is impossible to miss. Groups are
	// epic siblings (by direct parent), whole clusters (the shared label already
	// relates them), and the loose orphans — also by direct parent, so the
	// parentless rows form one pile while dangling-parent siblings pair only
	// among themselves.
	for ei := range board.Epics {
		detectTwins(board.Epics[ei].Children)
	}
	for ci := range board.Clusters {
		assignTwins(board.Clusters[ci].Tasks, nonTerminalIndices(board.Clusters[ci].Tasks))
	}
	detectTwins(board.Orphans)

	board.Stale = countStale(s.Tasks, now)

	return board
}

// looseLabelFreq counts, per label, how many loose tasks carry it (deduped
// within a task), feeding the ≥clusterShareMin most-shared-label fallback.
func looseLabelFreq(loose []Task) map[string]int {
	freq := make(map[string]int)
	for _, t := range loose {
		seen := make(map[string]bool, len(t.Labels))
		for _, l := range t.Labels {
			if seen[l] {
				continue
			}
			seen[l] = true
			freq[l]++
		}
	}
	return freq
}

// clusterKey resolves one loose task's cluster key: first proj: label, else
// first area: label, else its most-shared remaining non-phase label carried by
// at least clusterShareMin loose tasks (frequency desc, ties lexically first).
// phase: labels never key. Empty string means "no cluster".
func clusterKey(t Task, freq map[string]int) string {
	for _, l := range t.Labels {
		if strings.HasPrefix(l, labelProjPrefix) {
			return l
		}
	}
	for _, l := range t.Labels {
		if strings.HasPrefix(l, labelAreaPrefix) {
			return l
		}
	}
	best := ""
	bestFreq := 0
	for _, l := range t.Labels {
		if strings.HasPrefix(l, labelPhasePrefix) ||
			strings.HasPrefix(l, labelProjPrefix) ||
			strings.HasPrefix(l, labelAreaPrefix) {
			continue
		}
		f := freq[l]
		if f < clusterShareMin {
			continue
		}
		if f > bestFreq || (f == bestFreq && (best == "" || l < best)) {
			bestFreq = f
			best = l
		}
	}
	return best
}

// deriveClusters splits the loose pile into label-named Clusters (keys with
// ≥clusterMemberMin members) and the remaining loose tasks (empty-key or
// lone-keyed), preserving the input order of the survivors. Each cluster folds
// its terminal members to the ≤doneCueMax cue (charter D50) and band-orders the
// rest; clusters come back Active-first then recency-first (charter D49).
func deriveClusters(loose []Task, now time.Time, nowSet map[string]bool, evAt map[string]time.Time) ([]Cluster, []Task) {
	freq := looseLabelFreq(loose)

	keyByDoc := make(map[string]string, len(loose))
	groups := make(map[string][]Task)
	var order []string
	for _, t := range loose {
		k := clusterKey(t, freq)
		keyByDoc[t.DocID] = k
		if k == "" {
			continue
		}
		if _, seen := groups[k]; !seen {
			order = append(order, k)
		}
		groups[k] = append(groups[k], t)
	}

	var clusters []Cluster
	for _, k := range order {
		if len(groups[k]) < clusterMemberMin {
			continue
		}
		clusters = append(clusters, buildCluster(k, groups[k], now, nowSet, evAt))
	}
	sortClusters(clusters)

	remaining := make([]Task, 0, len(loose))
	for _, t := range loose {
		k := keyByDoc[t.DocID]
		if k != "" && len(groups[k]) >= clusterMemberMin {
			continue // moved into a cluster
		}
		remaining = append(remaining, t)
	}
	return clusters, remaining
}

// buildCluster folds terminal members to the ≤doneCueMax freshest cue (charter
// D50, age-independent) and band-orders the survivors, mirroring buildEpic's
// child handling (minus the epic root / dormancy). Active + LastActivity are set
// from the PRE-fold members, so sortClusters ranks by both (a live claim outranks
// recency) and the recency clock survives the terminal fold.
func buildCluster(key string, members []Task, now time.Time, nowSet map[string]bool, evAt map[string]time.Time) Cluster {
	c := Cluster{Key: key, Active: anyInNow(members, nowSet), LastActivity: sectionActivity(members, evAt)}
	var nonTerm, done []Task
	for _, m := range members {
		switch {
		case m.Lifecycle == lifeCancelled: // fold away entirely (W10-B)
			c.CancelledFolded++
		case isTerminal(m.Lifecycle):
			done = append(done, m) // no age gate — folded to the cue below
		default:
			nonTerm = append(nonTerm, m)
		}
	}
	c.Tasks = keepDoneCue(nonTerm, done, evAt, &c.DoneFolded)
	orderChildren(c.Tasks, now)
	return c
}

// keepDoneCue keeps at most doneCueMax freshest done tasks as a dim completion
// cue and folds the rest into *folded (charter D50). The returned slice is
// nonTerm + the kept cue; the caller band-orders it (childBand 6 sinks the cue to
// the bottom). Age is IRRELEVANT — a fresh mass-close folds exactly like an old
// one, so done never floods.
func keepDoneCue(nonTerm, done []Task, evAt map[string]time.Time, folded *int) []Task {
	sort.SliceStable(done, func(i, j int) bool {
		return lastActivity(done[i], evAt).After(lastActivity(done[j], evAt))
	})
	if len(done) > doneCueMax {
		*folded += len(done) - doneCueMax
		done = done[:doneCueMax]
	}
	return append(nonTerm, done...)
}

// sortClusters ranks clusters Active-first (a live claim always outranks
// recency, charter D49) then by LastActivity (newest first), stably.
func sortClusters(cs []Cluster) {
	sort.SliceStable(cs, func(i, j int) bool {
		if cs[i].Active != cs[j].Active {
			return cs[i].Active
		}
		return cs[i].LastActivity.After(cs[j].LastActivity)
	})
}

// bestClusterSuggestion returns the Key of the cluster whose members' titles an
// orphan best resembles, if the best title-token Jaccard reaches suggestThreshold.
// Clusters are already freshest-first, and only strictly-greater similarity wins,
// so ties resolve to the fresher cluster deterministically.
func bestClusterSuggestion(o Task, clusters []Cluster) (string, bool) {
	ot := titleTokens(o.Title)
	if len(ot) == 0 {
		return "", false
	}
	best := 0.0
	bestKey := ""
	for _, c := range clusters {
		for _, m := range c.Tasks {
			if j := jaccard(ot, titleTokens(m.Title)); j > best {
				best = j
				bestKey = c.Key
			}
		}
	}
	if bestKey != "" && best >= suggestThreshold {
		return bestKey, true
	}
	return "", false
}

// detectTwins marks title-near-duplicates among NON-terminal tasks grouped by
// direct ParentID (siblings), mutating TwinOf in place on the passed slice.
func detectTwins(tasks []Task) {
	groups := make(map[string][]int)
	var order []string
	for i := range tasks {
		if isTerminal(tasks[i].Lifecycle) {
			continue
		}
		k := tasks[i].ParentID
		if _, seen := groups[k]; !seen {
			order = append(order, k)
		}
		groups[k] = append(groups[k], i)
	}
	for _, k := range order {
		assignTwins(tasks, groups[k])
	}
}

// nonTerminalIndices returns the indices of the non-terminal tasks in a slice —
// the one-group membership a cluster's twin pass runs over.
func nonTerminalIndices(tasks []Task) []int {
	idx := make([]int, 0, len(tasks))
	for i := range tasks {
		if !isTerminal(tasks[i].Lifecycle) {
			idx = append(idx, i)
		}
	}
	return idx
}

// assignTwins, given a homogeneous group expressed as indices into tasks, sets
// each member's TwinOf to its best title-token match at or above twinThreshold.
// Deterministic: highest Jaccard wins, ties resolve to the smaller doc_id.
func assignTwins(tasks []Task, idx []int) {
	toks := make([]map[string]bool, len(idx))
	for a, i := range idx {
		toks[a] = titleTokens(tasks[i].Title)
	}
	for a := range idx {
		bestJ := 0.0
		bestPartner := ""
		bestTitle := ""
		for b := range idx {
			if a == b {
				continue
			}
			j := jaccard(toks[a], toks[b])
			if j < twinThreshold {
				continue
			}
			partner := tasks[idx[b]].DocID
			if j > bestJ || (j == bestJ && (bestPartner == "" || partner < bestPartner)) {
				bestJ = j
				bestPartner = partner
				bestTitle = tasks[idx[b]].Title
			}
		}
		if bestPartner != "" {
			tasks[idx[a]].TwinOf = bestPartner
			tasks[idx[a]].TwinTitle = bestTitle
		}
	}
}

// titleTokens is the lowercase letter/digit token SET of a title — the unit
// both the suggestion and twin similarities are measured on. Unicode-aware so
// non-ASCII titles ("Håndter feilkø") keep whole words instead of fragmenting
// into single-letter noise around æ/ø/å.
func titleTokens(s string) map[string]bool {
	toks := make(map[string]bool)
	var b strings.Builder
	flush := func() {
		if b.Len() > 0 {
			toks[b.String()] = true
			b.Reset()
		}
	}
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		} else {
			flush()
		}
	}
	flush()
	return toks
}

// jaccard is the set-overlap ratio |A∩B| / |A∪B|; 0 when either the union is
// empty (both titles tokenless) so empty titles never spuriously match.
func jaccard(a, b map[string]bool) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	inter := 0
	for k := range a {
		if b[k] {
			inter++
		}
	}
	union := len(a) + len(b) - inter
	if union == 0 {
		return 0
	}
	return float64(inter) / float64(union)
}

// countStale tallies non-terminal tasks whose last movement is older than
// staleCountAfter — the board-wide cold-work number surfaced in the header.
func countStale(tasks []Task, now time.Time) int {
	n := 0
	for _, t := range tasks {
		if isTerminal(t.Lifecycle) {
			continue
		}
		if now.Sub(t.UpdatedAt) > staleCountAfter {
			n++
		}
	}
	return n
}

// foldStaleOrphans splits the loose-orphan pile into the rows worth showing, a
// count of DONE/closed rows folded to the tally, and a count of CANCELLED rows to
// hide. Done orphans fold to the ≤doneCueMax freshest cue regardless of age
// (charter D50 — the age gate is gone; done never floods). Cancelled orphans fold
// at ANY age (charter wave-10 W10-B). Non-terminal orphans (open/ready/
// in_progress/blocked) never fold, however old: unfinished work is never hidden.
func foldStaleOrphans(orphans []Task, now time.Time, evAt map[string]time.Time) (kept []Task, folded, cancelled int) {
	var nonTerm, done []Task
	for _, o := range orphans {
		switch {
		case o.Lifecycle == lifeCancelled: // fold away entirely, at any age (W10-B)
			cancelled++
		case isTerminal(o.Lifecycle):
			done = append(done, o) // no age gate — folded to the cue below
		default:
			nonTerm = append(nonTerm, o)
		}
	}
	kept = keepDoneCue(nonTerm, done, evAt, &folded)
	return kept, folded, cancelled
}

// rootOf walks parent pointers to the epic root: the first ancestor that is
// parentless or whose parent is absent from the snapshot. A cycle (a task tree
// that points back at itself through bad data) is broken by returning the task
// where the loop is detected, so the function always terminates.
func rootOf(t Task, byID map[string]Task) string {
	seen := make(map[string]bool)
	cur := t
	for {
		if cur.ParentID == "" {
			return cur.DocID
		}
		parent, ok := byID[cur.ParentID]
		if !ok {
			return cur.DocID // dangling parent -> this task is the root
		}
		if seen[cur.DocID] {
			return cur.DocID // cycle guard
		}
		seen[cur.DocID] = true
		cur = parent
	}
}

// buildEpic folds terminal children to the ≤doneCueMax freshest cue (charter D50
// — age-independent, so a mass-close never floods), orders the survivors, and
// marks dormancy from the freshest member (root or ANY child, including folded
// ones — a just-closed child still counts as recent movement). The NOW-pinned
// claims are still in epic.Children at this stage so dormancy sees their
// freshness; dedupNowFromEpics strips them for display AFTER the epics are ranked.
func buildEpic(root Task, children []Task, now time.Time, evAt map[string]time.Time) Epic {
	epic := Epic{Root: root}

	var nonTerm, done []Task
	for _, c := range children {
		switch {
		case c.Lifecycle == lifeCancelled:
			// Cancelled work folds entirely away, at any age (charter wave-10 W10-B) —
			// it never renders as a row, only as the trailing "· N cancelled" tail.
			epic.CancelledFolded++
		case isTerminal(c.Lifecycle):
			done = append(done, c) // no age gate — folded to the cue below
		default:
			nonTerm = append(nonTerm, c)
		}
	}
	epic.Children = keepDoneCue(nonTerm, done, evAt, &epic.DoneFolded)
	orderChildren(epic.Children, now)

	freshest := root.UpdatedAt
	for _, c := range children {
		if c.UpdatedAt.After(freshest) {
			freshest = c.UpdatedAt
		}
	}
	epic.Dormant = now.Sub(freshest) > dormantAfter

	return epic
}

// dedupNowFromEpics removes the NOW-pinned claims from every epic's displayed
// children (charter D14 — a claimed task renders ONLY in the pinned band). It
// runs AFTER sortEpics so epic ranking and dormancy still saw the claims'
// freshness; the survivors keep their band order. A claimed child leaves the
// spine but stays counted nowhere in epicProgress (it is neither folded-done nor
// a kept row), so the header digits track the not-in-flight work — the running
// tasks are shown live in NOW above.
func dedupNowFromEpics(epics []Epic, nowSet map[string]bool) {
	if len(nowSet) == 0 {
		return
	}
	for i := range epics {
		epics[i].Children = stripNow(epics[i].Children, nowSet)
	}
}

// dedupNowFromClusters strips the NOW-pinned claims from every derived
// cluster's displayed members. It runs AFTER deriveClusters, so membership,
// label frequency and freshest-member ranking all saw the claimed tasks — a
// claim can never dissolve a minimum-size cluster or demote its rank. A cluster
// left with nothing to show (no member rows AND no folded-done count) is
// dropped: unlike an epic, whose authored root still earns a header, a derived
// section exists only through its visible rows — its claims are all pinned in
// NOW, and the section re-forms untouched when they resolve.
func dedupNowFromClusters(clusters []Cluster, nowSet map[string]bool) []Cluster {
	if len(nowSet) == 0 {
		return clusters
	}
	kept := clusters[:0]
	for _, c := range clusters {
		c.Tasks = stripNow(c.Tasks, nowSet)
		if len(c.Tasks) == 0 && c.DoneFolded == 0 {
			continue
		}
		kept = append(kept, c)
	}
	return kept
}

// stripNow filters the NOW-pinned claims out of one task list, in place,
// preserving order (charter D14 — a claimed task renders ONLY in the pinned
// band). With no claims it is the identity.
func stripNow(tasks []Task, nowSet map[string]bool) []Task {
	if len(nowSet) == 0 {
		return tasks
	}
	kept := tasks[:0]
	for _, t := range tasks {
		if !nowSet[t.DocID] {
			kept = append(kept, t)
		}
	}
	return kept
}

// ── Focus windows (charter D51 / wave-11) ────────────────────────────────────

// nowAnchorsFor returns the NOW claims whose context lives in a section's kept
// member set (charter D51): a claim relates when its parent is a kept member, it
// shares a parent with a kept member, or a kept member is its child. These are
// the focus-window seeds for derived clusters and the loose bucket (epics use
// nowByRoot directly, where the root membership is exact). A claim with no kept
// context yields nothing → the section falls to header mode, which is correct.
func nowAnchorsFor(kept, now []Task) []Task {
	if len(now) == 0 || len(kept) == 0 {
		return nil
	}
	keptIDs := make(map[string]bool, len(kept))
	keptParents := make(map[string]bool, len(kept))
	for _, k := range kept {
		keptIDs[bareID(k.DocID)] = true
		if k.ParentID != "" {
			keptParents[bareID(k.ParentID)] = true
		}
	}
	var out []Task
	for _, t := range now {
		pid := bareID(t.ParentID)
		if keptIDs[pid] || keptParents[pid] || keptIDs[bareID(t.DocID)] {
			out = append(out, t)
		}
	}
	return out
}

// sectionFocus builds a section's focus neighborhood (charter D51) and finalizes
// it: computeFocus over the kept children + the section's NOW anchors, then add
// the ≤doneCueMax done-cue ids (they render as the completion cue when the section
// shows rows, charter D50), then cap at focusWindowMax. Empty result => the
// section renders header+rollup only (no active/blocked work to focus around).
func sectionFocus(kept, nowAnchors []Task) map[string]bool {
	focus := computeFocus(kept, nowAnchors)
	if len(focus) == 0 {
		return focus
	}
	for _, k := range kept {
		if isTerminal(k.Lifecycle) { // the ≤doneCueMax done cue kept by keepDoneCue
			focus[bareID(k.DocID)] = true
		}
	}
	return capFocus(kept, focus)
}

// capFocus trims a focus set to focusWindowMax deterministically (charter D51
// step 5): iterate kept in its band+priority display order and keep the first
// focusWindowMax members that are in focus, dropping the lowest-priority / oldest
// extras. The dropped remainder becomes the honest "+N more" the spine computes.
func capFocus(kept []Task, focus map[string]bool) map[string]bool {
	if len(focus) <= focusWindowMax {
		return focus
	}
	capped := make(map[string]bool, focusWindowMax)
	for _, k := range kept {
		id := bareID(k.DocID)
		if focus[id] {
			capped[id] = true
			if len(capped) >= focusWindowMax {
				break
			}
		}
	}
	return capped
}

// computeFocus builds the focus neighborhood for a section (charter D51). kept =
// the section's final displayed children; nowAnchors = the section's live claims
// (pinned in NOW, used only as context anchors). Seeds = every blocked kept child
// (each shows itself) + the nowAnchors. Per seed, drawn from kept: the parent
// chain up (≤focusParents), ready siblings sharing the seed's ParentID
// (≤focusSiblings, priority then recency), and direct children (≤focusChildren).
// The union across seeds is ONE neighborhood, so two active tasks in one section
// MERGE into one wider window — more perspective in one eye-catch, never two
// lists. Empty (no blocked child, no anchor) → the caller picks header mode.
func computeFocus(kept, nowAnchors []Task) map[string]bool {
	focus := map[string]bool{}
	if len(kept) == 0 {
		return focus
	}
	keptByID := make(map[string]Task, len(kept))
	for _, k := range kept {
		keptByID[bareID(k.DocID)] = k
	}

	var seeds []Task
	for _, k := range kept {
		if k.Lifecycle == lifeBlocked {
			focus[bareID(k.DocID)] = true // a blocked kept child is itself shown
			seeds = append(seeds, k)
		}
	}
	seeds = append(seeds, nowAnchors...) // NOW anchors seed context, never added themselves

	for _, s := range seeds {
		// Parents up ≤focusParents, only through kept members.
		p := bareID(s.ParentID)
		for depth := 0; depth < focusParents; depth++ {
			par, ok := keptByID[p]
			if !ok {
				break
			}
			focus[p] = true
			p = bareID(par.ParentID)
		}

		// Ready siblings sharing the seed's parent: priority asc, then recency desc.
		sp := bareID(s.ParentID)
		sid := bareID(s.DocID)
		var sibs []Task
		for _, k := range kept {
			if bareID(k.ParentID) == sp && k.Lifecycle == lifeReady && bareID(k.DocID) != sid {
				sibs = append(sibs, k)
			}
		}
		sort.SliceStable(sibs, func(i, j int) bool {
			ri, rj := priorityRank(sibs[i].Priority), priorityRank(sibs[j].Priority)
			if ri != rj {
				return ri < rj
			}
			return sibs[i].UpdatedAt.After(sibs[j].UpdatedAt)
		})
		for i := 0; i < len(sibs) && i < focusSiblings; i++ {
			focus[bareID(sibs[i].DocID)] = true
		}

		// Direct children of the seed (kept is already band-ordered): first ≤focusChildren.
		added := 0
		for _, k := range kept {
			if added >= focusChildren {
				break
			}
			if bareID(k.ParentID) == sid {
				focus[bareID(k.DocID)] = true
				added++
			}
		}
	}
	return focus
}

// filterToFocus returns the subset of tasks whose bareID is in focus, preserving
// input order — the row filter modeFocus applies before nesting (charter D51).
func filterToFocus(tasks []Task, focus map[string]bool) []Task {
	out := make([]Task, 0, len(tasks))
	for _, t := range tasks {
		if focus[bareID(t.DocID)] {
			out = append(out, t)
		}
	}
	return out
}

// orderChildren sorts within an epic/cluster/orphan list:
// in_progress -> ready -> blocked -> open -> unknown -> STALE -> recent terminal,
// newest-updated first inside each band. Stable so equal timestamps keep their
// input order. now is needed because the stale band is age-derived.
func orderChildren(cs []Task, now time.Time) {
	sort.SliceStable(cs, func(i, j int) bool {
		bi, bj := childBand(cs[i], now), childBand(cs[j], now)
		if bi != bj {
			return bi < bj
		}
		return cs[i].UpdatedAt.After(cs[j].UpdatedAt)
	})
}

// childBand is the vertical ordering bucket for a task. Recent terminal rows
// (done/closed/cancelled that survived folding) sink to the very bottom; a
// non-terminal row untouched past staleBandAfter sinks to the stale band just
// above them; an unrecognised non-terminal status ranks just after open. The
// stale check is EXCLUSIVE (strictly older) like the fold/dormancy boundaries.
func childBand(t Task, now time.Time) int {
	if isTerminal(t.Lifecycle) {
		return 6
	}
	if now.Sub(t.UpdatedAt) > staleBandAfter {
		return 5
	}
	switch t.Lifecycle {
	case lifeInProgress:
		return 0
	case lifeReady:
		return 1
	case lifeBlocked:
		return 2
	case lifeOpen:
		return 3
	default:
		return 4
	}
}

func isTerminal(lc string) bool {
	switch lc {
	case lifeDone, lifeClosed, lifeCancelled:
		return true
	}
	return false
}

// sortEpics ranks epics by (Active desc, repo-mentioned desc, LastActivity desc)
// — charter D49. A live claim ALWAYS outranks recency (the wish's #1: active work
// is the hero); the repo-mention boost is a subordinate tiebreak (D7); recency
// then orders WITHIN a tier so the most-recently-worked epic tops the list and
// dormant ones sink naturally (no special dormancy gate). Stable so same-tier
// epics keep their construction order.
func sortEpics(epics []Epic, repo RepoContext) {
	sort.SliceStable(epics, func(i, j int) bool {
		ai, aj := epics[i].Active, epics[j].Active
		if ai != aj {
			return ai
		}
		mi, mj := epicMentioned(epics[i], repo), epicMentioned(epics[j], repo)
		if mi != mj {
			return mi
		}
		return epics[i].LastActivity.After(epics[j].LastActivity)
	})
}

// epicMentioned reports whether the repo's git scan named the epic root or any
// kept child. Boost only — never a filter.
func epicMentioned(e Epic, repo RepoContext) bool {
	if len(repo.Mentioned) == 0 {
		return false
	}
	if repo.Mentioned[e.Root.DocID] > 0 {
		return true
	}
	for _, c := range e.Children {
		if repo.Mentioned[c.DocID] > 0 {
			return true
		}
	}
	return false
}

// sortByUpdatedDesc orders tasks newest-updated first, in place, stably.
func sortByUpdatedDesc(ts []Task) {
	sort.SliceStable(ts, func(i, j int) bool {
		return ts[i].UpdatedAt.After(ts[j].UpdatedAt)
	})
}
