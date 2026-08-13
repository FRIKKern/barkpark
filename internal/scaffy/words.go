package scaffy

import (
	"strings"
	"unicode"
)

// splitWords splits a variable name or token spelling into its
// lowercase word list. Underscore, hyphen and case boundaries are
// equivalent separators (D22): "BlockName", "block-name", "blockName"
// and "block_name" all split to [block name].
func splitWords(s string) []string {
	var words []string
	var cur []rune
	flush := func() {
		if len(cur) > 0 {
			words = append(words, string(cur))
			cur = nil
		}
	}
	runes := []rune(s)
	for i, r := range runes {
		if r == '_' || r == '-' {
			flush()
			continue
		}
		if i > 0 && unicode.IsUpper(r) {
			prev := runes[i-1]
			if unicode.IsLower(prev) || unicode.IsDigit(prev) {
				// lower→Upper boundary: fooBar
				flush()
			} else if unicode.IsUpper(prev) && i+1 < len(runes) && unicode.IsLower(runes[i+1]) {
				// ACRONYMWord boundary: HTTPServer → http server
				flush()
			}
		}
		cur = append(cur, unicode.ToLower(r))
	}
	flush()
	return words
}

func capitalize(w string) string {
	if w == "" {
		return ""
	}
	r := []rune(w)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}

func joinPascal(ws []string) string {
	var b strings.Builder
	for _, w := range ws {
		b.WriteString(capitalize(w))
	}
	return b.String()
}

func joinCamel(ws []string) string {
	var b strings.Builder
	for i, w := range ws {
		if i == 0 {
			b.WriteString(w)
		} else {
			b.WriteString(capitalize(w))
		}
	}
	return b.String()
}

func joinKebab(ws []string) string { return strings.Join(ws, "-") }
func joinSnake(ws []string) string { return strings.Join(ws, "_") }

// joinScreaming is SCREAMING_SNAKE — the constant-name spelling JS,
// Rust and Python all share (PILOT_PROBE_PROJECTION and friends). Added
// after four-joiner era commands were already in the wild, so it rides
// LAST in every precedence list: no existing collapse resolution moves.
func joinScreaming(ws []string) string { return strings.ToUpper(strings.Join(ws, "_")) }

// spellingsOf returns the five canonical joiner outputs of a word list
// (A1): Pascal, kebab, camel, snake, SCREAMING. Collapsed duplicates (a
// one-word lowercase name has kebab == camel == snake) are kept —
// membership is what matters.
func spellingsOf(ws []string) []string {
	return []string{joinPascal(ws), joinKebab(ws), joinCamel(ws), joinSnake(ws), joinScreaming(ws)}
}

func isJoinerOutput(spelling string, ws []string) bool {
	for _, s := range spellingsOf(ws) {
		if s == spelling {
			return true
		}
	}
	return false
}

// isLowercaseSpelling reports whether a joiner-output spelling is one
// of the two lowercase forms (kebab or snake) — the only spellings
// legal in path positions (E-009).
func isLowercaseSpelling(spelling string, ws []string) bool {
	return spelling == joinKebab(ws) || spelling == joinSnake(ws)
}

func wordsEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
