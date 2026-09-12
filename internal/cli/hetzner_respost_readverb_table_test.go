package cli

import (
	"strings"
	"testing"
)

// TestHzResReadVerbsCoverEveryKind pins the TABLE the hint reads from against
// the derived call-site enumeration: every kind that can reach the refusal has
// an entry, and no entry names a kind that cannot.
func TestHzResReadVerbsCoverEveryKind(t *testing.T) {
	derived := hzNotReadableKinds(t)
	for _, kind := range derived {
		if _, ok := hzResReadVerbs[kind]; !ok {
			t.Errorf("kind %q reaches hzResNotReadable but has no hzResReadVerbs entry — its receipt cannot name a "+
				"verb it does not know about", kind)
		}
	}
	inDerived := map[string]bool{}
	for _, k := range derived {
		inDerived[k] = true
	}
	for kind := range hzResReadVerbs {
		if !inDerived[kind] {
			t.Errorf("hzResReadVerbs has an entry for kind %q, which no call site passes — the table has drifted "+
				"from the call sites", kind)
		}
	}
}

// TestHzResReadVerbsResolve is the RENAME TRIPWIRE: every non-empty entry is
// driven through the real dispatcher, so renaming or regrouping a hetzner read
// verb reds here instead of shipping a receipt that names the old path.
func TestHzResReadVerbsResolve(t *testing.T) {
	for kind, verb := range hzResReadVerbs {
		if len(verb.tokens) == 0 {
			continue
		}
		t.Run(kind, func(t *testing.T) {
			if ok, said := hzCommandResolves(t, verb.tokens); !ok {
				t.Errorf("hzResReadVerbs[%q] names `bp cloud %s`, which the CLI does not resolve: %q",
					kind, strings.Join(verb.tokens, " "), strings.TrimSpace(said))
			}
		})
	}
}

// TestHzResNoReadVerbKindsReallyHaveNone is the other half of the table's
// honesty: a kind marked "no read verb" must not have one hiding under the
// obvious path, or the receipt is withholding a command that works.
func TestHzResNoReadVerbKindsReallyHaveNone(t *testing.T) {
	for kind, verb := range hzResReadVerbs {
		if len(verb.tokens) > 0 {
			continue
		}
		if ok, _ := hzCommandResolves(t, []string{"hetzner", kind, "get"}); ok {
			t.Errorf("hzResReadVerbs[%q] claims there is no read verb, but `bp cloud hetzner %s get` resolves",
				kind, kind)
		}
	}
}
