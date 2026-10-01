package cli

import (
	"encoding/json"
	"fmt"
	"regexp"
	"regexp/syntax"
	"strings"
	"unicode"
)

// patternedString returns a seed value for a string field that carries a
// `validation.pattern`, one that MATCHES the pattern. Content.Validation checks
// the pattern: the write door reports a violation as an advisory (or refuses it
// on an enforcing dataset), and Studio refuses to save the document, so a
// placeholder that violates it seeds documents nobody can edit.
//
// It tries the readable placeholders first (`<name>-<n>`, `<name><n>`, `<n>`,
// `Name n`), so existing slug-style patterns keep their old values. When none
// matches, it builds the shortest string the pattern's syntax tree accepts,
// preferring letters and the digits of n so values stay distinct per document.
// ok is false only when the pattern does not compile or nothing generated
// matches; the caller then keeps its plain placeholder.
func patternedString(raw json.RawMessage, name string, n int) (string, bool) {
	var pattern string
	if json.Unmarshal(raw, &pattern) != nil || pattern == "" {
		return "", false
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return "", false
	}
	slug := slugify(name)
	for _, c := range []string{
		fmt.Sprintf("%s-%d", slug, n),
		fmt.Sprintf("%s%d", strings.ReplaceAll(slug, "-", ""), n),
		fmt.Sprintf("%d", n),
		fmt.Sprintf("%s %d", titleCase(name), n),
	} {
		if re.MatchString(c) {
			return c, true
		}
	}
	tree, err := syntax.Parse(pattern, syntax.Perl)
	if err != nil {
		return "", false
	}
	g := &patternGen{digits: fmt.Sprintf("%d", n), shift: (n - 1) % 26}
	var b strings.Builder
	g.emit(&b, tree.Simplify())
	if out := b.String(); re.MatchString(out) {
		return out, true
	}
	return "", false
}

// patternGen walks a parsed regexp and writes one string it accepts. Digit
// classes draw from the document number so seed-1 and seed-2 differ.
type patternGen struct {
	digits string
	next   int
	shift  int // letter classes start at the n-th letter, so letters differ per doc too
}

func (g *patternGen) digit() rune {
	d := rune(g.digits[g.next%len(g.digits)])
	g.next++
	return d
}

func (g *patternGen) emit(b *strings.Builder, re *syntax.Regexp) {
	switch re.Op {
	case syntax.OpLiteral:
		for _, r := range re.Rune {
			b.WriteRune(r)
		}
	case syntax.OpCharClass:
		b.WriteRune(g.classRune(re.Rune))
	case syntax.OpAnyChar, syntax.OpAnyCharNotNL:
		b.WriteRune('x')
	case syntax.OpCapture:
		g.emit(b, re.Sub[0])
	case syntax.OpConcat:
		for _, s := range re.Sub {
			g.emit(b, s)
		}
	case syntax.OpAlternate:
		g.emit(b, re.Sub[0])
	case syntax.OpPlus:
		g.emit(b, re.Sub[0])
	case syntax.OpRepeat:
		for i := 0; i < re.Min; i++ {
			g.emit(b, re.Sub[0])
		}
	}
	// OpStar, OpQuest, anchors, word boundaries and empty matches emit nothing.
}

// classRune picks a rune from a char class's [lo,hi] pairs: a digit of n when
// the class holds digits, else a letter (rotated by n), else its first printable rune.
func (g *patternGen) classRune(ranges []rune) rune {
	in := func(r rune) bool {
		for i := 0; i+1 < len(ranges); i += 2 {
			if ranges[i] <= r && r <= ranges[i+1] {
				return true
			}
		}
		return false
	}
	if d := g.digit(); in(d) {
		return d
	}
	g.next--
	for _, base := range []rune{'a', 'A'} {
		for i := 0; i < 26; i++ {
			if r := base + rune((g.shift+i)%26); in(r) {
				return r
			}
		}
	}
	for i := 0; i+1 < len(ranges); i += 2 {
		for r := ranges[i]; r <= ranges[i+1]; r++ {
			if unicode.IsPrint(r) {
				return r
			}
		}
	}
	if len(ranges) > 0 {
		return ranges[0]
	}
	return 'x'
}
