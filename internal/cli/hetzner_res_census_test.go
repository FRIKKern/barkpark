package cli

// hetzner_res_census_test.go is the ENROLMENT GATE for the non-server Hetzner
// receipt population: every (kind, action) that reports a completed mutating
// verb must carry an explicit disposition saying what its receipt is built from
// — paid, or unpaid with the task id that will pay it.
//
// WHY A NEW SCANNER AND NOT A WIDENING OF THE SHIPPED ONE (PDS-D404)
// ------------------------------------------------------------------
// hetzner_cmd_test.go's hzReceiptSitesFromSource is a line-regex keyed on the
// VERB alone. Two things make it unusable here, and both were measured rather
// than assumed:
//
//	1. ITS REGEX CANNOT SEE THESE SITES. `\b(hzDone|hzFlagVerbDone)\(` cannot
//	   match inside hzResDone — the \b fails after the `s`. Widening the
//	   alternation is worse than useless: it then takes the FIRST quoted token as
//	   the verb, which at hetzner_net_cmd.go:811 and :1224 is the KIND
//	   ("network", "firewall") because the action there is a variable. Two verbs
//	   the dispatch never accepts.
//	2. ITS KEY IS FATAL AT THIS SCALE. A bare verb collapses 52 verbs into 29
//	   keys, with `create` and `delete` colliding eleven ways each. `delete` on a
//	   volume and `delete` on a DNS record are different obligations with
//	   different reads; one key cannot carry both dispositions.
//
// So this census is go/ast + go/parser (stdlib; the repo gains no dependency)
// keyed on ARGUMENT POSITION, which is the only thing that stays true when a
// receipt's kind and action are both strings in the same call.
//
// WHAT IT REUSES FROM THE SHIPPED GATE, DELIBERATELY: the file GLOB (so a tenth
// hetzner_*.go is scanned the day it lands), the FLOOR (so a scan that stops
// finding call sites fails loudly instead of passing vacuously), the
// BIDIRECTIONAL stale-entry arms (a disposition naming a key no site emits fails
// too), the keyed-AND-exempt arm, and the exemption-needs-a-reason discipline.
//
// WHAT IT ADDS, AND WHY IT IS NOT OPTIONAL: the per-CALLER opaque check. A
// naive per-SITE "no unresolved actions" assertion reads 0 even when a dispatch
// arm passes a variable — because the SITE resolved fine, it just resolved to
// fewer keys. Measured: making one arm of the add-route/delete-route dispatch
// pass a variable silently dropped a key (52 → 51) while UNRESOLVED_SITES still
// read 0. So the gate asserts OPAQUE_CALLERS == 0 and names the file:line of any
// dispatch arm that passes a non-literal.

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// hzResEmitters are the functions that PRINT a completed-verb receipt for a
// non-server resource, with the ARGUMENT POSITIONS of the action and the kind.
// Positions, not names: `hzResDone(out, action, kind, …)` and
// `hzResDestroyed(out, ctx, action, kind, …)` differ by one slot, and a scanner
// that guessed "the first quoted token" would derive the KIND as the action at
// the two dispatch-shared sites.
var hzResEmitters = map[string]struct{ actionArg, kindArg int }{
	"hzResDone":              {actionArg: 1, kindArg: 2},
	"hzResDestroyed":         {actionArg: 2, kindArg: 3},
	"hzResDestroyedDeclared": {actionArg: 1, kindArg: 2},
	// The MUTATION half (PDS-D415). hzResObserved takes a ctx like
	// hzResDestroyed and so shares its slots; hzResObservedResponse does not
	// read, so it does not take one — which is exactly why this census keys on
	// ARGUMENT POSITION rather than "the first quoted token".
	"hzResObserved":         {actionArg: 2, kindArg: 3},
	"hzResObservedResponse": {actionArg: 1, kindArg: 2},
}

// hzResApparatus are the generic emitters themselves. A call to hzResDone from
// INSIDE hzResDestroyed is the apparatus forwarding, not a verb reporting — its
// kind and action are parameters, and counting it would both inflate the
// population and manufacture two permanently-unresolvable keys. They are named
// here rather than filtered by file so that moving the apparatus does not
// silently re-admit them.
var hzResApparatus = map[string]bool{
	"hzResDestroyed":         true,
	"hzResDestroyedDeclared": true,
	"hzResUnconfirmed":       true,
	"hzResUnconfirmedAbsent": true,
	"hzResObserved":          true,
	"hzResObservedResponse":  true,
	"hzResReportObserved":    true,
}

// hzResClass is what a receipt is BUILT FROM — the taxonomy the epic reasons
// about. Not every site deserves the same fix, and pretending otherwise is how
// a 50-site sweep becomes a rubber stamp.
type hzResClass string

const (
	// hzClassDestroy — the resource ceases to exist. Paid by this slice: the
	// receipt re-reads and either says it is gone or refuses the claim.
	hzClassDestroy hzResClass = "destroy"
	// hzClassSubRemoval — a sub-resource is removed from a parent that
	// survives. The sub-resource has no identity of its own, so the post-read
	// is a PARENT read plus a containment predicate. Round 2.
	hzClassSubRemoval hzResClass = "sub-resource-removal"
	// hzClassCreate — the receipt echoes the create RESPONSE. Server-sourced,
	// so not a pure argument echo, but nothing re-reads to confirm the resource
	// settled into the state the response promised.
	hzClassCreate hzResClass = "create"
	// hzClassRequestEcho — the receipt reports the ARGUMENT back. This is the
	// exact defect PDS-D366 killed on the server surface, still live here.
	hzClassRequestEcho hzResClass = "request-echo"
	// hzClassMeasuredUncompared — a quantity WAS measured, and then compared to
	// nothing durable.
	hzClassMeasuredUncompared hzResClass = "measured-uncompared"
	// hzClassNoCheapPostRead — confirming would cost a second full round trip
	// of the same payload.
	hzClassNoCheapPostRead hzResClass = "no-cheap-post-read"
)

// hzResDisposition is one (kind, action) key's standing.
type hzResDisposition struct {
	class hzResClass
	// note is PAID evidence or an `unpaid: <task-id>` pointer. Never empty —
	// silence is what this table exists to replace.
	note string
}

const (
	hzUnpaidSubRemoval = "unpaid: pds-w29r2-subresource-removals"
	hzUnpaidMutation   = "unpaid: pds-w29r2-mutation-receipts"
)

// hzResDispositions is the ledger: every (kind, action) the sources emit, and
// what its receipt is built from today. It is checked BIDIRECTIONALLY — a key
// with no row fails, and a row naming a key no site emits fails just as hard,
// because a stale row makes the ledger look more complete than it is.
var hzResDispositions = map[string]hzResDisposition{
	// ---- PAID by this slice: the twelve full destroys. -------------------
	"volume/delete":          {hzClassDestroy, "paid: hzResDestroyed re-reads Volume.GetByID(vol.ID)"},
	"network/delete":         {hzClassDestroy, "paid: hzResDestroyed re-reads Network.GetByID(netw.ID)"},
	"firewall/delete":        {hzClassDestroy, "paid: hzResDestroyed re-reads Firewall.GetByID(fw.ID)"},
	"load-balancer/delete":   {hzClassDestroy, "paid: hzResDestroyed re-reads LoadBalancer.GetByID(lb.ID)"},
	"floating-ip/delete":     {hzClassDestroy, "paid: hzResDestroyed re-reads FloatingIP.GetByID(fip.ID)"},
	"primary-ip/delete":      {hzClassDestroy, "paid: hzResDestroyed re-reads PrimaryIP.GetByID(pip.ID)"},
	"placement-group/delete": {hzClassDestroy, "paid: hzResDestroyed re-reads PlacementGroup.GetByID(pg.ID)"},
	"certificate/delete":     {hzClassDestroy, "paid: hzResDestroyed re-reads Certificate.GetByID(cert.ID)"},
	"zone/delete":            {hzClassDestroy, "paid: hzResDestroyed re-reads Zone.GetByID(zone.ID)"},
	"record/delete":          {hzClassDestroy, "paid: hzResDestroyed re-reads GetRRSetByNameAndType on the key it holds"},
	"bucket/delete":          {hzClassDestroy, "paid: hzResDestroyedDeclared — non-binding ListBuckets, fails closed"},
	"object/rm":              {hzClassDestroy, "paid: hzResDestroyedDeclared — non-binding key-prefix list, fails closed"},

	// ---- PAID by pds-w29-pay-lb: the LB family's four sub-removals. -------
	// A sub-resource has no identity of its own, so the post-read is a PARENT
	// read on the RESOLVED id plus a containment predicate.
	"load-balancer/delete-service": {hzClassSubRemoval,
		"paid: hzResObserved re-reads LoadBalancer.GetByID(lb.ID); hzObserveLBServiceAbsent"},
	"load-balancer/remove-target": {hzClassSubRemoval,
		"paid: hzResObserved re-reads LoadBalancer.GetByID(lb.ID); hzObserveLBTargetAbsent switches on target Type first"},
	"floating-ip/unassign": {hzClassSubRemoval,
		"paid: hzResObserved re-reads FloatingIP.GetByID(fip.ID); hzObserveFloatingIPUnassigned"},
	"primary-ip/unassign": {hzClassSubRemoval,
		"paid: hzResObserved re-reads PrimaryIP.GetByID(pip.ID); hzObservePrimaryIPUnassigned"},

	// ---- Round 2: the remaining sub-resource removals. --------------------
	"network/delete-subnet":         {hzClassSubRemoval, hzUnpaidSubRemoval},
	"network/delete-route":          {hzClassSubRemoval, hzUnpaidSubRemoval},
	"firewall/remove-from-resource": {hzClassSubRemoval, hzUnpaidSubRemoval},
	"volume/detach":                 {hzClassSubRemoval, hzUnpaidSubRemoval},

	// ---- PAID by pds-w29-pay-lb: the LB family's six creates. -------------
	// CLASS A2: the create RESPONSE object is server truth, so these observe
	// FROM it rather than paying a second round trip — and the receipt names
	// that weaker basis ("the create response object") instead of implying the
	// post-action GET the mutations take.
	"load-balancer/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.LoadBalancer; hzObserveLBCreated"},
	"floating-ip/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.FloatingIP; hzObserveFloatingIPCreated (type is the API's, not the flag's)"},
	"primary-ip/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.PrimaryIP; hzObservePrimaryIPCreated"},
	"placement-group/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.PlacementGroup; hzObservePlacementGroupCreated"},
	"certificate/create-uploaded": {hzClassCreate,
		"paid: hzResObservedResponse observes result.Certificate; hzObserveCertificateUploaded (fingerprint + validity window)"},
	"certificate/create-managed": {hzClassCreate,
		"paid: hzResObservedResponse observes result.Certificate; hzObserveCertificateManaged DECLARES the async issuance state rather than asserting `issued`"},

	// ---- Round 2: the remaining create receipts. --------------------------
	"volume/create":  {hzClassCreate, hzUnpaidMutation},
	"network/create": {hzClassCreate, hzUnpaidMutation},
	"firewall/create": {hzClassCreate, hzUnpaidMutation},
	"zone/create":     {hzClassCreate, hzUnpaidMutation},
	"record/create":   {hzClassCreate, hzUnpaidMutation},
	"bucket/create":   {hzClassCreate, hzUnpaidMutation},
	"backup/create":   {hzClassCreate, hzUnpaidMutation},
	"backup/restore":  {hzClassCreate, hzUnpaidMutation},

	// ---- PAID by pds-w29-pay-lb: the LB family's six request echoes. ------
	// Every hcloud ACTION endpoint returns `{action}` and nothing else, so the
	// single-resource GET on the RESOLVED id is the only server-side source.
	"load-balancer/add-service": {hzClassRequestEcho,
		"paid: hzResObserved re-reads LoadBalancer.GetByID(lb.ID); hzObserveLBServicePresent reports the SERVED destination port"},
	"load-balancer/add-target": {hzClassRequestEcho,
		"paid: hzResObserved re-reads LoadBalancer.GetByID(lb.ID); hzObserveLBTargetPresent binds on the resolved id across the server|label_selector|ip union"},
	"load-balancer/change-algorithm": {hzClassRequestEcho,
		"paid: hzResObserved re-reads LoadBalancer.GetByID(lb.ID); hzObserveLBAlgorithm — the poster child, now printing what the LB reports"},
	"load-balancer/change-type": {hzClassRequestEcho,
		"paid: hzResObserved re-reads LoadBalancer.GetByID(lb.ID); hzObserveLBType prints the resolved type name+id, never the raw flag"},
	"floating-ip/assign": {hzClassRequestEcho,
		"paid: hzResObserved re-reads FloatingIP.GetByID(fip.ID); hzObserveFloatingIPAssigned compares server IDs, prints the name"},
	"primary-ip/assign": {hzClassRequestEcho,
		"paid: hzResObserved re-reads PrimaryIP.GetByID(pip.ID); hzObservePrimaryIPAssigned checks the assignee PAIR"},

	// ---- Round 2: the remaining request echoes. ---------------------------
	"volume/attach":              {hzClassRequestEcho, hzUnpaidMutation},
	"volume/resize":              {hzClassRequestEcho, hzUnpaidMutation},
	"volume/change-protection":   {hzClassRequestEcho, hzUnpaidMutation},
	"network/add-subnet":         {hzClassRequestEcho, hzUnpaidMutation},
	"network/add-route":          {hzClassRequestEcho, hzUnpaidMutation},
	"network/change-ip-range":    {hzClassRequestEcho, hzUnpaidMutation},
	"firewall/set-rules":         {hzClassRequestEcho, hzUnpaidMutation},
	"firewall/apply-to-resource": {hzClassRequestEcho, hzUnpaidMutation},
	"zone/update":                {hzClassRequestEcho, hzUnpaidMutation},
	"record/update":              {hzClassRequestEcho, hzUnpaidMutation},

	// ---- Round 2: the object-storage pair that is neither. ----------------
	"object/put": {hzClassMeasuredUncompared, hzUnpaidMutation},
	"object/get": {hzClassNoCheapPostRead, hzUnpaidMutation},
}

// PDS-D418 — THE THREE RULINGS THAT STOP A PAID ROW BEING A SENTENCE
// ------------------------------------------------------------------
// A `paid:` note is prose, and prose is exactly what this census exists to
// replace. Before this wave a row could read "paid: hzResObserved re-reads …"
// while the source it names calls nothing of the sort — a paste from the row
// above, and no gate would notice. So three things are now MECHANICAL:
//
//	1. A paid note must NAME its paying symbol as the first token after
//	   `paid: `, and that symbol must actually be CALLED from the source file
//	   that emits the key (hzResPaidSymbol + the companion assertion).
//	2. The symbol must be legal FOR THAT CLASS. A `create` or `request-echo` row
//	   paid with hzResDestroyed REDS, because the destroy helper's nil branch
//	   means the opposite thing there — the measured fail-open this wave shipped
//	   the mutation apparatus to stop.
//	3. Every KIND currently in the ledger must still be emitted. The glob makes
//	   a NEW file cheap to enrol; nothing made a kind LEAVING cost anything
//	   louder than a tidy-looking row deletion.

// hzResPaidSymbol extracts the symbol a `paid:` note names — the first token
// after "paid: ". Returns "" for an unpaid row or a note that names nothing.
func hzResPaidSymbol(note string) string {
	rest, ok := strings.CutPrefix(strings.TrimSpace(note), "paid:")
	if !ok {
		return ""
	}
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		return ""
	}
	return strings.Trim(fields[0], "`,;")
}

// hzResClassHelpers is THE CLASS-TO-HELPER BINDING: which paying symbols are
// legal for which class. The point is not taxonomy — it is that hzResDestroyed
// and hzResObserved read the SAME (nil, nil) and mean opposite things, so a row
// paid with the wrong one is a fail-open wearing a green row.
var hzResClassHelpers = map[hzResClass][]string{
	hzClassDestroy:    {"hzResDestroyed", "hzResDestroyedDeclared"},
	hzClassSubRemoval: {"hzResObserved"},
	// A create observes FROM the response object (class A2) — it does not
	// re-read, so hzResObserved is wrong here too, in the other direction.
	hzClassCreate:      {"hzResObservedResponse"},
	hzClassRequestEcho: {"hzResObserved"},
}

// hzResLedgerKinds is every resource kind the ledger currently covers. Pinned
// by NAME so a kind vanishing from the sources costs an explicit edit here
// rather than passing as a row cleanup.
var hzResLedgerKinds = []string{
	"backup", "bucket", "certificate", "firewall", "floating-ip", "load-balancer",
	"network", "object", "placement-group", "primary-ip", "record", "volume", "zone",
}

// hzResCensusExemptions is the escape hatch for a (kind, action) that can never
// carry a disposition at all — and it is EMPTY TODAY, on purpose. It exists
// because the gates below need something to guard: a key that is BOTH keyed and
// exempt is a contradiction, and an exemption with an empty reason is an
// omission wearing a map key. Both arms were proven live by mutation rather
// than assumed (see the wave report); leaving the map empty is a claim that
// nothing currently needs excusing, not that the check is decorative.
var hzResCensusExemptions = map[string]string{}

// hzResSite is one derived receipt call.
type hzResSite struct {
	file      string
	line      int
	emitter   string
	kind      string // "" when the kind argument is not a literal
	action    string // "" when the action argument is not a literal
	enclosing string // the function that contains the call
	// actionParam is the flattened parameter index of the enclosing function's
	// parameter that supplies the action, when the action is that parameter.
	// -1 otherwise.
	actionParam int
}

// hzResSourceFiles is the population: every non-test hetzner_*.go. A GLOB, so a
// file added tomorrow is scanned the day it lands.
func hzResSourceFiles(t *testing.T) []string {
	t.Helper()
	all, err := filepath.Glob(filepath.Join(".", "hetzner_*.go"))
	if err != nil {
		t.Fatalf("glob hetzner_*.go: %v", err)
	}
	var srcs []string
	for _, p := range all {
		if !strings.HasSuffix(p, "_test.go") {
			srcs = append(srcs, p)
		}
	}
	sort.Strings(srcs)
	if len(srcs) < 2 {
		t.Fatalf("globbed %d hetzner sources (%v) — the scan is measuring itself, not the package", len(srcs), srcs)
	}
	return srcs
}

// hzResParseSources parses the globbed sources once.
func hzResParseSources(t *testing.T) (*token.FileSet, map[string]*ast.File) {
	t.Helper()
	fset := token.NewFileSet()
	files := map[string]*ast.File{}
	for _, path := range hzResSourceFiles(t) {
		f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		files[path] = f
	}
	return fset, files
}

// hzResStringLit returns the value of a string literal argument, or "" and
// false for anything else (an identifier, a call, a concatenation).
func hzResStringLit(e ast.Expr) (string, bool) {
	lit, ok := e.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return "", false
	}
	v, err := strconv.Unquote(lit.Value)
	if err != nil {
		return "", false
	}
	return v, true
}

// hzResParamIndex reports the FLATTENED parameter index of name in decl's
// signature (`a, b string, c int` → a=0, b=1, c=2), or -1.
func hzResParamIndex(decl *ast.FuncDecl, name string) int {
	if decl == nil || decl.Type.Params == nil {
		return -1
	}
	i := 0
	for _, field := range decl.Type.Params.List {
		if len(field.Names) == 0 {
			i++
			continue
		}
		for _, n := range field.Names {
			if n.Name == name {
				return i
			}
			i++
		}
	}
	return -1
}

// hzResSitesFromSource DERIVES every non-server receipt call in the globbed
// sources, keyed on argument position.
func hzResSitesFromSource(t *testing.T) []hzResSite {
	t.Helper()
	fset, files := hzResParseSources(t)
	var sites []hzResSite
	for path, file := range files {
		for _, d := range file.Decls {
			decl, ok := d.(*ast.FuncDecl)
			if !ok || decl.Body == nil {
				continue
			}
			if hzResApparatus[decl.Name.Name] {
				continue // the apparatus forwarding to hzResDone is not a verb site
			}
			ast.Inspect(decl.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				fn, ok := call.Fun.(*ast.Ident)
				if !ok {
					return true
				}
				pos, ok := hzResEmitters[fn.Name]
				if !ok || len(call.Args) <= pos.kindArg {
					return true
				}
				site := hzResSite{
					file:        path,
					line:        fset.Position(call.Pos()).Line,
					emitter:     fn.Name,
					enclosing:   decl.Name.Name,
					actionParam: -1,
				}
				site.kind, _ = hzResStringLit(call.Args[pos.kindArg])
				if lit, ok := hzResStringLit(call.Args[pos.actionArg]); ok {
					site.action = lit
				} else if id, ok := call.Args[pos.actionArg].(*ast.Ident); ok {
					site.actionParam = hzResParamIndex(decl, id.Name)
				}
				sites = append(sites, site)
				return true
			})
		}
	}
	sort.Slice(sites, func(i, j int) bool {
		if sites[i].file != sites[j].file {
			return sites[i].file < sites[j].file
		}
		return sites[i].line < sites[j].line
	})
	return sites
}

// hzResCaller is one call of a dispatch function that supplies a receipt's
// action, with the literal it passed (or "" when it passed something opaque).
type hzResCaller struct {
	file    string
	line    int
	callee  string
	literal string
}

// hzResCallersOf finds every call to fnName in the globbed sources and reads
// the argument at paramIdx. This is the ONE-HOP caller pass that resolves
// hetzner_net_cmd.go:811 and :1224 to their four dispatch literals.
func hzResCallersOf(t *testing.T, fnName string, paramIdx int) []hzResCaller {
	t.Helper()
	fset, files := hzResParseSources(t)
	var callers []hzResCaller
	for path, file := range files {
		ast.Inspect(file, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			fn, ok := call.Fun.(*ast.Ident)
			if !ok || fn.Name != fnName || len(call.Args) <= paramIdx {
				return true
			}
			c := hzResCaller{file: path, line: fset.Position(call.Pos()).Line, callee: fnName}
			c.literal, _ = hzResStringLit(call.Args[paramIdx])
			callers = append(callers, c)
			return true
		})
	}
	sort.Slice(callers, func(i, j int) bool {
		if callers[i].file != callers[j].file {
			return callers[i].file < callers[j].file
		}
		return callers[i].line < callers[j].line
	})
	return callers
}

// hzResCensus is the derived population: the resolved (kind, action) keys, the
// sites that emitted each, and the opaque callers that could not be resolved.
type hzResCensus struct {
	sites      []hzResSite
	keys       map[string][]string // "kind/action" → "file:line" emitters
	nonLiteral []hzResSite
	opaque     []hzResCaller
}

func hzResBuildCensus(t *testing.T) hzResCensus {
	t.Helper()
	c := hzResCensus{sites: hzResSitesFromSource(t), keys: map[string][]string{}}
	for _, s := range c.sites {
		where := fmt.Sprintf("%s:%d", s.file, s.line)
		if s.kind == "" {
			t.Errorf("%s: the KIND argument of %s is not a string literal — the census cannot key a receipt "+
				"whose resource kind is computed", where, s.emitter)
			continue
		}
		if s.action != "" {
			c.keys[s.kind+"/"+s.action] = append(c.keys[s.kind+"/"+s.action], where)
			continue
		}
		// NON-LITERAL: the action comes from the enclosing function's
		// parameter, so the keys are whatever its CALLERS pass.
		c.nonLiteral = append(c.nonLiteral, s)
		if s.actionParam < 0 {
			t.Errorf("%s: %s takes a non-literal action that is not a parameter of %s — nothing can resolve it",
				where, s.emitter, s.enclosing)
			continue
		}
		callers := hzResCallersOf(t, s.enclosing, s.actionParam)
		if len(callers) == 0 {
			t.Errorf("%s: %s is called by nothing this scan can see — its receipt keys are unknowable",
				where, s.enclosing)
			continue
		}
		for _, caller := range callers {
			if caller.literal == "" {
				c.opaque = append(c.opaque, caller)
				continue
			}
			key := s.kind + "/" + caller.literal
			c.keys[key] = append(c.keys[key], fmt.Sprintf("%s (via %s:%d)", where, caller.file, caller.line))
		}
	}
	return c
}

// TestHetznerResourceReceiptCensus is the enrolment gate.
func TestHetznerResourceReceiptCensus(t *testing.T) {
	c := hzResBuildCensus(t)

	// THE CENSUS, printed under -v: what was DERIVED, from which files, in
	// which class — the evidence that the population was COUNTED and not
	// transcribed from a charter that said 51.
	t.Logf("TOTAL=%d sites across %v", len(c.sites), hzResSourceFiles(t))
	t.Logf("NON_LITERAL=%d  KEYS=%d  OPAQUE_CALLERS=%d", len(c.nonLiteral), len(c.keys), len(c.opaque))
	byClass := map[hzResClass][]string{}
	for key := range c.keys {
		byClass[hzResDispositions[key].class] = append(byClass[hzResDispositions[key].class], key)
	}
	for _, class := range []hzResClass{hzClassDestroy, hzClassSubRemoval, hzClassCreate,
		hzClassRequestEcho, hzClassMeasuredUncompared, hzClassNoCheapPostRead} {
		keys := byClass[class]
		sort.Strings(keys)
		t.Logf("  %-20s %2d  %v", class, len(keys), keys)
	}

	// THE FLOOR. A self-measurement guard, not a census: deliberately BELOW the
	// measured 50 so adding a verb never has to touch it. A count under it means
	// the SCAN stopped finding call sites — a renamed emitter, a moved file, a
	// changed call shape — not that verbs were deleted.
	const siteFloor = 40
	if len(c.sites) < siteFloor {
		t.Fatalf("derived %d receipt sites across %v — below the floor of %d. The population measured 50 when this "+
			"census was written (38 hzResDone + 10 hzResDestroyed + 2 hzResDestroyedDeclared). Re-derive before "+
			"trusting anything below", len(c.sites), hzResSourceFiles(t), siteFloor)
	}

	// THE OPAQUE-CALLER ARM, and it is NOT optional. A per-SITE "nothing
	// unresolved" check reads 0 even when a dispatch arm passes a variable: the
	// SITE resolved, it just resolved to FEWER KEYS. Measured by mutation —
	// turning one add-route/delete-route arm into a variable dropped the key
	// count 52 → 51 while a naive unresolved-sites check stayed at 0.
	for _, o := range c.opaque {
		t.Errorf("%s:%d calls %s with a NON-LITERAL action — that dispatch arm's (kind, action) key is invisible "+
			"to this census, so a receipt can go unenrolled while every other arm of this gate reads green",
			o.file, o.line, o.callee)
	}

	// COLLISIONS. One key emitted by two sites means two obligations wearing one
	// disposition — the exact failure that makes a verb-only key useless here.
	for key, wheres := range c.keys {
		if len(wheres) > 1 {
			t.Errorf("(kind, action) %q is emitted by %d sites (%v) — one disposition cannot describe two receipts",
				key, len(wheres), wheres)
		}
	}

	// EVERY EMITTED KEY IS ENROLLED, and the keyed/exempt arms.
	for key := range c.keys {
		disp, keyed := hzResDispositions[key]
		reason, exempt := hzResCensusExemptions[key]
		switch {
		case keyed && exempt:
			t.Errorf("%q is BOTH given a disposition and exempt — one of the two is a lie about what its "+
				"receipt is built from", key)
		case exempt:
			if strings.TrimSpace(reason) == "" {
				t.Errorf("%q takes a census exemption with an empty reason — an exemption without an argument "+
					"is just an omission wearing a map key", key)
			}
		case !keyed:
			t.Errorf("%q reports a completed-verb receipt at %v but carries NO disposition — nobody can tell "+
				"whether it reports an observed state or the argument it was handed. Add a row: paid with its "+
				"evidence, or `unpaid: <task-id>`", key, c.keys[key])
		default:
			if strings.TrimSpace(disp.note) == "" {
				t.Errorf("%q carries an empty disposition note — a blank row is silence with extra steps", key)
			}
			if disp.class == "" {
				t.Errorf("%q carries no class — the classification is what decides which fix it needs", key)
			}
			if strings.HasPrefix(disp.note, "unpaid:") && strings.TrimSpace(strings.TrimPrefix(disp.note, "unpaid:")) == "" {
				t.Errorf("%q is unpaid but names no task — an unpaid row without a pointer is a backlog nobody holds", key)
			}
		}
	}

	// STALE ROWS, BOTH DIRECTIONS. A disposition (or exemption) naming a key no
	// site emits makes the ledger look more complete than it is.
	for key := range hzResDispositions {
		if _, live := c.keys[key]; !live {
			t.Errorf("hzResDispositions carries %q, which NO site in %v emits — a stale row inflates the ledger "+
				"and hides the next receipt that needs one", key, hzResSourceFiles(t))
		}
	}
	for key := range hzResCensusExemptions {
		if _, live := c.keys[key]; !live {
			t.Errorf("hzResCensusExemptions excuses %q, which NO site in %v emits — a stale exemption excuses "+
				"nothing", key, hzResSourceFiles(t))
		}
	}
}

// TestHetznerResourceDispositionsAreBoundToRealCode is PDS-D418's gate: the
// three rulings that turn a `paid:` note from a sentence into a claim something
// can falsify.
func TestHetznerResourceDispositionsAreBoundToRealCode(t *testing.T) {
	c := hzResBuildCensus(t)

	// Read each scanned source once; the companion assertion is a grep, and a
	// grep per row would re-read the same nine files fifty times.
	src := map[string]string{}
	for _, path := range hzResSourceFiles(t) {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		src[path] = string(b)
	}

	for key, wheres := range c.keys {
		disp, ok := hzResDispositions[key]
		if !ok || strings.HasPrefix(strings.TrimSpace(disp.note), "unpaid:") {
			continue // the enrolment gate above owns unenrolled and unpaid rows
		}
		symbol := hzResPaidSymbol(disp.note)
		if symbol == "" {
			t.Errorf("%q is paid but its note NAMES NO SYMBOL — write `paid: <helper> …` so the claim points at "+
				"code instead of describing it (note: %q)", key, disp.note)
			continue
		}

		// RULING 2 — the class-to-helper binding. Checked BEFORE the grep,
		// because hzResDestroyed is genuinely called from most of these files:
		// a create row paid with it would sail through the grep alone.
		legal, known := hzResClassHelpers[disp.class]
		if !known {
			t.Errorf("%q is class %q, which no row in hzResClassHelpers binds to a helper — a class nothing "+
				"binds cannot catch a receipt paid with the wrong polarity", key, disp.class)
		} else if !slices.Contains(legal, symbol) {
			t.Errorf("%q is class %q but is paid with %s, which is not one of %v. hzResDestroyed and "+
				"hzResObserved read the SAME (nil, nil) and mean OPPOSITE things — a create or a mutation paid "+
				"with the destroy helper emits confirmed_gone:true on a resource that 404s",
				key, disp.class, symbol, legal)
		}

		// RULING 1 — the companion grep: the named symbol is actually CALLED
		// from the source file that emits this key.
		file, _, _ := strings.Cut(wheres[0], ":")
		body, seen := src[file]
		if !seen {
			t.Errorf("%q is emitted from %q, which is not one of the scanned sources %v", key, file, hzResSourceFiles(t))
			continue
		}
		if !strings.Contains(body, symbol+"(") {
			t.Errorf("%q claims to be paid by %s, but %s never CALLS %s — the row describes code that is not "+
				"there, which is the one failure a prose ledger cannot catch by itself", key, symbol, file, symbol)
		}
	}

	// RULING 3 — the per-KIND presence assertion. The glob makes a new file
	// cheap to enrol; nothing made a kind LEAVING cost anything.
	live := map[string]bool{}
	for key := range c.keys {
		kind, _, _ := strings.Cut(key, "/")
		live[kind] = true
	}
	for _, kind := range hzResLedgerKinds {
		if !live[kind] {
			t.Errorf("kind %q emits NO receipt in %v any more. If that verb family really was removed, delete its "+
				"rows AND this pin in the same edit — a kind that leaves silently takes its obligations with it",
				kind, hzResSourceFiles(t))
		}
	}
	sort.Strings(hzResLedgerKinds)
	t.Logf("KINDS=%d %v", len(hzResLedgerKinds), hzResLedgerKinds)
}

// TestHetznerResourceCensusMeasuresTheKnownPopulation pins the numbers the wave
// derived, so a change to the population is a DECISION somebody makes rather
// than a drift nobody notices. These are exact, not floors: they are what the
// census measured on the day it shipped, and any movement should re-run the
// derivation before editing them.
func TestHetznerResourceCensusMeasuresTheKnownPopulation(t *testing.T) {
	c := hzResBuildCensus(t)
	if got := len(c.sites); got != 50 {
		t.Errorf("TOTAL = %d, want 50 — re-derive with `git grep -n 'hzResDone(' -- internal/cli | grep -v _test.go` "+
			"plus the hzResDestroyed/hzResDestroyedDeclared sites before changing this number", got)
	}
	if got := len(c.nonLiteral); got != 2 {
		t.Errorf("NON_LITERAL = %d, want 2 (hetzner_net_cmd.go's add-route/delete-route and "+
			"apply-to-resource/remove-from-resource dispatchers)", got)
	}
	if got := len(c.keys); got != 52 {
		t.Errorf("KEYS = %d, want 52 (48 literal sites + the 4 caller literals behind the 2 dispatchers)", got)
	}
	if got := len(c.opaque); got != 0 {
		t.Errorf("OPAQUE_CALLERS = %d, want 0 — %v", got, c.opaque)
	}
	// The two dispatchers must resolve to their FOUR caller literals, by name.
	for _, want := range []string{"network/add-route", "network/delete-route",
		"firewall/apply-to-resource", "firewall/remove-from-resource"} {
		if _, ok := c.keys[want]; !ok {
			t.Errorf("the one-hop caller pass did not resolve %q — the dispatch-shared receipt sites at "+
				"hetzner_net_cmd.go:811/:1224 are the whole reason this census is AST-based", want)
		}
	}
}
