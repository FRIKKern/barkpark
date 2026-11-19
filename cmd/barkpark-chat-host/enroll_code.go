package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/term"
)

// maxEnrollCodeBytes bounds what readEnrollCode reads: a code is 43
// characters (32 random bytes, base64url), so anything longer is not one.
const maxEnrollCodeBytes = 4096

// enrollCode is the one-time code for `enroll`: --token when given, else the
// first line of stdin. On a terminal it asks for it without echo; in a pipe
// (`printf '%s\n' CODE | barkpark-chat-host enroll …`, or bp chat-host add
// over ssh) it reads the line as is. Reading stdin keeps the code out of
// argv, where any process on the machine can read it in ps.
func enrollCode(flagValue string) (string, error) {
	if code := strings.TrimSpace(flagValue); code != "" {
		return code, nil
	}
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		fmt.Fprint(os.Stderr, "Paste the one-time code from Studio > Chat hosts (it is not shown): ")
		line, err := term.ReadPassword(fd)
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", fmt.Errorf("read the code: %w", err)
		}
		return checkEnrollCode(string(line))
	}
	return readEnrollCode(os.Stdin)
}

// readEnrollCode reads the code from the first line of r.
func readEnrollCode(r io.Reader) (string, error) {
	reader := bufio.NewReader(io.LimitReader(r, maxEnrollCodeBytes))
	line, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("read the code from stdin: %w", err)
	}
	return checkEnrollCode(line)
}

// rootList is a repeatable --root flag.
type rootList []string

func (r *rootList) String() string { return strings.Join(*r, ",") }

func (r *rootList) Set(value string) error {
	*r = append(*r, value)
	return nil
}

func checkEnrollCode(line string) (string, error) {
	code := strings.TrimSpace(line)
	if code == "" {
		return "", errors.New("no enrollment code: pipe it on stdin (printf '%s\\n' CODE | barkpark-chat-host enroll --url … --root …) or pass --token")
	}
	return code, nil
}
