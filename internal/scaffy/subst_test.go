package scaffy

// subst_test.go — the D37/D33a runtime --var contract: missing,
// unknown and newline-bearing values rejected; OPAQUE verbatim; SHAPE
// ts14 re-validated against the supplied value; SUCCESSOR checked
// (after == before + 1), never computed; transform vars resolve
// through the four words.go joiners.

import (
	"errors"
	"strings"
	"testing"
)

func varCmd(decls ...*VariableDecl) *Command {
	return &Command{SourceFile: "test.scaffy", Variables: decls}
}

func mustSubst(t *testing.T, cmd *Command, vars map[string]string) *substituter {
	t.Helper()
	s, err := newSubstituter(cmd, vars)
	if err != nil {
		t.Fatalf("newSubstituter: %v", err)
	}
	return s
}

func wantVarError(t *testing.T, cmd *Command, vars map[string]string, fragment string) {
	t.Helper()
	_, err := newSubstituter(cmd, vars)
	if err == nil {
		t.Fatalf("want VarError containing %q, got nil", fragment)
	}
	var ve *VarError
	if !errors.As(err, &ve) {
		t.Fatalf("want *VarError, got %T: %v", err, err)
	}
	if !strings.Contains(err.Error(), fragment) {
		t.Fatalf("VarError %q does not mention %q", err.Error(), fragment)
	}
}

func TestTransformSpellings(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "BlockName"})
	s := mustSubst(t, cmd, map[string]string{"BlockName": "FancyQuote"})
	got, err := s.text("{{.BlockName}} {{.block-name}} {{.blockName}} {{.block_name}} {{.BLOCK_NAME}}", "test.scaffy", 1)
	if err != nil {
		t.Fatal(err)
	}
	want := "FancyQuote fancy-quote fancyQuote fancy_quote FANCY_QUOTE"
	if got != want {
		t.Fatalf("transform spellings: got %q, want %q", got, want)
	}
}

func TestScreamingCollapsePrecedence(t *testing.T) {
	// A one-word variable named in caps: the SCREAMING spelling of the
	// NAME ("NAME") must not shadow Pascal ("Name"), and a one-word
	// value keeps kebab==camel==snake collapsed to the kebab output —
	// SCREAMING rides last, so no pre-existing collapse resolution moves.
	cmd := varCmd(&VariableDecl{Name: "Name"})
	s := mustSubst(t, cmd, map[string]string{"Name": "probe"})
	got, err := s.text("{{.Name}} {{.name}} {{.NAME}}", "test.scaffy", 1)
	if err != nil {
		t.Fatal(err)
	}
	want := "Probe probe PROBE"
	if got != want {
		t.Fatalf("screaming precedence: got %q, want %q", got, want)
	}
}

func TestOpaqueNeverRecased(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "TableName", Opaque: true})
	s := mustSubst(t, cmd, map[string]string{"TableName": "USER_Accounts"})
	// Even a lowercase token spelling yields the verbatim value (D22).
	got, err := s.text("{{.table-name}}", "test.scaffy", 1)
	if err != nil {
		t.Fatal(err)
	}
	if got != "USER_Accounts" {
		t.Fatalf("OPAQUE re-cased: got %q, want verbatim USER_Accounts", got)
	}
}

func TestMissingVarRejected(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "BlockName"})
	wantVarError(t, cmd, map[string]string{}, "missing --var BlockName")
}

func TestUnknownVarRejected(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "BlockName"})
	wantVarError(t, cmd, map[string]string{"BlockName": "X", "Bogus": "Y"}, `unknown --var "Bogus"`)
}

func TestNewlineVarRejectedD33a(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "BlockName"})
	wantVarError(t, cmd, map[string]string{"BlockName": "Two\nLines"}, "newline")
	wantVarError(t, cmd, map[string]string{"BlockName": "CR\rToo"}, "newline")
}

func TestShapeTs14RevalidatedAtRunTime(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "Ts", Opaque: true, Shape: "ts14"})
	for _, bad := range []string{
		"2026071610000",   // 13 digits
		"202607161000000", // 15 digits
		"2026071610000x",  // non-digit
		"20261332000000",  // month 13 — not a real instant
	} {
		wantVarError(t, cmd, map[string]string{"Ts": bad}, "SHAPE ts14")
	}
	mustSubst(t, cmd, map[string]string{"Ts": "20260716100000"})
}

func TestSuccessorCheckedNeverComputed(t *testing.T) {
	cmd := varCmd(
		&VariableDecl{Name: "CountBefore", Opaque: true},
		&VariableDecl{Name: "CountAfter", Opaque: true, Successor: "CountBefore"},
	)
	// Both supplied and consecutive: fine.
	mustSubst(t, cmd, map[string]string{"CountBefore": "42", "CountAfter": "43"})
	// Off-by-more-than-one: rejected.
	wantVarError(t, cmd, map[string]string{"CountBefore": "42", "CountAfter": "45"}, "+ 1")
	// Non-integer pair: rejected.
	wantVarError(t, cmd, map[string]string{"CountBefore": "x", "CountAfter": "43"}, "integers")
	// The successor is never computed: omitting CountAfter is a missing
	// var, not a derivation (D37).
	wantVarError(t, cmd, map[string]string{"CountBefore": "42"}, "missing --var CountAfter")
}

func TestOneOfMemberAccepted(t *testing.T) {
	// OPAQUE + ONEOF: every declared member substitutes verbatim (D56).
	cmd := varCmd(&VariableDecl{Name: "Visibility", Opaque: true, OneOf: []string{"public", "private"}})
	for _, member := range []string{"public", "private"} {
		s := mustSubst(t, cmd, map[string]string{"Visibility": member})
		got, err := s.text("{{.Visibility}}", "test.scaffy", 1)
		if err != nil {
			t.Fatal(err)
		}
		if got != member {
			t.Fatalf("ONEOF member %q: substituted to %q", member, got)
		}
	}
}

func TestOneOfNonMemberRejected(t *testing.T) {
	// A --var value outside the set is a VarError (exit 2), like SHAPE.
	cmd := varCmd(&VariableDecl{Name: "Visibility", Opaque: true, OneOf: []string{"public", "private"}})
	wantVarError(t, cmd, map[string]string{"Visibility": "internal"}, "ONEOF")
	// The error names the offending value and the legal members.
	wantVarError(t, cmd, map[string]string{"Visibility": "internal"}, `"public", "private"`)
}

func TestOneOfTransformMemberAccepted(t *testing.T) {
	// A non-OPAQUE (transform) ONEOF variable accepts a member and still
	// resolves through the joiners.
	cmd := varCmd(&VariableDecl{Name: "Tier", OneOf: []string{"element", "widget", "section"}})
	s := mustSubst(t, cmd, map[string]string{"Tier": "widget"})
	got, err := s.text("{{.Tier}}", "test.scaffy", 1)
	if err != nil {
		t.Fatal(err)
	}
	if got != "Widget" {
		t.Fatalf("transform ONEOF Pascal spelling: got %q, want Widget", got)
	}
}

func TestUnknownTokenFails(t *testing.T) {
	cmd := varCmd(&VariableDecl{Name: "BlockName"})
	s := mustSubst(t, cmd, map[string]string{"BlockName": "X"})
	_, err := s.text("{{.Mystery}}", "test.scaffy", 7)
	if err == nil || !strings.Contains(err.Error(), "{{.Mystery}}") {
		t.Fatalf("unresolved token must fail with the token named, got %v", err)
	}
	if !strings.Contains(err.Error(), "test.scaffy:7") {
		t.Fatalf("unresolved-token error must carry file:line, got %v", err)
	}
}

func TestSnippetUseResolvesToBytes(t *testing.T) {
	// SNIPPET/USE resolution goes through the same substituter (D37).
	src := `COMMAND "add-note" DESCRIPTION "Snippet resolution." CONCEPT "note" DIRECTION "add"

VARIABLE 1 "NoteName" TITLE "Note" DESCRIPTION "Name." EXAMPLES "Alpha"

SNIPPET note-line
::: note-line body :::
note {{.note-name}} MARK:note-{{.note-name}}
::: note-line body :::

CREATE FILE IF ABSENT "docs/{{.note-name}}.txt"
USE note-line
`
	cmd, findings := Parse("use.scaffy", []byte(src))
	if len(findings) > 0 {
		t.Fatalf("fixture must parse clean: %v", findings)
	}
	s := mustSubst(t, cmd, map[string]string{"NoteName": "Alpha"})
	op := cmd.Ops[0].(*CreateFile)
	got, err := s.payloadBytes(cmd, op.Payload, "use.scaffy")
	if err != nil {
		t.Fatal(err)
	}
	want := "note alpha MARK:note-alpha\n"
	if string(got) != want {
		t.Fatalf("USE payload bytes: got %q, want %q", got, want)
	}
}
