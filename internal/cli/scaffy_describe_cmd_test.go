package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// descKindFixture exercises every synthesized-kind branch (OPAQUE+SHAPE,
// ONEOF, bare OPAQUE, bare SUCCESSOR, plain), both file ops, and all three
// assert tiers (a FILE CONTAINS, a LOCAL CMD, a TIER ci CMD).
const descKindFixture = `COMMAND "desc-fixture" DESCRIPTION "Describe fixture — every kind." DOMAIN "barkpark" TAGS "a", "b" CONCEPT "desc-fix" DIRECTION "add" VARIABLES
  VARIABLE 1 "Ts" OPAQUE SHAPE "ts14" TITLE "Stamp" DESCRIPTION "d" EXAMPLES "20260714150200"
  VARIABLE 2 "Tier" ONEOF "element", "widget", "section" TITLE "Tier" DESCRIPTION "d" EXAMPLES "element"
  VARIABLE 3 "CountBefore" OPAQUE TITLE "Before" DESCRIPTION "d" EXAMPLES "46"
  VARIABLE 4 "CountAfter" SUCCESSOR "CountBefore" TITLE "After" DESCRIPTION "d" EXAMPLES "47"
  VARIABLE 5 "Name" TITLE "Name" DESCRIPTION "d" EXAMPLES "Alpha"

CREATE FILE IF ABSENT "docs/{{.name}}.txt"
::: body :::
hello {{.name}}
::: body :::

IN "docs/list.txt"
INSERT AFTER LAST
::: anchor :::
tail-anchor
::: anchor :::
WITH
::: entry :::
entry {{.name}} MARK:e-{{.name}}
::: entry :::
MARK "e-{{.name}}"

ASSERT FILE "docs/{{.name}}.txt" CONTAINS "hello {{.name}}"
ASSERT CMD "true"
ASSERT CMD "cd api && mix test" TIER ci
`

// describeEnvelope is the -o json shape of `bp scaffy describe`.
type describeEnvelope struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Direction   string         `json:"direction"`
	Domain      string         `json:"domain"`
	Tags        string         `json:"tags"`
	Variables   []describeVar  `json:"variables"`
	Ops         map[string]int `json:"ops"`
	Asserts     []describeAssert `json:"asserts"`
}

type describeVar struct {
	Name     string   `json:"name"`
	Kind     string   `json:"kind"`
	Title    string   `json:"title"`
	OneOf    []string `json:"oneof"`
	Examples []string `json:"examples"`
}

type describeAssert struct {
	Kind string `json:"kind"`
	Tier string `json:"tier"`
	Text string `json:"text"`
}

func describeJSON(t *testing.T, path string) describeEnvelope {
	t.Helper()
	code, stdout, stderr := runScaffyTest(t, globals{}, "json", "describe", path)
	if code != exitOK {
		t.Fatalf("describe %s exit = %d, want %d\n%s\n%s", path, code, exitOK, stdout, stderr)
	}
	var env describeEnvelope
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("stdout is not a JSON envelope: %v\n%s", err, stdout)
	}
	return env
}

// TestScaffyDescribeSynthesizedKinds pins the whole contract byte-exactly:
// every synthesized variable kind, both op-count keys, and the assert
// {kind,tier,text} rows for a command exercising OPAQUE/SHAPE/ONEOF/SUCCESSOR
// and a TIER ci assert.
func TestScaffyDescribeSynthesizedKinds(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "desc-fixture.scaffy")
	if err := os.WriteFile(path, []byte(descKindFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	env := describeJSON(t, path)

	if env.Name != "desc-fixture" || env.Direction != "add" || env.Domain != "barkpark" || env.Tags != "a, b" {
		t.Errorf("header = %+v, want name=desc-fixture direction=add domain=barkpark tags=\"a, b\"", env)
	}

	// Synthesized kinds, in declaration order — the precedence law (OPAQUE
	// wins over SUCCESSOR on CountAfter's sibling; a bare SUCCESSOR reads
	// "successor").
	wantKinds := map[string]string{
		"Ts":          "opaque shape:ts14",
		"Tier":        "enum",
		"CountBefore": "opaque",
		"CountAfter":  "successor",
		"Name":        "plain",
	}
	if len(env.Variables) != 5 {
		t.Fatalf("got %d variables, want 5: %+v", len(env.Variables), env.Variables)
	}
	for _, v := range env.Variables {
		if want := wantKinds[v.Name]; v.Kind != want {
			t.Errorf("variable %s kind = %q, want %q", v.Name, v.Kind, want)
		}
	}
	// ONEOF surfaces on the enum variable.
	for _, v := range env.Variables {
		if v.Name == "Tier" {
			if len(v.OneOf) != 3 || v.OneOf[0] != "element" || v.OneOf[2] != "section" {
				t.Errorf("Tier oneof = %v, want [element widget section]", v.OneOf)
			}
		}
	}

	// Op counts keyed by shape.
	wantOps := map[string]int{"create_file": 1, "in.insert_after_last": 1}
	if len(env.Ops) != len(wantOps) {
		t.Errorf("ops = %v, want %v", env.Ops, wantOps)
	}
	for k, want := range wantOps {
		if env.Ops[k] != want {
			t.Errorf("ops[%q] = %d, want %d (all: %v)", k, env.Ops[k], want, env.Ops)
		}
	}

	// Asserts: {kind, tier, text}; tier "" reads "local", TIER ci reads "ci".
	if len(env.Asserts) != 3 {
		t.Fatalf("got %d asserts, want 3: %+v", len(env.Asserts), env.Asserts)
	}
	wantAsserts := []describeAssert{
		{Kind: "file_contains", Tier: "local", Text: "hello {{.name}}"},
		{Kind: "cmd", Tier: "local", Text: "true"},
		{Kind: "cmd", Tier: "ci", Text: "cd api && mix test"},
	}
	for i, want := range wantAsserts {
		if env.Asserts[i] != want {
			t.Errorf("assert %d = %+v, want %+v", i, env.Asserts[i], want)
		}
	}
}

// TestScaffyDescribeCorpusAddMigration proves the shape:ts14 + opaque showcase
// against the real committed command (D102 evidence).
func TestScaffyDescribeCorpusAddMigration(t *testing.T) {
	path := filepath.Join(scaffyCorpusDir, "add-migration.scaffy")
	if _, err := os.Stat(path); err != nil {
		t.Skipf("corpus not present: %v", err)
	}
	env := describeJSON(t, path)
	if env.Direction != "add" {
		t.Errorf("direction = %q, want add", env.Direction)
	}
	var ts describeVar
	for _, v := range env.Variables {
		if v.Name == "Ts" {
			ts = v
		}
	}
	if ts.Kind != "opaque shape:ts14" {
		t.Errorf("add-migration Ts kind = %q, want opaque shape:ts14", ts.Kind)
	}
	if env.Ops["create_file"] != 1 {
		t.Errorf("add-migration ops[create_file] = %d, want 1 (all: %v)", env.Ops["create_file"], env.Ops)
	}
}

// TestScaffyDescribeCorpusClassifyBlockType proves the enum-via-ONEOF showcase
// against the real committed command (D102 evidence).
func TestScaffyDescribeCorpusClassifyBlockType(t *testing.T) {
	path := filepath.Join(scaffyCorpusDir, "classify-block-type.scaffy")
	if _, err := os.Stat(path); err != nil {
		t.Skipf("corpus not present: %v", err)
	}
	env := describeJSON(t, path)
	var tier describeVar
	for _, v := range env.Variables {
		if v.Name == "Tier" {
			tier = v
		}
	}
	if tier.Kind != "enum" {
		t.Errorf("classify-block-type Tier kind = %q, want enum", tier.Kind)
	}
	if len(tier.OneOf) != 3 {
		t.Errorf("classify-block-type Tier oneof = %v, want 3 members", tier.OneOf)
	}
	if env.Ops["in.insert_after_first"] != 1 {
		t.Errorf("classify-block-type ops[in.insert_after_first] = %d, want 1 (all: %v)", env.Ops["in.insert_after_first"], env.Ops)
	}
}

// TestScaffyDescribeResolution covers the path/name/.scaffy-suffix resolver
// (bare name and auto-suffix) from a controlled cwd.
func TestScaffyDescribeResolution(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "foo.scaffy"), []byte(descKindFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(orig)

	// Bare name (no .scaffy suffix) resolves to foo.scaffy in the cwd.
	if got, err := resolveScaffyDescribeTarget("foo"); err != nil || got != "foo.scaffy" {
		t.Errorf("resolve(foo) = %q, %v; want foo.scaffy, nil", got, err)
	}
	// Explicit filename resolves verbatim.
	if got, err := resolveScaffyDescribeTarget("foo.scaffy"); err != nil || got != "foo.scaffy" {
		t.Errorf("resolve(foo.scaffy) = %q, %v; want foo.scaffy, nil", got, err)
	}
	// A miss is fs.ErrNotExist-shaped.
	if _, err := resolveScaffyDescribeTarget("nope"); err == nil {
		t.Error("resolve(nope) should error")
	}
}

// TestScaffyDescribeExitCodes pins the usage/not-found exit scheme.
func TestScaffyDescribeExitCodes(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want int
	}{
		{"no positional", []string{"describe"}, exitUsage},
		{"two positionals", []string{"describe", "a", "b"}, exitUsage},
		{"unknown flag", []string{"describe", "--nope", "x"}, exitUsage},
		{"missing file", []string{"describe", "/no/such/command.scaffy"}, exitNotFound},
	}
	for _, c := range cases {
		code, stdout, stderr := runScaffyTest(t, globals{}, "", c.args...)
		if code != c.want {
			t.Errorf("%s: exit = %d, want %d\n%s\n%s", c.name, code, c.want, stdout, stderr)
		}
	}
}

// TestScaffyDescribeHumanRender smoke-checks the human sections render.
func TestScaffyDescribeHumanRender(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "desc-fixture.scaffy")
	if err := os.WriteFile(path, []byte(descKindFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	code, stdout, _ := runScaffyTest(t, globals{}, "", "describe", path)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\n%s", code, exitOK, stdout)
	}
	for _, want := range []string{"desc-fixture — direction add", "variables:", "Ts  opaque shape:ts14", "ops:", "create_file  1", "asserts:", "cmd  ci"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("human render missing %q:\n%s", want, stdout)
		}
	}
}
