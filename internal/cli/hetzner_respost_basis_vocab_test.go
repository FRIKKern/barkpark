package cli

// hetzner_respost_basis_vocab_test.go — PDS wave 34, LEG 3 of
// pds-w32-census-binds-the-basis: the only leg that catches a LYING BASIS
// CONSTANT.
//
// WHY THE OTHER TWO LEGS CANNOT. Leg 1 pins WHICH constant each call site
// passes and leg 2 pins WHICH READ that constant is bound to — both compare
// SYMBOLS. TestHzResBasisOfDegradesRatherThanBlanking already states the limit
// in the same words: "changing what a CONSTANT SAYS is not [caught] — every
// assertion there compares the key symbolically against the constant." A
// constant's wording exists in exactly one place in all Go code, its own
// declaration, so a `got != hzResBasisHead` compares the constant to itself and
// a rewording changes both sides at once. Measured: with legs 1 and 2 shipped
// and this file absent, rewording hzResBasisHead leaves the package green.
//
// THE RULE IS POSITIVE-FIRST, AND THAT IS THE FINDING. The filed leg-3 rule was
// negative-only ("a HEAD basis must not contain GET or byte"). Implemented
// verbatim it scores 1 of 4 evasions, and the one it catches is the one it was
// fitted to — wave 32's mutation B, authored as maximally-confusing prose that
// happens to carry both forbidden tokens. It misses a lowercase-`get`
// rewording, a method-free rewording ("a re-read of the stored object after the
// write"), and worst, rewording one constant into ANOTHER constant's own true
// wording. So every basis here DECLARES THE READ SHAPE IT NAMES, and the shape
// carries the vocabulary that read must use. A reworded constant reds unless
// the new wording still describes the same read.
//
// TOKEN RULES, both chosen because the true wordings need them and a naive
// substring rule produces FALSE POSITIVES that would get this gate deleted:
//
//   - 'GET', 'HEAD' and 'List' are CASE-SENSITIVE. They are HTTP methods and an
//     SDK verb; "get the object" is prose, not a method, and must not satisfy a
//     GET shape. A case-insensitive "get" also fires on tarGET and budGET.
//   - 'id' and 'key' are TOKEN-BOUNDED. strings.Contains(b, "id") fires on
//     "provided" (prov-ID-ed) and on "identity" — neither is a claim that an id
//     was resolved. Proven below in TestHetznerResourceBasisVocabPrimitives.
//   - 'scan' is a SUBSTRING on purpose: the true wording says "scanned".
//
// hzResBasisRRSetKey GETS ITS OWN SHAPE ROW, and it is the row that proves a
// two-shape taxonomy is not enough. Its true wording legitimately contains GET
// while naming a read that is NOT a GET on an id — it addresses a (zone, name,
// type) composite key, and its bound read is GetRRSetByNameAndType, not
// GetByID. Judged against hzResBasisGet's shape it reds honestly-wrongly on day
// one. Six bases need six shapes.
//
// AND THE SURFACE IS SIX, NOT FIVE. Two of the six are not constants at all:
// hetzner_storage_cmd.go:451 and :738 pass BARE STRING LITERALS into
// hzResDestroyedDeclared's mandatory `basis string` parameter. A gate that
// iterates the hzResBasis* identifiers — or one scoped to
// hetzner_respost_mutation.go, where only four of the five constants live —
// judges four of six and calls it coverage.

import (
	"regexp"
	"strings"
	"testing"
)

// hzBasisHasMethod reports whether s names the method m, CASE-SENSITIVELY.
func hzBasisHasMethod(s, m string) bool { return strings.Contains(s, m) }

// hzBasisHasToken reports whether s contains tok as a WHOLE WORD.
func hzBasisHasToken(s, tok string) bool {
	return regexp.MustCompile(`\b` + regexp.QuoteMeta(tok) + `\b`).MatchString(s)
}

// hzBasisShape declares, for ONE basis, the read it names and the vocabulary
// that read must and must not use.
//
// THE WORDING IS NOT STORED HERE. Each row names its basis by IDENTIFIER (a
// constant) or by census KEY (the two declared literals), and the wording is
// looked up from the DERIVED source at check time. A row that carried its own
// copy of the wording would be reworded in the same edit as the constant — the
// exact self-comparison this leg exists to break.
type hzBasisShape struct {
	konst string // the hzResBasis* identifier, for a constant row
	key   string // the (kind, action) census key, for a declared-literal row
	shape string // the read, in words, for the failure message

	mustMethods []string // case-sensitive, must appear
	mustSubs    []string // case-sensitive substrings, must appear
	mustTokens  []string // whole words, must appear
	notMethods  []string // case-sensitive, must NOT appear
	notTokens   []string // whole words, must NOT appear
}

// hzBasisShapes is the register. A basis with no row here is caught by
// TestHetznerResourceBasisShapeTableCoversEverySource, which derives the
// population rather than trusting this list's length.
func hzBasisShapes() []hzBasisShape {
	return []hzBasisShape{
		{
			konst: "hzResBasisGet",
			shape: "a single-resource GET on an id the verb already resolved",
			// Bound read: …GetByID(c, x.ID). Twenty-one sites inherit this by
			// omission, which is why its wording is worth defending at all.
			mustMethods: []string{"GET"},
			mustTokens:  []string{"id"},
			notMethods:  []string{"HEAD", "List"},
			notTokens:   []string{"response", "key"},
		},
		{
			konst: "hzResBasisResponse",
			shape: "NO post-read at all — the object the create call handed back",
			// Bound read: none. This is the ONLY basis that may claim no read,
			// so it is the only one whose shape forbids every method name.
			mustTokens: []string{"response"},
			mustSubs:   []string{"create"},
			notMethods: []string{"GET", "HEAD", "List"},
			notTokens:  []string{"id", "key"},
		},
		{
			konst: "hzResBasisHead",
			shape: "an existence HEAD on a stored key — bytes PRESENT, never bytes CORRECT",
			// Bound read: hzS3HeadRead. The HEAD claim is the weaker one and
			// must stay weaker: an operator weighs this receipt differently.
			mustMethods: []string{"HEAD"},
			mustTokens:  []string{"key"},
			notMethods:  []string{"GET", "List"},
			notTokens:   []string{"id", "response"},
		},
		{
			konst: "hzResBasisListScan",
			shape: "a COLLECTION LISTING scanned for a name — no single-resource read at all",
			// Bound read: hzS3BucketRead. 'scan' is a SUBSTRING because the
			// true wording says "scanned"; a token match would red it.
			mustMethods: []string{"List"},
			mustSubs:    []string{"scan"},
			mustTokens:  []string{"name"},
			notMethods:  []string{"GET", "HEAD"},
			notTokens:   []string{"id", "response"},
		},
		{
			// THE ROW THAT REFUTES A TWO-SHAPE TAXONOMY. It contains GET and
			// that is TRUE, but it resolves no id, so it cannot ride
			// hzResBasisGet's shape — and hzResBasisGet's shape cannot be
			// loosened to admit it without admitting every GET claim.
			konst: "hzResBasisRRSetKey",
			shape: "a single-resource GET on a composite (zone, name, type) key — NO id is resolved",
			// Bound read: GetRRSetByNameAndType.
			mustMethods: []string{"GET"},
			mustTokens:  []string{"key"},
			notMethods:  []string{"HEAD", "List"},
			notTokens:   []string{"id", "response"},
		},
		{
			// THE TWO ROWS A hzResBasis*-SHAPED GATE MISSES. Bare literals, in
			// another file, in a mandatory parameter.
			key:   "bucket/delete",
			shape: "a DECLARED NON-BINDING bucket listing taken after the delete",
			// Bound read: c.ListBuckets(…).
			mustMethods: []string{"List"},
			mustTokens:  []string{"delete"},
			notMethods:  []string{"GET", "HEAD"},
			notTokens:   []string{"id", "response", "create"},
		},
		{
			key:   "object/rm",
			shape: "a DECLARED NON-BINDING key-prefix listing taken after the delete",
			// Bound read: c.ListObjects(…, bucket, key).
			mustMethods: []string{"List"},
			mustTokens:  []string{"delete", "key"},
			notMethods:  []string{"GET", "HEAD"},
			notTokens:   []string{"id", "response", "create"},
		},
	}
}

// hzBasisName is a row's identity for messages and coverage.
func (s hzBasisShape) hzBasisName() string {
	if s.konst != "" {
		return s.konst
	}
	return "declared basis at " + s.key
}

// hzResDerivedBasisWordings returns EVERY confirmation basis the scanned
// sources can print, keyed the way hzBasisShapes keys them: constants by
// identifier, declared literals by census key.
//
// DERIVED, NOT ENUMERATED (HG-D31). The hand list is the hazard: nothing forces
// a SIXTH constant, or a THIRD declared literal, into a list somebody typed.
// Both halves come off the AST — hzResBasisConstants walks the const
// declarations, and the literal half walks the actual call sites.
func hzResDerivedBasisWordings(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	for name, wording := range hzResBasisConstants(t) {
		out[name] = wording
	}
	for _, s := range hzResBasisSites(t) {
		if s.basisForm != hzBasisLiteral {
			continue
		}
		key := hzResSiteKey(s)
		if key == "" {
			t.Errorf("%s:%d passes a declared basis literal from a site with no literal (kind, action) key — it "+
				"cannot be judged by wording, and it is the shape this leg exists to judge", s.file, s.line)
			continue
		}
		out[key] = s.basisText
	}
	if len(out) < 3 {
		t.Fatalf("derived %d basis wordings — the scan is finding nothing, not measuring an empty surface", len(out))
	}
	return out
}

// TestHetznerResourceBasisWordingMatchesTheReadItNames is the leg-3 gate.
func TestHetznerResourceBasisWordingMatchesTheReadItNames(t *testing.T) {
	wordings := hzResDerivedBasisWordings(t)
	for _, s := range hzBasisShapes() {
		name := s.hzBasisName()
		t.Run(name, func(t *testing.T) {
			got, ok := wordings[s.konst+s.key]
			if !ok {
				t.Fatalf("%s has a shape row but no wording in the derived sources — the row is stale, and a "+
					"stale row makes this register look like it judges more of the surface than it does", name)
			}
			if strings.TrimSpace(got) == "" {
				t.Fatalf("%s is blank", name)
			}
			for _, m := range s.mustMethods {
				if !hzBasisHasMethod(got, m) {
					t.Errorf("%s = %q\n  names %s\n  but does not contain %q (CASE-SENSITIVE: a method, not prose). "+
						"A receipt may not name a read the code does not perform.", name, got, s.shape, m)
				}
			}
			for _, sub := range s.mustSubs {
				if !strings.Contains(got, sub) {
					t.Errorf("%s = %q\n  names %s\n  but does not contain %q.", name, got, s.shape, sub)
				}
			}
			for _, tok := range s.mustTokens {
				if !hzBasisHasToken(got, tok) {
					t.Errorf("%s = %q\n  names %s\n  but does not contain the word %q.", name, got, s.shape, tok)
				}
			}
			for _, m := range s.notMethods {
				if hzBasisHasMethod(got, m) {
					t.Errorf("%s = %q\n  names %s\n  yet claims %q — that is a DIFFERENT read from the one this "+
						"basis is bound to, and in this family the difference is what an operator weighs.",
						name, got, s.shape, m)
				}
			}
			for _, tok := range s.notTokens {
				if hzBasisHasToken(got, tok) {
					t.Errorf("%s = %q\n  names %s\n  yet uses the word %q, which belongs to a different read.",
						name, got, s.shape, tok)
				}
			}
		})
	}
}

// TestHetznerResourceBasisWordingsAreDistinct kills the evasion class a shape
// check CANNOT see: rewording one basis into ANOTHER basis's own true wording.
// Each wording passes its own shape row by construction, so shape checking
// alone is blind to the collision — and this is the evasion that leaves the
// package green while two live receipts print "the create response object" for
// an existence HEAD.
func TestHetznerResourceBasisWordingsAreDistinct(t *testing.T) {
	seen := map[string]string{}
	names := 0
	for name, wording := range hzResDerivedBasisWordings(t) {
		names++
		norm := strings.ToLower(strings.Join(strings.Fields(wording), " "))
		if prev, dup := seen[norm]; dup {
			t.Errorf("%s and %s carry the SAME wording %q. Two bases that read identically cannot be told apart "+
				"on a receipt, so the confirmation_basis key stops discriminating — which is the whole reason it "+
				"is printed.", prev, name, wording)
			continue
		}
		seen[norm] = name
	}
	if names < 3 {
		t.Fatalf("only %d wordings compared — this arm is measuring nothing", names)
	}
	t.Logf("DISTINCT WORDINGS=%d of %d bases", len(seen), names)
}

// TestHetznerResourceBasisShapeTableCoversEverySource makes the register
// non-vacuous IN BOTH DIRECTIONS: every basis the sources can print must have a
// shape row, and every shape row must name a basis the sources still have.
//
// This is the arm that stops the sixth constant. hzResBasisRRSetKey already
// proved a basis can be declared outside the const block in another file, and
// the two declared literals proved a basis need not be a constant at all — so
// the population is DERIVED and the table is checked against it, never the
// other way round.
func TestHetznerResourceBasisShapeTableCoversEverySource(t *testing.T) {
	wordings := hzResDerivedBasisWordings(t)
	rows := map[string]bool{}
	for _, s := range hzBasisShapes() {
		if s.konst != "" && s.key != "" {
			t.Errorf("shape row %q names BOTH a constant and a census key — a row must identify exactly one basis", s.shape)
		}
		id := s.konst + s.key
		if rows[id] {
			t.Errorf("two shape rows both judge %q — the second silently never runs", id)
		}
		rows[id] = true
		if _, live := wordings[id]; !live {
			t.Errorf("RATCHET/SHAPE-ROW-STALE: the shape table judges %q, which the scanned sources no longer "+
				"print. A stale row inflates this register exactly the way a stale disposition inflates the census.", id)
		}
	}
	for id, wording := range wordings {
		if rows[id] {
			continue
		}
		t.Errorf("RATCHET/BASIS-UNJUDGED: %q = %q can be printed on a receipt but has NO shape row, so nothing in "+
			"this package checks that its wording describes the read it is bound to. It ships UNJUDGED — which is "+
			"precisely the state legs 1 and 2 leave a basis in, because both of them compare symbols.", id, wording)
	}
	t.Logf("SHAPE COVERAGE: %d rows for %d derived bases", len(rows), len(wordings))
}

// TestHetznerResourceBasisVocabPrimitives proves the two matchers do what the
// header claims, so this gate's greens are not an artefact of a loose matcher —
// and its reds are not an artefact of a matcher that fires on ordinary prose.
// A gate that reds an HONEST wording is a gate somebody deletes.
func TestHetznerResourceBasisVocabPrimitives(t *testing.T) {
	// FALSE-POSITIVE HALF: words a truthful basis may legitimately use.
	for _, w := range []string{"provided", "identity", "invalid", "consider", "idempotent"} {
		if hzBasisHasToken(w, "id") {
			t.Errorf("token 'id' wrongly matched inside %q — the gate would red an honest wording", w)
		}
	}
	for _, w := range []string{"target", "budget", "get the object after the create", "widget"} {
		if hzBasisHasMethod(w, "GET") {
			t.Errorf("method 'GET' wrongly matched inside %q — the method claim must be case-sensitive", w)
		}
	}
	if hzBasisHasMethod("a heading on the stored key", "HEAD") {
		t.Error("'HEAD' matched lowercase prose 'heading' — the method claim must be case-sensitive")
	}
	if hzBasisHasMethod("the listing after the delete", "List") {
		t.Error("'List' matched lowercase prose 'listing' — the SDK verb claim must be case-sensitive")
	}

	// TRUE-POSITIVE HALF: the matchers must still fire on the real wordings.
	if !hzBasisHasToken("GET on the resolved id", "id") {
		t.Error("token 'id' failed to match a standalone id")
	}
	if !hzBasisHasToken("the (zone, name, type) key the verb already held", "key") {
		t.Error("token 'key' failed to match next to punctuation")
	}
	if !strings.Contains("ListBuckets after the create, scanned for the name", "scan") {
		t.Error("substring 'scan' failed to match 'scanned' — this is why it is a substring and not a token")
	}
	if !hzBasisHasMethod("existence HEAD on the stored key", "HEAD") {
		t.Error("method 'HEAD' failed to match the true HEAD wording")
	}
}
