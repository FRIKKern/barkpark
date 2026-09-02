package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ---------------------------------------------------------------------------
// S2 #2a — THE FLAG MODEL. A repeated flag the manifest does not declare
// repeatable is a USAGE ERROR, never a silent tie-break.
//
// The defect was never "--filter is buggy". splitArgs collects into
// map[string][]string and hands the slice to whichever consumer asks first,
// and the two consumers disagree on how to reduce it:
//
//	buildBody   flags["file"][len-1]          -> LAST wins, silently
//	applyQuery  q.Add(name, v) for every v    -> a duplicate scalar key, which
//	                                            Plug decodes by keeping ONE,
//	                                            chosen by decode order
//
// Both answer 200 OK to a question the caller did not ask. The rule below is
// therefore general — it covers every non-repeatable flag on every command,
// value and bool, --long and -f short — with exactly two exemptions:
// `repeatable: true` in the manifest (doc.query's --filter, the six --set
// flags) and setBodyFlagName, which merges rather than discards.
//
// MUTATION PROOF: make refuseRepeatedFlag return nil unconditionally. The
// "non-repeatable ... twice" and "-f then --file" cases below go red naming
// the flag whose second value was swallowed; the repeatable and --set cases
// stay green, which is what makes the red mean "the rule died" rather than
// "the parser broke".
// ---------------------------------------------------------------------------
func TestSplitArgsRefusesRepeatedNonRepeatableFlag(t *testing.T) {
	cmd := manifest.Command{
		ID: "doc.query", Noun: "doc", Verb: "query",
		HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/query/:dataset/:type"},
		Args: []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "filter", Type: "string", Repeatable: true},
			{Name: "fields", Type: "string"},
			{Name: "file", Type: "file"},
			{Name: "force", Type: "bool"},
			// DELIBERATELY not marked repeatable: --set is repeatable by
			// construction and must survive a manifest that forgets to say so.
			{Name: "set", Type: "string"},
		},
	}

	cases := []struct {
		name    string
		tail    []string
		wantErr []string // substrings the refusal must carry, or nil to require success
		wantVal map[string][]string
	}{
		{
			name:    "a manifest-declared repeatable flag keeps every occurrence",
			tail:    []string{"post", "--filter", "status=published", "--filter", "lang=nb"},
			wantVal: map[string][]string{"filter": {"status=published", "lang=nb"}},
		},
		{
			name:    "--set is repeatable by construction even when the manifest forgets",
			tail:    []string{"post", "--set", "a=1", "--set", "b=2", "--set", "c=3"},
			wantVal: map[string][]string{"set": {"a=1", "b=2", "c=3"}},
		},
		{
			name:    "a single occurrence of a non-repeatable flag is untouched",
			tail:    []string{"post", "--fields", "title,slug"},
			wantVal: map[string][]string{"fields": {"title,slug"}},
		},
		{
			name:    "a non-repeatable value flag given twice refuses, naming both values",
			tail:    []string{"post", "--fields", "title", "--fields", "slug"},
			wantErr: []string{"--fields", "twice", `"title"`, `"slug"`, "not repeatable"},
		},
		{
			name:    "the inline --name=value spelling is the same flag",
			tail:    []string{"post", "--fields=title", "--fields=slug"},
			wantErr: []string{"--fields", `"title"`, `"slug"`},
		},
		{
			name:    "a bool flag given twice refuses without inventing values",
			tail:    []string{"post", "--force", "--force"},
			wantErr: []string{"--force", "twice", "not repeatable"},
		},
		{
			name: "-f and --file are ONE flag, and the refusal names the long form",
			// This is the buildBody last-wins path: on unpatched main the
			// second path silently won and the first file was never read.
			tail:    []string{"post", "-f", "first.json", "--file", "second.json"},
			wantErr: []string{"--file", `"first.json"`, `"second.json"`},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, flags, err := splitArgs(cmd, tc.tail)
			if len(tc.wantErr) > 0 {
				if err == nil {
					t.Fatalf("a repeated non-repeatable flag was accepted silently; flags=%v", flags)
				}
				for _, want := range tc.wantErr {
					if !strings.Contains(err.Error(), want) {
						t.Errorf("refusal %q does not carry %q", err.Error(), want)
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("splitArgs: %v", err)
			}
			for name, want := range tc.wantVal {
				got := flags[name]
				if len(got) != len(want) {
					t.Fatalf("flags[%q] = %v, want %v", name, got, want)
				}
				for i := range want {
					if got[i] != want[i] {
						t.Fatalf("flags[%q] = %v, want %v", name, got, want)
					}
				}
			}
		})
	}
}

// TestSplitArgsRepeatRuleCoversEveryCommandFlag pins the SCOPE claim the row
// asks for by name ("the decision states which OTHER repeated flags it
// covers"): the rule is a property of manifest.Flag, not a list of flag names.
// A command whose flags are entirely invented here — no `filter`, no `set`,
// nothing the CLI special-cases — is still covered.
func TestSplitArgsRepeatRuleCoversEveryCommandFlag(t *testing.T) {
	cmd := manifest.Command{
		ID: "plugin.settings", Noun: "plugin", Verb: "settings",
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/plugins/:name/settings"},
		Flags: []manifest.Flag{{Name: "scope", Type: "string"}, {Name: "since", Type: "string"}},
	}
	for _, name := range []string{"scope", "since"} {
		if _, _, err := splitArgs(cmd, []string{"--" + name, "a", "--" + name, "b"}); err == nil {
			t.Errorf("--%s repeated was accepted: the rule is keyed on a flag NAME, not on Repeatable", name)
		}
	}
	if _, _, err := splitArgs(cmd, []string{"--scope", "a", "--since", "b"}); err != nil {
		t.Errorf("two DIFFERENT flags must not trip the repeat rule: %v", err)
	}
}

// ---------------------------------------------------------------------------
// S2 #20 — THE STDIN CONTRACT. bp does not abort because of a stdin it does
// not read; it says so on stderr and proceeds.
// ---------------------------------------------------------------------------

// pipeStdin points os.Stdin at a pipe carrying input for the duration of t.
func pipeStdin(t *testing.T, input string) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	if _, err := io.WriteString(w, input); err != nil {
		t.Fatalf("write stdin pipe: %v", err)
	}
	_ = w.Close()
	original := os.Stdin
	os.Stdin = r
	t.Cleanup(func() {
		os.Stdin = original
		_ = r.Close()
	})
}

func stdinNoticeDocCreate() manifest.Command {
	return manifest.Command{
		ID: "doc.create", Noun: "doc", Verb: "create", Writes: true, MutationOp: "create",
		HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
		Args:  []manifest.Arg{{Name: "type", Required: true, Type: "string"}},
		Flags: []manifest.Flag{{Name: "file", Type: "file"}, {Name: "set", Type: "string", Repeatable: true}},
	}
}

// TestBuildBodyNeverRefusesUnusedStdin is the fail-first behaviour test for
// #20. On unpatched main both arms below return
// "piped stdin is unused; pass --file - to consume it" / "... does not accept
// --file; remove the stdin redirect" and exit 2 — inside a
// `while read -r id; do bp doc patch task "$id" --set …; done < ids.txt` the
// loop and bp share fd 0, so EVERY iteration aborted while the reads around
// them succeeded and the run looked healthy. Neither arm loses data by
// proceeding: the command was never going to read stdin under the flags it was
// given.
//
// MUTATION PROOF: restore either refusal in buildBodyWithStdinOwnership and
// the matching arm reds on the returned error, not on a message string.
func TestBuildBodyNeverRefusesUnusedStdin(t *testing.T) {
	t.Run("a command that declares --file but was not given it proceeds", func(t *testing.T) {
		pipeStdin(t, `{"title":"ignored"}`)
		body, _, _, err := buildBody(stdinNoticeDocCreate(), map[string][]string{}, map[string]string{"type": "paper"})
		if err != nil {
			t.Fatalf("an unread piped stdin must not abort the write: %v", err)
		}
		if want := `{"mutations":[{"create":{"type":"paper"}}]}`; string(body) != want {
			t.Fatalf("body = %s, want %s", body, want)
		}
	})

	t.Run("a mutation command with no --file flag proceeds", func(t *testing.T) {
		docPatch := manifest.Command{
			ID: "doc.patch", Noun: "doc", Verb: "patch", Writes: true, MutationOp: "patch", SetKey: "set",
			HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
			Args: []manifest.Arg{
				{Name: "type", Required: true, Type: "string"},
				{Name: "id", Required: true, Type: "string"},
			},
			Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
		}
		pipeStdin(t, `{"title":"ignored"}`)
		body, _, _, err := buildBody(docPatch, map[string][]string{"set": {"title=x"}},
			map[string]string{"type": "paper", "id": "p1"})
		if err != nil {
			t.Fatalf("an unread piped stdin must not abort the mutation: %v", err)
		}
		if !strings.Contains(string(body), `"title":"x"`) {
			t.Fatalf("the --set payload did not survive: %s", body)
		}
	})

	t.Run("--file <path> alongside a pipe uses the file and proceeds", func(t *testing.T) {
		dir := t.TempDir()
		path := dir + "/body.json"
		if err := os.WriteFile(path, []byte(`{"title":"from the file"}`), 0o600); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
		pipeStdin(t, `{"title":"from the pipe"}`)
		body, _, _, err := buildBody(stdinNoticeDocCreate(), map[string][]string{"file": {path}},
			map[string]string{"type": "paper"})
		if err != nil {
			t.Fatalf("--file with an idle pipe must not abort: %v", err)
		}
		if !strings.Contains(string(body), "from the file") {
			t.Fatalf("--file must still win over the pipe: %s", body)
		}
	})
}

// TestUnusedStdinNoticeContract pins the REPLACEMENT for the refusal: one
// stderr line naming what WOULD have consumed the pipe, and silence in the
// four cases where naming a flag would be a lie.
//
// MUTATION PROOF: return "" from unusedStdinNotice for the file-flag arm and
// the "must name --file -" case reds; return a notice for the `--file -` arm
// and the "stdin IS the body" case reds. A test that only asserted "no error"
// would stay green through both.
func TestUnusedStdinNoticeContract(t *testing.T) {
	docCreate := stdinNoticeDocCreate()
	taskClose := manifest.Command{
		ID: "task.close", Noun: "task", Verb: "close", Writes: true,
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/tasks/:doc_id/close"},
		Args: []manifest.Arg{{Name: "id", Required: true, Type: "string"}},
	}
	docGet := manifest.Command{
		ID: "doc.get", Noun: "doc", Verb: "get",
		HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"},
	}

	t.Run("a command that could have read the pipe names --file -", func(t *testing.T) {
		pipeStdin(t, `{"title":"ignored"}`)
		got := unusedStdinNotice(docCreate, map[string][]string{}, map[string]string{"type": "paper"})
		if !strings.Contains(got, "piped stdin is unused") || !strings.Contains(got, "--file -") {
			t.Fatalf("notice = %q, want it to name the unused pipe AND --file -", got)
		}
	})

	t.Run("--file - consumes stdin, so there is nothing to report", func(t *testing.T) {
		pipeStdin(t, `{"title":"used"}`)
		if got := unusedStdinNotice(docCreate, map[string][]string{"file": {"-"}}, map[string]string{"type": "paper"}); got != "" {
			t.Fatalf("--file - was told its own stdin is unused: %q", got)
		}
	})

	t.Run("--file <path> reports the pipe and names the file that won", func(t *testing.T) {
		pipeStdin(t, `{"title":"ignored"}`)
		got := unusedStdinNotice(docCreate, map[string][]string{"file": {"payload.json"}}, map[string]string{"type": "paper"})
		if !strings.Contains(got, "piped stdin is unused") || !strings.Contains(got, "payload.json") {
			t.Fatalf("notice = %q, want it to name payload.json as the body that won", got)
		}
	})

	t.Run("a mutation with no --file flag does not recommend a flag its parser rejects", func(t *testing.T) {
		docPatch := manifest.Command{
			ID: "doc.patch", Noun: "doc", Verb: "patch", Writes: true, MutationOp: "patch", SetKey: "set",
			HTTP:  manifest.HTTP{Method: "POST", PathTemplate: "/v1/data/mutate/:dataset"},
			Flags: []manifest.Flag{{Name: "set", Type: "string", Repeatable: true}},
		}
		pipeStdin(t, `{"title":"ignored"}`)
		got := unusedStdinNotice(docPatch, map[string][]string{"set": {"title=x"}}, map[string]string{})
		if !strings.Contains(got, "piped stdin is unused") {
			t.Fatalf("notice = %q, want the pipe reported", got)
		}
		if strings.Contains(got, "--file -") {
			t.Fatalf("doc patch declares no file flag; recommending --file - is a flag its parser rejects: %q", got)
		}
	})

	t.Run("a write with no stdin sink at all stays silent", func(t *testing.T) {
		// 59 of the 72 write commands in the served manifest. There is no flag
		// that could route stdin into them, so a notice would name nothing and
		// would fire on every `while read` iteration.
		pipeStdin(t, "task-aaa\ntask-bbb\n")
		if got := unusedStdinNotice(taskClose, map[string][]string{}, map[string]string{"id": "task-aaa"}); got != "" {
			t.Fatalf("a no-sink write warned about a non-choice: %q", got)
		}
	})

	t.Run("a read stays silent", func(t *testing.T) {
		pipeStdin(t, "noise\n")
		if got := unusedStdinNotice(docGet, map[string][]string{}, map[string]string{}); got != "" {
			t.Fatalf("a read has no body and warned anyway: %q", got)
		}
	})

	t.Run("no redirect, no notice", func(t *testing.T) {
		// os.Stdin left as the test binary's own — a /dev/null or terminal fd
		// carries nothing to discard.
		devNull, err := os.Open(os.DevNull)
		if err != nil {
			t.Fatalf("open %s: %v", os.DevNull, err)
		}
		original := os.Stdin
		os.Stdin = devNull
		t.Cleanup(func() { os.Stdin = original; _ = devNull.Close() })
		if got := unusedStdinNotice(docCreate, map[string][]string{}, map[string]string{"type": "paper"}); got != "" {
			t.Fatalf("an empty stdin produced a notice: %q", got)
		}
	})
}

// TestRunCommandWarnsOnUnusedStdinAndStillSends is the end-to-end half: the
// notice reaches STDERR (never stdout, so -o json stays one parseable
// document) and the request is still sent. On unpatched main the server is
// never reached at all — runCommand returns exitUsage from buildManifestRequest.
//
// MUTATION PROOF: drop the `for _, warning := range req.warnings` loop in
// runCommand and this reds on the stderr assertion while every buildBody test
// above stays green — the notice exists but nobody says it.
func TestRunCommandWarnsOnUnusedStdinAndStillSends(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"type":"paper"`) {
			t.Errorf("server received %s, want the --set/arg body", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"ok":true,"results":[{"id":"p1"}]}`)
	}))
	defer srv.Close()

	pipeStdin(t, `{"title":"ignored"}`)

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	g := globals{}
	out.applyGlobals(g)

	code := runCommand(out, g, manifest.Context{Server: srv.URL, Dataset: "production"},
		&manifest.Manifest{}, stdinNoticeDocCreate(), []string{"paper"})

	if code == exitUsage {
		t.Fatalf("an unread pipe still aborted the command (exit %d); stderr=%q", code, stderr.String())
	}
	if hits != 1 {
		t.Fatalf("the request was not sent: %d hits, stderr=%q", hits, stderr.String())
	}
	if !strings.Contains(stderr.String(), "piped stdin is unused") {
		t.Errorf("the notice never reached stderr: %q", stderr.String())
	}
	if strings.Contains(stdout.String(), "piped stdin is unused") {
		t.Errorf("the notice leaked onto stdout: %q", stdout.String())
	}
}
