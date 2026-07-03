package cloud

import (
	"context"
	"fmt"
	"os"
)

// warmNameSuffixHex is the length of the crypto/rand hex suffix in a warm-pool box
// name: warm-<8 hex> = 32 bits. UNIQUE by construction — NEVER a fixed name. The
// old fixed "warm-1" collided when a second job re-created it and leaked the
// refill; a random suffix is the fix.
const warmNameSuffixHex = 8

// warmServerName mints a unique warm-pool box name: warm-<crypto rand>.
func warmServerName() string { return "warm-" + randHex(warmNameSuffixHex) }

// CreateWarmServer creates ONE pre-baked pool box: a unique warm-<rand> name via
// the resilience ladder (so a sold-out preferred type still lands a box), then
// stamps barkpark-warm=true so the pool is identifiable. FAIL CLOSED on a label
// failure: a warm box that can't be marked warm is untracked spend the reconciler
// can't see, so the just-created box is torn down rather than leaked. Returns the
// created Server (its Labels carry barkpark-warm + barkpark-managed).
func CreateWarmServer(ctx context.Context, provider CloudProvider, base ServerSpec) (Server, error) {
	spec := base
	spec.Name = warmServerName()

	host, _, err := CreateWithFallback(ctx, provider, spec)
	if err != nil {
		return Server{}, fmt.Errorf("create warm server %q: %w", spec.Name, err)
	}

	labeler, ok := provider.(ServerLabeler)
	if !ok {
		warmDeleteBestEffort(provider, host.Name)
		return Server{}, fmt.Errorf(
			"create warm server %q: provider cannot label — refusing to leak an unidentifiable warm box",
			spec.Name,
		)
	}
	if lerr := labeler.LabelServer(ctx, host.Name, WarmLabelKey, warmLabelVal); lerr != nil {
		warmDeleteBestEffort(provider, host.Name)
		return Server{}, fmt.Errorf("create warm server %q: label %s: %w", spec.Name, WarmLabelKey, lerr)
	}

	if host.Labels == nil {
		host.Labels = map[string]string{}
	}
	host.Labels[WarmLabelKey] = warmLabelVal
	host.Labels[ManagedLabelKey] = managedLabelVal
	return host, nil
}

// warmDeleteBestEffort tears down a just-created warm box that could not be labelled,
// on a FRESH bounded context so it completes even if the create ctx is cancelled. A
// failure is logged (a leaked box must be observable) but never blocks the caller.
func warmDeleteBestEffort(provider CloudProvider, name string) {
	dctx, cancel := context.WithTimeout(context.Background(), cleanupTimeout)
	defer cancel()
	if err := provider.Delete(dctx, name); err != nil {
		fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: leaked unlabelable warm box %s (delete failed): %v\n", name, err)
	}
}

// AssignWarm turns an ALREADY-CLAIMED warm host into a live instance WITHOUT
// creating a server — the ≤15s go-live path. The DB claim already made the box
// un-claimable; this configures it. Ordered label transition so a box is never
// simultaneously advertised-as-warm and assigned:
//
//  1. stamp barkpark-fqdn — the box's stable IDENTITY, money-safety parity with
//     one-shot (a later Remove resolves the box by this label, never the IP, which
//     Hetzner recycles). HARD requirement: an unlabelable box can't be safely
//     removed later, so fail closed and tear it down.
//  2. remove barkpark-warm — best-effort; the box is now a real instance, not a
//     pool box. Done AFTER (1) so the box always carries an identity label before it
//     loses its pool label — there is never an instant with neither.
//  3. configureHost — the shared secrets→dns→caddy→secrets-install→migrate→
//     admin-token→health→register chain, with the create step skipped.
//
// On ANY failure the box + DNS are torn down (cleanupHost) and the error returned,
// so the caller falls back to one-shot create — never a dead-end launch. The
// caller owns dropping the warm_servers claim row (the box is consumed either way).
func (wp *WarmPool) AssignWarm(ctx context.Context, host Server, spec GoLiveSpec) (LiveServer, error) {
	wp.withDefaults()
	if wp.Provider == nil {
		return LiveServer{}, fmt.Errorf("assign: a CloudProvider must be set")
	}

	// 1. identity label — fail closed exactly like ProvisionOneShot's create path.
	if err := wp.labelFQDN(ctx, host.Name, spec.fqdn()); err != nil {
		if cerr := wp.cleanupHost(host, spec); cerr != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: %v\n", cerr)
		}
		return LiveServer{}, fmt.Errorf("assign: label fqdn %q: %w", spec.fqdn(), err)
	}

	// 2. drop the pool label (best-effort — the DB claim, not the label, is the
	// pool's source of truth, so a remove failure is cosmetic, not correctness).
	if remover, ok := wp.Provider.(ServerLabelRemover); ok {
		if err := remover.RemoveLabel(ctx, host.Name, WarmLabelKey); err != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: assign %s: remove %s label: %v\n", host.Name, WarmLabelKey, err)
		}
	}

	// 3. shared go-live chain (create skipped — the box is already booted).
	live, err := wp.configureHost(ctx, host, spec)
	if err != nil {
		if cerr := wp.cleanupHost(host, spec); cerr != nil {
			fmt.Fprintf(os.Stderr, "barkpark-provisioner: WARNING: %v\n", cerr)
		}
		return LiveServer{}, err
	}
	return live, nil
}
