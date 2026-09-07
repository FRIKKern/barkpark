package manifest

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// envlessConfig is the env layer with NOTHING set — the shape Resolve sees when
// no BARKPARK_* var is exported. apiclient.ConfigFromEnv bakes a non-empty floor
// of its own, which would mask the layers this file is measuring.
func envlessConfig() apiclient.Config { return apiclient.Config{} }

// typedDatasetCtx is the Context a `bp -d <ds>` produces: the value won at flag
// precedence and nothing injected it.
func typedDatasetCtx(ds string) Context {
	return Context{
		Server:       "https://s.example",
		Workspace:    "default",
		Project:      "default",
		Dataset:      ds,
		DatasetTyped: true,
	}
}

// ambientDatasetCtx is the Context an env var / .barkpark.json / saved config
// produces: the value is there, and NOBODY typed it on this command line.
func ambientDatasetCtx(ds string) Context {
	return Context{
		Server:    "https://s.example",
		Workspace: "default",
		Project:   "default",
		Dataset:   ds,
	}
}

// ── c1: StatedDataset, both directions ───────────────────────────────────────

// TestStatedDatasetArmsOnlyOnTypedAndDivergent walks all four corners of the
// provenance x divergence square in one table, because the two conjuncts are
// only meaningful together: either one alone has a known blast radius, and this
// is the test that names which.
func TestStatedDatasetArmsOnlyOnTypedAndDivergent(t *testing.T) {
	floor := DefaultDefaults().Dataset
	if floor != "production" {
		t.Fatalf("DefaultDefaults().Dataset = %q, want production — this test's fixtures name the floor literally", floor)
	}
	for _, tc := range []struct {
		name string
		ctx  Context
		want bool
		why  string
	}{
		{"typed and divergent", typedDatasetCtx("staging"), true,
			"`bp -d staging` is the filed bug — the only case that may change behaviour"},
		{"typed AT the floor", typedDatasetCtx("production"), false,
			"`bp -d production` names the value the request already uses; refusing it is a refusal for nothing"},
		{"ambient and divergent", ambientDatasetCtx("staging"), false,
			"a BARKPARK_DATASET / .barkpark.json / saved-config dataset is a standing preference; " +
				"arming on it refuses every command for every developer with a non-production default"},
		{"ambient at the floor", ambientDatasetCtx("production"), false,
			"the overwhelmingly common invocation — it must be untouched"},
		{"typed, divergent, but injected by -s", func() Context {
			c := typedDatasetCtx("staging")
			c.DatasetFromServerEntry = true
			return c
		}(), false,
			"`bp -s <entry>` copies the entry's dataset in at flag precedence without the operator typing it; " +
				"refusing here has no cure short of deleting the saved entry"},
		{"zero Context", Context{Dataset: "staging"}, false,
			"a Context built as a literal (a test, a caller that skips Resolve) reads as not-typed and is left alone"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := StatedDataset(tc.ctx); got != tc.want {
				t.Errorf("StatedDataset = %v, want %v — %s", got, tc.want, tc.why)
			}
		})
	}
}

// TestResolveMarksOnlyAFlagDatasetAsTyped is the other end of the same wire: the
// bit StatedDataset reads has to be SET by the real resolver, from the layer that
// actually won, or the rule above is testing a field nothing populates.
func TestResolveMarksOnlyAFlagDatasetAsTyped(t *testing.T) {
	def := DefaultDefaults()
	for _, tc := range []struct {
		name   string
		flags  map[string]string
		active ActiveContext
		want   bool
	}{
		{"typed -d", map[string]string{FlagDataset: "staging"}, ActiveContext{}, true},
		{"saved active config", nil, ActiveContext{Dataset: "staging"}, false},
		{"nothing anywhere", nil, ActiveContext{}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, src := ResolveWithSources(tc.flags, envlessConfig(), tc.active, def)
			if ctx.DatasetTyped != tc.want {
				t.Errorf("DatasetTyped = %v (dataset %q from layer %q), want %v",
					ctx.DatasetTyped, ctx.Dataset, src.Dataset, tc.want)
			}
		})
	}
}

// TestAttributeServerEntryStillSubtractsAnInjectedDataset pins the -s door shut
// on the dataset axis specifically. The mark already existed (it was landed with
// the -w/-p arm for the dataset's benefit); this asserts the new predicate
// actually consults it.
func TestAttributeServerEntryStillSubtractsAnInjectedDataset(t *testing.T) {
	ctx, src := ResolveWithSources(
		map[string]string{FlagDataset: "staging"}, envlessConfig(), ActiveContext{}, DefaultDefaults())
	if !ctx.DatasetTyped {
		t.Fatal("a flag-precedence dataset did not read as typed — the fixture is wrong before the subtraction is tested")
	}
	if StatedDataset(ctx) != true {
		t.Fatal("a typed divergent dataset did not arm — the subtraction below would prove nothing")
	}
	ctx, _ = AttributeServerEntry(ctx, src, map[string]bool{FlagDataset: true})
	if !ctx.DatasetFromServerEntry {
		t.Fatal("AttributeServerEntry did not mark the injected dataset")
	}
	if StatedDataset(ctx) {
		t.Error("an -s-injected dataset still arms the refusal — `bp -s <entry> task ready` has no cure short of deleting the saved entry")
	}
}

// ── c0: the manifest-wide sweep ──────────────────────────────────────────────

// TestNoAdvertisedPrefixCarriesADataset is the DERIVATION behind DatasetFate
// having three arms where ScopeFate has four. If a server ever advertises a
// prefix with a dataset segment, a DatasetMirrored fate becomes real and
// commandCarriesDataset's unconditional prefix composition becomes load-bearing
// in a way nobody checked. This reds first and says so.
func TestNoAdvertisedPrefixCarriesADataset(t *testing.T) {
	m := loadFixture(t)
	seen := 0
	for _, cmd := range m.Commands {
		if cmd.ScopedPrefix == nil || *cmd.ScopedPrefix == "" {
			continue
		}
		seen++
		if PlaceholderNames(*cmd.ScopedPrefix)["dataset"] {
			t.Errorf("%s advertises scoped_prefix %q, which carries a :dataset segment — "+
				"a dataset MIRROR now exists and DatasetFate needs a fourth arm", cmd.ID, *cmd.ScopedPrefix)
		}
	}
	if seen == 0 {
		t.Fatal("no command in the fixture advertises a scoped_prefix — this derivation is vacuous")
	}
	t.Logf("checked %d advertised scoped_prefixes; none carries a dataset segment", seen)
}

// TestDatasetFateIsTotal — the same totality guarantee ScopeFate has: no fifth
// outcome, and no command falls out of the switch.
func TestDatasetFateIsTotal(t *testing.T) {
	m := loadFixture(t)
	seen := map[DatasetFate]int{}
	for _, cmd := range m.Commands {
		f := DatasetFateFor(cmd)
		switch f {
		case DatasetCarried, DatasetUnscopedByDesign, DatasetRefused:
			seen[f]++
		default:
			t.Fatalf("%s got an unknown dataset fate %d", cmd.ID, int(f))
		}
	}
	for _, f := range []DatasetFate{DatasetCarried, DatasetUnscopedByDesign, DatasetRefused} {
		if seen[f] == 0 {
			t.Errorf("no command in the live surface classifies as %v — the case is untested by this sweep", f)
		}
	}
	tally := DatasetFateTally(m.Commands)
	for f, n := range seen {
		if tally[f] != n {
			t.Errorf("DatasetFateTally disagrees with the sweep for %v: %d vs %d", f, tally[f], n)
		}
	}
	t.Logf("live surface (%d commands): carried=%d unscoped-by-design=%d refused=%d",
		len(m.Commands), seen[DatasetCarried], seen[DatasetUnscopedByDesign], seen[DatasetRefused])
}

// TestEveryDatasetUnscopableCommandIsDeclared is the c0 tripwire, the dataset
// twin of TestEveryUnscopableCommandIsDeclared. It sweeps EVERY command in the
// shipped manifest, keeps the ones that can neither put a typed -d in their path
// nor forward it as a declared flag, and requires each one to have an explicit
// declaration — with a reason — in datasetDispositions (or an override).
//
// This is what makes the table DERIVED rather than hand-listed: a future command
// that quietly drops -d has no declaration, so it lands here as a RED with its
// own id in the message, and the author has to choose refuse or unscoped-by-
// design and write down why.
func TestEveryDatasetUnscopableCommandIsDeclared(t *testing.T) {
	m := loadFixture(t)
	assertEveryDatasetUnscopableCommandIsDeclared(t, m.Commands)
}

func assertEveryDatasetUnscopableCommandIsDeclared(t *testing.T, cmds []Command) {
	t.Helper()
	checked := 0
	for _, cmd := range cmds {
		if commandCarriesDataset(cmd) {
			continue
		}
		checked++
		d, ok := DatasetDispositionFor(cmd)
		if !ok {
			t.Errorf("%s (noun %q) cannot carry a typed -d and is UNDECLARED. "+
				"Add an entry to datasetDispositions in internal/manifest/dataset_scope.go: `refuse` "+
				"(Unscoped:false) unless -d is meaningless for it by construction, and say why in Reason.",
				cmd.ID, cmd.Noun)
			continue
		}
		if d.Reason == "" {
			t.Errorf("%s (noun %q) is declared with an EMPTY reason — the declaration is the record of "+
				"why the flag cannot land, so it has to say something", cmd.ID, cmd.Noun)
		}
	}
	if checked == 0 {
		t.Fatal("swept 0 dataset-unscopable commands — the enumeration is vacuous")
	}
	t.Logf("swept %d dataset-unscopable commands across %d declared nouns", checked, len(DeclaredDatasetNouns()))
}

// TestUndeclaredFlatVerbRedsTheDatasetEnumeration is the non-vacuity proof for
// the tripwire above: it runs the SAME assertion against the live surface plus
// one fake verb under a noun nobody has declared, and requires it to fail. If
// the enumeration ever goes blind, this goes red first and names it.
func TestUndeclaredFlatVerbRedsTheDatasetEnumeration(t *testing.T) {
	m := loadFixture(t)
	fake := Command{
		ID:       "quokka.stats",
		Noun:     "quokka",
		Verb:     "stats",
		AuthTier: "read",
		HTTP:     HTTP{Method: "GET", PathTemplate: "/v1/quokka/stats"},
	}
	probe := &testing.T{}
	assertEveryDatasetUnscopableCommandIsDeclared(probe, append(append([]Command{}, m.Commands...), fake))
	if !probe.Failed() {
		t.Fatal("a flat verb under an UNDECLARED noun passed the dataset enumeration — the c0 tripwire is blind")
	}
}

// TestDeclaredDatasetNounsAllExistInTheShippedManifest keeps the table from
// growing stale entries. A declaration is a claim about a real command family;
// if the family is gone, so is the claim.
func TestDeclaredDatasetNounsAllExistInTheShippedManifest(t *testing.T) {
	m := loadFixture(t)
	live := map[string]bool{}
	for _, cmd := range m.Commands {
		live[cmd.Noun] = true
	}
	for _, n := range DeclaredDatasetNouns() {
		if !live[n] {
			t.Errorf("datasetDispositions declares noun %q, which no command in the shipped manifest uses — drop the entry", n)
		}
	}
}

// TestEveryDeclaredDatasetNounHasAnUnscopableInhabitant is the mirror of the
// test above and the one that keeps the table HONEST rather than merely
// non-stale: a noun whose every command carries a dataset does not belong here,
// because its entry would be a reason nobody can ever read.
func TestEveryDeclaredDatasetNounHasAnUnscopableInhabitant(t *testing.T) {
	m := loadFixture(t)
	unscopable := map[string]bool{}
	for _, cmd := range m.Commands {
		if !commandCarriesDataset(cmd) {
			unscopable[cmd.Noun] = true
		}
	}
	for _, n := range DeclaredDatasetNouns() {
		if !unscopable[n] {
			t.Errorf("datasetDispositions declares noun %q, but every command under it already carries a dataset — the entry is dead", n)
		}
	}
}

// TestDatasetCarryingCommandsAreLeftAlone names the two carriage MECHANISMS with
// a live witness each, so a change that breaks either one is a named red rather
// than a quiet drop in the refused count.
func TestDatasetCarryingCommandsAreLeftAlone(t *testing.T) {
	m := loadFixture(t)
	for _, tc := range []struct{ id, how string }{
		{"doc.ls", ":dataset placeholder in the path template"},
		{"task.events", "a declared `dataset` flag that applyQuery forwards -d into"},
	} {
		cmd, ok := fixtureCommand(m, tc.id)
		if !ok {
			t.Fatalf("fixture has no %s — the %s witness is gone", tc.id, tc.how)
		}
		if got := DatasetFateFor(cmd); got != DatasetCarried {
			t.Errorf("DatasetFateFor(%s) = %v, want %v (%s)", tc.id, got, DatasetCarried, tc.how)
		}
	}
}

// TestPositionalDatasetArgIsNotCarriage pins the distinction commandCarriesDataset
// draws: a positional arg named `dataset` is the operator's own value for that
// slot and the global -d never reaches it, so it must NOT count as carriage. On
// the live surface the only such command also has the placeholder, which is
// exactly why a hand-written table would get this wrong and never notice.
func TestPositionalDatasetArgIsNotCarriage(t *testing.T) {
	argOnly := Command{
		ID:       "decoy.export",
		Noun:     "decoy",
		Verb:     "export",
		AuthTier: "read",
		HTTP:     HTTP{Method: "GET", PathTemplate: "/v1/decoy/export"},
		Args:     []Arg{{Name: "dataset", Required: true}},
	}
	if commandCarriesDataset(argOnly) {
		t.Error("a POSITIONAL arg named `dataset` was read as carrying the global -d; applyQuery forwards -d only into a declared FLAG")
	}
	flagged := argOnly
	flagged.Args = nil
	flagged.Flags = []Flag{{Name: "dataset"}}
	if !commandCarriesDataset(flagged) {
		t.Error("a declared `dataset` FLAG was not read as carriage — globalQueryForwards puts the typed -d there")
	}
}
