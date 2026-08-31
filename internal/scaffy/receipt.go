package scaffy

// receipt.go — the D35 uniform FAT receipt: one JSON record per
// mutating run, persisted under <repo-root>/.scaffy/receipts/, keyed
// per command + resolved vars so sibling runs coexist and retract
// independently. Fat means store-resolved-images: every op carries its
// resolved post-image bytes (and pre-image bytes for the REPLACE
// family) — a REANCHOR run-≥2 pre-image is a SIBLING run's payload,
// never derivable from the removing run's own vars, so remove replay
// (D36) reads images, never re-derives them. A full-no-op re-run
// writes nothing and therefore never clobbers an existing receipt.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// receiptVersion is the schema version stamped into every receipt.
const receiptVersion = 1

// Receipt is one run's persisted record (D35). []byte fields encode as
// base64 in JSON — images are byte-exact, never text-normalized.
type Receipt struct {
	ReceiptVersion int               `json:"receipt_version"`
	Command        string            `json:"command"`       // the .scaffy path as given to Run
	SourceSHA256   string            `json:"source_sha256"` // sha256 of the command file bytes
	Direction      string            `json:"direction"`
	Vars           map[string]string `json:"vars"` // the resolved var map
	Timestamp      string            `json:"timestamp"`
	Ops            []ReceiptOp       `json:"ops"` // mutating ops only, in apply order
	// CreatedDirs are the directories the apply's flush actually
	// mkdir'd for CREATE ops (never pre-existing ones), repo-relative
	// forward-slash, shallow→deep. Remove rmdirs them deepest-first when
	// empty. Omitted (nil) on runs that created no new dirs, and absent
	// entirely from receipts written before this field existed — a
	// pre-field receipt simply prunes nothing (backward compatible).
	CreatedDirs []string `json:"created_dirs,omitempty"`
}

// ReceiptOp is one applied op's fat record.
type ReceiptOp struct {
	Kind       string `json:"kind"` // create | delete | insert-after-first | insert-after-last | insert-before-first | insert-before-last | replace | remove
	Path       string `json:"path"` // resolved, repo-relative
	Mark       string `json:"mark,omitempty"`
	Reanchored bool   `json:"reanchored,omitempty"`
	PreImage   []byte `json:"pre_image,omitempty"` // REPLACE family + delete/remove
	PreSHA256  string `json:"pre_sha256,omitempty"`
	PostImage  []byte `json:"post_image,omitempty"` // bytes the op wrote
	PostSHA256 string `json:"post_sha256,omitempty"`
}

// ReadReceipt loads a persisted receipt (the D36 remove-replay seam).
// A torn or undecodable body (a crash mid-write under the old
// single-os.WriteFile path, or hand corruption) gets an actionable
// message instead of a silent dead end: a receipt that can't be read
// back can't be retracted either, so `bp scaffy remove` needs to be
// told exactly which file to delete and which command to re-run.
func ReadReceipt(path string) (*Receipt, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Receipt
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf(
			"%s: torn or undecodable scaffy receipt (%w) — delete this file and re-run bp scaffy run for the %q command (from the receipt filename) with its original --var values to regenerate it before retrying bp scaffy remove",
			path, err, receiptConceptHint(path))
	}
	return &r, nil
}

// receiptConceptHint pulls the leading <concept> segment out of a
// receipt's D35 filename (<concept>--<primary-var-kebab>--<hash>.json)
// so a torn receipt's error can still name which .scaffy command
// produced it even though its JSON body can't be decoded.
func receiptConceptHint(path string) string {
	base := strings.TrimSuffix(filepath.Base(path), ".json")
	concept, _, found := strings.Cut(base, "--")
	if !found || concept == "" {
		return "unknown"
	}
	return concept
}

// receiptPath computes the D35 location:
//
//	<repo-root>/.scaffy/receipts/<concept>--<primary-var-kebab>--<sha256(sorted k=v)[:12]>.json
//
// Per-command+vars keying: two runs of the same command with different
// vars land in distinct files and retract independently.
func receiptPath(repoRoot string, cmd *Command, vars map[string]string) string {
	concept := ""
	if cmd.Header.Concept != nil {
		concept = cmd.Header.Concept.Value
	}
	if concept == "" {
		concept = commandName(cmd, cmd.SourceFile)
	}
	primary := "no-vars"
	if len(cmd.Variables) > 0 {
		if v, ok := vars[cmd.Variables[0].Name]; ok && v != "" {
			primary = joinKebab(splitWords(v))
		}
	}
	name := kebabize(concept) + "--" + kebabize(primary) + "--" + varsKey(vars) + ".json"
	return filepath.Join(repoRoot, ".scaffy", "receipts", name)
}

// varsKey is sha256 over the sorted resolved k=v pairs, hex, first 12.
func varsKey(vars map[string]string) string {
	keys := make([]string, 0, len(vars))
	for k := range vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(vars[k])
		b.WriteByte('\n')
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])[:12]
}

// kebabize folds arbitrary text into a filename-safe kebab word.
func kebabize(s string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		default:
			if !dash && b.Len() > 0 {
				b.WriteByte('-')
				dash = true
			}
		}
	}
	return strings.TrimRight(b.String(), "-")
}

// writeReceipt persists one mutating run's receipt. The caller only
// invokes it when at least one op mutated (D35 — a no-op re-run never
// clobbers the receipt of the run that did the work).
//
// Staged temp-file-plus-rename, the same discipline as tree.flush():
// the new receipt is written, synced and closed under a sibling temp
// name first and only renamed over the real path once that succeeds,
// so an interrupted or failing write leaves the PREVIOUS receipt (or
// no receipt, on a first run) intact rather than a truncated one.
func writeReceipt(opts RunOptions, cmd *Command, src []byte, ops []ReceiptOp, createdDirs []string) (string, error) {
	r := &Receipt{
		ReceiptVersion: receiptVersion,
		Command:        opts.CommandPath,
		SourceSHA256:   sha256Hex(src),
		Direction:      cmd.Direction(),
		Vars:           opts.Vars,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
		Ops:            ops,
		CreatedDirs:    createdDirs,
	}
	path := receiptPath(opts.RepoRoot, cmd, opts.Vars)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	b = append(b, '\n')

	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".scaffy-tmp-*")
	if err != nil {
		return "", fmt.Errorf("stage receipt %s: %w", path, err)
	}
	if werr := stageWrite(tmp, b, 0o644); werr != nil {
		os.Remove(tmp.Name())
		return "", fmt.Errorf("stage receipt %s: %w", path, werr)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return "", fmt.Errorf("commit receipt %s: %w", path, err)
	}
	return path, nil
}

// sha256Hex is the hex digest of b (empty input hashes the empty
// string — a 0-byte post-image is still a checkable image, D26).
func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
