// Package azure is the Azure Resource Manager (ARM) implementation of the cloud
// provisioning seam (internal/cli/cloud.CloudProvider). It is deliberately
// self-contained: it depends only on the EXISTING cloud interfaces + label keys
// as they stand on main, plus the azure-sdk-for-go Track-2 modules. No registry,
// no new capability interfaces — wiring AzureProvider into the seam registry and
// the neutral CLI verbs is a later slice.
//
// The whole package is built to be tested with ZERO live Azure calls: every ARM
// client (and the credential's own token exchange) runs through an injectable
// azcore transport (policy.Transporter), which the test suite replaces with a
// fixture-replaying fake. Nothing here reaches the network in `go test`.
package azure

import (
	"fmt"
	"os"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
)

// Env var names for the service-principal 4-tuple. They are the SAME names the
// Azure CLI and the SDK's DefaultAzureCredential read, so an operator already
// authenticated for `az` needs no new setup.
const (
	EnvTenantID       = "AZURE_TENANT_ID"
	EnvClientID       = "AZURE_CLIENT_ID"
	EnvClientSecret   = "AZURE_CLIENT_SECRET"
	EnvSubscriptionID = "AZURE_SUBSCRIPTION_ID"
)

// Credentials is the service-principal client-credentials 4-tuple ARM needs. The
// first three authenticate (tenant + app registration + secret); SubscriptionID
// scopes every resource path. All four are required — a partial tuple can never
// provision, so we fail early with a clear message rather than a cryptic 401/404
// deep in a create.
type Credentials struct {
	TenantID       string
	ClientID       string
	ClientSecret   string
	SubscriptionID string
}

// Complete reports whether all four fields are non-empty — the presence check
// HasAuth answers. It is intentionally a pure field check (like Hetzner's
// env/context presence gate), not a live API call.
func (c Credentials) Complete() bool {
	return c.TenantID != "" && c.ClientID != "" && c.ClientSecret != "" && c.SubscriptionID != ""
}

// Validate returns a clear, actionable error naming EVERY missing field (not
// just the first), so an operator fixes the whole tuple in one pass instead of
// discovering the gaps one 401 at a time.
func (c Credentials) Validate() error {
	var missing []string
	if c.TenantID == "" {
		missing = append(missing, EnvTenantID)
	}
	if c.ClientID == "" {
		missing = append(missing, EnvClientID)
	}
	if c.ClientSecret == "" {
		missing = append(missing, EnvClientSecret)
	}
	if c.SubscriptionID == "" {
		missing = append(missing, EnvSubscriptionID)
	}
	if len(missing) > 0 {
		return fmt.Errorf("azure: incomplete service-principal credentials — missing %s (set them, pass a creds map, or configure the provider)", strings.Join(missing, ", "))
	}
	return nil
}

// ResolveCredentials resolves the 4-tuple with flag > env > stored precedence,
// mirroring hetzner.ResolveToken's ladder. `stored` is the credential blob the
// control plane hands the worker (nil when none); per-field env fills any gap it
// leaves; a non-empty value in `flags` outranks both. The resulting tuple is NOT
// verified live here — that is the control plane's verify-before-save preflight —
// but it IS checked for completeness so a missing field surfaces immediately with
// a clear error rather than as a 401 mid-provision.
//
// Passing nil for both maps resolves purely from the environment, which is how a
// bare `bp cloud azure …` escape-hatch invocation authenticates.
func ResolveCredentials(flags, stored map[string]string) (Credentials, error) {
	pick := func(flagKey, envKey string) string {
		if flags != nil {
			if v := strings.TrimSpace(flags[flagKey]); v != "" {
				return v
			}
		}
		if v := strings.TrimSpace(os.Getenv(envKey)); v != "" {
			return v
		}
		if stored != nil {
			if v := strings.TrimSpace(stored[flagKey]); v != "" {
				return v
			}
		}
		return ""
	}
	c := Credentials{
		TenantID:       pick("tenant_id", EnvTenantID),
		ClientID:       pick("client_id", EnvClientID),
		ClientSecret:   pick("client_secret", EnvClientSecret),
		SubscriptionID: pick("subscription_id", EnvSubscriptionID),
	}
	if err := c.Validate(); err != nil {
		return Credentials{}, err
	}
	return c, nil
}

// newClientSecretCredential builds the real azidentity.ClientSecretCredential
// from a complete tuple, routing its token exchange through `transport` when one
// is injected (nil => the SDK's default HTTPS transport). Instance discovery is
// disabled: it saves a network round-trip and, crucially, keeps the offline
// fixture surface small (the fake need only answer tenant discovery + the token
// POST, never the global instance-metadata endpoint).
//
// The caller guarantees creds.Complete(); azidentity still rejects a malformed
// tenant id, and that error is returned verbatim.
func newClientSecretCredential(creds Credentials, transport policy.Transporter) (*azidentity.ClientSecretCredential, error) {
	opts := &azidentity.ClientSecretCredentialOptions{
		DisableInstanceDiscovery: true,
	}
	if transport != nil {
		opts.ClientOptions.Transport = transport
	}
	cred, err := azidentity.NewClientSecretCredential(creds.TenantID, creds.ClientID, creds.ClientSecret, opts)
	if err != nil {
		return nil, fmt.Errorf("azure: build client-secret credential: %w", err)
	}
	return cred, nil
}
