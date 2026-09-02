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
// one. Seven bases need seven shapes.
//
// AND THE SURFACE IS SEVEN, NOT FIVE — SPREAD OVER THREE FILES. Two of the
// seven used to be no constants at all: hetzner_storage_cmd.go passed BARE
// STRING LITERALS into hzResDestroyedDeclared's mandatory `basis string`
// parameter until pds-w34-declared-basis-literals-need-constants named them
// (hzResBasisBucketListAfterDelete, hzResBasisObjectKeyListAfterDelete, declared
// beside their verbs). Iterating the hzResBasis* identifiers now reaches all
// seven — but a gate scoped to hetzner_respost_mutation.go, where only FOUR of
// them live, still judges four of seven and calls it coverage. That is why the
// population is globbed from every non-test hetzner_*.go and derived, never
// listed.

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
// constant) — or, if a bare literal ever reaches a call site again, by census
// KEY — and the wording is looked up from the DERIVED source at check time. A
// row that carried its own copy of the wording would be reworded in the same
// edit as the constant — the exact self-comparison this leg exists to break.
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
			// THE TWO ROWS THAT USED TO BE BARE LITERALS. They are constants
			// now (hetzner_storage_cmd.go, beside their verbs), so they are
			// keyed by IDENTIFIER like every other row — but they still prove
			// the lesson that made them: a gate scoped to
			// hetzner_respost_mutation.go, where only four of the seven live,
			// judges four of seven and calls it coverage.
			konst: "hzResBasisBucketListAfterDelete",
			shape: "a DECLARED NON-BINDING bucket listing taken after the delete",
			// Bound read: c.ListBuckets(…).
			mustMethods: []string{"List"},
			mustTokens:  []string{"delete"},
			notMethods:  []string{"GET", "HEAD"},
			notTokens:   []string{"id", "response", "create"},
		},
		{
			konst: "hzResBasisObjectKeyListAfterDelete",
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
// identifier, and any bare literal that reaches a call site by census key. Since
// wave 35 the literal half is EMPTY and that is the point — the loop stays so a
// new literal is judged rather than skipped.
//
// DERIVED, NOT ENUMERATED (HG-D31). The hand list is the hazard: nothing forces
// an EIGHTH constant, or a fresh declared literal, into a list somebody typed.
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
// This is the arm that stops the eighth constant. hzResBasisRRSetKey already
// proved a basis can be declared outside the const block in another file, and
// the two declared destroys proved a basis can arrive with no constant at all —
// they have one now, in a THIRD file — so
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

// ---------------------------------------------------------------------------
// LEG 4: THE ADDITIVE EMBELLISHMENT.
//
// THE HOLE LEG 3 LEAVES OPEN, MEASURED. Leg 3 judges a wording by SHAPE
// VOCABULARY — mustMethods, mustSubs, mustTokens, notMethods, notTokens, plus
// the distinctness arm. Every one of those asks whether a word is PRESENT or
// ABSENT. None of them asks what an ADDED clause asserts. So rewording
// hzResBasisBucketListAfterDelete to "ListBuckets after the delete, with every
// object in it re-checked" — a per-object re-check the code never performs —
// satisfies mustMethods 'List', mustTokens 'delete', forbids nothing, collides
// with no other wording, and the whole package stays GREEN. Measured on
// origin/main before this file's leg-4 arms existed: the nine
// TestHetznerResourceBasis* arms all PASS with that wording installed.
//
// WHAT LEG 4 ADDS. It is the first arm in the family that compares the wording
// against WHAT THE BOUND READ CAN VOUCH FOR, rather than against a token list.
// The binding is hzResBasisReads — leg 2's table, basis symbol → the read
// primitive's token — and hzBasisReadPowers says, for each of those primitives,
// which nouns it ENUMERATES and which it RE-READS INDIVIDUALLY. A wording may
// quantify over a noun only if its own bound read enumerates that noun, and may
// claim a per-member re-check only if its own bound read re-reads it.
//
// THIS IS NOT A TOKEN BAN, AND THE PROOF IS THAT THE SAME WORDS GO BOTH WAYS.
// "with every object … " is REFUSED on hzResBasisBucketListAfterDelete, whose
// bound read is ListBuckets — buckets are enumerated, objects are not. The
// identical phrase PASSES on hzResBasisObjectKeyListAfterDelete, whose bound
// read is ListObjects, which does enumerate objects. One vocabulary, two
// verdicts, and the binding is the only thing that decides.
//
// WHAT IT DOES NOT CATCH, STATED SO NOBODY OVER-READS A GREEN:
//
//   - It reads QUANTIFIER-AND-NOUN structure, not meaning. An embellishment
//     that adds an unsubstantiated clause carrying no quantifier and no
//     re-check word ("…, and the bucket was empty") still passes. This is a
//     vocabulary gate on the scope axis, deliberately, because the alternative
//     is prose analysis and a gate nobody trusts.
//   - It says nothing about TIMING ("after the delete" is unjudged here) or
//     about WHICH resource an argument carried — leg 2 already states that
//     second limit for itself.
//   - hzResBasisResponse is bound to NO read, so it can substantiate NOTHING.
//     That is the correct reading of a basis that performs no round trip, and
//     it means any quantifier added to that wording reds.

// hzBasisReadPower says what ONE read primitive can vouch for on a receipt.
//
// DERIVED FROM THE PRIMITIVE, NOT FROM THE PROSE. Each row was written by
// reading the call, never by reading the constant that names it: ListBuckets
// returns the bucket collection and nothing about any object inside one;
// ListObjects returns the object keys under a prefix and nothing about their
// contents; a listing NAMES its members, it does not READ them, which is why
// every listing row has an empty reReads.
type hzBasisReadPower struct {
	// enumerates: singular nouns whose whole population this one call walks.
	enumerates []string
	// reReads: singular nouns this call fetches INDIVIDUALLY, one round trip
	// per member. A listing has none — that is the distinction the
	// embellishment traded on.
	reReads []string
	// why is quoted in the failure message, so a red explains the primitive
	// rather than just naming it.
	why string
}

// hzBasisReadPowers is the register, keyed by the SAME token hzResBasisReads
// binds a basis to. TestHetznerResourceBasisReadPowersCoverEveryBoundRead keeps
// the two tables in step in both directions.
var hzBasisReadPowers = map[string]hzBasisReadPower{
	"GetByID(": {
		reReads: []string{"resource", "id", "server", "volume", "network"},
		why:     "one hcloud single-resource GET on one id",
	},
	"hzS3HeadRead(": {
		reReads: []string{"key"},
		why:     "one HEAD request against one stored key — presence, not content",
	},
	"hzS3BucketRead(": {
		enumerates: []string{"bucket", "name"},
		why:        "one bucket listing, scanned for a name — it walks buckets, never their contents",
	},
	"GetRRSetByNameAndType(": {
		reReads: []string{"record", "rrset", "key"},
		why:     "one composite-key GET for one RRSet",
	},
	"ListBuckets(": {
		enumerates: []string{"bucket", "name"},
		why:        "one bucket listing — it names buckets and says NOTHING about any object inside one",
	},
	"ListObjects(": {
		enumerates: []string{"object", "key"},
		why:        "one prefix listing — it names the object keys under a prefix, but reads none of them",
	},
}

// hzBasisQuantifiers widen a claim from "this read happened" to "every member
// of what this read touched was covered".
var hzBasisQuantifiers = []string{"every", "each", "all", "per", "any"}

// hzBasisReReadWords claim members were fetched INDIVIDUALLY. They are matched
// as whole hyphenated compounds, which is why the tokenizer keeps hyphens.
var hzBasisReReadWords = []string{
	"re-checked", "rechecked", "re-check", "recheck",
	"re-read", "reread", "re-verified", "reverified",
	"individually", "one-by-one",
}

// hzBasisNouns are the singular nouns a basis on this surface can be about.
// Anything outside this list carries no scope claim this gate will judge.
var hzBasisNouns = []string{
	"object", "bucket", "key", "record", "rrset",
	"resource", "id", "name", "zone", "server", "volume", "network",
}

// hzBasisClaimKind distinguishes the two assertions leg 4 can read.
type hzBasisClaimKind string

const (
	hzBasisClaimEnumerated hzBasisClaimKind = "enumerated"
	hzBasisClaimReRead     hzBasisClaimKind = "re-read individually"
)

// hzBasisClaim is ONE scope assertion recovered from a wording.
type hzBasisClaim struct {
	kind    hzBasisClaimKind
	trigger string // the word that made the claim, for the message
	noun    string // singular noun the claim is about
}

// hzBasisWordRe splits a wording into words, KEEPING hyphenated compounds whole
// so "re-checked" and "one-by-one" survive as single tokens.
var hzBasisWordRe = regexp.MustCompile(`[a-z]+(?:-[a-z]+)*`)

// hzBasisSingular folds a plural noun onto its singular form.
func hzBasisSingular(w string) string {
	if len(w) > 3 && strings.HasSuffix(w, "s") && !strings.HasSuffix(w, "ss") {
		return strings.TrimSuffix(w, "s")
	}
	return w
}

// hzBasisNounAt reports the singular noun at words[i], or "".
func hzBasisNounAt(words []string, i int) string {
	if i < 0 || i >= len(words) {
		return ""
	}
	n := hzBasisSingular(words[i])
	for _, cand := range hzBasisNouns {
		if n == cand {
			return n
		}
	}
	return ""
}

// hzBasisScopeWindow is how far from its trigger a noun may sit and still be
// the one the trigger governs. Four words covers "every object in it" and
// "all of the buckets" without reaching across a clause.
const hzBasisScopeWindow = 4

// hzBasisScopeClaims reads the scope assertions out of a wording.
//
// STRUCTURE, NOT MEANING. A quantifier claims the read covered every member of
// the nearest noun after it; a re-check word claims the nearest noun around it
// was fetched member by member. Nothing here parses grammar, and the header
// says exactly what that costs.
func hzBasisScopeClaims(wording string) []hzBasisClaim {
	raw := hzBasisWordRe.FindAllString(strings.ToLower(wording), -1)
	var words []string
	for _, r := range raw {
		if hzBasisIsReReadWord(r) {
			words = append(words, r) // keep the compound whole
			continue
		}
		words = append(words, strings.Split(r, "-")...)
	}

	var out []hzBasisClaim
	for i, w := range words {
		switch {
		case hzBasisIsQuantifier(w):
			// A quantifier governs the first noun that follows it.
			for j := i + 1; j < len(words) && j <= i+hzBasisScopeWindow; j++ {
				if n := hzBasisNounAt(words, j); n != "" {
					out = append(out, hzBasisClaim{kind: hzBasisClaimEnumerated, trigger: w, noun: n})
					break
				}
			}
		case hzBasisIsReReadWord(w):
			// A re-check word attaches to the nearest noun, looking BACK first
			// ("every object … re-checked") and then forward ("re-checked each
			// object").
			if n := hzBasisNearestNoun(words, i); n != "" {
				out = append(out, hzBasisClaim{kind: hzBasisClaimReRead, trigger: w, noun: n})
			}
		}
	}
	return out
}

// hzBasisNearestNoun looks backward then forward from i within the window.
func hzBasisNearestNoun(words []string, i int) string {
	for j := i - 1; j >= 0 && j >= i-hzBasisScopeWindow; j-- {
		if n := hzBasisNounAt(words, j); n != "" {
			return n
		}
	}
	for j := i + 1; j < len(words) && j <= i+hzBasisScopeWindow; j++ {
		if n := hzBasisNounAt(words, j); n != "" {
			return n
		}
	}
	return ""
}

func hzBasisIsQuantifier(w string) bool { return hzBasisInList(hzBasisQuantifiers, w) }
func hzBasisIsReReadWord(w string) bool { return hzBasisInList(hzBasisReReadWords, w) }

func hzBasisInList(list []string, w string) bool {
	for _, c := range list {
		if c == w {
			return true
		}
	}
	return false
}

// hzBasisVouched reports whether the union of a basis's bound reads can
// substantiate one claim, and returns the primitives it was weighed against.
func hzBasisVouched(reads []string, c hzBasisClaim) (bool, []string) {
	var why []string
	for _, tok := range reads {
		p, ok := hzBasisReadPowers[tok]
		if !ok {
			continue // TestHetznerResourceBasisReadPowersCoverEveryBoundRead owns this
		}
		why = append(why, tok+" ("+p.why+")")
		var vouches []string
		if c.kind == hzBasisClaimEnumerated {
			vouches = p.enumerates
		} else {
			vouches = p.reReads
		}
		if hzBasisInList(vouches, c.noun) {
			return true, why
		}
	}
	return false, why
}

// TestHetznerResourceBasisWordingClaimsNothingTheBoundReadCannotVouchFor is LEG
// 4: the arm that refuses an ADDITIVE embellishment.
//
// It is bound-read-driven by construction — the population is the DERIVED
// wordings, the rule comes from hzResBasisReads, and there is no per-wording
// allowlist anywhere in it. A phrase that is a lie on one basis is legal on
// another, and only the binding decides which.
func TestHetznerResourceBasisWordingClaimsNothingTheBoundReadCannotVouchFor(t *testing.T) {
	wordings := hzResDerivedBasisWordings(t)
	checked := 0
	for name, wording := range wordings {
		reads, bound := hzResBasisReads[name]
		if !bound {
			// A bare literal has no symbol, and a constant with no binding row
			// is already red at RATCHET/BASIS-CONSTANT-UNJUDGED. Repeating it
			// here would read like a second, independent finding.
			continue
		}
		checked++
		for _, c := range hzBasisScopeClaims(wording) {
			ok, weighed := hzBasisVouched(reads, c)
			if ok {
				continue
			}
			against := "NO read at all — this basis claims no round trip"
			if len(weighed) > 0 {
				against = strings.Join(weighed, ", ")
			}
			t.Errorf("RATCHET/BASIS-WORDING-UNSUBSTANTIATED: %s = %q\n"+
				"  asserts that every %s was %s (from the word %q)\n"+
				"  but its bound read is %s, which cannot vouch for that.\n"+
				"  THE RECEIPT CLAIMS MORE THAN THE READ PERFORMED. This is the ADDITIVE lie leg 3 cannot see: "+
				"the added clause breaks no shape rule, collides with no other wording, and would print on a live "+
				"receipt as a stronger guarantee than the code ever made.",
				name, wording, c.noun, c.kind, c.trigger, against)
		}
	}
	const checkedFloor = 5
	if checked < checkedFloor {
		t.Fatalf("only %d bases were weighed against their bound read (floor %d) — the derivation or the binding "+
			"table stopped resolving, and a silent zero is exactly how this family failed before", checked, checkedFloor)
	}
	t.Logf("SCOPE-CLAIMS WEIGHED: %d bases against %d read primitives", checked, len(hzBasisReadPowers))
}

// TestHetznerResourceBasisReadPowersCoverEveryBoundRead keeps leg 4's register
// in step with leg 2's binding table IN BOTH DIRECTIONS. A new read primitive
// entering hzResBasisReads without a power row would make leg 4 silently vouch
// for nothing on that basis — a green that means "unjudged", which is the shape
// this whole family exists to refuse.
func TestHetznerResourceBasisReadPowersCoverEveryBoundRead(t *testing.T) {
	used := map[string]bool{}
	for sym, reads := range hzResBasisReads {
		for _, tok := range reads {
			used[tok] = true
			if _, ok := hzBasisReadPowers[tok]; !ok {
				t.Errorf("RATCHET/READ-POWER-UNDECLARED: hzResBasisReads binds %s to the read %q, but "+
					"hzBasisReadPowers does not say what that primitive can vouch for. Leg 4 would weigh every "+
					"scope claim on %s against an empty power and call the silence a pass.", sym, tok, sym)
			}
		}
	}
	for tok := range hzBasisReadPowers {
		if !used[tok] {
			t.Errorf("hzBasisReadPowers declares powers for %q, which no row in hzResBasisReads binds any basis "+
				"to — a stale power row makes this register look like it speaks for more of the surface than it does", tok)
		}
	}
	if len(used) < 4 {
		t.Fatalf("only %d distinct read primitives are bound — the binding table stopped resolving", len(used))
	}
}

// TestHetznerResourceBasisScopeClaimPrimitives proves the claim reader fires on
// the embellishment and stays silent on every wording this surface actually
// ships — because a gate that reds an honest wording is a gate somebody
// deletes, and a gate that reads no claim at all is a vacuous green.
func TestHetznerResourceBasisScopeClaimPrimitives(t *testing.T) {
	// TRUE-POSITIVE HALF: the embellishment, read as two distinct claims.
	got := hzBasisScopeClaims("ListBuckets after the delete, with every object in it re-checked")
	want := []hzBasisClaim{
		{kind: hzBasisClaimEnumerated, trigger: "every", noun: "object"},
		{kind: hzBasisClaimReRead, trigger: "re-checked", noun: "object"},
	}
	if len(got) != len(want) {
		t.Fatalf("the embellishment yielded %d claims %v, want %d %v — the reader that refuses it must SEE it",
			len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("claim %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	// The same phrase on a listing that DOES walk objects is substantiated —
	// this is the half that proves leg 4 is not a token ban.
	if ok, _ := hzBasisVouched([]string{"ListObjects("}, want[0]); !ok {
		t.Error("'every object' was refused against ListObjects(, which enumerates object keys — leg 4 would be " +
			"a blanket ban on the word rather than a check against the binding")
	}
	if ok, _ := hzBasisVouched([]string{"ListBuckets("}, want[0]); ok {
		t.Error("'every object' was vouched for by ListBuckets(, which walks buckets and reads no object")
	}
	if ok, _ := hzBasisVouched([]string{"ListObjects("}, want[1]); ok {
		t.Error("'re-checked' was vouched for by a LISTING — a listing names its members, it does not read them")
	}

	// FALSE-POSITIVE HALF: every wording the tree ships today must read as ZERO
	// claims. If one of these ever carries a claim, it must be substantiated,
	// and the arm above is where that is decided — but a claim read out of
	// today's honest prose would mean the reader is too eager.
	for _, w := range []string{
		"single-resource GET on the resolved id",
		"the create response object",
		"existence HEAD on the stored key",
		"ListBuckets after the create, scanned for the name",
		"single-resource GET on the (zone, name, type) key the verb already held",
		"ListBuckets after the delete",
		"ListObjects on the exact key prefix after the delete",
	} {
		if c := hzBasisScopeClaims(w); len(c) != 0 {
			t.Errorf("the honest wording %q was read as carrying the scope claims %v — leg 4 would red a truthful "+
				"receipt, and a gate that reds honest prose is a gate somebody deletes", w, c)
		}
	}
}
