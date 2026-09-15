package cli

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ─── THE NON-EVALUATING PROSE DOOR (--description-file / --title-file) ──────
//
// `bp task stamp` already forces criterion wording through a FILE
// (`--criterion-text-file`, tasks_stamp_criterion_file.go, shipped #16646).
// People internalised that as a rule about CRITERION TEXT. IT IS A RULE ABOUT
// SHELL QUOTING, and `--description` and `--title` are exposed identically and
// were NOT forced — while being long and quote-heavy for exactly the same
// reasons criterion wording is: descriptions quote commands, paths and output
// constantly.
//
// Measured, twice in one night, hours apart:
//
//   - lead-cli-r18 passed an inline `--description` carrying a backticked
//     example command. zsh EXECUTED it; `bp task ready --limit 5` ran and its
//     whole JSON page was substituted in. 288,773 bytes were stored and
//     PUBLISHED on task-68e0f741e523e461.
//   - lead-api, same flag, smaller blast radius: zsh printed
//     `command not found: post` / `command not found: with` and the row stored
//     "a second  route" with two words silently deleted.
//
// ── WHY THE OBVIOUS REMEDY IS UNSATISFIABLE BY CONSTRUCTION ────────────────
//
// READ THIS BEFORE FILING OR BUILDING A CONTENT-INSPECTION GUARD:
//
//	bp CANNOT DETECT A BACKTICK IN AN INLINE ARGUMENT.
//
// The substitution happens in the SHELL, in the caller's process, BEFORE bp is
// executed. By the time bp reads argv the backticks are GONE — they have
// already been replaced by the output of the command they delimited, and no
// trace of them survives into the bytes bp receives. A requirement phrased
// "bp refuses an inline --description containing a backtick" is therefore
// UNSATISFIABLE: there is nothing for bp to look at. The same is true of `$`
// expansions, `$(...)`, and the word-deletion a failed substitution leaves
// behind — the mangling is COMPLETE before bp's first instruction runs.
//
// bp reported success CORRECTLY in both incidents. The payload was already
// wrong before bp saw it, so nothing could have refused it on content grounds.
//
// THIS IS THE REASON THE FILE-BASED FLAG IS THE FIX rather than validation:
// the only way to make the bytes survive is to keep them out of argv entirely.
// `--description-file <path>` (and `--title-file <path>`; `-` reads stdin) is
// read with os.ReadFile — no shell, no expansion, no interpretation — so
// backticks, `$`, quotes and newlines ride through verbatim. The inline flags
// are unchanged and still work; this is a second door beside them, exactly as
// `--criterion-text-file` is a second door beside `--criterion-text`.
//
// What bp CAN do, and does below, is notice an IMPLAUSIBLE PAYLOAD after the
// fact — see proseCeilings for why the numbers are what they are.

const proseTextSourceCode = "prose_text_source"

// proseStdin is os.Stdin, indirected so the `-` arm is testable without a real
// pipe (the house pattern — see stampStdin, destroyStdin, hookStdin).
var proseStdin io.Reader = os.Stdin

// proseField is one prose flag and its non-evaluating file sibling, plus the
// two population-derived sizes that decide whether a payload is plausible.
type proseField struct {
	// name is the field, without dashes: "description", "title".
	name string
	// warnBytes is the size above which a value is LOUD but still written.
	warnBytes int
	// refuseBytes is the size above which an INLINE value is refused. A value
	// that came from a file is never refused on size — the file IS the
	// documented way past the ceiling.
	refuseBytes int
	// warnWhy / refuseWhy state where the number came from, in the message.
	warnWhy   string
	refuseWhy string
}

func (p proseField) inlineFlag() string { return "--" + p.name }
func (p proseField) fileFlag() string   { return "--" + p.name + "-file" }

// proseCeilings — THE LIMITS ARE DERIVED FROM THE REAL POPULATION, NOT PICKED.
//
// Measured 2026-09-15 against the live ledger with `bp task ls --all -o json`
// (9,315 rows returned with no page cap in play — `--all` walks, and the
// per-page `has_more` was exhausted, so this is a census and not a page that
// happened to fill a --limit). Byte lengths via `utf8bytelength`.
//
//	content.description  9,298 rows carry a string (17 carry a non-string);
//	                     every one of them is non-empty.
//	    p50    1,462 B
//	    p75    2,749 B
//	    p90    4,462 B
//	    p95    5,734 B
//	    p99    9,017 B
//	    p99.5 11,199 B
//	    p99.9 18,564 B
//	    max   72,311 B      (143 rows > 8 KiB, 14 > 16 KiB, 3 > 32 KiB, 1 > 64 KiB)
//
//	title                9,315 rows.
//	    p50      103 B
//	    p90      145 B
//	    p99      198 B
//	    p99.9    237 B
//	    max      255 B
//
// The incident payload was 288,773 B — 3.99x the LARGEST legitimate
// description in the entire store. (It is not in the numbers above: that row,
// task-68e0f741e523e461, has since been repaired and now measures 2,423 B.)
//
// So the two numbers are:
//
//	REFUSE at 2x the observed population maximum. description 2 x 72,311 =
//	144,622 B; title 2 x 255 = 510 B. This admits EVERY value the live store
//	actually holds with 100% headroom — it cannot refuse a legitimate field
//	that exists today — while still refusing the observed incident at 1.996x
//	the limit. It is deliberately not 128 KiB, not 100,000, and not any other
//	round number: a round number carries no argument, and the first person to
//	hit it has no way to tell whether it was measured or guessed.
//
//	WARN at p99.9 — description 18,564 B, title 237 B. Above that a value is
//	larger than 999 of every 1,000 rows in the store, which is worth one loud
//	stderr line and is NOT worth refusing: 9 real descriptions sit above it.
//
// The ceiling binds the INLINE flag only. A genuinely long field has a
// documented way past it and the message names it: put the prose in a file and
// pass --description-file. That is not a loophole bolted on to make the limit
// tolerable — it is the same door this whole file exists to add, and it is the
// only channel where the bytes are known to be the ones the author wrote.
func proseCeilings() []proseField {
	return []proseField{
		{
			name:        "description",
			warnBytes:   18564,
			refuseBytes: 144622,
			warnWhy:     "p99.9 of the 9,298 string descriptions on the live ledger (measured 2026-09-15)",
			refuseWhy:   "2x the largest description in that population (72,311 B)",
		},
		{
			name:        "title",
			warnBytes:   237,
			refuseBytes: 510,
			warnWhy:     "p99.9 of the 9,315 task titles on the live ledger (measured 2026-09-15)",
			refuseWhy:   "2x the longest title in that population (255 B)",
		},
	}
}

// proseFieldByFileFlag indexes proseCeilings by its file flag spelling.
func proseFieldByFileFlag(flag string) (proseField, bool) {
	for _, p := range proseCeilings() {
		if p.fileFlag() == flag {
			return p, true
		}
	}
	return proseField{}, false
}

// proseFieldByInlineFlag indexes proseCeilings by its inline flag spelling.
func proseFieldByInlineFlag(flag string) (proseField, bool) {
	for _, p := range proseCeilings() {
		if p.inlineFlag() == flag {
			return p, true
		}
	}
	return proseField{}, false
}

// resolveProseTextFiles rewrites a command tail, replacing
// `--description-file <path>` with the INLINE spelling
// `--description=<the file's bytes>` (and the same for `--title-file`), so
// every stage after this line — the command's own parser, splitArgs, the body
// builder, the POST — sees the ordinary flag and can never drift from it.
//
// The inline `--flag=value` spelling is deliberate and is the same choice
// resolveCriterionTextFile makes: splitArgs refuses a space-form value that is
// flag-shaped, and prose may legitimately begin with `-` (a dashed list item).
// Inline has no such hazard.
//
// `-` as the path reads stdin. Exactly ONE trailing newline is stripped (with a
// preceding CR), because the obvious way to produce the file is a `> file`
// redirect or a heredoc, both of which append one.
//
// It ALSO screens every prose value that survives — whether it came from a file
// or was typed inline — against the population-derived sizes in proseCeilings.
// An oversize INLINE value is refused; an oversize value from a FILE is warned
// about and written, because the file is the documented way past the ceiling.
//
// `only` narrows which fields are in scope: a manifest command that declares
// `--description` but no `--title` must not grow a `--title-file`. Pass nil for
// "every field in proseCeilings" (the built-in `task create` case).
//
// Every failure returns an error and NOTHING is forwarded: a write that cannot
// read its own prose must not fall back to sending a truncated field.
func resolveProseTextFiles(tail []string, only map[string]bool, warn func(string, ...any)) ([]string, error) {
	inScope := func(name string) bool { return only == nil || only[name] }

	out := make([]string, 0, len(tail))
	fromFile := map[string]bool{}
	seenInline := map[string]bool{}

	for i := 0; i < len(tail); i++ {
		name, val, hasInline := splitFlagToken(tail[i])

		if p, ok := proseFieldByInlineFlag(name); ok && inScope(p.name) {
			seenInline[p.name] = true
			out = append(out, tail[i])
			continue
		}

		p, ok := proseFieldByFileFlag(name)
		if !ok || !inScope(p.name) {
			out = append(out, tail[i])
			continue
		}

		path := val
		if !hasInline {
			if i+1 >= len(tail) || strings.HasPrefix(tail[i+1], "--") {
				return nil, fmt.Errorf("%s needs a path (or `-` to read the %s from stdin)", p.fileFlag(), p.name)
			}
			path = tail[i+1]
			i++
		}
		if strings.TrimSpace(path) == "" {
			return nil, fmt.Errorf("%s was given an empty path", p.fileFlag())
		}
		if fromFile[p.name] {
			return nil, fmt.Errorf("%s was passed twice — one %s, one source", p.fileFlag(), p.name)
		}
		fromFile[p.name] = true

		text, err := readProseText(p, path)
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(text) == "" {
			return nil, fmt.Errorf("%s %s is empty — an empty %s is not a %s", p.fileFlag(), path, p.name, p.name)
		}
		out = append(out, p.inlineFlag()+"="+text)
	}

	// Both doors at once cannot be resolved SILENTLY: picking either one would
	// send prose the operator did not mean to send.
	for _, p := range proseCeilings() {
		if fromFile[p.name] && seenInline[p.name] {
			return nil, fmt.Errorf("pass EITHER %s or %s, not both — they are two sources for the same field and there is no safe way to pick between them (%s is the one that is never evaluated by a shell)",
				p.inlineFlag(), p.fileFlag(), p.fileFlag())
		}
	}

	// THE PLAUSIBILITY SCREEN, on the FINISHED tail, so it covers both doors.
	if err := screenProseSizes(out, fromFile, only, warn); err != nil {
		return nil, err
	}
	return out, nil
}

// screenProseSizes is the "an implausible payload is NOTICED, not stored
// silently" half. It reads the resolved tail, so the value it measures is the
// value that will be sent.
func screenProseSizes(tail []string, fromFile map[string]bool, only map[string]bool, warn func(string, ...any)) error {
	inScope := func(name string) bool { return only == nil || only[name] }

	for i := 0; i < len(tail); i++ {
		name, val, hasInline := splitFlagToken(tail[i])
		p, ok := proseFieldByInlineFlag(name)
		if !ok || !inScope(p.name) {
			continue
		}
		if !hasInline {
			if i+1 >= len(tail) {
				continue
			}
			val = tail[i+1]
			i++
		}
		n := len(val)
		if n > p.refuseBytes && !fromFile[p.name] {
			return fmt.Errorf("%s is %d bytes — refusing: the limit for an INLINE %s is %d bytes (%s). %s"+
				"\n  A value this far outside the population is nearly always a SHELL ACCIDENT, not prose: a backtick or $(…) in the argument"+
				"\n  was executed by your shell and its OUTPUT was substituted in before bp ran. bp cannot see that happen — argv carries only"+
				"\n  the result — which is why the fix is to keep the bytes out of argv:"+
				"\n      %s <path>   (or `-` for stdin) — read verbatim, never evaluated, and NOT subject to this limit."+
				"\n  That is also the documented way past the limit for a genuinely long %s.",
				p.inlineFlag(), n, p.name, p.refuseBytes, p.refuseWhy, proseShellMarks(val), p.fileFlag(), p.name)
		}
		if n > p.warnBytes && warn != nil {
			where := "inline"
			if fromFile[p.name] {
				where = "from " + p.fileFlag()
			}
			warn("warning: %s (%s) is %d bytes, above %d — %s. Writing it anyway; if you did not mean to, check for a `backtick` or $(…) your shell substituted before bp ran.",
				p.inlineFlag(), where, n, p.warnBytes, p.warnWhy)
		}
	}
	return nil
}

// proseShellMarks names substitution-capable characters SURVIVING in the value.
// It is a hint, never a verdict — and the comment at the top of this file is
// why: the dangerous characters are the ones the shell ALREADY CONSUMED, and
// those leave no trace at all. So this sentence is written to be useful when it
// fires and silent when it does not, never to be read as a detector.
func proseShellMarks(s string) string {
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
	return "(what reached bp still carries " + strings.Join(marks, " and ") + " — but anything your shell ATE left no trace, so this is a hint and never a verdict.) "
}

// readProseText reads a prose field from a file, or from stdin when the path is
// `-`, and strips exactly one trailing newline. No shell, no expansion, no
// interpretation of any kind — the bytes on disk are the bytes that ride the
// request.
func readProseText(p proseField, path string) (string, error) {
	var (
		raw []byte
		err error
	)
	if path == "-" {
		raw, err = io.ReadAll(proseStdin)
		if err != nil {
			return "", fmt.Errorf("reading the %s from stdin: %w", p.name, err)
		}
	} else {
		raw, err = os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("reading the %s from %s: %w", p.name, path, err)
		}
	}
	return trimOneTrailingNewline(string(raw)), nil
}

// proseFileScopeForCommand reports which prose fields a MANIFEST command is
// allowed to grow a `-file` sibling for: exactly the ones it already declares
// as a non-bool flag. A command that does not declare `--description` must not
// accept `--description-file`, or the refusal for a typo becomes "unknown flag
// --description" from the server instead of "unknown flag" from bp.
//
// It also refuses to shadow: if the server ever declares `--description-file`
// itself, the client-side door stands down for that command so there is one
// implementation and not two.
func proseFileScopeForCommand(cmd manifest.Command) map[string]bool {
	scope := map[string]bool{}
	for _, p := range proseCeilings() {
		if commandFlagType(cmd, p.name) == "" {
			continue
		}
		if commandFlagType(cmd, p.name+"-file") != "" {
			continue // server-declared; do not shadow it
		}
		scope[p.name] = true
	}
	if len(scope) == 0 {
		return nil
	}
	return scope
}

// proseFileHelpLines is the `--help` block for the client-side door. The
// manifest cannot declare these flags (they are resolved and consumed entirely
// in this process, exactly like `--criterion-text-file` and `task ls --match`),
// and a flag nobody can discover is a flag nobody uses — which here means the
// shell-evaluating recipe stays the only one anybody knows.
func proseFileHelpLines(scope map[string]bool) []string {
	var names []string
	for _, p := range proseCeilings() {
		if scope == nil || scope[p.name] {
			names = append(names, p.name)
		}
	}
	if len(names) == 0 {
		return nil
	}
	sort.Strings(names)

	lines := []string{"prose from a file (client-side, never evaluated by a shell):"}
	for _, n := range names {
		var p proseField
		for _, c := range proseCeilings() {
			if c.name == n {
				p = c
			}
		}
		lines = append(lines,
			fmt.Sprintf("  %-22s read the %s from a FILE instead of typing it as a shell argument;", p.fileFlag()+" <path>", p.name),
			fmt.Sprintf("  %-22s `-` reads stdin. Backticks, $, quotes and newlines ride through verbatim.", ""),
			fmt.Sprintf("  %-22s ONE trailing newline is stripped, so a `> file` redirect works as-is.", ""),
			fmt.Sprintf("  %-22s Inline %s is capped at %d bytes (%s); a value from a file is not.", "", p.inlineFlag(), p.refuseBytes, p.refuseWhy),
		)
	}
	lines = append(lines,
		"  WHY: inside a DOUBLE-QUOTED shell argument a backtick is COMMAND SUBSTITUTION and $NAME is a variable, so",
		"  bash/zsh EXECUTE what you typed and bp receives the OUTPUT instead. bp CANNOT detect this — the substitution",
		"  happens before bp is executed and argv carries only the result — so a file is the fix, not validation.",
		"  (Measured: 288,773 bytes of substituted JSON stored and published on one row; two words silently deleted on another.)",
	)
	return lines
}
