package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// applyQuery forwards --limit/--offset only when the command is `paginated` or
// declares the flag itself. Everything else it drops — correctly, since sending
// a knob the route does not read would be worse — but until now, SILENTLY.
//
// The measured shape on the live manifest: `bp token ls --limit 5` exits 0
// having requested and printed the workspace's ENTIRE credential inventory. The
// caller asked for five rows, got all of them, and nothing anywhere said the
// number had been ignored. On a list of seats or of tokens that is the reading
// most likely to mislead: "5 tokens reach this workspace" is a very different
// sentence from "the first 5 of however many do".
//
// This suite pins the notice, and — just as load-bearing — pins that it does
// NOT fire for the commands that really do carry pagination.
func warnDroppedPaginationStderr(t *testing.T, g globals, cmd manifest.Command) string {
	t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	warnDroppedPagination(w, g, cmd)
	if so.Len() != 0 {
		t.Errorf("the notice reached stdout, which must stay parseable: %q", so.String())
	}
	return se.String()
}

func TestWarnDroppedPagination(t *testing.T) {
	// Shapes lifted from the live manifest: token.ls / workspace.member-ls
	// declare neither `paginated` nor a limit flag; doc.ls is paginated;
	// media.search declares its own limit/offset flags without being paginated.
	unpaginated := manifest.Command{Noun: "token", Verb: "ls"}
	roster := manifest.Command{Noun: "workspace", Verb: "member-ls"}
	paginated := manifest.Command{Noun: "doc", Verb: "ls", Paginated: true}
	declaresOwn := manifest.Command{
		Noun:  "media",
		Verb:  "search",
		Flags: []manifest.Flag{{Name: "limit", Type: "int"}, {Name: "offset", Type: "int"}},
	}

	cases := []struct {
		name     string
		g        globals
		cmd      manifest.Command
		wantSaid []string
		wantHush bool
	}{
		{
			name:     "limit dropped on an unpaginated list",
			g:        globals{limit: 5, limitSet: true},
			cmd:      unpaginated,
			wantSaid: []string{"--limit", "token ls", "not a page"},
		},
		{
			name:     "offset dropped on the roster",
			g:        globals{offset: 50, offsetSet: true},
			cmd:      roster,
			wantSaid: []string{"--offset", "workspace member-ls"},
		},
		{
			name:     "both dropped are named in one line",
			g:        globals{limit: 5, limitSet: true, offset: 50, offsetSet: true},
			cmd:      unpaginated,
			wantSaid: []string{"--limit and --offset"},
		},
		{
			name:     "no knob set, no notice",
			g:        globals{},
			cmd:      unpaginated,
			wantHush: true,
		},
		{
			// The knob is honoured here, so a notice would be a lie.
			name:     "paginated command stays silent",
			g:        globals{limit: 5, limitSet: true, offset: 50, offsetSet: true},
			cmd:      paginated,
			wantHush: true,
		},
		{
			// applyQuery forwards these (the DECLARATION rule), so must we.
			name:     "command declaring its own flags stays silent",
			g:        globals{limit: 5, limitSet: true, offset: 50, offsetSet: true},
			cmd:      declaresOwn,
			wantHush: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := warnDroppedPaginationStderr(t, tc.g, tc.cmd)

			if tc.wantHush {
				if got != "" {
					t.Errorf("expected silence, got: %q", got)
				}
				return
			}
			for _, want := range tc.wantSaid {
				if !strings.Contains(got, want) {
					t.Errorf("notice omits %q:\n%s", want, got)
				}
			}
		})
	}
}

// The notice must never become a refusal: the request is still correct and
// still answers the question, and refusing would break every script passing a
// harmless global. This drives the real runCommand end to end.
func TestDroppedPaginationWarnsButStillAnswers(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, stdout, stderr := h.runDestroy(globals{limit: 5, limitSet: true}, "token", "ls")

	if code != exitOK {
		t.Errorf("exit = %d — the notice became a refusal, want %d", code, exitOK)
	}
	if !strings.Contains(stderr, "--limit") {
		t.Errorf("the dropped knob went unmentioned:\n%s", stderr)
	}
	if !strings.Contains(stdout, "ci-deploy") {
		t.Errorf("the answer did not survive the notice:\n%s", stdout)
	}
	// And the knob genuinely did not leave the client — the notice is true.
	if !h.sent("GET /w/acme/p/site/v1/tokens") || len(h.seen) != 1 {
		t.Errorf("unexpected requests: %v", h.seen)
	}
}
