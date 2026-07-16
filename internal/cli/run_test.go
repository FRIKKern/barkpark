package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func TestRunCommandWarnsWhenDefaultPageMayBeTruncated(t *testing.T) {
	body := `{"docs":[{"id":"1"},{"id":"2"},{"id":"3"}]}`

	for _, output := range []string{"json", "yaml"} {
		t.Run(output, func(t *testing.T) {
			stdout, stderr, code := runPageResponse(t, output, globals{}, paginatedReadCommand(3), body)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
			}
			if !strings.Contains(stderr, "--all") {
				t.Fatalf("stderr = %q, want deterministic truncation notice naming --all", stderr)
			}
			if strings.Contains(stdout, "--all") {
				t.Fatalf("notice contaminated %s stdout: %q", output, stdout)
			}

			switch output {
			case "json":
				var got map[string][]json.RawMessage
				if err := json.Unmarshal([]byte(stdout), &got); err != nil {
					t.Fatalf("JSON stdout is not parseable: %v\n%s", err, stdout)
				}
				if len(got["docs"]) != 3 {
					t.Fatalf("JSON docs = %d, want 3", len(got["docs"]))
				}
			case "yaml":
				if !strings.HasPrefix(stdout, "docs:\n") {
					t.Fatalf("YAML stdout lost its document shape: %q", stdout)
				}
			}
		})
	}
}

func TestRunCommandTruncationNoticeBoundaries(t *testing.T) {
	full := `{"docs":[{"id":"1"},{"id":"2"},{"id":"3"}]}`
	short := `{"docs":[{"id":"1"},{"id":"2"}]}`

	tests := []struct {
		name string
		g    globals
		cmd  manifest.Command
		body string
	}{
		{name: "short default page", cmd: paginatedReadCommand(3), body: short},
		{name: "explicit limit", g: globals{limit: 3, limitSet: true}, cmd: paginatedReadCommand(3), body: full},
		{name: "all pagination", g: globals{all: true}, cmd: paginatedReadCommand(3), body: full},
		{name: "non-paginated read", cmd: nonPaginatedReadCommand(), body: full},
		{name: "write", g: globals{yes: true}, cmd: paginatedWriteCommand(3), body: full},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, code := runPageResponse(t, "json", tc.g, tc.cmd, tc.body)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
			}
			if stderr != "" {
				t.Fatalf("stderr = %q, want no truncation notice", stderr)
			}
		})
	}
}

func runPageResponse(t *testing.T, output string, g globals, cmd manifest.Command, body string) (string, string, int) {
	t.Helper()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g.output = output
	g.outputSet = true
	out.applyGlobals(g)

	ctx := manifest.Context{Server: srv.URL}
	m := &manifest.Manifest{}
	code := runCommand(out, g, ctx, m, cmd, nil)
	return stdout.String(), stderr.String(), code
}

func paginatedReadCommand(defaultLimit int) manifest.Command {
	return manifest.Command{
		ID:            "task.ready",
		Noun:          "task",
		Verb:          "ready",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/tasks"},
		Flags:         []manifest.Flag{{Name: "limit", Type: "int", Default: float64(defaultLimit)}},
		Paginated:     true,
		DefaultOutput: "table",
	}
}

func nonPaginatedReadCommand() manifest.Command {
	cmd := paginatedReadCommand(3)
	cmd.Paginated = false
	return cmd
}

func paginatedWriteCommand(defaultLimit int) manifest.Command {
	cmd := paginatedReadCommand(defaultLimit)
	cmd.HTTP.Method = http.MethodPost
	cmd.Writes = true
	return cmd
}

// flagValueGuardCommand declares two string value-flags (--a and --b) so
// splitArgs' "next token is a declared flag, not a value" guard has something
// to trip over.
func flagValueGuardCommand() manifest.Command {
	return manifest.Command{
		ID:   "widget.frob",
		Noun: "widget",
		Verb: "frob",
		HTTP: manifest.HTTP{Method: http.MethodPost, PathTemplate: "/widgets"},
		Flags: []manifest.Flag{
			{Name: "a", Type: "string"},
			{Name: "b", Type: "string"},
		},
	}
}

func TestSplitArgsRejectsFlagShapedValue(t *testing.T) {
	cmd := flagValueGuardCommand()

	tests := []struct {
		name    string
		tail    []string
		wantErr bool
		wantVal string
	}{
		{name: "declared long flag swallowed as value", tail: []string{"--a", "--b"}, wantErr: true},
		{name: "dash-prefixed declared flag name swallowed as value", tail: []string{"--a", "-b"}, wantErr: true},
		{name: "flag at end of args with no value", tail: []string{"--a"}, wantErr: true},
		{name: "undeclared token still binds", tail: []string{"--a", "notaflag"}, wantErr: false, wantVal: "notaflag"},
		{name: "negative number still binds", tail: []string{"--a", "-5"}, wantErr: false, wantVal: "-5"},
		{name: "inline value bypasses the guard entirely", tail: []string{"--a=--b"}, wantErr: false, wantVal: "--b"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, flags, err := splitArgs(cmd, tc.tail)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("splitArgs(%v) = nil error, want a %q error", tc.tail, "needs a value")
				}
				if !strings.Contains(err.Error(), "needs a value") {
					t.Fatalf("splitArgs(%v) error = %q, want it to mention %q", tc.tail, err.Error(), "needs a value")
				}
				return
			}
			if err != nil {
				t.Fatalf("splitArgs(%v) unexpected error: %v", tc.tail, err)
			}
			if got := flags["a"]; len(got) != 1 || got[0] != tc.wantVal {
				t.Fatalf("splitArgs(%v) flags[a] = %v, want [%q]", tc.tail, got, tc.wantVal)
			}
		})
	}
}

func TestSplitArgsShortAliasRejectsFlagShapedValue(t *testing.T) {
	cmd := manifest.Command{
		ID:    "widget.frob",
		Noun:  "widget",
		Verb:  "frob",
		HTTP:  manifest.HTTP{Method: http.MethodPost, PathTemplate: "/widgets"},
		Flags: []manifest.Flag{{Name: "file", Type: "string"}, {Name: "b", Type: "string"}},
	}

	tests := []struct {
		name    string
		tail    []string
		wantErr bool
	}{
		{name: "short alias swallows declared long flag", tail: []string{"-f", "--b"}, wantErr: true},
		{name: "short alias at end of args", tail: []string{"-f"}, wantErr: true},
		{name: "short alias still binds a literal", tail: []string{"-f", "payload.json"}, wantErr: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, flags, err := splitArgs(cmd, tc.tail)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("splitArgs(%v) = nil error, want a %q error", tc.tail, "needs a value")
				}
				if !strings.Contains(err.Error(), "needs a value") {
					t.Fatalf("splitArgs(%v) error = %q, want it to mention %q", tc.tail, err.Error(), "needs a value")
				}
				return
			}
			if err != nil {
				t.Fatalf("splitArgs(%v) unexpected error: %v", tc.tail, err)
			}
			if got := flags["file"]; len(got) != 1 || got[0] != tc.tail[1] {
				t.Fatalf("splitArgs(%v) flags[file] = %v, want [%q]", tc.tail, got, tc.tail[1])
			}
		})
	}
}
