package cli

// context_detect.go — the deterministic verbatim detector behind `bp context
// pack`: pure entropy + structure rules that decide, at ingest and with no
// model call, which lines of a context MUST stay as exact text (the sidecar)
// versus which are safe to render optically. Ported line-for-line from the
// validated research harness (see /papers/optical-compression-research-report
// §6): a downscaled glyph render silently corrupts high-entropy strings —
// maximally confusable tokens (0/O, 1/l/I) proved unrecoverable at EVERY glyph
// size tested — so anything that must be reproduced byte-exact is routed to
// text by construction, never by model judgment.
//
// A line is VERBATIM if it contains any of:
//   - a hex run >= 16 chars           (checksums, SHAs, hashes)
//   - a UUID
//   - a ticket/sign-off code           (CAPTAIN-7731, JIRA-1234 shapes)
//   - a URL carrying credentials       (scheme://user:pass@host)
//   - a mixed-class token run >= 20    (API keys, secrets, opaque ids)
//   - a digit run >= 10                (account numbers, numeric ids)
//   - a KEY=VALUE whose value is high-entropy and opaque
//   - any other URL >= 8 chars of body (paths and params corrupt too)
//
// Everything else — prose, comments, low-entropy config — is image-safe.

import (
	"math"
	"regexp"
	"strings"
)

var (
	ctxHexRun  = regexp.MustCompile(`\b[0-9a-fA-F]{16,}\b`)
	ctxUUID    = regexp.MustCompile(`\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b`)
	ctxCode    = regexp.MustCompile(`\b[A-Z][A-Z0-9]{2,}-\d{2,}\b`)
	ctxCredURL = regexp.MustCompile(`\b\w+://[^\s:@/]+:[^\s:@/]+@\S+`)
	ctxURLAny  = regexp.MustCompile(`\b\w+://\S{8,}`)
	// RE2 has no lookahead, so the mixed-class token rule is a candidate-run
	// regexp plus a class check in code (hasMixedClasses).
	ctxTokenRun = regexp.MustCompile(`\b[A-Za-z0-9+/_=-]{20,}\b`)
	ctxDigitRun = regexp.MustCompile(`\d{10,}`)
	ctxKV       = regexp.MustCompile(`^\s*([A-Za-z_][\w.-]*)\s*[=:]\s*(\S.*)$`)
)

// hasMixedClasses reports whether s mixes upper, lower, and digit — the
// signature of a machine-minted token rather than a word or a plain number.
func hasMixedClasses(s string) bool {
	var upper, lower, digit bool
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z':
			upper = true
		case r >= 'a' && r <= 'z':
			lower = true
		case r >= '0' && r <= '9':
			digit = true
		}
	}
	return upper && lower && digit
}

// shannonEntropy is bits-per-character over the byte distribution of s.
func shannonEntropy(s string) float64 {
	if s == "" {
		return 0
	}
	var counts [256]int
	for i := 0; i < len(s); i++ {
		counts[s[i]]++
	}
	n := float64(len(s))
	var h float64
	for _, c := range counts {
		if c == 0 {
			continue
		}
		p := float64(c) / n
		h -= p * math.Log2(p)
	}
	return h
}

// highEntropyValue reports whether a KEY=VALUE value looks like a secret or an
// opaque id rather than a word, a number, or an enum: single-token, >= 12
// chars, mostly alphanumeric, entropy >= 3.2 bits/char, and mixing letters
// with digits. Trailing comments are stripped before judging.
func highEntropyValue(v string) bool {
	if i := strings.Index(v, "#"); i >= 0 {
		v = v[:i]
	}
	v = strings.TrimSpace(v)
	if len(v) < 12 || strings.ContainsAny(v, " \t") {
		return false
	}
	alnum := 0
	hasAlpha, hasDigit := false, false
	for _, r := range v {
		switch {
		case r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z':
			alnum++
			hasAlpha = true
		case r >= '0' && r <= '9':
			alnum++
			hasDigit = true
		}
	}
	if float64(alnum)/float64(len(v)) < 0.6 {
		return false
	}
	return shannonEntropy(v) >= 3.2 && hasAlpha && hasDigit
}

// classifyContextLine returns whether the line must stay as exact text, plus
// the rule names that fired (the sidecar records them for auditability).
func classifyContextLine(line string) (bool, []string) {
	var reasons []string
	if ctxCredURL.MatchString(line) {
		reasons = append(reasons, "cred-url")
	}
	if ctxUUID.MatchString(line) {
		reasons = append(reasons, "uuid")
	}
	if ctxCode.MatchString(line) {
		reasons = append(reasons, "code-token")
	}
	if ctxHexRun.MatchString(line) {
		reasons = append(reasons, "hex-run")
	}
	for _, run := range ctxTokenRun.FindAllString(line, -1) {
		if hasMixedClasses(run) {
			reasons = append(reasons, "token-run")
			break
		}
	}
	if ctxDigitRun.MatchString(line) {
		reasons = append(reasons, "digit-run")
	}
	if m := ctxKV.FindStringSubmatch(line); m != nil && highEntropyValue(m[2]) {
		reasons = append(reasons, "kv-opaque")
	}
	// A URL without credentials is still verbatim-critical: its path and query
	// corrupt as silently as a hash. Flag only when nothing else already has.
	if len(reasons) == 0 && ctxURLAny.MatchString(line) {
		reasons = append(reasons, "url")
	}
	return len(reasons) > 0, reasons
}

// contextVerbatimLine is one flagged line: its 0-based index in the packed
// body and the rules that fired.
type contextVerbatimLine struct {
	Index   int      `json:"index"`
	Line    string   `json:"line"`
	Reasons []string `json:"reasons"`
}

// detectVerbatim partitions body lines into the flagged set. The image still
// carries EVERY line (structure and locality survive); the sidecar duplicates
// only the flagged ones as the authoritative exact copy.
func detectVerbatim(lines []string) []contextVerbatimLine {
	var out []contextVerbatimLine
	for i, l := range lines {
		if ok, reasons := classifyContextLine(l); ok {
			out = append(out, contextVerbatimLine{Index: i, Line: l, Reasons: reasons})
		}
	}
	return out
}
