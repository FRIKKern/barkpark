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
	// -T: never ask for a remote pty. With `RequestTTY force` in the user's
	// ssh config a pty would echo the code on stdin back into what we print.
	sshErr := runSSH([]string{"-T", "--", f.ssh, remote}, strings.NewReader(minted.EnrollmentCode+"\n"), &remoteOut, os.Stderr)
	if text := strings.TrimSpace(remoteOut.String()); text != "" {
		out.errf("%s", text)
	}
	if sshErr != nil {
		return useError(out, "remote_enroll_failed", sshFailureHint(f, minted.Host.Name, remote, sshErr), exitGeneric)
	}

	if out.emitStructured(map[string]any{"host": minted.Host, "ssh": f.ssh, "enrolled": true}) {
		return exitOK
	}
	run := shellQuote(f.bin) + " run"
	if f.state != "" {
		run += " --state " + shellQuote(f.state)
	}
	out.outf("Enrolled %s on %s.", minted.Host.Name, f.ssh)
	out.outf("Start it there and keep it running, for example in tmux or as a service:")
	out.outf("")
	out.outf("  ssh %s %s", shellQuote(f.ssh), shellQuote(run))
	return exitOK
}

// sshFailureHint says what to do after ssh fails. ssh can exit non-zero (255)
// after the remote enroll succeeded, so it says "may not have", points at the
// list, and gives two ways on: send a new code over the same pipe, or revoke
// and add again. Neither puts the code in argv or on the screen.
func sshFailureHint(f chatHostEnrollFlags, name, remote string, sshErr error) string {
	add := []string{"bp chat-host add --ssh", shellQuote(f.ssh), "--name", shellQuote(name)}
	for _, root := range f.roots {
		add = append(add, "--root", shellQuote(root))
	}
	if f.state != "" {
		add = append(add, "--state", shellQuote(f.state))
	}
	if f.bin != "barkpark-chat-host" {
		add = append(add, "--bin", shellQuote(f.bin))
	}
	return fmt.Sprintf("%s may not have enrolled (ssh: %v). Check bp chat-host list: if %s still reads waiting, it did not.\n"+
		"Send it a new code over ssh's stdin (the old one stops working):\n"+
		"  bp chat-host new-code %s -o json | jq -r .enrollment_token | ssh -T %s %s\n"+
		"or revoke it and add it again:\n"+
		"  bp chat-host revoke %s && %s",
		f.ssh, sshErr, name,
		shellQuote(name), shellQuote(f.ssh), shellQuote(remote),
		shellQuote(name), strings.Join(add, " "))
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
