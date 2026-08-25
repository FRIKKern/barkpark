package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// REMAINDER B of the CLI honesty wave (task-d5640a667988b1d1), second half.
//
// The knob-refusal itself lives in pagination_drop_test.go, which owns the
// inverted contract. This file owns the COMPOUNDING case the row names, which
// is a different defect on a command that DOES honour its knobs:
// warnIfDefaultPageMayBeTruncated returned early on `g.limitSet`, so a page
// that filled exactly to an explicit --limit said nothing at all. The flag that
// was honoured silenced the warning that the flag being honoured made
// necessary.
//
// An explicit limit now SETS the threshold instead of suppressing the check.
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
		// It is also HONOURED here (a paginated read), so the knob refusal in
		// refuseDroppedKnobs must not fire either — this subtest covers both.
		if got := run(globals{all: true}); strings.Contains(got, "may be available") {
			t.Errorf("--all was told its own walk might be truncated: %q", got)
		}
	})
}
