package cloud

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// TestDefaultSpec asserts the per-provider region/type/image fallbacks. The
// hetzner default is cx23 / nbg1 / ubuntu-22.04 — the cheapest AVAILABLE type
// (cax ARM is out of stock; cpx is being retired), with BARKPARK_SERVER_TYPE /
// BARKPARK_SERVER_LOCATION overrides so ARM can be flipped back without a code
// change.
func TestDefaultSpec(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		want     ServerSpec
	}{
		{
			name:     "hetzner defaults",
			provider: ProviderHetzner,
			want:     ServerSpec{Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"},
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

// TestDefaultSpecHonoursEnvOverrides asserts BARKPARK_SERVER_TYPE and
// BARKPARK_SERVER_LOCATION override the hetzner default — the no-code-change
// escape hatch for when ARM stock returns (BARKPARK_SERVER_TYPE=cax11).
func TestDefaultSpecHonoursEnvOverrides(t *testing.T) {
	t.Setenv("BARKPARK_SERVER_TYPE", "cax11")
	t.Setenv("BARKPARK_SERVER_LOCATION", "fsn1")
	got := DefaultSpec(ProviderHetzner)
	want := ServerSpec{Region: "fsn1", ServerType: "cax11", Image: "ubuntu-22.04"}
	if got != want {
		t.Fatalf("DefaultSpec with env overrides = %+v, want %+v", got, want)
	}
}

// TestHcloudCreateArgv asserts the real provider builds the EXACT argv
// `hcloud server create` execs — byte-for-byte, including flag order — WITHOUT
// invoking hcloud. The resolved ssh-key NAME is now a parameter (the impure
// resolveSSHKey runs upstream), so this stays a pure assertion.
func TestHcloudCreateArgv(t *testing.T) {
	spec := ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"}
	want := []string{
		"hcloud", "server", "create",
		"--name", "acme",
		"--type", "cx23",
		"--image", "ubuntu-22.04",
		"--location", "nbg1",
		"--ssh-key", "barkpark-indx",
	}
	if got := hcloudCreateArgv(spec, "barkpark-indx"); !reflect.DeepEqual(got, want) {
		t.Fatalf("hcloudCreateArgv mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

// TestResolveSSHKey covers the three resolution paths: BARKPARK_SSH_KEY honored,
// an injected lister returning exactly one key auto-selects it, and 0 or 2 keys
// yield the clear "set BARKPARK_SSH_KEY" error.
func TestResolveSSHKey(t *testing.T) {
	ctx := context.Background()

	// (a) env honored — the lister is never consulted.
	t.Run("env honored", func(t *testing.T) {
		t.Setenv("BARKPARK_SSH_KEY", "explicit-key")
		restore := swapSSHKeyLister(func(context.Context) ([]string, error) {
			t.Fatal("lister should not be called when BARKPARK_SSH_KEY is set")
			return nil, nil
		})
		defer restore()
		got, err := resolveSSHKey(ctx)
		if err != nil {
			t.Fatalf("resolveSSHKey: %v", err)
		}
		if got != "explicit-key" {
			t.Fatalf("resolveSSHKey = %q, want %q (env)", got, "explicit-key")
		}
	})

	// (b) exactly one account key → auto-select it.
	t.Run("exactly one key auto-selects", func(t *testing.T) {
		t.Setenv("BARKPARK_SSH_KEY", "")
		restore := swapSSHKeyLister(func(context.Context) ([]string, error) {
			return []string{"barkpark-indx"}, nil
		})
		defer restore()
		got, err := resolveSSHKey(ctx)
		if err != nil {
			t.Fatalf("resolveSSHKey: %v", err)
		}
		if got != "barkpark-indx" {
			t.Fatalf("resolveSSHKey = %q, want %q (the only key)", got, "barkpark-indx")
		}
	})

	// (c) zero keys → clear error naming the count.
	t.Run("zero keys errors", func(t *testing.T) {
		t.Setenv("BARKPARK_SSH_KEY", "")
		restore := swapSSHKeyLister(func(context.Context) ([]string, error) {
			return nil, nil
		})
		defer restore()
		_, err := resolveSSHKey(ctx)
		if err == nil {
			t.Fatal("resolveSSHKey with 0 keys: want error, got nil")
		}
		if !strings.Contains(err.Error(), "BARKPARK_SSH_KEY") || !strings.Contains(err.Error(), "found 0 ssh keys") {
			t.Fatalf("error should name BARKPARK_SSH_KEY and the count, got: %v", err)
		}
	})

	// (d) two keys → ambiguous, clear error.
	t.Run("two keys errors", func(t *testing.T) {
		t.Setenv("BARKPARK_SSH_KEY", "")
		restore := swapSSHKeyLister(func(context.Context) ([]string, error) {
			return []string{"barkpark-indx", "barkpark-laptop"}, nil
		})
		defer restore()
		_, err := resolveSSHKey(ctx)
		if err == nil {
			t.Fatal("resolveSSHKey with 2 keys: want error, got nil")
		}
		if !strings.Contains(err.Error(), "found 2 ssh keys") {
			t.Fatalf("error should name the count (2), got: %v", err)
		}
	})
}

// swapSSHKeyLister installs a fake sshKeyLister and returns a restore func.
func swapSSHKeyLister(fn func(context.Context) ([]string, error)) func() {
	prev := sshKeyLister
	sshKeyLister = fn
	return func() { sshKeyLister = prev }
}

// TestHcloudIPArgv asserts the IP read-back argv matches `hcloud server ip
// <name>` from provision.go.
func TestHcloudIPArgv(t *testing.T) {
	want := []string{"hcloud", "server", "ip", "acme"}
	if got := hcloudIPArgv("acme"); !reflect.DeepEqual(got, want) {
		t.Fatalf("hcloudIPArgv mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

// TestHetznerCandidates asserts the resilience ladder: an ordered, deduped list
// that preserves Name+Image and varies only type/location. base leads; the four
// cx/cpx fallbacks follow; a candidate equal to base is skipped.
func TestHetznerCandidates(t *testing.T) {
	base := ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"}
	got := HetznerCandidates(base)
	want := []ServerSpec{
		{Name: "acme", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"}, // base
		{Name: "acme", Region: "fsn1", ServerType: "cx23", Image: "ubuntu-22.04"},
		{Name: "acme", Region: "hel1", ServerType: "cx23", Image: "ubuntu-22.04"},
		{Name: "acme", Region: "nbg1", ServerType: "cx33", Image: "ubuntu-22.04"},
		{Name: "acme", Region: "fsn1", ServerType: "cpx22", Image: "ubuntu-22.04"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("HetznerCandidates ladder mismatch\n got: %#v\nwant: %#v", got, want)
	}
	// Every candidate must preserve base.Name and base.Image.
	for i, c := range got {
		if c.Name != base.Name {
			t.Errorf("candidate %d Name = %q, want %q (preserved)", i, c.Name, base.Name)
		}
		if c.Image != base.Image {
			t.Errorf("candidate %d Image = %q, want %q (preserved)", i, c.Image, base.Image)
		}
	}
}

// TestHetznerCandidatesDedupesBase asserts a base equal to one of the ladder
// rungs is not emitted twice — when base IS {cx23/fsn1}, that rung is skipped so
// base leads exactly once.
func TestHetznerCandidatesDedupesBase(t *testing.T) {
	base := ServerSpec{Name: "acme", Region: "fsn1", ServerType: "cx23", Image: "ubuntu-22.04"}
	got := HetznerCandidates(base)
	// base leads, and the duplicate {cx23/fsn1} rung is removed → 4 entries.
	if len(got) != 4 {
		t.Fatalf("HetznerCandidates(base==cx23/fsn1) = %d entries, want 4 (base + dedupe): %#v", len(got), got)
	}
	if got[0] != base {
		t.Fatalf("first candidate = %+v, want base %+v", got[0], base)
	}
	// No entry after the lead may equal base.
	for i, c := range got[1:] {
		if c == base {
			t.Fatalf("candidate %d duplicates base %+v", i+1, base)
		}
	}
}

// failNProvider is a CloudProvider whose Create fails for the first failUntil
// invocations (with a distinct, surfaced error) then succeeds — modelling
// "preferred type sold out, a later rung available".
type failNProvider struct {
	failUntil int
	calls     int
	created   []ServerSpec
}

func (f *failNProvider) Create(_ context.Context, spec ServerSpec) (Server, error) {
	f.calls++
	f.created = append(f.created, spec)
	if f.calls <= f.failUntil {
		return Server{}, fmt.Errorf("resource_unavailable: %s sold out in %s", spec.ServerType, spec.Region)
	}
	return Server{ID: fmt.Sprintf("srv-%d", f.calls), Name: spec.Name, IP: "10.0.0.9"}, nil
}
func (f *failNProvider) IP(context.Context, string) (string, error) { return "10.0.0.9", nil }
func (f *failNProvider) Delete(context.Context, string) error       { return nil }
func (f *failNProvider) List(context.Context) ([]Server, error)     { return nil, nil }

// TestCreateWithFallback_SucceedsOnLaterCandidate asserts the ladder is walked:
// a provider that fails the first K candidates then succeeds returns the (K+1)th
// spec and that spec's server.
func TestCreateWithFallback_SucceedsOnLaterCandidate(t *testing.T) {
	base := ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"}
	candidates := HetznerCandidates(base)

	for k := 0; k < len(candidates); k++ {
		t.Run(fmt.Sprintf("fail_first_%d", k), func(t *testing.T) {
			prov := &failNProvider{failUntil: k}
			srv, spec, err := CreateWithFallback(context.Background(), prov, base)
			if err != nil {
				t.Fatalf("CreateWithFallback: unexpected error: %v", err)
			}
			if spec != candidates[k] {
				t.Fatalf("winning spec = %+v, want the (K+1)th candidate %+v", spec, candidates[k])
			}
			if srv.Name != base.Name {
				t.Fatalf("server name = %q, want %q", srv.Name, base.Name)
			}
			if prov.calls != k+1 {
				t.Fatalf("provider.Create calls = %d, want %d (stops at first success)", prov.calls, k+1)
			}
		})
	}
}

// TestCreateWithFallback_AllFailAggregates asserts that when every candidate
// fails, the aggregated error lists each candidate's type/location AND its
// underlying (now-visible) message — so a real failure like ssh-key-not-found is
// obvious, not hidden behind "all unavailable".
func TestCreateWithFallback_AllFailAggregates(t *testing.T) {
	base := ServerSpec{Name: "acme", Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"}
	candidates := HetznerCandidates(base)
	prov := &failNProvider{failUntil: len(candidates)} // fail every candidate

	_, _, err := CreateWithFallback(context.Background(), prov, base)
	if err == nil {
		t.Fatal("CreateWithFallback: want an error when all candidates fail, got nil")
	}
	msg := err.Error()
	for _, c := range candidates {
		tl := c.ServerType + "/" + c.Region
		if !strings.Contains(msg, tl) {
			t.Errorf("aggregated error missing candidate %q; got:\n%s", tl, msg)
		}
	}
	// Each underlying message must survive (sample the distinctive token).
	if !strings.Contains(msg, "resource_unavailable") {
		t.Errorf("aggregated error dropped the underlying hcloud message; got:\n%s", msg)
	}
	if prov.calls != len(candidates) {
		t.Errorf("provider.Create calls = %d, want %d (tried every candidate)", prov.calls, len(candidates))
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
