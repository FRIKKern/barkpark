package taskboard

import (
	"sort"
	"time"
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
)

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
//   - ORPHANS = every parentless non-goal leaf, newest-updated first.
func BuildBoard(s Snapshot, repo RepoContext, now time.Time) Board {
	board := Board{
		Counts: s.Counts,
		Events: s.Events,
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

		children := make([]Task, 0, len(members))
		for _, m := range members {
			if m.DocID != rootID {
				children = append(children, m)
			}
		}

		// A goal always headlines; a non-goal root only earns a section when it
		// actually heads a subtree. Everything else is a loose leaf.
		if root.Kind != kindGoal && len(children) == 0 {
			board.Orphans = append(board.Orphans, root)
			continue
		}
		board.Epics = append(board.Epics, buildEpic(root, children, now))
	}

	sortEpics(board.Epics, repo)
	sortByUpdatedDesc(board.Orphans)

	return board
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
// a just-closed child still counts as recent movement).
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
	orderChildren(kept)
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

// orderChildren sorts within an epic: in_progress -> ready -> blocked -> open
// -> (recent terminal), newest-updated first inside each band. Stable so equal
// timestamps keep their input order.
func orderChildren(cs []Task) {
	sort.SliceStable(cs, func(i, j int) bool {
		bi, bj := childBand(cs[i].Lifecycle), childBand(cs[j].Lifecycle)
		if bi != bj {
			return bi < bj
		}
		return cs[i].UpdatedAt.After(cs[j].UpdatedAt)
	})
}

// childBand is the vertical ordering bucket for a lifecycle. Recent terminal
// rows (done/closed/cancelled that survived folding) sink to the bottom; an
// unrecognised non-terminal status ranks just after open.
func childBand(lc string) int {
	switch lc {
	case lifeInProgress:
		return 0
	case lifeReady:
		return 1
	case lifeBlocked:
		return 2
	case lifeOpen:
		return 3
	case lifeDone, lifeClosed, lifeCancelled:
		return 5
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
