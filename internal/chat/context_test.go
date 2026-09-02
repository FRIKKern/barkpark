package chat

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
)

// context_test.go — the context identity band is a TRUTH surface, not a
// display surface, and these tests are written to tell the two apart. A test
// that only asserts "a context block rendered" passes just as happily against
// six hardcoded strings, which is a green about the wrong subject. So every
// assertion here derives its expectation from the FIXTURE's values — the
// connection the stub transport reports and the probe the model was handed —
// and every failure message says which field went wrong and what it should
// have carried.

// stubTransport is a Transport that answers nothing but Connection(). newModel
// never calls a transport method, so the embedded nil interface is safe and
// deliberate: any future call from newModel panics loudly here rather than
// silently reading zero values.
type stubTransport struct {
	Transport
	conn Connection
}

func (s stubTransport) Connection() Connection { return s.conn }

// mutedTransport reports NO connection (it does not implement
// ConnectionReporter at all) — the "no actual truth exists" arm.
type mutedTransport struct{ Transport }

// fixedProbe is a LocalProbe with canned answers.
func fixedProbe(host, repo string) LocalProbe {
	return LocalProbe{
		Hostname: func() (string, error) { return host, nil },
		RepoRoot: func() (string, error) { return repo, nil },
	}
}

// withProbe swaps the package's local probe for the duration of one test.
func withProbe(t *testing.T, p LocalProbe) {
	t.Helper()
	prev := localProbe
	localProbe = p
	t.Cleanup(func() { localProbe = prev })
}

// TestContextBandShowsTheConnectionNotTheConfig is THE MISMATCH FIXTURE: the
// config claims one server and one scope, the wire client actually carries
// another, and the launch screen must report the disagreement on every field
// where it exists — naming the field, showing the value in USE, and showing
// the value that was CONFIGURED.
//
// This is the assertion a hardcoded context block cannot survive. Every
// expected string is built from the fixture's own values, so a renderer that
// prints a template, or that echoes the config back at the operator, fails
// here no matter how well-formed its output looks.
func TestContextBandShowsTheConnectionNotTheConfig(t *testing.T) {
	withProbe(t, fixedProbe("workbench.local", "/repos/barkpark"))

	cfg := Config{
		BaseURL:   "https://guerrilla.barkpark.cloud",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	}
	// What the client ACTUALLY dials and carries — every field disagrees.
	conn := Connection{
		Endpoint:  "http://127.0.0.1:4000",
		Workspace: "default",
		Project:   "default",
		Dataset:   "staging",
	}
	m := newModel(stubTransport{conn: conn}, nil, cfg)
	m.width, m.height = 120, 40
	frame := m.renderPicker()
	// `go test -v` prints the disagreeing launch frame — the one screen an
	// operator most needs to recognise, and the hardest to describe in prose.
	t.Logf("launch frame while the config and the connection disagree:\n%s", frame)

	for _, tc := range []struct{ field, inUse, configured string }{
		{"server", conn.Endpoint, cfg.BaseURL},
		{"workspace", conn.Workspace, cfg.Workspace},
		{"project", conn.Project, cfg.Project},
		{"dataset", conn.Dataset, cfg.Dataset},
	} {
		t.Run(tc.field, func(t *testing.T) {
			want := fmt.Sprintf("⚠ %s %s — configured %q", tc.field, tc.inUse, tc.configured)
			if !strings.Contains(frame, want) {
				t.Errorf("the %s the launch screen shows is not the %s the client is on: "+
					"the wire client uses %q while the config says %q, and the frame carries no %q — "+
					"a surface that prints the config while the connection is somewhere else "+
					"is exactly how a wrong connection reads as a right one.\nframe:\n%s",
					tc.field, tc.field, tc.inUse, tc.configured, want, frame)
			}
			// And the configured value must never stand ALONE as the field's
			// value: that is the template rendering, dressed as truth.
			if bare := tc.field + " " + tc.configured; strings.Contains(frame, bare) &&
				!strings.Contains(frame, "⚠ "+bare) {
				t.Errorf("the frame presents %q as the live %s, but the client actually uses %q — "+
					"the config's claim was displayed as if it were the connection.\nframe:\n%s",
					bare, tc.field, tc.inUse, frame)
			}
		})
	}
}

// TestContextBandIsSilentWhenConfigAndConnectionAgree is the non-vacuity twin
// of the mismatch fixture: the ⚠ must be EARNED. Without this, a renderer that
// flags every field unconditionally would pass the test above while telling an
// operator on a perfectly healthy connection that something is wrong.
func TestContextBandIsSilentWhenConfigAndConnectionAgree(t *testing.T) {
	withProbe(t, fixedProbe("workbench.local", "/repos/barkpark"))

	cfg := Config{
		BaseURL:   "https://guerrilla.barkpark.cloud",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "production",
	}
	conn := Connection{
		Endpoint:  cfg.BaseURL,
		Workspace: cfg.Workspace,
		Project:   cfg.Project,
		Dataset:   cfg.Dataset,
	}
	m := newModel(stubTransport{conn: conn}, nil, cfg)
	m.width, m.height = 120, 40
	frame := m.renderPicker()

	if strings.Contains(frame, "⚠") {
		t.Errorf("config and connection agree on every field, so the band must claim no "+
			"disagreement — an unconditional ⚠ makes the mismatch signal worthless.\nframe:\n%s", frame)
	}
	for _, want := range []string{
		"server " + cfg.BaseURL,
		"workspace " + cfg.Workspace,
		"project " + cfg.Project,
		"dataset " + cfg.Dataset,
	} {
		if !strings.Contains(frame, want) {
			t.Errorf("agreeing field must still render its value %q\nframe:\n%s", want, frame)
		}
	}
}

// TestContextBandRefusesToPassASubstitutedDefaultOffAsAChoice pins the most
// dangerous single case in the whole surface. apiclient.New silently
// substitutes default/default/production for an EMPTY scope, so a naive band
// reading the client would print the word "production" for a dataset nobody
// ever chose — a plausible-looking default, indistinguishable from a decision,
// sitting exactly where a wrong connection hides.
//
// The absence must stay the headline, and the substitution must be reported.
func TestContextBandRefusesToPassASubstitutedDefaultOffAsAChoice(t *testing.T) {
	withProbe(t, fixedProbe("workbench.local", "/repos/barkpark"))

	// Nothing configured: the CLI resolved no scope at all.
	cfg := Config{BaseURL: "https://guerrilla.barkpark.cloud"}
	// The real apiclient substitution, verbatim.
	conn := Connection{
		Endpoint:  cfg.BaseURL,
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
	}
	m := newModel(stubTransport{conn: conn}, nil, cfg)
	m.width, m.height = 120, 40
	frame := m.renderPicker()

	for _, tc := range []struct{ field, substituted string }{
		{"workspace", conn.Workspace},
		{"project", conn.Project},
		{"dataset", conn.Dataset},
	} {
		t.Run(tc.field, func(t *testing.T) {
			want := fmt.Sprintf("⚠ %s %s — the connection uses %q", tc.field, absentUnset, tc.substituted)
			if !strings.Contains(frame, want) {
				t.Errorf("nothing configured %s, and the client substituted %q — the band must show "+
					"the ABSENCE (%s) and report the substitution, i.e. %q. A substituted default "+
					"rendered as a bare value reads as a deliberate choice.\nframe:\n%s",
					tc.field, tc.substituted, absentUnset, want, frame)
			}
			if bare := tc.field + " " + tc.substituted; strings.Contains(frame, bare) {
				t.Errorf("the band printed %q for a %s nobody configured — that is the "+
					"plausible-default lie this field exists to prevent.\nframe:\n%s",
					bare, tc.field, frame)
			}
		})
	}
}

// TestContextAbsenceIsTypedAndNeverBlank proves the three-way status is real:
// a value, a measured absence, and an unmeasurable field each render
// DIFFERENTLY, and none of them renders as an empty string. A blank where a
// value belongs is the failure mode; so is UNSET and UNKNOWN collapsing into
// one marker, because "there is no repo" and "I could not run git" send an
// operator to different places.
func TestContextAbsenceIsTypedAndNeverBlank(t *testing.T) {
	// Every arm of every field, exercised through the resolver.
	cases := []struct {
		name    string
		field   ContextField
		status  FieldStatus
		display string
	}{
		{"host unknown", hostField(LocalProbe{
			Hostname: func() (string, error) { return "", errors.New("no hostname") },
		}), FieldUnknown, absentUnknown},
		{"host blank is unknown, not a value", hostField(LocalProbe{
			Hostname: func() (string, error) { return "   ", nil },
		}), FieldUnknown, absentUnknown},
		{"repo determinately absent", repoField(LocalProbe{
			RepoRoot: func() (string, error) { return "", ErrNotARepo },
		}), FieldUnset, absentNoRepo},
		{"repo unmeasurable", repoField(LocalProbe{
			RepoRoot: func() (string, error) { return "", errors.New("git: not found") },
		}), FieldUnknown, absentUnknown},
		{"no probe at all is unknown", hostField(LocalProbe{}), FieldUnknown, absentUnknown},
		{"server unresolvable", reconciled("server", "", ""), FieldUnset, absentUnset},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.field.Status != tc.status {
				t.Errorf("%s: status %v, want %v — the three arms must stay distinct",
					tc.field.Name, tc.field.Status, tc.status)
			}
			got := tc.field.Display()
			if got == "" {
				t.Fatalf("%s rendered the EMPTY STRING where a value belongs — the one "+
					"output this surface may never produce", tc.field.Name)
			}
			if got != tc.display {
				t.Errorf("%s displayed %q, want the marker %q", tc.field.Name, got, tc.display)
			}
		})
	}

	// The markers must be pairwise distinct, or the typing buys nothing.
	markers := map[string]string{"unset": absentUnset, "unknown": absentUnknown, "no repo": absentNoRepo}
	seen := map[string]string{}
	for name, marker := range markers {
		if other, dup := seen[marker]; dup {
			t.Errorf("%q and %q render the SAME marker %q — a reader cannot tell "+
				"a measured absence from an unmeasurable field", name, other, marker)
		}
		seen[marker] = name
	}

	// And the absence must reach the PAINT, not just the struct.
	withProbe(t, LocalProbe{
		Hostname: func() (string, error) { return "", errors.New("boom") },
		RepoRoot: func() (string, error) { return "", ErrNotARepo },
	})
	m := newModel(mutedTransport{}, nil, Config{})
	m.width, m.height = 120, 40
	frame := m.renderPicker()
	for _, want := range []string{
		"host " + absentUnknown,
		"server " + absentUnset,
		"dataset " + absentUnset,
		"repo " + absentNoRepo,
	} {
		if !strings.Contains(frame, want) {
			t.Errorf("an absent field must be VISIBLY absent: expected %q in the launch "+
				"frame.\nframe:\n%s", want, frame)
		}
	}
}

// TestContextBandCarriesEveryField is the BY-NAME plumbing guard. Each field
// gets a sentinel value that appears nowhere else, and each is asserted
// independently — so severing the wire that carries ONE field from the
// resolved connection to the surface reds exactly one subtest, and its message
// says which field vanished. A guard that only reds "the context block
// changed" leaves an operator to go find out which fact they lost.
func TestContextBandCarriesEveryField(t *testing.T) {
	const (
		host      = "sentinel-host"
		repo      = "/sentinel/repo/root"
		server    = "https://sentinel-server.example"
		workspace = "sentinel-workspace"
		project   = "sentinel-project"
		dataset   = "sentinel-dataset"
	)
	withProbe(t, fixedProbe(host, repo))

	cfg := Config{BaseURL: server, Workspace: workspace, Project: project, Dataset: dataset}
	conn := Connection{Endpoint: server, Workspace: workspace, Project: project, Dataset: dataset}
	m := newModel(stubTransport{conn: conn}, nil, cfg)
	m.width, m.height = 120, 40
	frame := m.renderPicker()

	for _, tc := range []struct{ field, value string }{
		{"host", host},
		{"server", server},
		{"workspace", workspace},
		{"project", project},
		{"dataset", dataset},
		{"repo", repo},
	} {
		t.Run(tc.field, func(t *testing.T) {
			want := tc.field + " " + tc.value
			if !strings.Contains(frame, want) {
				t.Errorf("`bp chat` no longer shows the %q field: the launch frame must carry "+
					"%q, and does not. The plumbing that carries %q from the resolved "+
					"connection to the surface is broken — an operator reading this screen "+
					"cannot tell which %s they are on.\nframe:\n%s",
					tc.field, want, tc.field, tc.field, frame)
			}
			f, ok := m.ctxid.Field(tc.field)
			if !ok {
				t.Fatalf("the resolved identity carries no %q field at all", tc.field)
			}
			if f.Status != FieldSet || f.Value != tc.value {
				t.Errorf("the %q field resolved to %v/%q, want a real value %q",
					tc.field, f.Status, f.Value, tc.value)
			}
		})
	}
}

// TestHTTPTransportReportsTheConnectionItDials closes the last gap in the
// chain: the band is only as honest as the witness it reconciles against, and
// the witness is the REAL transport reading the REAL wire client. Config in,
// client built, client asked — no config value is copied along the way.
func TestHTTPTransportReportsTheConnectionItDials(t *testing.T) {
	cfg := Config{
		BaseURL:   "https://guerrilla.barkpark.cloud",
		Token:     "tok",
		Workspace: "acme",
		Project:   "site",
		Dataset:   "staging",
	}
	tr := NewHTTPTransport(cfg)
	r, ok := tr.(ConnectionReporter)
	if !ok {
		t.Fatalf("the real transport must be able to report what it dials — without it "+
			"the launch screen has nothing to reconcile the config against (%T)", tr)
	}
	want := Connection{Endpoint: cfg.BaseURL, Workspace: cfg.Workspace, Project: cfg.Project, Dataset: cfg.Dataset}
	if got := r.Connection(); got != want {
		t.Errorf("the wire client carries %+v, the config asked for %+v — the two must "+
			"agree by construction, or every reconciliation downstream is noise", got, want)
	}

	// An EMPTY scope is where apiclient substitutes defaults. The transport must
	// report the substitution rather than an empty string: that is the fact the
	// band turns into a visible "nothing was configured; the client uses X".
	bare := NewHTTPTransport(Config{BaseURL: "http://localhost:4000"})
	got := bare.(ConnectionReporter).Connection()
	if got.Dataset == "" {
		t.Fatalf("the client's EFFECTIVE dataset must be reported, substitution included; "+
			"got %+v", got)
	}
	f := reconciled("dataset", "", got.Dataset)
	if !f.Mismatch || f.Status != FieldUnset {
		t.Errorf("an unconfigured dataset that the client silently defaults to %q must "+
			"resolve to an UNSET field with a reported substitution, got %+v", got.Dataset, f)
	}
}

// TestGitRepoRootProbeMeasuresTheRepo proves the repo root is MEASURED, not
// configured — and that git answering "not a work tree" is kept apart from git
// never answering. The first is an absence; the second is ignorance.
func TestGitRepoRootProbeMeasuresTheRepo(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	root, err := probeGitRepoRootIn(wd)
	if err != nil {
		t.Fatalf("the test runs inside this repo, so the probe must find its root: %v", err)
	}
	if !strings.HasPrefix(wd, root) {
		t.Errorf("probed root %q is not an ancestor of the working directory %q — "+
			"the repo field would name a checkout nobody is in", root, wd)
	}

	// A directory outside any work tree: a DETERMINATE absence.
	if _, err := probeGitRepoRootIn(t.TempDir()); !errors.Is(err, ErrNotARepo) {
		t.Errorf("outside a work tree the probe must answer ErrNotARepo (a measured "+
			"absence the band renders as %q), got %v", absentNoRepo, err)
	}
}
