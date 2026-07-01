package provisioner

// dwb-4 wiring tests: the content bootstrap's place in the provision chain and
// on the worker's succeed wire. The bootstrap ITSELF is tested in
// internal/bootstrap; here we prove (a) ProvisionWith runs it exactly when a
// job carries a template, with the right request, (b) a bootstrap failure tears
// the box down and fails through the EXISTING machinery (no new failure
// plumbing), and (c) the outputs ride the succeed body to the control plane.

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestProvisionWithTemplateRunsBootstrap proves a template job runs the
// injected bootstrap AFTER the chain (health gate + admin token already done)
// with the instance FQDN + admin token + job identity, and surfaces the outputs.
func TestProvisionWithTemplateRunsBootstrap(t *testing.T) {
	seams, prov, _, _ := fakeSeams()

	var got BootstrapRequest
	want := &BootstrapOutputs{
		Template: "place-directory", Workspace: "acme", Project: "default",
		Dataset: "production", ReadToken: "bp_read_x",
		Env: map[string]string{"BARKPARK_TOKEN": "bp_read_x"},
	}
	seams.Bootstrap = func(_ context.Context, req BootstrapRequest) (*BootstrapOutputs, error) {
		got = req
		return want, nil
	}

	job := JobSpec{JobID: "job-t", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "place-directory"}
	ip, adminToken, boot, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}
	if boot != want {
		t.Fatalf("boot = %+v, want the bootstrap's outputs", boot)
	}
	if teardown == nil || ip == "" {
		t.Fatal("success must still return a live ip + teardown")
	}

	// ── the bootstrap request is the instance's PUBLIC origin + the chain's
	// admin token + the job identity ──
	if got.BaseURL != "https://acme.barkpark.cloud" {
		t.Errorf("bootstrap BaseURL = %q, want https://acme.barkpark.cloud", got.BaseURL)
	}
	if got.AdminToken != adminToken || !strings.HasPrefix(got.AdminToken, "bp_admin_") {
		t.Errorf("bootstrap AdminToken = %q, want the chain's minted admin token %q", got.AdminToken, adminToken)
	}
	if got.Template != "place-directory" || got.WorkspaceName != "Acme Co" || got.WorkspaceSlug != "acme" {
		t.Errorf("bootstrap request identity = %+v, want the job's template/name/slug", got)
	}

	// The box survives (one live server).
	if hosts, _ := prov.List(context.Background()); len(hosts) != 1 {
		t.Errorf("after a bootstrapped provision want 1 server, got %d", len(hosts))
	}
}

// TestProvisionWithoutTemplateSkipsBootstrap locks backward compatibility: no
// template on the job → the bootstrap seam is NEVER invoked and outputs are nil
// (the pre-dwb-4 behavior exactly).
func TestProvisionWithoutTemplateSkipsBootstrap(t *testing.T) {
	seams, _, _, _ := fakeSeams()
	called := false
	seams.Bootstrap = func(context.Context, BootstrapRequest) (*BootstrapOutputs, error) {
		called = true
		return &BootstrapOutputs{}, nil
	}

	_, _, boot, _, err := ProvisionWith(context.Background(), seams, JobSpec{JobID: "j", Name: "Plain", Slug: "plain", Region: "nbg1", ServerType: "cax11"})
	if err != nil {
		t.Fatalf("ProvisionWith: %v", err)
	}
	if called {
		t.Error("bootstrap ran for a job with NO template — must be skipped")
	}
	if boot != nil {
		t.Errorf("boot = %+v, want nil for a template-less job", boot)
	}
}

// TestProvisionWithBootstrapFailureTearsDown is the "never silently half-alive"
// guarantee: a red bootstrap makes ProvisionWith tear the (healthy!) box + DNS
// down and return an error with a NIL teardown — exactly the shape every other
// in-chain failure has, so the worker's EXISTING fail path (fail report →
// reaper retry → attempts cap) handles it with no new plumbing.
func TestProvisionWithBootstrapFailureTearsDown(t *testing.T) {
	seams, prov, dns, _ := fakeSeams()
	seams.Bootstrap = func(context.Context, BootstrapRequest) (*BootstrapOutputs, error) {
		return nil, errString("schema apply: status 500")
	}

	job := JobSpec{JobID: "job-b", Name: "Boom", Slug: "boom", Region: "nbg1", ServerType: "cax11", Template: "place-directory"}
	ip, _, boot, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err == nil {
		t.Fatal("ProvisionWith with a red bootstrap returned nil, want an error (the job must FAIL, not half-succeed)")
	}
	if ip != "" || boot != nil || teardown != nil {
		t.Errorf("red bootstrap returned (ip=%q boot=%v teardown non-nil=%v), want all zero — the box is gone", ip, boot, teardown != nil)
	}
	if !strings.Contains(err.Error(), "bootstrap") {
		t.Errorf("error %q does not name the bootstrap step", err)
	}

	// ── the healthy-but-unbootstrapped box was DELETED (server + DNS) ──
	if hosts, _ := prov.List(context.Background()); len(hosts) != 0 {
		t.Errorf("bootstrap failure left %d servers, want 0 (never a silently half-alive box): %+v", len(hosts), hosts)
	}
	if values, _ := dns.Resolve(context.Background(), "boom.barkpark.cloud"); len(values) != 0 {
		t.Errorf("bootstrap failure left DNS %v, want none", values)
	}
}

// TestRunOnceForwardsBootstrapOnSucceed proves the worker forwards the
// bootstrap outputs in the succeed body — the control plane's ONLY chance to
// store them — and that the read token never appears outside that body.
func TestRunOnceForwardsBootstrapOnSucceed(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-bp", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "website-starter"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	boot := &BootstrapOutputs{
		Template: "website-starter", Workspace: "acme", Project: "default",
		Dataset: "production", ReadToken: "bp_read_secret",
		Env: map[string]string{"BARKPARK_TOKEN": "bp_read_secret", "BARKPARK_DATASET": "production"},
	}
	var gotTemplate string
	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(_ context.Context, spec JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			gotTemplate = spec.Template
			return "203.0.113.20", "bp_admin_x", boot, func(context.Context) error { return nil }, nil
		},
	}

	claimed, err := w.RunOnce(context.Background())
	if err != nil || !claimed {
		t.Fatalf("RunOnce = (%v, %v), want (true, nil)", claimed, err)
	}

	// ── the claim's template reached Provision (the JSON contract) ──
	if gotTemplate != "website-starter" {
		t.Errorf("Provision got template %q, want website-starter", gotTemplate)
	}

	// ── the succeed body carries ip + admin_token + the FULL bootstrap object ──
	if cp.succeededIP != "203.0.113.20" || cp.succeededAdminToken != "bp_admin_x" {
		t.Errorf("succeed ip/admin_token = %q/%q — the pre-bootstrap fields must be unchanged", cp.succeededIP, cp.succeededAdminToken)
	}
	var body struct {
		Bootstrap struct {
			Template  string            `json:"template"`
			Workspace string            `json:"workspace"`
			Project   string            `json:"project"`
			Dataset   string            `json:"dataset"`
			ReadToken string            `json:"read_token"`
			Env       map[string]string `json:"env"`
		} `json:"bootstrap"`
	}
	if err := json.Unmarshal(cp.succeededRawBody, &body); err != nil {
		t.Fatalf("decode succeed body: %v", err)
	}
	b := body.Bootstrap
	if b.Template != "website-starter" || b.Workspace != "acme" || b.Project != "default" ||
		b.Dataset != "production" || b.ReadToken != "bp_read_secret" {
		t.Errorf("succeed bootstrap = %+v, want the provision's outputs", b)
	}
	if b.Env["BARKPARK_TOKEN"] != "bp_read_secret" || b.Env["BARKPARK_DATASET"] != "production" {
		t.Errorf("succeed bootstrap env = %v, want the resolved env map", b.Env)
	}
}

// TestRunOnceNoBootstrapKeepsBodyLean locks the wire back-compat: a nil
// bootstrap (no template) produces a succeed body with NO `bootstrap` key at
// all — an old control plane sees exactly the old shape.
func TestRunOnceNoBootstrapKeepsBodyLean(t *testing.T) {
	cp := &fakeControlPlane{
		wantToken: testToken,
		job:       &JobSpec{JobID: "job-nb", Name: "acme", Slug: "acme", Region: "nbg1", ServerType: "cax11"},
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	w := &Worker{
		ControlURL: srv.URL,
		Token:      testToken,
		HTTPClient: srv.Client(),
		Provision: func(context.Context, JobSpec) (string, string, *BootstrapOutputs, Teardown, error) {
			return "203.0.113.21", "", nil, func(context.Context) error { return nil }, nil
		},
	}
	if claimed, err := w.RunOnce(context.Background()); err != nil || !claimed {
		t.Fatalf("RunOnce = (%v, %v), want (true, nil)", claimed, err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(cp.succeededRawBody, &raw); err != nil {
		t.Fatalf("decode succeed body: %v", err)
	}
	if _, has := raw["bootstrap"]; has {
		t.Errorf("succeed body carries a bootstrap key for a template-less job: %s", cp.succeededRawBody)
	}
}
