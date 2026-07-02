package provisioner

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// fakeWarmRow is one warm-server row in the fake claim store.
type fakeWarmRow struct {
	name, ip, status string // status: ready | claimed | retiring
}

// fakeWarmClient is an in-memory, genuinely-atomic (mutex) WarmPoolClient — the
// seam's test double. Its atomicity is a mutex, NOT the production primitive
// (Postgres FOR UPDATE SKIP LOCKED lives in the cloud/ Elixir app and is tested
// there); this fake proves the GO orchestration claims-and-consumes correctly and
// that two concurrent claimers at the seam boundary never both win a row.
type fakeWarmClient struct {
	mu         sync.Mutex
	rows       []fakeWarmRow
	registered []string // every name Register was called with (idempotency-agnostic)
	claimErr   error    // when set, Claim returns it (transport failure)
	countErr   error    // when set, CountReady returns it
}

func (f *fakeWarmClient) Register(_ context.Context, ws WarmServer) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.registered = append(f.registered, ws.Name)
	for _, r := range f.rows {
		if r.name == ws.Name {
			return nil // idempotent on name
		}
	}
	f.rows = append(f.rows, fakeWarmRow{name: ws.Name, ip: ws.IP, status: "ready"})
	return nil
}

func (f *fakeWarmClient) claimReady(newStatus string) (WarmServer, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].status == "ready" {
			f.rows[i].status = newStatus
			return WarmServer{Name: f.rows[i].name, IP: f.rows[i].ip}, true, nil
		}
	}
	return WarmServer{}, false, nil
}

func (f *fakeWarmClient) Claim(_ context.Context) (WarmServer, bool, error) {
	if f.claimErr != nil {
		return WarmServer{}, false, f.claimErr
	}
	return f.claimReady("claimed")
}

func (f *fakeWarmClient) ClaimForRetire(_ context.Context) (WarmServer, bool, error) {
	return f.claimReady("retiring")
}

func (f *fakeWarmClient) Delete(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	kept := f.rows[:0]
	for _, r := range f.rows {
		if r.name != name {
			kept = append(kept, r)
		}
	}
	f.rows = kept
	return nil
}

func (f *fakeWarmClient) CountReady(_ context.Context) (int, error) {
	if f.countErr != nil {
		return 0, f.countErr
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, r := range f.rows {
		if r.status == "ready" {
			n++
		}
	}
	return n, nil
}

// helpers on the fake for test assertions.
func (f *fakeWarmClient) rowCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.rows)
}

func (f *fakeWarmClient) statusOf(name string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.rows {
		if r.name == name {
			return r.status
		}
	}
	return ""
}

func (f *fakeWarmClient) markStatus(name, status string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].name == name {
			f.rows[i].status = status
		}
	}
}

// seedWarmBox creates a warm box in the provider AND registers it in the client,
// returning the box (so a test can drive an assign of an already-pooled box).
func seedWarmBox(t *testing.T, ctx context.Context, prov *cloud.FakeProvider, wc *fakeWarmClient) cloud.Server {
	t.Helper()
	box, err := cloud.CreateWarmServer(ctx, prov, warmTestSpec())
	if err != nil {
		t.Fatalf("seed warm box: %v", err)
	}
	if err := wc.Register(ctx, WarmServer{Name: box.Name, IP: box.IP}); err != nil {
		t.Fatalf("register seeded warm box: %v", err)
	}
	return box
}

func warmTestSpec() cloud.ServerSpec {
	return cloud.ServerSpec{Region: "nbg1", ServerType: "cx23", Image: "snap-test"}
}

func acmeJob() JobSpec {
	return JobSpec{JobID: "job-1", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cx23"}
}

// ── empty-pool fallback ──

func TestProvisionWith_EmptyPoolFallsBackToOneShot(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	wc := &fakeWarmClient{} // no ready rows → empty pool
	seams.WarmPoolSize = 2
	seams.WarmClient = wc
	ctx := context.Background()

	ip, _, _, teardown, err := ProvisionWith(ctx, seams, acmeJob())
	if err != nil {
		t.Fatalf("ProvisionWith (empty pool should one-shot): %v", err)
	}
	if ip == "" || teardown == nil {
		t.Fatal("empty-pool fallback did not produce a live one-shot host")
	}
	// Exactly ONE host, a one-shot bp-acme-<suffix> box (no warm box was assigned).
	hosts, _ := prov.List(ctx)
	if len(hosts) != 1 || !strings.HasPrefix(hosts[0].Name, "bp-acme-") {
		t.Fatalf("empty-pool fallback: want one bp-acme- one-shot box, got %+v", hosts)
	}
}

// ── warm assign happy path + async refill fired ──

func TestProvisionWith_WarmAssignHappyPathAndRefill(t *testing.T) {
	seams, prov, dns, runner := fakeSeams()
	wc := &fakeWarmClient{}
	ctx := context.Background()
	box := seedWarmBox(t, ctx, prov, wc)

	// Observe the async refill deterministically (no racing on a real create).
	refilled := make(chan struct{}, 1)
	seams.WarmPoolSize = 1
	seams.WarmClient = wc
	seams.WarmRefill = func(context.Context) { refilled <- struct{}{} }

	ip, _, _, _, err := ProvisionWith(ctx, seams, acmeJob())
	if err != nil {
		t.Fatalf("ProvisionWith (warm assign): %v", err)
	}

	// The assigned box IS the warm box (its IP) — no one-shot bp-acme box created.
	if ip != box.IP {
		t.Errorf("assigned IP = %q, want the warm box IP %q", ip, box.IP)
	}
	for _, h := range mustList(t, prov) {
		if strings.HasPrefix(h.Name, "bp-acme-") {
			t.Errorf("a one-shot box %q was created on the warm-assign happy path", h.Name)
		}
	}
	// DNS + migrate ran through the shared chain.
	if v, _ := dns.Resolve(ctx, "acme.barkpark.cloud"); len(v) != 1 || v[0] != box.IP {
		t.Errorf("DNS for acme = %v, want [%s]", v, box.IP)
	}
	if !sawStep(runner, "ecto.migrate") {
		t.Errorf("assign chain did not migrate; ran: %v", runner.cmds)
	}
	// The claimed row was consumed (deleted).
	if wc.statusOf(box.Name) != "" {
		t.Errorf("warm row for %q not deleted after assign (status=%q)", box.Name, wc.statusOf(box.Name))
	}
	// The async refill fired.
	select {
	case <-refilled:
	case <-time.After(2 * time.Second):
		t.Fatal("async refill did not fire after a successful claim")
	}
}

// ── assign failure → teardown + one-shot fallback ──

func TestProvisionWith_WarmAssignFailureFallsBackToOneShot(t *testing.T) {
	prov := cloud.NewFakeProvider()
	dns := cloud.NewFakeDNS()
	wc := &fakeWarmClient{}
	ctx := context.Background()
	box := seedWarmBox(t, ctx, prov, wc)

	// The warm box's configure FAILS (migrate step), the one-shot box's succeeds —
	// keyed on host IP so the assign tears down but the fallback stands up.
	seams := Seams{
		Provider: prov,
		DNS:      dns,
		Registry: NopRegistry{},
		Health:   greenGate,
		RunnerFor: func(host string) cloud.StepRunner {
			if host == box.IP {
				return &recordingRunner{failOn: "migrate"}
			}
			return &recordingRunner{}
		},
		HealthPollInterval: time.Millisecond,
		HealthPollDeadline: 30 * time.Millisecond,
		WarmPoolSize:       1,
		WarmClient:         wc,
		WarmRefill:         func(context.Context) {}, // no-op → deterministic IPs
	}

	ip, _, _, teardown, err := ProvisionWith(ctx, seams, acmeJob())
	if err != nil {
		t.Fatalf("ProvisionWith should fall back to one-shot after a failed assign: %v", err)
	}
	if teardown == nil {
		t.Fatal("one-shot fallback returned a nil teardown")
	}

	// The warm box was torn down; a one-shot bp-acme box stands in its place.
	hosts := mustList(t, prov)
	if len(hosts) != 1 {
		t.Fatalf("want exactly 1 host after teardown+fallback, got %d: %+v", len(hosts), hosts)
	}
	if !strings.HasPrefix(hosts[0].Name, "bp-acme-") {
		t.Errorf("surviving host = %q, want the one-shot bp-acme- box", hosts[0].Name)
	}
	if ip != hosts[0].IP {
		t.Errorf("returned IP %q != surviving one-shot box IP %q", ip, hosts[0].IP)
	}
	// The warm row was dropped (box consumed on the failed assign).
	if wc.rowCount() != 0 {
		t.Errorf("warm row not deleted after a failed assign: %d rows remain", wc.rowCount())
	}
}

// ── reconciler ──

func TestReconcileWarmPool_GrowsToSize(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 3)
	if err != nil {
		t.Fatalf("reconcile grow: %v", err)
	}
	if created != 3 || deleted != 0 {
		t.Errorf("grow: created=%d deleted=%d, want 3/0", created, deleted)
	}
	if got, _ := wc.CountReady(ctx); got != 3 {
		t.Errorf("ready rows = %d, want 3", got)
	}
	warm, _ := prov.ListByLabel(ctx, cloud.WarmLabelKey, "true")
	if len(warm) != 3 {
		t.Errorf("provider warm boxes = %d, want 3", len(warm))
	}
}

func TestReconcileWarmPool_ShrinksToSize(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	// Seed 5 ready boxes.
	for i := 0; i < 5; i++ {
		seedWarmBox(t, ctx, prov, wc)
	}

	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 2)
	if err != nil {
		t.Fatalf("reconcile shrink: %v", err)
	}
	if created != 0 || deleted != 3 {
		t.Errorf("shrink: created=%d deleted=%d, want 0/3", created, deleted)
	}
	if got, _ := wc.CountReady(ctx); got != 2 {
		t.Errorf("ready rows = %d, want 2", got)
	}
	warm, _ := prov.ListByLabel(ctx, cloud.WarmLabelKey, "true")
	if len(warm) != 2 {
		t.Errorf("provider warm boxes = %d, want 2 (3 retired)", len(warm))
	}
}

func TestReconcileWarmPool_NeverTouchesClaimedBoxes(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	// 2 ready + 1 CLAIMED (an in-flight assign). CountReady sees only the 2 ready.
	a := seedWarmBox(t, ctx, prov, wc)
	b := seedWarmBox(t, ctx, prov, wc)
	claimed := seedWarmBox(t, ctx, prov, wc)
	wc.markStatus(claimed.Name, "claimed")

	// Reconcile to 0 — must retire only the 2 ready, never the claimed box.
	created, deleted, err := ReconcileWarmPoolWith(ctx, seams, 0)
	if err != nil {
		t.Fatalf("reconcile to 0: %v", err)
	}
	if created != 0 || deleted != 2 {
		t.Errorf("created=%d deleted=%d, want 0/2 (the claimed box is untouched)", created, deleted)
	}
	// The claimed box's Hetzner box + row survive; the ready boxes are gone.
	if _, err := prov.IP(ctx, claimed.Name); err != nil {
		t.Errorf("the claimed (in-flight assign) box %q was deleted by the reconciler: %v", claimed.Name, err)
	}
	if wc.statusOf(claimed.Name) != "claimed" {
		t.Errorf("claimed row status = %q, want it left claimed", wc.statusOf(claimed.Name))
	}
	if _, err := prov.IP(ctx, a.Name); err == nil {
		t.Errorf("ready box %q should have been retired", a.Name)
	}
	if _, err := prov.IP(ctx, b.Name); err == nil {
		t.Errorf("ready box %q should have been retired", b.Name)
	}
}

// ── refill is async / non-blocking ──

func TestWarmRefill_AsyncDoesNotBlockAssign(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	wc := &fakeWarmClient{}
	ctx := context.Background()
	seedWarmBox(t, ctx, prov, wc)

	started := make(chan struct{})
	release := make(chan struct{})
	seams.WarmPoolSize = 1
	seams.WarmClient = wc
	// A refill that blocks until released — if the assign waited on it, ProvisionWith
	// would deadlock past the deadline below.
	seams.WarmRefill = func(context.Context) {
		close(started)
		<-release
	}

	done := make(chan error, 1)
	go func() {
		_, _, _, _, err := ProvisionWith(ctx, seams, acmeJob())
		done <- err
	}()

	// The refill must have STARTED (fired async) …
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("refill never started")
	}
	// … and ProvisionWith must RETURN while the refill is still blocked (not blocked on it).
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("ProvisionWith returned an error: %v", err)
		}
	case <-time.After(2 * time.Second):
		close(release)
		t.Fatal("ProvisionWith blocked on the async refill — it must not")
	}
	close(release)
}

func TestDefaultWarmRefill_CreatesAndRegisters(t *testing.T) {
	seams, prov, _, _ := fakeSeams()
	wc := &fakeWarmClient{}
	seams.WarmClient = wc
	ctx := context.Background()

	defaultWarmRefill(ctx, seams)

	warm, _ := prov.ListByLabel(ctx, cloud.WarmLabelKey, "true")
	if len(warm) != 1 {
		t.Fatalf("default refill created %d warm boxes, want 1", len(warm))
	}
	if got, _ := wc.CountReady(ctx); got != 1 {
		t.Errorf("default refill registered %d ready rows, want 1", got)
	}
}

// ── concurrent double-claim: one winner per row (Go-seam defense-in-depth) ──

func TestWarmClient_ConcurrentClaimOneWinnerPerRow(t *testing.T) {
	wc := &fakeWarmClient{}
	ctx := context.Background()
	const n = 8
	for i := 0; i < n; i++ {
		_ = wc.Register(ctx, WarmServer{Name: fmt.Sprintf("warm-race-%d", i), IP: fmt.Sprintf("10.0.0.%d", i)})
	}

	// 2n concurrent claimers over n rows — every winner must be DISTINCT, and no
	// row handed out twice.
	var wg sync.WaitGroup
	var mu sync.Mutex
	winners := map[string]int{}
	for i := 0; i < 2*n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ws, ok, err := wc.Claim(ctx)
			if err != nil || !ok {
				return
			}
			mu.Lock()
			winners[ws.Name]++
			mu.Unlock()
		}()
	}
	wg.Wait()

	if len(winners) != n {
		t.Errorf("distinct claimed boxes = %d, want %d", len(winners), n)
	}
	for name, count := range winners {
		if count != 1 {
			t.Errorf("box %q was claimed %d times — a double-claim (must be exactly 1)", name, count)
		}
	}
	if got, _ := wc.CountReady(ctx); got != 0 {
		t.Errorf("ready rows after draining = %d, want 0", got)
	}
}

// ── HTTP client transport ──

func TestHTTPWarmPoolClient_RoundTrip(t *testing.T) {
	var gotAuth string
	var gotPaths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPaths = append(gotPaths, r.Method+" "+r.URL.Path)
		switch {
		case r.URL.Path == warmClaimPath:
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"name":"warm-x","ip":"10.1.2.3"}`))
		case r.URL.Path == warmClaimRetirePath:
			w.WriteHeader(204)
		case r.URL.Path == warmCountPath:
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"ready":4}`))
		default:
			w.WriteHeader(201)
			_, _ = w.Write([]byte(`{"ok":true}`))
		}
	}))
	defer srv.Close()

	c := &HTTPWarmPoolClient{ControlURL: srv.URL, Token: "sekret"}
	ctx := context.Background()

	ws, ok, err := c.Claim(ctx)
	if err != nil || !ok || ws.Name != "warm-x" || ws.IP != "10.1.2.3" {
		t.Fatalf("Claim = %+v ok=%v err=%v, want warm-x/10.1.2.3", ws, ok, err)
	}
	if _, ok, err := c.ClaimForRetire(ctx); err != nil || ok {
		t.Fatalf("ClaimForRetire (204) = ok=%v err=%v, want ok=false", ok, err)
	}
	if n, err := c.CountReady(ctx); err != nil || n != 4 {
		t.Fatalf("CountReady = %d err=%v, want 4", n, err)
	}
	if err := c.Register(ctx, WarmServer{Name: "warm-y", IP: "10.9.9.9"}); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if err := c.Delete(ctx, "warm-y"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if gotAuth != "Bearer sekret" {
		t.Errorf("Authorization = %q, want Bearer sekret", gotAuth)
	}
	joined := strings.Join(gotPaths, " | ")
	for _, want := range []string{
		"POST " + warmClaimPath,
		"POST " + warmClaimRetirePath,
		"GET " + warmCountPath,
		"POST " + warmRegisterPath,
		"DELETE " + warmRegisterPath + "/warm-y",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing request %q; saw: %s", want, joined)
		}
	}
}

// mustList lists provider hosts or fails the test.
func mustList(t *testing.T, prov *cloud.FakeProvider) []cloud.Server {
	t.Helper()
	hosts, err := prov.List(context.Background())
	if err != nil {
		t.Fatalf("provider List: %v", err)
	}
	return hosts
}

// sawStep reports whether any recorded step command contains sub.
func sawStep(r *recordingRunner, sub string) bool {
	for _, c := range r.cmds {
		if strings.Contains(c, sub) {
			return true
		}
	}
	return false
}
