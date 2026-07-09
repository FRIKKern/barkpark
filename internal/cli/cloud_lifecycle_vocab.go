package cli

import "github.com/FRIKKern/barkpark/internal/cloudclient"

// cloud_lifecycle_vocab.go — the REGISTRY leg of the neutral lifecycle vocabulary
// (Decision 34). It folds a control-plane Barkpark's status axes onto ONE of the
// seven S4 GenInstanceLifecycle keys so the fleet table (renderCloudBarkparksTable
// → renderHzTable's STATUS column) and the Cloud SPA fold identical inputs to the
// same state — one vocabulary, both surfaces.
//
// This is a faithful Go port of the SPA's lifecyclePillState (app.js:674-682)
// over instanceLifecycle (app.js:2375-2383): the same boolean ladder, the same
// precedence, the same "" fall-through for a state we cannot place. It touches
// the REGISTRY only — NOT the provider seam (a bare registry read has no
// CloudProvider) and NEVER attentionStatus, which is a different 8-label triage
// vocabulary pinned by its own fixtures (D32). host is the "up" signal, not url
// (url is stamped at launch, before the box answers).

// registryLifecycleToken returns the GenInstanceLifecycle key for a fleet row, or
// "" when the row's state is unplaceable (→ lifecycleTint degrades to no paint,
// and the STATUS cell renders blank). Precedence matches the SPA exactly:
// removing > errored > suspended > provisioning > live.
func registryLifecycleToken(b cloudclient.Barkpark) string {
	// instanceLifecycle's boolean ladder (app.js:2375-2383), verbatim in order so
	// the folds stay identical: an in-flight teardown wins, then the error/paused
	// folds, then provisioning (no host yet), then live.
	removing := b.DeprovisionStatus == "pending" || b.DeprovisionStatus == "claimed"
	removeFailed := b.DeprovisionStatus == "failed"
	failed := !removing && !removeFailed && b.Host == "" && b.ProvisionStatus == "failed"
	provisioning := !removing && !removeFailed && b.Host == "" && !failed
	suspended := !removing && !removeFailed && !failed && b.Suspended
	live := !removing && !removeFailed && !failed && !provisioning && !suspended && b.Host != ""

	// lifecyclePillState's fold (app.js:674-682): removing wins first, then the
	// error/paused folds, then provisioning, then live; "" otherwise.
	switch {
	case removing:
		return "decommissioned"
	case failed || removeFailed:
		return "degraded"
	case suspended:
		return "stopped"
	case provisioning:
		return "provisioning"
	case live:
		return "live"
	default:
		return ""
	}
}
