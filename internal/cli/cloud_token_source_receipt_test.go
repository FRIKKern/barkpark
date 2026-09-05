package cli

// cloud_token_source_receipt_test.go pins the RECEIPT half of the cloud-token
// tier work: the origin label reaches the surfaces that already report cloud
// auth state (`bp doctor`, `bp whoami`) and the not-logged-in refusal names the
// non-interactive door (BARKPARK_CLOUD_TOKEN) a CI job can actually use.
//
// Everything runs against httptest servers and a temp config home — no live
// control plane, no live Barkpark, no network beyond loopback.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// receiptSecretToken is a DISTINCTIVE fake credential: every 6-char window of it
// is a string no surface has any innocent reason to print, which is what makes
// the no-leak assertion below discriminating rather than decorative.
const receiptSecretToken = "zqv9-SECRET-7f3a1d5e9b2c4a6d8e0f"

// TestDoctorGateOptsArmsCloudProbeFromEnvTier is the env-tier half of criterion
// c0 at the seam doctor actually uses: with ONLY BARKPARK_CLOUD_TOKEN set (no
// config.json at all — the CI shape), the cloud-sites probe is armed with the
// env credential rather than the empty persisted field.
func TestDoctorGateOptsArmsCloudProbeFromEnvTier(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, receiptSecretToken)

	g := doctorGateOpts("https://acme.test", "content-tok")
	if g.CloudSitesToken != receiptSecretToken {
		t.Fatalf("CloudSitesToken = %q, want the env credential — an env-tier token must not be ignored", g.CloudSitesToken)
	}
	if g.CloudSitesURL == "" {
		t.Fatal("CloudSitesURL empty: the cloud tier reads as ABSENT under an env-only credential")
	}
	if src := doctorCloudTokenSource(); src != CloudTokenSourceEnv {
		t.Fatalf("doctorCloudTokenSource() = %q, want %q", src, CloudTokenSourceEnv)
	}
}

// TestDoctorPrintsCloudTokenSource: both doctor views carry the SOURCE label,
// and neither carries the value.
func TestDoctorPrintsCloudTokenSource(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, receiptSecretToken)
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer srv.Close()
	withDoctorGate(t, srv) // keeps the gate on loopback: no live control plane

	human, _, _ := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if !strings.Contains(human, "cloud token source: "+CloudTokenSourceEnv) {
		t.Fatalf("human doctor report is missing the cloud token source:\n%s", human)
	}

	jsonOut, _, _ := runCloudCapture(t, true, func(out *writer) int {
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	var payload map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &payload); err != nil {
		t.Fatalf("parse doctor json: %v\n%s", err, jsonOut)
	}
	cloud, ok := payload["cloud"].(map[string]any)
	if !ok {
		t.Fatalf("doctor json missing a cloud block:\n%s", jsonOut)
	}
	if cloud["token_source"] != CloudTokenSourceEnv {
		t.Fatalf("doctor json cloud.token_source = %v, want %q", cloud["token_source"], CloudTokenSourceEnv)
	}
	assertNoCredentialSubstring(t, "doctor human", human)
	assertNoCredentialSubstring(t, "doctor json", jsonOut)
}

// TestDoctorOmitsCloudTokenSourceWithoutCredential is the byte-identity guard:
// with NO cloud credential in either tier, neither view gains a byte.
func TestDoctorOmitsCloudTokenSourceWithoutCredential(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewTLSServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer srv.Close()
	withDoctorGate(t, srv)

	human, _, _ := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	if strings.Contains(human, "cloud token source") {
		t.Fatalf("no credential is in scope; the human report must not mention a source:\n%s", human)
	}
	jsonOut, _, _ := runCloudCapture(t, true, func(out *writer) int {
		return runDoctor(out, []string{"--url", srv.URL, "--token", "tok"})
	})
	var payload map[string]any
	if err := json.Unmarshal([]byte(jsonOut), &payload); err != nil {
		t.Fatalf("parse doctor json: %v\n%s", err, jsonOut)
	}
	if _, present := payload["cloud"]; present {
		t.Fatalf("doctor json grew a cloud block with no credential in scope:\n%s", jsonOut)
	}
}

// fakeCloudPlane answers GET /v1/me with 200 so whoami's probe VERIFIES without
// leaving loopback.
func fakeCloudPlane(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"user":{"email":"ci@acme.test"},"team":{"slug":"acme"}}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestWhoamiCarriesCloudTokenSource walks both tiers: an env credential reads
// env:BARKPARK_CLOUD_TOKEN and a persisted one reads config:cloud_token, in the
// human line and in cloud.token_source — and neither prints the value.
func TestWhoamiCarriesCloudTokenSource(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		env        bool
	}{
		{"env tier", CloudTokenSourceEnv, true},
		{"config tier", CloudTokenSourceConfig, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			plane := fakeCloudPlane(t)
			cfg := &Config{CloudURL: plane.URL}
			if tc.env {
				t.Setenv(CloudTokenEnv, receiptSecretToken)
			} else {
				cfg.CloudToken = receiptSecretToken
			}
			if err := SaveConfig(cfg); err != nil {
				t.Fatalf("SaveConfig: %v", err)
			}
			content := unreachableWhoamiServer(t)

			var hOut, hErr bytes.Buffer
			hw := newWriter(&hOut, &hErr)
			hw.output = "table"
			if code := runWhoami(hw, globals{}, manifest.Context{Server: content.URL}, tokenProvenance{}); code != exitOK {
				t.Fatalf("runWhoami (human) exit = %d\n%s", code, hErr.String())
			}
			if !strings.Contains(hOut.String(), "[source "+tc.want+"]") {
				t.Fatalf("human whoami is missing the cloud token source %q:\n%s", tc.want, hOut.String())
			}

			cloud, raw := whoamiCloudPayload(t, content.URL)
			if cloud["token_source"] != tc.want {
				t.Fatalf("whoami json cloud.token_source = %v, want %q\n%s", cloud["token_source"], tc.want, raw)
			}
			assertNoCredentialSubstring(t, "whoami human", hOut.String())
			assertNoCredentialSubstring(t, "whoami json", raw)
		})
	}
}

// TestWhoamiOmitsCloudTokenSourceWhenLoggedOut is the other byte-identity guard:
// the logged-out arm has no credential to attribute and gains nothing.
func TestWhoamiOmitsCloudTokenSourceWhenLoggedOut(t *testing.T) {
	withTempConfigHome(t)
	content := unreachableWhoamiServer(t)

	var hOut, hErr bytes.Buffer
	hw := newWriter(&hOut, &hErr)
	hw.output = "table"
	if code := runWhoami(hw, globals{}, manifest.Context{Server: content.URL}, tokenProvenance{}); code != exitOK {
		t.Fatalf("runWhoami exit = %d\n%s", code, hErr.String())
	}
	if strings.Contains(hOut.String(), "[source ") {
		t.Fatalf("logged-out whoami must not print a source:\n%s", hOut.String())
	}
	cloud, raw := whoamiCloudPayload(t, content.URL)
	if _, present := cloud["token_source"]; present {
		t.Fatalf("logged-out whoami json grew a token_source key:\n%s", raw)
	}
}

// TestCloudSiteRefusalNamesEnvTier is criterion c1: the refusal a logged-out CI
// job hits names the door that job can actually walk through.
func TestCloudSiteRefusalNamesEnvTier(t *testing.T) {
	withTempConfigHome(t)

	refused := true
	stdout, stderrOut, code := runCloudCapture(t, false, func(out *writer) int {
		if _, ok := siteCloudConfig(out, "spawn a site"); ok {
			refused = false
			return exitOK
		}
		return exitAuth
	})
	if !refused {
		t.Fatal("siteCloudConfig must refuse with no credential in scope")
	}
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d", code, exitAuth)
	}
	// The refusal lands on stderr as a human line or on stdout as a machine
	// error envelope depending on the resolved output shape; the WORDING is what
	// this pins, so both channels are read.
	stderr := stdout + stderrOut
	if !strings.Contains(stderr, "not logged in") {
		t.Fatalf("the refusal lost its original wording:\n%s", stderr)
	}
	if !strings.Contains(stderr, CloudTokenEnv) {
		t.Fatalf("the refusal must name %s as the non-interactive option:\n%s", CloudTokenEnv, stderr)
	}
	if !strings.Contains(stderr, "for a CI job") {
		t.Fatalf("the refusal must say WHO the env door is for:\n%s", stderr)
	}
	assertNoCredentialSubstring(t, "site refusal", stderr)
}

// assertNoCredentialSubstring is criterion c2's instrument: NO 6-character
// window of the fixture credential may appear in a captured surface. A label is
// allowed to say where a token came from; nothing is allowed to say what it is,
// and a partial echo (a truncated "token prefix", a debug %v of the config) is
// exactly the leak a whole-value Contains check would wave through.
func assertNoCredentialSubstring(t *testing.T, surface, captured string) {
	t.Helper()
	const window = 6
	for i := 0; i+window <= len(receiptSecretToken); i++ {
		frag := receiptSecretToken[i : i+window]
		if strings.Contains(captured, frag) {
			t.Fatalf("%s leaks a %d-char window of the credential (%q):\n%s", surface, window, frag, captured)
		}
	}
}
