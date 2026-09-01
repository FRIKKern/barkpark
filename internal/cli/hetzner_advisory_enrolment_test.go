package cli

// hetzner_advisory_enrolment_test.go is the ENROLMENT GATE for the Hetzner
// create-advisory population (PDS-D432). An advisory pair is one hzResAsked
// literal — a (response-field, asked-token, observed-token) triple fed to
// hzResDivergence so a CORRECT-looking create can still say "you asked for X,
// the server reports Y". The set of enrolled pairs is a JUDGEMENT (only flags
// whose validator is an identity may be enrolled), so it earns a table.
//
// WHY THIS GATE EXISTS. hetzner_lb_cmd.go once carried a PROSE header, "THE
// SEVEN ENROLLED CREATE PAIRS", that called itself "the complete list, in one
// place". Nothing guarded it. PDS wave 32 enrolled three MORE pairs in OTHER
// files — network/create ip_range (the POST-hzCIDR token), firewall/create
// rule_count, zone/create mode — and the prose, outside those slices' file set,
// silently understated the population by three for months. A bare prose rewrite
// buys one wave of accuracy and then drifts again the next time a pair lands in
// a file the author is not looking at.
//
// SO THE TABLE IS DERIVED, NOT TRANSCRIBED. hzAdvisoryPairsFromSource walks
// every non-test hetzner_*.go with go/ast and collects every hzResAsked
// composite literal keyed on (enclosing constructor, response-field) — the two
// coordinates that stay distinct when the same field name (`type`, `location`)
// is enrolled by two different verbs. hzAdvisoryEnrolledPairs is the declared
// registry, and the gate reds BOTH ways: a live pair with no row (a create
// enrolled without recording it) AND a row naming a pair no site emits (a stale
// transcription). Adding an hzResAsked without a registry row can no longer be
// invisible.
//
// It reuses hzResParseSources / hzResStringLit / hzResSourceFiles from
// hetzner_res_census_test.go (same glob, same stdlib parse, no new dependency).

import (
	"go/ast"
	"sort"
	"testing"
)

// hzAdvisoryPair is one enrolled create-advisory pair: the hzObserve*Created
// constructor the hzResAsked literal lives in, and the response FIELD it names
// (hzResAsked's first element). The enclosing constructor is part of the key
// because `type` is enrolled by both floating-ip and primary-ip create, and
// `location` by both load-balancer and primary-ip — a bare field name collapses
// them.
type hzAdvisoryPair struct {
	enclosing string
	field     string
}

// hzAdvisoryEnrolledPairs is THE enrolment table — machine-checked against
// source by TestHetznerAdvisoryEnrolmentTableComplete. It must name every live
// hzResAsked pair; the gate reds when a pair is added without a row here, or a
// row here names a pair no site emits. This is the durable replacement for the
// prose "SEVEN ENROLLED CREATE PAIRS" header, which drifted because nothing read
// it.
var hzAdvisoryEnrolledPairs = []hzAdvisoryPair{
	// load-balancer create — hetzner_lb_cmd.go, hzObserveLBCreated
	{"hzObserveLBCreated", "load_balancer_type"},
	{"hzObserveLBCreated", "location"},
	{"hzObserveLBCreated", "algorithm"},
	// floating-ip create — hetzner_lb_cmd.go, hzObserveFloatingIPCreated
	{"hzObserveFloatingIPCreated", "type"},
	{"hzObserveFloatingIPCreated", "home_location"},
	// primary-ip create — hetzner_lb_cmd.go, hzObservePrimaryIPCreated
	{"hzObservePrimaryIPCreated", "type"},
	{"hzObservePrimaryIPCreated", "location"},
	// network create — hetzner_net_cmd.go (PDS wave 32). ip_range is the
	// POST-hzCIDR token: the value that survives hzCIDR normalisation is what
	// the response echoes, so token equality is honest here.
	{"hzObserveNetworkCreated", "ip_range"},
	// firewall create — hetzner_net_cmd.go (PDS wave 32).
	{"hzObserveFirewallCreated", "rule_count"},
	// zone create — hetzner_dns_cmd.go (PDS wave 32).
	{"hzObserveZoneCreated", "mode"},
}

// hzAdvisoryFieldOf returns the response-field name a hzResAsked composite
// literal declares — its first element, whether written positionally
// (`hzResAsked{"mode", …}`) or keyed (`hzResAsked{field: "mode", …}`). The bool
// is false for anything non-literal, which the caller reports rather than
// silently dropping.
func hzAdvisoryFieldOf(cl *ast.CompositeLit) (string, bool) {
	for _, elt := range cl.Elts {
		if kv, ok := elt.(*ast.KeyValueExpr); ok {
			if key, ok := kv.Key.(*ast.Ident); ok && key.Name == "field" {
				return hzResStringLit(kv.Value)
			}
			continue
		}
		// positional: the FIRST element is `field`.
		return hzResStringLit(elt)
	}
	return "", false
}

// hzAdvisoryPairsFromSource DERIVES every enrolled advisory pair from the
// globbed hetzner_*.go sources, keyed on (enclosing constructor, field).
func hzAdvisoryPairsFromSource(t *testing.T) []hzAdvisoryPair {
	t.Helper()
	fset, files := hzResParseSources(t)
	var pairs []hzAdvisoryPair
	for _, file := range files {
		for _, d := range file.Decls {
			decl, ok := d.(*ast.FuncDecl)
			if !ok || decl.Body == nil {
				continue
			}
			ast.Inspect(decl.Body, func(n ast.Node) bool {
				cl, ok := n.(*ast.CompositeLit)
				if !ok {
					return true
				}
				id, ok := cl.Type.(*ast.Ident)
				if !ok || id.Name != "hzResAsked" {
					return true
				}
				field, ok := hzAdvisoryFieldOf(cl)
				if !ok {
					t.Errorf("%s: hzResAsked literal in %s has a non-literal first field — the enrolment gate keys on it and cannot record this pair",
						fset.Position(cl.Pos()), decl.Name.Name)
					return true
				}
				pairs = append(pairs, hzAdvisoryPair{enclosing: decl.Name.Name, field: field})
				return true
			})
		}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].enclosing != pairs[j].enclosing {
			return pairs[i].enclosing < pairs[j].enclosing
		}
		return pairs[i].field < pairs[j].field
	})
	return pairs
}

// TestHetznerAdvisoryEnrolmentTableComplete asserts the declared enrolment
// table names EXACTLY the live hzResAsked population — bidirectionally, so
// neither a new create enrolled without a row nor a stale row survives.
func TestHetznerAdvisoryEnrolmentTableComplete(t *testing.T) {
	live := hzAdvisoryPairsFromSource(t)

	// A vacuity floor: if the AST scan stops finding hzResAsked literals it
	// must fail loudly, not pass by measuring nothing. Seven live pairs
	// predate wave 32; the floor sits just below that so a real shrink still
	// reds while the arm cannot pass on an empty scan.
	const floor = 7
	if len(live) < floor {
		t.Fatalf("derived only %d hzResAsked advisory pairs (floor %d) — the AST scan is measuring nothing, not enforcing the enrolment table. The population was 10 when this gate was written.",
			len(live), floor)
	}

	liveSet := map[hzAdvisoryPair]bool{}
	for _, p := range live {
		liveSet[p] = true
	}
	wantSet := map[hzAdvisoryPair]bool{}
	for _, p := range hzAdvisoryEnrolledPairs {
		wantSet[p] = true
	}

	// Arm 1 — every live pair is recorded. This is the arm that caught the
	// wave-32 drift: ip_range / rule_count / mode emit advisories with no row.
	for p := range liveSet {
		if !wantSet[p] {
			t.Errorf("live advisory pair %s/%q emits a create advisory but has NO row in hzAdvisoryEnrolledPairs — a create was enrolled without recording it (this is exactly the wave-32 understatement PDS-D432 left standing)",
				p.enclosing, p.field)
		}
	}

	// Arm 2 — every recorded pair is live. A row naming a pair no hzResAsked
	// literal emits is a stale transcription and must red too.
	for _, p := range hzAdvisoryEnrolledPairs {
		if !liveSet[p] {
			t.Errorf("hzAdvisoryEnrolledPairs row %s/%q names a pair no hzResAsked literal emits — stale table entry",
				p.enclosing, p.field)
		}
	}
}
