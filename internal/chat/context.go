package chat

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// context.go — WHICH HOST IS TALKING TO WHICH SERVER.
//
// `bp chat` is one client among many servers, workspaces and repos, and the
// terminal it opens in says nothing about which of them it reached. This file
// resolves the full context identity the launch screen paints: the LOCAL
// execution host and repository root (probed off this machine), and the
// server / workspace / project / dataset the wire client is actually pointed
// at. render.go's contextLines paints it; nothing here renders.
//
// Two laws hold the surface honest, and both are load-bearing:
//
//  1. A DISPLAYED VALUE COMES FROM THE ACTUAL CONNECTION wherever an actual
//     truth exists. The live apiclient.Client reports the endpoint it dials
//     and the scope it carries (Connection / ConnectionReporter); the repo
//     root comes from `git rev-parse --show-toplevel`, never from a config
//     string. Where the config's claim and the connection DISAGREE the field
//     renders the CONNECTION's value and reports the disagreement beside it.
//     A surface that prints config while the wire uses something else is
//     precisely how a wrong connection reads as a right one.
//
//  2. ABSENCE IS VISIBLE AND TYPED. UNSET (measured — nothing is configured)
//     and UNKNOWN (the probe could not answer) are different facts, render
//     differently, and neither ever renders as a blank or as a plausible
//     default. This matters most on scope: apiclient.New silently substitutes
//     default/default/production for an empty workspace/project/dataset, so an
//     unset dataset would otherwise reach the eye as the word "production" —
//     the single value most likely to be wrong, wearing the costume of a
//     deliberate choice. The absence stays the headline and the substitution
//     is reported next to it.
//
// The scope fields are CONFIG-RESOLVED, not server-reported, and that is a
// fact about the wire and not a shortcut: the /v1/chat routes are flat and
// data-plane-token scoped (charter D3/D21), so the server has no
// workspace/project/dataset of its own to report back for this plane. The
// resolution itself is `bp whoami`'s — manifest.Context, handed in as
// chat.Config by internal/cli — never a second config reader.

// FieldStatus is the three-way answer to "do we have this value?". The middle
// arm is the whole point: "measured, and there is nothing" is a different fact
// from "could not measure", and an operator staring at a wrong connection needs
// to know which one they are looking at.
type FieldStatus int

const (
	// FieldUnknown — the probe could not answer (git missing, hostname call
	// failed, no transport to ask). NOT evidence that the value is empty.
	FieldUnknown FieldStatus = iota
	// FieldUnset — measured, and nothing is configured.
	FieldUnset
	// FieldSet — a real value.
	FieldSet
)

// The absence markers. They are distinct strings on purpose (law 2): a reader
// must be able to tell "nothing is set" from "I could not tell" from a real
// value at a glance, and none of them can be mistaken for a value.
const (
	absentUnset   = "(not set)"
	absentUnknown = "(unknown)"
	absentNoRepo  = "(not a git repo)"
)

// ContextField is one line-item of the identity: a name, a three-way status,
// the value when there is one, the visible marker when there is not, and — when
// the config's claim and the connection disagree — the disagreement, in text.
type ContextField struct {
	// Name is the label the surface prints and the name a guard reds by.
	Name string
	// Status says which of the three arms this field is in.
	Status FieldStatus
	// Value is the DISPLAYED value: the connection's actual value when one is
	// known, else the config's claim. Meaningful only when Status is FieldSet.
	Value string
	// Absent is the marker rendered when Status is not FieldSet. Never empty.
	Absent string
	// Note is the disagreement report, empty when nothing disagrees.
	Note string
	// Mismatch is true when the config's claim and the connection's actual
	// value disagree — including the "config said nothing, the client
	// substituted a default" case, which is a disagreement about the most
	// dangerous value in the set.
	Mismatch bool
}

// Display is the field's rendered text. It can NEVER return an empty string:
// a surface that renders "" where a value belongs is the exact failure mode
// this file exists to prevent, so the fallback is the loudest honest marker
// rather than a blank.
func (f ContextField) Display() string {
	v := f.Value
	if f.Status != FieldSet || v == "" {
		v = f.Absent
	}
	if v == "" {
		v = absentUnknown
	}
	if f.Note != "" {
		v += " " + f.Note
	}
	return v
}

// ContextIdentity is the whole answer, in paint order.
type ContextIdentity struct {
	Fields []ContextField
}

// Field returns the named field. The lookup exists so tests and future callers
// address a field BY NAME rather than by position — a positional read is how a
// reordered slice turns into a silently wrong reading.
func (ci ContextIdentity) Field(name string) (ContextField, bool) {
	for _, f := range ci.Fields {
		if f.Name == name {
			return f, true
		}
	}
	return ContextField{}, false
}

// Mismatches are the fields whose config claim and actual connection disagree.
func (ci ContextIdentity) Mismatches() []ContextField {
	var out []ContextField
	for _, f := range ci.Fields {
		if f.Mismatch {
			out = append(out, f)
		}
	}
	return out
}

// Connection is what the LIVE wire client reports about the connection it
// actually dials — the endpoint it sends to and the scope it carries. It is
// read off the running apiclient.Client, never off the Config struct, so a
// transport built against a different server or a different scope than the
// config named shows up as a disagreement instead of hiding behind a matching
// string.
type Connection struct {
	Endpoint  string
	Workspace string
	Project   string
	Dataset   string
}

// ConnectionReporter is the OPTIONAL half of Transport: a transport that can
// report the connection it dials. It is asserted, never required — folding it
// into Transport would force every fake in the suite to grow a method it has
// nothing truthful to say about, and a fake inventing an endpoint is worse than
// a fake reporting none. A transport that does not implement it yields the zero
// Connection, i.e. "no actual truth for these fields", and the surface then
// shows the config's claim unreconciled rather than inventing agreement.
type ConnectionReporter interface {
	Connection() Connection
}

// connectionOf asks a Transport what it dials, or returns the zero Connection.
func connectionOf(tr Transport) Connection {
	if r, ok := tr.(ConnectionReporter); ok {
		return r.Connection()
	}
	return Connection{}
}

// ErrNotARepo is the DETERMINATE answer "this directory is not inside a git
// work tree" — distinct from every other git failure, which means "could not
// measure". The distinction is the difference between FieldUnset and
// FieldUnknown on the repo field.
var ErrNotARepo = errors.New("not a git repository")

// LocalProbe is the local-machine seam: the two facts no server can report,
// measured off the process that is running. Injected as a package var so tests
// drive every arm — a value, a determinate absence, a failed probe — without
// needing a machine that happens to be in that state.
type LocalProbe struct {
	Hostname func() (string, error)
	RepoRoot func() (string, error)
}

// localProbe is the process's real local truth. Tests swap it and restore it.
var localProbe = LocalProbe{Hostname: os.Hostname, RepoRoot: gitRepoRoot}

// gitTimeout bounds the git probe. `bp chat` must not sit on a black screen
// because a network filesystem made rev-parse hang; a timeout is UNKNOWN, and
// unknown is a thing the surface can say.
const gitTimeout = 3 * time.Second

var (
	repoRootOnce sync.Once
	repoRootVal  string
	repoRootErr  error
)

// gitRepoRoot is the process-wide memoised repo-root probe. The working
// directory does not move under a running `bp chat`, so the answer is resolved
// once and shared — one exec per process, not one per model.
func gitRepoRoot() (string, error) {
	repoRootOnce.Do(func() {
		dir, err := os.Getwd()
		if err != nil {
			repoRootErr = err
			return
		}
		repoRootVal, repoRootErr = probeGitRepoRootIn(dir)
	})
	return repoRootVal, repoRootErr
}

// probeGitRepoRootIn asks git for dir's work-tree root. It separates the two
// failures that look identical from the outside: git ANSWERING "not a work
// tree" (exit 128 → ErrNotARepo, a determinate absence) from git never
// answering at all (missing binary, timeout, permission → the raw error, an
// unknown). Collapsing them would let "I could not run git" reach the eye as
// "you are not in a repo".
func probeGitRepoRootIn(dir string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 128 {
			return "", ErrNotARepo
		}
		return "", err
	}
	root := strings.TrimSpace(string(out))
	if root == "" {
		return "", ErrNotARepo
	}
	return root, nil
}

// ResolveContextIdentity builds the identity `bp chat` paints: the local host
// and repo root from probe, and the server/workspace/project/dataset
// reconciled between what the CLI resolved (cfg) and what the wire client
// actually carries (conn). Pure apart from probe, which owns every syscall.
func ResolveContextIdentity(cfg Config, conn Connection, probe LocalProbe) ContextIdentity {
	return ContextIdentity{Fields: []ContextField{
		hostField(probe),
		reconciled("server", cfg.BaseURL, conn.Endpoint),
		reconciled("workspace", cfg.Workspace, conn.Workspace),
		reconciled("project", cfg.Project, conn.Project),
		reconciled("dataset", cfg.Dataset, conn.Dataset),
		repoField(probe),
	}}
}

// hostField is the local execution host — the machine this `bp chat` process
// runs on. There is no config claim to reconcile against and no server truth
// for it: the server never learns the client's hostname, so a probe failure is
// UNKNOWN and never a guess.
func hostField(probe LocalProbe) ContextField {
	f := ContextField{Name: "host", Status: FieldUnknown, Absent: absentUnknown}
	if probe.Hostname == nil {
		return f
	}
	h, err := probe.Hostname()
	if h = strings.TrimSpace(h); err != nil || h == "" {
		return f
	}
	f.Status, f.Value = FieldSet, h
	return f
}

// repoField is the repository root of the directory `bp chat` was launched
// from — measured with git, never configured. "Not a repo" is a real, useful
// answer (you are chatting from outside a checkout) and is rendered as such;
// a git probe that could not run is UNKNOWN and says so.
func repoField(probe LocalProbe) ContextField {
	f := ContextField{Name: "repo", Status: FieldUnknown, Absent: absentUnknown}
	if probe.RepoRoot == nil {
		return f
	}
	root, err := probe.RepoRoot()
	root = strings.TrimSpace(root)
	switch {
	case errors.Is(err, ErrNotARepo):
		f.Status, f.Absent = FieldUnset, absentNoRepo
	case err != nil || root == "":
		// left UNKNOWN — the probe did not answer, which is not an absence.
	default:
		f.Status, f.Value = FieldSet, root
	}
	return f
}

// reconciled builds one field whose displayed value is what the CONNECTION
// actually uses, with the config's claim reported beside it whenever the two
// disagree. The four arms are each a distinct fact:
//
//   - neither: UNSET, plainly.
//   - config silent, connection carrying a value: the client substituted a
//     default nobody chose (apiclient.New does exactly this for scope). The
//     ABSENCE is the headline and the substitution is reported — showing
//     "production" alone here would be the plausible-default lie.
//   - connection silent: no actual truth exists for this field, so the
//     config's claim stands UNRECONCILED and nothing extra is claimed.
//   - both, disagreeing: the connection's value is the truth and the config's
//     claim is reported as the thing that is wrong.
func reconciled(name, declared, actual string) ContextField {
	declared, actual = strings.TrimSpace(declared), strings.TrimSpace(actual)
	f := ContextField{Name: name, Absent: absentUnset}
	switch {
	case declared == "" && actual == "":
		f.Status = FieldUnset
	case declared == "":
		f.Status = FieldUnset
		f.Mismatch = true
		f.Note = fmt.Sprintf("— the connection uses %q", actual)
	case actual == "", actual == declared:
		f.Status, f.Value = FieldSet, declared
	default:
		f.Status, f.Value = FieldSet, actual
		f.Mismatch = true
		f.Note = fmt.Sprintf("— configured %q", declared)
	}
	return f
}
