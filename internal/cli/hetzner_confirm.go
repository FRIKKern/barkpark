package cli

// hetzner_confirm.go is the ONE destructive-op confirmation gate for the
// `bp cloud hetzner …` surface (charter decision 5: one destructive-op grammar,
// both surfaces, three tiers). Every destroy-tier verb — the delete/rm and
// rebuild sites across hetzner_*.go — funnels through hzConfirmDestroy right
// after the resource is resolved and immediately before the API call, so the
// prompt always names the real resource that is about to die.
//
// The contract:
//   - --yes/-y skips the prompt (scripts that WANT the delete say so).
//   - A non-TTY stdin skips the prompt (pipes, CI, cron, every existing test
//     keep working unchanged — the flag-less script path is a hard guarantee).
//   - Interactive: a red consequence line, then the user must type the exact
//     resource name. Anything else aborts with a non-zero exit and NOTHING is
//     called on the API.

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/mattn/go-isatty"
)

// hzStdin is the confirm prompt's input. A package var (the newHetznerClient
// seam idiom) so tests can drive the prompt with an in-memory reader.
var hzStdin io.Reader = os.Stdin

// hzStdinIsTTY reports whether the confirm reader is an interactive terminal:
// only a real *os.File that isatty says is a terminal counts — any other
// reader (a pipe, a strings.Reader, /dev/null under `go test`) is non-TTY and
// passes through. A package var so tests can force the interactive path.
var hzStdinIsTTY = func(r io.Reader) bool {
	f, ok := r.(*os.File)
	return ok && isatty.IsTerminal(f.Fd())
}

// hzConfirmDestroy gates one destroy-tier operation. It returns nil (proceed)
// when yes is set or stdin is not a TTY; otherwise it prints the consequence
// line to stderr (red when color is on — stdout stays machine-clean) and
// requires the exact resource name back. Any other input — a mismatch, an
// empty line, EOF — returns an error and the caller must abort without
// touching the API.
func hzConfirmDestroy(stdin io.Reader, out *writer, kind, name string, yes bool) error {
	if yes {
		return nil
	}
	if !hzStdinIsTTY(stdin) {
		return nil
	}
	prompt := fmt.Sprintf("This permanently deletes %s %q. Type the name to confirm:", kind, name)
	if out.color {
		prompt = "\033[31m" + prompt + "\033[0m"
	}
	fmt.Fprintf(out.stderr, "%s ", prompt)
	line, err := bufio.NewReader(stdin).ReadString('\n')
	if err != nil && line == "" {
		return fmt.Errorf("aborted — could not read confirmation: %v", err)
	}
	got := strings.TrimRight(line, "\r\n")
	switch {
	case got == name:
		return nil
	case got == "":
		return fmt.Errorf("aborted — nothing entered (type %q to confirm, or pass --yes to skip the prompt)", name)
	default:
		return fmt.Errorf("aborted — %q does not match %s %q (pass --yes to skip the prompt)", got, kind, name)
	}
}

// hzConfirmAbort renders a hzConfirmDestroy refusal through the shared error
// envelope. exitGeneric, not exitUsage: the command line was fine — the human
// declined.
func hzConfirmAbort(out *writer, err error) int {
	return useError(out, "aborted", err.Error(), exitGeneric)
}

// hzOneTargetYes parses a destroy-tier tail that must be exactly `<id|name>`
// plus the shared --yes/-y prompt skip (the hzOneTarget shape, destroy
// edition).
func hzOneTargetYes(out *writer, args []string, usage string) (target string, yes bool, ok bool) {
	a, err := parseHzArgs(args, nil, []string{"yes"}, usage)
	if err != nil {
		useError(out, "usage", err.Error(), exitUsage)
		return "", false, false
	}
	if len(a.pos) != 1 {
		useError(out, "usage", "want exactly one <id|name> (usage: "+usage+")", exitUsage)
		return "", false, false
	}
	return a.pos[0], a.bools["yes"], true
}
