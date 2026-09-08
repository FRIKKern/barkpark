package cli

// stamp_body_prose_test.go pins WHERE `bp task stamp` puts its prose.
//
// THE DEFECT THIS CLOSES, measured on task-b71ece4e1a8d1f6d rather than reasoned:
// evidence rode the QUERY STRING, so the quantity the server refused was the
// ENCODED REQUEST LINE. A stamp whose URI reaches 9,933 bytes is refused 3/3 as
// `stream error: … INTERNAL_ERROR; received from peer`; 9,913 bytes lands 2/2.
// The refusal names no field, no bound and no unit, and is DETERMINISTIC WHILE
// LOOKING TRANSIENT — which invites retry, then "the ledger is flaky tonight".
//
// A LIMIT CHECK COULD NOT HAVE FIXED IT: a server cannot describe a request it
// never finished parsing. Moving the prose off the request line is the only
// repair that also makes a good message reachable.
//
// WHAT THE ASSERTIONS ARE FOR. It is easy to write a test that passes because
// the flag is absent from the query and never notice it went nowhere at all —
// evidence silently dropped is far worse than evidence in the wrong place, since
// the server would then refuse with "--met requires non-empty --evidence" and
// the caller would blame their own command. So every case asserts BOTH halves:
// absent from the query AND present in the body, by value.

import (
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func stampCmd() manifest.Command {
	return manifest.Command{
		ID:     "task.stamp",
		Writes: true,
		HTTP:   manifest.HTTP{Method: "POST", PathTemplate: "/v1/tasks/:doc_id/stamp"},
		Args: []manifest.Arg{
			{Name: "doc_id"}, {Name: "worker_id"}, {Name: "observed_epoch"},
		},
		Flags: []manifest.Flag{
			{Name: "criterion"}, {Name: "criterion-text"}, {Name: "met", Type: "bool"},
			{Name: "evidence"}, {Name: "miss", Type: "bool"}, {Name: "note"},
		},
	}
}

func TestStampProseRidesTheBodyNotTheQuery(t *testing.T) {
	cmd := stampCmd()

	for _, name := range []string{"evidence", "note"} {
		if !commandFlagBelongsInBody(cmd, name) {
			t.Errorf("stamp --%s must ride the BODY: in the query it rides the request "+
				"line, which is where the ~9.9KB wall is", name)
		}
	}

	// criterion-text STAYS in the query, deliberately: the server reads
	// "criterion_text"/"criterion-text" but not the camelCase "criterionText"
	// that bodyFlagKey produces for a hyphenated name. Pinning it keeps a future
	// "move everything" change from silently breaking the off-by-one guard —
	// which would fail OPEN, since a missing criterion-text is a 409 the caller
	// sees rather than a silent flip.
	if commandFlagBelongsInBody(cmd, "criterion-text") {
		t.Errorf("criterion-text must stay in the query until a key-preserving body "+
			"path exists: bodyFlagKey(%q) = %q, which the server does not read",
			"criterion-text", bodyFlagKey("criterion-text"))
	}

	// NON-VACUITY: the helper must not simply say "body" for everything on this
	// command, or the two assertions above pass while proving nothing.
	if commandFlagBelongsInBody(cmd, "criterion") {
		t.Error("control failed: --criterion is a scalar index and belongs in the " +
			"query; a helper that says body for every flag has not been shown to " +
			"discriminate")
	}
	if commandFlagBelongsInBody(cmd, "met") {
		t.Error("control failed: --met is a bool and belongs in the query")
	}

	// AND THE RULE MUST BE SCOPED TO THIS COMMAND. `evidence` and `note` are
	// ordinary names; a rule keyed on the NAME alone would move them on every
	// command that happens to declare one.
	other := manifest.Command{
		ID: "task.landed", Writes: true,
		HTTP: manifest.HTTP{Method: "POST", PathTemplate: "/v1/tasks/:doc_id/landed"},
	}
	if commandFlagBelongsInBody(other, "note") {
		t.Error("the rule leaked: task.landed --note must be unaffected — this rule " +
			"is keyed on the command id, not on the flag name")
	}
}

// TestStampBodyKeysSurviveEncoding checks the names the server actually reads.
// TasksController.stamp/2 does Map.get(params, "evidence") and "note" off the
// query+body merge, so the body keys must be those exact strings. bodyFlagKey
// camelCases hyphenated names, and a silent rename here would drop the evidence
// on the floor while the request still looked well-formed.
func TestStampBodyKeysAreWhatTheServerReads(t *testing.T) {
	for _, name := range []string{"evidence", "note"} {
		if got := bodyFlagKey(name); got != name {
			t.Errorf("bodyFlagKey(%q) = %q — the server reads %q off the merged "+
				"params, so a renamed key arrives as no key at all", name, got, name)
		}
	}
	// The control that gives the assertion above meaning: bodyFlagKey DOES
	// rename hyphenated names, so "unchanged" is a real property of these two
	// rather than a function that never renames anything.
	if got := bodyFlagKey("criterion-text"); got == "criterion-text" {
		t.Error("control failed: bodyFlagKey no longer camelCases hyphenated names, " +
			"so the check above proves nothing")
	}
}

// TestStampRequestShape drives the real query/body builders and asserts the
// wire shape end to end, because the unit checks above only pin the predicate.
func TestStampRequestShape(t *testing.T) {
	cmd := stampCmd()
	longProse := strings.Repeat("evidence prose with spaces, commas — and dashes. ", 200)

	flags := map[string][]string{
		"criterion":      {"2"},
		"criterion-text": {"the criterion wording"},
		"met":            {"true"},
		"evidence":       {longProse},
	}
	args := map[string]string{
		"doc_id": "task-abc", "worker_id": "w", "observed_epoch": "3",
	}

	raw := applyQuery("https://x/v1/tasks/task-abc/stamp", globals{}, cmd, flags, args)
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("applyQuery produced an unparseable URL: %v", err)
	}
	q := u.Query()
	if q.Get("evidence") != "" {
		t.Fatalf("evidence is STILL in the query (%d bytes) — the wall is on the "+
			"request line, so this change did nothing", len(q.Get("evidence")))
	}
	if q.Get("criterion") != "2" || q.Get("met") != "true" {
		t.Fatalf("the scalars must stay in the query: criterion=%q met=%q",
			q.Get("criterion"), q.Get("met"))
	}
	if q.Get("criterion-text") == "" {
		t.Fatal("criterion-text must stay in the query — it is the off-by-one guard")
	}

	body, _, _, err := buildBody(cmd, flags, args)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body is not JSON: %v — %s", err, string(body))
	}
	if got["evidence"] != longProse {
		t.Fatalf("evidence did not arrive in the body by value; body keys = %v. "+
			"Evidence DROPPED is worse than evidence misplaced: the server would "+
			"answer \"--met requires non-empty --evidence\" and the caller would "+
			"blame their own command.", stampBodyKeys(got))
	}
}

func stampBodyKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
