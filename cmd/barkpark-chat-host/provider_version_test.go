//go:build unix

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/FRIKKern/barkpark/internal/chathost"
)

// enrolWithVersion enrols against a server that refuses a provider version the
// way the real one does (registered_host.ex safe_version?, and the U+0000
// refusal of #26735): with a 422 the host takes as final. The only provider on
// PATH is a fake claude whose --version prints output. It returns the claude
// version the server was sent.
func enrolWithVersion(t *testing.T, output []byte) string {
	t.Helper()
	dir := t.TempDir()
	var escaped strings.Builder
	for _, b := range output {
		fmt.Fprintf(&escaped, "\\%03o", b)
	}
	script := "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '" + escaped.String() + "'; else echo '{\"loggedIn\":true}'; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	versions := make(chan string, 1)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var sent struct {
			Capabilities struct {
				Providers map[string]struct {
					Version string `json:"version"`
				} `json:"providers"`
			} `json:"capabilities"`
		}
		_ = json.Unmarshal(body, &sent)
		version := sent.Capabilities.Providers["claude"].Version
		versions <- version
		w.Header().Set("Content-Type", "application/json")
		if len(version) > 200 || strings.ContainsRune(version, 0) || !utf8.ValidString(version) {
			w.WriteHeader(http.StatusUnprocessableEntity)
			_, _ = w.Write([]byte(`{"error":{"code":"invalid_capabilities"}}`))
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer ts.Close()

	client := &chathost.Client{BaseURL: ts.URL, AllowInsecureLoopback: true}
	_, err := client.Enroll(context.Background(), "one-time-token", []string{dir}, capabilities())
	version := <-versions
	if err != nil {
		t.Fatalf("enrol = %v; the host would not start (version sent: %d bytes, %q)", err, len(version), version)
	}
	return version
}

// Since #26735 the server refuses capabilities holding U+0000, so a provider
// CLI whose --version prints a NUL would stop the host from enrolling, and
// from running, every time. The host stores each NUL as U+FFFD, as the
// server's EventText does (task-060e49b6007abbab). Two NULs, so replacing
// only the first one is caught.
func TestTheEnrolBodyCarriesNoNULFromAProviderVersion(t *testing.T) {
	got := enrolWithVersion(t, []byte("claude 2.1.0\x00 (Claude\x00 Code)\n"))
	if want := "claude 2.1.0" + string(utf8.RuneError) + " (Claude" + string(utf8.RuneError) + " Code)"; got != want {
		t.Fatalf("claude version %q; want %q: the rest of the version is kept, each NUL as U+FFFD", got, want)
	}
}

// The server refuses a provider version over 200 bytes the same way, so a CLI
// whose --version prints a banner or a notice would stop the host from
// starting. The host cuts it to 200 bytes on a rune boundary
// (task-d72dce0e2765f44a). The two-byte runes put a boundary at 199, so a cut
// at byte 200 splits one.
func TestAVersionLongerThan200BytesStillEnrols(t *testing.T) {
	full := "claude 2.1.0 " + strings.Repeat("é", 150) // 313 bytes
	got := enrolWithVersion(t, []byte(full+"\n"))
	if len(got) > 200 || !utf8.ValidString(got) || !strings.HasPrefix(full, got) || len(got) < 199 {
		t.Fatalf("claude version %d bytes %q; want the first 199 bytes of the output: at most 200, cut on a rune boundary", len(got), got)
	}
}

// JSON sends each byte that is not UTF-8 as a three-byte U+FFFD, so the cut
// counts the bytes the server gets, not the bytes the CLI printed: 120 lone
// bad bytes are 240 bytes printed and 480 sent.
func TestAVersionThatIsNotUTF8IsCutByTheBytesTheServerGets(t *testing.T) {
	got := enrolWithVersion(t, append([]byte("codex-cli "), []byte(strings.Repeat("\xffa", 120))...))
	if len(got) > 200 || !utf8.ValidString(got) || !strings.HasPrefix(got, "codex-cli "+string(utf8.RuneError)+"a") {
		t.Fatalf("claude version %d bytes %q; want at most 200 bytes of valid UTF-8", len(got), got)
	}
}
