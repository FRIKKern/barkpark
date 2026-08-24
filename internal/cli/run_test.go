package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// bulldocsPatchCommand mirrors the server manifest for `bulldocs patch`: a BATCH
// write whose ops come from --file and whose optional --if-rev optimistic guard
// must land in the JSON body as camelCase ifRev (bulldocs_ingest_controller reads
// only Map.get(params,"ifRev")).
func bulldocsPatchCommand() manifest.Command {
	return manifest.Command{
		ID:       "bulldocs.patch",
		Noun:     "bulldocs",
		Verb:     "patch",
		HTTP:     manifest.HTTP{Method: "POST", PathTemplate: "/v1/plugins/bulldocs/papers/:slug/ops"},
		AuthTier: "ingest",
		Args:     []manifest.Arg{{Name: "slug", Required: true, Type: "slug"}},
		Flags: []manifest.Flag{
			{Name: "file", Type: "file"},
			{Name: "if-rev", Type: "int"},
		},
		Writes: true,
		Batch:  true,
	}
}

// TestBulldocsPatchIfRevEntersBodyAsCamelCase pins the axi-b6 fix: `--if-rev`
// must merge into the ops body as `ifRev` and never leak into the query string,
// or the server's guard stays a silent no-op. Mutation proof: reverting
// commandFlagBelongsInBody to `cmd.ID != "cycle.open"` turns this RED (ifRev
// absent from the body, if-rev present in the URL).
func TestBulldocsPatchIfRevEntersBodyAsCamelCase(t *testing.T) {
	cmd := bulldocsPatchCommand()

	opsPath := filepath.Join(t.TempDir(), "ops.json")
	if err := os.WriteFile(opsPath, []byte(`{"ops":[{"insert-after":{"after":"b0","block":{"id":"b1"}}}]}`), 0o600); err != nil {
		t.Fatalf("write ops file: %v", err)
	}

	pos, flags, err := splitArgs(cmd, []string{"my-paper", "--file", opsPath, "--if-rev", "2"})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		t.Fatalf("bindArgs: %v", err)
	}

	rawURL := applyQuery("https://example.test/v1/plugins/bulldocs/papers/my-paper/ops", globals{}, cmd, flags, args)
	if strings.Contains(rawURL, "if-rev") || strings.Contains(rawURL, "ifRev") {
		t.Fatalf("if-rev guard leaked into the query string: %s", rawURL)
	}

	body, _, contentType, err := buildBodyWithStdinOwnership(cmd, flags, args, false)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if contentType != "application/json" {
		t.Fatalf("content type = %q, want application/json", contentType)
	}

	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if got["ifRev"] != "2" {
		t.Fatalf("body missing camelCase ifRev guard: %#v", got)
	}
	if _, ok := got["if-rev"]; ok {
		t.Fatalf("hyphenated flag name leaked into body: %#v", got)
	}
	if _, ok := got["ops"]; !ok {
		t.Fatalf("ops payload dropped when merging if-rev: %#v", got)
	}
}

// TestBulldocsPatchWithoutIfRevShipsFileVerbatim guards the additive contract:
// a plain patch (no --if-rev) still ships the --file ops object unchanged, with
// no injected guard field.
func TestBulldocsPatchWithoutIfRevShipsFileVerbatim(t *testing.T) {
	cmd := bulldocsPatchCommand()

	opsPath := filepath.Join(t.TempDir(), "ops.json")
	if err := os.WriteFile(opsPath, []byte(`{"ops":[{"insert-after":{"after":"b0","block":{"id":"b1"}}}]}`), 0o600); err != nil {
		t.Fatalf("write ops file: %v", err)
	}

	pos, flags, err := splitArgs(cmd, []string{"my-paper", "--file", opsPath})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	if _, err := bindArgs(cmd, pos); err != nil {
		t.Fatalf("bindArgs: %v", err)
	}

	body, _, _, err := buildBodyWithStdinOwnership(cmd, flags, map[string]string{"slug": "my-paper"}, false)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if _, ok := got["ifRev"]; ok {
		t.Fatalf("unset guard injected into body: %#v", got)
	}
	if _, ok := got["ops"]; !ok {
		t.Fatalf("ops payload missing: %#v", got)
	}
}

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
		// "explicit limit" USED TO LIVE HERE, pinning silence on a page that
		// filled an explicit --limit exactly. That was the inversion
		// task-d5640a667988b1d1 names: the flag being honoured silenced the
		// warning that the flag being honoured made necessary. The case is
		// MOVED, not deleted — it now asserts the notice in
		// TestTruncationGuardSurvivesAnExplicitLimit, and its quiet twin
		// (a page SHORT of an explicit limit) stays below.
		{name: "explicit limit, page not full", g: globals{limit: 9, limitSet: true}, cmd: paginatedReadCommand(3), body: full},
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

// TestRunCommandBriefViewFlip locks the option-B request-side flip (AXI R1,
// charter decision 5): machine output (json/yaml) on a command whose manifest
// declares views sends ?view=<default_for_agents>; the human shapes
// (table/minimal — incl. an explicit -o table while piped), --full, and a
// command WITHOUT a views declaration never send a view param.
func TestRunCommandBriefViewFlip(t *testing.T) {
	withViews := paginatedReadCommand(100)
	withViews.Views = &manifest.Views{
		Supported:        []string{"brief", "full"},
		Default:          "full",
		DefaultForAgents: "brief",
	}
	noViews := paginatedReadCommand(100)

	tests := []struct {
		name     string
		output   string
		g        globals
		cmd      manifest.Command
		wantView string
	}{
		{name: "json gets brief", output: "json", cmd: withViews, wantView: "brief"},
		{name: "yaml gets brief", output: "yaml", cmd: withViews, wantView: "brief"},
		{name: "explicit table stays full", output: "table", cmd: withViews, wantView: ""},
		{name: "minimal stays full", output: "minimal", cmd: withViews, wantView: ""},
		{name: "--full overrides brief", output: "json", g: globals{full: true}, cmd: withViews, wantView: ""},
		{name: "no views declaration never sends view", output: "json", cmd: noViews, wantView: ""},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var gotView string
			var hadView bool
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotView = r.URL.Query().Get("view")
				_, hadView = r.URL.Query()["view"]
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"docs":[]}`))
			}))
			defer srv.Close()

			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			g := tc.g
			g.output = tc.output
			g.outputSet = true
			out.applyGlobals(g)

			code := runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{}, tc.cmd, nil)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr.String())
			}
			if gotView != tc.wantView {
				t.Fatalf("view param = %q, want %q", gotView, tc.wantView)
			}
			if tc.wantView == "" && hadView {
				t.Fatal("request carried an empty view param; want NO view param at all")
			}
		})
	}
}

// TestRunCommandEmitsHelpHintsAllModes locks the R5 render seam: help[] entries
// on a 2xx envelope print to STDERR under ALL four output modes — the hook
// lives at runCommand's post-2xx site (the warnIfDefaultPageMayBeTruncated
// pattern), which is the one place proven to fire regardless of output shape —
// and stdout stays a single parseable document.
func TestRunCommandEmitsHelpHintsAllModes(t *testing.T) {
	body := `{"ok":true,"doc":{"doc_id":"t1"},"help":["bp task stamp t1 w1 3 --criterion 0 --met --evidence \"…\"","bp task close t1 w1 3 done"]}`

	for _, output := range []string{"json", "yaml", "table", "minimal"} {
		t.Run(output, func(t *testing.T) {
			stdout, stderr, code := runPageResponse(t, output, globals{yes: true}, nonPaginatedReadCommand(), body)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d; stderr=%q", code, exitOK, stderr)
			}
			if !strings.Contains(stderr, "help: bp task stamp t1") || !strings.Contains(stderr, "help: bp task close t1") {
				t.Fatalf("%s stderr = %q, want both help entries", output, stderr)
			}
			if strings.Contains(stdout, "help: ") {
				t.Fatalf("help hint contaminated %s stdout: %q", output, stdout)
			}
			if output == "json" {
				var v map[string]any
				if err := json.Unmarshal([]byte(stdout), &v); err != nil {
					t.Fatalf("JSON stdout is not parseable: %v\n%s", err, stdout)
				}
			}
		})
	}
}

// A {"result":…}-wrapped envelope still surfaces its help[] (helpEntries checks
// both the raw body and the unwrapped payload).
func TestRunCommandEmitsHelpHintsUnderResultWrapper(t *testing.T) {
	body := `{"result":{"ok":true,"help":["bp task pulse t1 w1 --now \"…\""]}}`
	_, stderr, code := runPageResponse(t, "json", globals{}, nonPaginatedReadCommand(), body)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stderr, "help: bp task pulse t1") {
		t.Fatalf("stderr = %q, want the wrapped help entry", stderr)
	}
}

// TestRenderSuccessJSONSilentOnAdvisories is the protective twin (ported from
// the wave's cli-flip-seam verify probe): renderSuccess's json/yaml arms print
// the raw payload and NOTHING else — warnings and help on the envelope are
// structurally dropped there. This is exactly WHY emitHelpHints hooks at
// runCommand post-2xx and must never move inside renderSuccess: anyone
// relocating it will red this test's sibling above.
func TestRenderSuccessJSONSilentOnAdvisories(t *testing.T) {
	body := []byte(`{"ok":true,"warnings":["unmet criteria"],"help":["bp task close t1 w1 3 done"]}`)

	for _, output := range []string{"json", "yaml"} {
		t.Run(output, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			out.output = output
			renderSuccess(out, nonPaginatedReadCommand(), body)
			if stderr.String() != "" {
				t.Fatalf("renderSuccess under -o %s wrote to stderr: %q — the json-silence premise this slice is built on has changed; re-audit the help[] hook placement", output, stderr.String())
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

// TestDocMutateClientFlagsStayOffTheWire guards the S1 review fix: the
// `Writes && Batch` body-routing rule must NOT capture client-consumed flags.
// `doc mutate --quiet` set the batch rule true for `quiet`, which both skipped
// the query string (clientOnly) AND leaked into the wire body as
// `{"mutations":[…],"quiet":"true"}`, re-serializing what should ship verbatim.
// Mutation proof: dropping "quiet" from commandFlagBelongsInBody's clientConsumed
// switch turns this RED.
func TestDocMutateClientFlagsStayOffTheWire(t *testing.T) {
	cmd := manifest.Command{
		ID: "doc.mutate", Noun: "doc", Verb: "mutate",
		Flags:  []manifest.Flag{{Name: "file", Type: "file"}, {Name: "quiet", Type: "bool"}},
		Writes: true, Batch: true,
	}
	opsPath := filepath.Join(t.TempDir(), "ops.json")
	if err := os.WriteFile(opsPath, []byte(`{"mutations":[{"publish":{"type":"task","id":"x"}}]}`), 0o600); err != nil {
		t.Fatalf("write ops file: %v", err)
	}
	flags := map[string][]string{"file": {opsPath}, "quiet": {"true"}}

	// Never in the query string.
	rawURL := applyQuery("https://example.test/v1/data/mutate", globals{}, cmd, flags, map[string]string{})
	if strings.Contains(rawURL, "quiet") {
		t.Fatalf("quiet leaked into query string: %s", rawURL)
	}
	// Never in the body.
	body, _, _, err := buildBodyWithStdinOwnership(cmd, flags, map[string]string{}, false)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	if strings.Contains(string(body), "quiet") {
		t.Fatalf("quiet leaked into doc.mutate body: %s", string(body))
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if _, ok := got["mutations"]; !ok {
		t.Fatalf("mutations payload dropped: %s", string(body))
	}
}
