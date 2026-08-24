package cli

import (
	"bytes"
	"strings"
	"testing"
)

// renderOf runs the full renderTable entry over a payload and returns stdout.
func renderOf(t *testing.T, payload string) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderTable(w, []byte(payload))
	if stderr.Len() != 0 {
		t.Fatalf("renderTable wrote to stderr: %q", stderr.String())
	}
	return stdout.String()
}

// The four admin/tenancy list verbs whose envelope key listEnvelopeKeys had
// drifted past. Each carried its rows under a key the renderer did not know, so
// renderKV handed the whole array to cellString, which truncates any nested
// value to cellMaxRunes display cells — one line of JSON ending in "...".
//
// token.ls is the one that cost something. It is the only way to enumerate the
// credentials that can reach a workspace and see which are still unrevoked, and
// against a live instance holding ~100 tokens it printed exactly:
//
//	tokens  [{"dataset":"production","expires_at":null,"id":"9e1eb0fc...
//
// Neither the ids `token revoke` takes as its argument nor the revoked_at the
// verb exists to report survived the cut, and the exit code was 0.
func TestListEnvelopesTabulateAdminVerbs(t *testing.T) {
	cases := []struct {
		name    string
		verb    string
		payload string
		// cols must appear as table headers; cells must appear as row values.
		cols  []string
		cells []string
	}{
		{
			name: "tokens",
			verb: "token ls",
			payload: `{"tokens":[
				{"id":"ac8ff595-deff-4c51-b251-0d05e8414184","label":"lead-verify-403fix","revoked_at":null},
				{"id":"9e1eb0fc-eff7-41e5-8e3e-7ae21e8ae2c9","label":"ssw8-probe","revoked_at":"2026-08-17T07:31:06Z"}]}`,
			cols:  []string{"id", "label", "revoked_at"},
			cells: []string{"lead-verify-403fix", "ssw8-probe", "2026-08-17T07:31:06Z"},
		},
		{
			name: "members",
			verb: "workspace member-ls",
			payload: `{"members":[
				{"identity":"frikk@guerrilla.no","role":"owner"},
				{"identity":"pelle@jarl.no","role":"member"}]}`,
			cols:  []string{"identity", "role"},
			cells: []string{"frikk@guerrilla.no", "pelle@jarl.no", "owner", "member"},
		},
		{
			name: "grants",
			verb: "access ls",
			payload: `{"grants":[
				{"id":"g1","subject":"u1","capability":"read"},
				{"id":"g2","subject":"u2","capability":"write"}]}`,
			cols:  []string{"id", "subject", "capability"},
			cells: []string{"u1", "u2", "read", "write"},
		},
		{
			name: "deliveries",
			verb: "webhook deliveries",
			payload: `{"deliveries":[
				{"id":"d1","status":"delivered","attempts":1},
				{"id":"d2","status":"failed","attempts":5}]}`,
			cols:  []string{"id", "status", "attempts"},
			cells: []string{"delivered", "failed"},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out := renderOf(t, c.payload)

			// The defect signature: the envelope key printed as a key/value
			// label with the whole array crammed beside it, cut off with "...".
			if strings.Contains(out, "...") {
				t.Errorf("`bp %s` truncated its rows into one cell:\n%s", c.verb, out)
			}
			if strings.HasPrefix(strings.TrimSpace(out), c.name+"  ") {
				t.Errorf("`bp %s` rendered the envelope key as a KV label, not a table:\n%s", c.verb, out)
			}
			for _, col := range c.cols {
				if !strings.Contains(out, col) {
					t.Errorf("`bp %s` table is missing column %q:\n%s", c.verb, col, out)
				}
			}
			for _, cell := range c.cells {
				if !strings.Contains(out, cell) {
					t.Errorf("`bp %s` dropped row value %q:\n%s", c.verb, cell, out)
				}
			}
			// A table, not a single line.
			if n := len(strings.Split(strings.TrimSpace(out), "\n")); n < 4 {
				t.Errorf("`bp %s` produced %d lines, want a header + separator + 2 rows:\n%s", c.verb, n, out)
			}
		})
	}
}

// The backstop: an envelope whose row key is in NO list still tabulates, so the
// next verb the API ships does not have to wait for someone to notice that its
// output collapsed. Sibling context is kept — workspace.dataset-ls answers
// {workspace, project, datasets} and dropping the first two to show the third
// would trade one silent withholding for another.
func TestUnknownListEnvelopeTabulatesAndKeepsSiblings(t *testing.T) {
	out := renderOf(t, `{
		"workspace":{"slug":"default","name":"Default"},
		"project":{"slug":"default","name":"Default"},
		"datasets":[{"id":"34d7f4ae","name":"production"},{"id":"7c1b2e90","name":"staging"}]}`)

	for _, want := range []string{"production", "staging", "34d7f4ae", "7c1b2e90"} {
		t.Run("row/"+want, func(t *testing.T) {
			if !strings.Contains(out, want) {
				t.Errorf("unknown envelope dropped %q:\n%s", want, out)
			}
		})
	}
	if !strings.Contains(out, "datasets:") {
		t.Errorf("rows are not labelled with the key they came under:\n%s", out)
	}
	// Sibling context survives: the datasets belong to a workspace/project, and
	// a reader who cannot see which learned less, not more.
	for _, want := range []string{"workspace", "project"} {
		if !strings.Contains(out, want) {
			t.Errorf("sibling context %q was dropped:\n%s", want, out)
		}
	}
}

// The backstop must not hijack a document. Envelope.render (api) flattens a
// document's content fields to the top level, so a doc.get payload can carry an
// array-of-objects field of its own — that array is the document's content, not
// rows about it, and the doc must still render as key/value lines.
func TestUnknownListEnvelopeRefusesADocument(t *testing.T) {
	out := renderOf(t, `{"_id":"post-1","_type":"post","title":"Hello",
		"body":[{"_type":"block","text":"one"},{"_type":"block","text":"two"}]}`)

	if strings.Contains(out, "body:") {
		t.Errorf("a document's content field was hijacked into a table:\n%s", out)
	}
	if !strings.Contains(out, "post-1") || !strings.Contains(out, "Hello") {
		t.Errorf("document key/value view lost its own fields:\n%s", out)
	}
}

// A scalar array has no columns to tabulate; promoting it to a one-column table
// would be noise. It stays a single key/value line.
func TestUnknownListEnvelopeLeavesScalarArraysAlone(t *testing.T) {
	out := renderOf(t, `{"ok":true,"names":["production","staging"]}`)
	if strings.Contains(out, "names:") {
		t.Errorf("a scalar array was promoted to a table:\n%s", out)
	}
	if !strings.Contains(out, "production") || !strings.Contains(out, "staging") {
		t.Errorf("scalar array values were dropped:\n%s", out)
	}
}
