package setup

import (
	"strings"
	"testing"
)

// The generated seed admin token never rides a process command line: an argv is
// visible to every user of the machine in `ps` while the step runs (r2-lane-b Go
// secret-exposure audit). It still reaches the seed — through the child's
// environment (native + docker) or an stdin preamble (ssh).
const seedTokenFixture = "bp_admin_FIXTURE_NOT_A_REAL_TOKEN"

func TestLocalSeedTokenNeverInArgv(t *testing.T) {
	lc := localContext{root: "/tmp/x", apiDir: "/tmp/x/api"}
	for _, docker := range []bool{false, true} {
		steps := localSteps(SetupPlan{Target: TargetLocal, Docker: docker, Profile: ProfileClean}, lc, "", false, seedTokenFixture)
		reached := false
		for _, s := range steps {
			for _, a := range s.Argv {
				if strings.Contains(a, seedTokenFixture) {
					t.Fatalf("docker=%v: step %q carries the admin token in its argv: %q", docker, s.Title, s.Argv)
				}
			}
			if strings.Contains(s.Cmd, seedTokenFixture) || strings.Contains(s.EnvLine, seedTokenFixture) {
				t.Fatalf("docker=%v: step %q renders the admin token", docker, s.Title)
			}
			for _, e := range s.Env {
				if e == "BARKPARK_SEED_ADMIN_TOKEN="+seedTokenFixture {
					reached = true
				}
			}
		}
		if !reached {
			t.Fatalf("docker=%v: no step hands the seed the admin token through its environment", docker)
		}
	}
}

func TestSSHInstallerTokenRidesStdinNotArgv(t *testing.T) {
	prefix := "DOMAIN=x.example PHX_SCHEME=https BARKPARK_SEED_PROFILE=clean BARKPARK_SEED_ADMIN_TOKEN=****"
	s, preamble := sshInstallerInvocation("root@host", prefix, seedTokenFixture)
	for _, a := range s.Argv {
		if strings.Contains(a, seedTokenFixture) {
			t.Fatalf("ssh argv carries the admin token: %q", s.Argv)
		}
		if strings.Contains(a, "BARKPARK_SEED_ADMIN_TOKEN") {
			t.Fatalf("ssh argv still names the token variable (it would override the stdin export): %q", s.Argv)
		}
	}
	if !strings.Contains(s.Argv[2], "BARKPARK_SEED_PROFILE=clean") || !strings.HasSuffix(s.Argv[2], " bash -s") {
		t.Fatalf("the rest of the env prefix must survive: %q", s.Argv[2])
	}
	if preamble != "export BARKPARK_SEED_ADMIN_TOKEN='"+seedTokenFixture+"'\n" {
		t.Fatalf("the token must reach the remote shell as an stdin export, got %q", preamble)
	}
	if _, none := sshInstallerInvocation("root@host", prefix, ""); none != "" {
		t.Fatalf("no token, no preamble: got %q", none)
	}
}
