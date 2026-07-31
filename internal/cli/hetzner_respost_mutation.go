package cli

// hetzner_respost_mutation.go — THE MUTATION POST-CONDITION APPARATUS: the
// SIBLING of hetzner_respost.go's destroy half, for every non-server Hetzner
// verb that leaves the resource ALIVE in a new state.
//
// THE LAW (PDS, unchanged since wave 22): NO BARKPARK VERB MAY REPORT SUCCESS
// ON AN EXIT CODE ALONE. The poster child this file exists to kill is
// `bp cloud hetzner load-balancer change-algorithm web-lb --algorithm
// round_robin`, which printed `algorithm: round_robin` because that is the
// string the operator typed. Every hcloud ACTION endpoint returns `{action}`
// and nothing else, so there is no "observe from the response" shortcut for a
// mutation the way there is for a create: the SINGLE-RESOURCE GET is the only
// server-side source, and this file is what makes every such verb take it.
//
// PDS-D415 — WHY THIS IS A SIBLING OF hzResDestroyed AND NOT A REUSE OF IT
// ------------------------------------------------------------------------
// THE POLARITY IS INVERTED, and that single fact is the whole reason for the
// file. hzResDestroyed's confirming read has three arms; the MIDDLE one flips:
//
//	                   (nil, nil)          non-nil            error
//	hzResDestroyed     the claim is        REFUSE: still      not confirmed,
//	                   EARNED (gone)       there              exit 0
//	hzResObserved      REFUSE: the verb    the state can be   not confirmed,
//	                   mutated something   OBSERVED and       exit 0
//	                   that is now not     compared
//	                   readable at all
//
// Reusing hzResDestroyed for a mutation is therefore not a style smell, it is a
// MEASURED FAIL-OPEN: fed a resource the API 404s, it emits
// `{"ok":true,"confirmed_gone":true}` for an action named "create".
// TestHetznerMutationPolarityIsLoadBearing pins both directions on the same
// input, because getting this backwards ships a lie on sixteen sites at once.
//
// The three ways this half differs from the destroy half — and there are
// exactly three, everything else is SHARED (hzResGoneRead, hzResUnconfirmed,
// hzResDone, hzResPayloadKey, hzMergeExtra):
//
//	1. THE NIL BRANCH IS INVERTED to a hard refusal at a non-zero exit.
//	2. THE RECEIPT KEY IS confirmed_present, not confirmed_gone.
//	3. IT CARRIES A DISAGREEMENT HOOK that names WHICH field disagreed, with
//	   what the server said and what was asked for — because "the post-condition
//	   failed" without a field name sends an operator reading the whole resource.
//
// THREE TRAPS THIS APPARATUS IS SHAPED AROUND (PDS-D399, all run-proven)
// ----------------------------------------------------------------------
//	(a) NESTED SERVER REFS CARRY AN ID, NEVER A NAME. `targets[].server` has
//	    props ['id','ip'] — a proven read gave Server.ID=42, Name="". So a naive
//	    "does the printed value appear in the payload" predicate FAILS ON HONEST
//	    DATA. Every predicate here binds on the id the verb ALREADY RESOLVED and
//	    keeps PRINTING the human name.
//	(b) `targets` and `services` are oneOf unions that hcloud-go flattens into
//	    one struct. Reading `.Server` on a label-selector target yields a ZERO
//	    VALUE, not an error — a confident false "confirmed". Every predicate
//	    switches on Type BEFORE any field read.
//	(c) THE READ MUST ADDRESS THE RESOLVED ID. resolveHzLB → hzResolve →
//	    LoadBalancer.Get goes straight to the NAME-FILTERED LIST for a
//	    non-numeric token, which can hand back a stale collection body that says
//	    `targets: []` while the receipt claims the target was added. Every call
//	    site passes a GetByID closure over the id it already holds.
//
// PDS-D401 (inherited): an UNREGISTERED read-back path yields ServeMux's
// text/plain 404, which hcloud-go cannot decode as an API error — so it becomes
// a TRANSPORT error and lands in the "not confirmed" arm, while PRODUCTION's
// JSON 404 lands in the refusal arm. Every fixture in hetzner_lb_cmd_test.go is
// explicit for that reason.

import (
	"context"
	"fmt"
	"strings"
)

// Mutation-side receipt keys. Deliberately DISTINCT spellings from the destroy
// half's confirmed_gone: one script key must never mean two opposite things.
const (
	hzKeyConfirmedPresent = "confirmed_present"

	// The two BASES a mutation receipt can be built from, named in the payload
	// so a reader can weigh the claim without reading this file. The GET basis
	// is strictly stronger: it is the server's own answer AFTER the action
	// settled, not the object the create call handed back.
	hzResBasisGet      = "single-resource GET on the resolved id"
	hzResBasisResponse = "the create response object"

	// hzKeyDivergence is the ADVISORY channel (PDS-D432): the receipt key a
	// create uses to say "the API accepted this, and what came back is not what
	// you asked for". It is deliberately NOT a refusal — see hzResObservation's
	// `advisory` field.
	hzKeyDivergence = "divergence"
)

// hzResObservation is what ONE post-read SAW: the fields to print, and — when
// the world disagrees with what the verb asked for — WHICH field disagreed,
// what the server reported, and what was wanted.
//
// THERE ARE THREE OUTCOMES, not two (PDS-D432):
//
//	field == "" && advisory == ""   ✓ receipt, exitOK
//	field == "" && advisory != ""   ✓ receipt PLUS a divergence line, STILL exitOK
//	field != ""                     REFUSAL at exitGeneric (hzResUnmet)
//
// `field` empty means agreement. It is the only signal that decides between a
// ✓ and a refusal, so it is deliberately the zero value: an observe hook that
// forgets to set it produces a ✓ only when it also produced no complaint.
type hzResObservation struct {
	// extra is the OBSERVED receipt payload — every value in it must come from
	// the object that was read, never from argv (PDS-D366). The one sanctioned
	// exception is a human NAME the server does not carry (trap (a)), which the
	// call site passes through `extra` instead.
	//
	// PDS-D432 — THE SECOND, NARROW CARVE-OUT FROM "NEVER FROM ARGV", AND IT IS
	// THE `advisory` FIELD BELOW, NOTHING ELSE. An advisory necessarily prints
	// argv: saying "you asked for X" requires X. It is authorised because it is
	// the ONE value in the receipt whose whole job is to contrast argv WITH the
	// observation, and it is required to be SELF-LABELLING in its own text —
	// it names the asked value as asked ("you asked for least_connections, the
	// server reports round_robin"), never as `<field>: <asked>`, which is the
	// request echo this apparatus exists to kill and which the anti-echo pin at
	// hetzner_lb_cmd_test.go:596/:606 reds on. Nothing else in `extra` may come
	// from argv, and an advisory may never change the exit code.
	extra map[string]any
	// field is the name of the field that disagreed; "" when nothing did.
	field string
	// saw is what the server reported for `field`; want is what was asked for.
	saw  string
	want string
	// advisory is the THIRD outcome: the create was accepted, the receipt is
	// honest, and what came back is not what argv asked for. Reported, never
	// challenged — it is folded into `extra` under hzKeyDivergence and the exit
	// code stays exitOK. Deliberately a SEPARATE field from `field`: reusing
	// `field` for an advisory would turn every divergence into a refusal, and a
	// create the API ACCEPTED must never exit non-zero on one (the only create
	// refusal stays obj == nil → hzResNotReadable).
	advisory string
}

// hzResAgrees is the agreeing observation, spelled as a constructor so a call
// site cannot accidentally leave `field` set from a previous branch.
func hzResAgrees(extra map[string]any) hzResObservation {
	return hzResObservation{extra: extra}
}

// hzResAgreesWith is the ADVISORY observation: a ✓ receipt that also carries a
// divergence line. `advisory` empty degrades to exactly hzResAgrees, so a call
// site whose comparison found nothing needs no branch of its own.
func hzResAgreesWith(extra map[string]any, advisory string) hzResObservation {
	return hzResObservation{extra: extra, advisory: advisory}
}

// hzResAsked is ONE argv value paired with what the response reports for it.
// Both sides are compared TOKEN-IDENTICALLY, so only flags whose own validator
// is an identity (or near-identity) may be enrolled — a flag the client
// normalises before sending (an id-or-name ref, a datacenter that answers as a
// location) would fire a FALSE advisory on a CORRECT create.
type hzResAsked struct {
	field    string
	asked    string
	observed string
}

// hzResDivergence compares each enrolled pair and renders the advisory text.
//
// A pair with an EMPTY `asked` is skipped: the flag was not given, or this
// branch of the verb does not carry it. A pair with an empty `observed` is
// skipped too — the response not carrying the field at all is silence, not
// disagreement, and there is nothing honest to contrast.
//
// THE PHRASING IS LOAD-BEARING (PDS-D432): `<field> — you asked for <asked>,
// the server reports <observed>`. It must never be spelled `<field>: <asked>`,
// which is the request echo under a new name.
func hzResDivergence(pairs ...hzResAsked) string {
	var lines []string
	for _, p := range pairs {
		if p.asked == "" || p.observed == "" || p.asked == p.observed {
			continue
		}
		lines = append(lines, fmt.Sprintf("%s — you asked for %s, the server reports %s", p.field, p.asked, p.observed))
	}
	return strings.Join(lines, "; ")
}

// hzResDisagrees is the refusing observation: the read succeeded and the world
// is NOT what the verb claimed.
func hzResDisagrees(field, saw, want string) hzResObservation {
	return hzResObservation{field: field, saw: saw, want: want}
}

// hzResObserveFn turns a freshly-read resource into an observation. It is where
// the union switch of trap (b) lives, per verb.
type hzResObserveFn[T any] func(*T) hzResObservation

// hzResObserved is THE mutation receipt: it re-reads the resource on its
// RESOLVED id, compares, and then either reports what the server NOW says or
// refuses the claim at a non-zero exit.
//
// It shares hzResGoneRead[T] with the destroy half on purpose — the same
// (value, *Response, error) triple, so the (nil, nil) miss stays
// distinguishable from a transport error — and inverts what that miss MEANS.
func hzResObserved[T any](out *writer, ctx context.Context, action, kind string, id any, name string, extra map[string]any, read hzResGoneRead[T], observe hzResObserveFn[T]) int {
	fresh, _, err := read(ctx)
	switch {
	case err != nil:
		// SHARED WITH THE DESTROY HALF, and for the same reason: the mutation
		// was accepted by the API; only the confirming read failed. Reporting a
		// failed verb here would push an operator into re-running a mutation
		// that already took. Not a ✓ either — the receipt says what could not
		// be observed.
		return hzResUnconfirmed(out, action, kind, id, name, hzMergeExtra(extra, map[string]any{
			hzKeyConfirmErr:       err.Error(),
			hzKeyConfirmedPresent: false,
		}), fmt.Sprintf("the %s was accepted but the confirming read failed, so the new state is %s: %v",
			action, hzNotConfirmedPhras, err))
	case fresh == nil:
		// THE INVERTED BRANCH. For a destroy this is the success condition; for
		// a mutation it means the verb reported changing something that is no
		// longer there at all.
		return hzResNotReadable(out, action, kind, id, name)
	default:
		return hzResReportObserved(out, action, kind, id, name, extra, hzResBasisGet, observe(fresh))
	}
}

// hzResObservedResponse is the CREATE half of the mutation apparatus.
//
// A create is NOT a request echo: the API's create RESPONSE carries the server's
// own object, so the response IS server truth and a second round trip would buy
// nothing. What this entry point exists to enforce is the OTHER half of that
// rule — that the receipt is built FROM that object and stops smuggling
// request-only extras beside it. The receipt names its basis
// ("the create response object") so a reader can tell it apart from the
// stronger post-action GET without reading the source.
//
// A create whose response carries no object is the same refusal as an
// unreadable post-read: the verb cannot report a resource nobody handed it.
func hzResObservedResponse[T any](out *writer, action, kind string, id any, name string, extra map[string]any, obj *T, observe hzResObserveFn[T]) int {
	if obj == nil {
		return hzResNotReadable(out, action, kind, id, name)
	}
	return hzResReportObserved(out, action, kind, id, name, extra, hzResBasisResponse, observe(obj))
}

// hzResReportObserved is the ONE place a mutation receipt is printed — the ✓ and
// the disagreement refusal in the same function, so the two cannot drift into
// different vocabularies.
func hzResReportObserved(out *writer, action, kind string, id any, name string, extra map[string]any, basis string, obs hzResObservation) int {
	if obs.field != "" {
		return hzResUnmet(out, action, kind, id, name, obs)
	}
	receipt := map[string]any{
		hzKeyConfirmedPresent: true,
		hzKeyConfirmBasis:     basis,
	}
	// THE THIRD OUTCOME (PDS-D432). `extra` is the one channel that reaches BOTH
	// surfaces for free — hzResDone spreads it into the JSON payload and
	// hzResPrintExtra prints it as a sorted `  key: value` line — so the
	// advisory rides it rather than growing a second reporting path that only
	// one surface would learn about. The exit code is untouched on purpose.
	if obs.advisory != "" {
		receipt[hzKeyDivergence] = obs.advisory
	}
	return hzResDone(out, action, kind, id, name, hzMergeExtra(extra, hzMergeExtra(obs.extra, receipt)))
}

// hzResNotReadable is the INVERTED nil branch: the API accepted the verb and
// then could not show the resource at all. Non-zero exit — a script that
// changed something and moved on is now wrong about the world, and unlike the
// destroy case there is no reading under which "gone" is what was wanted.
func hzResNotReadable(out *writer, action, kind string, id any, name string) int {
	return useError(out, "failed", fmt.Sprintf(
		"%s %s %s: the API accepted the %s but %s %s (id %v) is NOT READABLE afterwards — the post-condition is "+
			"UNMET, so this verb refuses to claim it holds (re-read it with `bp cloud hetzner %s get %s`)",
		action, kind, name, action, kind, name, id, kind, name), exitGeneric)
}

// hzResUnmet is THE DISAGREEMENT HOOK's output — the third difference from the
// destroy half. It NAMES the field, what the server reported, and what was
// asked for, because "the post-condition is unmet" on its own makes an operator
// re-read the entire resource to find out which part.
func hzResUnmet(out *writer, action, kind string, id any, name string, obs hzResObservation) int {
	return useError(out, "failed", fmt.Sprintf(
		"%s %s %s: the API accepted the %s but the %s now reports %s %s, not %s — the post-condition is UNMET on "+
			"field %q (id %v), so this verb refuses to claim it holds",
		action, kind, name, action, kind, obs.field, obs.saw, obs.want, obs.field, id), exitGeneric)
}
