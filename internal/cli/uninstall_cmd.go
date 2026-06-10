package cli

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mattn/go-isatty"
)

// localDevDB is the database the native local bring-up creates (mix dev
// config). The --local teardown offers to drop exactly this, by name, behind
// the confirm gate.
const localDevDB = "barkpark_dev"

// uninstallRunCmd is the shell-out seam for the --local teardown steps
// (docker compose down -v / dropdb). A var so table tests can record calls
// instead of actually tearing anything down.
var uninstallRunCmd = func(out *writer, dir, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Stdout = out.stdout
	cmd.Stderr = out.stderr
	return cmd.Run()
}

// uninstallAction is one teardown step: a human description plus the closure
// that does it. Command is the copy-pasteable line for the dry-run ("" for
// plain file removals, which name their path in the description).
type uninstallAction struct {
	desc string
	cmd  string
	run  func(out *writer) error
}

// runUninstall is the `bp uninstall` builtin — remove bp's local state from
// this machine. bp installs almost nothing, so uninstall is correspondingly
// small and honest: always the config file; --local additionally the dev stack
// (docker compose down -v when the managed clone is docker-managed, else a
// dropdb of barkpark_dev) plus ${BARKPARK_HOME:-~/.barkpark}. It NEVER touches
// remote servers or the binary itself (it prints the removal one-liner).
//
// Dry-run-first idiom: --dry-run lists everything and removes nothing; a real
// run needs --yes, or a y/N confirm on a genuine TTY. Non-TTY without --yes is
// a clean exit 2 — never a prompt.
func runUninstall(out *writer, g globals, args []string) int {
	jsonOut := g.outputSet && g.output == "json"

	local := false
	for _, a := range args {
		switch a {
		case "--local":
			local = true
		case "-h", "--help":
			printUninstallHelp(out)
			return exitOK
		default:
			out.errf("barkpark: unknown uninstall flag %q", a)
			out.errf("usage: bp uninstall [--local] [--yes] [--dry-run] [-o json]")
			return exitUsage
		}
	}
	if g.help {
		printUninstallHelp(out)
		return exitOK
	}

	actions, err := uninstallActions(local)
	if err != nil {
		out.errf("barkpark: uninstall: %v", err)
		return exitGeneric
	}

	binaryHint := uninstallBinaryHint()

	if g.dryRun {
		if jsonOut {
			out.renderJSON(map[string]any{
				"ok":           true,
				"dry_run":      true,
				"would_remove": uninstallDescriptions(actions),
				"binary":       binaryHint,
			})
			return exitOK
		}
		out.outf("bp uninstall — would remove:")
		writeUninstallList(out, actions)
		out.outf("")
		out.outf("(no execution — dry run)")
		out.outf("to remove the binary itself:  %s", binaryHint)
		return exitOK
	}

	// Real-run gate: --yes, or a one-line y/N confirm on a genuine TTY.
	if !g.yes {
		if !(isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stdout.Fd())) {
			out.errf("barkpark: bp uninstall removes local state — re-run with --yes, or run it on an interactive terminal")
			return exitUsage
		}
		out.outf("bp uninstall — about to remove:")
		writeUninstallList(out, actions)
		fmt.Fprintf(out.stdout, "\nproceed? [y/N] ")
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		switch strings.TrimSpace(strings.ToLower(line)) {
		case "y", "yes":
		default:
			out.outf("uninstall: aborted — nothing was removed.")
			return exitOK
		}
	}

	var removed []string
	for _, a := range actions {
		if err := a.run(out); err != nil {
			out.errf("barkpark: uninstall: %s: %v", a.desc, err)
			return exitGeneric
		}
		removed = append(removed, a.desc)
	}

	if jsonOut {
		out.renderJSON(map[string]any{
			"ok":      true,
			"removed": removed,
			"binary":  binaryHint,
		})
		return exitOK
	}
	out.outf("removed:")
	for _, d := range removed {
		out.outf("  %s", d)
	}
	out.outf("")
	out.outf("to remove the binary itself:  %s", binaryHint)
	return exitOK
}

// uninstallActions builds the ordered teardown list for this run.
func uninstallActions(local bool) ([]uninstallAction, error) {
	cfgPath, err := ConfigPath()
	if err != nil {
		return nil, err
	}

	cfgDesc := cfgPath + "   (saved servers + tokens)"
	if _, serr := os.Stat(cfgPath); os.IsNotExist(serr) {
		cfgDesc = cfgPath + "   (absent — nothing to do)"
	}
	actions := []uninstallAction{{
		desc: cfgDesc,
		run: func(_ *writer) error {
			err := os.Remove(cfgPath)
			if err != nil && !os.IsNotExist(err) {
				return err
			}
			return nil
		},
	}}
	if !local {
		return actions, nil
	}

	home := uninstallBarkparkHome()
	srcDir := filepath.Join(home, "src")
	if uninstallDockerManaged(srcDir) {
		actions = append(actions, uninstallAction{
			desc: "the docker dev stack (docker compose down -v in " + srcDir + ")",
			cmd:  "docker compose down -v",
			run: func(out *writer) error {
				return uninstallRunCmd(out, srcDir, "docker", "compose", "down", "-v")
			},
		})
	} else {
		actions = append(actions, uninstallAction{
			desc: "the local dev database " + localDevDB + " (dropdb on localhost:5432)",
			cmd:  "dropdb --if-exists " + localDevDB,
			run: func(out *writer) error {
				if _, lerr := exec.LookPath("dropdb"); lerr != nil {
					out.errf("  dropdb not on PATH — drop it manually: dropdb %s", localDevDB)
					return nil
				}
				return uninstallRunCmd(out, "", "dropdb", "--if-exists", localDevDB)
			},
		})
	}
	homeDesc := home + "   (managed clone, postgres, logs)"
	if _, serr := os.Stat(home); os.IsNotExist(serr) {
		homeDesc = home + "   (absent — nothing to do)"
	}
	actions = append(actions, uninstallAction{
		desc: homeDesc,
		run: func(_ *writer) error {
			err := os.RemoveAll(home)
			if err != nil && !os.IsNotExist(err) {
				return err
			}
			return nil
		},
	})
	return actions, nil
}

// writeUninstallList renders the action list for the dry-run / confirm screen.
func writeUninstallList(out *writer, actions []uninstallAction) {
	for _, a := range actions {
		out.outf("  %s", a.desc)
		if a.cmd != "" {
			out.outf("      $ %s", a.cmd)
		}
	}
}

// uninstallDescriptions projects the action list for the JSON envelope.
func uninstallDescriptions(actions []uninstallAction) []string {
	out := make([]string, 0, len(actions))
	for _, a := range actions {
		out = append(out, a.desc)
	}
	return out
}

// uninstallBarkparkHome mirrors the setup package's ${BARKPARK_HOME:-~/.barkpark}
// convention (the helper there is unexported; the value contract is shared).
func uninstallBarkparkHome() string {
	if h := strings.TrimSpace(os.Getenv("BARKPARK_HOME")); h != "" {
		return h
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".barkpark"
	}
	return filepath.Join(home, ".barkpark")
}

// uninstallDockerManaged reports whether the managed clone runs the docker dev
// stack: a compose file in srcDir AND `docker compose ps -q` listing containers.
func uninstallDockerManaged(srcDir string) bool {
	if st, err := os.Stat(filepath.Join(srcDir, "docker-compose.yml")); err != nil || st.IsDir() {
		return false
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return false
	}
	cmd := exec.Command("docker", "compose", "ps", "-q")
	cmd.Dir = srcDir
	out, err := cmd.Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

// uninstallBinaryHint renders the binary-removal one-liner (bp never deletes
// itself). Falls back to a generic path when os.Executable fails.
func uninstallBinaryHint() string {
	exe, err := os.Executable()
	if err != nil || exe == "" {
		exe = "/usr/local/bin/bp"
	}
	return "sudo rm " + exe
}

// printUninstallHelp writes the `bp uninstall` usage WITHOUT touching the TTY.
func printUninstallHelp(out *writer) {
	const help = `bp uninstall — remove bp's local state from this machine.

USAGE
  bp uninstall [--local] [--yes] [--dry-run] [-o json]

WHAT IT REMOVES
  always   ${XDG_CONFIG_HOME:-~/.config}/barkpark/config.json   (saved servers + tokens)
  --local  the local dev stack:  docker compose down -v  (when ~/.barkpark/src
           was docker-managed) or dropping the barkpark_dev database, plus
           ~/.barkpark (cloned repo, managed postgres, logs)

WHAT IT NEVER TOUCHES
  remote servers (use ssh + your provider console), this binary itself
  (the closing line prints the removal command).

FLAGS
  --local     also tear down the local dev stack (see above)
  --dry-run   list everything; remove NOTHING
  --yes       skip the confirm (required on a non-interactive terminal)
  -o json     emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}
