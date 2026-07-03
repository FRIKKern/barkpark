package cli

// hetzner_confirm_test.go proves the ONE destructive-op gate (charter decision
// 5) from both sides: the pure hzConfirmDestroy contract table (--yes and
// non-TTY pass through, interactive requires the exact name) and the wired
// commands (a piped server/volume delete still fires its DELETE unchanged; an
// interactive mismatch aborts with NOTHING sent to the API).

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"
)

// forceHzTTY makes hzConfirmDestroy treat any reader as an interactive
// terminal for one test, restoring the real detector afterwards.
func forceHzTTY(t *testing.T) {
	t.Helper()
	old := hzStdinIsTTY
	hzStdinIsTTY = func(io.Reader) bool { return true }
	t.Cleanup(func() { hzStdinIsTTY = old })
}

// swapHzStdin points the package-level confirm reader at an in-memory reader
// for one test (the same seam idiom as newHetznerClient).
func swapHzStdin(t *testing.T, r io.Reader) {
	t.Helper()
	old := hzStdin
	hzStdin = r
	t.Cleanup(func() { hzStdin = old })
}

// TestHzConfirmDestroyContract is the truth table of the gate: when it stays
// out of the way (--yes, non-TTY) and what an interactive session must type.
func TestHzConfirmDestroyContract(t *testing.T) {
	cases := []struct {
		name    string
		stdin   io.Reader
		tty     bool // force the reader to count as a terminal
		yes     bool
		wantErr bool
	}{
		{name: "yes flag passes through without reading stdin", stdin: strings.NewReader("would-not-match"), tty: true, yes: true},
		{name: "non-tty reader passes through (pipes, CI, tests)", stdin: strings.NewReader(""), tty: false},
		{name: "interactive exact name proceeds", stdin: strings.NewReader("web-1\n"), tty: true},
		{name: "interactive name with CRLF proceeds", stdin: strings.NewReader("web-1\r\n"), tty: true},
		{name: "interactive mismatch aborts", stdin: strings.NewReader("web-2\n"), tty: true, wantErr: true},
		{name: "interactive empty line aborts", stdin: strings.NewReader("\n"), tty: true, wantErr: true},
		{name: "interactive EOF aborts", stdin: strings.NewReader(""), tty: true, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.tty {
				forceHzTTY(t)
			}
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			err := hzConfirmDestroy(tc.stdin, out, "server", "web-1", tc.yes)
			if tc.wantErr && err == nil {
				t.Fatal("hzConfirmDestroy returned nil, want an abort error")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("hzConfirmDestroy returned %v, want nil", err)
			}
			if stdout.Len() != 0 {
				t.Errorf("prompt leaked to stdout (%q) — stdout must stay machine-clean", stdout.String())
			}
		})
	}
}

// TestHzConfirmDestroyPrompt pins the consequence line: on stderr, names the
// real kind+name, red when color is on and plain when it is off.
func TestHzConfirmDestroyPrompt(t *testing.T) {
	forceHzTTY(t)

	t.Run("color", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.color = true
		if err := hzConfirmDestroy(strings.NewReader("vol-a\n"), out, "volume", "vol-a", false); err != nil {
			t.Fatalf("matching confirm errored: %v", err)
		}
		got := stderr.String()
		if !strings.Contains(got, `This permanently deletes volume "vol-a". Type the name to confirm:`) {
			t.Errorf("prompt = %q, want the consequence line naming the volume", got)
		}
		if !strings.Contains(got, "\033[31m") {
			t.Errorf("prompt = %q, want ANSI red when color is on", got)
		}
	})

	t.Run("no-color", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		out.color = false
		if err := hzConfirmDestroy(strings.NewReader("vol-a\n"), out, "volume", "vol-a", false); err != nil {
			t.Fatalf("matching confirm errored: %v", err)
		}
		if got := stderr.String(); strings.Contains(got, "\033[") {
			t.Errorf("prompt = %q, want no ANSI escapes when color is off", got)
		}
	})
}

// TestHetznerServerDeleteNonTTYStillFires is the no-regression proof for the
// whole sweep: a script-style (piped stdin, no --yes) server delete behaves
// exactly as before the gate — resolve, DELETE, wait, receipt.
func TestHetznerServerDeleteNonTTYStillFires(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server":{"id":9,"name":"web-9","status":"running","server_type":{"id":1,"name":"cx22"},"public_net":{}}}`)
	})
	f.mux.HandleFunc("DELETE /servers/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"action":{"id":77,"command":"delete_server","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":77,"status":"success","progress":100}]}`)
	})
	swapHzStdin(t, strings.NewReader("")) // a pipe: non-TTY, nothing to type

	_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "delete", "9")
	if code != exitOK {
		t.Fatalf("piped server delete exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("DELETE", "/servers/9"); !ok {
		t.Fatalf("no DELETE /servers/9 was issued — the confirm gate must pass a non-TTY stdin through; requests: %v", f.requests())
	}
}

// TestHetznerVolumeDeleteNonTTYStillFires: same proof on the second
// representative surface (a resource without action-wait).
func TestHetznerVolumeDeleteNonTTYStillFires(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /volumes/7", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"volume":{"id":7,"name":"data-7","status":"available","size":10}}`)
	})
	f.mux.HandleFunc("DELETE /volumes/7", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 204, `{}`)
	})
	swapHzStdin(t, strings.NewReader(""))

	_, stderr, code := runHzCLI(t, "table", "hetzner", "volume", "delete", "7")
	if code != exitOK {
		t.Fatalf("piped volume delete exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("DELETE", "/volumes/7"); !ok {
		t.Fatalf("no DELETE /volumes/7 was issued — the confirm gate must pass a non-TTY stdin through; requests: %v", f.requests())
	}
}

// TestHetznerServerDeleteInteractiveMismatchAborts wires the gate end-to-end
// on the dangerous path: an interactive session typing the WRONG name exits
// non-zero and the API never sees a DELETE.
func TestHetznerServerDeleteInteractiveMismatchAborts(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server":{"id":9,"name":"web-9","status":"running","server_type":{"id":1,"name":"cx22"},"public_net":{}}}`)
	})
	forceHzTTY(t)
	swapHzStdin(t, strings.NewReader("web-90\n"))

	_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "delete", "9")
	if code == exitOK {
		t.Fatal("mismatched confirm exited 0, want a non-zero abort")
	}
	if _, ok := f.find("DELETE", "/servers/9"); ok {
		t.Fatal("DELETE /servers/9 was issued despite a mismatched confirmation")
	}
	if !strings.Contains(stderr, "web-9") {
		t.Errorf("abort stderr = %q, want it to name the resource", stderr)
	}
}

// TestHetznerServerDeleteInteractiveMatchProceeds: typing the exact name in an
// interactive session fires the delete.
func TestHetznerServerDeleteInteractiveMatchProceeds(t *testing.T) {
	f := newFakeHzAPI(t)
	f.mux.HandleFunc("GET /servers/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"server":{"id":9,"name":"web-9","status":"running","server_type":{"id":1,"name":"cx22"},"public_net":{}}}`)
	})
	f.mux.HandleFunc("DELETE /servers/9", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"action":{"id":77,"command":"delete_server","status":"running","progress":0}}`)
	})
	f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
		hzWriteJSON(w, 200, `{"actions":[{"id":77,"status":"success","progress":100}]}`)
	})
	forceHzTTY(t)
	swapHzStdin(t, strings.NewReader("web-9\n"))

	_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "delete", "9")
	if code != exitOK {
		t.Fatalf("confirmed server delete exited %d, stderr: %s", code, stderr)
	}
	if _, ok := f.find("DELETE", "/servers/9"); !ok {
		t.Fatalf("no DELETE /servers/9 after a correct confirmation; requests: %v", f.requests())
	}
}

// TestHetznerServerDeleteYesFlagSkipsPrompt: --yes (and its -y alias) skips
// the prompt even on a TTY — the script escape hatch.
func TestHetznerServerDeleteYesFlagSkipsPrompt(t *testing.T) {
	for _, flag := range []string{"--yes", "-y"} {
		t.Run(flag, func(t *testing.T) {
			f := newFakeHzAPI(t)
			f.mux.HandleFunc("GET /servers/9", func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 200, `{"server":{"id":9,"name":"web-9","status":"running","server_type":{"id":1,"name":"cx22"},"public_net":{}}}`)
			})
			f.mux.HandleFunc("DELETE /servers/9", func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 200, `{"action":{"id":77,"command":"delete_server","status":"running","progress":0}}`)
			})
			f.mux.HandleFunc("GET /actions", func(w http.ResponseWriter, r *http.Request) {
				hzWriteJSON(w, 200, `{"actions":[{"id":77,"status":"success","progress":100}]}`)
			})
			forceHzTTY(t)
			swapHzStdin(t, strings.NewReader("")) // nothing typed — --yes must not read

			_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "delete", "9", flag)
			if code != exitOK {
				t.Fatalf("server delete %s exited %d, stderr: %s", flag, code, stderr)
			}
			if _, ok := f.find("DELETE", "/servers/9"); !ok {
				t.Fatalf("no DELETE /servers/9 with %s; requests: %v", flag, f.requests())
			}
			if strings.Contains(stderr, "Type the name") {
				t.Errorf("%s still prompted: %q", flag, stderr)
			}
		})
	}
}

// TestHzYesAliasOnlyWhereDeclared: -y on a verb that never declared --yes is
// still an unknown flag, not a silent no-op.
func TestHzYesAliasOnlyWhereDeclared(t *testing.T) {
	f := newFakeHzAPI(t)
	_, stderr, code := runHzCLI(t, "table", "hetzner", "server", "list", "-y")
	if code != exitUsage {
		t.Fatalf("server list -y exited %d, want usage error %d (stderr: %s)", code, exitUsage, stderr)
	}
	if got := f.requests(); len(got) != 0 {
		t.Fatalf("server list -y still issued requests: %v", got)
	}
}
