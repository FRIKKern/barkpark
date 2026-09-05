package manifest

import (
	"encoding/json"
	"os"
	"testing"
)

// liveFixture is a slimmed capture of GET /v1/capabilities from
// guerrilla.barkpark.cloud on 2026-09-04 (admin tier, 207 commands) — id, noun,
// verb, auth_tier, http.method/path_template, arg+flag NAMES, writes, and
// scoped_prefix. Everything the scope rules read, nothing they don't.
//
// It is checked in so the manifest-wide enumeration below is a real sweep of a
// real server's surface rather than of three hand-written table rows, and so it
// runs offline and deterministically.
const liveFixture = "testdata/capabilities-guerrilla-2026-09-04.json"

func loadFixture(t *testing.T) *Manifest {
	t.Helper()
	raw, err := os.ReadFile(liveFixture)
	if err != nil {
		t.Fatalf("read %s: %v", liveFixture, err)
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("decode %s: %v", liveFixture, err)
	}
	if len(m.Commands) < 100 {
		t.Fatalf("fixture holds %d commands — too few to be the live surface; the sweep below would be vacuous", len(m.Commands))
	}
	return &m
}

func statedCtx(ws, prj string) Context {
	return Context{
		Server:            "https://s.example",
		Workspace:         ws,
		Project:           prj,
		Dataset:           "production",
		WorkspaceExplicit: true,
		ProjectExplicit:   true,
	}
}

func strptr(s string) *string { return &s }

// fixtureCommand looks one command up by id. The Manifest type carries no
// by-id index, and the sweep tests want to name their witnesses.
func fixtureCommand(m *Manifest, id string) (Command, bool) {
	for _, c := range m.Commands {
		if c.ID == id {
			return c, true
		}
	}
	return Command{}, false
}

// ── c0, the honest path ──────────────────────────────────────────────────────

// TestStatedScopeRoutesThroughTheAdvertisedMirror is the first half of c0: a
// flat-tier command that ADVERTISES a scoped_prefix stops sending the flat URL
// once the operator names a non-floor workspace, and goes to the mirror
// instead. doc.ls is the live inhabitant — auth_tier "none", flat template, and
// a "/w/:workspace_slug/p/:project_slug" prefix in the shipped manifest.
//
// The mirror is not hypothetical: on guerrilla, /v1/data/query/production/task
// and /w/default/p/default/v1/data/query/production/task both answer 200 with
// an identical body, and /w/<a-workspace-you-are-not-in>/... answers 403
// not_a_member.
func TestStatedScopeRoutesThroughTheAdvertisedMirror(t *testing.T) {
	m := loadFixture(t)
	cmd, ok := fixtureCommand(m, "doc.ls")
	if !ok {
		t.Fatal("fixture has no doc.ls — the honest-path witness is gone")
	}
	if cmd.ScopedPrefix == nil || *cmd.ScopedPrefix == "" {
		t.Fatalf("doc.ls carries no scoped_prefix in the fixture; this test proves nothing")
	}
	if isScopedTier(cmd.AuthTier) {
		t.Fatalf("doc.ls auth_tier = %q — a scoped tier already composed the prefix before this change, so it is the wrong witness", cmd.AuthTier)
	}
	if got := ScopeFateFor(cmd); got != ScopeMirrored {
		t.Fatalf("ScopeFateFor(doc.ls) = %v, want %v", got, ScopeMirrored)
	}

	args := map[string]string{"type": "task"}

	// Floor scope: unchanged, byte-identical to the pre-change behaviour.
	flat, err := m.BuildURL(cmd, statedCtx("default", "default"), args)
	if err != nil {
		t.Fatalf("BuildURL at the floor: %v", err)
	}
	if want := "https://s.example/v1/data/query/production/task"; flat != want {
		t.Errorf("floor scope URL = %q, want %q (no existing invocation may change shape)", flat, want)
	}

	// Stated non-floor scope: the request goes to the mirror, carrying the slugs.
	scoped, err := m.BuildURL(cmd, statedCtx("gyldendal", "books"), args)
	if err != nil {
		t.Fatalf("BuildURL with a stated scope: %v", err)
	}
	want := "https://s.example/w/gyldendal/p/books/v1/data/query/production/task"
	if scoped != want {
		t.Errorf("stated-scope URL = %q, want %q", scoped, want)
	}
	if scoped == flat {
		t.Error("`-w gyldendal` produced the SAME URL as the default workspace — this is the filed bug, unfixed")
	}
}

// TestFloorScopeNeverRoutesThroughTheMirror pins the blast radius: provenance
// alone must not arm the re-route. A saved context or a BARKPARK_WORKSPACE that
// is set to the floor value marks the Context explicit, and every operator has
// one — if that were enough, every bp invocation on the planet would change URL.
func TestFloorScopeNeverRoutesThroughTheMirror(t *testing.T) {
	m := loadFixture(t)
	cmd, _ := fixtureCommand(m, "doc.ls")
	for _, tc := range []struct {
		name string
		ctx  Context
	}{
		{"explicit but floor-valued", statedCtx("default", "default")},
		{"not explicit at all", Context{Server: "https://s.example", Workspace: "gyldendal", Project: "books", Dataset: "production"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := StatedScope(tc.ctx); len(got) != 0 {
				t.Fatalf("StatedScope = %v, want empty", got)
			}
			got, err := m.BuildURL(cmd, tc.ctx, map[string]string{"type": "task"})
			if err != nil {
				t.Fatalf("BuildURL: %v", err)
			}
			if want := "https://s.example/v1/data/query/production/task"; got != want {
				t.Errorf("URL = %q, want the unchanged flat %q", got, want)
			}
		})
	}
}

// ── c0, the refused path ─────────────────────────────────────────────────────

// TestUnrepresentableStatedScopeIsRefused is the second half of c0. task.ls has
// no scope placeholder in its path AND no advertised scoped_prefix, so there is
// no URL that answers "the tasks in workspace gyldendal". The fate is Refused
// and the CLI (internal/cli/scope_honesty.go) turns that into a usage-shaped
// error before any I/O.
func TestUnrepresentableStatedScopeIsRefused(t *testing.T) {
	m := loadFixture(t)
	cmd, ok := fixtureCommand(m, "task.ls")
	if !ok {
		t.Fatal("fixture has no task.ls — the refused-path witness is gone")
	}
	if cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" {
		t.Fatalf("task.ls now advertises a scoped_prefix (%q) — it is no longer the refused-path witness; pick another", *cmd.ScopedPrefix)
	}
	if got := ScopeFateFor(cmd); got != ScopeRefused {
		t.Fatalf("ScopeFateFor(task.ls) = %v, want %v", got, ScopeRefused)
	}
	// And at the floor there is nothing to refuse.
	if got := ScopeFateFor(cmd); got != ScopeRefused {
		t.Fatalf("fate is a property of the COMMAND, not the ctx: got %v", got)
	}
	if got := StatedScope(statedCtx("default", "default")); len(got) != 0 {
		t.Errorf("floor scope on a refused command still reports %v — it must be silent", got)
	}
}

// TestScopeCarriedCommandsAreLeftAlone: a command whose own path reads the
// workspace already honours -w and must neither be re-routed nor refused.
func TestScopeCarriedCommandsAreLeftAlone(t *testing.T) {
	m := loadFixture(t)
	for _, id := range []string{"workspace.project-ls", "token.ls"} {
		cmd, ok := fixtureCommand(m, id)
		if !ok {
			t.Fatalf("fixture has no %s", id)
		}
		if got := ScopeFateFor(cmd); got != ScopeCarried {
			t.Errorf("ScopeFateFor(%s) = %v, want %v", id, got, ScopeCarried)
		}
	}
}

// TestScopeFateIsTotal — the whole point of the four-way classification is that
// there is no fifth outcome and no command falls out of the switch.
func TestScopeFateIsTotal(t *testing.T) {
	m := loadFixture(t)
	seen := map[ScopeFate]int{}
	for _, cmd := range m.Commands {
		f := ScopeFateFor(cmd)
		switch f {
		case ScopeCarried, ScopeMirrored, ScopeUnscopedByDesign, ScopeRefused:
			seen[f]++
		default:
			t.Fatalf("%s got an unknown fate %d", cmd.ID, int(f))
		}
	}
	for _, f := range []ScopeFate{ScopeCarried, ScopeMirrored, ScopeUnscopedByDesign, ScopeRefused} {
		if seen[f] == 0 {
			t.Errorf("no command in the live surface classifies as %v — the case is untested by this sweep", f)
		}
	}
	t.Logf("live surface (%d commands): carried=%d mirrored=%d unscoped-by-design=%d refused=%d",
		len(m.Commands), seen[ScopeCarried], seen[ScopeMirrored], seen[ScopeUnscopedByDesign], seen[ScopeRefused])
}

// ── c2, the manifest-wide enumeration ────────────────────────────────────────

// TestEveryUnscopableCommandIsDeclared is the tripwire c2 asks for. It sweeps
// EVERY command in the shipped manifest, keeps the ones whose URL can neither
// carry nor mirror a stated -w/-p, and requires each one to have an explicit
// declaration — with a reason — in scopeDispositions (or an override).
//
// A future command that quietly drops the scope has no declaration, so it lands
// here as a RED with its own id in the message. Mutation-proved: appending a
// fake flat verb under an undeclared noun to the fixture's command list reds
// this test and nothing else.
func TestEveryUnscopableCommandIsDeclared(t *testing.T) {
	m := loadFixture(t)
	assertEveryUnscopableCommandIsDeclared(t, m.Commands)
}

func assertEveryUnscopableCommandIsDeclared(t *testing.T, cmds []Command) {
	t.Helper()
	checked := 0
	for _, cmd := range cmds {
		if commandCarriesScope(cmd) {
			continue
		}
		if cmd.ScopedPrefix != nil && *cmd.ScopedPrefix != "" {
			continue
		}
		checked++
		d, ok := ScopeDispositionFor(cmd)
		if !ok {
			t.Errorf("%s (noun %q) can neither carry nor mirror a stated -w/-p and is UNDECLARED. "+
				"Add an entry to scopeDispositions in internal/manifest/scope.go: `refuse` (Unscoped:false) "+
				"unless the flag is meaningless for it by construction, and say why in Reason.",
				cmd.ID, cmd.Noun)
			continue
		}
		if d.Reason == "" {
			t.Errorf("%s (noun %q) is declared with an EMPTY reason — the declaration is the record of why the flag cannot land, so it has to say something", cmd.ID, cmd.Noun)
		}
	}
	if checked == 0 {
		t.Fatal("swept 0 unscopable commands — the enumeration is vacuous")
	}
	t.Logf("swept %d unscopable commands across %d declared nouns", checked, len(DeclaredScopeNouns()))
}

// TestUndeclaredFlatVerbRedsTheEnumeration is the non-vacuity proof for the
// tripwire above: it runs the SAME assertion against the live surface plus one
// fake flat verb under a noun nobody has declared, and requires it to fail.
// If the enumeration ever goes blind, this test goes red first and names it.
func TestUndeclaredFlatVerbRedsTheEnumeration(t *testing.T) {
	m := loadFixture(t)
	fake := Command{
		ID:       "quokka.stats",
		Noun:     "quokka",
		Verb:     "stats",
		AuthTier: "read",
		HTTP:     HTTP{Method: "GET", PathTemplate: "/v1/quokka/stats"},
	}
	probe := &testing.T{}
	assertEveryUnscopableCommandIsDeclared(probe, append(append([]Command{}, m.Commands...), fake))
	if !probe.Failed() {
		t.Fatal("a flat verb under an UNDECLARED noun passed the enumeration — the c2 tripwire is blind")
	}
}

// TestDeclaredNounsAllExistInTheShippedManifest keeps the table from growing
// stale entries that no longer describe anything. A declaration is a claim
// about a real command family; if the family is gone, so is the claim.
func TestDeclaredNounsAllExistInTheShippedManifest(t *testing.T) {
	m := loadFixture(t)
	live := map[string]bool{}
	for _, cmd := range m.Commands {
		live[cmd.Noun] = true
	}
	for _, n := range DeclaredScopeNouns() {
		if !live[n] {
			t.Errorf("scopeDispositions declares noun %q, which no command in the shipped manifest uses — drop the entry", n)
		}
	}
}

// TestScopeAliasesAreWholeTokens guards the short aliases: ":p" is a prefix of
// :paper_id/:plugin/:path, so a substring test would report "this route reads
// the project scope" on the strength of an unrelated segment and re-route or
// refuse a command that never reads scope at all.
func TestScopeAliasesAreWholeTokens(t *testing.T) {
	decoy := Command{
		ID:       "decoy.get",
		Noun:     "decoy",
		AuthTier: "read",
		HTTP:     HTTP{Method: "GET", PathTemplate: "/v1/plugins/:plugin/papers/:paper_id"},
	}
	if commandCarriesScope(decoy) {
		t.Error("a path with :plugin/:paper_id was read as carrying the project scope — the alias match is a substring test again")
	}
	real := Command{
		ID:       "real.get",
		Noun:     "real",
		AuthTier: "read",
		HTTP:     HTTP{Method: "GET", PathTemplate: "/w/:ws/p/:p/v1/thing"},
	}
	if !commandCarriesScope(real) {
		t.Error("a path with the :ws/:p aliases was NOT read as carrying scope")
	}
}

// TestStatedScopeReportsOnlyTheDivergentFlag — a stated workspace with a
// floor-valued project must report "-w" alone, so the refusal names the flag
// the operator actually typed.
func TestStatedScopeReportsOnlyTheDivergentFlag(t *testing.T) {
	got := StatedScope(statedCtx("gyldendal", "default"))
	if len(got) != 1 || got[0] != "-w" {
		t.Errorf("StatedScope(-w gyldendal, project at the floor) = %v, want [-w]", got)
	}
	got = StatedScope(statedCtx("default", "books"))
	if len(got) != 1 || got[0] != "-p" {
		t.Errorf("StatedScope(project only) = %v, want [-p]", got)
	}
}

// TestScopedMirrorFlagStillComposesEverything — the pre-existing ctx.ScopedMirror
// arm is untouched by the new one.
func TestScopedMirrorFlagStillComposesEverything(t *testing.T) {
	m := &Manifest{}
	cmd := Command{
		ID:           "x.y",
		AuthTier:     "read",
		HTTP:         HTTP{Method: "GET", PathTemplate: "/v1/x"},
		ScopedPrefix: strptr("/w/:ws/p/:p"),
	}
	ctx := Context{Server: "https://s.example", Workspace: "acme", Project: "site", ScopedMirror: true}
	got, err := m.BuildURL(cmd, ctx, nil)
	if err != nil {
		t.Fatalf("BuildURL: %v", err)
	}
	if want := "https://s.example/w/acme/p/site/v1/x"; got != want {
		t.Errorf("URL = %q, want %q", got, want)
	}
}
