package azure

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// testCreds is a COMPLETE but entirely fake 4-tuple. UUID-shaped so azidentity
// accepts the tenant id; none of it is real and no request leaves the fake.
var testCreds = Credentials{
	TenantID:       "22222222-2222-2222-2222-222222222222",
	ClientID:       "11111111-1111-1111-1111-111111111111",
	ClientSecret:   "not-a-real-secret",
	SubscriptionID: "33333333-3333-3333-3333-333333333333",
}

// newTestProvider wires a provider to a fixture-replaying fake with a sub-second
// poll floor so LRO tests stay fast.
func newTestProvider(t *testing.T, routes []fakeRoute) (*AzureProvider, *fakeTransport) {
	t.Helper()
	ft := newFakeTransport(t, routes)
	p, err := New(testCreds,
		WithTransport(ft),
		WithPollFrequency(time.Millisecond),
		WithResourceGroup("barkpark-fleet"),
		WithLocation("eastus"),
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return p, ft
}

func TestCreate_HappyPath(t *testing.T) {
	p, ft := newTestProvider(t, createRoutes())

	srv, err := p.Create(context.Background(), cloud.ServerSpec{
		Name:       "acme-1",
		Region:     "eastus",
		ServerType: "Standard_B1s",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if srv.Name != "acme-1" {
		t.Errorf("Name = %q, want acme-1", srv.Name)
	}
	if srv.IP != "20.30.40.50" {
		t.Errorf("IP = %q, want 20.30.40.50", srv.IP)
	}
	if !strings.HasSuffix(srv.ID, "/virtualMachines/acme-1") {
		t.Errorf("ID = %q, want a VM resource id", srv.ID)
	}
	// The VM GET route must have been polled twice (Creating → Succeeded): proof
	// the LRO poll sequence actually ran, not a single-shot happy return.
	if got := ft.hits("vm-get"); got < 2 {
		t.Errorf("vm-get polled %d times, want >= 2 (LRO sequence)", got)
	}
	// Token exchange happened exactly once and was reused across every ARM call.
	if got := ft.hits("auth-token"); got != 1 {
		t.Errorf("auth-token hit %d times, want 1 (token must be cached)", got)
	}
	// No teardown on the happy path.
	if got := ft.hits("vm-delete"); got != 0 {
		t.Errorf("vm-delete hit %d times on happy path, want 0", got)
	}
}

func TestCreate_FailedReadbackDeletesOrphan(t *testing.T) {
	// The public IP GET returns no address → the read-back fails → Create must
	// tear down THIS box's per-box resources (VM, NIC, PublicIP) and never leak a
	// billed orphan. The shared group + VNet are left standing.
	routes := createRoutes()
	// Override the pip-get route to the no-IP fixture.
	for i := range routes {
		if routes[i].name == "pip-get" {
			routes[i].fixtures = []string{"publicip_get_noip.json"}
		}
	}
	routes = append(routes, deleteRoutes()...)

	p, ft := newTestProvider(t, routes)
	_, err := p.Create(context.Background(), cloud.ServerSpec{Name: "acme-1", Region: "eastus", ServerType: "Standard_B1s"})
	if err == nil {
		t.Fatal("Create with an unreadable IP returned nil error")
	}
	if !strings.Contains(err.Error(), "ip read-back") {
		t.Errorf("error %q should mention the ip read-back failure", err.Error())
	}
	// The orphan cleanup must have deleted the box's three per-box resources.
	for _, route := range []string{"vm-delete", "nic-delete", "pip-delete"} {
		if got := ft.hits(route); got != 1 {
			t.Errorf("%s hit %d times, want 1 (orphan cleanup must delete it)", route, got)
		}
	}
}

func TestDelete_Idempotent(t *testing.T) {
	p, ft := newTestProvider(t, append(authRoutes(), deleteRoutes()...))
	if err := p.Delete(context.Background(), "acme-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	// Dependency order: VM, then NIC, then PublicIP.
	for _, route := range []string{"vm-delete", "nic-delete", "pip-delete"} {
		if got := ft.hits(route); got != 1 {
			t.Errorf("%s hit %d times, want 1", route, got)
		}
	}
}

func TestDelete_NotFoundIsSuccess(t *testing.T) {
	// Every resource is already gone (404). Delete must swallow the not-found and
	// return nil, so the orphan sweep can call it safely and re-runs are no-ops.
	notFound := []fakeRoute{
		{name: "vm-delete", method: "DELETE", contains: []string{"/virtualmachines/"}, fixtures: []string{"delete_notfound.json"}},
		{name: "nic-delete", method: "DELETE", contains: []string{"/networkinterfaces/"}, fixtures: []string{"delete_notfound.json"}},
		{name: "pip-delete", method: "DELETE", contains: []string{"/publicipaddresses/"}, fixtures: []string{"delete_notfound.json"}},
	}
	p, _ := newTestProvider(t, append(authRoutes(), notFound...))
	if err := p.Delete(context.Background(), "ghost-1"); err != nil {
		t.Fatalf("Delete of an already-gone box should be nil, got %v", err)
	}
}

func TestTagLifecycle_Roundtrip(t *testing.T) {
	// The fake replays fixtures (it doesn't mutate state), so this verifies each
	// tag operation's request/response contract end to end: stamp orphaned, list
	// by that label and get the fqdn tag back, then strip the warm label.
	routes := authRoutes()
	routes = append(routes, tagRoute(), listRoute())
	p, ft := newTestProvider(t, routes)
	ctx := context.Background()

	if err := p.LabelServer(ctx, "acme-1", cloud.OrphanedLabelKey, "true"); err != nil {
		t.Fatalf("LabelServer: %v", err)
	}

	orphans, err := p.ListByLabel(ctx, cloud.OrphanedLabelKey, "true")
	if err != nil {
		t.Fatalf("ListByLabel: %v", err)
	}
	if len(orphans) != 1 || orphans[0].Name != "acme-1" {
		t.Fatalf("ListByLabel returned %+v, want exactly acme-1", orphans)
	}
	if got := orphans[0].Labels[cloud.FQDNLabelKey]; got != "acme-1.barkpark.cloud" {
		t.Errorf("orphan fqdn label = %q, want acme-1.barkpark.cloud (tags must ride back)", got)
	}

	if err := p.RemoveLabel(ctx, "warm-9", cloud.WarmLabelKey); err != nil {
		t.Fatalf("RemoveLabel: %v", err)
	}
	if got := ft.hits("tags-patch"); got != 2 {
		t.Errorf("tags-patch hit %d times, want 2 (label + remove)", got)
	}
}

func TestList_KeepsOnlyManaged(t *testing.T) {
	p, _ := newTestProvider(t, append(authRoutes(), listRoute()))
	servers, err := p.List(context.Background())
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	// The fixture has three VMs; the untagged one must be filtered out.
	names := map[string]bool{}
	for _, s := range servers {
		names[s.Name] = true
	}
	if !names["acme-1"] || !names["warm-9"] {
		t.Errorf("List missing managed boxes: got %v", names)
	}
	if names["unmanaged-x"] {
		t.Errorf("List returned an unmanaged (untagged) box")
	}
	// A managed VM in a DIFFERENT resource group belongs to another fleet and must
	// not leak into this fleet's listing (the sweep must never touch it).
	if names["foreign-7"] {
		t.Errorf("List returned a managed box from a foreign resource group")
	}
}

func TestDeallocateAndStart(t *testing.T) {
	p, ft := newTestProvider(t, append(authRoutes(), powerRoutes()...))
	ctx := context.Background()
	if err := p.Deallocate(ctx, "acme-1"); err != nil {
		t.Fatalf("Deallocate: %v", err)
	}
	if err := p.Start(ctx, "acme-1"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if got := ft.hits("async-op"); got < 2 {
		t.Errorf("async-op polled %d times, want >= 2 (deallocate + start each poll)", got)
	}
}

func TestHasAuth_MissingCredentials(t *testing.T) {
	// A provider with an incomplete tuple reports HasAuth=false and every op
	// returns a clear, field-naming error — no nil panic, no cryptic 401.
	p, err := New(Credentials{TenantID: "only-tenant"})
	if err != nil {
		t.Fatalf("New with partial creds should not error: %v", err)
	}
	if p.HasAuth(context.Background()) {
		t.Fatal("HasAuth = true for an incomplete tuple, want false")
	}
	_, err = p.Create(context.Background(), cloud.ServerSpec{Name: "x"})
	if err == nil {
		t.Fatal("Create with incomplete creds returned nil error")
	}
	for _, want := range []string{EnvClientID, EnvClientSecret, EnvSubscriptionID} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q should name the missing field %q", err.Error(), want)
		}
	}
}

func TestResolveCredentials_Missing(t *testing.T) {
	t.Setenv(EnvTenantID, "")
	t.Setenv(EnvClientID, "")
	t.Setenv(EnvClientSecret, "")
	t.Setenv(EnvSubscriptionID, "")
	_, err := ResolveCredentials(nil, nil)
	if err == nil {
		t.Fatal("ResolveCredentials with no creds returned nil error")
	}
	if !strings.Contains(err.Error(), "incomplete") {
		t.Errorf("error %q should explain the credentials are incomplete", err.Error())
	}
}

func TestResolveCredentials_Precedence(t *testing.T) {
	t.Setenv(EnvTenantID, "env-tenant")
	t.Setenv(EnvClientID, "env-client")
	t.Setenv(EnvClientSecret, "env-secret")
	t.Setenv(EnvSubscriptionID, "env-sub")

	// Flag outranks env; env fills the gaps a flag leaves; stored is the last
	// resort under env.
	flags := map[string]string{"tenant_id": "flag-tenant"}
	stored := map[string]string{"client_id": "stored-client", "subscription_id": "stored-sub"}
	got, err := ResolveCredentials(flags, stored)
	if err != nil {
		t.Fatalf("ResolveCredentials: %v", err)
	}
	if got.TenantID != "flag-tenant" {
		t.Errorf("TenantID = %q, want flag-tenant (flag wins)", got.TenantID)
	}
	if got.ClientID != "env-client" {
		t.Errorf("ClientID = %q, want env-client (env beats stored)", got.ClientID)
	}
	if got.ClientSecret != "env-secret" {
		t.Errorf("ClientSecret = %q, want env-secret", got.ClientSecret)
	}
	if got.SubscriptionID != "env-sub" {
		t.Errorf("SubscriptionID = %q, want env-sub", got.SubscriptionID)
	}
}
