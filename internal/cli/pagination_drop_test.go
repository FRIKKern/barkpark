package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// applyQuery forwards --limit/--offset only when the command is `paginated` or
// declares the flag itself. Everything else it drops — correctly, since sending
// a knob the route does not read would be worse.
//
// The measured shape on the live manifest: `bp token ls --limit 5` exited 0
// having requested and printed the workspace's ENTIRE credential inventory. The
// caller asked for five rows and got all of them. On a list of seats or of
// tokens that is the reading most likely to mislead: "5 tokens reach this
// workspace" is a very different sentence from "the first 5 of however many do".
//
// THIS SUITE USED TO PIN A NOTICE AND NOW PINS A REFUSAL. The inversion is
// deliberate and is recorded here rather than erased, because the old
// assertions were the evidence that the notice was ever the intended contract.
// The old rationale — "the request is still correct and still answers the
// question, and refusing would break every existing script that passes a
// harmless global" — rested on a caller population that could be enumerated.
// It cannot: a repo-wide sweep finds ZERO `bp … --all/--limit/--offset`
// invocations in scripts/ or .github/, and the callers that actually pass these
// flags are AGENTS, which live outside this repo. An enumeration returning zero
// because it cannot see the callers is not evidence of safety, so the register
// flips to the #13620 precedent: refuse a knob you cannot honour.
//
// What is still load-bearing, and unchanged: the refusal must NOT fire for the
// commands that really do carry pagination.
func droppedKnobRefusal(t *testing.T, g globals, cmd manifest.Command) (string, int, bool) {
	t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code, refused := refuseDroppedKnobs(w, g, cmd)
	if so.Len() != 0 {
		t.Errorf("the refusal reached stdout, which must stay parseable: %q", so.String())
	}
	return se.String(), code, refused
}

func TestRefuseDroppedKnobs(t *testing.T) {
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
	paginatedWrite := manifest.Command{Noun: "doc", Verb: "publish", Paginated: true, Writes: true}

	cases := []struct {
		name     string
		g        globals
		cmd      manifest.Command
		wantSaid []string
		wantHush bool
	}{
		{
			name:     "limit refused on an unpaginated list",
			g:        globals{limit: 5, limitSet: true},
			cmd:      unpaginated,
			wantSaid: []string{"--limit", "token ls", "Nothing was sent", "not a page"},
		},
		{
			name:     "offset refused on the roster",
			g:        globals{offset: 50, offsetSet: true},
			cmd:      roster,
			wantSaid: []string{"--offset", "workspace member-ls", "Nothing was sent"},
		},
		{
			name:     "both refused are named in one line",
			g:        globals{limit: 5, limitSet: true, offset: 50, offsetSet: true},
			cmd:      unpaginated,
			wantSaid: []string{"--limit and --offset"},
		},
		{
			// --all was the one knob dropped in TOTAL silence before this
			// change, and it is the flag agents pass most reflexively.
			name:     "--all refused on an unpaginated read",
			g:        globals{all: true},
			cmd:      unpaginated,
			wantSaid: []string{"--all", "does not paginate", "Nothing was sent"},
		},
		{
			// --all is honoured only at `cmd.Paginated && g.all && !cmd.Writes`,
			// so a paginated WRITE swallowed it too.
			name:     "--all refused on a paginated write",
			g:        globals{all: true},
			cmd:      paginatedWrite,
			wantSaid: []string{"--all", "never paginated"},
		},
		{
			name:     "no knob set, no refusal",
			g:        globals{},
			cmd:      unpaginated,
			wantHush: true,
		},
		{
			// The knob is honoured here, so refusing would be a lie.
			name:     "paginated command stays silent",
			g:        globals{limit: 5, limitSet: true, offset: 50, offsetSet: true, all: true},
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
			got, code, refused := droppedKnobRefusal(t, tc.g, tc.cmd)

			if tc.wantHush {
				if refused {
					t.Errorf("expected the command to proceed, got a refusal: %q", got)
				}
				if got != "" {
					t.Errorf("expected silence, got: %q", got)
				}
				return
			}
			if !refused {
				t.Fatalf("expected a refusal, got none")
			}
			if code != exitUsage {
				t.Errorf("exit = %d, want exitUsage (%d)", code, exitUsage)
			}
			for _, want := range tc.wantSaid {
				if !strings.Contains(got, want) {
					t.Errorf("refusal omits %q:\n%s", want, got)
				}
			}
		})
	}
}

// THE INVERSION, END TO END. This test is the descendant of
// TestDroppedPaginationWarnsButStillAnswers, whose comment read "The notice must
// never become a refusal". It has become one, on the lead's ruling, and the
// assertion is inverted rather than deleted so the reversal stays legible in
// the file that pinned the old contract.
//
// The load-bearing half is unchanged and matters MORE now: the request must not
// be sent. A refusal that still hit the network would be the worst of both.
func TestDroppedPaginationRefusesAndSendsNothing(t *testing.T) {
	h := newDestroyHarness(t)
	forceNonTTY(t)

	code, stdout, stderr := h.runDestroy(globals{limit: 5, limitSet: true}, "token", "ls")

	// The refusal CHANNEL depends on the resolved output shape: a human shape
	// writes to stderr, a machine shape renders {"ok":false,…} on stdout so a
	// scripted caller can parse it. This harness forces non-TTY, so assert on
	// the union rather than pinning a rendering decision this change does not
	// own.
	both := stdout + stderr

	if code != exitUsage {
		t.Errorf("exit = %d, want exitUsage (%d) — the refusal did not fire", code, exitUsage)
	}
	if !strings.Contains(both, "--limit") {
		t.Errorf("the refused knob went unnamed:\n%s", both)
	}
	if strings.Contains(both, "ci-deploy") {
		t.Errorf("a refused invocation still printed an answer:\n%s", both)
	}
	// NOTHING was sent — the refusal runs before buildManifestRequest.
	if len(h.seen) != 0 {
		t.Errorf("a refused invocation still reached the network: %v", h.seen)
	}
}
