package taskboard

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Repo correlation is 100% local and ADVISORY-ONLY (charter decision 7): it
// only feeds RepoContext.Mentioned, which BuildBoard reads for a rank boost and
// the renderer reads for a dim "↳ git" badge. It NEVER filters or hides a task,
// and outside a git repo the board degrades silently. Two strictly-separated
// layers live here: a pure text scanner (CorrelateRepo) with no I/O, and a thin
// shell (GatherRepoContext / gatherGit) that execs git with short timeouts and
// swallows every failure into the zero RepoContext.

// gitTimeout bounds each git invocation so a slow/hung repo never stalls a
// paint. Correlation is best-effort; a timeout is just "no repo context".
const gitTimeout = 3 * time.Second

// slugMinLen is the conservative floor for matching a task title's kebab slug
// against the branch name. Short slugs (e.g. "fix-bug") collide with common
// branch words, so we only trust slugs of at least this many bytes.
const slugMinLen = 8

// CorrelateRepo scans recent commit subjects and the current branch name for
// mentions of each task's doc_id, plus title-slug matches in the branch, and
// returns a RepoContext whose Mentioned maps doc_id -> mention count. It is
// PURE: no I/O, no exec — every input is injected, so it is exhaustively
// table-tested. Matching is boundary-anchored (a doc_id must appear as a whole
// id token, never as a substring inside a longer word), and doc_id matching is
// case-sensitive because ids are exact tokens; only the title-slug/branch
// comparison is case-folded, since branches and titles are conventionally cased
// differently. Mentioned is always non-nil (empty when nothing correlates).
func CorrelateRepo(gitLogSubjects []string, branch, repoName string, tasks []Task) RepoContext {
	rc := RepoContext{
		RepoName:  repoName,
		Branch:    branch,
		Mentioned: map[string]int{},
	}
	lowerBranch := strings.ToLower(branch)
	for _, t := range tasks {
		if t.DocID == "" {
			continue
		}
		n := 0
		// (a) exact doc_id token in each commit subject.
		for _, subj := range gitLogSubjects {
			n += countBoundedOccurrences(subj, t.DocID, isIDChar)
		}
		// (b) exact doc_id token in the branch name.
		n += countBoundedOccurrences(branch, t.DocID, isIDChar)
		// (c) title slug appearing as an exact kebab token in the branch.
		//     Conservative: only slugs >= slugMinLen, and counted once.
		if slug := slugify(t.Title); len(slug) >= slugMinLen {
			if countBoundedOccurrences(lowerBranch, slug, isSlugChar) > 0 {
				n++
			}
		}
		if n > 0 {
			rc.Mentioned[t.DocID] += n
		}
	}
	return rc
}

// GatherRepoContext is the SHELL: it execs git in dir to resolve the repo name
// and current branch, and confirms the repo has commit history. On ANY failure
// — no git binary, not a repo, detached with no commits, empty history — it
// returns the zero RepoContext silently (never an error, never output), so a
// caller can always paint. The returned Mentioned is an empty (non-nil) map:
// repo identity is known, but correlation against tasks is a separate, pure
// step. Integration code (a later slice) calls gatherGit for the raw subjects
// and feeds them to CorrelateRepo alongside the loaded tasks.
func GatherRepoContext(dir string) RepoContext {
	name, branch, _, ok := gatherGit(dir)
	if !ok {
		return RepoContext{}
	}
	return RepoContext{
		RepoName:  name,
		Branch:    branch,
		Mentioned: map[string]int{},
	}
}

// gatherGit runs the three git probes and returns the repo name, current branch
// (empty on detached HEAD — not a failure), the recent commit subjects, and an
// ok flag. ok is false on any exec failure or empty history. It is the reusable
// seam the integration slice uses to obtain subjects for CorrelateRepo.
func gatherGit(dir string) (repoName, branch string, subjects []string, ok bool) {
	root, ok := runGit(dir, "rev-parse", "--show-toplevel")
	if !ok {
		return "", "", nil, false
	}
	root = strings.TrimSpace(root)
	if root == "" {
		return "", "", nil, false
	}
	repoName = filepath.Base(root)

	// Detached HEAD yields an empty branch and a zero exit — that's fine.
	br, _ := runGit(dir, "branch", "--show-current")
	branch = strings.TrimSpace(br)

	logOut, ok := runGit(dir, "log", "--format=%s", "-100")
	if !ok {
		return "", "", nil, false
	}
	for _, line := range strings.Split(logOut, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			subjects = append(subjects, line)
		}
	}
	if len(subjects) == 0 {
		// Empty history: nothing to correlate — treat as "no repo".
		return "", "", nil, false
	}
	return repoName, branch, subjects, true
}

// runGit runs `git -C dir <args...>` under gitTimeout and returns stdout and an
// ok flag. Any error (missing binary, non-zero exit, timeout) reports ok=false
// with no output — the shell's fail-closed contract.
func runGit(dir string, args ...string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	full := append([]string{"-C", dir}, args...)
	out, err := exec.CommandContext(ctx, "git", full...).Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}

// countBoundedOccurrences counts non-overlapping occurrences of token in text
// where each occurrence is delimited on both sides by a boundary — the start or
// end of text, or a byte for which isWord reports false. This is what makes a
// short id fail to match inside a longer word: the id must stand alone as a
// whole token. token=="" counts as zero.
func countBoundedOccurrences(text, token string, isWord func(byte) bool) int {
	if token == "" {
		return 0
	}
	count, from := 0, 0
	for from <= len(text)-len(token) {
		i := strings.Index(text[from:], token)
		if i < 0 {
			break
		}
		start := from + i
		end := start + len(token)
		leftOK := start == 0 || !isWord(text[start-1])
		rightOK := end == len(text) || !isWord(text[end])
		if leftOK && rightOK {
			count++
			from = end
		} else {
			from = start + 1
		}
	}
	return count
}

// isIDChar reports whether b can be part of a task doc_id token. Ids are opaque
// tokens that may carry the "drafts." prefix, hyphens, or underscores, so all of
// those count as id characters for boundary purposes — which is precisely why a
// bare suffix like "abc123" does NOT match inside "drafts.abc123" (the '.' to
// its left is an id char, so there is no left boundary).
func isIDChar(b byte) bool {
	return b >= 'a' && b <= 'z' ||
		b >= 'A' && b <= 'Z' ||
		b >= '0' && b <= '9' ||
		b == '.' || b == '-' || b == '_'
}

// isSlugChar reports whether b is part of a kebab slug token. Hyphens are slug
// separators, so only alphanumerics count — that way a slug matches the branch
// even when it sits between hyphens (e.g. "repo-correlator-git" inside
// "loop/repo-correlator-git-scan") yet still cannot bleed into a longer word.
func isSlugChar(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= '0' && b <= '9'
}

// slugify lowercases title and collapses every run of non-alphanumeric bytes
// into a single hyphen, trimming leading/trailing hyphens — a conservative
// ASCII kebab. Non-ASCII runes act as separators.
func slugify(title string) string {
	var b strings.Builder
	prevHyphen := false
	for _, r := range strings.ToLower(title) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
			prevHyphen = false
		} else if !prevHyphen && b.Len() > 0 {
			b.WriteByte('-')
			prevHyphen = true
		}
	}
	return strings.TrimRight(b.String(), "-")
}
