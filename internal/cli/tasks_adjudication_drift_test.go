package cli

// tasks_adjudication_drift_test.go — THE LOCK.
//
// Two copies of a vocabulary with a test each is an UNLOCKED MIRROR: each suite
// reads only its own file and the two drift the day a fourth disposition lands.
// So this test does not restate `open parked closed`. It PARSES the api's own
// module — `api/lib/barkpark/tasks/stage.ex`, the module the birth fence screens
// against (`term not in Stage.dispositions()` -> 422) and the module PR #17843
// made the task schema's `options` read from — and compares it to
// `task_adjudication_vocabulary.json` in BOTH directions.
//
// Editing the Elixir alone reds here. Editing the JSON alone reds here.
// Replacing the JSON read in tasks_adjudication.go with a Go literal reds the
// behaviour tests in tasks_adjudication_test.go, which read the fixture for
// every expectation.
//
// READ ONLY — this row's fence is internal/cli/. The api-side half (a copy of
// this fixture under api/ with its own decode test, the edge_capabilities
// pattern) is handed back to the lead as a request, not made here.

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// serverStagePath is the api-side source of truth, relative to this package.
const serverStagePath = "../../api/lib/barkpark/tasks/stage.ex"

var (
	stageWordList = regexp.MustCompile(`@(dispositions|trigger_required)\s+~w\(([^)]*)\)`)
	stageKeyAttr  = regexp.MustCompile(`@(disposition_key|reopen_trigger_key|disposition_rerun_key)\s+"([^"]+)"`)
)

// stageVocabulary reads Stage's module attributes out of the Elixir source. A
// parse that finds NOTHING is a hard failure, never a pass: a blind parser
// would turn this lock into a green that measures nothing.
func stageVocabulary(t *testing.T) (keys map[string]string, lists map[string][]string) {
	t.Helper()
	src, err := os.ReadFile(serverStagePath)
	if err != nil {
		t.Skipf("api stage source not readable (%v) — drift arm cannot run", err)
	}
	keys = map[string]string{}
	for _, m := range stageKeyAttr.FindAllStringSubmatch(string(src), -1) {
		keys[m[1]] = m[2]
	}
	lists = map[string][]string{}
	for _, m := range stageWordList.FindAllStringSubmatch(string(src), -1) {
		lists[m[1]] = strings.Fields(m[2])
	}
	if len(keys) != 3 || len(lists) != 2 {
		t.Fatalf("parsed %d keys and %d lists out of %s — the parser went blind; fix the parser, "+
			"do NOT relax this assertion", len(keys), len(lists), serverStagePath)
	}
	return keys, lists
}

func TestAdjudicationFixtureMirrorsStageExactly(t *testing.T) {
	vocab := testVocabulary(t)
	keys, lists := stageVocabulary(t)

	for attr, want := range keys {
		var got string
		switch attr {
		case "disposition_key":
			got = vocab.DispositionKey
		case "reopen_trigger_key":
			got = vocab.ReopenTriggerKey
		case "disposition_rerun_key":
			got = vocab.DispositionRerunKey
		}
		if got != want {
			t.Errorf("fixture %s = %q but Stage's @%s = %q — the two copies have drifted; "+
				"edit stage.ex and task_adjudication_vocabulary.json in the SAME commit", attr, got, attr, want)
		}
	}

	assertSameSet(t, "dispositions", vocab.Dispositions, lists["dispositions"])
	assertSameSet(t, "trigger_required_dispositions", vocab.TriggerRequired, lists["trigger_required"])
}

// assertSameSet compares BOTH directions: a term the fixture has and Stage does
// not (a CLI that accepts what the api 422s) and a term Stage has and the
// fixture does not (a CLI that refuses a legal term).
func assertSameSet(t *testing.T, label string, fixture, stage []string) {
	t.Helper()
	for _, term := range fixture {
		if !containsString(stage, term) {
			t.Errorf("%s: fixture declares %q, Stage does not (%v) — the CLI would accept a term the api 422s",
				label, term, stage)
		}
	}
	for _, term := range stage {
		if !containsString(fixture, term) {
			t.Errorf("%s: Stage declares %q, the fixture does not (%v) — the CLI would refuse a legal term",
				label, term, fixture)
		}
	}
}
