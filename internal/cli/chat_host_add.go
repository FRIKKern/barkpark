package cli

// chat_host_add.go — `bp chat-host add --ssh user@host --name <n> --root <path>`:
// mint a one-time code with the workspace owner's token and enroll the remote
// machine over ssh in one step. The code travels on ssh's stdin to
// `barkpark-chat-host enroll`, which reads it from stdin: it is never in the
// ssh command line (local or remote ps), a file, or this terminal.

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runSSH runs `ssh <args…>` with stdin; a variable so tests can see what
// would run without a network.
var runSSH = func(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	cmd := exec.Command("ssh", args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, stderr
	return cmd.Run()
}

func runChatHostAdd(out *writer, ctx manifest.Context, args []string) int {
	f, err := parseChatHostFlags(args, true)
	if err != nil {
		return usageErrf(out, nil, "bp chat-host add %v", err)
	}
	if strings.TrimSpace(f.ssh) == "" || strings.HasPrefix(f.ssh, "-") {
		return usageErrf(out, nil, "bp chat-host add needs --ssh user@host (the machine to enroll)")
	}

	minted, _, rc := mintChatHostCode(out, ctx, "add", "", f)
	if rc != exitOK {
		return rc
	}

	remote := remoteEnrollCommand(ctx, f)
	out.errf("Enrolling %s on %s over ssh…", minted.Host.Name, f.ssh)
	var remoteOut bytes.Buffer
	sshErr := runSSH([]string{"--", f.ssh, remote}, strings.NewReader(minted.EnrollmentCode+"\n"), &remoteOut, os.Stderr)
	if text := strings.TrimSpace(remoteOut.String()); text != "" {
		out.errf("%s", text)
	}
	if sshErr != nil {
		return useError(out, "remote_enroll_failed", fmt.Sprintf(
			"%s did not enroll (%v). %s is registered and waiting; fix the machine, then run bp chat-host new-code %s and try again.",
			f.ssh, sshErr, minted.Host.Name, shellQuote(minted.Host.Name)), exitGeneric)
	}

	if out.emitStructured(map[string]any{"host": minted.Host, "ssh": f.ssh, "enrolled": true}) {
		return exitOK
	}
	run := f.bin + " run"
	if f.state != "" {
		run += " --state " + shellQuote(f.state)
	}
	out.outf("Enrolled %s on %s.", minted.Host.Name, f.ssh)
	out.outf("Start it there and keep it running, for example in tmux or as a service:")
	out.outf("")
	out.outf("  ssh %s %s", shellQuote(f.ssh), shellQuote(run))
	return exitOK
}

// remoteEnrollCommand is the shell command ssh runs on the machine. It names
// the server and folders, never the code.
func remoteEnrollCommand(ctx manifest.Context, f chatHostEnrollFlags) string {
	parts := []string{shellQuote(f.bin), "enroll", "--url", shellQuote(strings.TrimRight(ctx.Server, "/"))}
	for _, root := range f.roots {
		parts = append(parts, "--root", shellQuote(root))
	}
	if f.state != "" {
		parts = append(parts, "--state", shellQuote(f.state))
	}
	return strings.Join(parts, " ")
}
