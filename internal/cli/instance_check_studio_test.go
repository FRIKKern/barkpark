package cli

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestInstanceStudioOrigin(t *testing.T) {
	for in, want := range map[string]string{
		"https://studio.example.com":              "https://studio.example.com",
		"https://Studio.Example.com:443/desk?x=1": "https://studio.example.com",
		"http://localhost:3000/":                  "http://localhost:3000",
		"http://localhost:80":                     "http://localhost",
	} {
		if got, err := instanceStudioOrigin(in); err != nil || got != want {
			t.Errorf("%s: got %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"studio.example.com", "ftp://x", "https://", "https://u:p@x.example.com"} {
		if _, err := instanceStudioOrigin(bad); err == nil {
			t.Errorf("%s: want an error", bad)
		}
	}
}

func TestInstanceCheckStudioURL(t *testing.T) {
	stubInstanceProbes(t, allExtensions, nil)
	studioProblems := func(env map[string]string, url string) []string {
		t.Helper()
		problems, _ := instanceCheck(t.Context(), env, instanceCheckOpts{skip: map[string]bool{}, studioURL: url})
		var out []string
		for _, p := range problems {
			if p.Doc == instanceDocStudio {
				out = append(out, p.Problem)
			}
		}
		sort.Strings(out)
		return out
	}

	env := completeEnv(t)
	if got := studioProblems(env, ""); len(got) != 0 {
		t.Fatalf("no --studio-url: want no Studio problems, got %v", got)
	}
	env["BARKPARK_ALWAYS_ALLOWED_ORIGINS"] = "https://cms.example.com,https://studio.example.com"
	if got := studioProblems(env, "https://studio.example.com"); len(got) != 1 || !strings.Contains(got[0], "is not set") {
		t.Fatalf("unset: got %v", got)
	}
	_, notes := instanceStudioCheck(env, "https://studio.example.com")
	if len(notes) != 2 || !strings.Contains(notes[0].Problem, "is in BARKPARK_ALWAYS_ALLOWED_ORIGINS") {
		t.Fatalf("want the allowed-origins note first, got %v", notes)
	}

	env["BARKPARK_STUDIO_SSO_ORIGINS"] = "https://studio.example.com, http://localhost:3000"
	if got := studioProblems(env, "https://studio.example.com/desk"); len(got) != 0 {
		t.Fatalf("listed: got %v", got)
	}
	if got := studioProblems(env, "http://localhost:3000"); len(got) != 0 {
		t.Fatalf("loopback http listed: got %v", got)
	}
	if got := studioProblems(env, "https://other.example.com"); len(got) != 1 || !strings.Contains(got[0], "does not list https://other.example.com") {
		t.Fatalf("not listed: got %v", got)
	}

	env["BARKPARK_STUDIO_SSO_ORIGINS"] = "https://studio.example.com/"
	got := studioProblems(env, "https://studio.example.com")
	if len(got) != 2 || !strings.Contains(strings.Join(got, "\n"), `lists "https://studio.example.com/", which never matches`) {
		t.Fatalf("trailing slash: got %v", got)
	}

	env["BARKPARK_STUDIO_SSO_ORIGINS"] = "http://studio.example.com"
	if got := studioProblems(env, "http://studio.example.com"); len(got) != 1 || !strings.Contains(got[0], "plain HTTP") {
		t.Fatalf("plain http: got %v", got)
	}
}

func TestInstanceCheckStudioURLFlag(t *testing.T) {
	stubInstanceProbes(t, allExtensions, nil)
	env := completeEnv(t)
	env["BARKPARK_STUDIO_SSO_ORIGINS"] = "http://localhost:3000"
	var b strings.Builder
	for k, v := range env {
		b.WriteString(k + "=" + v + "\n")
	}
	path := filepath.Join(t.TempDir(), "barkpark.env")
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, code := runInstanceVerb(t, "check", "--env-file", path, "--studio-url", "http://localhost:3000")
	if code != exitOK {
		t.Fatalf("listed studio: exit %d\n%s%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "receives sign-ins at http://localhost:3000/auth/cloud/callback") ||
		!strings.Contains(stdout, "redirect URI must be https://cms.example.com/v1/auth/oidc/<org>/callback") {
		t.Fatalf("want the callback note:\n%s", stdout)
	}

	stdout, _, code = runInstanceVerb(t, "check", "--env-file", path, "--studio-url", "https://studio.example.com")
	if code != exitGeneric || !strings.Contains(stdout, "does not list https://studio.example.com") || !strings.Contains(stdout, instanceDocStudio) {
		t.Fatalf("unlisted studio: exit %d\n%s", code, stdout)
	}

	if _, _, code := runInstanceVerb(t, "check", "--env-file", path, "--studio-url", "studio.example.com"); code != exitUsage {
		t.Fatalf("bad url: exit %d, want usage", code)
	}
}
