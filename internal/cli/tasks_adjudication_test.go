package cli

// tasks_adjudication_test.go — the CLI half of pds-w29 c3 (task-953a23f03f690fb2).
//
// THREE THINGS ARE PROVEN HERE:
//
//  1. CAPTURE — `bp task create --disposition … --reopen-trigger …
//     --disposition-rerun …` puts all three keys, with the operator's values,
//     in the create mutation the server receives. Proven against a stub that
//     records the request body, not against the parser's own map.
//  2. REFUSAL — an off-vocabulary term is refused CLIENT-SIDE with a message
//     naming the allowed set, and the legacy `--set disposition=…` spelling is
//     screened by the same wall.
//  3. NO RETYPED VOCABULARY — every expectation below is read from
//     task_adjudication_vocabulary.json, so a mutation of that file changes
//     what these tests assert; the drift test in
//     tasks_adjudication_drift_test.go is the arm that reds when the fixture
//     and `Barkpark.Tasks.Stage` disagree.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func testVocabulary(t *testing.T) taskAdjudicationVocabulary {
	t.Helper()
	v, err := loadTaskAdjudicationVocabulary()
	if err != nil {
		t.Fatalf("vocabulary fixture unreadable: %v", err)
	}
	return v
}

// THE CAPTURE ARM. Drop any one of the three writes in parseTaskCreateArgs and
// this reds naming the missing key.
func TestRunTaskCreateSendsTheAdjudicationTriple(t *testing.T) {
	vocab := testVocabulary(t)

	var captured map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		var body struct {
			Mutations []map[string]map[string]any `json:"mutations"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err == nil && len(body.Mutations) > 0 {
			if create, ok := body.Mutations[0]["create"]; ok {
				captured = create
			}
		}
		_, _ = rw.Write([]byte(`{"results":[{"id":"drafts.task-1","document":{"_id":"drafts.task-1","_draft":true}}]}`))
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	tail := []string{
		"a parked task",
		"--disposition", "parked",
		"--reopen-trigger", "when the Bokbasen contract lands",
		"--disposition-rerun", "bp task get task-1 -o json",
	}
	if code := runTaskCreate(w, globals{yes: true}, ctx, tail); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	if captured == nil {
		t.Fatalf("no create mutation reached the server")
	}
	for key, want := range map[string]string{
		vocab.DispositionKey:      "parked",
		vocab.ReopenTriggerKey:    "when the Bokbasen contract lands",
		vocab.DispositionRerunKey: "bp task get task-1 -o json",
	} {
		got, ok := captured[key].(string)
		if !ok {
			t.Fatalf("create body carries no %q — the flag never reached the wire (body keys: %v)", key, adjudicationBodyKeys(captured))
		}
		if got != want {
			t.Errorf("create body %s = %q, want %q", key, got, want)
		}
	}
}

func adjudicationBodyKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// THE REFUSAL ARM. The message must NAME the allowed set — a bare "invalid
// disposition" sends the filer to the source to guess again.
func TestTaskCreateRefusesAnOffVocabularyDisposition(t *testing.T) {
	vocab := testVocabulary(t)

	_, _, err := parseTaskCreateArgs([]string{"t", "--disposition", "banana"})
	if err == nil {
		t.Fatalf("an off-vocabulary disposition was accepted")
	}
	for _, term := range vocab.Dispositions {
		if !strings.Contains(err.Error(), term) {
			t.Errorf("refusal %q does not name the allowed term %q", err, term)
		}
	}
}

// Every term the fixture declares must be ACCEPTED. This is the arm a fixture
// mutation reds: rename a term in the JSON without renaming it in the api and
// the drift test reds; break the READ (e.g. hardcode a list in Go) and this
// stops tracking the fixture at all.
func TestTaskCreateAcceptsEveryDeclaredDisposition(t *testing.T) {
	vocab := testVocabulary(t)
	for _, term := range vocab.Dispositions {
		tail := []string{"t", "--disposition", term}
		if containsString(vocab.TriggerRequired, term) {
			tail = append(tail, "--reopen-trigger", "when the blocker clears")
		}
		body, _, err := parseTaskCreateArgs(tail)
		if err != nil {
			t.Fatalf("declared disposition %q was refused: %v", term, err)
		}
		if body[vocab.DispositionKey] != term {
			t.Errorf("body %s = %v, want %q", vocab.DispositionKey, body[vocab.DispositionKey], term)
		}
	}
}

// The case split matters: the birth fence is lowercase-canonical, so an
// upper-cased term is a 422 the CLI can refuse for free.
func TestTaskCreateRefusesAMiscasedDisposition(t *testing.T) {
	vocab := testVocabulary(t)
	if len(vocab.Dispositions) == 0 {
		t.Fatalf("no dispositions declared")
	}
	upper := strings.ToUpper(vocab.Dispositions[0])
	if _, _, err := parseTaskCreateArgs([]string{"t", "--disposition", upper}); err == nil {
		t.Fatalf("mis-cased disposition %q was accepted", upper)
	}
}

// THE DOOR THIS ROW EXISTS TO CLOSE: `--set disposition=…` used to sail past
// every vocabulary. The screen runs on the finished body, so it does not.
func TestTaskCreateScreensTheLegacySetSpelling(t *testing.T) {
	vocab := testVocabulary(t)
	if _, _, err := parseTaskCreateArgs([]string{"t", "--set", vocab.DispositionKey + "=banana"}); err == nil {
		t.Fatalf("--set %s=banana bypassed the vocabulary screen", vocab.DispositionKey)
	}
}

// A parked row with no trigger is a hollow park — refused here rather than at
// the api's 422, where the filer has already paid for the round trip.
func TestTaskCreateRefusesAHollowPark(t *testing.T) {
	vocab := testVocabulary(t)
	for _, term := range vocab.TriggerRequired {
		_, _, err := parseTaskCreateArgs([]string{"t", "--disposition", term})
		if err == nil {
			t.Fatalf("disposition %q was accepted with no reopen trigger", term)
		}
		if !strings.Contains(err.Error(), "--reopen-trigger") {
			t.Errorf("hollow-park refusal %q does not name the flag that fixes it", err)
		}
	}
	// …and the same term WITH a trigger is fine (the refusal is about the
	// missing trigger, not about the term).
	for _, term := range vocab.TriggerRequired {
		if _, _, err := parseTaskCreateArgs([]string{"t", "--disposition", term, "--reopen-trigger", "when X lands"}); err != nil {
			t.Fatalf("disposition %q with a trigger was refused: %v", term, err)
		}
	}
}

// A task with no adjudication at all must stay a one-liner — the screen may not
// make `bp task create "title"` harder.
func TestTaskCreateWithoutAdjudicationIsUnaffected(t *testing.T) {
	body, _, err := parseTaskCreateArgs([]string{"plain task"})
	if err != nil {
		t.Fatalf("plain create refused: %v", err)
	}
	vocab := testVocabulary(t)
	if _, present := body[vocab.DispositionKey]; present {
		t.Errorf("a plain create invented a %s", vocab.DispositionKey)
	}
}

// `bp task create --help` must list all three flags (row c2).
func TestTaskCreateHelpListsTheAdjudicationFlags(t *testing.T) {
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	printTaskCreateHelp(w)
	help := so.String()
	for _, flag := range []string{"--disposition", "--reopen-trigger", "--disposition-rerun"} {
		if !strings.Contains(help, flag) {
			t.Errorf("task create --help never names %s", flag)
		}
	}
	for _, term := range testVocabulary(t).Dispositions {
		if !strings.Contains(help, term) {
			t.Errorf("help does not name the declared term %q", term)
		}
	}
}
