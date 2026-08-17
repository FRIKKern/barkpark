package setup

import (
	"strings"
	"testing"
)

// The deploy path threads BARKPARK_CLOUD_URL — the CONTROL-PLANE ORIGIN CONSTANT
// https://barkpark.cloud — into the ssh env prefix so deploy.sh persists it onto
// boxes provisioned before caddy.go's go-live step started stamping it. These
// tests pin the value to the constant and pin that it is NOT derived from
// PHX_SCHEME://DOMAIN (charter D40 refutes the D31 self-referential derivation).

func TestBuildDeployPlanThreadsCloudURL(t *testing.T) {
	plan := SetupPlan{
		Target:  TargetDeploy,
		SSHHost: "root@1.2.3.4",
		Domain:  "gyldendal.barkpark.cloud",
		Scheme:  "https",
	}
	p, err := buildDeployPlan(plan, Options{})
	if err != nil {
		t.Fatalf("buildDeployPlan: %v", err)
	}

	got := p.Env["BARKPARK_CLOUD_URL"]
	if got != "https://barkpark.cloud" {
		t.Errorf("Env[BARKPARK_CLOUD_URL] = %q, want the control-plane origin constant https://barkpark.cloud", got)
	}

	// It must NOT be the self-referential PHX_SCHEME://DOMAIN deep-link.
	if selfRef := plan.Scheme + "://" + plan.Domain; got == selfRef {
		t.Errorf("BARKPARK_CLOUD_URL derived as %q (PHX_SCHEME://DOMAIN) — must be the fixed control-plane origin, not the instance's own host", selfRef)
	}

	// The rendered installer step must carry the env in its command line so the
	// remote bash actually receives it.
	var seen bool
	for _, s := range p.Steps {
		if strings.Contains(s.Command, "BARKPARK_CLOUD_URL=https://barkpark.cloud") {
			seen = true
			break
		}
	}
	if !seen {
		t.Errorf("no plan step carries BARKPARK_CLOUD_URL=https://barkpark.cloud in its command; steps=%+v", p.Steps)
	}
}
