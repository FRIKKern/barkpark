// Package docdiff compares two versions of a document and renders the result.
//
// It has two users. The TUI's diff view (cmd/barkpark/diff.go) compares the
// editor's field values, which are strings, and prints every line of both
// sides: FieldRows. `bp doc diff` (internal/cli/doc_diff_cmd.go) compares two
// decoded JSON documents field by field: Diff, Summary and Render.
package docdiff

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

// Kind says what happened to the value at a path.
type Kind string

const (
	Added   Kind = "added"
	Removed Kind = "removed"
	Changed Kind = "changed"
	// Moved is reported once for an array of keyed rows whose order changed.
	// Before and After hold the `_key` values of the rows both sides have, in
	// each side's order.
	Moved Kind = "moved"
)

// Change is one difference. Path is dotted, with [n] for an array row:
// `seo.title`, `blocks[2].text`. A row of a keyed array is numbered by its
// place in the new version, or in the old one when it was removed.
type Change struct {
	Path   string `json:"path"`
	Kind   Kind   `json:"kind"`
	Before any    `json:"before"`
	After  any    `json:"after"`
}

// Decode reads a JSON object and keeps numbers as written, so 1 and 1.0 are
// not made equal and a large integer keeps every digit.
func Decode(raw []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v map[string]any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}

// Diff returns the differences between two documents, sorted by path order of
// discovery: object keys alphabetically, array rows in order. A key whose
// value is null counts as a key that is not there.
func Diff(before, after map[string]any) []Change {
	var out []Change
	diffMap("", before, after, &out)
	return out
}

func diffMap(path string, b, a map[string]any, out *[]Change) {
	keys := map[string]bool{}
	for k, v := range b {
		if v != nil {
			keys[k] = true
		}
	}
	for k, v := range a {
		if v != nil {
			keys[k] = true
		}
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		p := joinPath(path, k)
		bv, av := b[k], a[k]
		switch {
		case bv == nil:
			*out = append(*out, Change{Path: p, Kind: Added, After: av})
		case av == nil:
			*out = append(*out, Change{Path: p, Kind: Removed, Before: bv})
		default:
			diffValue(p, bv, av, out)
		}
	}
}

func diffValue(path string, b, a any, out *[]Change) {
	if bm, ok := b.(map[string]any); ok {
		if am, ok := a.(map[string]any); ok {
			diffMap(path, bm, am, out)
			return
		}
	}
	if bs, ok := b.([]any); ok {
		if as, ok := a.([]any); ok {
			bk, bKeyed := rowKeys(bs)
			ak, aKeyed := rowKeys(as)
			if bKeyed && aKeyed && len(bs)+len(as) > 0 {
				diffKeyed(path, bs, as, bk, ak, out)
			} else {
				diffIndexed(path, bs, as, out)
			}
			return
		}
	}
	if !reflect.DeepEqual(b, a) {
		*out = append(*out, Change{Path: path, Kind: Changed, Before: b, After: a})
	}
}

// rowKeys returns the `_key` of every row, and whether every row is an object
// with a `_key` of its own. An empty array counts as keyed.
func rowKeys(rows []any) ([]string, bool) {
	keys := make([]string, 0, len(rows))
	seen := map[string]bool{}
	for _, r := range rows {
		m, ok := r.(map[string]any)
		if !ok {
			return nil, false
		}
		k, ok := m["_key"].(string)
		if !ok || k == "" || seen[k] {
			return nil, false
		}
		seen[k] = true
		keys = append(keys, k)
	}
	return keys, true
}

func diffIndexed(path string, b, a []any, out *[]Change) {
	for i := 0; i < len(b) || i < len(a); i++ {
		p := path + "[" + strconv.Itoa(i) + "]"
		switch {
		case i >= len(b):
			*out = append(*out, Change{Path: p, Kind: Added, After: a[i]})
		case i >= len(a):
			*out = append(*out, Change{Path: p, Kind: Removed, Before: b[i]})
		default:
			diffValue(p, b[i], a[i], out)
		}
	}
}

// diffKeyed matches rows by `_key`, so a row that moved is compared to itself
// and not to the row that took its place.
func diffKeyed(path string, b, a []any, bk, ak []string, out *[]Change) {
	bIndex := map[string]int{}
	for i, k := range bk {
		bIndex[k] = i
	}
	aIndex := map[string]int{}
	for i, k := range ak {
		aIndex[k] = i
	}
	var bShared, aShared []any
	for _, k := range bk {
		if _, ok := aIndex[k]; ok {
			bShared = append(bShared, k)
		}
	}
	for _, k := range ak {
		if _, ok := bIndex[k]; ok {
			aShared = append(aShared, k)
		}
	}
	if !reflect.DeepEqual(bShared, aShared) {
		*out = append(*out, Change{Path: path, Kind: Moved, Before: bShared, After: aShared})
	}
	for i, k := range bk {
		if _, ok := aIndex[k]; !ok {
			*out = append(*out, Change{Path: path + "[" + strconv.Itoa(i) + "]", Kind: Removed, Before: b[i]})
		}
	}
	for i, k := range ak {
		p := path + "[" + strconv.Itoa(i) + "]"
		if j, ok := bIndex[k]; ok {
			diffValue(p, b[j], a[i], out)
		} else {
			*out = append(*out, Change{Path: p, Kind: Added, After: a[i]})
		}
	}
}

func joinPath(path, key string) string {
	plain := key != ""
	for _, r := range key {
		if !(r == '_' || r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z') {
			plain = false
			break
		}
	}
	if !plain {
		return path + "[" + strconv.Quote(key) + "]"
	}
	if path == "" {
		return key
	}
	return path + "." + key
}

// Counts is how many changes there are of each kind.
type Counts struct {
	Changed int `json:"changed"`
	Added   int `json:"added"`
	Removed int `json:"removed"`
	Moved   int `json:"moved"`
}

// Count tallies the changes by kind.
func Count(changes []Change) Counts {
	var c Counts
	for _, ch := range changes {
		switch ch.Kind {
		case Changed:
			c.Changed++
		case Added:
			c.Added++
		case Removed:
			c.Removed++
		case Moved:
			c.Moved++
		}
	}
	return c
}

// Summary is the one-line count: "3 changed, 1 added, 0 removed". Moved
// arrays are named only when there are any.
func Summary(changes []Change) string {
	c := Count(changes)
	s := fmt.Sprintf("%d changed, %d added, %d removed", c.Changed, c.Added, c.Removed)
	if c.Moved > 0 {
		s += fmt.Sprintf(", %d reordered", c.Moved)
	}
	return s
}

// Row is one printed line of a diff. Sign is '-' for the old side, '+' for
// the new side, '~' for a path whose value changed, and ' ' for a note.
type Row struct {
	Sign byte
	Text string
}

// FieldRows is the TUI's view of one changed field: every line of the old
// value as a '-' row, then every line of the new value as a '+' row. An empty
// value prints as "(empty)".
func FieldRows(oldV, newV string) []Row {
	var rows []Row
	for _, side := range []struct {
		sign byte
		v    string
	}{{'-', oldV}, {'+', newV}} {
		for _, ln := range strings.Split(side.v, "\n") {
			if ln == "" && side.v == "" {
				ln = "(empty)"
			}
			rows = append(rows, Row{Sign: side.sign, Text: ln})
		}
	}
	return rows
}
