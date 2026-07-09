package provisioner

import (
	"context"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// azureCreds is a complete-looking 4-tuple; the fake factory ignores it, but it
// mirrors the shape the control plane hands the worker so the routing test reads
// like the real crossing.
func azureCreds() map[string]string {
	return map[string]string{
		"tenant_id":       "t-1",
		"client_id":       "c-1",
		"client_secret":   "s-1",
		"subscription_id": "sub-1",
	}
}

// TestProvisionWith_AzureRoutesThroughRegistry_PoolSizeZero proves the S6 routing
// contract WITHOUT depending on S5's real azure factory: a job with Kind "azure"
// is provisioned through cloud.ProviderFor (a fake registered under the azure slug
// here), NOT through seams.Provider (the Hetzner fake), and the warm pool is forced
// OFF even though the seams carry a pool + a ready warm box. The proof is threefold:
// the box lands on the azure provider, the Hetzner provider is untouched, and the
// seeded warm row is never claimed.
func TestProvisionWith_AzureRoutesThroughRegistry_PoolSizeZero(t *testing.T) {
	seams, hetznerProv, _, _ := fakeSeams(t)
	ctx := context.Background()

	// A distinct fake stands in for the (unregistered until S5) azure provider, so
	// we can prove the box was created THROUGH the registry, not on seams.Provider.
	azureProv := cloud.NewFakeProvider()
	cloud.Register(cloud.ProviderAzure, func(map[string]string) (cloud.CloudProvider, error) {
		return azureProv, nil
	})

	// Turn the warm pool ON at the seams level with a genuinely-ready box. If azure
	// honoured it, tryWarmAssign would consume this row; pool-size-zero routing must
	// ignore it and one-shot on the azure provider instead.
	wc := &fakeWarmClient{}
	warmBox := seedWarmBox(t, ctx, hetznerProv, wc)
	seams.WarmPoolSize = 5
	seams.WarmClient = wc

	// S2 prereq satisfied so the honest-failure gate passes and we reach the create.
	t.Setenv(envAzureSSHPubKey, "ssh-ed25519 AAAAtest azure@barkpark")

	job := JobSpec{
		JobID:       "job-az",
		Name:        "Acme Co",
		Slug:        "acme",
		Region:      "eastus",
		ServerType:  "Standard_B1s",
		Kind:        cloud.ProviderAzure,
		Credentials: azureCreds(),
	}
	ip, adminToken, _, teardown, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith (azure): %v", err)
	}
	if ip == "" || teardown == nil {
		t.Fatalf("azure provision did not produce a live one-shot host (ip=%q teardown=%v)", ip, teardown)
	}
	if !strings.HasPrefix(adminToken, "bp_admin_") {
		t.Errorf("adminToken = %q, want a bp_admin_ token forwarded to the control plane", adminToken)
	}

	// ── the box was created on the AZURE provider (registry path), a bp-acme box ──
	azureHosts, _ := azureProv.List(ctx)
	if len(azureHosts) != 1 || !strings.HasPrefix(azureHosts[0].Name, "bp-acme-") {
		t.Fatalf("azure provider hosts = %+v, want exactly one bp-acme- one-shot box (resolved via ProviderFor)", azureHosts)
	}
	if ip != azureHosts[0].IP {
		t.Errorf("returned IP %q is not the azure box IP %q", ip, azureHosts[0].IP)
	}

	// ── seams.Provider (Hetzner fake) still holds ONLY the seeded warm box; azure
	// never touched it ──
	hetznerHosts, _ := hetznerProv.List(ctx)
	for _, h := range hetznerHosts {
		if strings.HasPrefix(h.Name, "bp-acme-") {
			t.Errorf("a bp-acme box %q was created on the Hetzner provider — azure did not route through the registry", h.Name)
		}
	}

	// ── pool-size-zero: the ready warm row was NOT claimed (still ready) ──
	if st := wc.statusOf(warmBox.Name); st != "ready" {
		t.Errorf("warm row %q status = %q after an azure job, want \"ready\" (pool-size-zero must not assign a warm box)", warmBox.Name, st)
	}
}

// TestProvisionWith_AzureMissingSSHPubKey_FailsHonestly proves the S2 prereq is
// enforced BEFORE any box is created: with no BARKPARK_AZURE_SSH_PUBKEY set, an
// azure job fails with copy that names the exact fix, and NOTHING is provisioned
// (no billed, login-dead orphan).
func TestProvisionWith_AzureMissingSSHPubKey_FailsHonestly(t *testing.T) {
	seams, hetznerProv, _, _ := fakeSeams(t)
	ctx := context.Background()

	azureProv := cloud.NewFakeProvider()
	cloud.Register(cloud.ProviderAzure, func(map[string]string) (cloud.CloudProvider, error) {
		return azureProv, nil
	})

	// Explicitly clear the env so the test is deterministic regardless of the host.
	t.Setenv(envAzureSSHPubKey, "")

	job := JobSpec{
		JobID:       "job-az-nokey",
		Name:        "Acme Co",
		Slug:        "acme",
		Region:      "eastus",
		ServerType:  "Standard_B1s",
		Kind:        cloud.ProviderAzure,
		Credentials: azureCreds(),
	}
	ip, _, _, teardown, err := ProvisionWith(ctx, seams, job)
	if err == nil {
		t.Fatal("ProvisionWith (azure, no ssh key) returned nil error, want an honest prereq failure")
	}
	if !strings.Contains(err.Error(), envAzureSSHPubKey) {
		t.Errorf("error = %q, want it to name the missing %s prereq", err.Error(), envAzureSSHPubKey)
	}
	if ip != "" || teardown != nil {
		t.Errorf("a failed prereq must not return a live host (ip=%q teardown=%v)", ip, teardown)
	}
	// No box anywhere — the prereq fired before create.
	azureHosts, _ := azureProv.List(ctx)
	hetznerHosts, _ := hetznerProv.List(ctx)
	if len(azureHosts) != 0 || len(hetznerHosts) != 0 {
		t.Errorf("a box was created despite the failed prereq (azure=%+v hetzner=%+v)", azureHosts, hetznerHosts)
	}
}

// TestProvisionWith_HetznerKindUnchanged proves an explicit Kind "hetzner" routes
// exactly like the empty (default) kind: the box is created on seams.Provider, and
// the Kind field does not divert it through the registry.
func TestProvisionWith_HetznerKindUnchanged(t *testing.T) {
	seams, prov, _, _ := fakeSeams(t)
	ctx := context.Background()

	job := JobSpec{JobID: "job-hz", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cx23", Kind: cloud.ProviderHetzner}
	ip, _, _, teardown, err := ProvisionWith(ctx, seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith (kind=hetzner): %v", err)
	}
	if ip == "" || teardown == nil {
		t.Fatal("kind=hetzner did not produce a live host through seams.Provider")
	}
	hosts, _ := prov.List(ctx)
	if len(hosts) != 1 || !strings.HasPrefix(hosts[0].Name, "bp-acme-") {
		t.Fatalf("kind=hetzner hosts = %+v, want one bp-acme- box on seams.Provider", hosts)
	}
}
