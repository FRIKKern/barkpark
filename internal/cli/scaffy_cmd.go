package cli

// scaffy_cmd.go is `bp scaffy` — the CLI surface over internal/scaffy, the one
// implementation of the pinned Scaffy v2 grammar (charter D27/D31). Two verbs:
//
//	bp scaffy validate <path>...       parse + lint, compiler-style findings
//	bp scaffy fmt [--check] <path>...  canonical structural form, in place
//
// PURE LOCAL like make/style: no network, no auth, no manifest — this file
// never touches the server. All parsing/linting/formatting lives in
// internal/scaffy (Parse/Lint/ValidateFile/Format); this file only walks
// paths, renders findings, and maps results onto the stable exit-code scheme:
//
//	0  clean (no findings / already canonical)
//	2  usage error (exitUsage, via usageErrf)
//	4  missing path / unreadable or unwritable file (exitNotFound)
//	5  validation findings, or fmt --check non-fixpoint (exitValidation)
//
// -o json|yaml emits a machine envelope ({ok, files, findings[]} for
// validate; {ok, mode, files, changed[]} for fmt) per the doctor exemplar:
// the exit code follows the FINDINGS, never the output shape.

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// runScaffy dispatches the scaffy verbs. args is everything after the noun
// (rest[1:] in Execute). Mirrors the mcp/context two-verb builtin pattern:
// help/empty-verb prints usage and exits 0; an unknown verb is exit 2.
func runScaffy(out *writer, g globals, args []string) int {
	verb := ""
	if len(args) > 0 {
		verb = args[0]
	}
	switch verb {
	case "validate":
		if g.help {
			printScaffyValidateHelp(out)
			return exitOK
		}
		return runScaffyValidate(out, args[1:])
	case "fmt":
		if g.help {
			printScaffyFmtHelp(out)
			return exitOK
		}
		return runScaffyFmt(out, args[1:])
	case "":
		if g.help {
			printScaffyHelp(out)
			return exitOK
		}
		// A bare `bp scaffy` with no verb is incomplete usage (the `bp <noun>`
		// convention in Execute's manifest path); usageErrf keeps -o json parity.
		return usageErrf(out, func() { printScaffyHelp(out) }, "scaffy needs a verb: validate or fmt")
	default:
		return usageErrf(out, func() { printScaffyHelp(out) }, "unknown command %q %q", "scaffy", verb)
	}
}

// runScaffyValidate is `bp scaffy validate <path>...`. Each path is a .scaffy
// file or a directory (a directory validates its *.scaffy files, sorted,
// non-recursive). Findings print compiler-style "file:line: RULE-ID message"
// followed by an indented fix-hint line; the exit code is 5 on ANY finding
// (D27), 0 when every file is clean.
func runScaffyValidate(out *writer, args []string) int {
	paths, badFlag := splitScaffyArgs(args, nil)
	if badFlag != "" {
		return usageErrf(out, func() { printScaffyValidateHelp(out) }, "unknown validate flag %q", badFlag)
	}
	if len(paths) == 0 {
		return usageErrf(out, func() { printScaffyValidateHelp(out) }, "scaffy validate needs at least one <path>")
	}

	files, err := collectScaffyFiles(paths)
	if err != nil {
		return useError(out, "io", "scaffy validate: "+err.Error(), exitNotFound)
	}

	var findings []scaffy.Finding
	for _, f := range files {
		src, rerr := os.ReadFile(f)
		if rerr != nil {
			return useError(out, "io", "scaffy validate: "+rerr.Error(), exitNotFound)
		}
		findings = append(findings, scaffy.ValidateFile(f, src)...)
	}

	if out.machineOut() {
		out.emitStructured(map[string]any{
			"ok":       len(findings) == 0,
			"files":    len(files),
			"findings": scaffyFindingsJSON(findings),
		})
	} else {
		for _, f := range findings {
			out.outf("%s", f.String())
			if f.Hint != "" {
				out.outf("  hint: %s", f.Hint)
			}
		}
		if len(findings) == 0 {
			out.outf("clean: %d file(s), 0 findings", len(files))
		} else {
			out.outf("%d finding(s) across %d file(s)", len(findings), len(files))
		}
	}

	if len(findings) > 0 {
		return exitValidation
	}
	return exitOK
}

// runScaffyFmt is `bp scaffy fmt [--check] <path>...`. Without --check it
// rewrites each non-canonical file in place (exit 0); with --check it lists
// the non-fixpoint files, writes NOTHING, and exits 5 when any exist (D27).
// A file fmt cannot canonicalize (unclosed fence — the payload boundary is
// undecidable) is a validation-level red, never a rewrite.
func runScaffyFmt(out *writer, args []string) int {
	check := false
	paths, badFlag := splitScaffyArgs(args, func(a string) bool {
		if a == "--check" {
			check = true
			return true
		}
		return false
	})
	if badFlag != "" {
		return usageErrf(out, func() { printScaffyFmtHelp(out) }, "unknown fmt flag %q", badFlag)
	}
	if len(paths) == 0 {
		return usageErrf(out, func() { printScaffyFmtHelp(out) }, "scaffy fmt needs at least one <path>")
	}

	files, err := collectScaffyFiles(paths)
	if err != nil {
		return useError(out, "io", "scaffy fmt: "+err.Error(), exitNotFound)
	}

	var changed []string
	for _, f := range files {
		src, rerr := os.ReadFile(f)
		if rerr != nil {
			return useError(out, "io", "scaffy fmt: "+rerr.Error(), exitNotFound)
		}
		formatted, ferr := scaffy.Format(src)
		if ferr != nil {
			msg := fmt.Sprintf("scaffy fmt: %s: %v", f, ferr)
			if !renderErrorEnvelope(out, "validation", msg, "", "run `bp scaffy validate` for the full findings") {
				out.userErr("%s", msg)
			}
			return exitValidation
		}
		if bytes.Equal(formatted, src) {
			continue
		}
		changed = append(changed, f)
		if check {
			continue // --check never writes
		}
		mode := fs.FileMode(0o644)
		if info, serr := os.Stat(f); serr == nil {
			mode = info.Mode().Perm()
		}
		if werr := os.WriteFile(f, formatted, mode); werr != nil {
			return useError(out, "io", "scaffy fmt: "+werr.Error(), exitNotFound)
		}
	}

	if out.machineOut() {
		fmtMode := "write"
		if check {
			fmtMode = "check"
		}
		changedJSON := make([]any, 0, len(changed))
		for _, f := range changed {
			changedJSON = append(changedJSON, f)
		}
		out.emitStructured(map[string]any{
			"ok":      !check || len(changed) == 0,
			"mode":    fmtMode,
			"files":   len(files),
			"changed": changedJSON,
		})
	} else {
		for _, f := range changed {
			out.outf("%s", f)
		}
		switch {
		case check && len(changed) > 0:
			out.outf("%d file(s) not canonical (run `bp scaffy fmt` to rewrite)", len(changed))
		case check:
			out.outf("canonical: %d file(s) already a fixpoint", len(files))
		case len(changed) > 0:
			out.outf("rewrote %d of %d file(s)", len(changed), len(files))
		default:
			out.outf("canonical: %d file(s) already a fixpoint", len(files))
		}
	}

	if check && len(changed) > 0 {
		return exitValidation
	}
	return exitOK
}

// splitScaffyArgs separates positional paths from flags. local (when non-nil)
// claims verb-local flags; any other dash token is returned as badFlag so the
// caller can raise the usage error with its own help.
func splitScaffyArgs(args []string, local func(string) bool) (paths []string, badFlag string) {
	for _, a := range args {
		if local != nil && local(a) {
			continue
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			return nil, a
		}
		paths = append(paths, a)
	}
	return paths, ""
}

// collectScaffyFiles expands each arg: a directory contributes its *.scaffy
// files (sorted, non-recursive); a plain file passes through as-is. A path
// that does not exist, or a path set that yields zero files, is an error —
// fail-loud per the scaffy doctrine, never a vacuous green.
func collectScaffyFiles(paths []string) ([]string, error) {
	var files []string
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		if info.IsDir() {
			matches, gerr := filepath.Glob(filepath.Join(p, "*.scaffy"))
			if gerr != nil {
				return nil, fmt.Errorf("%s: %v", p, gerr)
			}
			sort.Strings(matches)
			files = append(files, matches...)
			continue
		}
		files = append(files, p)
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no .scaffy files found under the given path(s)")
	}
	return files, nil
}

// scaffyFindingsJSON shapes findings for the machine envelope. Hint is
// omitted when empty so the JSON mirrors the human view's optional hint line.
func scaffyFindingsJSON(findings []scaffy.Finding) []any {
	arr := make([]any, 0, len(findings))
	for _, f := range findings {
		m := map[string]any{
			"file":    f.File,
			"line":    f.Line,
			"rule":    f.Rule,
			"message": f.Msg,
		}
		if f.Hint != "" {
			m["hint"] = f.Hint
		}
		arr = append(arr, m)
	}
	return arr
}

func printScaffyHelp(out *writer) {
	out.outf(`usage: bp scaffy <validate|fmt> [flags] <path>...

Validate and format .scaffy command files (the pinned Scaffy v2 grammar,
internal/scaffy). Pure local: no server, no auth, no manifest.

commands:
  validate <path>...        parse + lint each file; a directory validates its
                            *.scaffy files. Findings print compiler-style as
                            file:line: RULE-ID message, each with a fix hint.
  fmt [--check] <path>...   rewrite files to canonical structural form in
                            place; --check lists non-fixpoint files and
                            writes nothing. Comment prose and payload bytes
                            are never touched.

examples:
  bp scaffy validate scaffy/commands/             # lint the whole corpus
  bp scaffy validate add-plugin.scaffy -o json    # machine envelope
  bp scaffy fmt --check scaffy/commands/          # CI fixpoint gate
  bp scaffy fmt add-plugin.scaffy                 # canonicalize in place

exit codes:
  0  clean — no findings / already canonical
  2  usage error
  4  missing path / unreadable or unwritable file
  5  validation findings (validate) or non-fixpoint files (fmt --check)`)
}

func printScaffyValidateHelp(out *writer) {
	out.outf(`usage: bp scaffy validate <path>...

Parse + lint .scaffy command files against the frozen rule catalog (E-xxx
error / W-xxx warn / P-xxx parse — see internal/scaffy doc.go). Each path is
a .scaffy file or a directory (validates its *.scaffy files). Pure text-level
(D27): no repo access, no anchor checks. Every finding prints as

  file:line: RULE-ID message
    hint: the likely fix

-o json|-o yaml emits {ok, files, findings:[{file,line,rule,message,hint}]}.

examples:
  bp scaffy validate scaffy/commands/
  bp scaffy validate add-plugin.scaffy add-migration.scaffy
  bp scaffy validate scaffy/commands/ -o json | jq '.findings'

exit codes:
  0  every file clean
  2  usage error
  4  missing path / unreadable file
  5  one or more findings`)
}

func printScaffyFmtHelp(out *writer) {
	out.outf(`usage: bp scaffy fmt [--check] <path>...

Rewrite .scaffy files to canonical structural form in place: keyword lines
single-spaced and flush-left, fence lines normalized. Comment prose and
payload bytes are NEVER rewritten, and fmt is idempotent — the committed
corpus is a fixpoint (D27).

flags:
  --check   list files that are not a fixpoint and write nothing — the CI
            gate form; exits 5 when any file would change

-o json|-o yaml emits {ok, mode, files, changed:[...]}.

examples:
  bp scaffy fmt scaffy/commands/
  bp scaffy fmt --check scaffy/commands/

exit codes:
  0  all files already canonical / rewritten successfully
  2  usage error
  4  missing path / unreadable or unwritable file
  5  --check found non-fixpoint file(s), or a file fmt cannot canonicalize`)
}
