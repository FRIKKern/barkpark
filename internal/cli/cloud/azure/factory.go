package azure

// factory.go is the seam-wiring half of the azure provider (charter Decision 3 +
// 5). It self-registers AzureProvider into the cloud registry via this package's
// init(), so linking the azure package into a binary (the `bp` CLI does) makes
// `cloud.ProviderFor("azure", creds)` resolve without the cloud package ever
// importing azure back (which would be an import cycle — azure imports cloud to
// implement the seam). It also promotes the provider's power actions to the
// exported cloud.Pauser interface so the capability is honestly discoverable.

import (
	"context"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// init self-registers the azure factory. It runs whenever this package is linked
// into a binary; the cloud package's own test binary does NOT link azure, so
// azure stays unregistered there (no import cycle, no forced Azure SDK in a
// build that never touches Azure).
func init() {
	cloud.Register(cloud.ProviderAzure, Factory)
}

// Factory builds an AzureProvider from the per-provider credential blob the
// control plane stores (keys tenant_id/client_id/client_secret/subscription_id),
// falling back to the AZURE_* environment for any field the blob leaves empty.
// It is the cloud.ProviderFactory the registry calls from ProviderFor.
//
// Credential resolution uses ResolveCredentials(nil, creds): the stored blob is
// the base, env fills gaps. New does NOT hard-fail on an incomplete tuple, but
// ResolveCredentials validates completeness first, so a half-configured provider
// surfaces a clear "missing AZURE_…" error at resolve time rather than a cryptic
// 401 mid-provision. Construction makes NO live Azure call — the credential's
// token exchange is lazy — so building a provider (e.g. for the capability
// matrix) never reaches the network.
func Factory(creds map[string]string) (cloud.CloudProvider, error) {
	resolved, err := ResolveCredentials(nil, creds)
	if err != nil {
		return nil, err
	}
	return New(resolved)
}

// Pause satisfies cloud.Pauser by deallocating the VM (stops compute billing
// without deleting the box) — the Azure analogue of Hetzner poweroff. It wraps
// the LRO Deallocate under the neutral name the seam's Pauser interface uses, so
// providers_capabilities.json can honestly claim pause for azure and the parity
// test agrees.
func (p *AzureProvider) Pause(ctx context.Context, name string) error {
	return p.Deallocate(ctx, name)
}

// Resume satisfies cloud.Pauser by starting a deallocated VM back up.
func (p *AzureProvider) Resume(ctx context.Context, name string) error {
	return p.Start(ctx, name)
}

// compile-time assertion: AzureProvider satisfies the exported Pauser capability
// (via the Pause/Resume wrappers above), matching the fixture's pause=true claim.
var _ cloud.Pauser = (*AzureProvider)(nil)
