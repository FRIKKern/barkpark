package cli

import (
	"fmt"
	"strings"
)

// ─── THE NON-EVALUATING AMENDED-CRITERION DOOR ──────────────────────────────
//
// `bp task stamp --amend` (server half: #19930) replaces a criterion's WORDING
// on a row — usually a SEALED one — when the sentence itself turned out false.
// The replacement is criterion wording, i.e. MARKDOWN full of `backticked code
// spans`, so the inline `--amended-criterion "…"` has exactly the hazard
// `--criterion-text "…"` has: bash/zsh EXECUTE the backticks and expand $NAME
// before bp runs, and the ledger stores whatever the shell produced. Two lanes
// corrupted stored prose that way on 2026-09-23, one writing an operator's
// `id` output into a shared field.
//
// The server's manifest has always told the operator to use
// `--amended-criterion-file <path>` — but no bp parser implemented it, so every
// binary refused the documented recipe as cli_manifest_drift and prescribed a
// reinstall that could not help (task-f65368969b1a2471). This is that flag.
//
// It mirrors resolveCriterionTextFile exactly: the file's bytes are rewritten
// into the inline `--amended-criterion=<bytes>` spelling before parseStampArgs
// and splitArgs see the tail, so the rest of the pipeline is untouched and the
// value rides the POST body as `amended_criterion` (stampBodyKey). `-` reads
// stdin. ONE trailing newline is stripped — the same rule, via the same
// function (trimOneTrailingNewline), as the criterion-text file, so a pair of
// `jq -r … > file` files is treated identically on both sides of the CAS.
const (
	amendedCriterionFileFlag = "--amended-criterion-file"
	amendedCriterionFlag     = "--amended-criterion"

	// amendedCriterionSourceCode is the CLI-side refusal code for a bad
	// --amended-criterion-file invocation. Nothing was sent, so like
	// criterion_text_source it carries exitValidation explicitly.
	amendedCriterionSourceCode = "amended_criterion_source"
)

// resolveAmendedCriterionFile rewrites `--amended-criterion-file <path>` into
// `--amended-criterion=<the file's bytes>`. Every failure returns an error and
// NOTHING is forwarded.
//
// BLANK IS REFUSED HERE, not passed through. The server refuses blank
// replacement wording too — 400 invalid_stamp out of Params.parse_stamp/1,
// which tests String.trim, so whitespace-only counts as blank — and this
// applies the SAME rule (TrimSpace) one hop earlier, the way an empty
// --criterion-text-file is refused before anything is sent. Emptying a
// criterion is a deletion, not a correction.
func resolveAmendedCriterionFile(tail []string) ([]string, error) {
	out := make([]string, 0, len(tail))
	seenFile := false
	seenInline := false
	for i := 0; i < len(tail); i++ {
		name, val, hasInline := splitFlagToken(tail[i])
		if name == amendedCriterionFlag {
			seenInline = true
			out = append(out, tail[i])
			continue
		}
		if name != amendedCriterionFileFlag {
			out = append(out, tail[i])
			continue
		}
		path := val
		if !hasInline {
			if i+1 >= len(tail) || strings.HasPrefix(tail[i+1], "--") {
				return nil, fmt.Errorf("%s needs a path (or `-` to read the replacement wording from stdin)", amendedCriterionFileFlag)
			}
			path = tail[i+1]
			i++
		}
		if strings.TrimSpace(path) == "" {
			return nil, fmt.Errorf("%s was given an empty path", amendedCriterionFileFlag)
		}
		if seenFile {
			return nil, fmt.Errorf("%s was passed twice — one criterion, one replacement, one source", amendedCriterionFileFlag)
		}
		seenFile = true
		text, err := readStampTextFile(path, "the replacement criterion wording")
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(text) == "" {
			return nil, fmt.Errorf("%s %s is blank — refusing before anything is sent: emptying a criterion is a DELETION, not a correction (the server refuses blank replacement wording too)", amendedCriterionFileFlag, path)
		}
		out = append(out, amendedCriterionFlag+"="+text)
	}
	if seenFile && seenInline {
		return nil, fmt.Errorf("pass EITHER %s or %s, not both — they are two sources for the same replacement wording and there is no safe way to pick between them (%s is the one that is never evaluated by a shell)",
			amendedCriterionFlag, amendedCriterionFileFlag, amendedCriterionFileFlag)
	}
	return out, nil
}

// stampStdinClaimedTwice reports whether BOTH text-file doors asked for stdin.
// There is one stdin: the first reader would take all of it and the second
// would read nothing, so the refusal has to come before either reads.
func stampStdinClaimedTwice(tail []string) bool {
	n := 0
	for i := 0; i < len(tail); i++ {
		name, val, inline := splitFlagToken(tail[i])
		if name != criterionTextFileFlag && name != amendedCriterionFileFlag {
			continue
		}
		if !inline && i+1 < len(tail) {
			val = tail[i+1]
		}
		if val == "-" {
			n++
		}
	}
	return n > 1
}

// stampAmendHelpLines is the `bp task stamp --help` block for the client-side
// amendment door, shown beside the criterion-text block for the same reason:
// the manifest cannot render a flag it does not declare.
func stampAmendHelpLines() []string {
	return []string{
		"replacement wording for --amend (client-side, never evaluated by a shell):",
		"  " + amendedCriterionFileFlag + " <path>   read the REPLACEMENT wording from a FILE; `-` reads stdin.",
		"                              ONE trailing newline is stripped (same rule as " + criterionTextFileFlag + "),",
		"                              so a `jq -r … > file` round trip matches byte for byte. Blank is refused.",
		"  e.g. bp task get <id> -o json | jq -r '.doc.content.acceptance_criteria[N].criterion' > crit.txt",
		"       $EDITOR amended.txt",
		"       bp task stamp <id> <worker> <epoch> --criterion N --amend --criterion-text-file crit.txt \\",
		"         " + amendedCriterionFileFlag + " amended.txt --note \"<why>\" --observed-rev <rev>   (--observed-rev on a sealed row)",
		"  Do NOT pass " + amendedCriterionFlag + " \"…\" inline: criterion wording is MARKDOWN, and a backticked span inside a",
		"  double-quoted shell argument is COMMAND SUBSTITUTION — the shell runs it and the criterion is rewritten to its output.",
	}
}
