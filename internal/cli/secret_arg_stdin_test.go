package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A secret given as "-" is read from stdin, so it never sits in argv (run 1 F24).
func TestSecretArgReadsStdin(t *testing.T) {
	cmd := manifest.Command{
		Noun: "org", Verb: "oidc-rotate-secret",
		Args: []manifest.Arg{
			{Name: "org_slug", Required: true, Type: "string"},
			{Name: "client_secret", Required: true, Type: secretArgType},
		},
	}
	withStdin := func(s string) {
		old := secretStdinReader
		secretStdinReader = strings.NewReader(s)
		t.Cleanup(func() { secretStdinReader = old })
	}

	t.Run("dash reads the first line", func(t *testing.T) {
		withStdin("s3cr3t-value\r\nignored\n")
		args := map[string]string{"org_slug": "acme", "client_secret": "-"}
		if err := readSecretArgsFromStdin(cmd, args, nil, true); err != nil {
			t.Fatal(err)
		}
		if args["client_secret"] != "s3cr3t-value" {
			t.Fatalf("client_secret = %q", args["client_secret"])
		}
	})

	t.Run("a literal value is left alone", func(t *testing.T) {
		withStdin("from-stdin\n")
		args := map[string]string{"org_slug": "acme", "client_secret": "literal"}
		if err := readSecretArgsFromStdin(cmd, args, nil, true); err != nil {
			t.Fatal(err)
		}
		if args["client_secret"] != "literal" {
			t.Fatalf("client_secret = %q", args["client_secret"])
		}
	})

	t.Run("a dash on a string arg is not read", func(t *testing.T) {
		withStdin("from-stdin\n")
		args := map[string]string{"org_slug": "-", "client_secret": "literal"}
		if err := readSecretArgsFromStdin(cmd, args, nil, true); err != nil {
			t.Fatal(err)
		}
		if args["org_slug"] != "-" {
			t.Fatalf("org_slug = %q", args["org_slug"])
		}
	})

	t.Run("empty stdin is refused", func(t *testing.T) {
		withStdin("")
		args := map[string]string{"org_slug": "acme", "client_secret": "-"}
		if err := readSecretArgsFromStdin(cmd, args, nil, true); err == nil {
			t.Fatal("empty stdin was accepted")
		}
	})

	t.Run("headless dispatch refuses", func(t *testing.T) {
		withStdin("x\n")
		args := map[string]string{"org_slug": "acme", "client_secret": "-"}
		if err := readSecretArgsFromStdin(cmd, args, nil, false); err == nil {
			t.Fatal("headless dispatch read stdin")
		}
	})

	t.Run("--file - conflicts", func(t *testing.T) {
		withStdin("x\n")
		args := map[string]string{"org_slug": "acme", "client_secret": "-"}
		flags := map[string][]string{"file": {"-"}}
		if err := readSecretArgsFromStdin(cmd, args, flags, true); err == nil {
			t.Fatal("two stdin readers were accepted")
		}
	})
}
