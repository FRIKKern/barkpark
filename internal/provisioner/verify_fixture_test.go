package provisioner

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// verifyProbesFixturePath is the shared probe-vocabulary fixture
// (cloud/priv/static/__fixtures__/verify_probes.json) — the SAME file the
// Elixir on-demand executor (BarkparkCloud.Verify.probes/0) asserts itself
// against. It lives under the cloud app but is READ from Go here, exactly like
// the hetzner_overview.json golden: this test package is two dirs deep
// (internal/provisioner → repo root → cloud/priv/static/__fixtures__).
//
// This is the D53 one-fixture-two-asserters tripwire: the provisioner's compiled
// VERIFY gate (verify.go, #1003) and the Elixir re-runnable executor MUST speak
// the same probe vocabulary in the same order, or a box's birth certificate and
// its on-demand re-issue would disagree. The fixture is the single source; a
// drift on EITHER side reds a gate. It is also the ratified tripwire for the
// verify.login `status < 500` rule — if /v1/auth/login ever drifts to a 404
// (moved/removed), this pinned rule is where the weakening surfaces.
var verifyProbesFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "verify_probes.json")

type verifyProbeSpec struct {
	Name     string `json:"name"`
	Label    string `json:"label"`
	PassRule string `json:"pass_rule"`
}

type verifyProbesFixture struct {
	Probes []verifyProbeSpec `json:"probes"`
}

func readVerifyProbesFixture(t *testing.T) verifyProbesFixture {
	t.Helper()
	raw, err := os.ReadFile(verifyProbesFixturePath)
	if err != nil {
		t.Fatalf("read verify_probes.json fixture: %v", err)
	}
	var fx verifyProbesFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode verify_probes.json: %v", err)
	}
	return fx
}

// TestVerifyFixtureIsWellFormed pins the fixture's own shape: exactly three
// probes, each with a non-empty name/label/pass-rule, in the gate order. A typo
// or a dropped field reds here before any executor even runs.
func TestVerifyFixtureIsWellFormed(t *testing.T) {
	fx := readVerifyProbesFixture(t)

	wantNames := []string{"verify.api", "verify.login", "verify.studio"}
	if len(fx.Probes) != len(wantNames) {
		t.Fatalf("fixture has %d probes, want %d: %+v", len(fx.Probes), len(wantNames), fx.Probes)
	}
	for i, p := range fx.Probes {
		if p.Name != wantNames[i] {
			t.Errorf("probe[%d].name = %q, want %q", i, p.Name, wantNames[i])
		}
		if p.Label == "" {
			t.Errorf("probe[%d] (%s) has an empty label", i, p.Name)
		}
		if p.PassRule == "" {
			t.Errorf("probe[%d] (%s) has an empty pass_rule", i, p.Name)
		}
	}

	// The verify.login <500 rule is the #957 guard — pin its exact wording so a
	// silent weakening (e.g. to "== 401") is a visible diff, not a quiet drift.
	if got := probeRule(fx, "verify.login"); got != "status < 500" {
		t.Errorf("verify.login pass_rule = %q, want %q (the #957 dead-on-arrival guard)", got, "status < 500")
	}
	if got := probeRule(fx, "verify.api"); got != "status == 200" {
		t.Errorf("verify.api pass_rule = %q, want %q", got, "status == 200")
	}
}

// TestProvisionerProbeVocabularyMatchesFixture is the actual cross-asserter: it
// runs the Go gate's COMPILED probes (the same functions runVerifyGate dispatches,
// in the same order) against an all-green fake instance and collects the name
// each one narrates, then asserts that ordered vocabulary equals the fixture.
// No behavior change to the worker — this reads the gate as-shipped.
func TestProvisionerProbeVocabularyMatchesFixture(t *testing.T) {
	fx := readVerifyProbesFixture(t)

	inst := newFakeInstance(t, fakeInstanceBehavior{})
	cfg := verifyConfig{baseURL: inst.URL, probeTimeout: 2 * time.Second, totalBudget: 5 * time.Second}
	client := &http.Client{
		Timeout: cfg.probeTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	// The gate's dispatch order (runVerifyGate iterates exactly this slice).
	probes := []func(context.Context, verifyConfig, *http.Client) probeOutcome{
		verifyAPI, verifyLogin, verifyStudio,
	}

	var gotNames []string
	for _, probe := range probes {
		out := probe(context.Background(), cfg, client)
		gotNames = append(gotNames, out.name)
	}

	var wantNames []string
	for _, p := range fx.Probes {
		wantNames = append(wantNames, p.Name)
	}

	if len(gotNames) != len(wantNames) {
		t.Fatalf("gate ran %d probes %v, fixture pins %d %v", len(gotNames), gotNames, len(wantNames), wantNames)
	}
	for i := range wantNames {
		if gotNames[i] != wantNames[i] {
			t.Errorf("probe[%d]: gate narrates %q, fixture pins %q", i, gotNames[i], wantNames[i])
		}
	}
}

func probeRule(fx verifyProbesFixture, name string) string {
	for _, p := range fx.Probes {
		if p.Name == name {
			return p.PassRule
		}
	}
	return ""
}
