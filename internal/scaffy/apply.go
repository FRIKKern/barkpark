package scaffy

// apply.go — the engine forward path (W3, D33–D43): bp scaffy run.
// Run validates the command (ValidateFile pre-gate — never bare Parse),
// enforces the D37 --var contract, applies ops in order over an
// in-memory tree overlay (guards BEFORE anchor resolution; a per-op
// skip never aborts siblings; an op FAILURE aborts with nothing
// written), then — outside dry-run — flushes the overlay, persists the
// D35 fat receipt and executes the closing asserts (TIER ci deferred,
// never run locally; ASSERT CMD per D38: sh -c verbatim from the repo
// root with CC=/usr/bin/clang appended). Dry-run computes everything,
// writes and executes nothing, and reports -/+ per-file line diffs.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// assertCmdTimeout is the default per-CMD wall clock (D38 — the floor
// is the cold pnpm bootstrap, 740s measured; anything under ~900s
// kills the flagship at its own assert). Package-private so tests can
// shrink it.
var assertCmdTimeout = 900 * time.Second

// RunOptions is the exported seam the CLI builds against (D40).
type RunOptions struct {
	CommandPath string            // the .scaffy file to run
	Vars        map[string]string // resolved --var set, keyed by declared VARIABLE name
	DryRun      bool              // compute everything, write/exec nothing (D39)
	RepoRoot    string            // the tree every IN/CREATE path resolves against
}

// RunReport is Run's structured result: per-op statuses, assert
// results with tier, the persisted receipt path and per-file dry-run
// diffs (D40). Ok is false when any executed assert failed.
type RunReport struct {
	Ok         bool              `json:"ok"`
	Command    string            `json:"command"`
	Direction  string            `json:"direction"`
	Vars       map[string]string `json:"vars"`
	DryRun     bool              `json:"dry_run"`
	Ops        []OpResult        `json:"ops"`
	Asserts    []AssertResult    `json:"asserts"`
	Receipt    string            `json:"receipt,omitempty"`
	Diffs      []FileDiff        `json:"diffs,omitempty"`
	Mutated    bool              `json:"mutated"`
	DurationMS int64             `json:"duration_ms"`
}

// Op statuses (D39 vocabulary: ● created · ○ injected · ○ replaced ·
// = skipped · ✕ deleted; REMOVE-verb retractions report "removed").
const (
	OpCreated  = "created"
	OpInjected = "injected"
	OpReplaced = "replaced"
	OpRemoved  = "removed"
	OpDeleted  = "deleted"
	OpSkipped  = "skipped"
)

// OpResult is one op's outcome.
type OpResult struct {
	Index      int    `json:"index"`
	Kind       string `json:"kind"` // create | delete | insert-after-first | insert-after-last | insert-before-first | insert-before-last | replace | remove
	Path       string `json:"path"`
	Mark       string `json:"mark,omitempty"`
	Status     string `json:"status"`
	Reason     string `json:"reason,omitempty"` // skip reason
	Line       int    `json:"line"`
	Reanchored bool   `json:"reanchored,omitempty"` // REPLACE anchored at the mark-family tail (run ≥2, D21/D33)
}

// Assert statuses.
const (
	AssertPass     = "pass"
	AssertFail     = "fail"
	AssertDeferred = "deferred"  // TIER ci — reported, never executed locally (D38)
	AssertWouldRun = "would-run" // dry-run: a LOCAL CMD listed, not executed (D39)
)

// AssertResult is one closing assertion's outcome.
type AssertResult struct {
	Index  int    `json:"index"`
	Kind   string `json:"kind"` // file-contains | file-dont-contain | file-exists | file-absent | cmd
	Path   string `json:"path,omitempty"`
	Text   string `json:"text,omitempty"` // substituted match text / verbatim command
	Tier   string `json:"tier,omitempty"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
	Line   int    `json:"line"`
}

// FileDiff is one file's dry-run line diff: "-" lines leave, "+" lines
// arrive (D39 — hand-rolled LCS, dep-free).
type FileDiff struct {
	Path  string   `json:"path"`
	Lines []string `json:"lines"`
}

// ValidationError carries the pre-gate findings (exit 5 at the CLI).
type ValidationError struct {
	Findings []Finding
}

func (e *ValidationError) Error() string {
	if len(e.Findings) == 1 {
		return e.Findings[0].String()
	}
	return fmt.Sprintf("%s (and %d more findings — run bp scaffy validate)", e.Findings[0].String(), len(e.Findings)-1)
}

// PathMissingError reports an IN-op target file absent from the tree
// (exit 4 at the CLI).
type PathMissingError struct {
	File string // the .scaffy source
	Line int
	Path string // the missing target, repo-relative
}

func (e *PathMissingError) Error() string {
	return fmt.Sprintf("%s:%d: target file %q missing from the tree", e.File, e.Line, e.Path)
}

// ApplyError is a fail-loud op defect: anchor not exactly-once (D20),
// REANCHOR tail desync (D33), an escaping path (exit 5 at the CLI).
type ApplyError struct {
	File string
	Line int
	Msg  string
}

func (e *ApplyError) Error() string { return fmt.Sprintf("%s:%d: %s", e.File, e.Line, e.Msg) }

func applyErrorf(file string, line int, format string, args ...any) *ApplyError {
	return &ApplyError{File: file, Line: line, Msg: fmt.Sprintf(format, args...)}
}

// tree is the in-memory overlay Run applies ops against: reads fall
// through to disk, writes and deletes stay virtual until flush. Ops
// therefore see their predecessors' output, and an op failure aborts
// the run with the real tree untouched.
type tree struct {
	root    string
	files   map[string][]byte // rel → current bytes (overlay)
	deleted map[string]bool
	touched []string // mutation order, deduped

	// createdDirs are the directories flush actually mkdir'd (never
	// pre-existing ones), repo-relative forward-slash, deduped in
	// creation order — the D35 receipt records them so remove can rmdir
	// the now-empty residue a CREATE left behind.
	createdDirs    []string
	createdDirSeen map[string]bool
}

func newTree(root string) *tree {
	return &tree{root: root, files: map[string][]byte{}, deleted: map[string]bool{}, createdDirSeen: map[string]bool{}}
}

// resolve confines a repo-relative path to the root (a scaffold must
// never write outside the tree it was pointed at).
func (t *tree) resolve(rel string) (string, error) {
	if filepath.IsAbs(rel) {
		return "", fmt.Errorf("path %q is absolute — command paths are repo-relative", rel)
	}
	clean := filepath.Clean(filepath.FromSlash(rel))
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q escapes the repo root", rel)
	}
	return filepath.Join(t.root, clean), nil
}

// read returns a file's current overlay bytes and whether it exists.
func (t *tree) read(rel string) ([]byte, bool, error) {
	if t.deleted[rel] {
		return nil, false, nil
	}
	if b, ok := t.files[rel]; ok {
		return b, true, nil
	}
	abs, err := t.resolve(rel)
	if err != nil {
		return nil, false, err
	}
	b, err := os.ReadFile(abs)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return b, true, nil
}

func (t *tree) note(rel string) {
	for _, p := range t.touched {
		if p == rel {
			return
		}
	}
	t.touched = append(t.touched, rel)
}

func (t *tree) write(rel string, b []byte) {
	delete(t.deleted, rel)
	t.files[rel] = b
	t.note(rel)
}

func (t *tree) delete(rel string) {
	delete(t.files, rel)
	t.deleted[rel] = true
	t.note(rel)
}

// stagedWrite is one CREATE/INSERT/REPLACE write staged to a sibling
// temp file, waiting for flush's commit phase to rename it into place.
type stagedWrite struct {
	rel string
	abs string
	tmp string
}

// flush writes the overlay to disk, all-or-nothing (apply.go:6-8):
// every non-delete write is first staged to a sibling temp file in its
// own directory (os.CreateTemp), written, synced and closed, and only
// renamed into place once EVERY staged write has succeeded. A failure
// at any point during staging removes every temp file created so far
// and returns with no real path touched — the guarantee the prior
// per-file os.WriteFile loop advertised but did not keep, since it
// wrote straight to the real paths and aborted mid-loop on error.
// Deletes run last, after every write is committed. CREATE still
// implies mkdir -p (D26); an existing file's mode survives an
// overwrite (staging never inherits os.CreateTemp's 0600 default) —
// only a newly created path gets the 0o644 default.
func (t *tree) flush() error {
	var staged []stagedWrite
	cleanupStaged := func() {
		for _, s := range staged {
			os.Remove(s.tmp)
		}
	}

	for _, rel := range t.touched {
		if t.deleted[rel] {
			continue
		}
		abs, err := t.resolve(rel)
		if err != nil {
			cleanupStaged()
			return err
		}
		// Record the ancestor dirs this CREATE is about to bring into
		// being (computed BEFORE the mkdir, while they are still absent)
		// so remove can retract them; writes to an existing file's dir
		// yield nothing here.
		t.noteCreatedDirs(dirsToCreate(t.root, abs))
		dir := filepath.Dir(abs)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			cleanupStaged()
			return fmt.Errorf("flush %s: mkdir: %w", rel, err)
		}
		mode := os.FileMode(0o644)
		if fi, statErr := os.Stat(abs); statErr == nil {
			mode = fi.Mode().Perm() // preserve an existing file's mode
		}
		b := t.files[rel]
		if b == nil {
			b = []byte{} // empty fence ⇒ 0-byte file (D26)
		}
		tmp, err := os.CreateTemp(dir, "."+filepath.Base(abs)+".scaffy-tmp-*")
		if err != nil {
			cleanupStaged()
			return fmt.Errorf("flush %s: stage: %w", rel, err)
		}
		werr := stageWrite(tmp, b, mode)
		if werr != nil {
			os.Remove(tmp.Name())
			cleanupStaged()
			return fmt.Errorf("flush %s: stage: %w", rel, werr)
		}
		staged = append(staged, stagedWrite{rel: rel, abs: abs, tmp: tmp.Name()})
	}

	// Commit: every staged write verified — rename each temp into place.
	for i, s := range staged {
		if err := os.Rename(s.tmp, s.abs); err != nil {
			// The remaining un-renamed temps are still just temps; the
			// ones already renamed are now real files this call cannot
			// retract (rename is the atomic unit, not the whole batch).
			for _, rest := range staged[i+1:] {
				os.Remove(rest.tmp)
			}
			return fmt.Errorf("flush %s: commit: %w", s.rel, err)
		}
	}

	// Deletes last, only once every write above is committed.
	for _, rel := range t.touched {
		if !t.deleted[rel] {
			continue
		}
		abs, err := t.resolve(rel)
		if err != nil {
			return err
		}
		if err := os.Remove(abs); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("flush %s: remove: %w", rel, err)
		}
	}
	return nil
}

// stageWrite writes b to tmp, verifies the write, syncs and closes it,
// then chmods it to mode — the full staging sequence a temp file must
// pass before flush will consider it fit to rename into place. tmp is
// always closed by the time this returns, success or failure.
func stageWrite(tmp *os.File, b []byte, mode os.FileMode) error {
	n, err := tmp.Write(b)
	if err == nil && n != len(b) {
		err = fmt.Errorf("short write: wrote %d of %d bytes", n, len(b))
	}
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp.Name(), mode)
	}
	return err
}

// noteCreatedDirs appends the given repo-relative dirs to the tree's
// created-dir ledger, deduped, preserving first-seen (shallow→deep)
// order. Sequential flush means a dir a prior file already created
// re-tests as existing in dirsToCreate and never reaches here twice.
func (t *tree) noteCreatedDirs(dirs []string) {
	for _, d := range dirs {
		if !t.createdDirSeen[d] {
			t.createdDirSeen[d] = true
			t.createdDirs = append(t.createdDirs, d)
		}
	}
}

// dirsToCreate returns the ancestor directories of file fileAbs that do
// not yet exist, bounded strictly below root (root itself is never
// returned), ordered shallow→deep — exactly the dirs an os.MkdirAll for
// fileAbs will bring into being. The first existing ancestor stops the
// walk: its own parents necessarily exist too. Paths are repo-relative
// forward-slash to match ReceiptOp.Path.
func dirsToCreate(root, fileAbs string) []string {
	var missing []string
	dir := filepath.Dir(fileAbs)
	for {
		if dir == root || !strings.HasPrefix(dir, root+string(filepath.Separator)) {
			break
		}
		if _, err := os.Stat(dir); err == nil {
			break // exists — and so do all its ancestors
		}
		rel, err := filepath.Rel(root, dir)
		if err != nil {
			break
		}
		missing = append(missing, filepath.ToSlash(rel))
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	// Reverse deep→shallow into shallow→deep (creation order).
	for i, j := 0, len(missing)-1; i < j; i, j = i+1, j-1 {
		missing[i], missing[j] = missing[j], missing[i]
	}
	return missing
}

// Run executes one .scaffy command's forward path (D40 seam).
func Run(opts RunOptions) (*RunReport, error) {
	started := time.Now()
	if opts.CommandPath == "" || opts.RepoRoot == "" {
		return nil, varErrorf("RunOptions requires CommandPath and RepoRoot")
	}
	src, err := os.ReadFile(opts.CommandPath)
	if err != nil {
		return nil, err
	}

	// Pre-gate: the full validator, never bare Parse (D37 — a partial
	// AST from dirty input must never reach the applier).
	if findings := ValidateFile(opts.CommandPath, src); len(findings) > 0 {
		return nil, &ValidationError{Findings: findings}
	}
	cmd, _ := Parse(opts.CommandPath, src)

	sub, err := newSubstituter(cmd, opts.Vars)
	if err != nil {
		return nil, err
	}

	report := &RunReport{
		Ok:        true,
		Command:   commandName(cmd, opts.CommandPath),
		Direction: cmd.Direction(),
		Vars:      opts.Vars,
		DryRun:    opts.DryRun,
	}

	tr := newTree(opts.RepoRoot)
	var receiptOps []ReceiptOp
	for i, op := range cmd.Ops {
		res, rop, err := applyOp(cmd, sub, tr, i, op)
		if err != nil {
			return nil, err
		}
		report.Ops = append(report.Ops, *res)
		if rop != nil {
			receiptOps = append(receiptOps, *rop)
			report.Mutated = true
		}
	}

	if opts.DryRun {
		report.Diffs, err = treeDiffs(tr)
		if err != nil {
			return nil, err
		}
	} else if report.Mutated {
		if err := tr.flush(); err != nil {
			return nil, err
		}
		// A full-no-op re-run never reaches here — an existing receipt
		// is only ever replaced by a run that actually mutated (D35).
		rp, err := writeReceipt(opts, cmd, src, receiptOps, tr.createdDirs)
		if err != nil {
			return nil, err
		}
		report.Receipt = rp
	}

	for i, a := range cmd.Asserts {
		res, err := runAssert(cmd, sub, tr, opts, i, a)
		if err != nil {
			return nil, err
		}
		report.Asserts = append(report.Asserts, *res)
		if res.Status == AssertFail {
			report.Ok = false
		}
	}

	report.DurationMS = time.Since(started).Milliseconds()
	return report, nil
}

func commandName(cmd *Command, path string) string {
	if cmd.Header.Command != nil && cmd.Header.Command.Value != "" {
		return cmd.Header.Command.Value
	}
	return strings.TrimSuffix(filepath.Base(path), ".scaffy")
}

// guardSkip evaluates an op's explicit ASLONG guards against the
// file's CURRENT overlay bytes — before any anchor resolution, so a
// consumed anchor on a re-run skips instead of failing (D23):
// DONT CONTAIN acts while the text is absent; positive CONTAIN acts
// only while the text is still present.
func guardSkip(sub *substituter, file string, guards []*Aslong, content []byte) (bool, string, error) {
	for _, g := range guards {
		text, err := sub.text(g.Text, file, g.Pos.Line)
		if err != nil {
			return false, "", err
		}
		has := bytes.Contains(content, []byte(text))
		if g.Dont && has {
			return true, fmt.Sprintf("guard: file already contains %q", text), nil
		}
		if !g.Dont && !has {
			return true, fmt.Sprintf("guard: file no longer contains %q", text), nil
		}
	}
	return false, "", nil
}

// applyOp applies one op against the overlay. It returns the op's
// result plus its receipt entry (nil when the op skipped). A skip
// never aborts siblings; a defect returns an error and aborts the run.
func applyOp(cmd *Command, sub *substituter, tr *tree, index int, op Op) (*OpResult, *ReceiptOp, error) {
	srcFile := cmd.SourceFile
	switch o := op.(type) {
	case *CreateFile:
		return applyCreate(cmd, sub, tr, index, o)
	case *DeleteFile:
		return applyDelete(cmd, sub, tr, index, o)
	case *InOp:
		return applyInOp(cmd, sub, tr, index, o)
	default:
		return nil, nil, applyErrorf(srcFile, op.OpPos().Line, "unknown op kind %T", op)
	}
}

func applyCreate(cmd *Command, sub *substituter, tr *tree, index int, o *CreateFile) (*OpResult, *ReceiptOp, error) {
	srcFile := cmd.SourceFile
	rel, err := sub.text(o.Path.Value, srcFile, o.Path.Pos.Line)
	if err != nil {
		return nil, nil, err
	}
	if _, err := tr.resolve(rel); err != nil {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "%v", err)
	}
	res := &OpResult{Index: index, Kind: "create", Path: rel, Line: o.Pos.Line}
	content, exists, err := tr.read(rel)
	if err != nil {
		return nil, nil, err
	}
	if exists {
		res.Status = OpSkipped
		res.Reason = "file already exists (IF ABSENT)"
		return res, nil, nil
	}
	// Whole-file guards check on-disk content (D28) — an absent file
	// contains nothing.
	if skip, reason, err := guardSkip(sub, srcFile, o.Guards, content); err != nil {
		return nil, nil, err
	} else if skip {
		res.Status = OpSkipped
		res.Reason = reason
		return res, nil, nil
	}
	payload, err := sub.payloadBytes(cmd, o.Payload, srcFile)
	if err != nil {
		return nil, nil, err
	}
	tr.write(rel, payload) // empty fence ⇒ 0-byte file; flush mkdir -p's (D26)
	res.Status = OpCreated
	return res, &ReceiptOp{Kind: "create", Path: rel, PostImage: payload, PostSHA256: sha256Hex(payload)}, nil
}

func applyDelete(cmd *Command, sub *substituter, tr *tree, index int, o *DeleteFile) (*OpResult, *ReceiptOp, error) {
	srcFile := cmd.SourceFile
	rel, err := sub.text(o.Path.Value, srcFile, o.Path.Pos.Line)
	if err != nil {
		return nil, nil, err
	}
	res := &OpResult{Index: index, Kind: "delete", Path: rel, Line: o.Pos.Line}
	content, exists, err := tr.read(rel)
	if err != nil {
		return nil, nil, err
	}
	if !exists {
		res.Status = OpSkipped
		res.Reason = "file already absent (IF PRESENT)"
		return res, nil, nil
	}
	if skip, reason, err := guardSkip(sub, srcFile, o.Guards, content); err != nil {
		return nil, nil, err
	} else if skip {
		res.Status = OpSkipped
		res.Reason = reason
		return res, nil, nil
	}
	tr.delete(rel)
	res.Status = OpDeleted
	return res, &ReceiptOp{Kind: "delete", Path: rel, PreImage: content, PreSHA256: sha256Hex(content)}, nil
}

func applyInOp(cmd *Command, sub *substituter, tr *tree, index int, o *InOp) (*OpResult, *ReceiptOp, error) {
	srcFile := cmd.SourceFile
	rel, err := sub.text(o.Path.Value, srcFile, o.InPos.Line)
	if err != nil {
		return nil, nil, err
	}
	res := &OpResult{Index: index, Kind: inOpKind(o.Verb), Path: rel, Line: o.Pos.Line}

	markName := ""
	if o.Mark != nil {
		markName, err = sub.text(o.Mark.Name, srcFile, o.Mark.Pos.Line)
		if err != nil {
			return nil, nil, err
		}
		res.Mark = markName
	}

	content, exists, err := tr.read(rel)
	if err != nil {
		return nil, nil, err
	}
	if !exists {
		return nil, nil, &PathMissingError{File: srcFile, Line: o.InPos.Line, Path: rel}
	}

	// Guards BEFORE anchor resolution: the implicit planted-MARK guard
	// (a non-virtual mark the op itself plants — its presence means
	// this exact op already ran) and every explicit ASLONG (D23/D24).
	if o.Mark != nil && !o.Mark.Virtual && o.Verb != RemoveVerb {
		planted := "MARK:" + markName
		if bytes.Contains(content, []byte(planted)) {
			res.Status = OpSkipped
			res.Reason = fmt.Sprintf("mark %q already planted", planted)
			return res, nil, nil
		}
	}
	if skip, reason, err := guardSkip(sub, srcFile, o.Guards, content); err != nil {
		return nil, nil, err
	} else if skip {
		res.Status = OpSkipped
		res.Reason = reason
		return res, nil, nil
	}

	target, err := sub.fencedBytes(o.Target, srcFile)
	if err != nil {
		return nil, nil, err
	}
	if len(target) == 0 {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "%s target fence is empty", o.Verb)
	}

	switch o.Verb {
	case InsertAfterFirst, InsertAfterLast, InsertBeforeFirst, InsertBeforeLast:
		payload, err := sub.payloadBytes(cmd, o.Payload, srcFile)
		if err != nil {
			return nil, nil, err
		}
		idx := bytes.Index(content, target)
		if o.Verb == InsertAfterLast || o.Verb == InsertBeforeLast {
			idx = bytes.LastIndex(content, target)
		}
		if idx < 0 {
			return nil, nil, applyErrorf(srcFile, o.Pos.Line, "%s anchor not found in %q", o.Verb, rel)
		}
		// AFTER splices at the anchor's end; BEFORE splices at its start
		// (the anchor survives untouched either way).
		pos := idx + len(target)
		if o.Verb == InsertBeforeFirst || o.Verb == InsertBeforeLast {
			pos = idx
		}
		next := make([]byte, 0, len(content)+len(payload))
		next = append(next, content[:pos]...)
		next = append(next, payload...)
		next = append(next, content[pos:]...)
		tr.write(rel, next)
		res.Status = OpInjected
		return res, &ReceiptOp{Kind: res.Kind, Path: rel, Mark: markName, PostImage: payload, PostSHA256: sha256Hex(payload)}, nil

	case RemoveVerb:
		// The consumed-mark retraction (D25). Byte-exact, exactly-once
		// — the same conservatism as D20.
		n := bytes.Count(content, target)
		if n != 1 {
			return nil, nil, applyErrorf(srcFile, o.Pos.Line, "REMOVE block occurs %d times in %q — exactly once required", n, rel)
		}
		next := bytes.Replace(content, target, nil, 1)
		tr.write(rel, next)
		res.Status = OpRemoved
		return res, &ReceiptOp{Kind: res.Kind, Path: rel, Mark: markName, PreImage: target, PreSHA256: sha256Hex(target)}, nil

	case Replace:
		return applyReplace(cmd, sub, tr, o, res, rel, content, target, markName)
	}
	return nil, nil, applyErrorf(srcFile, o.Pos.Line, "unhandled verb %s", o.Verb)
}

func inOpKind(v InOpVerb) string {
	switch v {
	case InsertAfterFirst:
		return "insert-after-first"
	case InsertAfterLast:
		return "insert-after-last"
	case InsertBeforeFirst:
		return "insert-before-first"
	case InsertBeforeLast:
		return "insert-before-last"
	case Replace:
		return "replace"
	case RemoveVerb:
		return "remove"
	}
	return "?"
}

// applyReplace handles REPLACE, including the D21/D33 REANCHOR path.
// Run 1 (no planted family mark in the file): the fenced structural
// target, byte-exact, exactly once (D20). Run ≥2: the effective anchor
// is the LAST planted block of the mark family — extent K lines from
// the UNSUBSTITUTED template — and the splice is: separator comma
// edited in-place onto the prior block's tail line (byte-adjacent to
// its closing byte, never line-start) + the substituted mark-onward
// payload lines. The receipt records the prior sibling block as the
// pre-image (D35 fat — it is a SIBLING run's payload, underivable from
// this run's vars).
func applyReplace(cmd *Command, sub *substituter, tr *tree, o *InOp, res *OpResult, rel string, content, target []byte, markName string) (*OpResult, *ReceiptOp, error) {
	srcFile := cmd.SourceFile
	payload, err := sub.payloadBytes(cmd, o.Payload, srcFile)
	if err != nil {
		return nil, nil, err
	}

	if o.Reanchor != nil {
		prefix, err := sub.text(o.Reanchor.Prefix, srcFile, o.Reanchor.Pos.Line)
		if err != nil {
			return nil, nil, err
		}
		needle := "MARK:" + prefix
		if bytes.Contains(content, []byte(needle)) {
			return reanchorSplice(cmd, sub, tr, o, res, rel, content, needle)
		}
	}

	// Run 1: byte-exact fenced anchor, exactly once (D20 — zero and
	// multiple both fail loud; accretion by whole-line or substring
	// matching is the recorded corruption class).
	n := bytes.Count(content, target)
	if n != 1 {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "REPLACE anchor occurs %d times in %q — exactly once required (D20)", n, rel)
	}
	next := bytes.Replace(content, target, payload, 1)
	tr.write(rel, next)
	res.Status = OpReplaced
	return res, &ReceiptOp{
		Kind: res.Kind, Path: rel, Mark: markName,
		PreImage: target, PreSHA256: sha256Hex(target),
		PostImage: payload, PostSHA256: sha256Hex(payload),
	}, nil
}

// reanchorSplice is the run-≥2 path (D33 static-K-from-template).
func reanchorSplice(cmd *Command, sub *substituter, tr *tree, o *InOp, res *OpResult, rel string, content []byte, needle string) (*OpResult, *ReceiptOp, error) {
	srcFile := cmd.SourceFile
	tpl := payloadTemplate(cmd, o.Payload)
	if tpl == nil {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "REANCHOR REPLACE carries no payload template")
	}
	// K from the UNSUBSTITUTED template: mark-comment line through the
	// payload's last line. Substitution is line-count-invariant (D33a),
	// so no prior-run vars and no receipt continuity are needed.
	markIdx := -1
	for i, ln := range tpl.Lines {
		if strings.Contains(ln, "MARK:") {
			markIdx = i
			break
		}
	}
	if markIdx < 0 {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "REANCHOR requires the payload to plant its MARK comment line")
	}
	k := len(tpl.Lines) - markIdx

	lines := splitKeepNL(content)
	last := -1
	for i, ln := range lines {
		if strings.Contains(ln, needle) {
			last = i
		}
	}
	if last < 0 {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "mark family %q vanished between guard and anchor resolution", needle)
	}
	if last+k > len(lines) {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line,
			"mark family tail desync: block at %s:%d needs %d lines, file ends after %d — the family extent no longer matches the template (D33)",
			rel, last+1, k, len(lines)-last)
	}

	// Assert the prior block's tail-line shape before splicing (D33):
	// the family's last block is always separator-bare, ending in the
	// template's closing byte.
	tailIdx := last + k - 1
	tail := strings.TrimSuffix(lines[tailIdx], "\n")
	trimmedTail := strings.TrimRight(tail, " \t")
	tplLast := strings.TrimRight(tpl.Lines[len(tpl.Lines)-1], " \t")
	if len(tplLast) == 0 {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line, "REANCHOR template's last payload line is blank — no tail shape to anchor on (D33)")
	}
	closing := tplLast[len(tplLast)-1]
	if len(trimmedTail) == 0 || trimmedTail[len(trimmedTail)-1] != closing {
		return nil, nil, applyErrorf(srcFile, o.Pos.Line,
			"mark family tail desync: prior block tail %q does not end in %q as the template requires — refusing to splice (D33)",
			trimmedTail, string(closing))
	}

	preImage := []byte(strings.Join(lines[last:last+k], ""))

	subLines, err := sub.fencedLines(tpl, srcFile)
	if err != nil {
		return nil, nil, err
	}
	newLines := subLines[markIdx:]

	// Separator comma edited in-place, byte-adjacent to the closing
	// byte — never line-start (D33).
	rest := tail[len(trimmedTail):]
	newTail := trimmedTail + "," + rest + "\n"

	var next []byte
	for i, ln := range lines {
		if i == tailIdx {
			next = append(next, newTail...)
			next = append(next, joinLines(newLines)...)
			continue
		}
		next = append(next, ln...)
	}
	tr.write(rel, next)

	postImage := append([]byte(newTail), joinLines(newLines)...)
	res.Status = OpReplaced
	res.Reanchored = true
	return res, &ReceiptOp{
		Kind: res.Kind, Path: rel, Mark: res.Mark, Reanchored: true,
		PreImage: preImage, PreSHA256: sha256Hex(preImage),
		PostImage: postImage, PostSHA256: sha256Hex(postImage),
	}, nil
}

// splitKeepNL splits bytes into lines, each keeping its trailing
// newline (the last line may lack one). Byte-conservative: the concat
// of the result is the input.
func splitKeepNL(b []byte) []string {
	var out []string
	for len(b) > 0 {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			out = append(out, string(b))
			break
		}
		out = append(out, string(b[:i+1]))
		b = b[i+1:]
	}
	return out
}

// runAssert evaluates one closing assertion. FILE checks are pure
// reads against the overlay (post-flush that IS the disk; in dry-run
// it is the computed post-state). CMDs follow D38; TIER ci is reported
// deferred and never executed; in dry-run LOCAL CMDs are listed as
// would-run and never executed either (D39).
func runAssert(cmd *Command, sub *substituter, tr *tree, opts RunOptions, index int, a *Assert) (*AssertResult, error) {
	srcFile := cmd.SourceFile
	res := &AssertResult{Index: index, Line: a.Pos.Line, Tier: a.Tier}

	if a.Kind == AssertCmd {
		res.Kind = "cmd"
		text, err := sub.text(a.Text, srcFile, a.TextPos.Line)
		if err != nil {
			return nil, err
		}
		res.Text = text
		if a.Tier == "ci" {
			res.Status = AssertDeferred
			res.Detail = "TIER ci — deferred to the PR, never run locally (D38)"
			return res, nil
		}
		if opts.DryRun {
			res.Status = AssertWouldRun
			return res, nil
		}
		ctx, cancel := context.WithTimeout(context.Background(), assertCmdTimeout)
		defer cancel()
		// D38+D101: sh -c with the VERBATIM (substituted) command string
		// from the repo root — never pre-cd, strings carry their own cd.
		// D101 (amends D38): default CC=/usr/bin/clang ONLY when the
		// ambient env carries no CC — a stranger's CC (a real cross host,
		// a node-gyp/NIF build that honors it) is preserved verbatim,
		// never clobbered by our sentinel.
		c := exec.CommandContext(ctx, "sh", "-c", text)
		c.Dir = opts.RepoRoot
		c.Env = os.Environ()
		if _, ok := os.LookupEnv("CC"); !ok {
			c.Env = append(c.Env, "CC=/usr/bin/clang")
		}
		out, err := c.CombinedOutput()
		if err != nil {
			res.Status = AssertFail
			detail := strings.TrimSpace(string(out))
			if ctx.Err() == context.DeadlineExceeded {
				detail = fmt.Sprintf("timeout after %s", assertCmdTimeout)
			} else if detail == "" {
				detail = err.Error()
			}
			res.Detail = truncate(detail, 2000)
			return res, nil
		}
		res.Status = AssertPass
		return res, nil
	}

	rel, err := sub.text(a.Path.Value, srcFile, a.Pos.Line)
	if err != nil {
		return nil, err
	}
	res.Path = rel
	content, exists, err := tr.read(rel)
	if err != nil {
		return nil, err
	}
	switch a.Kind {
	case AssertFileExists:
		res.Kind = "file-exists"
		if exists {
			res.Status = AssertPass
		} else {
			res.Status = AssertFail
			res.Detail = "file missing"
		}
	case AssertFileAbsent:
		res.Kind = "file-absent"
		if !exists {
			res.Status = AssertPass
		} else {
			res.Status = AssertFail
			res.Detail = "file still present"
		}
	case AssertFileContains, AssertFileDontContain:
		text, err := sub.text(a.Text, srcFile, a.TextPos.Line)
		if err != nil {
			return nil, err
		}
		res.Text = text
		has := exists && bytes.Contains(content, []byte(text))
		if a.Kind == AssertFileContains {
			res.Kind = "file-contains"
			if has {
				res.Status = AssertPass
			} else {
				res.Status = AssertFail
				res.Detail = "text not found"
				if !exists {
					res.Detail = "file missing"
				}
			}
		} else {
			res.Kind = "file-dont-contain"
			if has {
				res.Status = AssertFail
				res.Detail = "text still present"
			} else {
				res.Status = AssertPass
			}
		}
	default:
		return nil, applyErrorf(srcFile, a.Pos.Line, "unknown assert kind %v", a.Kind)
	}
	return res, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + " …[truncated]"
}

// treeDiffs renders the overlay's pending mutations as per-file -/+
// line diffs (dry-run, D39 — hand-rolled LCS, dep-free).
func treeDiffs(tr *tree) ([]FileDiff, error) {
	var diffs []FileDiff
	for _, rel := range tr.touched {
		abs, err := tr.resolve(rel)
		if err != nil {
			return nil, err
		}
		var before []byte
		if b, err := os.ReadFile(abs); err == nil {
			before = b
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		var after []byte
		if !tr.deleted[rel] {
			after = tr.files[rel]
		}
		lines := diffLines(splitPlain(before), splitPlain(after))
		diffs = append(diffs, FileDiff{Path: rel, Lines: lines})
	}
	return diffs, nil
}

func splitPlain(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	s := strings.TrimSuffix(string(b), "\n")
	return strings.Split(s, "\n")
}

// diffLines emits the -/+ lines of an LCS line diff (equal lines are
// omitted — the dry-run report shows what leaves and what arrives).
func diffLines(a, b []string) []string {
	// Guard the DP table on pathological sizes: fall back to a plain
	// swap rendering.
	if len(a)*len(b) > 4<<20 {
		out := make([]string, 0, len(a)+len(b))
		for _, l := range a {
			out = append(out, "-"+l)
		}
		for _, l := range b {
			out = append(out, "+"+l)
		}
		return out
	}
	n, m := len(a), len(b)
	lcs := make([][]int, n+1)
	for i := range lcs {
		lcs[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else if lcs[i+1][j] >= lcs[i][j+1] {
				lcs[i][j] = lcs[i+1][j]
			} else {
				lcs[i][j] = lcs[i][j+1]
			}
		}
	}
	var out []string
	i, j := 0, 0
	for i < n && j < m {
		switch {
		case a[i] == b[j]:
			i++
			j++
		case lcs[i+1][j] >= lcs[i][j+1]:
			out = append(out, "-"+a[i])
			i++
		default:
			out = append(out, "+"+b[j])
			j++
		}
	}
	for ; i < n; i++ {
		out = append(out, "-"+a[i])
	}
	for ; j < m; j++ {
		out = append(out, "+"+b[j])
	}
	return out
}
