package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// REMAINDER B of the CLI honesty wave (task-d5640a667988b1d1).
//
// The row asked for a refuse-vs-notice ruling. The ruling was already made and
// landed inside warnDroppedPagination itself — notice, not refusal, because
// "the request is still correct and still answers the question, and refusing
// would break every existing script that passes a harmless global". These
// tests extend that settled register to the one knob it had not reached.
//
// Measured before the change, against the live manifest, both channels
// captured: --limit and --offset ALREADY emitted a note; --all emitted
// nothing at all. The row read them all as silent because its repro captured
// stdout only, and the notice goes to stderr.
func TestWarnDroppedPaginationCoversAll(t *testing.T) {
	// A command that declares NEITHER knob and does not paginate — the shape
	// `doc get` has on the live manifest.
	plain := manifest.Command{
		ID: "doc.get", Noun: "doc", Verb: "get",
		HTTP:          manifest.HTTP{Method: http.MethodGet, PathTemplate: "/doc"},
		DefaultOutput: "table",
	}

	t.Run("--all on a non-paginated read is named", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		warnDroppedPagination(out, globals{all: true}, plain)
		if !strings.Contains(stderr.String(), "--all ignored") {
			t.Errorf("--all was dropped in silence: %q", stderr.String())
		}
		if stdout.Len() != 0 {
			t.Errorf("the notice polluted stdout: %q", stdout.String())
		}
	})

	t.Run("--all on a paginated WRITE is named", func(t *testing.T) {
		// runCommand honours --all only at `cmd.Paginated && g.all &&
		// !cmd.Writes`, so a paginated write drops it just as silently.
		w := paginatedWriteCommand(50)
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		warnDroppedPagination(out, globals{all: true}, w)
		if !strings.Contains(stderr.String(), "--all ignored") {
			t.Errorf("--all on a paginated write was silent: %q", stderr.String())
		}
		if !strings.Contains(stderr.String(), "never paginated") {
			t.Errorf("the write arm did not say why: %q", stderr.String())
		}
	})

	t.Run("--all on a paginated READ is NOT named", func(t *testing.T) {
		// It is honoured there; a note would be a lie.
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		warnDroppedPagination(out, globals{all: true}, paginatedReadCommand(50))
		if stderr.Len() != 0 {
			t.Errorf("--all was called ignored on the command that honours it: %q", stderr.String())
		}
	})

	t.Run("the limit/offset arm still works", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		warnDroppedPagination(out, globals{limitSet: true, limit: 7}, plain)
		if !strings.Contains(stderr.String(), "--limit ignored") {
			t.Errorf("the pre-existing limit notice regressed: %q", stderr.String())
		}
	})
}

// The compounding case the row names: an explicit --limit used to SUPPRESS the
// truncation guard entirely, so a page that filled exactly to the limit said
// nothing at all — the flag that was honoured silenced the warning that the
// flag being honoured made necessary.
func TestTruncationGuardSurvivesAnExplicitLimit(t *testing.T) {
	rows := `{"documents":[{"id":"1"},{"id":"2"},{"id":"3"}]}`

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(rows))
	}))
	defer srv.Close()

	run := func(g globals) string {
		var stdout, stderr bytes.Buffer
		out := newWriter(&stdout, &stderr)
		g.output, g.outputSet = "json", true
		out.applyGlobals(g)
		runCommand(out, g, manifest.Context{Server: srv.URL}, &manifest.Manifest{},
			paginatedReadCommand(3), nil)
		return stderr.String()
	}

	t.Run("a page filling an explicit --limit exactly says so", func(t *testing.T) {
		got := run(globals{limitSet: true, limit: 3})
		if !strings.Contains(got, "filled your --limit of 3") {
			t.Errorf("an exactly-full explicit page stayed silent: %q", got)
		}
	})

	t.Run("under the explicit limit stays quiet", func(t *testing.T) {
		if got := run(globals{limitSet: true, limit: 9}); got != "" {
			t.Errorf("a short page warned anyway: %q", got)
		}
	})

	t.Run("the default-limit wording is unchanged", func(t *testing.T) {
		got := run(globals{})
		if !strings.Contains(got, "reached the default limit of 3") {
			t.Errorf("the default-page wording moved: %q", got)
		}
	})

	t.Run("--all still suppresses it", func(t *testing.T) {
		// --all walks every page, so "more may be available" would be false.
		if got := run(globals{all: true}); strings.Contains(got, "may be available") {
			t.Errorf("--all was told its own walk might be truncated: %q", got)
		}
	})
}
