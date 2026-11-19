package cli

// The prose scan and the task-create parser must agree on which flags take the
// next argument as their value (task-4b3183fca9ea2708). They disagreed: the
// scan knew only --title and --description, so after `--set --` it read "--"
// as the end of the flags and left a --title-file after it unread, while the
// parser took "--" as --set's value.

import (
	"bytes"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Every flag `bp task create --help` names, asked of the parser itself: a flag
// it answers "needs a value" for takes a value. Not a list kept in this test,
// so a flag added to the parser and its help is walked too.
func TestTaskCreateScanAndParserAgreeOnEveryValueFlag(t *testing.T) {
	var so, se bytes.Buffer
	printTaskCreateHelp(&writer{stdout: &so, stderr: &se})
	// The help's flag lines (a flag at the start of an indented line), not
	// its prose, which also names other commands' flags (`--perspective raw`).
	var flags []string
	for _, m := range regexp.MustCompile(`(?m)^\s+(--[a-z][a-z-]*)`).FindAllStringSubmatch(so.String()+se.String(), -1) {
		flags = append(flags, m[1])
	}
	flags = slices.Compact(slices.Sorted(slices.Values(flags)))

	p := writeSpecimen(t, "text.txt", "A text from a file")
	valueFlags := 0
	for _, f := range flags {
		if strings.HasSuffix(f, "-file") {
			continue // the prose door's own flags
		}
		_, _, err := parseTaskCreateArgs([]string{f})
		if err != nil && strings.Contains(err.Error(), "unknown flag") {
			// A flag dropped from taskCreateValueFlags lands here.
			t.Errorf("%s: `task create --help` lists it, but the parser calls it unknown", f)
			continue
		}
		parserTakesValue := err != nil && strings.Contains(err.Error(), "needs a value")

		// --title with --title-file is the "two sources" refusal, so --title
		// reads the description's file instead.
		fileFlag, read := "--title-file", "--title=A text from a file"
		if f == "--title" {
			fileFlag, read = "--description-file", "--description=A text from a file"
		}
		got, rerr := resolveTaskCreateProse([]string{"T", f, "--", fileFlag, p}, func(string, ...any) {})
		if rerr != nil {
			t.Fatalf("%s: resolveTaskCreateProse: %v", f, rerr)
		}
		scanTakesValue := slices.Contains(got, read)

		if parserTakesValue != scanTakesValue {
			t.Errorf("%s: the parser takes a value = %v, the prose scan = %v (resolved %q)",
				f, parserTakesValue, scanTakesValue, got)
		}
		if parserTakesValue {
			valueFlags++
		}
	}
	// --title and --description at least: a walk that found no value flag would
	// pass on any tree.
	if valueFlags < 2 {
		t.Fatalf("the walk found %d value flags in %v", valueFlags, flags)
	}
}

// The command itself, not only its two passes: `bp task create T
// --reopen-trigger -- --description-file f` files the file's text as the
// description, so the command's prose pass is the one that reads the list.
func TestTaskCreateReadsADescriptionFileAfterAValueFlagDashDash(t *testing.T) {
	p := writeSpecimen(t, "description.txt", "A description from a file")
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "json"}
	ctx := manifest.Context{Server: "http://127.0.0.1:1", Dataset: "production", Token: "tok"}
	code := runTaskCreate(w, globals{dryRun: true}, ctx, []string{"T", "--reopen-trigger", "--", "--description-file", p})
	if code != exitOK || !strings.Contains(so.String()+se.String(), "A description from a file") {
		t.Fatalf("exit = %d, want 0 and the file's text in the request\nstdout=%s\nstderr=%s", code, so.String(), se.String())
	}
}
