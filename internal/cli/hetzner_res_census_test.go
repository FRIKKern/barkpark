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
// read 0. So the gate asserts OPAQUE_ACTION_CALLERS == 0 and names the file:line
// of any dispatch arm that passes a non-literal ACTION.
//
// THE NAME IS EXACT AND DELIBERATE (PDS-D456). This counter can only ever hold
// an unresolvable ACTION, never an unresolvable KIND: hzResBuildCensus's kind
// branch t.Errorf's and `continue`s BEFORE the caller pass that fills it runs,
// so a non-literal kind can never reach it. It was called OPAQUE_CALLERS, which
// invited "extend it to cover kinds too" — that extension is impossible without
// merging an unkeyable SITE into a counter whose message says ACTION. A
// non-literal kind is already caught, by name, at that guard.

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

// PDS wave 32 — THE DEBT REACHED ZERO, AND WHAT THAT DOES NOT MEAN.
//
// The two `unpaid:` constants that used to live here — the sub-removal one and
// the mutation one — are GONE, because every row that named one is paid. THE
// METRIC IS A GREP FOR THEIR SHARED PREFIX (hz + Unpaid) OVER THIS FILE, and it
// must read 0; it read 21 on the day this edit was made (2 declarations + 19
// uses), which is why this paragraph spells the prefix apart rather than
// quoting it — a comment that names the token would keep the metric off zero
// forever. The honest headline is 17 unpaid SITES / 19 unpaid KEYS → 0.
//
// TWO NUMBERS THAT DO **NOT** GO TO ZERO, AND MUST NOT BE QUOTED AS IF THEY DID:
//
//	`grep -c 'unpaid:'`      floors at 4 — the hzResDisposition type doc plus the
//	                         census's OWN unpaid-format validator below. Driving
//	                         it to 0 would delete the enforcement.
//	`grep -c 'hzResDone('`   stays at 6 across internal/cli: the func DEFINITION
//	                         in hetzner_net_cmd.go, the two DECLARED classes
//	                         (object/get, backup/restore), and the apparatus
//	                         forwards.
//
// AND THE BOUNDARY ON THE CLAIM ITSELF. Zero unpaid rows means: every (kind,
// action) in ONE resource family — the non-server Hetzner verbs — on ONE
// provider now carries a disposition that names code something can falsify. It
// does NOT mean every Barkpark verb is honest, it does not reach the server
// surface or any non-Hetzner provider, and the REFUSAL direction is still proven
// only by fakes: no live credential has ever been spent watching one of these
// verbs refuse. That last gap is the same one wave 30's live placement-group
// round trip stated for the success direction.

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

	// ---- PAID by pds-w29-pay-net-dns: the last four sub-removals. ---------
	// Two of these four are emitted by a SHARED DISPATCH SITE whose sibling arm
	// is a PRESENT check. No arm of this census reads that direction branch, so
	// the wrong-direction payment is invisible here by construction — the
	// both-direction fakes in hetzner_net_cmd_test.go are what catch it.
	"network/delete-subnet": {hzClassSubRemoval,
		"paid: hzResObserved re-reads Network.GetByID(netw.ID); hzObserveNetworkSubnetAbsent"},
	"network/delete-route": {hzClassSubRemoval,
		"paid: hzResObserved re-reads Network.GetByID(netw.ID); hzObserveNetworkRouteAbsent — the delete-route arm of the shared dispatcher"},
	"firewall/remove-from-resource": {hzClassSubRemoval,
		"paid: hzResObserved re-reads Firewall.GetByID(fw.ID); hzObserveFirewallRemoved switches on the resource Type first"},
	"volume/detach": {hzClassSubRemoval,
		"paid: hzResObserved re-reads Volume.GetByID(vol.ID); hzObserveVolumeDetached"},

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

	// ---- PAID by pds-w29-pay-net-dns: the last five creates. --------------
	// Three of them are ADVISORY-ENROLLED (PDS-D432): network/create compares the
	// POST-hzCIDR token, never the raw --ip-range flag (hzCIDR masks host bits,
	// so the raw flag fires a FALSE advisory on a CORRECT create);
	// firewall/create compares `rule_count` with the COUNT grade stated in the
	// receipt; zone/create compares the RAW --mode value, because the resolved
	// mode would be degenerately always-equal.
	"volume/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.Volume; hzObserveVolumeCreated reports the device the API assigned"},
	"network/create": {hzClassCreate,
		"paid: hzResObservedResponse observes the created Network under an EMPTY-ID COLLAPSE; hzObserveNetworkCreated " +
			"advises on the normalised ip_range"},
	"firewall/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.Firewall under an EMPTY-ID COLLAPSE (the generated converter makes " +
			"nil unreachable, so an id-less firewall is collapsed to nil); hzObserveFirewallCreated reports an " +
			"OBSERVED rule_count, graded COUNT"},
	"zone/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.Zone; hzObserveZoneCreated advises on the RAW --mode token"},
	"record/create": {hzClassCreate,
		"paid: hzResObservedResponse observes result.RRSet under an EMPTY-ID COLLAPSE (the generated converter makes " +
			"nil unreachable, so an id-less rrset is collapsed to nil); hzObserveRecordCreated"},

	// ---- PAID by pds-w29-pay-storage-backup: the S3 writes. ---------------
	// These take the STRONGER basis of the two a create can have: an actual
	// post-read, not the response object — because the S3 write calls return no
	// object at all, and a bucket/key that is absent afterwards is exactly the
	// silently-dropping endpoint this epic exists to catch.
	"bucket/create": {hzClassCreate,
		"paid: hzResObserved re-reads ListBuckets after the create; hzObserveBucketCreated reports the CREATED " +
			"time the listing gave and marks `location` declared-unconfirmed"},
	"backup/create": {hzClassCreate,
		"paid: hzResObserved HEADs the key backup.Backup returned; hzObserveBackupStored reports the STORED length " +
			"and marks `database` declared-unconfirmed"},
	"backup/restore": {hzClassNoCheapPostRead,
		"paid: hzRestoreNotConfirmed — DECLARED EXEMPTION: the post-condition lives in the target Postgres, " +
			"outside this verb's S3 credential plane, so the receipt says not confirmed instead of fabricating it"},

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

	// ---- PAID by pds-w29-pay-net-dns: the last ten request echoes. --------
	// Every hcloud ACTION endpoint returns `{action}` and nothing else, so the
	// single-resource GET on the RESOLVED id is the only server-side source —
	// including for `record`, whose key is the (zone, name, type) the verb
	// already holds rather than a numeric id.
	"volume/attach": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Volume.GetByID(vol.ID); hzObserveVolumeAttached binds on the RESOLVED server id"},
	"volume/resize": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Volume.GetByID(vol.ID); hzObserveVolumeSize reports the size the volume NOW carries"},
	"volume/change-protection": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Volume.GetByID(vol.ID); hzObserveVolumeProtection reads Protection.Delete"},
	"network/add-subnet": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Network.GetByID(netw.ID); hzObserveNetworkSubnetPresent reports the range the API CHOSE when --ip-range was omitted"},
	"network/add-route": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Network.GetByID(netw.ID); hzObserveNetworkRoutePresent — the add-route arm of the shared dispatcher"},
	"network/change-ip-range": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Network.GetByID(netw.ID); hzObserveNetworkIPRange"},
	"firewall/set-rules": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Firewall.GetByID(fw.ID); hzObserveFirewallRuleCount refuses on a differing count, graded COUNT"},
	"firewall/apply-to-resource": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Firewall.GetByID(fw.ID); hzObserveFirewallApplied switches on the resource Type first"},
	"zone/update": {hzClassRequestEcho,
		"paid: hzResObserved re-reads Zone.GetByID(zone.ID); hzObserveZoneUpdated compares only what was ASKED for"},
	"record/update": {hzClassRequestEcho,
		"paid: hzResObserved re-reads GetRRSetByNameAndType on the key it holds; hzObserveRecordUpdated compares values order-insensitively"},

	// ---- PAID by pds-w29-pay-storage-backup: the pair that is neither. ----
	// object/put is ONE line on TWO paths (PutObject with a source size,
	// PutLarge without one), so its post-read is EXISTENCE-based and the length
	// is compared only when there is a length to compare.
	// object/get is a RECLASSIFICATION, not a new read: a GET already carries
	// the server's declared length on the same response and refuses on a
	// mismatch, so the honest payment is to name the symbol that does it — a
	// HeadObject afterwards would confirm nothing and cost the whole payload.
	"object/put": {hzClassMeasuredUncompared,
		"paid: hzResObserved HEADs the key after the write; hzObserveObjectStored reports the STORED length and " +
			"compares it only when the source declared one"},
	"object/get": {hzClassNoCheapPostRead,
		"paid: hzSizeVerdict compares the length the SAME response declared against the bytes written, and the " +
			"copy is refused non-zero on a mismatch — a GET *is* the read"},
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
	// A create takes ONE of two bases, and both REFUSE on the miss — which is
	// the property this binding exists to enforce. hzResObservedResponse
	// observes the create RESPONSE object (class A2: server truth, but the
	// object handed back rather than the world re-read). hzResObserved is the
	// STRONGER of the two: an actual post-read, which is the only basis
	// available where the create call returns no object at all (every S3 write
	// — CreateBucket and PutObject return an error and nothing else). What stays
	// illegal for both is hzResDestroyed, whose (nil, nil) branch means the
	// OPPOSITE thing and emits confirmed_gone:true on a create that never took.
	hzClassCreate:      {"hzResObservedResponse", "hzResObserved"},
	hzClassRequestEcho: {"hzResObserved"},
	// A quantity that WAS measured is paid by re-reading it from the store —
	// never by comparing the measurement to itself.
	hzClassMeasuredUncompared: {"hzResObserved"},
	// The class where a second read buys nothing. Its legal symbols are the two
	// that DECLARE the gap in the receipt instead of papering over it:
	// hzSizeVerdict (the length rode the same response the bytes did, so the
	// GET is the read) and hzRestoreNotConfirmed (the post-condition lives in
	// another system entirely, so the receipt says `not confirmed`). Both name
	// what was NOT verified — a row here paid with an observe helper would be
	// claiming a read this class says does not exist.
	hzClassNoCheapPostRead: {"hzSizeVerdict", "hzRestoreNotConfirmed"},
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

	// ---- PDS wave 34, leg 1: the CONFIRMATION BASIS, derived. ------------
	// basisForm says HOW this site names the read its receipt claims, and it is
	// the discriminator every basis arm below keys on:
	//
	//	hzBasisConst      the site passed a named hzResBasis* constant
	//	hzBasisInherited  the site passed nothing; hzResBasisOf supplies the GET
	//	                  default (21 of the 25 hzResObserved sites today)
	//	hzBasisResponse   hzResObservedResponse, which takes no basis argument
	//	                  at all — it hardcodes hzResBasisResponse
	//	hzBasisLiteral    a BARE STRING passed where a constant belongs. Legal
	//	                  today ONLY on hzResDestroyedDeclared, whose `basis
	//	                  string` parameter is mandatory and non-variadic; an
	//	                  hzResObserved site that does this is REJECTED, because
	//	                  a literal cannot be bound to a class.
	basisForm hzBasisForm
	// basisIdent is the constant's identifier, "" unless basisForm is
	// hzBasisConst or hzBasisResponse. A SYMBOL, not a string compare — the same
	// discrimination the scanner already makes for the action.
	basisIdent string
	// basisText is the WORDING the receipt will actually print: the constant's
	// value, the literal's value, or hzResBasisGet for an inherited site.
	basisText string
	// readText is the source of the confirming-read argument, whitespace
	// collapsed. This is leg 2's whole evidence: what the site claims (basis)
	// judged against what it actually calls (read).
	readText string
}

// hzBasisForm is how a site names its confirmation basis. See hzResSite.
type hzBasisForm string

const (
	hzBasisNone      hzBasisForm = ""          // the emitter carries no basis at all
	hzBasisConst     hzBasisForm = "const"     // a named hzResBasis* identifier
	hzBasisInherited hzBasisForm = "inherited" // omitted; hzResBasisOf's GET default
	hzBasisResponse  hzBasisForm = "response"  // hzResObservedResponse's hardcoded basis
	hzBasisLiteral   hzBasisForm = "literal"   // a bare string at the call site
)

// hzResBasisArgs is the BASIS argument slot per emitter, and the two shapes are
// deliberately different so nothing can average them:
//
//	hzResObserved          index 9, TRAILING VARIADIC — absent means inherited.
//	hzResDestroyedDeclared index 6, MANDATORY and non-variadic — the object-store
//	                       destroys must always say what listing they scanned.
//
// hzResObservedResponse is ABSENT ON PURPOSE: it takes no basis argument, so
// there is no slot to read. Its basis is asserted structurally instead, by
// TestHetznerResourceBasisResponseEmitterHardcodesItsBasis.
var hzResBasisArgs = map[string]int{
	"hzResObserved":          9,
	"hzResDestroyedDeclared": 6,
}

// hzResReadArgs is the CONFIRMING-READ argument slot per emitter — the closure
// or read helper whose source text leg 2 judges the basis against. Both shapes
// present today are covered: an *ast.CallExpr helper (hzS3HeadRead(c, …)) and an
// *ast.FuncLit whose body names its primitive (… hc.Volume.GetByID(c, vol.ID)).
var hzResReadArgs = map[string]int{
	"hzResObserved":          7,
	"hzResDestroyedDeclared": 7,
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
	text := hzResSourceText(t)
	consts := hzResBasisConstants(t)
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
				hzResCaptureBasis(t, &site, call, fset, text[path], consts)
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
		// THE SINGLE LOAD-BEARING DETECTOR FOR A NON-LITERAL KIND, and the one
		// place it is caught. Four tests appear to red on that mutation; they are
		// NOT four arms — they are THIS t.Errorf, reached through every test that
		// calls hzResBuildCensus, plus the one genuinely independent stale-row
		// arm. True redundancy is 2x, not 4x. So a tidy-looking refactor of
		// hzResBuildCensus to RETURN errors instead of calling t.Errorf would
		// delete four apparent arms in one edit: any such change must move this
		// assertion, not just relocate its text.
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
	t.Logf("NON_LITERAL=%d  KEYS=%d  OPAQUE_ACTION_CALLERS=%d", len(c.nonLiteral), len(c.keys), len(c.opaque))
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

	// THE OPAQUE-ACTION-CALLER ARM, and it is NOT optional. A per-SITE "nothing
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

// TestHetznerResourceCensusMeasuresTheKnownPopulation holds the ONE population
// pin that mutation testing could not remove, plus two invariants that are not
// population counts at all.
//
// PDS-D444/D455 — WHY TOTAL SURVIVED AND ITS TWO NEIGHBOURS DID NOT. Eleven
// mutations against a clean tree, re-run on the merged tree, found exactly one
// shape that no other arm of this file notices: mutation I2 — take a real,
// paid, dispositioned verb, delete its hzResDone call so it returns exitOK with
// NO receipt at all, and delete its disposition row in the SAME coherent
// commit. The stale-row arm is escaped (the row left with the site), the
// kind-presence arm is escaped (the kind still emits other receipts), the site
// floor is escaped (49 > 40). That is a Barkpark verb reporting success on an
// exit code alone — this epic's founding law — repealable in one silent commit.
// TOTAL is the only thing that reds on it, so TOTAL stays.
//
//   - KEYS != 52 was DELETED: it fired in lockstep with TOTAL on I2 and on
//     population collapse, and was blind to the one shape it might have owned
//     (a duplicate key leaves KEYS at 52; the collision arm catches that).
//   - NON_LITERAL != 2 was DELETED: it reddened in ZERO of the eleven mutations.
//     Both numbers are still LOGGED by the census test above — they just no
//     longer tax an honest growth commit.
//
// TWO THINGS TO KNOW BEFORE YOU TOUCH TOTAL:
//   - Only the COHERENT I2 is TOTAL's alone. The incoherent version (emitter
//     deleted, disposition row kept) is caught a second time by the genuinely
//     independent stale-row arm.
//   - TOTAL's uniqueness is about COHERENCE, not ARITY. No single-key kind
//     exists on main (the minima are backup/bucket/placement-group at 2 keys
//     each), so an I2 never incidentally empties a kind; constructed, a
//     single-key I2 reds THREE arms, while a fully coherent one reds TOTAL alone.
//
// DO NOT convert TOTAL to a floor. Measured: `< 50` keeps the I2 catch and
// removes the growth tax, but shrinkage MASKED BY PRIOR GROWTH (population
// grows to 51, then a real receipt and its row are deleted back to 50) then
// passes fully green. A floor is only as strong as an exact pin if every growth
// commit bumps it — which restores the tax it was meant to remove.
func TestHetznerResourceCensusMeasuresTheKnownPopulation(t *testing.T) {
	c := hzResBuildCensus(t)
	if got := len(c.sites); got != 50 {
		t.Errorf("TOTAL = %d, want 50 — a receipt site left (or joined) the population. Retiring a verb "+
			"COHERENTLY (its hzResDone/hzResDestroyed call AND its disposition row deleted in ONE commit) "+
			"reds HERE AND NOWHERE ELSE — that is mutation I2, and it is this epic's law ('no Barkpark verb "+
			"may report success on an exit code alone') repealable in a single silent edit. A real removal "+
			"is still allowed; it just has to be made HERE, deliberately. Re-derive with "+
			"`git grep -n 'hzResDone(' -- internal/cli | grep -v _test.go` plus the hzResDestroyed/"+
			"hzResDestroyedDeclared sites before changing this number", got)
	}
	// NOT a population count: an unresolvable dispatch ACTION means a receipt
	// key is invisible to the whole census, so the number is 0 forever.
	if got := len(c.opaque); got != 0 {
		t.Errorf("OPAQUE_ACTION_CALLERS = %d, want 0 — %v", got, c.opaque)
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

// PDS-D426 — THE SHRUNKEN-POPULATION HOLE, AND THE TWO ARMS THAT CLOSE IT
// ------------------------------------------------------------------------
// PDS-D418's ruling 3 was written "so deleting a kind costs an explicit,
// reviewable edit rather than a row cleanup that looks like tidying". As
// IMPLEMENTED above it iterates hzResLedgerKinds and asserts each pinned kind is
// LIVE — pinned-subset-of-live, and nothing more. So the ledger can be satisfied
// by SHRINKING it. Measured on clean main before these arms existed: deleting
// "zone" from hzResLedgerKinds, with the three zone rows and every zone source
// UNTOUCHED, left the whole suite `ok` with zero errors, cheerfully logging
// KINDS=12. One line, fully green. Every other arm here checks the ledger
// against the code; none checked the ledger's own POPULATION against the code.
//
// ARM 1 (below) adds the missing direction — kind-set EQUALITY, so a kind that
// still emits receipts but has left the pin is as loud as a pin with no
// receipts. ARM 3 scans the sources the census does NOT glob, so relocating an
// emitter out of hetzner_*.go cannot shrink the population either.
//
// A THIRD ARM WAS PROTOTYPED AND DELIBERATELY NOT BUILT: pinning the globbed
// SOURCE SET by name. It was measured redundant — with it excluded, de-globbing
// hetzner_storage_cmd.go is still caught twice over, by the shipped stale-row
// arm (five named orphan rows) and by ARM 1 ("bucket" pinned, emitting nothing).
// It is also the only candidate arm that reds on every NEW hetzner_*.go, i.e.
// the only one that taxes growth, which is what PDS-D418 rules against.
//
// NEITHER ARM QUOTES A KIND COUNT. Set equality already implies the length, and
// a bare len() pin is precisely the renegotiable number D418 forbids: it turns
// every legitimate refactor into a floor negotiation. The exact pins that used
// to tax growth here (TOTAL=50 / KEYS=52 / NON_LITERAL=2) were the filed
// question pds-bl-census-exact-pins-tax-growth, and it has since been SETTLED by
// mutation (PDS-D444/D455): KEYS and NON_LITERAL are deleted as measured
// redundant, and TOTAL is kept — see the comment on
// TestHetznerResourceCensusMeasuresTheKnownPopulation for why it is the only arm
// that notices a receipt retired coherently with its disposition row.
//
// WHAT THIS IS WORTH, STATED HONESTLY SO NOBODY OVER-READS IT
// ------------------------------------------------------------
//   - THIS GATE IS ADVISORY (PDS-D425). go-tests.yml runs these tests on every
//     **/*.go PR and really executes them, but live branch protection requires
//     only ["Elixir gate", "PR references an active task"]. A red here is a
//     signal a reviewer sees; it CANNOT refuse a merge. Registering the context
//     is a separate repo-wide decision (the workflow is paths-filtered, and a
//     required paths-filtered context deadlocks main) — filed as
//     pds-bl-go-tests-not-required.
//   - IT MAKES SHRINKAGE EXPLICIT AND REVIEWABLE, NOT IMPOSSIBLE. The honest
//     two-step — delete the verb, delete its rows, delete the pin, in one
//     coherent commit — still goes green, which is correct for a real removal.
//     What it stops is the pin moving ALONE.
//   - IT IS BLIND TO FUNC-VALUE EMITTERS. Both arms (like the shipped scanner)
//     match *ast.Ident call targets, so an emitter reached through a variable, a
//     method value, or a struct field is invisible to them. Filed as
//     pds-bl-census-ast-scan-blind-to-func-values.

// hzResNonGlobbedSources is the complement of the census population: every
// non-test *.go in internal/cli that hzResSourceFiles does NOT scan. Test files
// are excluded because they legitimately call the emitters directly to prove
// their behaviour (hetzner_lb_cmd_test.go and success_claim_registry_test.go
// both do); production code outside the glob has no such excuse.
func hzResNonGlobbedSources(t *testing.T) []string {
	t.Helper()
	globbed := map[string]bool{}
	for _, p := range hzResSourceFiles(t) {
		globbed[filepath.Base(p)] = true
	}
	all, err := filepath.Glob(filepath.Join(".", "*.go"))
	if err != nil {
		t.Fatalf("glob *.go: %v", err)
	}
	var srcs []string
	for _, p := range all {
		if strings.HasSuffix(p, "_test.go") || globbed[filepath.Base(p)] {
			continue
		}
		srcs = append(srcs, p)
	}
	sort.Strings(srcs)
	return srcs
}

// TestHetznerResourceCensusKindSetIsExact is ARM 1: the ledger's kind population
// must EQUAL the kinds the sources emit, in both directions. The shipped ruling-3
// loop asserts only that a pinned kind is live; this asserts the converse too, so
// a kind cannot leave the ledger while its receipts stay in the tree.
func TestHetznerResourceCensusKindSetIsExact(t *testing.T) {
	c := hzResBuildCensus(t)

	live := map[string][]string{} // kind → the keys that prove it
	for key := range c.keys {
		kind, _, _ := strings.Cut(key, "/")
		live[kind] = append(live[kind], key)
	}
	pinned := map[string]bool{}
	for _, kind := range hzResLedgerKinds {
		pinned[kind] = true
	}

	liveKinds := make([]string, 0, len(live))
	for kind := range live {
		liveKinds = append(liveKinds, kind)
	}
	sort.Strings(liveKinds)

	for _, kind := range liveKinds {
		if pinned[kind] {
			continue
		}
		keys := slices.Clone(live[kind])
		sort.Strings(keys)
		t.Errorf("RATCHET/KIND-UNPINNED: kind %q emits receipts in the scanned sources (%v) but is ABSENT from "+
			"hzResLedgerKinds — the ledger's population is smaller than the code's, so this kind's obligations "+
			"are invisible to every per-kind arm of this census. Add %q to hzResLedgerKinds.", kind, keys, kind)
	}

	for _, kind := range hzResLedgerKinds {
		if len(live[kind]) > 0 {
			continue
		}
		t.Errorf("RATCHET/KIND-VANISHED: kind %q is pinned but emits NO receipt any more in %v. If the verb family "+
			"really was removed, delete its dispositions AND this pin in the same commit — a kind that leaves "+
			"silently takes its obligations with it.", kind, hzResSourceFiles(t))
	}

	t.Logf("KIND-SET live=%v pinned=%v", liveKinds, hzResLedgerKinds)
}

// TestHetznerResourceReceiptEmittersStayInsideTheCensusGlob is ARM 3: no
// production source OUTSIDE hetzner_*.go may call a receipt emitter. Equality of
// the kind set (ARM 1) is only as honest as the file set it is derived from — a
// receipt-emitting file renamed or moved out of the glob shrinks the derived
// population, and every arm that reasons from c.keys then reads a smaller world
// without saying so. This arm is completely GROWTH-FREE: a new hetzner_*.go is
// inside the glob, so it never speaks for legitimate growth.
func TestHetznerResourceReceiptEmittersStayInsideTheCensusGlob(t *testing.T) {
	sources := hzResNonGlobbedSources(t)

	// A vacuity floor, not a census: if this scan stops finding sources the arm
	// would pass by looking at nothing. It counts FILES OUTSIDE the census, a
	// population that only grows, so it is not a tax on anything.
	const nonGlobbedFloor = 40
	if len(sources) < nonGlobbedFloor {
		t.Fatalf("only %d non-globbed sources to scan (floor %d) — this arm is measuring nothing. internal/cli held "+
			"86 when it was written; check the working directory and the glob before trusting a green here",
			len(sources), nonGlobbedFloor)
	}

	fset := token.NewFileSet()
	orphans := 0
	for _, path := range sources {
		f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			fn, ok := call.Fun.(*ast.Ident)
			if !ok {
				return true
			}
			if _, emitter := hzResEmitters[fn.Name]; !emitter {
				return true
			}
			orphans++
			t.Errorf("RATCHET/EMITTER-OUTSIDE-GLOB: %s:%d calls %s, but %s is NOT one of the census sources %v. "+
				"This receipt is emitted where the census cannot see it, so its (kind, action) carries no "+
				"disposition and no per-kind arm speaks for it. Either move it back under hetzner_*.go or widen "+
				"hzResSourceFiles in the same commit.",
				path, fset.Position(call.Pos()).Line, fn.Name, path, hzResSourceFiles(t))
			return true
		})
	}

	t.Logf("OUT-OF-GLOB SCAN: %d non-globbed non-test sources in internal/cli, %d orphaned emitter calls",
		len(sources), orphans)
}

// ============================================================================
// PDS wave 34 — THE CENSUS LEARNS EACH RECEIPT'S CONFIRMATION BASIS
// ============================================================================
//
// WHAT WAS UNDEFENDED, MEASURED RATHER THAN ASSERTED. Before this block the word
// `basis` appeared in this file only inside comments. The scanner read
// call.Args[actionArg] and call.Args[kindArg] and nothing else, so the trailing
// variadic that names the read a receipt claims was never looked at. Three
// things followed:
//
//	(a) 21 of the 25 hzResObserved sites INHERIT hzResBasisGet by omission, and
//	    nothing checked that the read they perform is a GET. Giving one of them
//	    an explicit contradicting basis was GREEN on the pre-change tree
//	    (ok 29.593s, full package, no selector).
//	(b) The 4 explicit sites were pinned only BEHAVIOURALLY, by
//	    TestHzResObservedBasisIsVisibleToAnOperator, which drives four verbs
//	    through fakes. That arm is real — swapping backup create's
//	    hzResBasisHead for hzResBasisListScan REDS it, measured — but it speaks
//	    for four sites out of twenty-five, and it compares the printed value
//	    against the CONSTANT, so it cannot see the constant itself change.
//	(c) The two hzResDestroyedDeclared sites passed BARE STRING LITERALS into a
//	    mandatory `basis string` parameter. No constant, no const block, no
//	    test. THE BASIS SURFACE IS SEVEN, NOT FOUR: seven hzResBasis* constants —
//	    four in hetzner_respost_mutation.go, hzResBasisRRSetKey deliberately
//	    outside that block in hetzner_dns_cmd.go, and (since wave 35 paid
//	    pds-w34-declared-basis-literals-need-constants)
//	    hzResBasisBucketListAfterDelete and hzResBasisObjectKeyListAfterDelete
//	    beside their verbs in hetzner_storage_cmd.go. Anything scoped to ONE
//	    FILE still misses three of the seven, which is why the population is
//	    globbed and derived rather than listed.
//
// A CORRECTION TO THIS PACKAGE'S OWN PROSE. hetzner_respost_basis_test.go says
// "thirteen" / "the ten hcloud callers" / "the three object-store call sites".
// DERIVED FROM SOURCE the population is 25 hzResObserved sites: 4 explicit
// (hetzner_backup_cmd.go:225, hetzner_dns_cmd.go:767, hetzner_storage_cmd.go:423
// and :615 — CALL lines, one or two above the argument lines usually quoted) and
// 21 inherited, of which hetzner_lb_cmd.go carries 10 and hetzner_net_cmd.go
// another 10 that no comment in the package mentions. A binding table written
// off that prose would have been half empty.

// hzResSourceText reads the globbed sources once so an argument's SOURCE TEXT
// can be sliced by offset. Leg 2 needs the text, not the tree: the confirming
// read appears in two AST shapes (a helper *ast.CallExpr and an *ast.FuncLit
// whose body names its primitive), and matching the text is the one rule that
// covers both without a per-shape special case a third shape would escape.
func hzResSourceText(t *testing.T) map[string]string {
	t.Helper()
	text := map[string]string{}
	for _, path := range hzResSourceFiles(t) {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		text[path] = string(b)
	}
	return text
}

// hzResExprText returns e's source, whitespace collapsed to single spaces.
func hzResExprText(fset *token.FileSet, src string, e ast.Expr) string {
	lo, hi := fset.Position(e.Pos()).Offset, fset.Position(e.End()).Offset
	if lo < 0 || hi > len(src) || lo >= hi {
		return ""
	}
	return strings.Join(strings.Fields(src[lo:hi]), " ")
}

// hzResBasisConstants DERIVES every basis constant in the scanned sources —
// identifier → wording — by walking the AST for `const hzResBasis… = "…"`.
//
// DERIVED, NEVER HAND-ENUMERATED (HG-D31). A hand list is the vacuous-coverage
// shape this epic keeps finding: it looks like an index and defends only the
// members somebody remembered. hzResBasisRRSetKey already proved a basis
// constant can be declared in another file entirely, so nothing about the const
// block's contents bounds the population — the seven live constants sit in
// THREE files. An EIGHTH constant added anywhere under hetzner_*.go enters this
// map the day it lands, and reds the coverage arms below because it has no row.
func hzResBasisConstants(t *testing.T) map[string]string {
	t.Helper()
	_, files := hzResParseSources(t)
	consts := map[string]string{}
	for _, file := range files {
		for _, d := range file.Decls {
			gen, ok := d.(*ast.GenDecl)
			if !ok || gen.Tok != token.CONST {
				continue
			}
			for _, s := range gen.Specs {
				vs, ok := s.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for i, name := range vs.Names {
					if !strings.HasPrefix(name.Name, "hzResBasis") || i >= len(vs.Values) {
						continue
					}
					if v, ok := hzResStringLit(vs.Values[i]); ok {
						consts[name.Name] = v
					}
				}
			}
		}
	}
	if len(consts) < 2 {
		t.Fatalf("derived %d basis constants from %v — the scan is finding nothing, not measuring an empty surface",
			len(consts), hzResSourceFiles(t))
	}
	return consts
}

// hzResCaptureBasis fills the basis and read fields of one derived site.
//
// THE NAMED-CONSTANT RULE LIVES HERE, and it is the same discrimination the
// scanner already makes for the action: an *ast.Ident is a SYMBOL the census can
// bind to a class, an *ast.BasicLit is a sentence nothing can bind. A string at
// ANY call site — wave 35 removed the hzResDestroyedDeclared exemption — is
// REJECTED by name, not because literals are ugly, but because the per-key
// table, the read binding and the wording gate all key on the symbol, so a
// literal opts a site out of all three at once while still printing a
// confirmation_basis an operator will trust.
func hzResCaptureBasis(t *testing.T, site *hzResSite, call *ast.CallExpr, fset *token.FileSet, src string, consts map[string]string) {
	t.Helper()
	where := fmt.Sprintf("%s:%d", site.file, site.line)

	if ra, ok := hzResReadArgs[site.emitter]; ok && len(call.Args) > ra {
		site.readText = hzResExprText(fset, src, call.Args[ra])
	}

	if site.emitter == "hzResObservedResponse" {
		// No basis argument exists to read: this emitter hardcodes its basis,
		// which is asserted structurally rather than positionally.
		site.basisForm, site.basisIdent, site.basisText = hzBasisResponse, "hzResBasisResponse", consts["hzResBasisResponse"]
		return
	}

	ba, carries := hzResBasisArgs[site.emitter]
	if !carries {
		site.basisForm = hzBasisNone
		return
	}
	if len(call.Args) <= ba {
		if site.emitter != "hzResObserved" {
			t.Errorf("%s: %s takes a MANDATORY basis at argument %d and this call has %d — the census cannot "+
				"judge a receipt that names no read", where, site.emitter, ba, len(call.Args))
			return
		}
		// The trailing variadic omitted: hzResBasisOf supplies the GET default.
		site.basisForm, site.basisIdent, site.basisText = hzBasisInherited, "hzResBasisGet", consts["hzResBasisGet"]
		return
	}

	switch arg := call.Args[ba].(type) {
	case *ast.Ident:
		site.basisForm, site.basisIdent = hzBasisConst, arg.Name
		text, known := consts[arg.Name]
		if !known {
			t.Errorf("%s: %s passes basis %s, which is not a basis constant this census can derive from %v — "+
				"the receipt names a read nothing in the scanned sources defines",
				where, site.emitter, arg.Name, hzResSourceFiles(t))
			return
		}
		site.basisText = text
	case *ast.BasicLit:
		lit, ok := hzResStringLit(arg)
		if !ok {
			t.Errorf("%s: %s passes a non-string basis literal", where, site.emitter)
			return
		}
		// EVERY EMITTER, not just hzResObserved. Until wave 35 the two
		// hzResDestroyedDeclared sites were exempt, and that exemption was the
		// hole: a literal is unbindable wherever it is passed, and nothing
		// stopped a THIRD declared destroy landing with another bare string.
		// The site is still RECORDED as a literal (basisForm below) so the
		// coverage arms see it and it fails LOUDLY rather than vanishing from
		// the population.
		site.basisForm, site.basisText = hzBasisLiteral, lit
		t.Errorf("%s: %s passes the STRING LITERAL %q as its confirmation basis. A LITERAL CANNOT BE BOUND TO "+
			"A CLASS: the per-key pin, the read binding and the wording gate all key on the SYMBOL, so a "+
			"literal opts this receipt out of all three at once. Declare an hzResBasis* constant and pass that.",
			where, site.emitter, lit)
	default:
		t.Errorf("%s: %s passes a basis this census cannot resolve (%T) — neither a named constant nor a literal",
			where, site.emitter, call.Args[ba])
	}
}

// hzResBasisKeyed is one census key's basis expectation. `symbol` is the basis
// identifier, and since wave 35 EVERY live row sets it: the two declared
// object-store destroys, the last sites passing a bare string, became constants.
// `literal` is kept as the pin a bare string WOULD get — hzResCaptureBasis now
// reds such a site at capture, and this arm is the second signal, not the
// first. Exactly one is set.
type hzResBasisKeyed struct {
	symbol  string
	literal string
}

// hzResBases is LEG 1: every receipt key that carries a confirmation basis, and
// WHICH basis it carries. Checked BIDIRECTIONALLY, exactly like
// hzResDispositions — a new receipt site with no row here reds BY NAME, and a
// row naming a key nothing emits reds just as hard.
//
// WHY THIS REPAIRS SOMETHING ARM A GAVE UP (pds-w32-census-pin-simplify). Arm A
// deleted the KEYS != 52 and NON_LITERAL != 2 pins as measured-redundant, which
// was right on the evidence — but KEYS was the last arm that noticed a NEW KEY
// appear at all, and nothing replaced that direction. This table restores it as
// a NAMED row: a receipt site that joins the population without declaring what
// read it confirms fails here with its own key in the message, not as a count
// that moved by one.
//
// IT IS A SEPARATE STRUCTURE ON PURPOSE, and the usual reason given for that is
// half wrong. hzResDispositions IS a map keyed on "kind/action"; it is its ROWS
// that are unkeyed positional struct literals ({class, note}), which is why
// adding a third field to hzResDisposition is a compile error on all of them at
// once. The constraint stands; "the rows are unkeyed" is right about the rows
// and wrong about the map.
// THE POPULATION, DERIVED (not transcribed): 38 basis-carrying sites — 6
// explicit constants (4 plus the two declared destroys wave 35 named), 21
// inherited defaults and 11 response-emitter creates, with NO literals left.
// 36 carry a literal (kind, action) key and are pinned below;
// the other 2 are the DISPATCH-SHARED sites (hetzner_net_cmd.go:1115 and :1693),
// whose keys come from their callers and whose every arm inherits the SAME basis
// argument, so there is nothing per-key to pin for them.
var hzResBases = map[string]hzResBasisKeyed{
	// ---- The object-store reads: the three sites whose basis is NOT a GET. ---
	"backup/create": {symbol: "hzResBasisHead"},
	"object/put":    {symbol: "hzResBasisHead"},
	"bucket/create": {symbol: "hzResBasisListScan"},

	// ---- The composite-key read, declared outside the const block. ----------
	"record/update": {symbol: "hzResBasisRRSetKey"},

	// ---- The eleven creates that observe the RESPONSE object. ---------------
	// Every one of these goes through hzResObservedResponse, which takes no
	// basis argument at all — so this column is really pinning WHICH EMITTER
	// each create uses. A create that switched to hzResObserved without paying
	// for a real post-read would arrive here carrying hzResBasisGet.
	"zone/create":                 {symbol: "hzResBasisResponse"},
	"record/create":               {symbol: "hzResBasisResponse"},
	"load-balancer/create":        {symbol: "hzResBasisResponse"},
	"floating-ip/create":          {symbol: "hzResBasisResponse"},
	"primary-ip/create":           {symbol: "hzResBasisResponse"},
	"placement-group/create":      {symbol: "hzResBasisResponse"},
	"certificate/create-uploaded": {symbol: "hzResBasisResponse"},
	"certificate/create-managed":  {symbol: "hzResBasisResponse"},
	"volume/create":               {symbol: "hzResBasisResponse"},
	"network/create":              {symbol: "hzResBasisResponse"},
	"firewall/create":             {symbol: "hzResBasisResponse"},

	// ---- The nineteen keyed sites that INHERIT the GET default. -------------
	// These are the ones nothing spoke for before: the basis is supplied by
	// OMISSION, so no call site names it and no fake drives it. Pinned here so
	// that handing one of them a contradicting explicit basis costs an edit in
	// this table rather than passing green.
	"zone/update":                    {symbol: "hzResBasisGet"},
	"load-balancer/add-service":      {symbol: "hzResBasisGet"},
	"load-balancer/delete-service":   {symbol: "hzResBasisGet"},
	"load-balancer/add-target":       {symbol: "hzResBasisGet"},
	"load-balancer/remove-target":    {symbol: "hzResBasisGet"},
	"load-balancer/change-algorithm": {symbol: "hzResBasisGet"},
	"load-balancer/change-type":      {symbol: "hzResBasisGet"},
	"floating-ip/assign":             {symbol: "hzResBasisGet"},
	"floating-ip/unassign":           {symbol: "hzResBasisGet"},
	"primary-ip/assign":              {symbol: "hzResBasisGet"},
	"primary-ip/unassign":            {symbol: "hzResBasisGet"},
	"volume/attach":                  {symbol: "hzResBasisGet"},
	"volume/detach":                  {symbol: "hzResBasisGet"},
	"volume/resize":                  {symbol: "hzResBasisGet"},
	"volume/change-protection":       {symbol: "hzResBasisGet"},
	"network/add-subnet":             {symbol: "hzResBasisGet"},
	"network/delete-subnet":          {symbol: "hzResBasisGet"},
	"network/change-ip-range":        {symbol: "hzResBasisGet"},
	"firewall/set-rules":             {symbol: "hzResBasisGet"},

	// ---- The two DECLARED destroys, now pinned by SYMBOL like everything ----
	// else. They were the only two rows in this table pinned by WORDING, because
	// they passed bare strings into a mandatory parameter — so leg 1 compared a
	// string to a hand-typed copy of ITSELF and a coordinated reword (call site
	// plus row, one edit each) walked past it. Paid by
	// pds-w34-declared-basis-literals-need-constants: both are constants beside
	// their verbs in hetzner_storage_cmd.go, so the symbol pin is real here and
	// the wording is defended separately by leg 3.
	"bucket/delete": {symbol: "hzResBasisBucketListAfterDelete"},
	"object/rm":     {symbol: "hzResBasisObjectKeyListAfterDelete"},
}

// hzResBasisReads is LEG 2: basis SYMBOL → the token the confirming read's
// source must contain. Keyed on the symbol rather than the wording so that
// rewording a constant cannot quietly move a site onto a different read rule —
// that evasion is leg 3's, and it must not be able to hide here.
//
// HIGH-FLIP-RISK, SO IT IS DERIVED AND NOT REMEMBERED. This table decides which
// read 25 call sites are judged against, and a wrong row reds an HONEST wording
// — at which point somebody deletes the gate. Every row below was read off the
// tree (all 21 inherited sites resolve to `…GetByID(c, x.ID)`; the four explicit
// ones to hzS3HeadRead, hzS3BucketRead and GetRRSetByNameAndType), never
// inferred from the constants' prose.
var hzResBasisReads = map[string][]string{
	// The default. Twenty-one sites, every one an hcloud single-resource GET.
	"hzResBasisGet": {"GetByID("},
	// The object-store pair, both through the S3 read helpers — which is the
	// whole reason these two constants exist.
	"hzResBasisHead":     {"hzS3HeadRead("},
	"hzResBasisListScan": {"hzS3BucketRead("},
	// The composite-key read. NOT a GetByID, which is exactly why record update
	// needed its own constant rather than riding the GET default.
	"hzResBasisRRSetKey": {"GetRRSetByNameAndType("},
	// hzResObservedResponse performs NO post-read; there is no read argument to
	// bind. Its honesty is structural — the emitter cannot name another basis —
	// and is asserted by its own arm below.
	"hzResBasisResponse": nil,
	// The two DECLARED NON-BINDING destroys. Their reads are S3 LISTINGS, not
	// single-resource reads at all, which is why the receipt says "declared":
	// bucket delete scans the collection, object rm lists under the deleted
	// key's own prefix. Bound here like every other constant now that they ARE
	// constants — this is what replaced hzResDeclaredBasisReads, which keyed on
	// the census key because there was no symbol to key on.
	"hzResBasisBucketListAfterDelete":    {"ListBuckets("},
	"hzResBasisObjectKeyListAfterDelete": {"ListObjects("},
}

// hzResDeclaredBasisReads is GONE (wave 35). It was LEG 2 for the two declared
// destroys, keyed on the CENSUS KEY because their basis was a bare literal with
// no symbol to key on. Both are constants now, so they ride hzResBasisReads
// above with everything else — and the exemption that made a key-shaped table
// necessary is closed in hzResCaptureBasis, which now refuses a literal at EVERY
// emitter. Deleting this table before that refusal existed would have left the
// next bare literal silently unjudged; the order was the point.

// hzResBasisSites returns the derived sites that carry a basis at all.
func hzResBasisSites(t *testing.T) []hzResSite {
	t.Helper()
	var out []hzResSite
	for _, s := range hzResSitesFromSource(t) {
		if s.basisForm != hzBasisNone {
			out = append(out, s)
		}
	}
	return out
}

// hzResSiteKey is the (kind, action) key a site emits, or "" when its action is
// not a literal (the dispatch-shared sites).
func hzResSiteKey(s hzResSite) string {
	if s.kind == "" || s.action == "" {
		return ""
	}
	return s.kind + "/" + s.action
}

// TestHetznerResourceBasisIsBoundPerKey is LEG 1's gate.
func TestHetznerResourceBasisIsBoundPerKey(t *testing.T) {
	sites := hzResBasisSites(t)

	byForm := map[hzBasisForm]int{}
	for _, s := range sites {
		byForm[s.basisForm]++
	}
	t.Logf("BASIS SITES=%d  const=%d inherited=%d response=%d literal=%d",
		len(sites), byForm[hzBasisConst], byForm[hzBasisInherited], byForm[hzBasisResponse], byForm[hzBasisLiteral])

	live := map[string]hzResSite{}
	for _, s := range sites {
		key := hzResSiteKey(s)
		if key == "" {
			// A dispatch-shared site: its keys come from its callers, and every
			// arm of it inherits the SAME basis argument, so there is nothing
			// per-key to pin here. The enrolment gate above owns those keys.
			continue
		}
		live[key] = s
		want, pinned := hzResBases[key]
		if !pinned {
			t.Errorf("RATCHET/BASIS-UNPINNED: %q emits a receipt at %s:%d that prints confirmation_basis %q, but "+
				"hzResBases carries NO row for it. A receipt that names a read while nothing records WHICH read it "+
				"is supposed to name is back where this epic started. Add a row.",
				key, s.file, s.line, s.basisText)
			continue
		}
		switch {
		case s.basisForm == hzBasisLiteral:
			if want.literal != s.basisText {
				t.Errorf("%q passes the declared basis %q at %s:%d, but hzResBases pins %q — a declared destroy "+
					"changed what listing it says it scanned", key, s.basisText, s.file, s.line, want.literal)
			}
		default:
			if want.symbol != s.basisIdent {
				t.Errorf("%q is emitted at %s:%d with basis %s, but hzResBases pins %s. THIS IS THE CALL-SITE "+
					"MUTATION: a verb that swaps the read it CLAIMS while performing the same read as before "+
					"prints a receipt an operator cannot tell from an honest one.",
					key, s.file, s.line, s.basisIdent, want.symbol)
			}
		}
	}

	for key := range hzResBases {
		if _, ok := live[key]; !ok {
			t.Errorf("hzResBases pins a basis for %q, which emits no basis-carrying receipt in %v — a stale row "+
				"makes this ledger look like it speaks for more of the surface than it does", key, hzResSourceFiles(t))
		}
	}
}

// TestHetznerResourceBasisMayNotClaimTheResponseWithoutBeingTheResponseEmitter
// closes the WIDENED-HELPER HOLE. hzResClassHelpers licenses BOTH
// hzResObservedResponse and hzResObserved for hzClassCreate, and it binds
// SYMBOLS, never BASES — so a create could take the stronger helper (which
// really does re-read) and hand it any basis at all, including the create
// response basis, which names a read hzResObserved by construction does not
// perform. hzResObserved re-reads; "the create response object" says it did not.
func TestHetznerResourceBasisMayNotClaimTheResponseWithoutBeingTheResponseEmitter(t *testing.T) {
	checked := 0
	for _, s := range hzResBasisSites(t) {
		if s.emitter == "hzResObservedResponse" {
			continue
		}
		checked++
		if s.basisIdent == "hzResBasisResponse" || s.basisText == hzResBasisResponse {
			t.Errorf("%s:%d calls %s — which PERFORMS a confirming read — while claiming the basis %q. That is a "+
				"receipt naming a read it did not do, in the direction that flatters it: the response object is "+
				"what a create was HANDED, not what the world said afterwards. Either drop to "+
				"hzResObservedResponse or name the read this site actually performs (%s).",
				s.file, s.line, s.emitter, s.basisText, s.readText)
		}
	}
	if checked == 0 {
		t.Fatal("no reading emitters were examined — this arm is measuring nothing")
	}
	t.Logf("READING SITES CHECKED=%d", checked)
}

// TestHetznerResourceBasisResponseEmitterHardcodesItsBasis is the structural
// half of the same rule, from the other end: hzResObservedResponse takes no
// basis argument, so its honesty cannot be checked at a call site. It is checked
// at the DECLARATION — the function must name hzResBasisResponse and nothing
// else. Widening it to accept a basis (exactly how hzResObserved got one) reds
// here rather than silently opening the surface.
func TestHetznerResourceBasisResponseEmitterHardcodesItsBasis(t *testing.T) {
	_, files := hzResParseSources(t)
	found := false
	for path, file := range files {
		for _, d := range file.Decls {
			decl, ok := d.(*ast.FuncDecl)
			if !ok || decl.Name.Name != "hzResObservedResponse" || decl.Body == nil {
				continue
			}
			found = true
			if _, takes := hzResBasisArgs["hzResObservedResponse"]; takes {
				t.Errorf("%s: hzResObservedResponse now carries a basis argument slot — it must be censused "+
					"positionally like the others, not asserted structurally here", path)
			}
			var named []string
			ast.Inspect(decl.Body, func(n ast.Node) bool {
				if id, ok := n.(*ast.Ident); ok && strings.HasPrefix(id.Name, "hzResBasis") {
					named = append(named, id.Name)
				}
				return true
			})
			if len(named) != 1 || named[0] != "hzResBasisResponse" {
				t.Errorf("%s: hzResObservedResponse names %v as its basis. It performs no read at all, so exactly "+
					"one basis is truthful there — hzResBasisResponse. Anything else is this emitter claiming a "+
					"round trip it does not make.", path, named)
			}
		}
	}
	if !found {
		t.Fatal("hzResObservedResponse was not found in the scanned sources — this arm is measuring nothing")
	}
}

// TestHetznerResourceBasisMatchesTheReadTheSitePerforms is LEG 2, and it is what
// turns "the receipt names a read" into "the receipt names THE read".
//
// WHAT IT CAN AND CANNOT SEE, stated so nobody over-reads a green. It matches
// the SOURCE TEXT of the confirming-read argument against a token the basis
// requires. That proves the site CALLS the primitive its basis names. It does
// NOT prove the primitive was called on the right resource, and it cannot: which
// id an argument carries is not knowable from a token match. This binds a claim
// to a CALL, not a claim to a round trip.
func TestHetznerResourceBasisMatchesTheReadTheSitePerforms(t *testing.T) {
	sites := hzResBasisSites(t)
	judged := 0
	for _, s := range sites {
		var want []string
		var rule string
		switch {
		case s.basisForm == hzBasisResponse:
			continue // no read exists to bind
		case s.basisForm == hzBasisLiteral:
			// A literal has no symbol, so nothing here can bind it to a read.
			// hzResCaptureBasis already reds it BY NAME at capture, at every
			// emitter — this arm would only repeat that in a shape that reads
			// like a second, independent finding.
			continue
		default:
			w, ok := hzResBasisReads[s.basisIdent]
			if !ok {
				t.Errorf("RATCHET/BASIS-READ-UNBOUND: %s:%d claims basis %s, which no row in hzResBasisReads binds "+
					"to a read. A basis constant nothing binds is a sentence again.", s.file, s.line, s.basisIdent)
				continue
			}
			want, rule = w, fmt.Sprintf("basis %s", s.basisIdent)
		}
		if len(want) == 0 {
			continue
		}
		if strings.TrimSpace(s.readText) == "" {
			t.Errorf("%s:%d claims %s but this census could not read its confirming-read argument — an unreadable "+
				"read cannot be judged, and an unjudged read is what this arm exists to stop", s.file, s.line, rule)
			continue
		}
		judged++
		for _, tok := range want {
			if !strings.Contains(s.readText, tok) {
				t.Errorf("%s:%d prints confirmation_basis %q (%s) but its confirming read is `%s`, which never "+
					"calls %s. THE RECEIPT NAMES A READ THE CODE DOES NOT PERFORM — this epic's law, at a call "+
					"site, in the shape an operator would believe.", s.file, s.line, s.basisText, rule, s.readText, tok)
			}
		}
	}
	// A vacuity floor. The whole arm passes by looking at nothing if the read
	// slots stop resolving, and a silent zero is how this family failed before.
	const judgedFloor = 20
	if judged < judgedFloor {
		t.Fatalf("only %d sites were judged against their read (floor %d) — the scan lost the read argument, so "+
			"this green means nothing. 27 were judged when it was written (25 hzResObserved plus the 2 declared "+
			"destroys; the response emitter performs no read).", judged, judgedFloor)
	}
	t.Logf("READ-BOUND SITES=%d of %d basis-carrying sites", judged, len(sites))

	consts := hzResBasisConstants(t)
	for sym := range hzResBasisReads {
		if _, ok := consts[sym]; !ok {
			t.Errorf("hzResBasisReads binds %s to a read, but no such basis constant exists in %v — a stale "+
				"binding row makes the table look like it covers a constant that is gone", sym, hzResSourceFiles(t))
		}
	}
}

// TestHetznerResourceBasisEveryConstantIsBoundToARead is the OTHER direction of
// leg 2, and it is what stops an EIGHTH constant riding in unjudged: every basis
// constant DERIVED from the sources must carry a read binding. Derivation is the
// point — a hand list defends only what somebody remembered, and
// hzResBasisRRSetKey already proved a constant can be declared anywhere.
func TestHetznerResourceBasisEveryConstantIsBoundToARead(t *testing.T) {
	consts := hzResBasisConstants(t)
	names := make([]string, 0, len(consts))
	for name := range consts {
		names = append(names, name)
	}
	sort.Strings(names)
	t.Logf("BASIS CONSTANTS DERIVED=%d %v", len(names), names)

	for _, name := range names {
		if _, bound := hzResBasisReads[name]; !bound {
			t.Errorf("RATCHET/BASIS-CONSTANT-UNJUDGED: the basis constant %s = %q exists in the scanned sources "+
				"but no row in hzResBasisReads says which read it names. It will print on a receipt while nothing "+
				"in this package can tell whether that read happened. Add a row (nil if the emitter performs no "+
				"read at all, as hzResObservedResponse does).", name, consts[name])
		}
	}
}
