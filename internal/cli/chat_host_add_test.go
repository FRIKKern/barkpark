package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

// stubSSH swaps runSSH for a recorder and restores it after the test.
func stubSSH(t *testing.T, fail error) (*[]string, *string) {
	t.Helper()
	var args []string
	var stdin string
	prev := runSSH
	runSSH = func(a []string, in io.Reader, stdout, _ io.Writer) error {
		args = a
		b, _ := io.ReadAll(in)
		stdin = string(b)
		_, _ = io.WriteString(stdout, "enrolled host vm2 (h9)\n")
		return fail
	}
	t.Cleanup(func() { runSSH = prev })
	return &args, &stdin
}

// TestChatHostAddNeverPutsCodeInSSHArgs: add mints a code and hands it to the
// machine's enroll on ssh's stdin. It is never in ssh's argv (which ps shows
// on both machines) and never printed.
func TestChatHostAddNeverPutsCodeInSSHArgs(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()
	args, stdin := stubSSH(t, nil)

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"add", "--ssh", "bot@vm2", "--name", "vm2", "--root", "/srv/bot"})
	if rc != exitOK {
		t.Fatalf("rc = %d, stderr:\n%s", rc, stderr.String())
	}
	if *stdin != "SECRET-CODE\n" {
		t.Fatalf("ssh stdin = %q, want the code and a newline", *stdin)
	}
	if strings.Contains(strings.Join(*args, " "), "SECRET-CODE") {
		t.Fatalf("the code is in ssh's argv: %q", *args)
	}
	if len(*args) < 4 || (*args)[1] != "--" || (*args)[2] != "bot@vm2" {
		t.Fatalf("ssh argv = %q, want -T -- bot@vm2 <command>", *args)
	}
	remote := (*args)[3]
	for _, want := range []string{"barkpark-chat-host enroll", "--url " + srv.URL, "--root /srv/bot"} {
		if !strings.Contains(remote, want) {
			t.Fatalf("remote command %q lacks %q", remote, want)
		}
	}
	if strings.Contains(stdout.String()+stderr.String(), "SECRET-CODE") {
		t.Fatalf("add printed the code:\n%s\n%s", stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "Enrolled vm2 on bot@vm2") {
		t.Fatalf("stdout does not report the enroll:\n%s", stdout.String())
	}
}

// TestChatHostAddNeverAsksForARemotePty: ssh gets -T before the host, so a
// `RequestTTY force` in the user's ssh config cannot give the remote side a
// pty that echoes the code on stdin back into what bp prints.
func TestChatHostAddNeverAsksForARemotePty(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()
	args, _ := stubSSH(t, nil)

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"add", "--ssh", "bot@vm2", "--name", "vm2", "--root", "/srv/bot"})
	if rc != exitOK {
		t.Fatalf("rc = %d, stderr:\n%s", rc, stderr.String())
	}
	dashdash := -1
	for i, a := range *args {
		if a == "--" {
			dashdash = i
			break
		}
	}
	hasT := false
	for _, a := range (*args)[:max(dashdash, 0)] {
		hasT = hasT || a == "-T"
	}
	if dashdash < 0 || !hasT {
		t.Fatalf("ssh argv = %q, want -T among the options before --", *args)
	}
}

// TestChatHostAddQuotesBinInTheRunHint: a --bin path with a space is quoted
// in the printed `ssh … run` line, so pasting it runs that binary.
func TestChatHostAddQuotesBinInTheRunHint(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()
	stubSSH(t, nil)

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"add", "--ssh", "bot@vm2", "--name", "vm2", "--root", "/srv/bot", "--bin", "/opt/chat host/bin"})
	if rc != exitOK {
		t.Fatalf("rc = %d, stderr:\n%s", rc, stderr.String())
	}
	want := `ssh bot@vm2 ''\''/opt/chat host/bin'\'' run'`
	if !strings.Contains(stdout.String(), want) {
		t.Fatalf("run hint does not quote --bin; want %s in:\n%s", want, stdout.String())
	}
}

// TestChatHostAddNonOwnerMintsNothing: a non-owner token is refused before
// ssh runs.
func TestChatHostAddNonOwnerMintsNothing(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, false, &seen)
	defer srv.Close()
	args, _ := stubSSH(t, nil)

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"add", "--ssh", "bot@vm2", "--name", "vm2", "--root", "/srv/bot"})
	if rc != exitAuth {
		t.Fatalf("rc = %d, want %d", rc, exitAuth)
	}
	if *args != nil {
		t.Fatalf("ssh ran for a refused mint: %q", *args)
	}
	if !strings.Contains(stderr.String(), "this needs the workspace owner's token") {
		t.Fatalf("stderr:\n%s", stderr.String())
	}
}

// TestChatHostAddRefusesAnOptionAsHost: --ssh "-oProxyCommand=…" must not
// reach ssh as an option, and nothing is minted for it.
func TestChatHostAddRefusesAnOptionAsHost(t *testing.T) {
	args, _ := stubSSH(t, nil)
	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx("http://127.0.0.1:1"),
		[]string{"add", "--ssh=-oProxyCommand=touch /tmp/x", "--name", "vm2", "--root", "/srv/bot"})
	if rc != exitUsage {
		t.Fatalf("rc = %d, want %d", rc, exitUsage)
	}
	if *args != nil {
		t.Fatalf("ssh ran: %q", *args)
	}
}

// TestChatHostAddSSHFailureSaysWhatToDo: a failed remote enroll leaves the
// host waiting and says how to try again, without the code.
func TestChatHostAddSSHFailureSaysWhatToDo(t *testing.T) {
	var seen []string
	srv := chatHostServer(t, true, &seen)
	defer srv.Close()
	stubSSH(t, errors.New("exit status 127"))

	var stdout, stderr bytes.Buffer
	rc := runChatHost(newWriter(&stdout, &stderr), globals{}, chatHostCtx(srv.URL),
		[]string{"add", "--ssh", "bot@vm2", "--name", "vm2", "--root", "/srv/bot"})
	if rc == exitOK {
		t.Fatal("a failed remote enroll must not exit 0")
	}
	for _, want := range []string{
		// ssh can exit 255 after the remote enroll worked: no false "did not".
		"may not have enrolled", "bp chat-host list",
		// A way on that works as printed: only the code goes down the pipe.
		"bp chat-host new-code vm2 -o json | jq -r .enrollment_token | ssh -T bot@vm2 'barkpark-chat-host enroll --url ",
		"bp chat-host revoke vm2 && bp chat-host add --ssh bot@vm2 --name vm2 --root /srv/bot",
	} {
		if !strings.Contains(stderr.String(), want) {
			t.Fatalf("stderr lacks %q:\n%s", want, stderr.String())
		}
	}
	if strings.Contains(stderr.String(), "did not enroll") {
		t.Fatalf("stderr claims the enroll failed; ssh cannot know:\n%s", stderr.String())
	}
	if strings.Contains(stdout.String()+stderr.String(), "SECRET-CODE") {
		t.Fatal("a failed add printed the code")
	}
}
