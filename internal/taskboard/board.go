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

// Attention-policy thresholds. Boundaries are EXCLUSIVE: a done child at
// exactly 24h stays visible, an epic idle exactly 7d is not yet dormant — the
// fold/collapse only trips once the age is strictly past the threshold.
const (
	doneFoldAfter = 24 * time.Hour
	dormantAfter  = 7 * 24 * time.Hour
	// staleBandAfter is the age past which a NON-terminal row sinks into the
	// stale band (below open, above terminal) — a visible "this hasn't moved"
	// demotion inside the same ordered list, no toggle. Exclusive like the others.
	staleBandAfter = 7 * 24 * time.Hour
	// staleCountAfter is the (shorter) age that makes a non-terminal task count
	// toward Board.Stale — the header's cold-work tally trips earlier than the
	// band demotion so the number warns before rows visibly rot.
	staleCountAfter = 3 * 24 * time.Hour
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

// readyHeadMax is how many ready tasks the claim-forward READY TO CLAIM band
// offers when nothing is in flight (wave-7 decision 35) — a short, scannable
// head, not a return to the flat wall. The rest live behind a "+K more ready"
// tail and inside their (folded-by-default) sections.
const readyHeadMax = 5

// groupHeadMax is how many children a category (epic / cluster / loose bucket)
// shows by DEFAULT before folding the rest behind a "+K more" line. The user's
// direction (2026-07-04): "we want to see at least 5 tasks per category" — a
// collapsed-to-header default hid too much, so every section now shows a
// glanceable head of its top children and expands (l / enter) to the full list.
const groupHeadMax = 5

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

// readyHead selects the top readyHeadMax ready tasks across the whole corpus for
// the claim-forward band (wave-7 decision 35), ordered priority-ascending
// (priorityRank: P0/P1 first, absent/non-numeric last) then updated_at desc, and
// also reports the total ready count. Ready is the ENGINE's readiness overlay
// (composeSnapshot marks open/blocked rows ready) — the same signal the header's
// ready tally and `bp task next` use — so the head is exactly what can be claimed.
func readyHead(tasks []Task) (head []Task, total int) {
	// A task that is itself a parent (some other task names it as ParentID) is a
	// goal/epic ROOT — you claim its leaf children, not the whole goal. Exclude
	// parents from the claim-forward head so `c` never claims an entire epic
	// (wave-7 polish: the head is where you pick up ACTIONABLE work). bareID
	// normalizes the drafts. prefix so a bare ParentID matches a prefixed DocID.
	parents := make(map[string]bool)
	for _, t := range tasks {
		if t.ParentID != "" {
			parents[bareID(t.ParentID)] = true
		}
	}
	var ready []Task
	for _, t := range tasks {
		if t.Lifecycle == lifeReady && !parents[bareID(t.DocID)] {
			ready = append(ready, t)
		}
	}
	sort.SliceStable(ready, func(i, j int) bool {
		ri, rj := priorityRank(ready[i].Priority), priorityRank(ready[j].Priority)
		if ri != rj {
			return ri < rj
		}
		return ready[i].UpdatedAt.After(ready[j].UpdatedAt)
	})
	total = len(ready)
	if len(ready) > readyHeadMax {
		ready = ready[:readyHeadMax]
	}
	return ready, total
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
		epic := buildEpic(root, children, now)
		// Active (wave-7 decision 32) = the epic owns a NOW task. Computed here,
		// while the full descendant set + root are in hand and BEFORE
		// dedupNowFromEpics strips the claims for display, so it sees exactly which
		// sections contribute to the pinned band. It is the sole auto-fold input:
		// a folded-by-default epic auto-expands only when its own work is running.
		epic.Active = nowSet[root.DocID] || anyInNow(children, nowSet)
		board.Epics = append(board.Epics, epic)
	}

	sortEpics(board.Epics, repo)
	// Strip the NOW-pinned claims from the ranked epics' displayed children (D14).
	dedupNowFromEpics(board.Epics, nowSet)
	board.Orphans, board.OrphansFolded = foldStaleOrphans(board.Orphans, now)
	orderChildren(board.Orphans, now)

	// Carve derived clusters out of the loose-orphan pile: labels that relate
	// tasks become named sections so the flat "(no epic)" queue self-organizes.
	// The freq map is computed against the SAME loose set the keys are resolved
	// from, so suggestion-eligibility below stays consistent with clustering.
	loose := board.Orphans
	board.Clusters, board.Orphans = deriveClusters(loose, now)

	// Cluster/orphan Active (wave-7 decision 32/33), computed while the NOW tasks
	// are STILL members (before the de-dup below strips them for display): a
	// cluster or the loose bucket auto-expands only when its own work is running.
	for i := range board.Clusters {
		board.Clusters[i].Active = anyInNow(board.Clusters[i].Tasks, nowSet)
	}
	board.OrphansActive = anyInNow(board.Orphans, nowSet)

	// NOW de-dup for the loose pile, mirroring the epic treatment above: the
	// claims stayed in `loose` through label frequency, cluster membership and
	// freshest-member ranking — so claiming one member of a minimum-size cluster
	// never dissolves the section or drops its rank mid-session — and leave the
	// DISPLAY only now (charter D14).
	board.Clusters = dedupNowFromClusters(board.Clusters, nowSet)
	board.Orphans = stripNow(board.Orphans, nowSet)

	// READY TO CLAIM head (wave-7 decision 35): the top readyHeadMax ready tasks
	// across the WHOLE corpus, priority-ascending then freshest, plus the total
	// ready depth. It powers the claim-forward band that replaces the empty-NOW
	// dead-line, so there is always an obvious next task to claim.
	board.ReadyHead, board.ReadyTotal = readyHead(s.Tasks)

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
// its stale terminal members (same 24h boundary as epics) and band-orders the
// rest; clusters come back freshest-member first.
func deriveClusters(loose []Task, now time.Time) ([]Cluster, []Task) {
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
		clusters = append(clusters, buildCluster(k, groups[k], now))
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

// buildCluster folds stale terminal members and band-orders the survivors,
// mirroring buildEpic's child handling (minus the epic root / dormancy).
func buildCluster(key string, members []Task, now time.Time) Cluster {
	c := Cluster{Key: key}
	kept := make([]Task, 0, len(members))
	for _, m := range members {
		if isTerminal(m.Lifecycle) && now.Sub(m.UpdatedAt) > doneFoldAfter {
			c.DoneFolded++
			continue
		}
		kept = append(kept, m)
	}
	orderChildren(kept, now)
	c.Tasks = kept
	return c
}

// sortClusters ranks clusters by freshest member (updated desc), stably.
func sortClusters(cs []Cluster) {
	sort.SliceStable(cs, func(i, j int) bool {
		return clusterFreshest(cs[i]).After(clusterFreshest(cs[j]))
	})
}

// clusterFreshest is the newest updated_at across a cluster's kept members.
func clusterFreshest(c Cluster) time.Time {
	var freshest time.Time
	for _, t := range c.Tasks {
		if t.UpdatedAt.After(freshest) {
			freshest = t.UpdatedAt
		}
	}
	return freshest
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

// foldStaleOrphans splits the loose-orphan pile into the rows worth showing and
// a count of terminal rows to hide. The boundary is the SAME exclusive 24h
// doneFoldAfter epics use for their children, so a done orphan at exactly 24h
// stays visible and one a second older folds — the two folds behave identically.
// Non-terminal orphans (open/ready/in_progress/blocked) never fold, however old:
// unfinished work is never hidden.
func foldStaleOrphans(orphans []Task, now time.Time) (kept []Task, folded int) {
	kept = make([]Task, 0, len(orphans))
	for _, o := range orphans {
		if isTerminal(o.Lifecycle) && now.Sub(o.UpdatedAt) > doneFoldAfter {
			folded++
			continue
		}
		kept = append(kept, o)
	}
	return kept, folded
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

// buildEpic folds stale terminal children, orders the survivors, and marks
// dormancy from the freshest member (root or ANY child, including folded ones —
// a just-closed child still counts as recent movement). The NOW-pinned claims
// are still in epic.Children at this stage so ranking (epicFreshest) and
// dormancy see their freshness; dedupNowFromEpics strips them for display AFTER
// the epics are ranked.
func buildEpic(root Task, children []Task, now time.Time) Epic {
	epic := Epic{Root: root}

	kept := make([]Task, 0, len(children))
	for _, c := range children {
		if isTerminal(c.Lifecycle) && now.Sub(c.UpdatedAt) > doneFoldAfter {
			epic.DoneFolded++
			continue
		}
		kept = append(kept, c)
	}
	orderChildren(kept, now)
	epic.Children = kept

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

// sortEpics ranks epics by repo relevance first (any member mentioned in this
// repo's git context floats up), then by freshest member updated desc. Stable
// so same-tier epics keep their construction order.
func sortEpics(epics []Epic, repo RepoContext) {
	sort.SliceStable(epics, func(i, j int) bool {
		mi, mj := epicMentioned(epics[i], repo), epicMentioned(epics[j], repo)
		if mi != mj {
			return mi
		}
		return epicFreshest(epics[i]).After(epicFreshest(epics[j]))
	})
}

// epicFreshest is the newest updated_at across the epic root and its kept
// children — the "freshest child movement" the ranking is built on.
func epicFreshest(e Epic) time.Time {
	freshest := e.Root.UpdatedAt
	for _, c := range e.Children {
		if c.UpdatedAt.After(freshest) {
			freshest = c.UpdatedAt
		}
	}
	return freshest
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
