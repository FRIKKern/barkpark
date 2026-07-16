package scaffy

import (
	"fmt"
	"strings"
)

// Format canonicalizes a .scaffy source's STRUCTURE and nothing else
// (D27): structural keyword lines become flush-left and single-spaced
// (quoted strings kept byte-exact), fence lines are normalized to
// "::: <label> :::", whitespace-only lines collapse to empty, and the
// file ends with exactly one newline. Comment prose and payload bytes
// are NEVER rewritten. Format is idempotent: Format(Format(x)) ==
// Format(x).
//
// Lines it cannot classify safely (malformed quoting) pass through
// verbatim — fmt never guesses. An unclosed fence is an error: without
// the closing line the payload boundary is undecidable.
func Format(src []byte) ([]byte, error) {
	lines := splitLines(src)
	out := make([]string, 0, len(lines))
	inFence := false
	var fenceOpen string // normalized label of the open fence
	openLine := 0
	for n, line := range lines {
		if inFence {
			if isFenceLine(line) {
				// Any fence line ends the block, label match or not —
				// mirroring the parser (a mismatch is its E-001 finding,
				// not fmt's concern).
				out = append(out, fenceLine(fenceLabelOf(line)))
				inFence = false
				continue
			}
			out = append(out, line) // payload bytes, verbatim
			continue
		}
		t := strings.TrimSpace(line)
		if t == "" {
			out = append(out, "")
			continue
		}
		if strings.HasPrefix(t, "#") {
			out = append(out, line) // comment prose, verbatim
			continue
		}
		if isFenceLine(line) {
			fenceOpen = fenceLabelOf(line)
			openLine = n + 1
			out = append(out, fenceLine(fenceOpen))
			inFence = true
			continue
		}
		if strings.HasPrefix(t, ":::") {
			// an indented fence-ish line outside any fence: pass through
			// verbatim — flush-lefting it would change what parses.
			out = append(out, line)
			continue
		}
		fs, err := splitStructural(t)
		if err != nil || len(fs) == 0 {
			out = append(out, line)
			continue
		}
		out = append(out, joinFields(fs))
	}
	if inFence {
		return nil, fmt.Errorf("scaffy: unclosed fence %q opened at line %d", fenceOpen, openLine)
	}
	return []byte(strings.Join(out, "\n") + "\n"), nil
}

func fenceLine(label string) string {
	if label == "" {
		return "::: :::"
	}
	return "::: " + label + " :::"
}

func joinFields(fs []field) string {
	parts := make([]string, len(fs))
	for i, f := range fs {
		if f.quoted {
			parts[i] = `"` + f.raw + `"`
		} else {
			parts[i] = f.text
		}
	}
	return strings.Join(parts, " ")
}
