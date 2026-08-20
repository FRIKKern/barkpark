package scaffy

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestGreenFixturesClean: the synthetic green corpus validates with
// zero findings — errors AND warns.
func TestGreenFixturesClean(t *testing.T) {
	for _, fx := range greenFixtures(t) {
		t.Run(fx, func(t *testing.T) {
			findings := ValidateFile(fx, readFixture(t, filepath.Join("green", fx)))
			for _, f := range findings {
				t.Errorf("unexpected finding: %s (hint: %s)", f, f.Hint)
			}
		})
	}
}

// expectation is one "# expect: RULE LINE" annotation in a red fixture.
type expectation struct {
	rule string
	line int
}

func parseExpectations(t *testing.T, name string, src []byte) []expectation {
	t.Helper()
	var exps []expectation
	for _, line := range strings.Split(string(src), "\n") {
		rest, ok := strings.CutPrefix(line, "# expect: ")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) != 2 {
			t.Fatalf("%s: malformed expectation %q", name, line)
		}
		n, err := strconv.Atoi(fields[1])
		if err != nil {
			t.Fatalf("%s: malformed expectation line %q", name, line)
		}
		exps = append(exps, expectation{rule: fields[0], line: n})
	}
	if len(exps) == 0 {
		t.Fatalf("%s carries no # expect: annotations", name)
	}
	return exps
}

// TestRedFixtures walks every adversarial fixture and asserts that
// validation reports each annotated RULE-ID at its exact file:line.
// The log output enumerates the rules as they are proven.
func TestRedFixtures(t *testing.T) {
	for _, fx := range redFixtures(t) {
		t.Run(fx, func(t *testing.T) {
			src := readFixture(t, filepath.Join("red", fx))
			exps := parseExpectations(t, fx, src)
			findings := ValidateFile(fx, src)
			for _, exp := range exps {
				found := false
				for _, f := range findings {
					if f.Rule == exp.rule && f.Line == exp.line {
						found = true
						if f.File != fx {
							t.Errorf("finding carries File %q, want %q", f.File, fx)
						}
						t.Logf("proven: %s at %s:%d — %s", exp.rule, fx, exp.line, f.Msg)
						break
					}
				}
				if !found {
					t.Errorf("want %s at line %d, got findings:\n%s", exp.rule, exp.line, renderFindings(findings))
				}
			}
		})
	}
}

// TestEveryRuleHasRedFixture: the catalog is fully adversarially
// covered — every rule ID in doc.go's Rules has at least one red
// fixture expecting it.
func TestEveryRuleHasRedFixture(t *testing.T) {
	covered := map[string]bool{}
	for _, fx := range redFixtures(t) {
		src := readFixture(t, filepath.Join("red", fx))
		for _, exp := range parseExpectations(t, fx, src) {
			if _, ok := RuleByID(exp.rule); !ok {
				t.Errorf("%s expects unknown rule %s", fx, exp.rule)
			}
			covered[exp.rule] = true
		}
	}
	for _, r := range Rules {
		if !covered[r.ID] {
			t.Errorf("rule %s (%s) has no adversarial red fixture", r.ID, r.Title)
		}
	}
}

// TestLegacyBugClasses pins the four W1/nextgen-era bug classes to
// their rules: each has a dedicated red fixture and reds with the
// expected RULE-ID.
func TestLegacyBugClasses(t *testing.T) {
	classes := map[string]struct {
		fixture string
		rule    string
	}{
		"quote-mismatch guard": {"E-006-quote-mismatch-guard.scaffy", RuleGuardNotDerived},
		"unfenced multi-line":  {"E-002-unfenced-payload.scaffy", RuleUnfenced},
		"undeclared token":     {"E-003-undeclared-token.scaffy", RuleUndeclaredToken},
		"missing MARK":         {"E-007-missing-mark.scaffy", RuleMissingMark},
	}
	for name, c := range classes {
		t.Run(name, func(t *testing.T) {
			src := readFixture(t, filepath.Join("red", c.fixture))
			findings := ValidateFile(c.fixture, src)
			for _, f := range findings {
				if f.Rule == c.rule {
					t.Logf("legacy class %q reds as %s: %s", name, c.rule, f)
					return
				}
			}
			t.Errorf("legacy class %q did not red with %s; findings:\n%s", name, c.rule, renderFindings(findings))
		})
	}
}

// TestLintOneOfExamplesOutsideSet: a declared EXAMPLES value outside the
// ONEOF set reds as E-021 at the VARIABLE line (D56).
func TestLintOneOfExamplesOutsideSet(t *testing.T) {
	src := []byte(`DIRECTION "add"
VARIABLE 1 "Visibility" ONEOF "public", "private" TITLE "t" DESCRIPTION "d" EXAMPLES "public", "internal"
ASSERT FILE "x/y.json" CONTAINS "{{.Visibility}}"
`)
	findings := ValidateFile("t.scaffy", src)
	got := 0
	for _, f := range findings {
		if f.Rule == RuleOneOf {
			got++
			if f.Line != 2 {
				t.Errorf("E-021 at line %d, want 2", f.Line)
			}
		}
	}
	if got != 1 {
		t.Errorf("want exactly one E-021, got %d; findings:\n%s", got, renderFindings(findings))
	}
}

// TestLintOneOfAllMembersClean: EXAMPLES wholly inside the ONEOF set
// yields no E-021.
func TestLintOneOfAllMembersClean(t *testing.T) {
	src := []byte(`DIRECTION "add"
VARIABLE 1 "Tier" ONEOF "element", "widget", "section" TITLE "t" DESCRIPTION "d" EXAMPLES "element", "section"
ASSERT FILE "x/y.ex" CONTAINS "@{{.Tier}} list"
`)
	for _, f := range ValidateFile("t.scaffy", src) {
		if f.Rule == RuleOneOf {
			t.Errorf("unexpected E-021 on all-member EXAMPLES: %s", f)
		}
	}
}

// TestValidateFileSortsFindings: findings come back ordered by line.
func TestValidateFileSortsFindings(t *testing.T) {
	src := []byte("ASLONG FILE CONTAIN \"x\"\nFROBNICATE\n")
	findings := ValidateFile("x.scaffy", src)
	if len(findings) < 2 {
		t.Fatalf("want ≥2 findings, got %v", findings)
	}
	for i := 1; i < len(findings); i++ {
		if findings[i].Line < findings[i-1].Line {
			t.Errorf("findings not sorted: %v", findings)
		}
	}
}

func greenFixtures(t *testing.T) []string {
	return fixtureNames(t, "green")
}

func redFixtures(t *testing.T) []string {
	names := fixtureNames(t, "red")
	if len(names) < len(Rules) {
		t.Fatalf("only %d red fixtures for %d rules", len(names), len(Rules))
	}
	return names
}

func fixtureNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join("testdata", dir))
	if err != nil {
		t.Fatalf("read testdata/%s: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".scaffy") {
			names = append(names, e.Name())
		}
	}
	return names
}

func renderFindings(fs []Finding) string {
	var b strings.Builder
	for _, f := range fs {
		b.WriteString("  " + f.String() + "\n")
	}
	if b.Len() == 0 {
		return "  (none)\n"
	}
	return b.String()
}
