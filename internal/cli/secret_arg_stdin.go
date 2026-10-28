package cli

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// secretArgType is the manifest arg type for a value that must not sit in
// argv, such as an OIDC client secret. A positional value of "-" for such an
// arg reads the value from stdin, so it stays out of shell history and the
// process list:
//
//	bp org oidc-create acme <issuer> <client id> - --yes < ./client-secret
//
// The value is the first line of stdin with its line ending removed. An
// empty value is refused.
const secretArgType = "secret"

// secretStdinReader is the source for "-" secret args. A test seam.
var secretStdinReader io.Reader = os.Stdin

// readSecretArgsFromStdin replaces a "-" value of a secret-typed arg with the
// first line of stdin. Only one arg per invocation may read stdin, and not
// together with --file -. Headless dispatch does not own process stdin, so
// it refuses "-" there.
func readSecretArgsFromStdin(cmd manifest.Command, args map[string]string, flags map[string][]string, ownsProcessStdin bool) error {
	var name string
	for _, a := range cmd.Args {
		if a.Type != secretArgType || args[a.Name] != "-" {
			continue
		}
		if name != "" {
			return fmt.Errorf("only one argument can read stdin: <%s> and <%s> are both \"-\"", name, a.Name)
		}
		name = a.Name
	}
	if name == "" {
		return nil
	}
	if !ownsProcessStdin {
		return fmt.Errorf("<%s> \"-\" reads stdin, which is unavailable in headless dispatch", name)
	}
	if files := flags["file"]; len(files) > 0 && files[len(files)-1] == "-" {
		return fmt.Errorf("<%s> \"-\" and --file - both read stdin; give the body with --file <path>", name)
	}
	line, err := bufio.NewReader(secretStdinReader).ReadString('\n')
	if err != nil && err != io.EOF {
		return fmt.Errorf("read <%s> from stdin: %w", name, err)
	}
	value := strings.TrimRight(line, "\r\n")
	if value == "" {
		return fmt.Errorf("<%s> \"-\" read an empty value from stdin; redirect the file that holds it, such as - < ./client-secret", name)
	}
	args[name] = value
	return nil
}
