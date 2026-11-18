// Package textcut cuts text to a byte budget on a grapheme boundary.
//
// Backing off to the last whole rune is not enough. A flag is two regional
// indicators, and one of them alone draws as a boxed letter. A tag flag (🏴
// and its tags) cut inside its tags draws as a plain black flag. A ZWJ
// sequence cut after its joiner leaves a dangling joiner. So the cut backs off
// to the last whole grapheme (task-a743c93d44c11c48), the Go twin of the
// server's Barkpark.ByteCut (api/lib/barkpark/byte_cut.ex).
//
// One grapheme can be larger than the whole budget: one letter with many
// combining marks is a single grapheme. Then the cut keeps that grapheme's rune
// prefix, so the letter and some of its marks still show. A flag is never kept
// in part: an oversized flag grapheme is dropped.
//
// A byte that is not UTF-8 is kept, and is a grapheme of its own, as these
// cuts kept such bytes before (the server's twin cuts at the first bad byte,
// because its output must be JSON). A cut never splits a valid rune.
package textcut

import (
	"unicode/utf8"

	"github.com/rivo/uniseg"
)

// @canonical capability:go-grapheme-byte-cut aka:utf8.RuneStart,rune boundary,truncate,clamp,lone regional indicator
// Prefix returns the longest prefix of s that is at most maxBytes bytes and
// ends on a grapheme boundary of s.
func Prefix(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	if maxBytes <= 0 {
		return ""
	}
	// Whether a byte offset is a grapheme boundary depends on nothing after
	// the rune that starts there, so segmenting s through one rune past the
	// budget gives the same boundaries as segmenting all of s, and a giant
	// final grapheme is never read in full.
	window := s[:runeEnd(s, maxBytes)]
	end, state := 0, -1
	for rest := window; rest != ""; {
		var cluster string
		cluster, rest, _, state = uniseg.FirstGraphemeClusterInString(rest, state)
		if end+len(cluster) > maxBytes {
			break
		}
		end += len(cluster)
	}
	if end > 0 {
		return window[:end]
	}
	return oversized(validPrefix(s[:maxBytes]))
}

// The end of the whole rune that holds byte i of s (i < len(s)): the rune that
// crosses the budget, or the one that starts right at it.
func runeEnd(s string, i int) int {
	start := i
	for start > 0 && i-start < utf8.UTFMax && !utf8.RuneStart(s[start]) {
		start--
	}
	_, size := utf8.DecodeRuneInString(s[start:])
	return max(start+size, i)
}

// The first grapheme is larger than the budget: keep its rune prefix, unless
// it is a flag.
func oversized(whole string) string {
	for _, r := range whole {
		if (r >= 0x1F1E6 && r <= 0x1F1FF) || (r >= 0xE0020 && r <= 0xE007F) {
			return ""
		}
	}
	return whole
}

// The longest prefix of s that is valid UTF-8.
func validPrefix(s string) string {
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size <= 1 {
			return s[:i]
		}
		i += size
	}
	return s
}
