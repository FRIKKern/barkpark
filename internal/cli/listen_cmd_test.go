package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// TestRunListenRejectsBadInput asserts `bp listen` errors at exit-usage instead
// of silently dropping input: a second positional (`bp listen post article`) and
// an unknown flag (`bp listen --type post`) both fail before any connection is
// opened — mirroring runExport's strictness.
func TestRunListenRejectsBadInput(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string // substring the error message must contain
	}{
		{"extra positional", []string{"post", "article"}, `extra "article"`},
		{"unknown flag", []string{"--type", "post"}, `unknown listen flag "--type"`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)

			if code := runListen(w, globals{}, manifest.Context{}, tc.args); code != exitUsage {
				t.Fatalf("runListen(%v) exit = %d, want %d; stderr=%s", tc.args, code, exitUsage, stderr.String())
			}
			if !strings.Contains(stderr.String(), tc.want) {
				t.Errorf("runListen(%v) stderr = %q, want to contain %q", tc.args, stderr.String(), tc.want)
			}
		})
	}
}

// TestRunListenHelp asserts `bp listen --help` prints usage and exits OK without
// opening the live stream — globals{help:true} short-circuits before any client.
func TestRunListenHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	if code := runListen(w, globals{help: true}, manifest.Context{}, nil); code != exitOK {
		t.Fatalf("runListen(help) exit = %d, want %d; stderr=%s", code, exitOK, stderr.String())
	}
	if !strings.Contains(stdout.String(), "usage: bp listen") {
		t.Errorf("runListen(help) stdout = %q, want to contain %q", stdout.String(), "usage: bp listen")
	}
}
