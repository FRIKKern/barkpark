package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// taskRosterWithTwoCarriers is the roster shape the retired prose got wrong:
// `task get` cannot carry a dataset, and TWO siblings can. The frozen sentence
// named exactly one of them.
func taskRosterWithTwoCarriers() []manifest.Command {
	return []manifest.Command{
		{ID: "task.get", Noun: "task", Verb: "get",
			Args: []manifest.Arg{{Name: "doc_id", Required: true}},
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/:doc_id"}},
		{ID: "task.ready", Noun: "task", Verb: "ready", Flags: []manifest.Flag{{Name: "dataset"}},
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/ready"}},
		{ID: "task.events", Noun: "task", Verb: "events", Flags: []manifest.Flag{{Name: "dataset"}},
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/events"}},
		{ID: "doc.get", Noun: "doc", Verb: "get",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"}},
	}
}

func datasetTaskGetCmd() manifest.Command { return taskRosterWithTwoCarriers()[0] }

func typedDatasetCtx(ds string) manifest.Context {
	return manifest.Context{Server: "https://s.example", Dataset: ds, DatasetTyped: true}
}

// TestDatasetRefusalNamesEveryCarryingSibling is the RED arm: remove the roster
// threading in scope_honesty.go (pass nil instead of m.Commands, or drop the
// DatasetCarryingSiblings block) and this fails, because the message no longer
// names the remedy the operator can actually reach.
//
// It asserts BOTH carriers. Asserting only one would pass against the retired
// prose, which is the whole defect.
func TestDatasetRefusalNamesEveryCarryingSibling(t *testing.T) {
	msg := refuseUnrepresentableDataset(taskGetCmd(), typedDatasetCtx("aker-brygge"), taskRosterWithTwoCarriers())
	if msg == "" {
		t.Fatal("no refusal for a typed, divergent -d on a route that cannot carry it — this test measures nothing")
	}
	for _, want := range []string{"`bp task ready`", "`bp task events`"} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal does not name the carrying sibling %s — the operator is sent to `bp capabilities` "+
				"while a reachable door exists in the same family.\nmessage: %s", want, msg)
		}
	}
	// The refused door must not be advertised as its own remedy.
	if strings.Contains(msg, "`bp task get`  carries") || strings.Contains(msg, ", `bp task get`") {
		t.Errorf("the refused verb is listed as a remedy:\n%s", msg)
	}
	// And the refusal still says WHY, from the declared disposition.
	d, ok := manifest.DatasetDispositionFor(taskGetCmd())
	if !ok || d.Reason == "" {
		t.Fatal("task has no declared dataset Reason — the manifest-wide enumeration should have caught this")
	}
	if !strings.Contains(msg, d.Reason) {
		t.Errorf("refusal dropped the declared reason %q:\n%s", d.Reason, msg)
	}
	t.Logf("refusal: %s", msg)
}

// TestDatasetRefusalOmitsTheClauseWhenNothingCarries is the QUIET arm. A family
// where no door carries a dataset must get the generic `bp capabilities` line
// and no fabricated remedy — a clause naming zero verbs, or naming a carrier
// from another noun, is worse than none.
func TestDatasetRefusalOmitsTheClauseWhenNothingCarries(t *testing.T) {
	// Same roster, but the task carriers removed; doc.get (another noun) stays,
	// so a leak across nouns shows up here rather than nowhere.
	roster := []manifest.Command{
		taskGetCmd(),
		{ID: "doc.get", Noun: "doc", Verb: "get",
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"}},
	}
	msg := refuseUnrepresentableDataset(taskGetCmd(), typedDatasetCtx("aker-brygge"), roster)
	if msg == "" {
		t.Fatal("the refusal vanished — the quiet arm must still refuse, just without the derived clause")
	}
	if strings.Contains(msg, "In this family") {
		t.Errorf("a remedy clause was rendered for a family with no carrying door:\n%s", msg)
	}
	if strings.Contains(msg, "bp doc get") {
		t.Errorf("a carrier from ANOTHER noun leaked into the refusal:\n%s", msg)
	}
	if !strings.Contains(msg, "`bp capabilities` marks them") {
		t.Errorf("the generic fallback clause is gone, so the operator is left with no next step:\n%s", msg)
	}
}

// TestDatasetRemedyClauseIsGrammaticalForOneCarrier — the single-carrier case is
// the common one and the one the retired prose handled correctly by accident.
func TestDatasetRemedyClauseIsGrammaticalForOneCarrier(t *testing.T) {
	roster := []manifest.Command{
		taskGetCmd(),
		{ID: "task.events", Noun: "task", Verb: "events", Flags: []manifest.Flag{{Name: "dataset"}},
			HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/events"}},
	}
	msg := refuseUnrepresentableDataset(taskGetCmd(), typedDatasetCtx("aker-brygge"), roster)
	if !strings.Contains(msg, "`bp task events` carries the dataset.") {
		t.Errorf("one-carrier clause is not grammatical:\n%s", msg)
	}
}

// TestFloorDatasetStillRendersNoRefusal is the POSITIVE CONTROL that keeps this
// change from widening the refusal. A typed -d naming the BAKED FLOOR is the
// case the row that prompted this work was measured on (`-d production`), and it
// must stay byte-identical: no refusal, the request goes out, and the server's
// own honest `ambiguous_dataset` answer is what the operator reads.
func TestFloorDatasetStillRendersNoRefusal(t *testing.T) {
	floor := manifest.DefaultDefaults().Dataset
	if floor == "" {
		t.Fatal("the baked floor dataset is empty — this control measures nothing")
	}
	if msg := refuseUnrepresentableDataset(taskGetCmd(), typedDatasetCtx(floor), taskRosterWithTwoCarriers()); msg != "" {
		t.Errorf("a typed -d %s (the floor) now refuses — this change must not widen the refusal:\n%s", floor, msg)
	}
	// And an AMBIENT divergent dataset (not typed) is still untouched.
	ambient := manifest.Context{Server: "https://s.example", Dataset: "aker-brygge"}
	if msg := refuseUnrepresentableDataset(taskGetCmd(), ambient, taskRosterWithTwoCarriers()); msg != "" {
		t.Errorf("an ambient (untyped) dataset now refuses:\n%s", msg)
	}
	// CONTROL ON THE CONTROL: the same roster and command DO refuse for a typed,
	// divergent dataset — otherwise the two silences above prove nothing.
	if msg := refuseUnrepresentableDataset(taskGetCmd(), typedDatasetCtx("aker-brygge"), taskRosterWithTwoCarriers()); msg == "" {
		t.Fatal("the armed case does not refuse — both silences above are vacuous")
	}
}

// TestCarryingCommandIsNeverRefused — once a route DOES declare a `dataset`
// flag, the refusal must get out of the way. This is the arm that matters for
// the api-side half of task-7cba0e62c3813fac: the moment the manifest declares
// `dataset` on task.get, the CLI threads it and this refusal stops firing, with
// no further Go change.
func TestCarryingCommandIsNeverRefused(t *testing.T) {
	declared := taskGetCmd()
	declared.Flags = []manifest.Flag{{Name: "dataset"}}

	if fate := manifest.DatasetFateFor(declared); fate != manifest.DatasetCarried {
		t.Fatalf("task.get with a declared dataset flag classifies as %v, want carried", fate)
	}
	if msg := refuseUnrepresentableDataset(declared, typedDatasetCtx("aker-brygge"), taskRosterWithTwoCarriers()); msg != "" {
		t.Errorf("a route that declares `dataset` is still refused:\n%s", msg)
	}
	// CONTROL: the same command WITHOUT the declaration refuses, so the pass
	// above is the declaration's doing and not the context's.
	if msg := refuseUnrepresentableDataset(taskGetCmd(), typedDatasetCtx("aker-brygge"), taskRosterWithTwoCarriers()); msg == "" {
		t.Fatal("the undeclared control does not refuse — the assertion above measures nothing")
	}
}

// TestBuildSeamThreadsTheRosterIntoTheRefusal is the arm that covers the
// THREADING itself rather than the rendering: it drives the real build seam
// (buildManifestRequest — the one both CLI dispatch and headless MCP dispatch
// pass through) with a real Manifest, so reverting run.go's `m.Commands` to
// `nil` reds here while every direct-call test above stays green.
func TestBuildSeamThreadsTheRosterIntoTheRefusal(t *testing.T) {
	datasetFixture(t)

	g := globals{dataset: "aker-brygge", datasetSet: true}
	ctx := resolveContext(g)
	if !manifest.StatedDataset(ctx) {
		t.Fatalf("StatedDataset = false for a typed `-d aker-brygge` — the refusal cannot fire and this test is vacuous")
	}

	m := &manifest.Manifest{Commands: taskRosterWithTwoCarriers()}
	req, derr := buildManifestRequest(g, ctx, m, datasetTaskGetCmd(), []string{"some-id"}, false)
	if derr == nil {
		t.Fatalf("`bp -d aker-brygge task get some-id` was BUILT, url=%q — the typed dataset is nowhere in it", req.url)
	}
	msg := derr.Error()
	for _, want := range []string{"`bp task ready`", "`bp task events`"} {
		if !strings.Contains(msg, want) {
			t.Errorf("the build seam did not thread the roster — refusal omits %s.\nmessage: %s", want, msg)
		}
	}

	// CONTROL: the SAME call with an EMPTY manifest still refuses, and refuses
	// without the clause. This is what separates "the roster was threaded" from
	// "the refusal fired", which are different claims.
	_, bare := buildManifestRequest(g, ctx, &manifest.Manifest{}, datasetTaskGetCmd(), []string{"some-id"}, false)
	if bare == nil {
		t.Fatal("an empty-roster build did not refuse — the control measures nothing")
	}
	if strings.Contains(bare.Error(), "In this family") {
		t.Errorf("a remedy clause was rendered from an EMPTY roster:\n%s", bare.Error())
	}
}
