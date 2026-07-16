package scaffy

import (
	"fmt"
	"strings"
)

// Format canonicalizes a .scaffy source's STRUCTURE and nothing else
// (D27): structural keyword lines become flush-left and single-spaced
// (quoted strings kept byte-exact; VARIABLE declarations two-space
// indented, list commas bound to the preceding value — the corpus
// spellings), fence lines are normalized to "::: <label> :::",
// whitespace-only lines collapse to empty, and the file ends with
// exactly one newline. Comment prose and payload bytes are NEVER
// rewritten. Format is idempotent: Format(Format(x)) == Format(x).
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
		formatted := joinFields(fs)
		if fs[0].text == "VARIABLE" && !fs[0].quoted {
			// VARIABLE declarations are children of the header's
			// VARIABLES block — canonically two-space indented (the
			// corpus spelling).
			formatted = "  " + formatted
		}
		out = append(out, formatted)
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
	var parts []string
	for _, f := range fs {
		var s string
		if f.quoted {
			s = `"` + f.raw + `"`
		} else {
			s = f.text
		}
		// a list comma binds to the preceding value: `"a", "b"` — never
		// ` , ` (the TAGS/EXAMPLES comma-separated quoted lists).
		if !f.quoted && f.text == "," && len(parts) > 0 {
			parts[len(parts)-1] += ","
			continue
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, " ")
}
