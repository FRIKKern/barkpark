package setup

import (
	"regexp"
	"strings"
	"testing"
)

// TestGenerateAdminTokenFormat pins the token shape the clean seed and the
// docs promise: bp_admin_ + 32 base64url chars (24 random bytes).
func TestGenerateAdminTokenFormat(t *testing.T) {
	re := regexp.MustCompile(`^bp_admin_[A-Za-z0-9_-]{32}$`)
	seen := map[string]bool{}
	for i := 0; i < 8; i++ {
		tok, err := GenerateAdminToken()
		if err != nil {
			t.Fatalf("GenerateAdminToken: %v", err)
		}
		if !re.MatchString(tok) {
			t.Fatalf("token %q does not match %s", tok, re)
		}
		if seen[tok] {
			t.Fatalf("token %q repeated — not random", tok)
		}
		seen[tok] = true
	}
}

// TestBuildLocalPlanCarriesProfileAndRedactsToken: the structured local plan
// defaults to the clean profile, threads BARKPARK_SEED_PROFILE, and only ever
// shows the redacted admin-token placeholder (generation is execute-time).
func TestBuildLocalPlanCarriesProfileAndRedactsToken(t *testing.T) {
	p := buildLocalPlan(SetupPlan{Target: TargetLocal}, Options{})
	if p.Profile != ProfileClean {
		t.Fatalf("Profile = %q, want %q (default)", p.Profile, ProfileClean)
	}
	if p.Env["BARKPARK_SEED_PROFILE"] != ProfileClean {
		t.Fatalf("Env[BARKPARK_SEED_PROFILE] = %q, want clean", p.Env["BARKPARK_SEED_PROFILE"])
	}
	if p.Env["BARKPARK_SEED_ADMIN_TOKEN"] != "****" {
		t.Fatalf("Env[BARKPARK_SEED_ADMIN_TOKEN] = %q, want the **** redaction", p.Env["BARKPARK_SEED_ADMIN_TOKEN"])
	}
	for _, s := range p.Steps {
		if strings.Contains(s.Command, "bp_admin_") {
			t.Fatalf("plan step leaks a token: %q", s.Command)
		}
	}
}

// TestBuildLocalPlanDemoProfile: --profile demo rides through and mints no
// admin-token env at all (the demo seed keeps the dev token).
func TestBuildLocalPlanDemoProfile(t *testing.T) {
	p := buildLocalPlan(SetupPlan{Target: TargetLocal, Profile: ProfileDemo}, Options{})
	if p.Profile != ProfileDemo {
		t.Fatalf("Profile = %q, want demo", p.Profile)
	}
	if _, ok := p.Env["BARKPARK_SEED_ADMIN_TOKEN"]; ok {
		t.Fatalf("demo plan must not carry BARKPARK_SEED_ADMIN_TOKEN, env=%v", p.Env)
	}
}

// TestValidateRejectsUnknownProfile: an unknown --profile is a validation
// error (the CLI maps it to a usage error, exit 2).
func TestValidateRejectsUnknownProfile(t *testing.T) {
	err := SetupPlan{Target: TargetLocal, Profile: "bogus"}.Validate()
	if err == nil || !strings.Contains(err.Error(), "--profile") {
		t.Fatalf("Validate = %v, want a --profile error", err)
	}
}

// TestLocalSeedStepThreadsRealEnv: on a real run the seed step carries the
// live BARKPARK_SEED_* env while the display line stays redacted.
func TestLocalSeedStepThreadsRealEnv(t *testing.T) {
	tok, err := GenerateAdminToken()
	if err != nil {
		t.Fatalf("GenerateAdminToken: %v", err)
	}
	steps := localSteps(SetupPlan{Target: TargetLocal}, resolveLocalContext(), "", false, tok)
	var seed *localStep
	for i := range steps {
		if strings.Contains(steps[i].Title, "reset + seed") {
			seed = &steps[i]
		}
	}
	if seed == nil {
		t.Fatalf("no seed step in %v", steps)
	}
	wantEnv := map[string]bool{
		"BARKPARK_SEED_PROFILE=clean":      false,
		"BARKPARK_SEED_ADMIN_TOKEN=" + tok: false,
	}
	for _, kv := range seed.Env {
		if _, ok := wantEnv[kv]; ok {
			wantEnv[kv] = true
		}
	}
	for kv, ok := range wantEnv {
		if !ok {
			t.Fatalf("seed step env missing %q (env=%v)", kv, seed.Env)
		}
	}
	if strings.Contains(seed.EnvLine, tok) {
		t.Fatalf("EnvLine leaks the live token: %q", seed.EnvLine)
	}
	if !strings.Contains(seed.EnvLine, "BARKPARK_SEED_ADMIN_TOKEN=****") {
		t.Fatalf("EnvLine missing the redacted token marker: %q", seed.EnvLine)
	}
}
