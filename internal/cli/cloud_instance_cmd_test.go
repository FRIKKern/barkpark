package cli

// cloud_instance_cmd_test.go proves the provider-neutral fleet verbs and the
// azure escape hatch route through the cloud seam against the FAKE provider —
// zero live cloud calls. It also proves S5's azure wiring: azure resolves via
// cloud.ProviderFor (the blank/self-registered import populated the registry) and
// its committed capability row matches what AzureProvider actually satisfies.

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/cli/cloud/azure"
)

var azureEnvVars = []string{"AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "AZURE_SUBSCRIPTION_ID"}

func completeAzureCreds() map[string]string {
	return map[string]string{
		"tenant_id":       "00000000-0000-0000-0000-000000000000",
		"client_id":       "11111111-1111-1111-1111-111111111111",
		"client_secret":   "test-secret",
		"subscription_id": "22222222-2222-2222-2222-222222222222",
	}
}

// runInstanceCapture drives `bp cloud instance …` with an in-memory writer.
func runInstanceCapture(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudInstance(w, globals{}, args)
	return sout.String(), serr.String(), code
}

func runAzureCapture(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudAzure(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// coreOnlyProvider satisfies ONLY cloud.CloudProvider — no label capability — so
// the label-verb degrade path has a real provider to degrade against.
type coreOnlyProvider struct{}

func (coreOnlyProvider) Create(_ context.Context, spec cloud.ServerSpec) (cloud.Server, error) {
	return cloud.Server{Name: spec.Name, IP: "203.0.113.1"}, nil
}
func (coreOnlyProvider) IP(context.Context, string) (string, error)   { return "203.0.113.1", nil }
func (coreOnlyProvider) Delete(context.Context, string) error         { return nil }
func (coreOnlyProvider) List(context.Context) ([]cloud.Server, error) { return nil, nil }

// TestCloudInstanceRoundtripFake exercises create → list → ip → label → delete
// against a SHARED stateful fake registered under a test slug, proving each verb
// routes through ProviderFor and hits the core CloudProvider methods.
func TestCloudInstanceRoundtripFake(t *testing.T) {
	cloud.Register("s5fake", func(map[string]string) (cloud.CloudProvider, error) {
		return sharedS5Fake, nil
	})

	// create
	stdout, stderr, code := runInstanceCapture(t, "table", "create", "--provider", "s5fake", "--name", "web-1")
	if code != exitOK {
		t.Fatalf("create exit=%d\n%s\n%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "web-1") || !strings.Contains(stdout, "10.0.0.1") {
		t.Fatalf("create should report the box + its fake IP:\n%s", stdout)
	}

	// list shows it
	stdout, _, code = runInstanceCapture(t, "table", "list", "--provider", "s5fake")
	if code != exitOK || !strings.Contains(stdout, "web-1") {
		t.Fatalf("list should show the created box: exit=%d\n%s", code, stdout)
	}

	// ip prints the bare address (scriptable)
	stdout, _, code = runInstanceCapture(t, "table", "ip", "--provider", "s5fake", "web-1")
	if code != exitOK || strings.TrimSpace(stdout) != "10.0.0.1" {
		t.Fatalf("ip should print the bare address: exit=%d out=%q", code, stdout)
	}

	// label set (fake honours the label capability)
	stdout, stderr, code = runInstanceCapture(t, "table", "label", "set", "--provider", "s5fake", "web-1", "env", "prod")
	if code != exitOK {
		t.Fatalf("label set exit=%d\n%s\n%s", code, stdout, stderr)
	}

	// delete
	stdout, _, code = runInstanceCapture(t, "table", "delete", "--provider", "s5fake", "--yes", "web-1")
	if code != exitOK {
		t.Fatalf("delete exit=%d\n%s", code, stdout)
	}

	// list is empty again
	stdout, _, code = runInstanceCapture(t, "table", "list", "--provider", "s5fake")
	if code != exitOK || !strings.Contains(stdout, "no instances") {
		t.Fatalf("list should be empty after delete: exit=%d\n%s", code, stdout)
	}
}

var sharedS5Fake = cloud.NewFakeProvider()

// TestCloudInstanceUnknownProvider: an unregistered --provider is a usage error
// naming the known slugs, never a silent no-op.
func TestCloudInstanceUnknownProvider(t *testing.T) {
	_, stderr, code := runInstanceCapture(t, "table", "list", "--provider", "gcp")
	if code != exitUsage {
		t.Fatalf("exit=%d, want %d (usage)", code, exitUsage)
	}
	if !strings.Contains(stderr, "gcp") || !strings.Contains(stderr, "hetzner") {
		t.Errorf("error must name the bad kind AND the known slugs:\n%s", stderr)
	}
}

// TestCloudInstanceLabelDegrades: a provider without the label capability makes
// `label set` print an HONEST reason and exit non-fatally — never a dead verb.
func TestCloudInstanceLabelDegrades(t *testing.T) {
	cloud.Register("coreonly", func(map[string]string) (cloud.CloudProvider, error) {
		return coreOnlyProvider{}, nil
	})
	_, stderr, code := runInstanceCapture(t, "table", "label", "set", "--provider", "coreonly", "box", "k", "v")
	if code != exitGeneric {
		t.Fatalf("degrade exit=%d, want %d\n%s", code, exitGeneric, stderr)
	}
	for _, want := range []string{"coreonly", "does not support", "labels"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("degrade message should carry %q:\n%s", want, stderr)
		}
	}
}

// TestCloudInstanceHelp: -h prints usage naming the command, no routing.
func TestCloudInstanceHelp(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloudInstance(w, globals{help: true}, nil); code != exitOK {
		t.Fatalf("help exit=%d", code)
	}
	if !strings.Contains(sout.String(), "bp cloud instance") {
		t.Fatalf("help must name the command:\n%s", sout.String())
	}
}

// ── azure wiring (S5) ────────────────────────────────────────────────────────

// TestProviderForAzureConstructsOffline is criterion 1: with the azure package
// linked (blank/self-registered import), cloud.ProviderFor("azure", creds)
// resolves a real provider from a canned 4-tuple, making ZERO live Azure calls
// (construction never touches the network), and the provider advertises the
// capabilities the fixture claims.
func TestProviderForAzureConstructsOffline(t *testing.T) {
	for _, k := range azureEnvVars {
		t.Setenv(k, "") // env must not override the canned stored creds
	}
	p, err := cloud.ProviderFor(cloud.ProviderAzure, completeAzureCreds())
	if err != nil {
		t.Fatalf("ProviderFor(azure, creds): %v", err)
	}
	if p == nil {
		t.Fatal("ProviderFor(azure) returned a nil provider")
	}
	if _, ok := p.(cloud.Pauser); !ok {
		t.Error("azure provider should satisfy cloud.Pauser (pause=true)")
	}
	if _, ok := p.(cloud.ServerLabeler); !ok {
		t.Error("azure provider should satisfy cloud.ServerLabeler (labels=true)")
	}
	if _, ok := p.(cloud.Cataloger); ok {
		t.Error("azure provider must NOT claim Cataloger yet (catalog=false)")
	}
	// Azure implements NONE of the lifecycle FACET interfaces on the provider
	// struct — its decommission + audit are CLI-level (registered via the dispatch
	// table), and it has no archive/resurrect/adopt at all (Decision 20). So a
	// direct type-assert for every facet interface must fail.
	if _, ok := p.(cloud.Archiver); ok {
		t.Error("azure provider must NOT implement Archiver (archive=false)")
	}
	if _, ok := p.(cloud.Resurrector); ok {
		t.Error("azure provider must NOT implement Resurrector (resurrect=false)")
	}
	if _, ok := p.(cloud.Decommissioner); ok {
		t.Error("azure Decommission is CLI-level, not a provider method — must NOT implement Decommissioner")
	}
	if _, ok := p.(cloud.Adopter); ok {
		t.Error("azure provider must NOT implement Adopter (adopt=false)")
	}
	if _, ok := p.(cloud.Auditor); ok {
		t.Error("azure Audit is CLI-level, not a provider method — must NOT implement Auditor")
	}
}

// TestAzureFixtureParityInCLI proves the committed azure capability row matches
// what AzureProvider ACTUALLY satisfies — the cross-surface contract, checked in
// the binary where the azure package is linked (the cloud package's own test
// binary can't link azure without an import cycle).
func TestAzureFixtureParityInCLI(t *testing.T) {
	for _, k := range azureEnvVars {
		t.Setenv(k, "")
	}
	p, err := cloud.ProviderFor(cloud.ProviderAzure, completeAzureCreds())
	if err != nil {
		t.Fatalf("ProviderFor(azure): %v", err)
	}
	fixture, err := cloud.LoadCapabilities()
	if err != nil {
		t.Fatalf("LoadCapabilities: %v", err)
	}
	actual := cloud.DetectCapabilities(cloud.ProviderAzure, p)
	if actual != fixture[cloud.ProviderAzure].Capabilities {
		t.Errorf("azure fixture drift:\n  fixture: %+v\n  actual:  %+v", fixture[cloud.ProviderAzure].Capabilities, actual)
	}
}

// TestAzureRegisteredInCLI: the azure slug is registered in the bp binary (its
// package init self-registered it), so it appears in RegisteredProviders.
func TestAzureRegisteredInCLI(t *testing.T) {
	found := false
	for _, s := range cloud.RegisteredProviders() {
		if s == cloud.ProviderAzure {
			found = true
		}
	}
	if !found {
		t.Fatalf("azure must be registered in the cli binary; RegisteredProviders=%v", cloud.RegisteredProviders())
	}
}

// ── azure escape hatch ───────────────────────────────────────────────────────

// TestCloudAzureMissingCredsExitsAuth: `bp cloud azure list` with no credentials
// (flag or env) is an AUTH failure whose remediation names the AZURE_* env vars —
// and makes no network call.
func TestCloudAzureMissingCredsExitsAuth(t *testing.T) {
	for _, k := range azureEnvVars {
		t.Setenv(k, "")
	}
	_, stderr, code := runAzureCapture(t, "table", "list")
	if code != exitAuth {
		t.Fatalf("exit=%d, want %d (auth)\n%s", code, exitAuth, stderr)
	}
	if !strings.Contains(stderr, "AZURE_") {
		t.Errorf("remediation should name the AZURE_* env vars:\n%s", stderr)
	}
}

// TestCloudAzureRoutesWithFlagCreds: the escape hatch collects the cred flags
// (underscore-keyed) and routes the verb to the built provider — proven with a
// stubbed builder + a stateful fake, so no live ARM call.
func TestCloudAzureRoutesWithFlagCreds(t *testing.T) {
	shared := cloud.NewFakeProvider()
	var gotFlags map[string]string
	orig := azureProviderBuilder
	azureProviderBuilder = func(flags map[string]string) (cloud.CloudProvider, error) {
		gotFlags = flags
		return shared, nil
	}
	defer func() { azureProviderBuilder = orig }()

	credArgs := []string{"--tenant-id", "T", "--client-id", "C", "--client-secret", "S", "--subscription-id", "SUB"}

	_, stderr, code := runAzureCapture(t, "table", append([]string{"create", "--name", "web-1"}, credArgs...)...)
	if code != exitOK {
		t.Fatalf("create exit=%d\n%s", code, stderr)
	}
	want := map[string]string{"tenant_id": "T", "client_id": "C", "client_secret": "S", "subscription_id": "SUB"}
	for k, v := range want {
		if gotFlags[k] != v {
			t.Errorf("escape hatch cred flag %s = %q, want %q (all: %v)", k, gotFlags[k], v, gotFlags)
		}
	}

	stdout, _, code := runAzureCapture(t, "table", append([]string{"list"}, credArgs...)...)
	if code != exitOK || !strings.Contains(stdout, "web-1") {
		t.Fatalf("list should route to the built provider and show the box: exit=%d\n%s", code, stdout)
	}
}

// TestAzureResolveFlagBeatsEnv pins the escape hatch's precedence contract:
// a cred flag outranks the matching AZURE_* env var, and env fills any gap.
func TestAzureResolveFlagBeatsEnv(t *testing.T) {
	t.Setenv("AZURE_TENANT_ID", "env-tenant")
	t.Setenv("AZURE_CLIENT_ID", "env-client")
	t.Setenv("AZURE_CLIENT_SECRET", "env-secret")
	t.Setenv("AZURE_SUBSCRIPTION_ID", "env-sub")

	creds, err := azure.ResolveCredentials(map[string]string{"tenant_id": "flag-tenant"}, nil)
	if err != nil {
		t.Fatalf("ResolveCredentials: %v", err)
	}
	if creds.TenantID != "flag-tenant" {
		t.Errorf("flag must beat env: TenantID=%q", creds.TenantID)
	}
	if creds.ClientID != "env-client" {
		t.Errorf("env must fill the gap: ClientID=%q", creds.ClientID)
	}
}

// TestCloudAzureHelp: -h names the command and its cred flags.
func TestCloudAzureHelp(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloudAzure(w, globals{help: true}, nil); code != exitOK {
		t.Fatalf("help exit=%d", code)
	}
	if !strings.Contains(sout.String(), "bp cloud azure") || !strings.Contains(sout.String(), "--tenant-id") {
		t.Fatalf("help must name the command + cred flags:\n%s", sout.String())
	}
}
