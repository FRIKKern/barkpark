//go:build unix

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/FRIKKern/barkpark/internal/chathost"
)

// Since #26735 the server refuses capabilities holding U+0000 with a 422 the
// host takes as final, so a provider CLI whose --version prints a NUL would
// stop the host from enrolling, and from running, every time. The host stores
// it as U+FFFD, as the server's EventText does (task-060e49b6007abbab).
func TestTheEnrolBodyCarriesNoNULFromAProviderVersion(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\nif [ \"$1\" = --version ]; then printf 'claude 2.1.0\\000 (Claude Code)\\n'; else echo '{\"loggedIn\":true}'; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	bodies := make(chan []byte, 1)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		bodies <- body
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer ts.Close()

	client := &chathost.Client{BaseURL: ts.URL, AllowInsecureLoopback: true}
	if _, err := client.Enroll(context.Background(), "one-time-token", []string{dir}, capabilities()); err != nil {
		t.Fatal(err)
	}
	body := <-bodies
	if bytes.Contains(body, []byte(`\u0000`)) || bytes.IndexByte(body, 0) >= 0 {
		t.Fatalf("enrol body carries U+0000: %s", body)
	}
	var sent struct {
		Capabilities struct {
			Providers map[string]struct {
				Version string `json:"version"`
			} `json:"providers"`
		} `json:"capabilities"`
	}
	if err := json.Unmarshal(body, &sent); err != nil {
		t.Fatal(err)
	}
	if got, want := sent.Capabilities.Providers["claude"].Version, "claude 2.1.0� (Claude Code)"; got != want {
		t.Fatalf("claude version %q; want %q: the rest of the version is kept, the NUL as U+FFFD", got, want)
	}
}
