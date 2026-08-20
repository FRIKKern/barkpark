package main

import "testing"

func TestAgentHealthGateOpts(t *testing.T) {
	got := agentHealthGateOpts("https://box.example.com", "")
	if !got.StubsOptional {
		t.Fatal("agent health gate must treat unwired agent/backup stubs as optional")
	}
	if got.PostgresProbeURL != "https://box.example.com/status.json" {
		t.Fatalf("PostgresProbeURL = %q, want public status DB probe", got.PostgresProbeURL)
	}
	if !got.RequireDatabaseStatusOperational {
		t.Fatal("agent health gate must require the public database status to be operational")
	}
	if got.Token != "" {
		t.Fatalf("Token = %q, want empty when no instance health token is configured", got.Token)
	}
}

// TestResolveSitesDir pins the precedence of the sites root and, more
// importantly, that the FALLBACK is a real answer the payload can report.
// BARKPARK_SITES_DIR is set on no box in the fleet, so every box today takes
// the default branch; a fallback nobody can see is a wrong number nobody can
// explain (charter D59).
func TestResolveSitesDir(t *testing.T) {
	cases := []struct {
		name       string
		flag, env  string
		want       string
		wantIsFlag bool
	}{
		{name: "flag wins", flag: "/srv/sites", env: "/other", want: "/srv/sites"},
		{name: "env when no flag", env: "/var/sites", want: "/var/sites"},
		{name: "default on every box today", want: defaultSitesDir},
		{name: "blank env is not a directory", env: "   ", want: defaultSitesDir},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := resolveSitesDir(c.flag, c.env); got != c.want {
				t.Errorf("resolveSitesDir(%q, %q) = %q, want %q", c.flag, c.env, got, c.want)
			}
		})
	}
	if resolveSitesDir("", "") == "" {
		t.Fatal("resolveSitesDir must never return empty — an unwired probe would report no path at all")
	}
}
