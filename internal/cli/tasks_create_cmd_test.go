package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The two fields the task schema REQUIRES at creation — the whole reason this
// verb exists, since the generic doc-create path omits them. If a refactor ever
// drops a default, these tests fail loudly.
func TestParseTaskCreateArgs_InjectsRequiredDefaults(t *testing.T) {
	body, publish, err := parseTaskCreateArgs([]string{"My task"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if publish {
		t.Errorf("publish should default false")
	}
	if body["kind"] != "task" {
		t.Errorf("kind default = %v, want task", body["kind"])
	}
	if body["lifecycle_status"] != "open" {
		t.Errorf("lifecycle_status default = %v, want open", body["lifecycle_status"])
	}
	if body["title"] != "My task" {
		t.Errorf("positional title = %v, want My task", body["title"])
	}
}

func TestParseTaskCreateArgs_FlagsAndTypedSet(t *testing.T) {
	body, publish, err := parseTaskCreateArgs([]string{
		"--title", "T", "--description", "D",
		"--set", "priority:=3", "--set", "parent_id=goal-1", "--publish",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !publish {
		t.Errorf("--publish should set publish=true")
	}
	if body["title"] != "T" || body["description"] != "D" {
		t.Errorf("title/description = %v/%v", body["title"], body["description"])
	}
	// key:=json sends a typed value — priority must be a number, not "3".
	if got, ok := body["priority"].(float64); !ok || got != 3 {
		t.Errorf("priority = %#v, want number 3", body["priority"])
	}
	if body["parent_id"] != "goal-1" {
		t.Errorf("parent_id = %v, want goal-1 (string)", body["parent_id"])
	}
}

// Regression (task-bp-create-drops-long-description): the builtin `bp task
// create` --set parser (applyTaskSet) and its --description flag must also carry
// a multi-KB, multi-line description VERBATIM — no newline truncation, no drop —
// past the 5,783 bytes that reproduced the report.
func TestParseTaskCreateArgs_LongMultilineDescription(t *testing.T) {
	line := "rationale: a task reason with a colon a:b and a := marker, padding padding padding\n"
	desc := "Hit twice during round nine.\n\n" + strings.Repeat(line, 84)
	if len(desc) <= 5783 {
		t.Fatalf("description must exceed the reproduced 5783 bytes, got %d", len(desc))
	}

	// via --set description=<big>
	viaSet, _, err := parseTaskCreateArgs([]string{"t", "--set", "description=" + desc})
	if err != nil {
		t.Fatalf("--set path: %v", err)
	}
	if got, _ := viaSet["description"].(string); got != desc {
		t.Fatalf("--set description not verbatim: got %d bytes, want %d", len(got), len(desc))
	}

	// via --description <big>
	viaFlag, _, err := parseTaskCreateArgs([]string{"t", "--description", desc})
	if err != nil {
		t.Fatalf("--description path: %v", err)
	}
	if got, _ := viaFlag["description"].(string); got != desc {
		t.Fatalf("--description not verbatim: got %d bytes, want %d", len(got), len(desc))
	}
}

func TestParseTaskCreateArgs_SetOverridesDefault(t *testing.T) {
	body, _, err := parseTaskCreateArgs([]string{"t", "--set", "lifecycle_status=blocked"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if body["lifecycle_status"] != "blocked" {
		t.Errorf("--set should override the default: got %v", body["lifecycle_status"])
	}
}

func TestParseTaskCreateArgs_Errors(t *testing.T) {
	cases := [][]string{
		{"--title"},             // flag needs a value
		{"--set"},               // flag needs a value
		{"--set", "noeq"},       // malformed --set
		{"--set", "x:=notjson"}, // typed set with invalid JSON
		{"--bogus"},             // unknown flag
		{"one", "two"},          // two positionals (second is not the title)
	}
	for _, tc := range cases {
		if _, _, err := parseTaskCreateArgs(tc); err == nil {
			t.Errorf("parseTaskCreateArgs(%v) = nil error, want error", tc)
		}
	}
}

// taskCreateStubMutate is a mutate endpoint that behaves like the real one on
// the axis these tests exercise: it PERSISTS the create op and echoes the
// stored record back as results[].document, the way
// Content.Mutations does with Envelope.render. The receipt reads its claims off
// that document (PDS wave 48), so a stub that returned a bare id would be
// testing a receipt with nothing to read.
func taskCreateStubMutate(t *testing.T, docID string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		if !strings.Contains(req.URL.Path, "/v1/data/mutate") {
			rw.WriteHeader(http.StatusNotFound)
			return
		}
		var body struct {
			Mutations []map[string]map[string]any `json:"mutations"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil || len(body.Mutations) == 0 {
			rw.WriteHeader(http.StatusBadRequest)
			return
		}
		op := body.Mutations[0]
		document := map[string]any{"_id": docID, "_draft": true}
		if create, ok := op["create"]; ok {
			for k, v := range create {
				document[k] = v
			}
			document["_id"] = docID
			document["_draft"] = true
		}
		if _, ok := op["publish"]; ok {
			document["_id"] = strings.TrimPrefix(docID, "drafts.")
			document["_draft"] = false
		}
		result := map[string]any{"id": document["_id"], "document": document}
		json.NewEncoder(rw).Encode(map[string]any{"results": []any{result}})
	}))
}

// tlv-s6 (TLV charter D14): the create receipt names the lifecycle_status the
// task was born with — a birth-as-considering must be visible, never silently
// assumed "open". PDS wave 48: the value descends from the record the server
// PERSISTED, not from the request map. Runs the real runTaskCreate against a
// stub mutate endpoint.
func TestRunTaskCreateReceiptEchoesBornLifecycle(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-9")
	defer ts.Close()

	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	cases := []struct {
		name string
		tail []string
		want string
	}{
		{"default open", []string{"a task"}, "open"},
		{"born considering", []string{"a task", "--set", "lifecycle_status=considering"}, "considering"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var so, se bytes.Buffer
			w := &writer{stdout: &so, stderr: &se, output: "json"}
			if code := runTaskCreate(w, globals{yes: true}, ctx, tc.tail); code != exitOK {
				t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
			}
			var receipt struct {
				ID              string `json:"id"`
				Draft           string `json:"draft"`
				Status          string `json:"status"`
				LifecycleStatus string `json:"lifecycle_status"`
			}
			if err := json.Unmarshal(so.Bytes(), &receipt); err != nil {
				t.Fatalf("receipt did not parse: %v (%q)", err, so.String())
			}
			if receipt.ID != "task-9" || receipt.Draft != "drafts.task-9" || receipt.Status != "draft" {
				t.Fatalf("receipt = %+v, want id task-9 / draft drafts.task-9 / status draft", receipt)
			}
			if receipt.LifecycleStatus != tc.want {
				t.Fatalf("receipt.lifecycle_status = %q, want %q", receipt.LifecycleStatus, tc.want)
			}
		})
	}
}

// The human (non-machine) receipt line names the born lifecycle too.
func TestRunTaskCreateHumanReceiptNamesLifecycle(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-3")
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	tail := []string{"a task", "--set", "lifecycle_status=considering"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, tail); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	if got := so.String(); !strings.Contains(got, "lifecycle considering") {
		t.Fatalf("human receipt %q does not name the born lifecycle", got)
	}
}

// PDS wave 48. THE DIVERGENCE THE OLD RECEIPT COULD NOT PRINT: the request asks
// for lifecycle_status=open and the server stores "blocked". The receipt must
// name what the server STORED — the old `born := body["lifecycle_status"]` read
// the request map the CLI had defaulted "open" into, so it printed "open" here
// and no test could ever have caught it.
func TestRunTaskCreateReceiptNamesTheStoredLifecycleNotTheRequested(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		io.WriteString(rw, `{"results":[{"id":"drafts.task-11","document":{"_id":"drafts.task-11","_draft":true,"lifecycle_status":"blocked"}}]}`)
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task"}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	if got := so.String(); !strings.Contains(got, "lifecycle blocked") {
		t.Fatalf("receipt %q does not name the STORED lifecycle — it is still speaking for the request", got)
	}
}

// A server that echoes no document cannot back the claim, so the receipt says
// so instead of filling the gap in from what was sent.
func TestRunTaskCreateReceiptRefusesWhatTheServerDidNotEcho(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		io.WriteString(rw, `{"results":[{"id":"drafts.task-12"}]}`)
	}))
	defer ts.Close()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task"}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	got := so.String()
	if strings.Contains(got, "lifecycle open") {
		t.Fatalf("receipt %q claims a lifecycle the server never echoed", got)
	}
	if !strings.Contains(got, "unknown") || !strings.Contains(got, "unconfirmed") {
		t.Fatalf("receipt %q does not say what it could not confirm", got)
	}
}

func TestIsProdServer(t *testing.T) {
	// Fail-closed (onb-backlog-isprod-custom-host-write-confirm): any non-local
	// host is prod — including guerrilla.barkpark.cloud, which IS the live fleet
	// and was previously (wrongly) asserted non-prod here.
	prod := []string{"https://api.barkpark.cloud", "https://prod.example.com", "https://guerrilla.barkpark.cloud"}
	nonprod := []string{"http://localhost:4000", "http://127.0.0.1:4000"}
	for _, s := range prod {
		if !isProdServer(s) {
			t.Errorf("isProdServer(%q) = false, want true", s)
		}
	}
	for _, s := range nonprod {
		if isProdServer(s) {
			t.Errorf("isProdServer(%q) = true, want false", s)
		}
	}
}

// The create body carries the required fields flat at top level (never nested
// under content.*), which is the shape the server's mutate contract accepts.
func TestTaskCreateBodyShape(t *testing.T) {
	body, _, _ := parseTaskCreateArgs([]string{"hello"})
	want := map[string]any{"kind": "task", "lifecycle_status": "open", "title": "hello"}
	if !reflect.DeepEqual(body, want) {
		t.Errorf("body = %#v, want %#v", body, want)
	}
}

func TestEnsureTaskPortableBrief(t *testing.T) {
	body := map[string]any{
		"title":       "Ship the reader",
		"description": "**Why:** humans must scan it.",
		"acceptance_criteria": []any{
			map[string]any{"criterion": "PortableDoc renders in the task TUI"},
		},
	}
	ensureTaskPortableBrief(body)
	brief, ok := body["brief"].(map[string]any)
	if !ok || brief["version"] != 1 {
		t.Fatalf("brief = %#v, want PortableDoc v1", body["brief"])
	}
	blocks, _ := brief["blocks"].([]any)
	if len(blocks) != 4 {
		t.Fatalf("blocks = %d, want criteria then purpose pairs", len(blocks))
	}
	if blocks[0].(map[string]any)["id"] != "criteria" || blocks[1].(map[string]any)["id"] != "criteria-list" {
		t.Fatalf("criteria are not the first brief section: %#v", blocks)
	}
	if blocks[1].(map[string]any)["type"] != "list" {
		t.Fatalf("criteria are not a TUI-supported list: %#v", blocks[1])
	}
	purpose := blocks[3].(map[string]any)["content"].([]any)[0].(map[string]any)["value"]
	if strings.Contains(purpose.(string), "**") {
		t.Fatalf("purpose retained Markdown markers: %q", purpose)
	}
	for _, block := range blocks {
		id, _ := block.(map[string]any)["id"].(string)
		if id == "state" || id == "state-callout" || id == "done" || id == "done-list" || id == "done-copy" {
			t.Fatalf("brief retained deprecated generated block %q", id)
		}
	}
}

func TestEnsureTaskPortableBriefPreservesExplicitBrief(t *testing.T) {
	explicit := map[string]any{"version": float64(1), "blocks": []any{map[string]any{"type": "heading"}}}
	body := map[string]any{"title": "t", "brief": explicit}
	ensureTaskPortableBrief(body)
	if !reflect.DeepEqual(body["brief"], explicit) {
		t.Fatalf("explicit brief was replaced: %#v", body["brief"])
	}
}

// ── pds-bl-task-create-draft-at-rc0 ──────────────────────────────────────────
//
// THE DEFECT, reproduced live against guerrilla before this was written:
//
//	$ bp task create --yes --title "…"          rc=0
//	{"draft":"drafts.task-9f3aa…","id":"task-9f3aa…","lifecycle_status":"open","status":"draft"}
//	$ bp task create --yes -o table --title "…" rc=0
//	created task task-42b4b… (draft, lifecycle open)
//
// and the row was NOT on the board. ONE HALF OF THE FILED ROW IS REFUTED by
// that second line: the human receipt DOES print the field carrying the truth
// ("draft"), and it was trusted anyway. So the defect is not a missing fact —
// it is a TRUE LINE WITH NO REMEDY. It never says what "draft" costs (the row
// is invisible to `bp task ready` and cannot be claimed) nor the one command
// that fixes it, while `lifecycle open` sits beside it and "open" is the
// BOARD's word for ready.
//
// These tests pin the remedy on all three surfaces and are written so that
// deleting it reds them.

func TestTaskCreateHumanReceiptCarriesItsRemedy(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-9")
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{"a task"}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	got := so.String()
	// The FACT is still there — this must not become a receipt that hides the state.
	if !strings.Contains(got, "draft") {
		t.Errorf("the receipt no longer names the draft state:\n%s", got)
	}
	// THE CONSEQUENCE, in the words a person uses for it.
	if !strings.Contains(got, "NOT ON THE BOARD") {
		t.Errorf("the receipt does not say what the draft state COSTS — a builder who trusts it files a task the board never shows:\n%s", got)
	}
	if !strings.Contains(got, "bp task ready") {
		t.Errorf("the receipt does not name the command that will fail to show this row:\n%s", got)
	}
	// THE REMEDY, exact and runnable.
	if !strings.Contains(got, "bp doc publish task task-9 --yes") {
		t.Errorf("the receipt does not carry the one command that puts the row on the board:\n%s", got)
	}
	// And the way to avoid the state entirely next time.
	if !strings.Contains(got, "--publish") {
		t.Errorf("the receipt does not mention creating it published instead:\n%s", got)
	}
}

// THE REMEDY IS WITHHELD WHEN IT DOES NOT APPLY. A remedy printed under a
// published row is noise, and noise is how a real remedy stops being read.
func TestTaskCreatePublishedReceiptCarriesNoRemedy(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-9")
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se}
	// The row carries a WALL-PASSING body. Before the client-side pre-flight
	// (tasks_publish_wall.go) this test passed with a bare title, because the stub
	// mutate endpoint has no publish wall — a green that could not have caught the
	// phantom-draft defect it sat next to.
	if code := runTaskCreate(w, globals{yes: true}, ctx, []string{
		"a task", "--publish",
		"--description", wallPassingDescription,
		"--set", wallPassingTags,
	}); code != exitOK {
		t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
	}
	got := so.String()
	if !strings.Contains(got, "published") {
		t.Fatalf("the --publish receipt does not report published:\n%s", got)
	}
	if strings.Contains(got, "NOT ON THE BOARD") || strings.Contains(got, "bp doc publish") {
		t.Errorf("a published row was told how to publish itself:\n%s", got)
	}
}

// THE MACHINE RECEIPT GETS A FIELD, NOT A SENTENCE. `status` already said
// "draft" and was misread; a caller branching in code needs one boolean that
// answers the question the verb's NAME made them ask.
func TestTaskCreateJSONReceiptCarriesOnBoardAndRemedy(t *testing.T) {
	ts := taskCreateStubMutate(t, "drafts.task-9")
	defer ts.Close()
	ctx := manifest.Context{Server: ts.URL, Dataset: "production", Token: "tok"}

	for _, tc := range []struct {
		name        string
		tail        []string
		wantOnBoard bool
	}{
		{"draft", []string{"a task"}, false},
		// Wall-passing body: --publish now refuses a row that could not clear the
		// server's publish wall, so a bare title here would test the refusal path.
		{"published", []string{"a task", "--publish", "--description", wallPassingDescription, "--set", wallPassingTags}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var so, se bytes.Buffer
			w := &writer{stdout: &so, stderr: &se, output: "json"}
			if code := runTaskCreate(w, globals{yes: true}, ctx, tc.tail); code != exitOK {
				t.Fatalf("runTaskCreate exit = %d, stderr: %s", code, se.String())
			}
			var receipt struct {
				OnBoard        *bool  `json:"on_board"`
				PublishCommand string `json:"publish_command"`
				Status         string `json:"status"`
			}
			if err := json.Unmarshal(so.Bytes(), &receipt); err != nil {
				t.Fatalf("receipt did not parse: %v (%q)", err, so.String())
			}
			if receipt.OnBoard == nil {
				t.Fatalf("receipt carries no on_board field — a script still has to infer the board state from `status` beside a `lifecycle_status` that says \"open\": %s", so.String())
			}
			if *receipt.OnBoard != tc.wantOnBoard {
				t.Errorf("on_board = %v, want %v (status %q)", *receipt.OnBoard, tc.wantOnBoard, receipt.Status)
			}
			if tc.wantOnBoard && receipt.PublishCommand != "" {
				t.Errorf("a published row carries publish_command %q", receipt.PublishCommand)
			}
			if !tc.wantOnBoard && receipt.PublishCommand != "bp doc publish task task-9 --yes" {
				t.Errorf("publish_command = %q, want the runnable command", receipt.PublishCommand)
			}
		})
	}
}

// THE REMEDY NAMES A COMMAND THAT EXISTS — the failure mode a handoff pointing
// at a nonexistent path has already cost this repo once. `bp task` has no
// `publish` verb (the server manifest declares only the lifecycle/read verbs,
// and cli.go intercepts exactly frontier / lint / create / next --frontier), so
// a remedy reading "bp task publish …" would send every reader to a usage
// error. The command this prints was RUN, not reasoned about: `bp doc publish
// task <id> --yes` is what put task-e72560e947dba4e6 on the board while this
// row was being built.
//
// HONEST LIMIT, stated rather than faked: `doc publish` is a MANIFEST verb
// resolved from GET /v1/capabilities, so no offline unit test can confirm the
// server still routes it — an earlier draft of this test grepped cli.go for it
// and failed, because it was never there to find. What IS checkable offline is
// the half that would actually rot: if someone ever adds a `bp task publish`
// intercept, this receipt should point at that friendlier verb instead, and
// this test reds to say so.
func TestTaskPublishCommandNamesARealVerb(t *testing.T) {
	got := taskPublishCommand("task-9")
	if strings.HasPrefix(got, "bp task publish") {
		t.Fatalf("the remedy names `bp task publish`, which is not a verb: %q", got)
	}
	if got != "bp doc publish task task-9 --yes" {
		t.Fatalf("taskPublishCommand = %q", got)
	}
	src, err := os.ReadFile("cli.go")
	if err != nil {
		t.Fatalf("cannot read cli.go to check the task intercepts: %v", err)
	}
	if strings.Contains(string(src), `if verb == "publish" {`) {
		t.Error("`bp task publish` now exists — point taskPublishCommand at it, so the remedy names the verb closest to what the reader just ran")
	}
}

// A census of 7691 type:task rows found 559 with NO acceptance_criteria key at
// all — invisible to the acceptance-criteria gate, because a counting sweep
// reads a missing key as zero obligations rather than obligations it cannot
// see. The cause was discoverability, not capability: --set has always taken
// the typed array, but the help never showed it, so filers reached for
// --description and wrote prose criteria instead. These assertions pin the two
// facts that close that gap — the copyable typed-JSON example, and that the
// same one flag also builds the brief's Criteria section (ensureTaskPortableBrief
// composes it from acceptance_criteria). Delete either line from
// printTaskCreateHelp and this test reds.
func TestTaskCreateHelpTeachesTypedAcceptanceCriteria(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	printTaskCreateHelp(w)

	out := stdout.String()
	for _, want := range []string{
		"acceptance_criteria:=",      // the typed --set form, copyable as-is
		`{"criterion":"gates green"`, // …carrying a real criterion object
		"Criteria",                   // the brief section the same flag builds
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("bp task create --help no longer teaches %q — filers fall back to prose criteria in --description, and the row lands with no acceptance_criteria key at all: %q", want, out)
		}
	}
}
