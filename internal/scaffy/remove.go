package scaffy

// remove.go — the engine reverse path (W3, D36): bp scaffy remove =
// RECEIPT REPLAY. Remove loads the fat receipt keyed identically to the
// run that wrote it (command concept + resolved vars, receipt.go) and
// inverts its ops in REVERSE order over the same in-memory tree overlay
// apply uses — a failed remove therefore writes NOTHING (overlay
// semantics, exactly like a failed run).
//
// Drift-refusal, three outcomes per op (D36):
//
//	(a) current bytes match the recorded post-image → invert;
//	(b) post-image absent but the pre-image state present → already
//	    retracted, clean skip (idempotent remove, success);
//	(c) neither, or multiple matches → REFUSE fail-loud with a
//	    file:line SCAFFY-DRIFT message, no partial apply. Where
//	    derivable, the message names the interfering LATER SIBLING of
//	    the mark family — LIFO within a family falls out of this
//	    refusal, receipts across commands/files stay order-free.
//
// The receipt is authoritative for inversion: fat images decouple
// remove from .scaffy source drift (D35), so a changed command source
// is NOT a refusal reason. The receipt file itself persists after a
// successful remove — a second remove replays it and skips clean on
// every op (idempotent, exit-0 semantics).
//
// Reviewer handoffs honored here (W3 engine-core review):
//   - ASLONG guards are a RUN concept evaluated in guardSkip (apply.go,
//     the single seam) — remove never re-evaluates guards; drift-refusal
//     against recorded images IS the remove-side guard. No fork.
//   - REMOVE-verb receipt ops record their pre-image WITHOUT position,
//     so they have no inversion path — confirmed per D36: a
//     DIRECTION-remove command is a `bp scaffy run` target, first-class,
//     never an object of `remove`. Remove refuses direction-remove
//     commands up front and refuses a stray remove-kind op in any
//     receipt as defense-in-depth.
//   - Receipts persist BEFORE asserts run, so a run whose closing
//     asserts FAILED still left a replayable receipt — Remove inverts
//     it like any other (protective test covers the cycle).

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// RemoveOptions is the exported seam the CLI builds against (D40).
type RemoveOptions struct {
	CommandPath string            // the .scaffy file whose receipt to replay
	Vars        map[string]string // the SAME resolved --var set the run was keyed with
	DryRun      bool              // report what would be inverted, touch nothing
	RepoRoot    string            // the tree the receipt's paths resolve against
}

// ReceiptMissingError reports no persisted receipt for the command +
// vars key — nothing to remove. Not-found-shaped: errors.Is(err,
// fs.ErrNotExist) holds, and the CLI maps it to exit 4.
type ReceiptMissingError struct {
	Command string
	Receipt string // the receipt path that was probed
}

func (e *ReceiptMissingError) Error() string {
	return fmt.Sprintf("no receipt for %q at %s — nothing to remove (was the command applied with exactly these vars?)", e.Command, e.Receipt)
}

// Is makes the error not-found-shaped for errors.Is.
func (e *ReceiptMissingError) Is(target error) bool { return target == fs.ErrNotExist }

// DriftFinding is one op's drift refusal: the tree no longer matches
// either recorded image, or an image matches ambiguously.
type DriftFinding struct {
	Path    string // target file, repo-relative
	Line    int    // 1-based line in the target where the drift shows
	OpIndex int    // the op's index in the receipt
	Kind    string
	Msg     string
}

func (f DriftFinding) String() string {
	return fmt.Sprintf("%s:%d: SCAFFY-DRIFT %s", f.Path, f.Line, f.Msg)
}

// DriftError aggregates every drifted op of a refused remove (exit 5 at
// the CLI). All ops are evaluated so the report is complete — but a
// refused remove has written NOTHING.
type DriftError struct {
	Findings []DriftFinding
}

func (e *DriftError) Error() string {
	msgs := make([]string, len(e.Findings))
	for i, f := range e.Findings {
		msgs[i] = f.String()
	}
	return strings.Join(msgs, "\n")
}

// Remove executes one command's reverse path by receipt replay (D36,
// D40 seam). The returned report reuses the RunReport shape: Ops carry
// the inversions in replay (reverse-receipt) order, Receipt names the
// replayed receipt, Asserts stay empty — a remove runs no closing
// asserts, the byte-clean tree is the acceptance (D34).
func Remove(opts RemoveOptions) (*RunReport, error) {
	started := time.Now()
	if opts.CommandPath == "" || opts.RepoRoot == "" {
		return nil, varErrorf("RemoveOptions requires CommandPath and RepoRoot")
	}
	src, err := os.ReadFile(opts.CommandPath)
	if err != nil {
		return nil, err
	}

	// Pre-gate: the full validator, never bare Parse (D37) — remove
	// needs the command only for receipt keying, but a red command must
	// stay unusable on every engine path.
	if findings := ValidateFile(opts.CommandPath, src); len(findings) > 0 {
		return nil, &ValidationError{Findings: findings}
	}
	cmd, _ := Parse(opts.CommandPath, src)
	name := commandName(cmd, opts.CommandPath)

	// D36 dispatch law: a DIRECTION-remove command runs FORWARD — it is
	// never the object of `remove` (its REMOVE-verb receipts record
	// pre-images without position, so no inversion path exists).
	if cmd.Direction() == "remove" {
		return nil, varErrorf("%s is DIRECTION \"remove\" — run it forward (bp scaffy run); receipt replay inverts add-direction receipts only (D36)", name)
	}

	// The D37 var contract validates the key: a missing/unknown/mangled
	// --var must be a usage error here, not a confusing receipt miss.
	if _, err := newSubstituter(cmd, opts.Vars); err != nil {
		return nil, err
	}

	// Identical keying to the run that wrote the receipt (receipt.go).
	rpath := receiptPath(opts.RepoRoot, cmd, opts.Vars)
	rec, err := ReadReceipt(rpath)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, &ReceiptMissingError{Command: name, Receipt: rpath}
	}
	if err != nil {
		return nil, err
	}
	if rec.ReceiptVersion != receiptVersion {
		return nil, fmt.Errorf("%s: receipt_version %d unsupported (engine speaks %d)", rpath, rec.ReceiptVersion, receiptVersion)
	}
	// Defense-in-depth behind the direction check above.
	if rec.Direction == "remove" {
		return nil, varErrorf("%s records a DIRECTION \"remove\" run — such runs invert nothing; run the command forward instead (D36)", rpath)
	}

	report := &RunReport{
		Ok:        true,
		Command:   name,
		Direction: rec.Direction,
		Vars:      opts.Vars,
		DryRun:    opts.DryRun,
		Receipt:   rpath,
	}

	// Invert in REVERSE order over the overlay. Every op is evaluated —
	// a complete drift report — but one finding refuses the whole
	// remove: the overlay is discarded, nothing reaches disk.
	tr := newTree(opts.RepoRoot)
	var drifts []DriftFinding
	for i := len(rec.Ops) - 1; i >= 0; i-- {
		res, mutated, finding, err := invertOp(tr, rpath, i, rec.Ops[i])
		if err != nil {
			return nil, err
		}
		if finding != nil {
			drifts = append(drifts, *finding)
			continue
		}
		report.Ops = append(report.Ops, *res)
		if mutated {
			report.Mutated = true
		}
	}
	if len(drifts) > 0 {
		return nil, &DriftError{Findings: drifts}
	}

	if opts.DryRun {
		report.Diffs, err = treeDiffs(tr)
		if err != nil {
			return nil, err
		}
	} else {
		if report.Mutated {
			if err := tr.flush(); err != nil {
				return nil, err
			}
		}
		// Retract the now-empty directories the apply created (D35
		// created_dirs). Best-effort cosmetic cleanup: deepest-first so a
		// child empties its parent, rmdir ONLY when the dir is empty, and
		// never a hard failure — a non-empty or vanished dir is left as
		// found. A pre-field receipt carries none and prunes nothing.
		pruneCreatedDirs(opts.RepoRoot, rec.CreatedDirs)
	}
	// The receipt file stays — a second remove skips clean on every op.

	report.DurationMS = time.Since(started).Milliseconds()
	return report, nil
}

// Remove-side op statuses (the run statuses in apply.go cover the
// forward vocabulary; restore is remove-only).
const (
	// OpRestored is a REPLACE inversion: the recorded post-image swapped
	// back to the pre-image state.
	OpRestored = "restored"
)

// invertOp inverts one receipt op against the overlay. It returns the
// op's result and whether it mutated, OR a drift finding (refusal), OR
// a hard error. Exactly one of result/finding/error is meaningful.
func invertOp(tr *tree, rpath string, idx int, op ReceiptOp) (*OpResult, bool, *DriftFinding, error) {
	res := &OpResult{Index: idx, Kind: op.Kind, Path: op.Path, Mark: op.Mark, Reanchored: op.Reanchored}
	drift := func(line int, format string, args ...any) (*OpResult, bool, *DriftFinding, error) {
		return nil, false, &DriftFinding{Path: op.Path, Line: line, OpIndex: idx, Kind: op.Kind, Msg: fmt.Sprintf(format, args...)}, nil
	}

	content, exists, err := tr.read(op.Path)
	if err != nil {
		return nil, false, nil, err
	}

	switch op.Kind {
	case "create":
		// Inverse of CREATE: verify the on-disk bytes against the
		// recorded post-image sha, then delete the owned file.
		if !exists {
			res.Status = OpSkipped
			res.Reason = "already retracted: file absent"
			return res, false, nil, nil
		}
		if sha256Hex(content) == op.PostSHA256 {
			tr.delete(op.Path)
			res.Status = OpDeleted
			return res, true, nil, nil
		}
		return drift(firstDiffLine(content, op.PostImage),
			"created file no longer matches the receipt post-image (sha %.12s… ≠ recorded %.12s…) — hand-edited since apply; refusing to delete", sha256Hex(content), op.PostSHA256)

	case "delete":
		// Inverse of DELETE: restore the recorded pre-image file.
		if !exists {
			tr.write(op.Path, op.PreImage)
			res.Status = OpCreated
			return res, true, nil, nil
		}
		if sha256Hex(content) == op.PreSHA256 {
			res.Status = OpSkipped
			res.Reason = "already retracted: file already restored"
			return res, false, nil, nil
		}
		return drift(firstDiffLine(content, op.PreImage),
			"a file now exists at the deleted path but matches neither absence nor the recorded pre-image — refusing to overwrite")

	case "insert-after-first", "insert-after-last", "insert-before-first", "insert-before-last":
		// Inverse of INSERT (AFTER and BEFORE alike — both splice the
		// payload beside an untouched anchor): locate the recorded
		// post-image bytes exactly once and excise them. No pre-image
		// exists for an insert — the pre state is "file without the
		// payload".
		if !exists {
			return drift(1, "target file missing — cannot excise the recorded insertion")
		}
		switch n := bytes.Count(content, op.PostImage); {
		case n == 1:
			tr.write(op.Path, bytes.Replace(content, op.PostImage, nil, 1))
			res.Status = OpRemoved
			return res, true, nil, nil
		case n == 0:
			// A planted mark still present with the post-image gone means
			// the block was hand-mutated, not retracted.
			if op.Mark != "" {
				if off := bytes.Index(content, []byte("MARK:"+op.Mark)); off >= 0 {
					return drift(lineOf(content, off),
						"mark %q still planted but the recorded post-image is gone — the inserted block was hand-mutated; refusing to guess its extent", "MARK:"+op.Mark)
				}
			}
			res.Status = OpSkipped
			res.Reason = "already retracted: post-image absent"
			return res, false, nil, nil
		default:
			return drift(secondMatchLine(content, op.PostImage),
				"recorded post-image occurs %d times — exactly once required to excise; refusing the ambiguous match", n)
		}

	case "replace":
		// Inverse of REPLACE: swap the recorded post-image back to the
		// pre-image state. For a REANCHOR splice (run ≥2) the post-image
		// spans [prior tail comma'd + this run's block] while the
		// pre-image spans the whole prior sibling block [mark..tail] —
		// the bytes the splice actually consumed are exactly the
		// pre-image's LAST line (the original separator-bare tail), so
		// that line is what the swap restores. Comma restoration is
		// implicit in the image swap — never line arithmetic (D34/D35).
		restore := op.PreImage
		if op.Reanchored {
			restore = lastLine(op.PreImage)
		}
		if !exists {
			return drift(1, "target file missing — cannot restore the recorded pre-image")
		}
		switch n := bytes.Count(content, op.PostImage); {
		case n == 1:
			tr.write(op.Path, bytes.Replace(content, op.PostImage, restore, 1))
			res.Status = OpRestored
			return res, true, nil, nil
		case n == 0:
			if len(op.PreImage) > 0 && bytes.Contains(content, op.PreImage) {
				res.Status = OpSkipped
				res.Reason = "already retracted: pre-image state present"
				return res, false, nil, nil
			}
			line := 1
			msg := "neither the recorded post-image nor the pre-image is present — the region was hand-mutated or a later run re-anchored past it"
			if op.Mark != "" {
				if off := bytes.Index(content, []byte("MARK:"+op.Mark)); off >= 0 {
					line = lineOf(content, off)
				}
				if sib := interferingSibling(content, op.Mark); sib != "" {
					msg += fmt.Sprintf("; later sibling %s is still planted — remove it first (LIFO within a mark family, D36)", sib)
				}
			}
			return drift(line, "%s", msg)
		default:
			return drift(secondMatchLine(content, op.PostImage),
				"recorded post-image occurs %d times — exactly once required to restore; refusing the ambiguous match", n)
		}

	case "remove":
		// Reviewer handoff (2), confirmed against D36: a REMOVE-verb op
		// records its pre-image WITHOUT position, so no inversion path
		// exists — and none is needed, because DIRECTION-remove commands
		// run forward. Reaching this op means a hand-built or foreign
		// receipt: refuse hard.
		return nil, false, nil, fmt.Errorf("%s: op %d (REMOVE in %s) records a positionless pre-image and cannot be inverted — DIRECTION-remove commands run forward via bp scaffy run (D36)", rpath, idx, op.Path)

	default:
		return nil, false, nil, fmt.Errorf("%s: op %d has unknown kind %q", rpath, idx, op.Kind)
	}
}

// pruneCreatedDirs rmdirs the apply-created directories that are empty
// after file deletion (D35). Deepest-first (most path separators first)
// so removing a child leaves its parent empty and thus prunable in the
// same pass. Best-effort: a non-empty dir (still holds a sibling or a
// hand-added file) or an already-vanished one is silently left — never
// force-removed, never a remove failure.
func pruneCreatedDirs(root string, dirs []string) {
	if len(dirs) == 0 {
		return
	}
	sorted := append([]string(nil), dirs...)
	sort.Slice(sorted, func(i, j int) bool {
		return strings.Count(sorted[i], "/") > strings.Count(sorted[j], "/")
	})
	for _, d := range sorted {
		abs := filepath.Join(root, filepath.FromSlash(d))
		entries, err := os.ReadDir(abs)
		if err != nil {
			continue // already gone, or unreadable — leave it
		}
		if len(entries) == 0 {
			_ = os.Remove(abs) // rmdir; only ever succeeds on an empty dir
		}
	}
}

// lastLine returns b's final line, keeping its trailing newline when
// present. For a REANCHOR pre-image this is the prior sibling's
// original separator-bare tail line — the exact bytes the splice
// consumed (apply.go reanchorSplice replaces one tail line with
// newTail + the new block).
func lastLine(b []byte) []byte {
	if len(b) == 0 {
		return b
	}
	search := b
	if b[len(b)-1] == '\n' {
		search = b[:len(b)-1]
	}
	i := bytes.LastIndexByte(search, '\n')
	return b[i+1:]
}

// lineOf is the 1-based line number of byte offset off in b.
func lineOf(b []byte, off int) int {
	if off > len(b) {
		off = len(b)
	}
	return 1 + bytes.Count(b[:off], []byte{'\n'})
}

// firstDiffLine is the line where current bytes first diverge from the
// recorded image — the actionable file:line of a whole-file drift.
func firstDiffLine(cur, want []byte) int {
	n := len(cur)
	if len(want) < n {
		n = len(want)
	}
	i := 0
	for i < n && cur[i] == want[i] {
		i++
	}
	return lineOf(cur, i)
}

// secondMatchLine is the line of the second occurrence of image — the
// ambiguity a multiple-match refusal points at.
func secondMatchLine(content, image []byte) int {
	first := bytes.Index(content, image)
	if first < 0 {
		return 1
	}
	rest := content[first+1:]
	second := bytes.Index(rest, image)
	if second < 0 {
		return lineOf(content, first)
	}
	return lineOf(content, first+1+second)
}

// interferingSibling names the NEXT planted mark after this op's own
// mark, when both are derivable from the current bytes — the later
// sibling whose splice mutated this op's post-image (the LIFO message,
// D36).
func interferingSibling(content []byte, mark string) string {
	if mark == "" {
		return ""
	}
	own := []byte("MARK:" + mark)
	i := bytes.Index(content, own)
	if i < 0 {
		return ""
	}
	rest := content[i+len(own):]
	j := bytes.Index(rest, []byte("MARK:"))
	if j < 0 {
		return ""
	}
	tok := rest[j+len("MARK:"):]
	end := 0
	for end < len(tok) && isMarkByte(tok[end]) {
		end++
	}
	if end == 0 {
		return ""
	}
	return "MARK:" + string(tok[:end])
}

func isMarkByte(c byte) bool {
	return c == '-' || c == '_' ||
		(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}
