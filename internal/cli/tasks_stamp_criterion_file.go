package cli

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// ─── THE NON-EVALUATING CRITERION-TEXT DOOR ─────────────────────────────────
//
// `bp task stamp --met` REQUIRES `--criterion-text "<the exact stored wording>"`
// (the server's off-by-one guard: an index alone is unverifiable, so an
// unguarded met-flip is refused). Every documented recipe passed that wording
// back as a DOUBLE-QUOTED shell argument — and criterion wording is MARKDOWN,
// so it is full of `backticked code spans`. In bash and zsh a backtick inside
// double quotes is COMMAND SUBSTITUTION and `$NAME` is a variable expansion:
// the shell EXECUTES whatever the criterion happens to carry, splices the
// output in, and bp is handed text that is not the stored wording.
//
// Measured (task-6576859f2c12a8e8, lead-security-10): a criterion whose wording
// contains `cd api && mix test` made the OPERATOR'S SHELL run the test suite
// before bp saw the argument. The server refused with `criteria_mismatch` — so
// the ledger was safe — but the refusal names an off-by-one index, the operator
// has no reason to suspect their own shell, and the recipe is what produced it.
//
// Two reasons that is more than a wart:
//
//  1. It is arbitrary command execution off LEDGER CONTENT. Rows are written by
//     many agents and by GitHub issue import; the criterion is DATA, and the
//     documented recipe evaluated it, typically as an admin token holder.
//  2. The refusal is the only thing that caught it. A code span that substitutes
//     to something still matching (empty output inside otherwise-identical text)
//     stamps SILENTLY with mangled wording — and evidence is PERMANENT at close.
//
// The fix is not "quote better". It is to stop requiring the wording to make a
// round trip through a shell at all: `--criterion-text-file <path>` (and `-`
// for stdin) reads the bytes from a file, so backticks, `$`, quotes and
// newlines are never evaluated by anything. `--criterion-text` is unchanged and
// still works — this is a second door beside it, not a replacement.
const (
	criterionTextFileFlag = "--criterion-text-file"
	criterionTextFlag     = "--criterion-text"

	// criterionTextSourceCode is the CLI-side error code for a bad
	// --criterion-text-file invocation. Like the merge-gate fallback's refusal
	// it carries its exit explicitly (exitValidation) rather than riding the
	// server-reason table in errors.go: nothing was sent, so no server reason
	// exists to map.
	criterionTextSourceCode = "criterion_text_source"
)

// stampStdin is os.Stdin, indirected so the `-` arm is testable without a real
// pipe (the house pattern — see destroyStdin, hookStdin, hzStdin).
var stampStdin io.Reader = os.Stdin

// resolveCriterionTextFile rewrites a `task stamp` tail, replacing
// `--criterion-text-file <path>` with the INLINE spelling
// `--criterion-text=<the file's bytes>` so the rest of the pipeline
// (parseStampArgs → splitArgs → the POST → the read-back) is untouched and the
// new door can never drift from the old one.
//
// The inline `--flag=value` spelling is deliberate: splitArgs refuses a
// space-form value that is flag-shaped, and a criterion may legitimately begin
// with `-` (a dashed list item). Inline has no such hazard.
//
// `-` as the path reads stdin. Exactly ONE trailing newline is stripped (with a
// preceding CR), because the obvious way to produce the file —
// `bp task get <id> -o json | jq -r '…criterion' > crit.txt` — appends one, and
// the server's comparison is byte-exact. Interior newlines are preserved: a
// multi-paragraph criterion is exactly the shape the shell path could not carry.
//
// Every failure returns an error and NOTHING is forwarded: a stamp that cannot
// read its own guard text must not fall back to sending an unguarded write.
func resolveCriterionTextFile(tail []string) ([]string, error) {
	out := make([]string, 0, len(tail))
	seenFile := false
	seenInline := false
	for i := 0; i < len(tail); i++ {
		name, val, hasInline := splitFlagToken(tail[i])
		if name == criterionTextFlag {
			seenInline = true
			out = append(out, tail[i])
			continue
		}
		if name != criterionTextFileFlag {
			out = append(out, tail[i])
			continue
		}
		path := val
		if !hasInline {
			if i+1 >= len(tail) || strings.HasPrefix(tail[i+1], "--") {
				return nil, fmt.Errorf("%s needs a path (or `-` to read the criterion wording from stdin)", criterionTextFileFlag)
			}
			path = tail[i+1]
			i++
		}
		if strings.TrimSpace(path) == "" {
			return nil, fmt.Errorf("%s was given an empty path", criterionTextFileFlag)
		}
		if seenFile {
			return nil, fmt.Errorf("%s was passed twice — one criterion, one wording, one source", criterionTextFileFlag)
		}
		seenFile = true
		text, err := readCriterionText(path)
		if err != nil {
			return nil, err
		}
		if text == "" {
			return nil, fmt.Errorf("%s %s is empty — the criterion wording is the off-by-one guard, and an empty guard is no guard", criterionTextFileFlag, path)
		}
		out = append(out, criterionTextFlag+"="+text)
	}
	if seenFile && seenInline {
		// Both doors at once cannot be resolved SILENTLY: picking either one
		// would send wording the operator did not mean to send, and the whole
		// point of the guard is that the bytes are the ones they chose.
		return nil, fmt.Errorf("pass EITHER %s or %s, not both — they are two sources for the same guard text and there is no safe way to pick between them (%s is the one that is never evaluated by a shell)",
			criterionTextFlag, criterionTextFileFlag, criterionTextFileFlag)
	}
	return out, nil
}

// readCriterionText reads the criterion wording from a file, or from stdin when
// the path is `-`, and strips exactly one trailing newline. No shell, no
// expansion, no interpretation of any kind — the bytes on disk are the bytes
// that ride the POST.
func readCriterionText(path string) (string, error) {
	var (
		raw []byte
		err error
	)
	if path == "-" {
		raw, err = io.ReadAll(stampStdin)
		if err != nil {
			return "", fmt.Errorf("reading the criterion wording from stdin: %w", err)
		}
	} else {
		raw, err = os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("reading the criterion wording from %s: %w", path, err)
		}
	}
	return trimOneTrailingNewline(string(raw)), nil
}

// trimOneTrailingNewline removes ONE trailing "\n" (and a "\r" before it).
// One, not all: a criterion that genuinely ends in a blank line keeps it, and a
// redirect's single appended newline is the only thing removed.
func trimOneTrailingNewline(s string) string {
	s = strings.TrimSuffix(s, "\n")
	return strings.TrimSuffix(s, "\r")
}

// ─── THE REFUSAL THAT NAMES THE REAL CAUSE ──────────────────────────────────

// explainCriteriaMismatch prints the CLI's half of a `criteria_mismatch`
// refusal. The server's hint (params.ex criteria_hint/2) names exactly one
// candidate cause — "the index is off by one, or the list changed" — and sends
// the operator to re-read the row. When the real cause was their own shell
// EXECUTING a backticked code span in the wording, that hint is a wild goose
// chase: the index was right, the list did not change, and re-reading the row
// produces the same text which they then re-mangle the same way.
//
// So: name the second cause, say which one this invocation is even capable of,
// and hand over the non-evaluating recipe.
func explainCriteriaMismatch(out *writer, cmdText string, fromFile bool) {
	out.errf("note: a text mismatch has TWO candidate causes and the server's hint names only the first.")
	out.errf("  (1) THE INDEX — --criterion is 0-BASED (the first criterion is 0), or the list changed since you read it.")
	if fromFile {
		// The wording came off disk, so nothing evaluated it: cause (2) is
		// RULED OUT here, and saying so is the whole value of knowing the
		// source — it collapses the search back to (1).
		out.errf("  (2) SHELL EVALUATION — RULED OUT for this run: the wording came from %s, so no shell touched it. That leaves (1).", criterionTextFileFlag)
		return
	}
	out.errf("  (2) SHELL EVALUATION — criterion wording is MARKDOWN and full of `backticked code spans`. Inside a")
	out.errf("      DOUBLE-QUOTED shell argument a backtick is COMMAND SUBSTITUTION and $NAME is a variable, so bash/zsh")
	out.errf("      RAN the code span and bp was handed text that is no longer the stored wording. Nothing was written.")
	if marks := shellEvaluationMarks(cmdText); marks != "" {
		out.errf("      The text that reached bp still carries %s — but the ones the shell ATE left no trace, which is why this cause is invisible from the message alone.", marks)
	}
	out.errf("  fix — stop sending the wording through a shell at all:")
	out.errf("      bp task get <id> -o json | jq -r '.doc.content.acceptance_criteria[N].criterion' > crit.txt")
	out.errf("      bp task stamp <id> <worker> <epoch> --criterion N %s crit.txt --met --evidence \"…\"", criterionTextFileFlag)
	out.errf("      (%s - reads it from stdin instead; both send the bytes verbatim — backticks, $, quotes and newlines included.)", criterionTextFileFlag)
}

// shellEvaluationMarks names the substitution-capable characters SURVIVING in
// the text bp received. It is a hint, never a verdict: the dangerous case is
// the one where the shell already consumed them.
func shellEvaluationMarks(s string) string {
	var marks []string
	if strings.Contains(s, "`") {
		marks = append(marks, "a backtick")
	}
	if strings.Contains(s, "$") {
		marks = append(marks, "a $")
	}
	if len(marks) == 0 {
		return ""
	}
	return strings.Join(marks, " and ")
}

// criteriaMismatchReason reports whether a CLI error code is the text-mismatch
// refusal. Server reasons can be minted COMPOUND (`reason:<detail>` — see
// errors.go's family lookup), so match on the part before the colon.
func criteriaMismatchReason(code string) bool {
	if i := strings.IndexByte(code, ':'); i >= 0 {
		code = code[:i]
	}
	return code == "criteria_mismatch"
}

// stampTextCameFromFile reports whether the ORIGINAL tail asked for the
// non-evaluating door. It must be read BEFORE resolveCriterionTextFile rewrites
// the tail, because after the rewrite both doors look identical by design —
// and the mismatch hint's most useful sentence is the one that RULES OUT shell
// evaluation for a run that never used a shell.
func stampTextCameFromFile(tail []string) bool {
	for _, a := range tail {
		if name, _, _ := splitFlagToken(a); name == criterionTextFileFlag {
			return true
		}
	}
	return false
}

// stampCriterionTextHelpLines is the `bp task stamp --help` block for the
// client-side door. The manifest cannot declare --criterion-text-file (it is
// resolved and consumed entirely in this process, exactly like `task ls
// --match`), and a flag nobody can discover is a flag nobody uses — which here
// means the shell-evaluating recipe stays the only one anybody knows.
func stampCriterionTextHelpLines() []string {
	return []string{
		"criterion text (client-side, never evaluated by a shell):",
		"  " + criterionTextFileFlag + " <path>   read the criterion's exact stored wording from a FILE instead of",
		"                              retyping it as a shell argument; `-` reads it from stdin. Backticks, $,",
		"                              quotes and newlines ride through verbatim. ONE trailing newline is",
		"                              stripped, so a `> file` redirect works as-is.",
		"  WHY: criterion wording is MARKDOWN and full of `backticked code spans`, and inside a DOUBLE-QUOTED",
		"  shell argument a backtick is COMMAND SUBSTITUTION — bash/zsh EXECUTE the code span and bp receives",
		"  text that no longer matches the stored wording (409 criteria_mismatch, nothing written).",
		"  e.g. bp task get <id> -o json | jq -r '.doc.content.acceptance_criteria[N].criterion' > crit.txt",
		"       bp task stamp <id> <worker> <epoch> --criterion N " + criterionTextFileFlag + " crit.txt --met --evidence \"…\"",
		"  " + criterionTextFlag + " <value> still works unchanged; pass exactly one of the two.",
	}
}
