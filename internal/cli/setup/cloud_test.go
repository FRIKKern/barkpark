package setup

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestCloudTargetIsKnownAndDispatches: TargetCloud validates as a known target
// and Execute routes it to executeCloud (proven by the nil-hook error, which is
// executeCloud's — Validate itself never rejects a present hook it cannot see).
func TestCloudTargetValidatesAsKnownTarget(t *testing.T) {
	if err := (SetupPlan{Target: TargetCloud}).Validate(); err != nil {
		t.Fatalf("TargetCloud should validate as a known target, got: %v", err)
	}
}

// TestCloudNilHookRejected: Execute of TargetCloud with no CloudLogin hook wired
// is a clear error (a non-CLI embedding) — never a nil-deref or a silent no-op.
func TestCloudNilHookRejected(t *testing.T) {
	err := Execute(SetupPlan{Target: TargetCloud}, Options{})
	if err == nil {
		t.Fatal("expected an error when TargetCloud runs with no CloudLogin hook, got nil")
	}
	if !strings.Contains(err.Error(), "no Barkpark Cloud login is wired") {
		t.Fatalf("nil-hook error should name the missing login, got: %s", err.Error())
	}

	// BuildPlan (JSON dry-run) rejects the nil hook the same way.
	if _, berr := BuildPlan(SetupPlan{Target: TargetCloud}, Options{}); berr == nil {
		t.Fatal("BuildPlan of TargetCloud with no hook should error, got nil")
	}
}

// TestCloudHookDelegatesToConnect: a hook that returns a picked Barkpark's
// server + token makes executeCloud delegate to the UNCHANGED connect path — the
// server is probed and persisted through the store, so bp defaults there.
func TestCloudHookDelegatesToConnect(t *testing.T) {
	// A minimal barkpark: /v1/capabilities echoes an admin tier for the token.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth_tier":"admin","manifest_version":"1","server":{"name":"my-park","version":"1.2.3"},"commands":[]}`))
	}))
	defer srv.Close()

	store := &memConfigStore{}
	hook := func(_ Options) (CloudLoginResult, error) {
		return CloudLoginResult{Server: srv.URL, Token: "picked-admin-token", Name: "my-park"}, nil
	}

	err := Execute(SetupPlan{Target: TargetCloud}, Options{Store: store, CloudLogin: hook})
	if err != nil {
		t.Fatalf("cloud → connect delegation should succeed, got: %v", err)
	}
	if store.saved == nil {
		t.Fatal("delegation must persist the connection through the store")
	}
	if store.saved.Server != srv.URL {
		t.Fatalf("saved server = %q, want %q", store.saved.Server, srv.URL)
	}
	if store.saved.Token != "picked-admin-token" {
		t.Fatalf("saved token = %q, want the picked admin token", store.saved.Token)
	}
	if store.saved.Name != "my-park" {
		t.Fatalf("saved name = %q, want the barkpark name carried through", store.saved.Name)
	}
	if store.saved.Tier != "admin" {
		t.Fatalf("saved tier = %q, want the probed admin tier", store.saved.Tier)
	}
}

// TestCloudHookLoggedInOnlyIsCompleteNotDeadEnd: a logged-in-only result (empty
// fleet / no selection) finishes cleanly WITHOUT connecting or persisting — being
// logged in is a valid end state, not an error.
func TestCloudHookLoggedInOnlyIsCompleteNotDeadEnd(t *testing.T) {
	store := &memConfigStore{}
	hook := func(_ Options) (CloudLoginResult, error) {
		return CloudLoginResult{LoggedInOnly: true}, nil
	}
	if err := Execute(SetupPlan{Target: TargetCloud}, Options{Store: store, CloudLogin: hook}); err != nil {
		t.Fatalf("logged-in-only should be a clean success, got: %v", err)
	}
	if store.saved != nil {
		t.Fatalf("logged-in-only must NOT persist a connection, saved: %+v", store.saved)
	}
}

// TestCloudHookErrorPropagates: a hook error (login/pick failure) surfaces from
// Execute rather than being swallowed.
func TestCloudHookErrorPropagates(t *testing.T) {
	hook := func(_ Options) (CloudLoginResult, error) {
		return CloudLoginResult{}, errFake
	}
	err := Execute(SetupPlan{Target: TargetCloud}, Options{CloudLogin: hook})
	if err != errFake {
		t.Fatalf("hook error should propagate verbatim, got: %v", err)
	}
}

// TestCloudDryRunNeverCallsHook: a dry run describes the flow without logging in
// — the hook must never fire (no network, no browser).
func TestCloudDryRunNeverCallsHook(t *testing.T) {
	called := false
	hook := func(_ Options) (CloudLoginResult, error) {
		called = true
		return CloudLoginResult{LoggedInOnly: true}, nil
	}
	if err := Execute(SetupPlan{Target: TargetCloud}, Options{DryRun: true, CloudLogin: hook}); err != nil {
		t.Fatalf("cloud dry-run should succeed, got: %v", err)
	}
	if called {
		t.Fatal("cloud dry-run must NOT invoke the CloudLogin hook")
	}
}

// TestBuildCloudPlanDescribesFlow: the structured dry-run carries the three
// login → pick → connect steps for a JSON consumer.
func TestBuildCloudPlanDescribesFlow(t *testing.T) {
	hook := func(_ Options) (CloudLoginResult, error) { return CloudLoginResult{}, nil }
	p, err := BuildPlan(SetupPlan{Target: TargetCloud}, Options{CloudLogin: hook})
	if err != nil {
		t.Fatalf("BuildPlan cloud should succeed with a hook, got: %v", err)
	}
	if p.Target != TargetCloud {
		t.Fatalf("plan target = %q, want cloud", p.Target)
	}
	if len(p.Steps) != 3 {
		t.Fatalf("cloud plan should have 3 steps, got %d", len(p.Steps))
	}
}

var errFake = fakeErr("boom")

type fakeErr string

func (e fakeErr) Error() string { return string(e) }

// ── wizard target coverage ──

// TestWizardCloudTargetRowAtPositionTwo: the target list shows "Barkpark Cloud"
// at position 2 (index 1) with its blurb.
func TestWizardCloudTargetRowAtPositionTwo(t *testing.T) {
	if len(targetChoices) < 2 {
		t.Fatal("expected at least two target choices")
	}
	if targetChoices[1].target != TargetCloud {
		t.Fatalf("position 2 target = %q, want cloud", targetChoices[1].target)
	}
	if targetChoices[1].label != "Barkpark Cloud" {
		t.Fatalf("position 2 label = %q, want \"Barkpark Cloud\"", targetChoices[1].label)
	}
	view := newWizardModel(nil).viewTarget()
	if !strings.Contains(view, "Barkpark Cloud") || !strings.Contains(view, "log in and pick your barkpark") {
		t.Fatalf("target view missing the cloud row:\n%s", view)
	}
}

// TestWizardCloudSelectionShortCircuits: picking Barkpark Cloud (down once, enter)
// jumps straight to confirm — no inputs, profile, or plugins — and the assembled
// plan is the bare cloud target.
func TestWizardCloudSelectionShortCircuits(t *testing.T) {
	m := newWizardModel(nil)
	m = drive(m, "down", "enter") // Connect → Barkpark Cloud → enter

	if m.stage != stageConfirm {
		t.Fatalf("cloud selection should short-circuit to confirm, got stage %d", m.stage)
	}
	p := m.plan()
	if p.Target != TargetCloud {
		t.Fatalf("plan target = %q, want cloud", p.Target)
	}
	if p.Server != "" || p.Token != "" || len(p.Plugins) != 0 || p.Profile != "" {
		t.Fatalf("cloud plan should be the bare target, got %+v", p)
	}
	// The confirm view names the login action and shows no plugins line.
	view := m.viewConfirm()
	if !strings.Contains(view, "log in to Barkpark Cloud") {
		t.Fatalf("cloud confirm view should describe the login action:\n%s", view)
	}
	if strings.Contains(view, "plugins:") {
		t.Fatalf("cloud confirm view should not show a plugins line:\n%s", view)
	}
}
