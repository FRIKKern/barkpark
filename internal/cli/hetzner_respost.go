package cli

// hetzner_respost.go — THE DESTROY POST-CONDITION APPARATUS for every non-server
// Hetzner resource.
//
// THE LAW (PDS, unchanged since wave 22): NO BARKPARK VERB MAY REPORT SUCCESS ON
// AN EXIT CODE ALONE. Before this file, `bp cloud hetzner volume delete data-1`
// printed a ✓ because the DELETE call did not return an error — a claim built on
// the transport, not on the world. A destroy is the one receipt in this CLI
// whose lie destroys something, so it is the one that must re-read.
//
// WHY THIS IS A SIBLING OF hzReadBack AND NOT A WIDENING OF IT
// ------------------------------------------------------------
// hzReadBack (hetzner_cmd.go) is the SERVER surface's post-read. Two things stop
// it being reused here:
//
//	1. TYPE. Every hzPost field is typed on *hcloud.Server and hzReadBack hard-
//	   calls hc.Server.GetByID. There are eight more resource kinds.
//	2. POLARITY. hzReadBack's nil branch is INVERTED for a destroy: it treats a
//	   vanished resource as "no longer readable" — an ERROR, reported as
//	   "confirmation unavailable". For a destroy, vanished IS the success
//	   condition. Widening hzReadBack would mean a single function whose nil
//	   branch means opposite things depending on the caller, which is exactly the
//	   ambiguity this epic exists to remove.
//
// The GRAMMAR does transfer, and is kept verbatim: observe / unmet /
// unreadable / partial, plus PDS-D366's law that THE OBSERVATION IS ARGUMENT-
// FREE — nothing in a receipt here is copied from what the user typed.
// hzResolve[T] (hetzner_net_cmd.go) is the existence proof that generics over
// hcloud resources compile in this package; this file copies its shape.
//
// PDS-D400 — THE GONE-CHECK BINDS TO THE RESOLVED NUMERIC ID, NEVER THE TOKEN
// -------------------------------------------------------------------------
// The obvious implementation — "re-run the resolve the verb already ran, and
// expect it to fail" — is UNSOUND, and was proven so by construction:
// hzResolve delegates to the SDK's getByIDOrName, which on a numeric token that
// 404s FALLS THROUGH to a name-filtered LIST. So deleting volume id 42 while a
// DIFFERENT volume is NAMED "42" makes the re-resolve return the impostor, and
// the receipt refuses a delete that was entirely correct. Every call site
// therefore hands hzResDestroyed a closure over the id it ALREADY RESOLVED
// (vol.ID, not the user's argv), so the confirming read cannot see a second
// resource at all. TestHetznerVolumeDeleteImpostorNameDoesNotRefuse pins it.
//
// THE THREE-WAY PREDICATE, AND WHY NOT TWO
// ----------------------------------------
//
//	(nil, nil)  the API says the resource is not there → the claim is EARNED.
//	non-nil     the API still returns it → REFUSE the claim, exit non-zero. The
//	            DELETE was accepted and the resource survived; a ✓ here is the
//	            lie the epic is about.
//	error       the confirming read could not be made → "not confirmed", exit 0.
//	            The destroy was accepted by the API; only the confirmation
//	            failed. Reporting a FAILED verb here would be the same lie
//	            pointing the other way, and would push an operator into deleting
//	            something twice.
//
// PDS-D401 — THE VACUITY TRAP THE TESTS MUST DODGE
// ------------------------------------------------
// http.ServeMux's default 404 is text/plain. hcloud-go's errorFromBody returns
// nil unless hasJSONBody(), so an UNREGISTERED read-back path yields a TRANSPORT
// error, which lands in the "not confirmed" arm — while PRODUCTION returns a
// JSON 404 and lands in the clean (nil, resp, nil) "gone" arm. A test that
// simply omits the GET fixture therefore proves the wrong arm and reads green.
// Every proof in hetzner_respost_test.go registers an explicit JSON 404 or a
// STATEFUL handler, and every destroy kind additionally gets a LYING-FAKE case
// whose GET keeps returning the resource after the DELETE.

import (
	"context"
	"fmt"
	"sort"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// Receipt keys. Named so a script can key on the confirmation without parsing
// prose, and so the census and the success-claim rows have one spelling to
// traverse.
const (
	hzKeyConfirmedGone  = "confirmed_gone"
	hzKeyConfirmedAbs   = "confirmed_absent"
	hzKeyConfirmation   = "confirmation"
	hzKeyConfirmErr     = "confirmation_error"
	hzKeyConfirmBasis   = "confirmation_basis"
	hzConfirmUnavail    = "unavailable"
	hzNotConfirmedPhras = "not confirmed"
)

// hzResGoneRead is one destroy's confirming read: ARGUMENT-FREE at the seam
// (it takes only a context), because everything it needs — the resolved id, the
// (zone,name,type) key — is captured by the call site at the moment it was
// resolved. The SDK's own (value, *Response, error) triple rides through
// unchanged so the (nil, nil) miss stays distinguishable from a transport error.
type hzResGoneRead[T any] func(context.Context) (*T, *hcloud.Response, error)

// hzResDestroyed is THE destroy receipt: it re-reads, and then either says the
// resource is gone or refuses the claim. It is the only way a full destroy in
// this package reports success.
//
// It is generic over the hcloud resource type for one reason: so the three-way
// predicate is written ONCE. A per-kind copy is how nine call sites end up with
// eight-and-a-half behaviours.
func hzResDestroyed[T any](out *writer, ctx context.Context, action, kind string, id any, name string, extra map[string]any, read hzResGoneRead[T]) int {
	fresh, _, err := read(ctx)
	switch {
	case err != nil:
		// The destroy was accepted; only the confirmation failed. Never a
		// failed verb — see the block comment.
		return hzResUnconfirmed(out, action, kind, id, name, hzMergeExtra(extra, map[string]any{
			hzKeyConfirmErr: err.Error(),
		}), fmt.Sprintf("the %s was accepted but the confirming read failed, so removal is %s: %v",
			action, hzNotConfirmedPhras, err))
	case fresh != nil:
		return hzResStillThere(out, action, kind, id, name)
	default:
		return hzResDone(out, action, kind, id, name, hzMergeExtra(extra, map[string]any{
			hzKeyConfirmedGone: true,
		}))
	}
}

// hzResStillThere REFUSES a destroy claim: the API accepted the delete and then
// handed the resource straight back. Non-zero exit, because a script that
// deleted something and moved on is now wrong about the world.
func hzResStillThere(out *writer, action, kind string, id any, name string) int {
	return useError(out, "failed", fmt.Sprintf(
		"%s %s %s: the API accepted the %s but %s id %v is STILL READABLE — the resource was NOT destroyed, "+
			"so this verb refuses to claim it was (re-read it with `bp cloud hetzner %s list`)",
		action, kind, name, action, kind, id, kind), exitGeneric)
}

// hzResUnconfirmed reports a destroy whose confirming read could not be made:
// the verb did everything it promises, the API accepted it, and nobody can
// currently see whether it took. It is deliberately NOT a ✓ — the receipt says
// what was sent and what could not be observed — and it exits 0, because a
// failed READ is not a failed DELETE.
func hzResUnconfirmed(out *writer, action, kind string, id any, name string, extra map[string]any, note string) int {
	payload := map[string]any{
		"ok":                  true,
		"action":              action,
		"complete":            false,
		hzKeyConfirmedGone:    false,
		hzKeyConfirmation:     hzConfirmUnavail,
		"note":                note,
		hzResPayloadKey(kind): map[string]any{"id": id, "name": name},
	}
	for k, v := range extra {
		payload[k] = v
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("⚠ %s — %s %s (id %v): %s", action, kind, name, id, note)
	hzResPrintExtra(out, extra)
	return exitOK
}

// hzResDestroyedDeclared is the OBJECT-STORAGE half of the apparatus, and it is
// deliberately weaker.
//
// Hetzner's S3-compatible object storage documents NO consistency model, so a
// list-after-delete that still shows the key is not proof the delete failed —
// it may be a replica that has not caught up. Refusing the claim on that basis
// would manufacture false reds on correct deletes. So this read is DECLARED
// NON-BINDING: it always reports what it saw (`confirmed_absent: true|false`)
// together with the BASIS of that reading, and a still-present object produces
// an honest ⚠ partial — never a ✓, never a hard failure. That is still a strict
// improvement on the exit code alone, because the receipt now carries a fact
// somebody can check.
//
// absent() reports (gone, err). A read that errors fails CLOSED: it reports
// confirmed_absent=false with the error as the reason, never an optimistic true.
func hzResDestroyedDeclared(out *writer, action, kind string, id any, name string, extra map[string]any, basis string, absent func() (bool, error)) int {
	gone, err := absent()
	switch {
	case err != nil:
		return hzResUnconfirmedAbsent(out, action, kind, id, name, extra, basis,
			fmt.Sprintf("the %s was accepted but the confirming read failed, so absence is %s: %v",
				action, hzNotConfirmedPhras, err))
	case !gone:
		return hzResUnconfirmedAbsent(out, action, kind, id, name, extra, basis,
			fmt.Sprintf("the %s was accepted but %s %s is STILL LISTED afterwards — absence is %s "+
				"(this endpoint documents no consistency model, so this is reported, not treated as a failure)",
				action, kind, name, hzNotConfirmedPhras))
	default:
		return hzResDone(out, action, kind, id, name, hzMergeExtra(extra, map[string]any{
			hzKeyConfirmedAbs:  true,
			hzKeyConfirmBasis:  basis,
			hzKeyConfirmedGone: true,
			hzKeyConfirmation:  "declared",
		}))
	}
}

// hzResUnconfirmedAbsent is hzResUnconfirmed's object-storage twin: same honest
// partial, with the basis of the reading named so the reader can weigh it.
func hzResUnconfirmedAbsent(out *writer, action, kind string, id any, name string, extra map[string]any, basis, note string) int {
	payload := map[string]any{
		"ok":                  true,
		"action":              action,
		"complete":            false,
		hzKeyConfirmedAbs:     false,
		hzKeyConfirmedGone:    false,
		hzKeyConfirmation:     hzConfirmUnavail,
		hzKeyConfirmBasis:     basis,
		"note":                note,
		hzResPayloadKey(kind): map[string]any{"id": id, "name": name},
	}
	for k, v := range extra {
		payload[k] = v
	}
	if out.emitStructured(payload) {
		return exitOK
	}
	out.outf("⚠ %s — %s %s (id %v): %s", action, kind, name, id, note)
	hzResPrintExtra(out, extra)
	return exitOK
}

// hzResPayloadKey is hzResDone's payload-key rule, shared so the partial shapes
// key their resource exactly as the ✓ shape does.
func hzResPayloadKey(kind string) string {
	k := make([]byte, 0, len(kind))
	for i := 0; i < len(kind); i++ {
		if kind[i] == '-' {
			k = append(k, '_')
			continue
		}
		k = append(k, kind[i])
	}
	return string(k)
}

// hzResPrintExtra renders the table view's sorted extra lines — hzDone's tail,
// shared rather than re-typed.
func hzResPrintExtra(out *writer, extra map[string]any) {
	keys := make([]string, 0, len(extra))
	for k := range extra {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out.outf("  %s: %s", k, cellString(extra[k]))
	}
}
