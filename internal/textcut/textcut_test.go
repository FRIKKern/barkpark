package textcut

import (
	"math/rand"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/rivo/uniseg"
)

const (
	scotland = "🏴\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F"
	mark     = "́"
	family   = "👨‍👩‍👧"
)

func TestPrefix(t *testing.T) {
	cases := []struct {
		name string
		in   string
		max  int
		want string
	}{
		{"a cut between a flag's two indicators drops the flag", "ab🇳🇴", 6, "ab"},
		{"text after the flag does not keep half of it", "ab🇳🇴cd", 9, "ab"},
		{"a cut at the flag's end keeps it", "ab🇳🇴cd", 10, "ab🇳🇴"},
		{"pairing counts from the start of a run of indicators", "🇳🇴🇸🇪", 12, "🇳🇴"},
		{"a cut inside a tag flag drops the whole flag", "ab" + scotland + "!", 10, "ab"},
		{"a cut at a tag flag's end keeps it", "ab" + scotland + "!", 2 + len(scotland), "ab" + scotland},
		{"a cut after a joiner drops the whole ZWJ sequence", "ab" + family + "z", 2 + len("👨‍"), "ab"},
		{"a combining mark belongs to its letter", "abce" + mark + "z", 4, "abc"},
		{"CR LF is one grapheme", "ab\r\ncd", 3, "ab"},
		{"a rune is never split", "a🐕", 4, "a"},
		{"an oversized grapheme keeps its rune prefix", "x" + strings.Repeat(mark, 100), 7, "x" + strings.Repeat(mark, 3)},
		{"an oversized flag is dropped", "🇳🇴", 4, ""},
		{"an oversized tag flag is dropped", scotland, 10, ""},
		{"short text is unchanged", "abc", 3, "abc"},
		{"a zero budget is empty", "abc", 0, ""},
		{"a negative budget is empty", "abc", -1, ""},
		{"a bad byte is kept as a grapheme of its own", "ab\xffcdef", 4, "ab\xffc"},
		{"an emoji before a bad byte is kept whole", "a🏴\xffbc", 5, "a🏴"},
		{"an emoji cut before a bad byte is dropped", "🐕\xffx", 2, ""},
		{"a flag letter cut before a bad byte is dropped", "a🇳🇴\xff", 6, "a"},
		// U+0600 is a Prepend: GB9b joins it to the bad byte after it, so a
		// cut right after it lands inside a grapheme of the whole text.
		{"a prepend joined to the bad byte at the budget is dropped", "a؀\x80zz", 3, "a"},
		// With nothing before it, that grapheme is the first and oversized:
		// its valid rune prefix is kept, as for any oversized grapheme.
		{"an oversized prepend grapheme keeps its rune prefix", "؀\x80zz", 2, "؀"},
	}
	for _, c := range cases {
		if got := Prefix(c.in, c.max); got != c.want {
			t.Errorf("%s: Prefix(%q, %d) = %q, want %q", c.name, c.in, c.max, got, c.want)
		}
	}
}

// Every cut of valid mixed text is the longest prefix that ends on one of the
// text's own grapheme boundaries, as uniseg finds them over the WHOLE text.
func TestPrefixEndsOnTheWholeTextsBoundaries(t *testing.T) {
	text := "a🇳🇴b" + scotland + "e" + mark + "\r\n" + family + "🇸🇪🇳🇴🇫" + "z" + mark + mark + "ok"
	bounds := map[int]bool{0: true}
	end, state := 0, -1
	for rest := text; rest != ""; {
		var cluster string
		cluster, rest, _, state = uniseg.FirstGraphemeClusterInString(rest, state)
		end += len(cluster)
		bounds[end] = true
	}
	for max := 0; max <= len(text); max++ {
		got := len(Prefix(text, max))
		want := 0
		for b := range bounds {
			if b <= max && b > want {
				want = b
			}
		}
		if got != want {
			t.Errorf("max %d: cut at %d, want %d", max, got, want)
		}
	}
}

func TestPrefixFuzzWithBadBytes(t *testing.T) {
	pool := []string{"a", "b", " ", "\r", "\n", "é", mark, "🐕", "‍", "🇳", "🇴", "🏴",
		"\U000E0067", "\U000E007F", "中", "؀", "\xff", "\xc3", "\x80"}
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 5000; i++ {
		var b strings.Builder
		for n := rng.Intn(12) + 1; n > 0; n-- {
			b.WriteString(pool[rng.Intn(len(pool))])
		}
		text := b.String()
		max := rng.Intn(len(text) + 1)
		got := Prefix(text, max)
		if !strings.HasPrefix(text, got) {
			t.Fatalf("Prefix(%q, %d) = %q is not a prefix", text, max, got)
		}
		if len(text) > max && len(got) > max {
			t.Fatalf("Prefix(%q, %d) = %q is over the budget", text, max, got)
		}
		if splitsValidRune(text, len(got)) {
			t.Fatalf("Prefix(%q, %d) = %q splits a rune", text, max, got)
		}
		if utf8.ValidString(text) && !utf8.ValidString(got) {
			t.Fatalf("Prefix(%q, %d) = %q is not UTF-8", text, max, got)
		}
		// When a grapheme of the whole text ends within the budget, the cut is
		// the last such end. (Otherwise the first grapheme is oversized, and
		// its own rule applies.)
		if want := lastBoundary(text, max); want > 0 && len(got) != want {
			t.Fatalf("Prefix(%q, %d) = %q, want the whole text's boundary at %d", text, max, got, want)
		}
	}
}

// Does a cut at `at` fall inside a valid multi-byte rune of text? A stray
// continuation byte is no rune start, but no valid rune holds it either.
func splitsValidRune(text string, at int) bool {
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		if r != utf8.RuneError || size > 1 {
			if i < at && at < i+size {
				return true
			}
		}
		i += size
	}
	return false
}

// The last grapheme boundary of the whole of text at or before max.
func lastBoundary(text string, max int) int {
	last, end, state := 0, 0, -1
	for rest := text; rest != ""; {
		var cluster string
		cluster, rest, _, state = uniseg.FirstGraphemeClusterInString(rest, state)
		if end += len(cluster); end > max {
			break
		}
		last = end
	}
	return last
}
