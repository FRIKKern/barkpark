package cloud

import (
	"context"
	"strings"
	"testing"
)

// sealedTestBundle seals a minimal real bp-bundle-v1 into a fake store and returns
// the store, the bundle prefix and the KEK — so a resurrect test drives the actual
// unseal path instead of a stubbed one.
func sealedTestBundle(t *testing.T) (*FakeBundleStore, string, string) {
	t.Helper()
	const kek = "cmVzdXJyZWN0LWtla3ZhbHVlLTAwMDAwMDA="
	t.Setenv("BARKPARK_BUNDLE_KEK", kek) // WriteBundle seals secrets.enc under this
	store := NewFakeBundleStore()
	man, err := WriteBundle(context.Background(), store, BundleWriteSpec{
		FQDN:           "acme.barkpark.cloud",
		Slug:           "acme",
		TeamID:         "team-1",
		SourceProvider: "hetzner",
		DBName:         "barkpark_acme",
		DB:             strings.NewReader("PGDMP-fake"),
		Media:          strings.NewReader("fake-media"),
		Secrets: map[string]string{
			"SECRET_KEY_BASE":    strings.Repeat("A", 64),
			"BARKPARK_KEK":       "a2VrdmFsdWU=",
			"BARKPARK_CLOAK_KEY": "Y2xvYWtrZXl2YWx1ZQ==",
		},
	})
	if err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	return store, man.Prefix(), kek
}

// TestRestoreInstallSecrets_WritesTrustedProxies covers the SECOND write path: a
// resurrect runs its own chain (never configureHost), so without this a resurrected
// box would come back believing only loopback and silently keep one rate-limit
// bucket per team. The trust list is a property of the CURRENT control plane, so it
// comes from the worker env — never from the archived bundle.
func TestRestoreInstallSecrets_WritesTrustedProxies(t *testing.T) {
	store, prefix, kek := sealedTestBundle(t)
	runner := &recordingRunner{}
	e := &RestoreExecutor{
		Store:          store,
		RunnerFor:      func(string) StepRunner { return runner },
		TrustedProxies: "203.0.113.7",
	}

	if err := e.InstallSecrets(context.Background(), "hetzner", prefix, kek, "10.0.0.9"); err != nil {
		t.Fatalf("InstallSecrets: %v", err)
	}
	all := runner.joined()
	if !strings.Contains(all, "BARKPARK_TRUSTED_PROXIES=203.0.113.7") {
		t.Fatalf("the resurrect never wrote the trust list; steps ran:\n%s", all)
	}
	// It must land WITH (not after) the identity merge — the single restart that
	// loads both comes later, at RestoreData's tail.
	xff := runner.eventIndex("BARKPARK_TRUSTED_PROXIES")
	if xff < 0 || len(runner.titles) < 2 {
		t.Fatalf("expected both the trust-list step and the identity merge; events: %v", runner.events)
	}
}

// TestRestoreInstallSecrets_NoStepWhenUnset / _MalformedFailsClosed pin the two
// honest edges of the resurrect path: unconfigured resurrects exactly as before,
// and a malformed worker value is refused BEFORE anything is unsealed or shipped
// (a .env that raises would turn the resurrect's own restart into an outage).
func TestRestoreInstallSecrets_NoStepWhenUnset(t *testing.T) {
	store, prefix, kek := sealedTestBundle(t)
	runner := &recordingRunner{}
	e := &RestoreExecutor{Store: store, RunnerFor: func(string) StepRunner { return runner }}

	if err := e.InstallSecrets(context.Background(), "hetzner", prefix, kek, "10.0.0.9"); err != nil {
		t.Fatalf("InstallSecrets: %v", err)
	}
	if strings.Contains(runner.joined(), "BARKPARK_TRUSTED_PROXIES") {
		t.Errorf("an unconfigured worker must not write a trust list; steps ran:\n%s", runner.joined())
	}
	if len(runner.titles) != 1 {
		t.Errorf("want exactly the identity-merge step, got %v", runner.titles)
	}
}

func TestRestoreInstallSecrets_MalformedFailsClosed(t *testing.T) {
	store, prefix, kek := sealedTestBundle(t)
	runner := &recordingRunner{}
	e := &RestoreExecutor{
		Store:          store,
		RunnerFor:      func(string) StepRunner { return runner },
		TrustedProxies: "10.0.0.0/8",
	}

	err := e.InstallSecrets(context.Background(), "hetzner", prefix, kek, "10.0.0.9")
	if err == nil {
		t.Fatal("InstallSecrets succeeded with a malformed egress value; want a closed failure")
	}
	if !strings.Contains(err.Error(), "BARKPARK_CLOUD_EGRESS_IPS") {
		t.Errorf("the error must name the env var an operator has to fix, got %v", err)
	}
	if len(runner.titles) != 0 {
		t.Errorf("nothing may reach the box on a refused value, ran: %v", runner.titles)
	}
}

// TestNormalizeTrustedProxies pins the shape gate on the control-plane egress
// value. It is deliberately stricter than "pass the operator's string through":
// api/config/runtime.exs RAISES on a malformed BARKPARK_TRUSTED_PROXIES entry, so
// an unvalidated write would not degrade a rate-limit bucket key — it would refuse
// to boot the instance at the very restart the go-live performs two steps later.
func TestNormalizeTrustedProxies(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		err  string // substring the error must carry; "" = must succeed
	}{
		// "not configured" is a supported STATE, never an error: the caller skips the
		// step and the instance keeps loopback-only trust.
		{name: "empty is not configured", in: "", want: ""},
		{name: "whitespace is not configured", in: "   ", want: ""},
		{name: "commas only is not configured", in: " , , ", want: ""},

		{name: "one v4 egress", in: "203.0.113.7", want: "203.0.113.7"},
		{name: "v4 + v6 egress, whitespace tolerated", in: "203.0.113.7, 2a01:4f9::1", want: "203.0.113.7,2a01:4f9::1"},

		// Alternate spellings of ONE address must collapse the same way client_ip
		// collapses them, or the .env entry never matches the hop the box sees.
		{name: "v6 canonicalized", in: "2A01:04F9:0000::0001", want: "2a01:4f9::1"},
		{name: "v4-mapped v6 canonicalized to v4", in: "::ffff:127.0.0.1", want: "127.0.0.1"},

		// The tempting wrong answer. A trusted RANGE lets any host inside it forge
		// every client's bucket key via x-forwarded-for, which is why the Elixir side
		// refuses ranges outright — so this gets its own message, not a generic one.
		{name: "CIDR refused by name", in: "10.0.0.0/8", err: "CIDR range"},
		{name: "single-host CIDR still refused", in: "203.0.113.7/32", err: "CIDR range"},

		// A hostname cannot be compared against a peer address, and runtime.exs
		// raises on it.
		{name: "hostname refused", in: "barkpark.cloud", err: "not a valid IP"},
		{name: "url refused", in: "https://barkpark.cloud", err: "not a valid IP"},
		{name: "host:port refused", in: "203.0.113.7:443", err: "not a valid IP"},
		{name: "octet out of range refused", in: "203.0.113.999", err: "not a valid IP"},

		// One good hop must not license a bad one — a partially-valid list is
		// refused WHOLE, because a partial write is the silent-coarseness bug again.
		{name: "mixed list refused whole", in: "203.0.113.7,notanip", err: "not a valid IP"},
		{name: "good hop then a range refused whole", in: "203.0.113.7,10.0.0.0/8", err: "CIDR range"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeTrustedProxies(tc.in)
			switch {
			case tc.err == "" && err != nil:
				t.Fatalf("NormalizeTrustedProxies(%q) errored unexpectedly: %v", tc.in, err)
			case tc.err != "" && err == nil:
				t.Fatalf("NormalizeTrustedProxies(%q) = %q, want an error mentioning %q", tc.in, got, tc.err)
			case tc.err != "":
				if !strings.Contains(err.Error(), tc.err) {
					t.Fatalf("NormalizeTrustedProxies(%q) error = %v, want it to mention %q", tc.in, err, tc.err)
				}
				if got != "" {
					t.Errorf("a rejected value must normalize to the empty string, got %q", got)
				}
				return
			}
			if got != tc.want {
				t.Errorf("NormalizeTrustedProxies(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestTrustedProxiesStep_ShapeAndIdempotence pins the .env edit: the anchored
// grep -v strip + a single printf append + the mv swap, so re-running the go-live
// chain leaves exactly one BARKPARK_TRUSTED_PROXIES line. It also pins the
// deliberate ABSENCE of a restart — the caller relies on secretsInstallStep's
// single restart to load this value, and a restart here would be a second one.
func TestTrustedProxiesStep_ShapeAndIdempotence(t *testing.T) {
	s := trustedProxiesStep("203.0.113.7")
	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("trustedProxiesStep argv = %v, want [bash -lc <script>]", s.Argv)
	}
	script := s.Argv[2]

	if !strings.Contains(script, "-e '^BARKPARK_TRUSTED_PROXIES='") {
		t.Errorf("the idempotent grep -v does not strip a prior anchored line; script:\n%s", script)
	}
	if got := strings.Count(script, "'BARKPARK_TRUSTED_PROXIES=%s\\n'"); got != 1 {
		t.Errorf("the value is appended %d times, want exactly 1; script:\n%s", got, script)
	}
	if !strings.Contains(script, "mv /opt/barkpark/.env.bpnew /opt/barkpark/.env") {
		t.Errorf("the rewrite is not swapped in with mv (a truncating write would risk a half file); script:\n%s", script)
	}
	if !strings.Contains(script, "203.0.113.7") {
		t.Errorf("the egress address never reaches the script; script:\n%s", script)
	}
	if strings.Contains(script, "systemctl restart") {
		t.Errorf("this step must NOT restart — secretsInstallStep's single restart loads the value; script:\n%s", script)
	}
	// Non-secret (a public server address): it SHOULD be narrated, so an operator
	// reading the step can see which address the box was told to believe.
	if !strings.Contains(s.Title, "203.0.113.7") || !strings.Contains(s.Cmd, "203.0.113.7") {
		t.Errorf("the address must be visible in the narrated Title/Cmd, got Title=%q Cmd=%q", s.Title, s.Cmd)
	}
	// The step rewrites .env, so a failure could echo neighbouring secret-shaped
	// lines (DATABASE_URL, SECRET_KEY_BASE) out of grep/printf.
	if !s.RedactEnvSecrets {
		t.Error("a step that rewrites .env must set RedactEnvSecrets")
	}
}

// TestProvision_WritesTrustedProxiesBeforeSecrets is the ORDERING proof: the trust
// list must land BEFORE the secrets step, because that step's single `systemctl
// restart barkpark` is what makes Phoenix read it (the trust list is read once at
// boot, exactly like PHX_HOST). Written after, the box would serve without it
// until some unrelated later restart — the silent-coarseness window this whole
// change exists to close.
func TestProvision_WritesTrustedProxiesBeforeSecrets(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, _ := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	wp.TrustedProxies = " 203.0.113.7 " // padded on purpose: the writer normalizes

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	all := runner.joined()
	if !strings.Contains(all, "BARKPARK_TRUSTED_PROXIES=203.0.113.7") {
		t.Fatalf("the chain never set BARKPARK_TRUSTED_PROXIES; steps ran:\n%s", all)
	}
	xff := runner.eventIndex("BARKPARK_TRUSTED_PROXIES")
	secrets := runner.eventIndex("minted per-instance secrets")
	if xff < 0 || secrets < 0 {
		t.Fatalf("missing step(s): trusted-proxies index %d, secrets index %d; events: %v", xff, secrets, runner.events)
	}
	if xff > secrets {
		t.Errorf("trusted-proxies ran at %d, AFTER secrets at %d — the secrets restart would not load the trust list; events: %v", xff, secrets, runner.events)
	}
}

// TestProvision_NoTrustedProxiesStepWhenUnset pins the back-compat state: an
// unconfigured worker provisions exactly as it did before this field existed (the
// box keeps loopback-only trust). Honest cost, not a hidden default — a fabricated
// address here would be worse than none.
func TestProvision_NoTrustedProxiesStepWhenUnset(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, _ := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	// wp.TrustedProxies deliberately left empty.

	if _, err := wp.Provision(context.Background(), spec); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if strings.Contains(runner.joined(), "BARKPARK_TRUSTED_PROXIES") {
		t.Errorf("an unconfigured worker must not write a trust list at all; steps ran:\n%s", runner.joined())
	}
	// The rest of the chain is untouched.
	if !strings.Contains(runner.joined(), "PHX_HOST=acme.barkpark.cloud") {
		t.Errorf("the chain regressed when TrustedProxies was unset; steps ran:\n%s", runner.joined())
	}
}

// TestProvision_MalformedTrustedProxiesFailsClosed proves a bad worker env fails
// the go-live CLOSED rather than shipping an .env that raises at the restart two
// steps later. A box that boots without its trust list is coarse; a box that does
// not boot at all is an outage — so this is refused before the secrets step runs.
func TestProvision_MalformedTrustedProxiesFailsClosed(t *testing.T) {
	spec := acmeSpec()
	wp, _, _, runner, reg := newFakeWarmPool(t, greenGate(spec.healthTarget()))
	wp.TrustedProxies = "10.0.0.0/8" // a range: refused on both sides

	_, err := wp.Provision(context.Background(), spec)
	if err == nil {
		t.Fatal("Provision succeeded with a malformed BARKPARK_CLOUD_EGRESS_IPS; want a closed failure")
	}
	if !strings.Contains(err.Error(), "BARKPARK_CLOUD_EGRESS_IPS") {
		t.Errorf("the error must name the env var an operator has to fix, got %v", err)
	}
	if strings.Contains(runner.joined(), "minted per-instance secrets") {
		t.Errorf("the secrets step ran anyway — the malformed value must fail BEFORE it; steps ran:\n%s", runner.joined())
	}
	// Fail-closed also means the box is never registered/marked ready.
	if got := len(reg.Registered()); got != 0 {
		t.Errorf("registered %d server(s) on a failed go-live, want 0", got)
	}
}
