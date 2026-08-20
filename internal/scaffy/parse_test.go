package scaffy

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func readFixture(t *testing.T, rel string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", rel))
	if err != nil {
		t.Fatalf("read fixture %s: %v", rel, err)
	}
	return b
}

// TestParseGreenFullGrammar drives the full pinned grammar through one
// add-direction fixture: header incl. DIRECTION, OPAQUE / SHAPE "ts14" /
// SUCCESSOR variable annotations, SNIPPET/USE, CREATE (incl. the
// empty-fence 0-byte case), INSERT AFTER FIRST/LAST, REPLACE + REANCHOR,
// MARK / MARK VIRTUAL, ASLONG, ASSERT FILE CONTAINS/EXISTS and ASSERT
// CMD (+ TIER ci).
func TestParseGreenFullGrammar(t *testing.T) {
	src := readFixture(t, "green/add-widget.scaffy")
	cmd, findings := Parse("add-widget.scaffy", src)
	if len(findings) != 0 {
		t.Fatalf("unexpected parse findings: %v", findings)
	}

	if got := cmd.Direction(); got != "add" {
		t.Errorf("Direction() = %q, want add", got)
	}
	if cmd.Header.Command == nil || cmd.Header.Command.Value != "add-widget" {
		t.Errorf("header COMMAND not parsed: %+v", cmd.Header.Command)
	}
	if cmd.Header.LastUpdated == nil || cmd.Header.LastUpdated.Value != "16-07-2026-10-00-00" {
		t.Errorf("header LAST_UPDATED not parsed: %+v", cmd.Header.LastUpdated)
	}

	if len(cmd.Variables) != 4 {
		t.Fatalf("got %d variables, want 4", len(cmd.Variables))
	}
	ts := cmd.Variables[1]
	if !ts.Opaque || ts.Shape != "ts14" {
		t.Errorf("Ts should be OPAQUE SHAPE ts14, got opaque=%v shape=%q", ts.Opaque, ts.Shape)
	}
	after := cmd.Variables[3]
	if !after.Opaque || after.Successor != "CountBefore" {
		t.Errorf("CountAfter should be OPAQUE SUCCESSOR CountBefore, got opaque=%v successor=%q", after.Opaque, after.Successor)
	}

	if len(cmd.Snippets) != 1 || cmd.Snippets[0].Name != "widget-div" {
		t.Fatalf("snippets = %+v, want one named widget-div", cmd.Snippets)
	}
	if cmd.Snippet("widget-div") == nil {
		t.Error("Snippet lookup failed")
	}

	if len(cmd.Ops) != 8 {
		t.Fatalf("got %d ops, want 8", len(cmd.Ops))
	}
	var creates []*CreateFile
	var inOps []*InOp
	for _, op := range cmd.Ops {
		switch o := op.(type) {
		case *CreateFile:
			creates = append(creates, o)
		case *InOp:
			inOps = append(inOps, o)
		}
	}
	if len(creates) != 4 || len(inOps) != 4 {
		t.Fatalf("got %d creates + %d in-ops, want 4 + 4", len(creates), len(inOps))
	}

	// D26: an empty fence spells a 0-byte file.
	if b := creates[1].Payload.Fenced.Bytes(); len(b) != 0 {
		t.Errorf("empty fence payload = %d bytes, want 0", len(b))
	}
	// SNIPPET/USE.
	if creates[2].Payload.Use != "widget-div" {
		t.Errorf("create #3 payload = %+v, want USE widget-div", creates[2].Payload)
	}

	wantVerbs := []InOpVerb{InsertAfterFirst, InsertAfterLast, Replace, Replace}
	for i, o := range inOps {
		if o.Verb != wantVerbs[i] {
			t.Errorf("in-op %d verb = %s, want %s", i, o.Verb, wantVerbs[i])
		}
	}
	cron := inOps[2]
	if cron.Path == nil || cron.Path.Value != "api/config/config.exs" {
		t.Errorf("cron op path = %+v", cron.Path)
	}
	if cron.Mark == nil || cron.Mark.Virtual || cron.Mark.Name != "cron-{{.widget-name}}" {
		t.Errorf("cron mark = %+v", cron.Mark)
	}
	if cron.Reanchor == nil || cron.Reanchor.Prefix != "cron-" {
		t.Errorf("cron REANCHOR = %+v, want prefix cron-", cron.Reanchor)
	}
	if len(cron.Guards) != 1 || !cron.Guards[0].Dont {
		t.Errorf("cron guards = %+v, want one DONT CONTAIN", cron.Guards)
	}
	bump := inOps[3]
	if bump.Mark == nil || !bump.Mark.Virtual {
		t.Errorf("count-bump mark = %+v, want VIRTUAL", bump.Mark)
	}

	if len(cmd.Asserts) != 5 {
		t.Fatalf("got %d asserts, want 5", len(cmd.Asserts))
	}
	wantKinds := []AssertKind{AssertFileContains, AssertFileExists, AssertFileContains, AssertCmd, AssertCmd}
	for i, a := range cmd.Asserts {
		if a.Kind != wantKinds[i] {
			t.Errorf("assert %d kind = %s, want %s", i, a.Kind, wantKinds[i])
		}
	}
	if tier := cmd.Asserts[4].Tier; tier != "ci" {
		t.Errorf("last assert tier = %q, want ci", tier)
	}
}

// TestParseGreenRemoveDirection covers the remove half of the grammar:
// REMOVE with a consumed mark, DELETE FILE IF PRESENT + positive
// ASLONG, ASSERT FILE ABSENT / DONT CONTAIN.
func TestParseGreenRemoveDirection(t *testing.T) {
	src := readFixture(t, "green/remove-widget.scaffy")
	cmd, findings := Parse("remove-widget.scaffy", src)
	if len(findings) != 0 {
		t.Fatalf("unexpected parse findings: %v", findings)
	}
	if got := cmd.Direction(); got != "remove" {
		t.Errorf("Direction() = %q, want remove", got)
	}
	if len(cmd.Ops) != 2 {
		t.Fatalf("got %d ops, want 2", len(cmd.Ops))
	}
	rm, ok := cmd.Ops[0].(*InOp)
	if !ok || rm.Verb != RemoveVerb {
		t.Fatalf("op 0 = %#v, want REMOVE", cmd.Ops[0])
	}
	if rm.Payload != nil {
		t.Errorf("REMOVE carries a payload: %+v", rm.Payload)
	}
	if len(rm.Guards) != 1 || rm.Guards[0].Dont {
		t.Errorf("REMOVE guards = %+v, want one positive CONTAIN", rm.Guards)
	}
	del, ok := cmd.Ops[1].(*DeleteFile)
	if !ok {
		t.Fatalf("op 1 = %#v, want DELETE FILE", cmd.Ops[1])
	}
	if len(del.Guards) != 1 {
		t.Errorf("DELETE guards = %+v, want one", del.Guards)
	}
	if len(cmd.Asserts) != 2 || cmd.Asserts[0].Kind != AssertFileAbsent || cmd.Asserts[1].Kind != AssertFileDontContain {
		t.Errorf("asserts = %+v, want ABSENT + DONT CONTAIN", cmd.Asserts)
	}
}

// TestPositionsOnEveryNode reflect-walks the green ASTs and requires
// every position field (Pos, InPos) to carry a real 1-based line.
func TestPositionsOnEveryNode(t *testing.T) {
	for _, fx := range []string{"green/add-widget.scaffy", "green/remove-widget.scaffy"} {
		cmd, _ := Parse(fx, readFixture(t, fx))
		walkPositions(t, reflect.ValueOf(cmd), "Command")
	}
}

func walkPositions(t *testing.T, v reflect.Value, path string) {
	t.Helper()
	switch v.Kind() {
	case reflect.Ptr, reflect.Interface:
		if !v.IsNil() {
			walkPositions(t, v.Elem(), path)
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			walkPositions(t, v.Index(i), path)
		}
	case reflect.Struct:
		typ := v.Type()
		for i := 0; i < v.NumField(); i++ {
			f := typ.Field(i)
			if !f.IsExported() {
				continue
			}
			fv := v.Field(i)
			if f.Type == reflect.TypeOf(Pos{}) {
				// Pos-named fields are mandatory on every node; other
				// *Pos fields (ShapePos, TierPos, …) are set only when
				// their clause is present.
				if (f.Name == "Pos" || f.Name == "InPos") && fv.Interface().(Pos).Line < 1 {
					t.Errorf("%s.%s has no position", v.Type().Name(), f.Name)
				}
				continue
			}
			walkPositions(t, fv, path+"."+f.Name)
		}
	}
}

// TestParseCorpusSpellings pins the three spellings the live corpus
// (scaffy/commands/*.scaffy, the normative source) uses that the green
// fixtures do not: the whole header as ONE line ending in the bare
// VARIABLES keyword, TAGS/EXAMPLES as comma-separated quoted lists, and
// CREATE introduced by a bare WITH line before its fenced payload.
func TestParseCorpusSpellings(t *testing.T) {
	src := []byte(`COMMAND "Add Widget" DESCRIPTION "d." LAST_UPDATED "16-07-2026-00-00-00" DOMAIN "barkpark" TAGS "scaffy", "widget", "demo" CONCEPT "widget" VARIANT "starter" DIRECTION "add" VARIABLES
  VARIABLE 1 "WidgetName" TITLE "t" DESCRIPTION "d" EXAMPLES "Timeline", "FactBox", "Milestone"

CREATE FILE IF ABSENT "internal/widgets/{{.widget_name}}.go"
WITH
::: {{.widget-name}} module :::
package widgets
::: {{.widget-name}} module :::
`)
	cmd, findings := Parse("corpus-spellings.scaffy", src)
	if len(findings) != 0 {
		t.Fatalf("unexpected parse findings: %v", findings)
	}
	if got := cmd.Direction(); got != "add" {
		t.Errorf("Direction() = %q, want add (one-line header)", got)
	}
	if cmd.Header.Tags == nil || cmd.Header.Tags.Value != "scaffy, widget, demo" {
		t.Errorf("TAGS list = %+v", cmd.Header.Tags)
	}
	if cmd.Header.Variant == nil || cmd.Header.Variant.Value != "starter" {
		t.Errorf("VARIANT = %+v", cmd.Header.Variant)
	}
	if len(cmd.Variables) != 1 || len(cmd.Variables[0].Examples) != 3 || cmd.Variables[0].Examples[2] != "Milestone" {
		t.Errorf("EXAMPLES list = %+v", cmd.Variables)
	}
	if len(cmd.Ops) != 1 {
		t.Fatalf("ops = %d, want 1", len(cmd.Ops))
	}
	cf, ok := cmd.Ops[0].(*CreateFile)
	if !ok || cf.Payload == nil || cf.Payload.Fenced == nil || len(cf.Payload.Fenced.Lines) != 1 {
		t.Errorf("CREATE … WITH payload not parsed: %#v", cmd.Ops[0])
	}
	// The one-line header and the comma lists are fmt fixpoints.
	out, err := Format(src)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != string(src) {
		t.Errorf("corpus spellings are not a fmt fixpoint\n--- got ---\n%s--- want ---\n%s", out, src)
	}
}

// TestParseOneOf pins the D56 ONEOF parse: the comma-separated quoted
// enum set lands in VariableDecl.OneOf (in order), OneOfPos carries the
// declaration line, and the keyword coexists with OPAQUE + the rest.
func TestParseOneOf(t *testing.T) {
	src := []byte(`DIRECTION "add"
VARIABLE 1 "Visibility" OPAQUE ONEOF "public", "private" TITLE "t" DESCRIPTION "d" EXAMPLES "public"
ASSERT FILE "x/{{.Visibility}}.json" EXISTS
`)
	cmd, findings := Parse("oneof.scaffy", src)
	if len(findings) != 0 {
		t.Fatalf("unexpected parse findings: %v", findings)
	}
	if len(cmd.Variables) != 1 {
		t.Fatalf("got %d variables, want 1", len(cmd.Variables))
	}
	v := cmd.Variables[0]
	if !v.Opaque {
		t.Errorf("OPAQUE not parsed alongside ONEOF")
	}
	want := []string{"public", "private"}
	if !reflect.DeepEqual(v.OneOf, want) {
		t.Errorf("OneOf = %v, want %v", v.OneOf, want)
	}
	if v.OneOfPos.Line != 2 {
		t.Errorf("OneOfPos.Line = %d, want 2", v.OneOfPos.Line)
	}
	if len(v.Examples) != 1 || v.Examples[0] != "public" {
		t.Errorf("EXAMPLES = %v, want [public]", v.Examples)
	}
}

// TestParseUnknownVariableKeywordNamesOneOf: the unknown-keyword hint
// lists ONEOF among the legal keywords (D56, parse.go:373).
func TestParseUnknownVariableKeywordNamesOneOf(t *testing.T) {
	src := []byte(`DIRECTION "add"
VARIABLE 1 "X" BOGUS "y" TITLE "t" DESCRIPTION "d" EXAMPLES "z"
`)
	_, findings := Parse("bad.scaffy", src)
	found := false
	for _, f := range findings {
		if f.Rule == RuleMalformedStatement && strings.Contains(f.Hint, "ONEOF") {
			found = true
		}
	}
	if !found {
		t.Errorf("unknown-keyword hint does not mention ONEOF; findings: %v", findings)
	}
}

// TestParseFailsLoud pins the doctrine inversion: where mermaid.go
// silently skips unparseable lines, scaffy reports them.
func TestParseFailsLoud(t *testing.T) {
	_, findings := Parse("x.scaffy", []byte("DIRECTION \"add\"\nGIBBERISH LINE HERE\n"))
	if len(findings) == 0 {
		t.Fatal("unparseable statement produced no findings — silent skip is forbidden")
	}
	f := findings[0]
	if f.Rule != RuleUnknownStatement || f.Line != 2 || f.File != "x.scaffy" {
		t.Errorf("finding = %+v, want P-001 at x.scaffy:2", f)
	}
	if f.String() != "x.scaffy:2: P-001 unknown statement \"GIBBERISH\"" {
		t.Errorf("String() = %q", f.String())
	}
}
