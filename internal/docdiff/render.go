package docdiff

import (
	"encoding/json"
	"fmt"
	"strings"
)

const (
	// maxValueRunes is how much of one value a row shows.
	maxValueRunes = 100
	// maxLineRows caps the rows of one multi-line text diff.
	maxLineRows = 40
	// maxLineCells caps the line-by-line comparison table. Two texts over it
	// are not printed line by line; a note gives their sizes.
	maxLineCells = 4_000_000
)

// Render turns the changes into rows for a person: one row per added or
// removed value, and for a changed value its path, then the old and the new
// value. A text of several lines shows only the lines that differ.
func Render(changes []Change) []Row {
	var rows []Row
	for _, c := range changes {
		switch c.Kind {
		case Added:
			rows = append(rows, Row{'+', c.Path + "  " + clip(valueText(c.After), 0)})
		case Removed:
			rows = append(rows, Row{'-', c.Path + "  " + clip(valueText(c.Before), 0)})
		case Moved:
			rows = append(rows, Row{'~', c.Path + "  (rows reordered)"})
			rows = append(rows, Row{'-', "    " + clip(keyList(c.Before), 0)})
			rows = append(rows, Row{'+', "    " + clip(keyList(c.After), 0)})
		case Changed:
			rows = append(rows, Row{'~', c.Path})
			bs, bok := c.Before.(string)
			as, aok := c.After.(string)
			if bok && aok && (strings.Contains(bs, "\n") || strings.Contains(as, "\n")) {
				rows = append(rows, LineRows(bs, as)...)
				continue
			}
			bt, at := valueText(c.Before), valueText(c.After)
			from := 0
			if len([]rune(bt)) > maxValueRunes || len([]rune(at)) > maxValueRunes {
				// Start both sides a little before the first difference, so
				// two long values that differ near the end do not print alike.
				from = commonPrefixRunes(bt, at) - 20
			}
			rows = append(rows, Row{'-', "    " + clip(bt, from)})
			rows = append(rows, Row{'+', "    " + clip(at, from)})
		}
	}
	return rows
}

// Format prints one row as text: the sign, a space, the text.
func (r Row) Format() string {
	return string(r.Sign) + " " + r.Text
}

func valueText(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}

func keyList(v any) string {
	list, _ := v.([]any)
	parts := make([]string, 0, len(list))
	for _, k := range list {
		parts = append(parts, fmt.Sprint(k))
	}
	return strings.Join(parts, ", ")
}

// clip shows up to maxValueRunes runes of s starting at rune from, with an
// ellipsis on each side that was cut.
func clip(s string, from int) string {
	r := []rune(s)
	if from < 0 || len(r) <= maxValueRunes {
		from = 0
	}
	if from > len(r)-maxValueRunes && len(r) > maxValueRunes {
		from = len(r) - maxValueRunes
	}
	end := from + maxValueRunes
	if end > len(r) {
		end = len(r)
	}
	out := string(r[from:end])
	if from > 0 {
		out = "…" + out
	}
	if end < len(r) {
		out += "…"
	}
	return out
}

func commonPrefixRunes(a, b string) int {
	ar, br := []rune(a), []rune(b)
	n := 0
	for n < len(ar) && n < len(br) && ar[n] == br[n] {
		n++
	}
	return n
}

// LineRows compares two texts line by line and returns the lines only one
// side has, in order, then a note with the count of lines both sides share.
func LineRows(oldV, newV string) []Row {
	b, a := strings.Split(oldV, "\n"), strings.Split(newV, "\n")
	var rows []Row
	same := 0
	// The lines both sides start and end with are the same by definition.
	// Setting them aside first keeps a long text with a small change well
	// under the table cap below.
	for len(b) > 0 && len(a) > 0 && b[0] == a[0] {
		b, a, same = b[1:], a[1:], same+1
	}
	for len(b) > 0 && len(a) > 0 && b[len(b)-1] == a[len(a)-1] {
		b, a, same = b[:len(b)-1], a[:len(a)-1], same+1
	}
	if len(b)*len(a) > maxLineCells {
		// Too much differs to compare line by line. Printing every old line
		// as removed would mark lines that did not change, so say how much
		// there is and point at the full values.
		rows = append(rows, Row{' ', fmt.Sprintf("    too long to show line by line: %d line(s) before and %d after differ in the middle; -o json has both texts", len(b), len(a))})
	} else {
		// lcs[i][j] is the length of the longest common run of lines of
		// b[i:] and a[j:].
		lcs := make([][]int, len(b)+1)
		for i := range lcs {
			lcs[i] = make([]int, len(a)+1)
		}
		for i := len(b) - 1; i >= 0; i-- {
			for j := len(a) - 1; j >= 0; j-- {
				switch {
				case b[i] == a[j]:
					lcs[i][j] = lcs[i+1][j+1] + 1
				case lcs[i+1][j] >= lcs[i][j+1]:
					lcs[i][j] = lcs[i+1][j]
				default:
					lcs[i][j] = lcs[i][j+1]
				}
			}
		}
		i, j := 0, 0
		for i < len(b) || j < len(a) {
			switch {
			case i < len(b) && j < len(a) && b[i] == a[j]:
				same++
				i++
				j++
			case j >= len(a) || i < len(b) && lcs[i+1][j] >= lcs[i][j+1]:
				rows = append(rows, Row{'-', "    " + clip(b[i], 0)})
				i++
			default:
				rows = append(rows, Row{'+', "    " + clip(a[j], 0)})
				j++
			}
		}
	}
	if len(rows) > maxLineRows {
		cut := len(rows) - maxLineRows
		rows = append(rows[:maxLineRows], Row{' ', fmt.Sprintf("    … %d more changed line(s)", cut)})
	}
	if same > 0 {
		rows = append(rows, Row{' ', fmt.Sprintf("    (%d line(s) the same)", same)})
	}
	return rows
}
