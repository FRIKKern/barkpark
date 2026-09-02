package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/agent"
)

// TestResolveHealthToken pins the precedence AND — the load-bearing half — that
// every failure to find a token is a QUIET EMPTY with a source string that says
// so, never an error and never a garbage bearer. Before this, the token came
// only from a `--health-token` literal that exactly one box passed (via a systemd
// drop-in in nobody's source control), so every other box in the fleet read ""
// and nothing anywhere said so.
func TestResolveHealthToken(t *testing.T) {
	dir := t.TempDir()

	present := filepath.Join(dir, "agent.health.token")
	if err := os.WriteFile(present, []byte("bp_admin_LiveToken123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty.token")
	if err := os.WriteFile(empty, []byte("   \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	absent := filepath.Join(dir, "nothing-here.token")

	cases := []struct {
		name                     string
		flagToken, flagFile, env string
		wantToken                string
		wantSourceHas            string
	}{
		{
			// The guerrilla drop-in passes --health-token "$(cat …)". It must keep
			// winning, byte-for-byte, so that box behaves identically after this change.
			name:      "explicit flag wins over a readable file",
			flagToken: "bp_admin_FromTheDropIn", flagFile: present,
			wantToken: "bp_admin_FromTheDropIn", wantSourceHas: "--health-token",
		},
		{
			name: "file when no flag token", flagFile: present,
			wantToken: "bp_admin_LiveToken123", wantSourceHas: present,
		},
		{
			name: "trailing newline is trimmed", flagFile: present,
			wantToken: "bp_admin_LiveToken123", wantSourceHas: "read from",
		},
		{
			name: "env names the file when no flag", env: present,
			wantToken: "bp_admin_LiveToken123", wantSourceHas: present,
		},
		{
			name: "flag file beats env", flagFile: present, env: absent,
			wantToken: "bp_admin_LiveToken123", wantSourceHas: present,
		},
		{
			// THE case every box in the fleet is in today.
			name: "absent file is unmetered, not an error", flagFile: absent,
			wantToken: "", wantSourceHas: "unmetered",
		},
		{
			name: "empty file is unmetered", flagFile: empty,
			wantToken: "", wantSourceHas: "is empty",
		},
		{
			name: "blank flag file falls through to the default path", flagFile: "   ", env: present,
			wantToken: "bp_admin_LiveToken123", wantSourceHas: present,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tok, src := resolveHealthToken(c.flagToken, c.flagFile, c.env)
			if tok != c.wantToken {
				t.Errorf("token = %q, want %q (source %q)", tok, c.wantToken, src)
			}
			if !strings.Contains(src, c.wantSourceHas) {
				t.Errorf("source = %q, want it to mention %q", src, c.wantSourceHas)
			}
		})
	}
}

// TestResolveHealthTokenFallsBackToTheCanonicalPath pins that "nothing
// configured" resolves the SAME path the provisioner writes and the unit names —
// so a box whose unit predates the flag still finds a backfilled token file.
func TestResolveHealthTokenFallsBackToTheCanonicalPath(t *testing.T) {
	tok, src := resolveHealthToken("", "", "")
	if !strings.Contains(src, defaultHealthTokenFile) {
		t.Fatalf("source = %q, want it to name %q", src, defaultHealthTokenFile)
	}
	// On a dev box that path does not exist; the answer must still be a quiet
	// empty rather than a panic or a fabricated token.
	if tok != "" && !strings.Contains(src, "read from") {
		t.Fatalf("token %q with source %q: a non-empty token must name the file it came from", tok, src)
	}
}

// TestCommittedUnitNamesTheHealthTokenFile is the tripwire that keeps the two
// halves of this fix from drifting: the COMMITTED unit must pass
// --health-token-file, and the path it passes must be the one the agent falls
// back to. Rename the constant without touching the unit (or drop the flag from
// the unit) and this reds — which is the failure that otherwise ships as three
// silently-unmetered vitals on every box.
func TestCommittedUnitNamesTheHealthTokenFile(t *testing.T) {
	const unitPath = "../../deploy/systemd/barkpark-agent.service"
	b, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatalf("read committed unit: %v", err)
	}
	unit := string(b)
	var exec string
	for _, line := range strings.Split(unit, "\n") {
		if strings.HasPrefix(line, "ExecStart=") {
			exec = line
		}
	}
	if exec == "" {
		t.Fatalf("no ExecStart= in %s", unitPath)
	}
	if want := "--health-token-file " + defaultHealthTokenFile; !strings.Contains(exec, want) {
		t.Errorf("committed unit ExecStart does not pass %q:\n%s", want, exec)
	}
	// A PATH, never a value: the unit is a public committed artifact.
	if strings.Contains(exec, "--health-token ") {
		t.Errorf("committed unit passes a literal --health-token; it must pass only --health-token-file:\n%s", exec)
	}
}

// TestReqStatsProbeCarriesTheResolvedHealthToken is the red-without/green-with
// pair on the WIRE: the probe main builds sends no Authorization header when the
// token file is absent (so /v1/instance/request-stats 401s and the three vitals
// keep their -1 sentinels — today's fleet-wide behaviour), and sends exactly
// `Bearer <file contents>` when the file is there.
func TestReqStatsProbeCarriesTheResolvedHealthToken(t *testing.T) {
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "agent.health.token")
	absent := filepath.Join(dir, "not-written.token")

	var gotAuth string
	var authed bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		if gotAuth == "" {
			// What the real instance does: RequireToken denies an anonymous read
			// of instance-operational data.
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		authed = true
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"req_per_s":3.05,"p95_ms":1066,"err_5xx_per_s":0,"window_s":60}`))
	}))
	defer srv.Close()

	// RED half — no token file: no bearer, 401, sentinels.
	tok, _ := resolveHealthToken("", absent, "")
	reqPerS, p95, err5xx, _, err := agent.NewReqStatsProbe(srv.URL, tok, nil)()
	if err == nil {
		t.Fatal("probe with no health token must fail (the route 401s), keeping the sentinels")
	}
	if gotAuth != "" {
		t.Errorf("probe sent Authorization %q with no token file; want none", gotAuth)
	}
	if reqPerS != -1 || p95 != -1 || err5xx != -1 {
		t.Errorf("unauthenticated probe = (%v, %v, %v), want the -1 sentinels", reqPerS, p95, err5xx)
	}

	// GREEN half — token file present: bearer sent, real numbers land.
	if err := os.WriteFile(tokenFile, []byte("bp_admin_LiveToken123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tok, _ = resolveHealthToken("", tokenFile, "")
	reqPerS, p95, err5xx, _, err = agent.NewReqStatsProbe(srv.URL, tok, nil)()
	if err != nil {
		t.Fatalf("probe with the health token failed: %v", err)
	}
	if !authed {
		t.Fatal("server never saw an authenticated request")
	}
	if gotAuth != "Bearer bp_admin_LiveToken123" {
		t.Errorf("Authorization = %q, want the trimmed file contents as a bearer", gotAuth)
	}
	if reqPerS != 3.05 || p95 != 1066 || err5xx != 0 {
		t.Errorf("metered probe = (%v, %v, %v), want (3.05, 1066, 0)", reqPerS, p95, err5xx)
	}
}
