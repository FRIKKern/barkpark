package cloud

import (
	"context"
	"fmt"
	"sort"
	"sync"
)

// FakeProvider is the in-memory CloudProvider every provisioning test runs
// against — no network, no Hetzner spend. Create records a server in a map and
// assigns a DETERMINISTIC fake IP ("10.0.0.<n>") and id ("fake-<n>") from a
// monotonically increasing counter, so tests can assert exact values. IP /
// Delete / List operate purely on the map. It is safe for concurrent use.
//
// NewFakeProvider returns a ready instance; the zero value also works (the map
// is lazily created on first Create).
type FakeProvider struct {
	mu      sync.Mutex
	servers map[string]Server
	next    int // counter feeding the deterministic id/IP
}

// NewFakeProvider returns an empty in-memory provider.
func NewFakeProvider() *FakeProvider {
	return &FakeProvider{servers: map[string]Server{}}
}

// Create records a server under spec.Name, assigning a deterministic id and IP.
// Re-creating an existing name is an error (the real hcloud rejects a duplicate
// name too), so a test can assert that path without touching the cloud.
func (f *FakeProvider) Create(_ context.Context, spec ServerSpec) (Server, error) {
	if spec.Name == "" {
		return Server{}, fmt.Errorf("cloud: fake Create requires a non-empty server name")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.servers == nil {
		f.servers = map[string]Server{}
	}
	if _, exists := f.servers[spec.Name]; exists {
		return Server{}, fmt.Errorf("cloud: fake server %q already exists", spec.Name)
	}
	f.next++
	srv := Server{
		ID:   fmt.Sprintf("fake-%d", f.next),
		Name: spec.Name,
		IP:   fmt.Sprintf("10.0.0.%d", f.next),
	}
	f.servers[spec.Name] = srv
	return srv, nil
}

// IP returns the recorded server's IP, or an error when the name is unknown.
func (f *FakeProvider) IP(_ context.Context, name string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	srv, ok := f.servers[name]
	if !ok {
		return "", fmt.Errorf("cloud: fake server %q not found", name)
	}
	return srv.IP, nil
}

// Delete removes the server from the map. Deleting an unknown name is an error so
// a test can assert the not-found path.
func (f *FakeProvider) Delete(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.servers[name]; !ok {
		return fmt.Errorf("cloud: fake server %q not found", name)
	}
	delete(f.servers, name)
	return nil
}

// List returns the recorded servers sorted by name so the result is
// deterministic for assertions.
func (f *FakeProvider) List(_ context.Context) ([]Server, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Server, 0, len(f.servers))
	for _, srv := range f.servers {
		out = append(out, srv)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// compile-time assertion that *FakeProvider satisfies the interface.
var _ CloudProvider = (*FakeProvider)(nil)
