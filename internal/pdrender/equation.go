package pdrender

import (
	"regexp"
	"strings"
)

// ── equation ───────────────────────────────────────────────────────────────
//
// Math/equation block (B025) — a confirmed Notion AND Typst gap. TeX source
// in, MathML out on the web (server-side, zero client JS); the terminal has
// no MathML renderer, so it prints a best-effort unicode approximation of
// common TeX constructs (superscripts, subscripts, greek letters, a handful
// of operators) and falls back to the RAW TeX source for anything it doesn't
// recognize — honest degradation, never a fabricated render.
//
//	equation: {tex: "E = mc^2", display?: true}
//
// display (block vs inline sizing) has no terminal effect — width-wrapped
// text either way; it is a web/print sizing hint only.
type equationRenderer struct{}

func (equationRenderer) Render(b Block, ctx RenderCtx) []string {
	tex := strings.TrimSpace(attrStr(b.Attrs, "tex"))
	if tex == "" {
		return nil
	}
	return wrapLines(sanitizeText(texToUnicode(tex)), ctx.Width)
}

// texMacros is the bounded, deterministic set of TeX macros this renderer
// recognizes — greek letters + common math operators. Anything outside this
// set survives verbatim in the raw TeX fallback (honest: a macro table, not
// a TeX parser).
var texMacros = map[string]string{
	`\alpha`:      "α",
	`\beta`:       "β",
	`\gamma`:      "γ",
	`\delta`:      "δ",
	`\epsilon`:    "ε",
	`\theta`:      "θ",
	`\lambda`:     "λ",
	`\mu`:         "μ",
	`\pi`:         "π",
	`\sigma`:      "σ",
	`\phi`:        "φ",
	`\omega`:      "ω",
	`\Delta`:      "Δ",
	`\Gamma`:      "Γ",
	`\Sigma`:      "Σ",
	`\Omega`:      "Ω",
	`\infty`:      "∞",
	`\sum`:        "∑",
	`\int`:        "∫",
	`\prod`:       "∏",
	`\partial`:    "∂",
	`\nabla`:      "∇",
	`\cdot`:       "·",
	`\times`:      "×",
	`\div`:        "÷",
	`\pm`:         "±",
	`\mp`:         "∓",
	`\leq`:        "≤",
	`\geq`:        "≥",
	`\neq`:        "≠",
	`\approx`:     "≈",
	`\equiv`:      "≡",
	`\to`:         "→",
	`\rightarrow`: "→",
	`\leftarrow`:  "←",
	`\in`:         "∈",
	`\notin`:      "∉",
	`\subset`:     "⊂",
	`\cup`:        "∪",
	`\cap`:        "∩",
	`\forall`:     "∀",
	`\exists`:     "∃",
	`\sqrt`:       "√",
}

var (
	texSuperGroup = regexp.MustCompile(`\^\{([^{}]*)\}`)
	texSubGroup   = regexp.MustCompile(`_\{([^{}]*)\}`)
	texSuperChar  = regexp.MustCompile(`\^(.)`)
	texSubChar    = regexp.MustCompile(`_(.)`)
	texFrac       = regexp.MustCompile(`\\frac\{([^{}]*)\}\{([^{}]*)\}`)
	texMacroWord  = regexp.MustCompile(`\\[a-zA-Z]+`)
)

var superDigits = map[rune]rune{
	'0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
	'5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
	'+': '⁺', '-': '⁻', '=': '⁼', '(': '⁽', ')': '⁾', 'n': 'ⁿ', 'i': 'ⁱ',
}

var subDigits = map[rune]rune{
	'0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄',
	'5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
	'+': '₊', '-': '₋', '=': '₌', '(': '₍', ')': '₎',
}

// texToUnicode is a bounded, deterministic best-effort approximation of TeX
// math source: \frac{a}{b} -> "a/b", ^/_ groups or single chars -> unicode
// super/subscript digits (falling back to a bare "^x"/"_x" run when a
// character has no unicode counterpart), and a fixed macro table for greek
// letters/operators. Unrecognized macros pass through verbatim — the raw TeX
// fallback the block's contract calls for.
func texToUnicode(tex string) string {
	s := texFrac.ReplaceAllString(tex, "$1/$2")
	s = texSuperGroup.ReplaceAllStringFunc(s, func(m string) string {
		return toScript(texSuperGroup.FindStringSubmatch(m)[1], superDigits, "^")
	})
	s = texSubGroup.ReplaceAllStringFunc(s, func(m string) string {
		return toScript(texSubGroup.FindStringSubmatch(m)[1], subDigits, "_")
	})
	s = texSuperChar.ReplaceAllStringFunc(s, func(m string) string {
		return toScript(texSuperChar.FindStringSubmatch(m)[1], superDigits, "^")
	})
	s = texSubChar.ReplaceAllStringFunc(s, func(m string) string {
		return toScript(texSubChar.FindStringSubmatch(m)[1], subDigits, "_")
	})
	s = texMacroWord.ReplaceAllStringFunc(s, func(m string) string {
		if u, ok := texMacros[m]; ok {
			return u
		}
		return m // honest fallback: unrecognized macro stays raw TeX
	})
	return s
}

// toScript renders each rune of body through the given super/subscript table;
// a rune with no table entry falls the WHOLE run back to "prefix(body)" (a
// readable raw-TeX-ish fallback) rather than a silently mixed unicode/ASCII run.
func toScript(body string, table map[rune]rune, prefix string) string {
	out := make([]rune, 0, len(body))
	for _, r := range body {
		u, ok := table[r]
		if !ok {
			return prefix + body
		}
		out = append(out, u)
	}
	return string(out)
}
