package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
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

// TestRunListenSinglePrefixOnError asserts a failed listen prints its error with
// exactly one "listen: " prefix. The apiclient no longer wraps the message, so a
// regression that re-adds a wrap would stutter "listen: listen: …". A 403 on the
// first connect is fatal (no retry), so the command returns promptly.
func TestRunListenSinglePrefixOnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"no read access"}}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	ctx := manifest.Context{Server: srv.URL, Dataset: "production"}

	if code := runListen(w, globals{}, ctx, nil); code != exitGeneric {
		t.Fatalf("runListen exit = %d, want %d; stderr=%s", code, exitGeneric, stderr.String())
	}
	if n := strings.Count(stderr.String(), "listen: "); n != 1 {
		t.Errorf("stderr = %q, want exactly one %q prefix (got %d)", stderr.String(), "listen: ", n)
	}
	if !strings.Contains(stderr.String(), "no read access") {
		t.Errorf("stderr = %q, want the server's message %q", stderr.String(), "no read access")
	}
}
