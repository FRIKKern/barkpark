package main

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/agent"
)

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

// TestResolveConsumerRoots pins the precedence of the extra consumer roots and,
// more importantly, the two answers that are easy to get wrong:
//
//   - "" is NOT "measure nothing" — it is "use the defaults", because that is
//     what every box in the fleet sends today (no unit file names roots), and a
//     silent nothing there would ship the axis switched off.
//   - "none" IS "measure nothing", spelled, so the defaults are removable by an
//     operator who means it rather than by an accident.
//
// It also pins that a nonexistent path SURVIVES resolution. A root that is not
// on this box is a reportable fact (`absent`); dropping it here would restore
// the exact invisibility the axis exists to end.
func TestResolveConsumerRoots(t *testing.T) {
	cases := []struct {
		name string
		flag string
		env  string
		want []string
	}{
		{name: "nothing said takes the build-plane defaults", want: agent.DefaultConsumerRoots},
		{name: "blank env is not a configuration", env: "   ", want: agent.DefaultConsumerRoots},
		{name: "flag wins over env", flag: "/srv/a", env: "/srv/b", want: []string{"/srv/a"}},
		{name: "env when no flag", env: "/srv/b,/srv/c", want: []string{"/srv/b", "/srv/c"}},
		{name: "spaces and a trailing comma", flag: " /srv/a , /srv/b , ", want: []string{"/srv/a", "/srv/b"}},
		{name: "none opts out", flag: "none", want: nil},
		{name: "NONE opts out too", env: "NONE", want: nil},
		{name: "an all-blank value states no roots", flag: " , , ", want: nil},
		{
			name: "a path that is not on this box survives",
			flag: "/opt/barkpark/sites",
			want: []string{"/opt/barkpark/sites"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := resolveConsumerRoots(c.flag, c.env)
			if len(got) != len(c.want) {
				t.Fatalf("resolveConsumerRoots(%q, %q) = %v, want %v", c.flag, c.env, got, c.want)
			}
			for i := range got {
				if got[i] != c.want[i] {
					t.Fatalf("resolveConsumerRoots(%q, %q) = %v, want %v", c.flag, c.env, got, c.want)
				}
			}
		})
	}

	// The defaults are the finding, not a placeholder: the two trees holding
	// 25 GiB on the build-plane box must be in the list nothing overrode.
	def := resolveConsumerRoots("", "")
	for _, want := range []string{"/var/lib/containerd", "/var/lib/barkpark-builder"} {
		found := false
		for _, got := range def {
			if got == want {
				found = true
			}
		}
		if !found {
			t.Errorf("the default roots %v do not include %s — that is 14 GiB (containerd) and "+
				"11 GiB (builder) of a 37 GiB filesystem going unnamed on the box that fills up", def, want)
		}
	}
}
