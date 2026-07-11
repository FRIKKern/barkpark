package cloud

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"
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
	mu       sync.Mutex
	servers  map[string]Server
	archives map[string][]Archive // fqdn → recorded archives, oldest→newest (append order)
	created  []ServerSpec         // every spec Create was handed, in call order
	next     int                  // counter feeding the deterministic id/IP
}

// NewFakeProvider returns an empty in-memory provider.
func NewFakeProvider() *FakeProvider {
	return &FakeProvider{servers: map[string]Server{}, archives: map[string][]Archive{}}
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
	f.created = append(f.created, spec)
	f.next++
	srv := Server{
		ID:   fmt.Sprintf("fake-%d", f.next),
		Name: spec.Name,
		IP:   fmt.Sprintf("10.0.0.%d", f.next),
		// Mirror the real provider: every created box is stamped managed=true so
		// the orphan sweep can distinguish managed (leave alone) from orphaned.
		Labels: map[string]string{ManagedLabelKey: managedLabelVal},
	}
	f.servers[spec.Name] = srv
	return srv, nil
}

// CreatedSpecs returns a copy of every ServerSpec Create was handed, in call
// order — so a test can assert the EXACT shape (region/type/image) that reached
// the provider boundary, not just that a server exists.
func (f *FakeProvider) CreatedSpecs() []ServerSpec {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]ServerSpec, len(f.created))
	copy(out, f.created)
	return out
}

// LabelServer adds (or overwrites) a label on an existing fake server — the
// in-memory analogue of `hcloud server add-label --overwrite`. Labeling an
// unknown name is an error so a test can assert the not-found path. This is what
// the teardown path calls to stamp barkpark-orphaned=true on a box whose Delete
// failed.
func (f *FakeProvider) LabelServer(_ context.Context, name, key, val string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	srv, ok := f.servers[name]
	if !ok {
		return fmt.Errorf("cloud: fake server %q not found", name)
	}
	if srv.Labels == nil {
		srv.Labels = map[string]string{}
	}
	srv.Labels[key] = val
	f.servers[name] = srv
	return nil
}

// RemoveLabel strips a label from an existing fake server — the in-memory
// analogue of `hcloud server remove-label`. Removing from an unknown name is an
// error so a test can assert the not-found path; removing an absent key is a
// no-op. This is what AssignWarm calls to drop barkpark-warm off a promoted box.
func (f *FakeProvider) RemoveLabel(_ context.Context, name, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	srv, ok := f.servers[name]
	if !ok {
		return fmt.Errorf("cloud: fake server %q not found", name)
	}
	if srv.Labels != nil {
		delete(srv.Labels, key)
		f.servers[name] = srv
	}
	return nil
}

// ListByLabel returns the recorded servers carrying key=val, sorted by name for
// deterministic assertions — the in-memory analogue of
// `hcloud server list -l <key>=<val>`. It is the safe input to SweepOrphans: only
// boxes the teardown path stamped orphaned come back, so a managed-but-not-orphaned
// box and an unlabeled box are never returned.
func (f *FakeProvider) ListByLabel(_ context.Context, key, val string) ([]Server, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Server, 0)
	for _, srv := range f.servers {
		if srv.Labels[key] == val {
			out = append(out, srv)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
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

// ── Optional seam-v2 capabilities ───────────────────────────────────────────
// The fake honours EVERY optional capability (providers_capabilities.json marks
// fake all-true) so it is the reference provider future capability tests run
// against — the real Hetzner/Azure impls are verified for equivalence against
// this behaviour. All operate purely in memory: no network, no spend.

// HasAuth (Authenticator): the fake needs no credential, so it is always
// authenticated. Lets `bp cloud providers` show a deterministic auth state.
func (f *FakeProvider) HasAuth(context.Context) bool { return true }

// Catalog (Cataloger) returns a small, deterministic normalized catalog so a
// launch-menu test has stable regions and priced sizes to assert against.
func (f *FakeProvider) Catalog(context.Context) (Catalog, error) {
	return Catalog{
		Regions: []string{"fake-region-a", "fake-region-b"},
		ServerTypes: []ServerType{
			{Slug: "fake-small", Cores: 2, RAMGb: 4, DiskGb: 40, MonthlyPrice: 5.0},
			{Slug: "fake-large", Cores: 8, RAMGb: 16, DiskGb: 160, MonthlyPrice: 20.0},
		},
	}, nil
}

// Archive (Archiver) returns a synthetic resurrection-bearing archive for
// target AND records it in the archives map so a later Resurrect has a newest
// archive to rebuild from. It stays BOX-AGNOSTIC — archiving does not require a
// live server (snapshotting an fqdn the fake never created is fine), so the
// unseeded-box lifecycle test keeps passing. An empty target is an error so a
// test can assert that guard.
func (f *FakeProvider) Archive(_ context.Context, target string) (Archive, error) {
	if target == "" {
		return Archive{}, fmt.Errorf("cloud: fake Archive requires a non-empty target")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.archives == nil {
		f.archives = map[string][]Archive{}
	}
	a := Archive{ID: "fake-archive-" + target, FQDN: target, Provider: ProviderFake, Created: time.Now().UTC()}
	f.archives[target] = append(f.archives[target], a)
	return a, nil
}

// Decommission (Decommissioner) tears the box down — the in-memory analogue
// of archive→teardown→verify-no-residue. An unknown target is a not-found error.
func (f *FakeProvider) Decommission(_ context.Context, target string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.servers[target]; !ok {
		return fmt.Errorf("cloud: fake server %q not found", target)
	}
	delete(f.servers, target)
	return nil
}

// Resurrect (Resurrector) rebuilds an instance for fqdn from its NEWEST recorded
// archive — modelled as a fresh Create under the fqdn name. With no archive on
// record it is an honest not-found error (nothing to restore), so the fake
// mirrors the real path where resurrect refuses an fqdn no snapshot carries.
func (f *FakeProvider) Resurrect(ctx context.Context, fqdn string) (Server, error) {
	f.mu.Lock()
	has := len(f.archives[fqdn]) > 0
	f.mu.Unlock()
	if !has {
		return Server{}, fmt.Errorf("cloud: fake has no archive for %q — archive it first", fqdn)
	}
	return f.Create(ctx, ServerSpec{Name: fqdn})
}

// Adopt (Adopter) converts a standalone box into a tenant of team;
// the fake just validates the inputs (an empty fqdn or team is an error).
func (f *FakeProvider) Adopt(_ context.Context, fqdn, team string) error {
	if fqdn == "" || team == "" {
		return fmt.Errorf("cloud: fake Adopt requires a non-empty fqdn and team")
	}
	return nil
}

// Audit (Auditor) cross-checks the fleet — the fake reports how many
// boxes it holds with no residue issues.
func (f *FakeProvider) Audit(context.Context) (AuditReport, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return AuditReport{Checked: len(f.servers)}, nil
}

// Pause (Pauser) stops a box without deleting it. An unknown name is a not-found
// error; the fake has no power state to change, so a present box is a no-op.
func (f *FakeProvider) Pause(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.servers[name]; !ok {
		return fmt.Errorf("cloud: fake server %q not found", name)
	}
	return nil
}

// Resume (Pauser) starts a paused box. An unknown name is a not-found error.
func (f *FakeProvider) Resume(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.servers[name]; !ok {
		return fmt.Errorf("cloud: fake server %q not found", name)
	}
	return nil
}

// compile-time assertions that *FakeProvider satisfies the core interface, the
// optional label-aware capabilities the orphan-recovery path uses, and — as the
// reference provider — EVERY seam-v2 optional capability the fixture marks true,
// including each lifecycle FACET interface (charter Decision 20) that replaced
// the old all-or-nothing InstanceLifecycler.
var (
	_ CloudProvider      = (*FakeProvider)(nil)
	_ ServerLabeler      = (*FakeProvider)(nil)
	_ LabelLister        = (*FakeProvider)(nil)
	_ ServerLabelRemover = (*FakeProvider)(nil)
	_ Cataloger          = (*FakeProvider)(nil)
	_ Archiver           = (*FakeProvider)(nil)
	_ Resurrector        = (*FakeProvider)(nil)
	_ Decommissioner     = (*FakeProvider)(nil)
	_ Adopter            = (*FakeProvider)(nil)
	_ Auditor            = (*FakeProvider)(nil)
	_ Pauser             = (*FakeProvider)(nil)
	_ Authenticator      = (*FakeProvider)(nil)
)

// ── FakeBundleStore ──────────────────────────────────────────────────────────
// The in-memory BundleStore every bundle test writes/reads through — the
// object-store analogue of FakeProvider: no S3, no spend, deterministic. It
// ships as a public constructor (like NewFakeProvider) so any package building
// on the bundle library can round-trip a bundle in a unit test.

// FakeBundleStore is a concurrency-safe, in-memory object store keyed by full
// object key. It honours the whole BundleStore seam (PutLarge/Get/List/Delete)
// against a map so a bundle can be written and re-read with zero network.
type FakeBundleStore struct {
	mu      sync.Mutex
	objects map[string][]byte
}

// NewFakeBundleStore returns an empty in-memory store.
func NewFakeBundleStore() *FakeBundleStore {
	return &FakeBundleStore{objects: map[string][]byte{}}
}

// PutLarge drains r fully and records it under key — the in-memory analogue of
// a multipart upload. A re-put overwrites, matching S3's last-write-wins.
func (s *FakeBundleStore) PutLarge(_ context.Context, key string, r io.Reader) error {
	b, err := io.ReadAll(r)
	if err != nil {
		return fmt.Errorf("cloud: fake bundle store read body for %s: %w", key, err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.objects == nil {
		s.objects = map[string][]byte{}
	}
	s.objects[key] = b
	return nil
}

// Get returns a reader over the recorded bytes for key, or a not-found error so a
// test can assert the missing-object path.
func (s *FakeBundleStore) Get(_ context.Context, key string) (io.ReadCloser, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.objects[key]
	if !ok {
		return nil, fmt.Errorf("cloud: fake bundle store: object %q not found", key)
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}

// List returns every recorded object key under prefix, sorted for deterministic
// assertions.
func (s *FakeBundleStore) List(_ context.Context, prefix string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0)
	for k := range s.objects {
		if strings.HasPrefix(k, prefix) {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out, nil
}

// Delete removes key. Deleting an absent key is a no-op — S3 DELETE is
// idempotent by contract, and the objstore adapter honours the same.
func (s *FakeBundleStore) Delete(_ context.Context, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.objects, key)
	return nil
}

var _ BundleStore = (*FakeBundleStore)(nil)
