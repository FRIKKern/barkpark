package cloud

import (
	"context"
	"reflect"
	"testing"
)

// TestDefaultSpec asserts the per-provider region/type/image fallbacks. The
// hetzner row must stay nbg1 / cax11 / ubuntu-22.04 — identical to
// setup.defaultsFor — so the extracted seam does not drift from today's plan.
func TestDefaultSpec(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		want     ServerSpec
	}{
		{
			name:     "hetzner defaults",
			provider: ProviderHetzner,
			want:     ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"},
		},
		{
			name:     "unknown provider is zero",
			provider: "gcp",
			want:     ServerSpec{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := DefaultSpec(tt.provider); got != tt.want {
				t.Fatalf("DefaultSpec(%q) = %+v, want %+v", tt.provider, got, tt.want)
			}
		})
	}
}

// TestHcloudCreateArgv asserts the real provider builds the EXACT argv
// `bp setup --target provision` builds today — byte-for-byte, including flag
// order — WITHOUT invoking hcloud. BARKPARK_SSH_KEY is cleared so the ssh-key
// resolves to the documented "barkpark" default.
func TestHcloudCreateArgv(t *testing.T) {
	t.Setenv("BARKPARK_SSH_KEY", "")

	spec := ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"}
	want := []string{
		"hcloud", "server", "create",
		"--name", "acme",
		"--type", "cax11",
		"--image", "ubuntu-22.04",
		"--location", "nbg1",
		"--ssh-key", "barkpark",
	}
	if got := hcloudCreateArgv(spec); !reflect.DeepEqual(got, want) {
		t.Fatalf("hcloudCreateArgv mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

// TestHcloudCreateArgvHonoursSSHKeyEnv asserts BARKPARK_SSH_KEY overrides the
// ssh-key token exactly as setup.provisionSSHKey does.
func TestHcloudCreateArgvHonoursSSHKeyEnv(t *testing.T) {
	t.Setenv("BARKPARK_SSH_KEY", "my-key")
	got := hcloudCreateArgv(ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"})
	if got[len(got)-1] != "my-key" {
		t.Fatalf("ssh-key = %q, want %q (BARKPARK_SSH_KEY override)", got[len(got)-1], "my-key")
	}
}

// TestHcloudIPArgv asserts the IP read-back argv matches `hcloud server ip
// <name>` from provision.go.
func TestHcloudIPArgv(t *testing.T) {
	want := []string{"hcloud", "server", "ip", "acme"}
	if got := hcloudIPArgv("acme"); !reflect.DeepEqual(got, want) {
		t.Fatalf("hcloudIPArgv mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

// TestFakeProviderCreateIPContract asserts the FakeProvider's core contract:
// Create returns a server with a deterministic id + IP; IP(name) returns that
// same IP; List includes it; Delete removes it (and IP/Delete then 404).
func TestFakeProviderCreateIPContract(t *testing.T) {
	ctx := context.Background()
	fp := NewFakeProvider()

	srv, err := fp.Create(ctx, ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if srv.Name != "acme" {
		t.Fatalf("created name = %q, want %q", srv.Name, "acme")
	}
	if srv.IP != "10.0.0.1" {
		t.Fatalf("first fake IP = %q, want %q", srv.IP, "10.0.0.1")
	}
	if srv.ID != "fake-1" {
		t.Fatalf("first fake id = %q, want %q", srv.ID, "fake-1")
	}

	// IP(name) returns the same IP Create assigned.
	gotIP, err := fp.IP(ctx, "acme")
	if err != nil {
		t.Fatalf("IP: %v", err)
	}
	if gotIP != srv.IP {
		t.Fatalf("IP(%q) = %q, want %q (same as Create)", "acme", gotIP, srv.IP)
	}

	// List includes the created server.
	list, err := fp.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || list[0].Name != "acme" || list[0].IP != "10.0.0.1" {
		t.Fatalf("List = %+v, want one acme @ 10.0.0.1", list)
	}

	// A second create gets the next deterministic IP/id.
	srv2, err := fp.Create(ctx, ServerSpec{Name: "beta"})
	if err != nil {
		t.Fatalf("Create beta: %v", err)
	}
	if srv2.IP != "10.0.0.2" || srv2.ID != "fake-2" {
		t.Fatalf("second server = %+v, want IP 10.0.0.2 / id fake-2", srv2)
	}

	// Delete removes it; IP and Delete then report not-found.
	if err := fp.Delete(ctx, "acme"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := fp.IP(ctx, "acme"); err == nil {
		t.Fatalf("IP after Delete: want not-found error, got nil")
	}
	if err := fp.Delete(ctx, "acme"); err == nil {
		t.Fatalf("double Delete: want not-found error, got nil")
	}

	list, err = fp.List(ctx)
	if err != nil {
		t.Fatalf("List after Delete: %v", err)
	}
	if len(list) != 1 || list[0].Name != "beta" {
		t.Fatalf("List after deleting acme = %+v, want just beta", list)
	}
}

// TestFakeProviderRejectsDuplicateAndEmpty asserts the guard rails: a duplicate
// name and an empty name both error rather than silently corrupting the map.
func TestFakeProviderRejectsDuplicateAndEmpty(t *testing.T) {
	ctx := context.Background()
	fp := NewFakeProvider()

	if _, err := fp.Create(ctx, ServerSpec{Name: ""}); err == nil {
		t.Fatalf("Create with empty name: want error, got nil")
	}
	if _, err := fp.Create(ctx, ServerSpec{Name: "acme"}); err != nil {
		t.Fatalf("Create acme: %v", err)
	}
	if _, err := fp.Create(ctx, ServerSpec{Name: "acme"}); err == nil {
		t.Fatalf("duplicate Create: want error, got nil")
	}
}

// TestFakeProviderSatisfiesInterface is a belt-and-suspenders runtime check that
// the fake is usable wherever a CloudProvider is expected.
func TestFakeProviderSatisfiesInterface(t *testing.T) {
	var p CloudProvider = NewFakeProvider()
	if _, err := p.Create(context.Background(), ServerSpec{Name: "x"}); err != nil {
		t.Fatalf("Create via interface: %v", err)
	}
}
