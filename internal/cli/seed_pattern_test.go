package cli

import (
	"encoding/json"
	"regexp"
	"testing"
)

// TestFakeValueMatchesItsPattern pins that bp seed fills a pattern-validated
// string field with a value the pattern accepts. Content.Validation checks the
// pattern (advisory at the write door, a refusal on Studio save), so a violating
// placeholder seeds documents Studio then refuses to save. Before the fix every patterned field
// got "<name>-<n>", which fails all of these but the slug regex with digits.
func TestFakeValueMatchesItsPattern(t *testing.T) {
	patterns := map[string]string{
		"code":     `^[a-z-]+$`,
		"isbn":     `^\d{13}$`,
		"sku":      `^[A-Z]{3}-\d{4}$`,
		"slug":     `^[a-z0-9]+(?:-[a-z0-9]+)*$`,
		"email":    `^[^@\s]+@[^@\s]+\.[a-z]{2,}$`,
		"hex":      `^#[0-9a-fA-F]{6}$`,
		"year":     `^(19|20)\d{2}$`,
		"lang":     `^(nb|nn|en)$`,
		"postcode": `^\d{4}$`,
	}
	for name, pat := range patterns {
		raw, _ := json.Marshal(pat)
		f := seedField{Name: name, Type: "string", Validation: map[string]json.RawMessage{"pattern": raw}}
		re := regexp.MustCompile(pat)
		for _, n := range []int{1, 2, 7, 12} {
			v, ok := fakeValue(f, n).(string)
			if !ok || !re.MatchString(v) {
				t.Errorf("%s n=%d: seeded %q, which pattern %s rejects", name, n, v, pat)
			}
		}
	}
}

// TestFakeValuePatternKeepsReadableSlugs pins that a pattern the old
// "<name>-<n>" placeholder already satisfied keeps that value.
func TestFakeValuePatternKeepsReadableSlugs(t *testing.T) {
	raw, _ := json.Marshal(`^[a-z0-9-]+$`)
	f := seedField{Name: "handle", Type: "string", Validation: map[string]json.RawMessage{"pattern": raw}}
	if got := fakeValue(f, 3); got != "handle-3" {
		t.Errorf("got %q, want handle-3", got)
	}
}

// TestFakeValuePatternDistinctPerDoc pins that a digits-only or letters-only pattern still
// gives each seeded document its own value.
func TestFakeValuePatternDistinctPerDoc(t *testing.T) {
	raw, _ := json.Marshal(`^\d{13}$`)
	f := seedField{Name: "isbn", Type: "string", Validation: map[string]json.RawMessage{"pattern": raw}}
	if a, b := fakeValue(f, 1), fakeValue(f, 2); a == b {
		t.Errorf("n=1 and n=2 both seeded %q", a)
	}
	raw, _ = json.Marshal(`^[a-z-]+$`)
	f = seedField{Name: "code", Type: "string", Validation: map[string]json.RawMessage{"pattern": raw}}
	if a, b := fakeValue(f, 1), fakeValue(f, 2); a == b {
		t.Errorf("letters-only pattern: n=1 and n=2 both seeded %q", a)
	}
}
