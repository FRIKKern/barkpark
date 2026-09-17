package cli

import (
	"sort"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// ve-bl-stamp-flatkey-bug — the READ half of the bracket-key defect.
//
// checkSetKeyIndexing (run.go) stops a bracketed --set key at the write seam,
// so nothing NEW can land. It says nothing about what is already stored: a row
// that took the write before the guard existed still carries a top-level
// content key literally named `acceptance_criteria[5].evidence` beside the
// untouched array, and no reader of `acceptance_criteria[]` ever sees it.
//
// ScanCriteriaResidue is that reader. Point it at a document's decoded content
// and it names every bracket-indexed key, at any depth — the corpus scan the
// row's third criterion asks for, and the assertion a regression test makes
// about PERSISTED content rather than about the request that produced it.
// ---------------------------------------------------------------------------

// ResidueKey is one bracket-indexed key found in stored content.
type ResidueKey struct {
	// Path is the dotted location of the offending key inside the document,
	// e.g. `acceptance_criteria[5].evidence` at the top level or
	// `content.acceptance_criteria[5].met` one level down.
	Path string
	// Head is the field name the key pretends to index (`acceptance_criteria`).
	Head string
}

// IsCriteria reports whether this residue key targets the acceptance_criteria
// array — the shape the row was filed about.
func (r ResidueKey) IsCriteria() bool { return r.Head == "acceptance_criteria" }

// ScanCriteriaResidue walks decoded JSON and returns every map KEY carrying a
// bracket segment, sorted by path. It reads keys only: a bracket inside a
// VALUE — a JSON array, or prose quoting `acceptance_criteria[5]` — is not the
// defect and is never reported.
//
// A key is residue when it satisfies the same predicate the write-seam guard
// refuses (checkSetKeyIndexing): it contains a `[` or a `]`. Keeping one
// predicate on both seams is deliberate — an enumeration of known-bad spellings
// would have to be re-derived every time someone invents a new one.
func ScanCriteriaResidue(v any) []ResidueKey {
	var found []ResidueKey
	var walk func(node any, prefix string)
	walk = func(node any, prefix string) {
		switch n := node.(type) {
		case map[string]any:
			for k, child := range n {
				path := k
				if prefix != "" {
					path = prefix + "." + k
				}
				if bracketKeyHead(k) != "" {
					found = append(found, ResidueKey{Path: path, Head: bracketKeyHead(k)})
				}
				walk(child, path)
			}
		case []any:
			for i, child := range n {
				walk(child, prefix+"["+strconv.Itoa(i)+"]")
			}
		}
	}
	walk(v, "")
	sort.Slice(found, func(i, j int) bool { return found[i].Path < found[j].Path })
	return found
}

// bracketKeyHead returns the field name a bracketed key pretends to index, or
// "" when the key carries no bracket at all. It mirrors checkSetKeyIndexing's
// head extraction so the reader and the refuser agree on what they are naming.
func bracketKeyHead(key string) string {
	open := strings.IndexByte(key, '[')
	if open < 0 && !strings.ContainsRune(key, ']') {
		return ""
	}
	if open > 0 {
		return key[:open]
	}
	return key
}
