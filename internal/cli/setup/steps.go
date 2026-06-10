package setup

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// step is one ordered action in an executor's plan. Cmd is the shell-equivalent
// rendered for the dry-run (and, for outbound/destructive steps, the exact thing
// that runs). Argv is the resolved argv a real run execs; when nil the step is
// pure narration (a "wait for X" or "verify Y" that the executor handles inline
// rather than shelling out). EnvLine, when set, is prefixed to the rendered Cmd
// so the operator sees the env that rides with it (e.g. DOMAIN=… PHX_SCHEME=…).
type step struct {
	Title   string   // short human label
	Cmd     string   // rendered command line (for display)
	Argv    []string // resolved argv for a real run; nil = narration-only
	Dir     string   // working dir for the argv (empty = inherit)
	EnvLine string   // env prefix shown before Cmd in the rendered plan
	Stdin   string   // optional path/contents fed on stdin (display hint only)

	// Env is the REAL KEY=VALUE pairs applied to the child process on a real
	// run (appended to os.Environ()). It is deliberately separate from EnvLine:
	// EnvLine is the display form and may redact secrets (e.g. the generated
	// BARKPARK_SEED_ADMIN_TOKEN shows as ****), Env carries the live values.
	Env []string
}

// rendered returns the display string for a step: "$ ENV cmd" or just the
// narration title when there is no command.
func (s step) rendered() string {
	if s.Cmd == "" {
		return s.Title
	}
	if s.EnvLine != "" {
		return "$ " + s.EnvLine + " " + s.Cmd
	}
	return "$ " + s.Cmd
}

// printPlan writes an ordered, numbered plan to w under a heading. It is the
// single dry-run renderer shared by Local/Deploy/Provision so every target's
// "here is what I would do" block looks identical.
func printPlan(w io.Writer, heading string, steps []step) {
	fmt.Fprintln(w, heading)
	for i, s := range steps {
		fmt.Fprintf(w, "  %2d. %s\n", i+1, s.Title)
		if s.Cmd != "" {
			fmt.Fprintf(w, "      %s\n", s.rendered())
		}
		if s.Dir != "" {
			fmt.Fprintf(w, "         (in %s)\n", s.Dir)
		}
	}
}

// runStep executes one step's argv, streaming stdout+stderr to w with live
// progress. A nil Argv is a no-op (narration-only steps are handled by the
// executor itself). The step's Dir scopes the working directory.
func runStep(ctx context.Context, w io.Writer, s step) error {
	if len(s.Argv) == 0 {
		return nil
	}
	fmt.Fprintf(w, ">> %s\n", s.Title)
	fmt.Fprintf(w, "   %s\n", s.rendered())
	cmd := exec.CommandContext(ctx, s.Argv[0], s.Argv[1:]...)
	if s.Dir != "" {
		cmd.Dir = s.Dir
	}
	if len(s.Env) > 0 {
		cmd.Env = append(os.Environ(), s.Env...)
	}
	cmd.Stdout = w
	cmd.Stderr = w
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("step %q failed: %w", s.Title, err)
	}
	return nil
}

// runStepWithStdin is runStep with a stdin reader wired to the child process —
// used by the deploy executor to pipe deploy.sh into `ssh … bash -s`. Output is
// streamed live to w.
func runStepWithStdin(ctx context.Context, w io.Writer, s step, stdin io.Reader) error {
	if len(s.Argv) == 0 {
		return nil
	}
	cmd := exec.CommandContext(ctx, s.Argv[0], s.Argv[1:]...)
	if s.Dir != "" {
		cmd.Dir = s.Dir
	}
	if len(s.Env) > 0 {
		cmd.Env = append(os.Environ(), s.Env...)
	}
	cmd.Stdin = stdin
	cmd.Stdout = w
	cmd.Stderr = w
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("step %q failed: %w", s.Title, err)
	}
	return nil
}

// lookExec reports whether a binary is on PATH. Executors use it for the
// presence gate (docker / mix / hcloud / az / ssh) before a real run.
func lookExec(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// runCapture runs argv and returns its combined stdout+stderr as a string. It
// is used for the polling/verification beats (wait-for-healthy, capabilities
// probe via curl-free in-process checks live elsewhere) where the executor needs
// the output rather than streaming it.
func runCapture(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// runCaptureDir is runCapture scoped to a working directory — the compose
// health poll runs `docker compose ps` from the resolved repo root, not cwd.
func runCaptureDir(ctx context.Context, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// asWriter narrows a writerLike back to io.Writer for fmt.Fprintln. writerLike
// is exactly io.Writer's method set, so this is a safe assertion that keeps the
// wait closures' signatures free of an io import.
func asWriter(w writerLike) io.Writer {
	if iw, ok := w.(io.Writer); ok {
		return iw
	}
	return io.Discard
}

// shJoin renders an argv as a copy-pasteable shell line for display. It quotes
// any token containing whitespace or a quote so the rendered line is faithful.
func shJoin(argv []string) string {
	parts := make([]string, len(argv))
	for i, a := range argv {
		if strings.ContainsAny(a, " \t\"'") {
			parts[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
		} else {
			parts[i] = a
		}
	}
	return strings.Join(parts, " ")
}
