package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// isolateTokenSourceEnv gives one test a private config home, a private manifest
// cache, a clean BARKPARK_* dialect and a cwd with no .barkpark.json above it —
// the four ambient inputs that would otherwise let the developer's own shell
// decide what the resolver reads.
func isolateTokenSourceEnv(t *testing.T) {
	t.Helper()
	withTempConfigHome(t)
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	clearBarkparkEnv(t)
	t.Chdir(t.TempDir())
}

// TestTokenProvenanceLayers pins the token_source label for EVERY layer
// resolveContext folds — the table criterion 1 asks for. It drives
// resolveContextProv, the one function that produces both the token and its
// label, so a change to the precedence that forgot the label would red here.
//
// The two env names are pinned separately (BARKPARK_API_TOKEN is canonical,
// BARKPARK_TOKEN is the live alias that caused this row), and so is the
// precedence BETWEEN them and above them: --token beats env, and the canonical
// env name beats the alias when both are exported.
func TestTokenProvenanceLayers(t *testing.T) {
	const server = "https://api.example.test"

	cases := []struct {
		name string
		// cfg is saved to the temp config home; nil writes no config at all.
		cfg *Config
		// repoServer, when non-empty, writes a .barkpark.json naming that server.
		repoServer string
		env        map[string]string
		g          globals
		wantSource string
		wantToken  string
	}{
		{
			name:       "flag beats everything",
			cfg:        &Config{Server: server, Token: "saved-token-1111"},
			env:        map[string]string{"BARKPARK_TOKEN": "env-token-2222"},
			g:          globals{token: "flag-token-3333"},
			wantSource: tokenSourceFlag,
			wantToken:  "flag-token-3333",
		},
		{
			name:       "canonical env name",
			cfg:        &Config{Server: server, Token: "saved-token-1111"},
			env:        map[string]string{"BARKPARK_API_TOKEN": "env-token-2222"},
			wantSource: "env:BARKPARK_API_TOKEN",
			wantToken:  "env-token-2222",
		},
		{
			name:       "alias env name — the one this row was filed for",
			cfg:        &Config{Server: server, Token: "saved-token-1111"},
			env:        map[string]string{"BARKPARK_TOKEN": "env-token-2222"},
			wantSource: "env:BARKPARK_TOKEN",
			wantToken:  "env-token-2222",
		},
		{
			name: "canonical env name outranks the alias",
			cfg:  &Config{Server: server, Token: "saved-token-1111"},
			env: map[string]string{
				"BARKPARK_API_TOKEN": "canon-token-4444",
				"BARKPARK_TOKEN":     "alias-token-5555",
			},
			wantSource: "env:BARKPARK_API_TOKEN",
			wantToken:  "canon-token-4444",
		},
		{
			name:       "saved config",
			cfg:        &Config{Server: server, Token: "saved-token-1111"},
			wantSource: tokenSourceSaved,
			wantToken:  "saved-token-1111",
		},
		{
			name: "repo file — its server names a saved entry that carries the token",
			cfg: &Config{
				Server: server, Token: "saved-token-1111",
				KnownServers: []ServerEntry{
					{Name: "other", Server: "https://other.example.test", Token: "repo-token-6666"},
				},
			},
			repoServer: "other",
			wantSource: tokenSourceRepoFile,
			wantToken:  "repo-token-6666",
		},
		{
			name:       "-s <name> carries the entry's token — that is the SAVED credential, not a flag the user typed",
			cfg:        &Config{KnownServers: []ServerEntry{{Name: "cloud", Server: server, Token: "entry-token-7777"}}},
			g:          globals{server: "cloud"},
			wantSource: tokenSourceSaved,
			wantToken:  "entry-token-7777",
		},
		{
			name:       "baked default floor — no config, no env, no flag",
			cfg:        nil,
			wantSource: tokenSourceDefault,
			wantToken:  bakedDefaults().Token,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			isolateTokenSourceEnv(t)
			if tc.cfg != nil {
				if err := SaveConfig(tc.cfg); err != nil {
					t.Fatalf("SaveConfig: %v", err)
				}
			}
			if tc.repoServer != "" {
				body := []byte(`{"server":` + jsonQuote(tc.repoServer) + `}`)
				if err := os.WriteFile(filepath.Join(mustGetwd(t), repoFileName), body, 0o600); err != nil {
					t.Fatalf("write repo file: %v", err)
				}
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			ctx, prov := resolveContextProv(tc.g)
			if ctx.Token != tc.wantToken {
				t.Fatalf("resolved token = %q, want %q — the fixture did not exercise the layer it names", ctx.Token, tc.wantToken)
			}
			if prov.Source != tc.wantSource {
				t.Errorf("token_source = %q, want %q", prov.Source, tc.wantSource)
			}
			if prov.Tail == "" {
				t.Errorf("token tail is empty for a resolved token — whoami would print `set ()`")
			}
			if strings.Contains(prov.describe(), tc.wantToken) {
				t.Errorf("describe() = %q leaks the token VALUE %q — only a ≤4-char tail may ever be shown", prov.describe(), tc.wantToken)
			}
		})
	}
}

// TestTokenProvenanceShadowRequiresSameServer proves the shadow claim is
// CONDITIONAL, not merely present: an env token in front of a saved token for a
// DIFFERENT server is not a shadow, because that saved credential would not have
// been used anyway. Without this arm the warning would fire on every machine
// that exports both a token and a server override.
func TestTokenProvenanceShadowRequiresSameServer(t *testing.T) {
	isolateTokenSourceEnv(t)
	if err := SaveConfig(&Config{Server: "https://saved.example.test", Token: "saved-token-1111"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	// Same server: the saved token IS shadowed.
	t.Setenv("BARKPARK_TOKEN", "env-token-2222")
	_, prov := resolveContextProv(globals{})
	if !prov.shadowsSaved() {
		t.Fatalf("shadowsSaved() = false with an env token over a saved token for the same server — the whole hazard")
	}
	if prov.Alt != tokenSourceSaved {
		t.Errorf("Alt = %q, want %q", prov.Alt, tokenSourceSaved)
	}

	// Env ALSO redirects the server: the saved token belongs somewhere else.
	t.Setenv("BARKPARK_API_URL", "https://elsewhere.example.test")
	_, prov = resolveContextProv(globals{})
	if prov.shadowsSaved() {
		t.Errorf("shadowsSaved() = true when the env pointed at a different server — the saved credential was never in the running, and accusing it sends the operator to unset the wrong thing")
	}
}

// tokenSourceManifestJSON is the smallest manifest bp will parse, carrying the
// one field this row reads: the caller's auth_tier.
func tokenSourceManifestJSON(tier string) string {
	return `{"manifest_version":"1","etag":"t","server":{"name":"test","base_url":"http://replaced"},` +
		`"auth_tier":"` + tier + `","nouns":[],"commands":[]}`
}

// shadowServer stands up an instance that REFUSES one specific bearer with 401
// and answers every other credential with a manifest at `tier`. It is the
// httptest server criterion 2 asks for.
func shadowServer(t *testing.T, refuse, tier string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, manifest.CapabilitiesPath) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if refuse != "" && r.Header.Get("Authorization") == "Bearer "+refuse {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":{"code":"unauthorized","message":"bad token"}}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(tokenSourceManifestJSON(tier)))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// whoamiJSON runs `bp whoami -o json` through the REAL resolver and returns the
// decoded payload plus stderr.
func whoamiJSON(t *testing.T) (map[string]any, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	ctx, prov := resolveContextProv(globals{})
	if code := runWhoami(w, globals{}, ctx, prov); code != exitOK {
		t.Fatalf("runWhoami exit = %d (whoami reports config; it is never a connectivity gate)\n%s", code, stderr.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("decode whoami json: %v\n%s", err, stdout.String())
	}
	return payload, stderr.String()
}

// TestWhoamiEnvShadowWarning is the measured reproduction, in a test: a valid
// saved token for the server, a rejected BARKPARK_TOKEN in the shell. Before
// this row bp answered `source: saved, token_present: true` and named nothing.
func TestWhoamiEnvShadowWarning(t *testing.T) {
	isolateTokenSourceEnv(t)
	const envTok = "bogus-token-xyz"
	srv := shadowServer(t, envTok, "admin")
	if err := SaveConfig(&Config{Server: srv.URL, Token: "saved-good-token-abcd"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	t.Setenv("BARKPARK_TOKEN", envTok)

	payload, stderr := whoamiJSON(t)

	if got := payload["token_source"]; got != "env:BARKPARK_TOKEN" {
		t.Errorf("token_source = %v, want env:BARKPARK_TOKEN — `source: saved` described the SERVER and read as the credential", got)
	}
	if got := payload["token_present"]; got != true {
		t.Errorf("token_present = %v, want true", got)
	}

	warns, _ := payload["warnings"].([]any)
	if len(warns) != 1 {
		t.Fatalf("warnings = %v, want exactly ONE (the finding and its remedy travel together)\nstderr: %s", warns, stderr)
	}
	joined := strings.Join(append(warningStrings(warns), stderr), "\n")
	// The 401 arm must say REFUSED, not the tier-none sentence — two different
	// observations, and a warning that reports the wrong one is a lie the reader
	// will catch.
	if !strings.Contains(joined, "REFUSED") {
		t.Errorf("the 401 arm did not report a refusal; got:\n%s", joined)
	}
	for _, want := range []string{"BARKPARK_TOKEN", "…-xyz", "unset BARKPARK_TOKEN", "saved"} {
		if !strings.Contains(joined, want) {
			t.Errorf("warning does not mention %q; got:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, envTok) || strings.Contains(joined, "saved-good-token-abcd") {
		t.Errorf("the warning printed a token VALUE — only a ≤4-char tail is ever allowed:\n%s", joined)
	}
	if !strings.Contains(stderr, "BARKPARK_TOKEN") {
		t.Errorf("the warning never reached STDERR — a human running plain `bp whoami` would not see it:\n%s", stderr)
	}
}

// TestWhoamiEnvShadowWarningOnTierNone is the OTHER half of the trigger, and the
// shape actually measured against guerrilla: /v1/capabilities answers 200 with
// auth_tier "none" for an unknown bearer rather than 401ing. A warning wired only
// to the 401 would be silent on the exact server that produced this row.
func TestWhoamiEnvShadowWarningOnTierNone(t *testing.T) {
	isolateTokenSourceEnv(t)
	srv := shadowServer(t, "", "none") // 200 for everyone, tier none
	if err := SaveConfig(&Config{Server: srv.URL, Token: "saved-good-token-abcd"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	t.Setenv("BARKPARK_TOKEN", "bogus-token-xyz")

	payload, stderr := whoamiJSON(t)

	if got := payload["auth_tier"]; got != "none" {
		t.Fatalf("auth_tier = %v, want none — the fixture did not reproduce the measured shape", got)
	}
	warns, _ := payload["warnings"].([]any)
	if len(warns) == 0 {
		t.Fatalf("warnings[] is empty on a REACHABLE server answering tier none — the measured reproduction\nstderr: %s", stderr)
	}
	joined := strings.Join(warningStrings(warns), "\n")
	if !strings.Contains(joined, "unset BARKPARK_TOKEN") {
		t.Errorf("warning does not name the fix: %v", warns)
	}
	if !strings.Contains(joined, "auth_tier none") {
		t.Errorf("the tier-none arm claimed something other than what it observed: %v", warns)
	}
}

// TestWhoamiEnvTokenAcceptedPrintsNoWarning is the negative arm: an env token
// the server ACCEPTS is a deliberate override and must stay silent. Without this
// arm the warning would be a permanent nag for everyone who uses env tokens on
// purpose — which is how a real signal gets trained out of an operator.
func TestWhoamiEnvTokenAcceptedPrintsNoWarning(t *testing.T) {
	isolateTokenSourceEnv(t)
	srv := shadowServer(t, "", "admin") // refuses nothing: every token is admin
	if err := SaveConfig(&Config{Server: srv.URL, Token: "saved-good-token-abcd"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	t.Setenv("BARKPARK_TOKEN", "good-env-token-wxyz")

	payload, stderr := whoamiJSON(t)

	if got := payload["token_source"]; got != "env:BARKPARK_TOKEN" {
		t.Errorf("token_source = %v, want env:BARKPARK_TOKEN — the source is reported whether or not it is a problem", got)
	}
	if warns, _ := payload["warnings"].([]any); len(warns) != 0 {
		t.Errorf("warnings = %v, want none — an ACCEPTED env token is a deliberate override, not a hazard", warns)
	}
	if strings.Contains(stderr, "SHADOW") {
		t.Errorf("stderr warned about a working credential:\n%s", stderr)
	}
}

// TestWhoamiHumanTokenLineNamesTheSource pins the table/text renderer: the
// source prints next to the token line, where a human reads it.
func TestWhoamiHumanTokenLineNamesTheSource(t *testing.T) {
	isolateTokenSourceEnv(t)
	srv := shadowServer(t, "", "admin")
	if err := SaveConfig(&Config{Server: srv.URL, Token: "saved-good-token-abcd"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	ctx, prov := resolveContextProv(globals{})
	if code := runWhoami(w, globals{}, ctx, prov); code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "token:     set (saved") {
		t.Errorf("human token line does not name the source; got:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "saved-good-token-abcd") {
		t.Errorf("the human render leaked the token value:\n%s", stdout.String())
	}
}

// TestTierHiddenRefusalNamesTheCredential is the MUTATION-PROVEN criterion:
// strip the credential source out of the refusal (tierHiddenMsg /
// suggestUnknownNoun's errf) and this test reds on the missing source, then on
// the missing shadow remedy.
func TestTierHiddenRefusalNamesTheCredential(t *testing.T) {
	isolateTokenSourceEnv(t)
	if err := SaveConfig(&Config{Server: "https://api.example.test", Token: "saved-good-token-abcd"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	t.Setenv("BARKPARK_TOKEN", "bogus-token-xyz")
	_, prov := resolveContextProv(globals{})
	if !prov.shadowsSaved() {
		t.Fatalf("fixture did not reproduce the shadow — the assertions below would be vacuous")
	}

	tree := &manifest.Tree{} // an empty tree: `task` is hidden at this tier
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := suggestUnknownNoun(w, tree, "none", "task", prov, ""); code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage", code)
	}
	human := stderr.String()
	for _, want := range []string{
		"hidden at your auth tier",
		"credential in use: env:BARKPARK_TOKEN",
		"unset BARKPARK_TOKEN",
	} {
		if !strings.Contains(human, want) {
			t.Errorf("refusal missing %q — it sent the operator to redo a login that already works; got:\n%s", want, human)
		}
	}

	// The machine shape carries the same fact.
	var mOut, mErr bytes.Buffer
	mw := newWriter(&mOut, &mErr)
	mw.output = "json"
	suggestUnknownNoun(mw, tree, "none", "task", prov, "")
	machine := mOut.String() + mErr.String()
	for _, want := range []string{"hidden at your auth tier", "env:BARKPARK_TOKEN", "unset BARKPARK_TOKEN"} {
		if !strings.Contains(machine, want) {
			t.Errorf("machine refusal missing %q; got:\n%s", want, machine)
		}
	}
	if strings.Contains(human+machine, "bogus-token-xyz") {
		t.Errorf("the refusal printed the token VALUE:\n%s", human+machine)
	}
}

// TestTierHiddenRefusalStillTellsAnAnonymousCallerToLogIn guards the arm the fix
// must not break: with no credential to shadow, `barkpark login` IS the remedy.
func TestTierHiddenRefusalStillTellsAnAnonymousCallerToLogIn(t *testing.T) {
	isolateTokenSourceEnv(t)
	_, prov := resolveContextProv(globals{})

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	suggestUnknownNoun(w, &manifest.Tree{}, "none", "task", prov, "")
	if !strings.Contains(stderr.String(), "barkpark login") {
		t.Errorf("an unshadowed caller lost the login advice:\n%s", stderr.String())
	}
	if !strings.Contains(stderr.String(), "credential in use: "+tokenSourceDefault) {
		t.Errorf("refusal does not name the baked default credential it used:\n%s", stderr.String())
	}
}

// TestOnboardingAuthArmReportsTokenSource covers the doctor half of criterion 3.
func TestOnboardingAuthArmReportsTokenSource(t *testing.T) {
	isolateTokenSourceEnv(t)
	if err := SaveConfig(&Config{Server: "https://api.example.test", Token: "saved-good-token-abcd"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	t.Setenv("BARKPARK_TOKEN", "bogus-token-xyz")
	ctx, prov := resolveContextProv(globals{})

	m, err := manifest.Parse([]byte(tokenSourceManifestJSON("none")))
	if err != nil {
		t.Fatalf("parse fixture manifest: %v", err)
	}
	a := onboardingAuth(m, ctx, prov)
	if a.TokenSource != "env:BARKPARK_TOKEN" {
		t.Errorf("auth.token_source = %q, want env:BARKPARK_TOKEN", a.TokenSource)
	}
	if !strings.Contains(a.TokenShadow, "unset BARKPARK_TOKEN") {
		t.Errorf("auth.token_shadow does not name the fix: %q", a.TokenShadow)
	}
	if !strings.Contains(authDetail(a), "credential env:BARKPARK_TOKEN") {
		t.Errorf("the human AUTH line does not name the credential: %q", authDetail(a))
	}
	if strings.Contains(a.TokenShadow+authDetail(a), "bogus-token-xyz") {
		t.Errorf("the doctor receipt leaked the token value: %q", a.TokenShadow)
	}
}

// --- tiny helpers ------------------------------------------------------------

func warningStrings(v []any) []string {
	out := make([]string, 0, len(v))
	for _, w := range v {
		if s, ok := w.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func mustGetwd(t *testing.T) string {
	t.Helper()
	d, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return d
}
