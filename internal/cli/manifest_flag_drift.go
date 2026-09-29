package cli

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ─── THE MANIFEST/PARSER DRIFT REFUSAL ──────────────────────────────────────
//
// bp is manifest-driven: `bp <noun> <verb> --help` renders the SERVER's
// `GET /v1/capabilities` prose, while the flag PARSER is compiled into the
// local binary. The two can disagree in exactly one direction — the server's
// prose can document a flag this binary does not implement — and when it does
// the CLI actively INSTRUCTS the operator to pass a flag it will then refuse.
//
// Measured shape (task-d69061081fccd709): the tasks plugin's manifest summary
// for `task stamp` tells the operator that `--met` REQUIRES the wording via
// `--criterion-text-file <path>`, and the server's own rejection hint prints
// that flag as THE fix. `--criterion-text-file` is a CLIENT-SIDE flag —
// resolveCriterionTextFile rewrites it away before splitArgs ever sees it, and
// the manifest cannot declare it (the server knows nothing about a local path).
// So a binary older than that feature parses the flag as unknown and answers
// `bp: unknown flag --criterion-text-file for task stamp` plus a usage dump.
//
// A usage dump is the WRONG refusal for that: it says "you typed something
// wrong" about a flag the tool itself just told the operator to type. The
// operator's next move is to retype the wording inline as
// `--criterion-text "…"` — which is the command-substitution trap the file
// door exists to close.
//
// So: whenever an unknown flag is one the manifest's OWN PROSE advertises,
// refuse by NAME — the binary is behind the server manifest — and name the one
// command that fixes it (onbCLIDevRemedy, the same string bp doctor and
// bp upgrade name). A flag that appears nowhere in the manifest prose is an
// ordinary typo and keeps the ordinary usage refusal: the guard can lose.

// manifestFlagDriftCode is the named error code for the drift refusal. It rides
// the CLI-side envelope (nothing was sent, so there is no server reason to map)
// and is deliberately NOT "usage": a stale binary is not a typo.
const manifestFlagDriftCode = "cli_manifest_drift"

// flagDriftError is the unknown-flag error raised when the manifest documents
// the flag. It is a distinct type so the dispatch seam can suppress the usage
// dump (errors.As) without matching on message text.
type flagDriftError struct{ msg string }

func (e *flagDriftError) Error() string { return e.msg }

// manifestAdvertisesFlag reports whether the manifest's prose for cmd mentions
// the long flag `--name` — the command summary or any declared flag's summary.
// Boundary-checked on the right so `--c` does not match `--criterion-text-file`
// and `--criterion` does not match `--criterion-text`.
func manifestAdvertisesFlag(cmd manifest.Command, name string) bool {
	if name == "" {
		return false
	}
	needle := "--" + name
	haystacks := make([]string, 0, len(cmd.Flags)+1)
	haystacks = append(haystacks, cmd.Summary)
	for _, f := range cmd.Flags {
		haystacks = append(haystacks, f.Summary)
	}
	for _, h := range haystacks {
		// PROSE ABOUT A FOREIGN TOOL IS NOT AN ADVERTISEMENT — but only THAT
		// PROSE. A summary that quotes another program's command line
		// (`git rev-list --count …`, `git -C`) mentions flags that are not
		// bp's and never will be, so a drift verdict off that text sends an
		// up-to-date operator to a reinstall that cannot help. The
		// disqualification is scoped to the CLAUSE that talks about the
		// foreign tool; the rest of the field still advertises normally.
		h = withoutForeignProgramClauses(h)
		for i := 0; ; {
			j := strings.Index(h[i:], needle)
			if j < 0 {
				break
			}
			end := i + j + len(needle)
			if end >= len(h) || !isFlagNameByte(h[end]) {
				return true
			}
			i = end
		}
	}
	return false
}

// isFlagNameByte reports whether b can continue a long flag name.
func isFlagNameByte(b byte) bool {
	switch {
	case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9':
		return true
	case b == '-', b == '_':
		return true
	}
	return false
}

// ─── SCOPING THE FOREIGN-TOOL DISQUALIFIER ──────────────────────────────────
//
// The first cut of this guard disqualified the WHOLE FIELD as soon as any
// backticked bare word appeared, and its doc comment claimed "a field that only
// quotes VALUES stays eligible to advertise." That sentence was false about the
// code beneath it: the span reader applied no invocation test at all, so a
// backticked NOUN disqualified the field just as hard as a command line.
//
// Measured over api/lib/barkpark/plugins/tasks.ex (the tasks manifest prose,
// 2026-09-13): 39 long prose strings mention a `--flag`; 5 of those carry a
// backticked bare word; exactly ONE of the 5 is a real program invocation (the
// PDS wave-28 `--rerun` summary quoting `git rev-list --count …`). The other
// four were disqualified by a NOUN — `cursor`/`has_more`, `file_digests`,
// `state`/`open`/`note`, `landed`/`renew` — and three of them advertise real bp
// flags (`--since`, `--files`, `--note`/`--supersede`/`--disposition`) that the
// guard therefore went blind to. A guard that exists so the CLI does not go
// quiet had made four fields quiet.
//
// THE UNIT IS A CLAUSE, NOT A FIELD — and not a bare span either. Scoping to
// the span alone is too narrow on the real prose: the `--rerun` summary writes
// "`git -C` in any spelling (also --git-dir/--work-tree — it retargets the repo
// the check runs against)", so git's own flags sit OUTSIDE the backticks. Span
// scoping would re-open the exact false stale-install verdict on
// `bp task stage --git-dir` that this guard was built to close. The clause that
// invokes the foreign program is the smallest unit that covers the mention and
// still leaves the other four-fifths of that field able to advertise.

// spanInvokesForeignProgram reports whether a backticked code span's first
// token names a program other than bp. It decides what a SPAN is — never what a
// FIELD is. A span whose first token is not a bare word (`-`, the stdin
// spelling; `<path>`; `--files …`) invokes nothing.
func spanInvokesForeignProgram(span string) bool {
	word := strings.TrimSpace(span)
	if k := strings.IndexAny(word, " \t"); k >= 0 {
		word = word[:k]
	}
	if word == "" || word == "bp" || word == "barkpark" {
		return false
	}
	return isBareWord(word)
}

// withoutForeignProgramClauses returns text with every clause that invokes a
// foreign program replaced by a space. Clauses break at `.`, `;`, `!` and `?`
// followed by whitespace or end-of-text, and NEVER inside a backtick span — so
// `git rev-list --count origin/main..<sha>` and `api/lib/x.ex` do not split a
// sentence in half.
func withoutForeignProgramClauses(text string) string {
	var out strings.Builder
	out.Grow(len(text))
	for _, clause := range splitClauses(text) {
		if clauseInvokesForeignProgram(clause) {
			out.WriteByte(' ')
			continue
		}
		out.WriteString(clause)
	}
	return out.String()
}

// clauseInvokesForeignProgram reports whether any complete backtick span in the
// clause invokes a foreign program.
func clauseInvokesForeignProgram(clause string) bool {
	for {
		i := strings.IndexByte(clause, '`')
		if i < 0 {
			return false
		}
		rest := clause[i+1:]
		j := strings.IndexByte(rest, '`')
		if j < 0 {
			return false
		}
		if spanInvokesForeignProgram(rest[:j]) {
			return true
		}
		clause = rest[j+1:]
	}
}

// splitClauses cuts text into clauses at sentence punctuation that is outside a
// backtick span and followed by whitespace or the end of the text. The
// terminator and the whitespace after it stay with the clause they end, so
// concatenating the result reproduces text exactly.
func splitClauses(text string) []string {
	var out []string
	inSpan := false
	start := 0
	for i := 0; i < len(text); i++ {
		switch c := text[i]; {
		case c == '`':
			inSpan = !inSpan
		case inSpan:
		case c == '.' || c == ';' || c == '!' || c == '?':
			j := i + 1
			if j < len(text) && !isSpaceByte(text[j]) {
				continue
			}
			for j < len(text) && isSpaceByte(text[j]) {
				j++
			}
			out = append(out, text[start:j])
			start = j
			i = j - 1
		}
	}
	if start < len(text) {
		out = append(out, text[start:])
	}
	return out
}

// isSpaceByte reports whether b is inter-word whitespace.
func isSpaceByte(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// isBareWord reports whether w is an identifier-shaped program name: a letter
// followed by letters, digits, hyphens or underscores. `-` and `<path>` are not.
func isBareWord(w string) bool {
	if w == "" {
		return false
	}
	c := w[0]
	if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
		return false
	}
	for i := 1; i < len(w); i++ {
		if !isFlagNameByte(w[i]) {
			return false
		}
	}
	return true
}

// flagParsableSomewhere reports whether THIS binary can already parse `--name`
// on SOME command: as a global flag, or as a flag the loaded manifest declares
// on any command at all. bp is manifest-driven, so a flag declared anywhere in
// the manifest is a flag this parser accepts there — which is proof the binary
// is NOT behind the manifest with respect to that flag. The mention is then a
// CROSS-REFERENCE ("unlike stamp's --merge-gated", "the same idea as close's
// --set observed_rev=<rev>"), and the honest answer is the ordinary usage
// refusal, not a stale-install verdict whose prescribed remedy cannot work.
func flagParsableSomewhere(m *manifest.Manifest, name string) bool {
	if name == "" {
		return false
	}
	if isKnownGlobalFlag("--" + name) {
		return true
	}
	if m == nil {
		return false
	}
	for _, c := range m.Commands {
		for _, f := range c.Flags {
			if f.Name == name {
				return true
			}
		}
	}
	return false
}

// unknownFlagError builds the refusal for a flag this binary's parser does not
// declare: the NAMED drift refusal when the manifest advertises it, and the
// ordinary usage error otherwise.
//
// `m` is the loaded manifest (nil when the caller has none). It is what lets
// the guard tell DRIFT from a CROSS-REFERENCE: see flagParsableSomewhere.
// Both disqualifiers fail OPEN, back to the ordinary unknown-flag usage dump —
// the behaviour that predates this guard. That direction is deliberate: a
// missed drift costs the operator one usage dump, while a FALSE "your install
// is stale" suppresses the usage dump and prescribes a reinstall that will
// never fix anything, so the operator loops on a culprit that is not the cause.
func unknownFlagError(m *manifest.Manifest, cmd manifest.Command, spelled, name string) error {
	if manifestAdvertisesFlag(cmd, name) && !flagParsableSomewhere(m, name) {
		return &flagDriftError{msg: fmt.Sprintf(
			"%s: this bp is BEHIND the server manifest — the manifest for %s %s DOCUMENTS %s, but this binary's parser does not implement it. This is a stale install, not a typo: refresh it with `%s`, then re-run. (Do not work around it by retyping the value inline — the flag the manifest names is the safe door.)",
			manifestFlagDriftCode, cmd.Noun, cmd.Verb, spelled, onbCLIDevRemedy)}
	}
	return fmt.Errorf("unknown flag %s for %s %s", spelled, cmd.Noun, cmd.Verb)
}
