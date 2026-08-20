// Package scaffy is the one implementation of the pinned Scaffy v2
// grammar (charter D3, A1–A5, D20–D28): a lexer, a typed AST with
// positions on every node, a fail-loud parser, the frozen lint catalog
// and an idempotent structural formatter for .scaffy command files.
//
// Doctrine: the opposite of pdrender/mermaid.go's silent-skip — every
// violation is reported as a Finding ("file:line: RULE-ID message")
// with a fix hint, never skipped. validate is text-level by default
// (D27): no repo access. The opt-in repo-aware layer (RepoCheck, behind
// `validate --repo`) adds the anchor-exists / occurrence-count checks D5
// promises — reported with the R-xxx rule IDs (repocheck.go). The
// forward/replay engine (Run/Remove) is apply.go / remove.go.
//
// Public API (the CLI slice builds against exactly this):
//
//	Parse(filename, src)        (*Command, []Finding)   // typed AST + parse findings
//	Lint(cmd)                   []Finding               // the lint catalog over one AST
//	ValidateFile(filename, src) []Finding               // Parse + Lint, sorted
//	Format(src)                 ([]byte, error)         // canonical form; Format∘Format == Format
//	RepoCheck(path, src, opts)  (*RepoCheckResult, err) // opt-in anchor drift vs the tree (D5)
//
// Format canonicalizes STRUCTURE only: keyword lines are single-spaced
// and flush-left (VARIABLE declarations two-space indented, list commas
// bound to the preceding value — the corpus spellings), fence lines are
// normalized — comment prose and payload bytes are never rewritten
// (D27).
//
// # Rule catalog
//
// IDs are frozen (D28). E-xxx = error, W-xxx = warn, P-xxx = parse
// error. The Rules slice below is the machine-readable index.
//
//	E-001  fence pairing: unclosed fence or open/close label mismatch
//	E-002  unfenced multi-line target/payload (every block is fenced, D3(a))
//	E-003  undeclared token: no VARIABLE's word-list matches (D3(d))
//	E-004  malformed token spelling: matches a VARIABLE but is not one of
//	       the five joiner outputs Pascal/kebab/camel/snake/SCREAMING (A1/D22)
//	E-005  self-consuming REPLACE (target survives as a substring of its
//	       own payload) without BOTH a payload-derived ASLONG and a
//	       REANCHOR (A4/D21)
//	E-006  ASLONG guard is not a verbatim substring of what the op
//	       touches: a DONT CONTAIN guard derives from the payload (text
//	       the op writes), a positive CONTAIN guard from the fenced
//	       target (text the op consumes — REMOVE and the un-sweep
//	       REPLACE alike); whole-file CREATE/DELETE guards are exempt —
//	       they check on-disk content (D3(c)/D23/D28)
//	E-007  IN-op carries no MARK (D3(b))
//	E-008  plain MARK's planted text MARK:<name> does not appear verbatim
//	       in the op's own payload (VIRTUAL exempt, D24)
//	E-009  path-position token is not a lowercase spelling (kebab or
//	       snake; Pascal/camel red; OPAQUE exempt) (D28 correction)
//	E-010  MARK VIRTUAL without an ASLONG guard (idempotency must rest
//	       somewhere, D24)
//	E-011  ASLONG polarity contradicts DIRECTION: add ⇒ DONT CONTAIN,
//	       remove ⇒ CONTAIN (D23 — declared, never inferred)
//	E-012  guard/assert hygiene: non-ASCII text, or a }}} run (a token's
//	       }} adjacent to a literal }) (A5); ASSERT CMD strings are
//	       shell text, not match text — only the }}} rule binds them
//	E-013  OPAQUE variable referenced in more than one spelling in the
//	       file (D22)
//	E-014  SUCCESSOR pair: EXAMPLES value is not the named sibling's
//	       EXAMPLES + 1 (D22, the CountBefore/CountAfter lint)
//	E-015  SHAPE violation: unknown shape, or ts14 value that is not
//	       exactly 14 ASCII digits forming a real UTC instant (D16/D22)
//	E-016  REMOVE's fenced block does not contain its consumed mark text
//	       MARK:<name> (D25)
//	E-017  DELETE FILE IF PRESENT without a content-distinguishing ASLONG
//	       (D25)
//	E-018  ASSERT CMD TIER value is not "ci" (A2)
//	E-019  mark name is not kebab, or duplicates another mark in the same
//	       target file (D24)
//	E-020  DIRECTION header missing or not "add"|"remove" (D23)
//	E-021  ONEOF violation: a declared EXAMPLES value is not a member of
//	       the variable's ONEOF enum set (D56)
//	W-001  byte-identical payload appears twice — define a SNIPPET and
//	       USE it (D3(e))
//	W-002  declared VARIABLE is never referenced
//	W-003  generic fence label ("target"/"payload") — name the block
//	       (D27)
//	P-001  unknown statement
//	P-002  malformed statement (wrong arity, unquoted value, bad header)
//	P-003  dangling clause (MARK/ASLONG/REANCHOR/WITH/USE without an op
//	       to attach to)
//	P-004  USE references an undefined SNIPPET
//	P-005  REANCHOR misplaced (only directly after MARK on REPLACE, D21)
package scaffy

// Rule IDs, frozen (D28).
const (
	RuleFencePair          = "E-001"
	RuleUnfenced           = "E-002"
	RuleUndeclaredToken    = "E-003"
	RuleMalformedToken     = "E-004"
	RuleSelfConsuming      = "E-005"
	RuleGuardNotDerived    = "E-006"
	RuleMissingMark        = "E-007"
	RuleUnplantedMark      = "E-008"
	RulePathCasing         = "E-009"
	RuleVirtualNeedsGuard  = "E-010"
	RuleGuardPolarity      = "E-011"
	RuleGuardHygiene       = "E-012"
	RuleOpaqueSpelling     = "E-013"
	RuleSuccessor          = "E-014"
	RuleShape              = "E-015"
	RuleConsumedMark       = "E-016"
	RuleDeleteNeedsGuard   = "E-017"
	RuleTier               = "E-018"
	RuleMarkName           = "E-019"
	RuleDirectionRequired  = "E-020"
	RuleOneOf              = "E-021"
	RuleDuplicatePayload   = "W-001"
	RuleUnusedVariable     = "W-002"
	RuleGenericFenceLabel  = "W-003"
	RuleUnknownStatement   = "P-001"
	RuleMalformedStatement = "P-002"
	RuleDanglingClause     = "P-003"
	RuleUndefinedSnippet   = "P-004"
	RuleReanchorMisplaced  = "P-005"
)

// Severity of a rule: parse errors and E-rules fail validation, W-rules
// warn.
type Severity string

const (
	SeverityError Severity = "error"
	SeverityWarn  Severity = "warn"
)

// RuleInfo describes one catalog entry.
type RuleInfo struct {
	ID       string
	Severity Severity
	Title    string
}

// Rules is the frozen catalog, in ID order. Every Finding.Rule is one
// of these IDs.
var Rules = []RuleInfo{
	{RuleFencePair, SeverityError, "unclosed fence or fence label mismatch"},
	{RuleUnfenced, SeverityError, "unfenced multi-line target/payload"},
	{RuleUndeclaredToken, SeverityError, "token does not resolve to a declared VARIABLE"},
	{RuleMalformedToken, SeverityError, "token spelling is not a joiner output of its VARIABLE"},
	{RuleSelfConsuming, SeverityError, "self-consuming REPLACE needs a payload-derived ASLONG and a REANCHOR"},
	{RuleGuardNotDerived, SeverityError, "ASLONG guard is not a verbatim substring of the op's payload/fenced target"},
	{RuleMissingMark, SeverityError, "IN-op carries no MARK"},
	{RuleUnplantedMark, SeverityError, "plain MARK's planted text is missing from the op's own payload"},
	{RulePathCasing, SeverityError, "path-position token is not a lowercase (kebab/snake) spelling"},
	{RuleVirtualNeedsGuard, SeverityError, "MARK VIRTUAL requires an ASLONG guard"},
	{RuleGuardPolarity, SeverityError, "ASLONG polarity contradicts the declared DIRECTION"},
	{RuleGuardHygiene, SeverityError, "guard/assert text must be ASCII and free of }}} runs"},
	{RuleOpaqueSpelling, SeverityError, "OPAQUE variable referenced in more than one spelling"},
	{RuleSuccessor, SeverityError, "SUCCESSOR EXAMPLES value is not the sibling's EXAMPLES + 1"},
	{RuleShape, SeverityError, "SHAPE violation"},
	{RuleConsumedMark, SeverityError, "REMOVE's fenced block must contain its consumed mark text"},
	{RuleDeleteNeedsGuard, SeverityError, "DELETE FILE IF PRESENT needs a content-distinguishing ASLONG"},
	{RuleTier, SeverityError, "TIER value must be ci"},
	{RuleMarkName, SeverityError, "mark name must be kebab and unique within its target file"},
	{RuleDirectionRequired, SeverityError, "DIRECTION header missing or not add|remove"},
	{RuleOneOf, SeverityError, "ONEOF violation: an EXAMPLES value is outside the declared enum set"},
	{RuleDuplicatePayload, SeverityWarn, "duplicate payload — define a SNIPPET and USE it"},
	{RuleUnusedVariable, SeverityWarn, "declared VARIABLE is never referenced"},
	{RuleGenericFenceLabel, SeverityWarn, "generic fence label — name the block"},
	{RuleUnknownStatement, SeverityError, "unknown statement"},
	{RuleMalformedStatement, SeverityError, "malformed statement"},
	{RuleDanglingClause, SeverityError, "dangling clause without an op to attach to"},
	{RuleUndefinedSnippet, SeverityError, "USE references an undefined SNIPPET"},
	{RuleReanchorMisplaced, SeverityError, "REANCHOR only directly after MARK on REPLACE"},
}

// RuleByID looks a rule up in the catalog.
func RuleByID(id string) (RuleInfo, bool) {
	for _, r := range Rules {
		if r.ID == id {
			return r, true
		}
	}
	return RuleInfo{}, false
}
